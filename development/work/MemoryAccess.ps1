param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('ReadChain', 'ReadInt32', 'WriteInt32', 'ReadBytes', 'WriteBytes')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [UInt64]$Address,

    [string]$Offsets = '',

    [int]$Value,

    [string]$Bytes = '',

    [int]$Length = 16
)

$source = @'
using System;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;

public sealed class CodexMemoryAccess : IDisposable
{
    private readonly IntPtr process;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer, UIntPtr size, out UIntPtr bytesRead);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteProcessMemory(IntPtr process, IntPtr address, byte[] buffer, UIntPtr size, out UIntPtr bytesWritten);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool VirtualProtectEx(IntPtr process, IntPtr address, UIntPtr size, uint newProtect, out uint oldProtect);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public CodexMemoryAccess(int processId)
    {
        const uint access = 0x0010 | 0x0020 | 0x0008 | 0x0400;
        process = OpenProcess(access, false, processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
    }

    public byte[] Read(ulong address, int length)
    {
        var buffer = new byte[length];
        UIntPtr read;
        if (!ReadProcessMemory(process, new IntPtr((long)address), buffer, (UIntPtr)(uint)length, out read) || read.ToUInt64() != (ulong)length)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "ReadProcessMemory failed at 0x" + address.ToString("X"));
        return buffer;
    }

    public ulong ReadUInt64(ulong address) { return BitConverter.ToUInt64(Read(address, 8), 0); }
    public int ReadInt32(ulong address) { return BitConverter.ToInt32(Read(address, 4), 0); }

    public void Write(ulong address, byte[] bytes)
    {
        uint oldProtect;
        if (!VirtualProtectEx(process, new IntPtr((long)address), (UIntPtr)(uint)bytes.Length, 0x40, out oldProtect))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "VirtualProtectEx failed");
        try
        {
            UIntPtr written;
            if (!WriteProcessMemory(process, new IntPtr((long)address), bytes, (UIntPtr)(uint)bytes.Length, out written) || written.ToUInt64() != (ulong)bytes.Length)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteProcessMemory failed");
        }
        finally
        {
            uint ignored;
            VirtualProtectEx(process, new IntPtr((long)address), (UIntPtr)(uint)bytes.Length, oldProtect, out ignored);
        }
    }

    public void Dispose()
    {
        if (process != IntPtr.Zero) CloseHandle(process);
    }
}
'@

if (-not ('CodexMemoryAccess' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

$memory = [CodexMemoryAccess]::new($ProcessId)
try {
    switch ($Mode) {
        'ReadChain' {
            $current = $Address
            "base address: 0x{0:X16}" -f $current
            $step = 0
            foreach ($offsetText in ($Offsets -split ',' | Where-Object { $_ -ne '' })) {
                $pointer = $memory.ReadUInt64($current)
                $normalizedOffset = $offsetText.Trim()
                if ($normalizedOffset.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
                    $normalizedOffset = $normalizedOffset.Substring(2)
                }
                $offset = [Convert]::ToUInt64($normalizedOffset, 16)
                $current = $pointer + $offset
                $step++
                "step {0}: ptr=0x{1:X16}, +0x{2:X} => 0x{3:X16}" -f $step,$pointer,$offset,$current
            }
            "int32: {0}" -f $memory.ReadInt32($current)
        }
        'ReadInt32' {
            $memory.ReadInt32($Address)
        }
        'WriteInt32' {
            $memory.Write($Address, [BitConverter]::GetBytes([int]$Value))
            "wrote int32 {0} to 0x{1:X16}" -f $Value,$Address
        }
        'ReadBytes' {
            ($memory.Read($Address, $Length) | ForEach-Object { $_.ToString('X2') }) -join ' '
        }
        'WriteBytes' {
            $parsed = @($Bytes -split '\s+' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })
            $memory.Write($Address, [byte[]]$parsed)
            "wrote {0} byte(s) to 0x{1:X16}" -f $parsed.Count,$Address
        }
    }
}
finally {
    $memory.Dispose()
}
