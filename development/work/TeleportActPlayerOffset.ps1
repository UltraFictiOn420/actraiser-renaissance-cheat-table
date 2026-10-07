param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [float]$DeltaX = 0,
    [float]$DeltaY = 0
)

$source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;

public sealed class ActPlayerOffsetTeleporter : IDisposable
{
    private readonly IntPtr process;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer, UIntPtr size, out UIntPtr bytesRead);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteProcessMemory(IntPtr process, IntPtr address, byte[] buffer, UIntPtr size, out UIntPtr bytesWritten);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr size, uint allocationType, uint protect);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool VirtualFreeEx(IntPtr process, IntPtr address, UIntPtr size, uint freeType);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateRemoteThread(IntPtr process, IntPtr attributes, UIntPtr stackSize, IntPtr startAddress, IntPtr parameter, uint flags, out uint threadId);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public ActPlayerOffsetTeleporter(int processId)
    {
        process = OpenProcess(0x0010 | 0x0020 | 0x0008 | 0x0002 | 0x0400, false, processId);
        if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
    }

    private byte[] Read(ulong address, int length)
    {
        var bytes = new byte[length];
        UIntPtr read;
        if (!ReadProcessMemory(process, new IntPtr((long)address), bytes, (UIntPtr)(uint)length, out read) || read.ToUInt64() != (ulong)length)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "ReadProcessMemory failed at 0x" + address.ToString("X"));
        return bytes;
    }

    private ulong U64(ulong address) { return BitConverter.ToUInt64(Read(address, 8), 0); }
    private float F32(ulong address) { return BitConverter.ToSingle(Read(address, 4), 0); }

    private void Write(ulong address, byte[] bytes)
    {
        UIntPtr written;
        if (!WriteProcessMemory(process, new IntPtr((long)address), bytes, (UIntPtr)(uint)bytes.Length, out written) || written.ToUInt64() != (ulong)bytes.Length)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteProcessMemory failed at 0x" + address.ToString("X"));
    }

    private void WriteFloat(ulong address, float value) { Write(address, BitConverter.GetBytes(value)); }

    public string Teleport(ulong gameAssemblyBase, float deltaX, float deltaY)
    {
        ulong sceneClass = U64(gameAssemblyBase + 0x16A3788);
        ulong sceneStatic = U64(sceneClass + 0xB8);
        ulong scene = U64(sceneStatic + 0x50);
        ulong player = U64(scene + 0xC0);
        ulong svObject = U64(player + 0x78);
        if (svObject == 0) throw new InvalidOperationException("The player's SVObject was null");

        float oldX = F32(player + 0xCC);
        float oldY = F32(player + 0xD0);
        float targetX = oldX + deltaX;
        float targetY = oldY + deltaY;
        float targetZ = F32(player + 0xD4);

        IntPtr remote = VirtualAllocEx(process, IntPtr.Zero, (UIntPtr)0x100, 0x1000 | 0x2000, 0x40);
        if (remote == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "VirtualAllocEx failed");
        try
        {
            ulong codeAddress = (ulong)remote.ToInt64();
            ulong vectorAddress = codeAddress + 0x80;
            ulong teleportAddress = gameAssemblyBase + 0xFCB430;
            var code = new List<byte>();
            code.AddRange(new byte[] { 0x48, 0x83, 0xEC, 0x28 });
            code.AddRange(new byte[] { 0x48, 0xB9 }); code.AddRange(BitConverter.GetBytes(svObject));
            code.AddRange(new byte[] { 0x48, 0xBA }); code.AddRange(BitConverter.GetBytes(vectorAddress));
            code.AddRange(new byte[] { 0x45, 0x33, 0xC0 });
            code.AddRange(new byte[] { 0x48, 0xB8 }); code.AddRange(BitConverter.GetBytes(teleportAddress));
            code.AddRange(new byte[] { 0xFF, 0xD0, 0x48, 0x83, 0xC4, 0x28, 0x33, 0xC0, 0xC3 });
            Write(codeAddress, code.ToArray());
            var vector = new byte[12];
            Buffer.BlockCopy(BitConverter.GetBytes(targetX), 0, vector, 0, 4);
            Buffer.BlockCopy(BitConverter.GetBytes(targetY), 0, vector, 4, 4);
            Buffer.BlockCopy(BitConverter.GetBytes(targetZ), 0, vector, 8, 4);
            Write(vectorAddress, vector);

            uint threadId;
            IntPtr thread = CreateRemoteThread(process, IntPtr.Zero, UIntPtr.Zero, remote, IntPtr.Zero, 0, out threadId);
            if (thread == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateRemoteThread failed");
            try
            {
                uint wait = WaitForSingleObject(thread, 5000);
                if (wait != 0) throw new InvalidOperationException("Native teleport call did not finish (wait=" + wait + ")");
            }
            finally { CloseHandle(thread); }

            // Keep the ACTOL-side cached position and movement state synchronized.
            WriteFloat(player + 0xCC, targetX);
            WriteFloat(player + 0xD0, targetY);
            WriteFloat(player + 0xD4, targetZ);
            for (ulong offset = 0xD8; offset <= 0xEC; offset += 4) WriteFloat(player + offset, 0.0f);

            return String.Format(CultureInfo.InvariantCulture,
                "Moved player from ({0:F3},{1:F3}) to ({2:F3},{3:F3})", oldX, oldY, targetX, targetY);
        }
        finally { VirtualFreeEx(process, remote, UIntPtr.Zero, 0x8000); }
    }

    public void Dispose() { if (process != IntPtr.Zero) CloseHandle(process); }
}
'@

if (-not ('ActPlayerOffsetTeleporter' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

$targetProcess = Get-Process -Id $ProcessId -ErrorAction Stop
$module = $targetProcess.Modules | Where-Object ModuleName -eq 'GameAssembly.dll' | Select-Object -First 1
if (-not $module) { throw 'GameAssembly.dll was not loaded.' }

$teleporter = [ActPlayerOffsetTeleporter]::new($ProcessId)
try {
    $teleporter.Teleport([UInt64]$module.BaseAddress.ToInt64(), $DeltaX, $DeltaY)
}
finally {
    $teleporter.Dispose()
}
