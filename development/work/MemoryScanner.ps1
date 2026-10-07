param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [string]$Spec,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [switch]$Intersect
)

$source = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;

public static class CodexMemoryScanner
{
    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORY_BASIC_INFORMATION
    {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public ushort PartitionId;
        public UIntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(
        IntPtr process,
        IntPtr baseAddress,
        [Out] byte[] buffer,
        UIntPtr size,
        out UIntPtr bytesRead);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern UIntPtr VirtualQueryEx(
        IntPtr process,
        IntPtr address,
        out MEMORY_BASIC_INFORMATION information,
        UIntPtr informationLength);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    private const uint PROCESS_VM_READ = 0x0010;
    private const uint PROCESS_QUERY_INFORMATION = 0x0400;
    private const uint MEM_COMMIT = 0x1000;
    private const uint PAGE_GUARD = 0x100;
    private const uint PAGE_NOACCESS = 0x01;
    private const int CHUNK_SIZE = 1024 * 1024;

    private sealed class Target
    {
        public string Label;
        public uint Bits;
        public HashSet<ulong> Previous;
        public List<ulong> Matches = new List<ulong>();
    }

    public static Dictionary<string, long> Scan(int processId, string spec, string outputDirectory, bool intersect)
    {
        Directory.CreateDirectory(outputDirectory);
        var targets = ParseTargets(spec, outputDirectory, intersect);
        var byBits = new Dictionary<uint, List<Target>>();
        foreach (var target in targets)
        {
            List<Target> list;
            if (!byBits.TryGetValue(target.Bits, out list))
            {
                list = new List<Target>();
                byBits[target.Bits] = list;
            }
            list.Add(target);
        }

        IntPtr process = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, false, processId);
        if (process == IntPtr.Zero)
            throw new InvalidOperationException("OpenProcess failed with Win32 error " + Marshal.GetLastWin32Error());

        ulong scannedBytes = 0;
        try
        {
            ulong address = 0;
            int mbiSize = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION));
            byte[] buffer = new byte[CHUNK_SIZE];

            while (address < 0x00007FFFFFFFFFFFUL)
            {
                MEMORY_BASIC_INFORMATION mbi;
                UIntPtr queried = VirtualQueryEx(process, new IntPtr((long)address), out mbi, (UIntPtr)(uint)mbiSize);
                if (queried == UIntPtr.Zero)
                    break;

                ulong baseAddress = (ulong)mbi.BaseAddress.ToInt64();
                ulong regionSize = mbi.RegionSize.ToUInt64();
                ulong nextAddress = baseAddress + regionSize;
                if (nextAddress <= address)
                    break;

                bool readable = mbi.State == MEM_COMMIT &&
                                (mbi.Protect & PAGE_GUARD) == 0 &&
                                (mbi.Protect & PAGE_NOACCESS) == 0 &&
                                IsWritable(mbi.Protect);

                if (readable)
                {
                    ulong cursor = baseAddress;
                    ulong end = nextAddress;
                    while (cursor < end)
                    {
                        int request = (int)Math.Min((ulong)buffer.Length, end - cursor);
                        UIntPtr bytesRead;
                        bool ok = ReadProcessMemory(process, new IntPtr((long)cursor), buffer, (UIntPtr)(uint)request, out bytesRead);
                        int count = ok ? checked((int)bytesRead.ToUInt64()) : 0;
                        if (count >= 4)
                        {
                            scannedBytes += (uint)count;
                            int start = (int)((4 - (cursor & 3UL)) & 3UL);
                            for (int i = start; i <= count - 4; i += 4)
                            {
                                uint bits = (uint)(buffer[i] |
                                                   (buffer[i + 1] << 8) |
                                                   (buffer[i + 2] << 16) |
                                                   (buffer[i + 3] << 24));
                                List<Target> matching;
                                if (!byBits.TryGetValue(bits, out matching))
                                    continue;

                                ulong matchAddress = cursor + (uint)i;
                                foreach (var target in matching)
                                {
                                    if (target.Previous == null || target.Previous.Contains(matchAddress))
                                        target.Matches.Add(matchAddress);
                                }
                            }
                        }
                        cursor += (uint)request;
                    }
                }

                address = nextAddress;
            }
        }
        finally
        {
            CloseHandle(process);
        }

        var result = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (var target in targets)
        {
            string path = Path.Combine(outputDirectory, target.Label + ".txt");
            using (var writer = new StreamWriter(path, false))
            {
                foreach (ulong match in target.Matches)
                    writer.WriteLine(match.ToString("X16", CultureInfo.InvariantCulture));
            }
            result[target.Label] = target.Matches.Count;
        }
        result["_scanned_bytes"] = checked((long)scannedBytes);
        return result;
    }

    private static bool IsWritable(uint protect)
    {
        uint basic = protect & 0xFF;
        return basic == 0x04 || basic == 0x08 || basic == 0x40 || basic == 0x80;
    }

    private static List<Target> ParseTargets(string spec, string outputDirectory, bool intersect)
    {
        var targets = new List<Target>();
        foreach (string raw in spec.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string[] parts = raw.Split(':');
            if (parts.Length != 3)
                throw new ArgumentException("Invalid target spec: " + raw);

            string label = parts[0];
            string type = parts[1].ToLowerInvariant();
            string valueText = parts[2];
            uint bits;
            if (type == "i32")
            {
                int value = int.Parse(valueText, CultureInfo.InvariantCulture);
                bits = unchecked((uint)value);
            }
            else if (type == "f32")
            {
                float value = float.Parse(valueText, CultureInfo.InvariantCulture);
                bits = BitConverter.ToUInt32(BitConverter.GetBytes(value), 0);
            }
            else
            {
                throw new ArgumentException("Unsupported type in target spec: " + type);
            }

            HashSet<ulong> previous = null;
            if (intersect)
            {
                previous = new HashSet<ulong>();
                string path = Path.Combine(outputDirectory, label + ".txt");
                if (!File.Exists(path))
                    throw new FileNotFoundException("Cannot intersect without a prior candidate file", path);
                foreach (string line in File.ReadLines(path))
                {
                    ulong parsed;
                    if (ulong.TryParse(line.Trim(), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out parsed))
                        previous.Add(parsed);
                }
            }

            targets.Add(new Target { Label = label, Bits = bits, Previous = previous });
        }
        return targets;
    }
}
'@

if (-not ('CodexMemoryScanner' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

[CodexMemoryScanner]::Scan($ProcessId, $Spec, $OutputDirectory, [bool]$Intersect) |
    Sort-Object Name |
    Format-Table -AutoSize
