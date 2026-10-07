param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [string]$HpCandidateFile
)

$source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;

public static class SVParameterOwnerFinder
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
    private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer, UIntPtr size, out UIntPtr bytesRead);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern UIntPtr VirtualQueryEx(IntPtr process, IntPtr address, out MEMORY_BASIC_INFORMATION information, UIntPtr informationLength);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    private static bool ReadExact(IntPtr process, ulong address, byte[] buffer)
    {
        UIntPtr read;
        return ReadProcessMemory(process, new IntPtr((long)address), buffer, (UIntPtr)(uint)buffer.Length, out read) && read.ToUInt64() == (ulong)buffer.Length;
    }

    private static bool IsWritable(uint protect)
    {
        uint basic = protect & 0xFF;
        return basic == 0x04 || basic == 0x08 || basic == 0x40 || basic == 0x80;
    }

    public static string[] Find(int processId, string candidateFile)
    {
        IntPtr process = OpenProcess(0x0010 | 0x0400, false, processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");

        try
        {
            var targets = new HashSet<ulong>();
            foreach (string line in File.ReadLines(candidateFile))
            {
                ulong hpAddress;
                if (!ulong.TryParse(line.Trim(), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out hpAddress))
                    continue;

                var fields = new byte[24];
                if (!ReadExact(process, hpAddress, fields)) continue;
                int hp = BitConverter.ToInt32(fields, 0);
                int maxHp = BitConverter.ToInt32(fields, 4);
                int type = BitConverter.ToInt32(fields, 16);
                int uniqueId = BitConverter.ToInt32(fields, 20);
                if (hp == 200 && maxHp == 200 && type >= 0 && type <= 2 && uniqueId >= 0 && uniqueId <= 100000)
                    targets.Add(hpAddress - 0x10);
            }

            var output = new List<string>();
            var seenOwners = new HashSet<ulong>();
            var chunk = new byte[1024 * 1024];
            int mbiSize = Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION));
            ulong address = 0;

            while (address < 0x00007FFFFFFFFFFFUL)
            {
                MEMORY_BASIC_INFORMATION mbi;
                UIntPtr queried = VirtualQueryEx(process, new IntPtr((long)address), out mbi, (UIntPtr)(uint)mbiSize);
                if (queried == UIntPtr.Zero) break;
                ulong regionBase = (ulong)mbi.BaseAddress.ToInt64();
                ulong regionSize = mbi.RegionSize.ToUInt64();
                ulong next = regionBase + regionSize;
                if (next <= address) break;

                if (mbi.State == 0x1000 && (mbi.Protect & 0x100) == 0 && (mbi.Protect & 0x01) == 0 && IsWritable(mbi.Protect))
                {
                    for (ulong cursor = regionBase; cursor < next; cursor += (uint)chunk.Length)
                    {
                        int request = (int)Math.Min((ulong)chunk.Length, next - cursor);
                        UIntPtr read;
                        if (!ReadProcessMemory(process, new IntPtr((long)cursor), chunk, (UIntPtr)(uint)request, out read))
                            continue;
                        int count = (int)read.ToUInt64();
                        int start = (int)((8 - (cursor & 7UL)) & 7UL);
                        for (int i = start; i <= count - 8; i += 8)
                        {
                            ulong value = BitConverter.ToUInt64(chunk, i);
                            if (!targets.Contains(value)) continue;
                            ulong reference = cursor + (uint)i;
                            if (reference < 0x18) continue;
                            ulong owner = reference - 0x18;
                            if (!seenOwners.Add(owner)) continue;

                            var ownerData = new byte[0x110];
                            if (!ReadExact(process, owner, ownerData)) continue;
                            ulong classPointer = BitConverter.ToUInt64(ownerData, 0);
                            byte isPlayerble = ownerData[0xFD];
                            int hp = 0, maxHp = 0, mp = 0, maxMp = 0, type = 0, uniqueId = 0;
                            var fields = new byte[24];
                            if (ReadExact(process, value + 0x10, fields))
                            {
                                hp = BitConverter.ToInt32(fields, 0);
                                maxHp = BitConverter.ToInt32(fields, 4);
                                mp = BitConverter.ToInt32(fields, 8);
                                maxMp = BitConverter.ToInt32(fields, 12);
                                type = BitConverter.ToInt32(fields, 16);
                                uniqueId = BitConverter.ToInt32(fields, 20);
                            }
                            output.Add(String.Format(CultureInfo.InvariantCulture,
                                "owner=0x{0:X16} class=0x{1:X16} param=0x{2:X16} playerFlag={3} HP={4}/{5} MP={6}/{7} Type={8} UniqueID={9}",
                                owner, classPointer, value, isPlayerble, hp, maxHp, mp, maxMp, type, uniqueId));
                        }
                    }
                }
                address = next;
            }
            return output.ToArray();
        }
        finally
        {
            CloseHandle(process);
        }
    }
}
'@

if (-not ('SVParameterOwnerFinder' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

[SVParameterOwnerFinder]::Find($ProcessId, $HpCandidateFile)
