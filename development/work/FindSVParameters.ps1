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

public static class SVParameterFinder
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer, UIntPtr size, out UIntPtr bytesRead);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static string[] Find(int processId, string candidateFile)
    {
        IntPtr process = OpenProcess(0x0010 | 0x0400, false, processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");

        var output = new List<string>();
        try
        {
            foreach (string line in File.ReadLines(candidateFile))
            {
                ulong hpAddress;
                if (!ulong.TryParse(line.Trim(), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out hpAddress))
                    continue;

                var bytes = new byte[24];
                UIntPtr read;
                if (!ReadProcessMemory(process, new IntPtr((long)hpAddress), bytes, (UIntPtr)24, out read) || read.ToUInt64() != 24)
                    continue;

                int hp = BitConverter.ToInt32(bytes, 0);
                int maxHp = BitConverter.ToInt32(bytes, 4);
                int mp = BitConverter.ToInt32(bytes, 8);
                int maxMp = BitConverter.ToInt32(bytes, 12);
                int type = BitConverter.ToInt32(bytes, 16);
                int uniqueId = BitConverter.ToInt32(bytes, 20);

                if (hp == 200 && maxHp == 200 && type >= 0 && type <= 2 && uniqueId >= 0 && uniqueId <= 100000)
                {
                    output.Add(String.Format(CultureInfo.InvariantCulture,
                        "object=0x{0:X16} hp@0x{1:X16} HP={2}/{3} MP={4}/{5} Type={6} UniqueID={7}",
                        hpAddress - 0x10, hpAddress, hp, maxHp, mp, maxMp, type, uniqueId));
                }
            }
        }
        finally
        {
            CloseHandle(process);
        }
        return output.ToArray();
    }
}
'@

if (-not ('SVParameterFinder' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

[SVParameterFinder]::Find($ProcessId, $HpCandidateFile)
