param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId
)

$source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

public sealed class NativeActTeleportTester : IDisposable
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

    public NativeActTeleportTester(int processId)
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
    private int I32(ulong address) { return BitConverter.ToInt32(Read(address, 4), 0); }
    private float F32(ulong address) { return BitConverter.ToSingle(Read(address, 4), 0); }
    private string ManagedString(ulong address)
    {
        if (address == 0) return "";
        int length = I32(address + 0x10);
        if (length <= 0 || length > 512) return "";
        return Encoding.Unicode.GetString(Read(address + 0x14, length * 2));
    }

    private void Write(ulong address, byte[] bytes)
    {
        UIntPtr written;
        if (!WriteProcessMemory(process, new IntPtr((long)address), bytes, (UIntPtr)(uint)bytes.Length, out written) || written.ToUInt64() != (ulong)bytes.Length)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WriteProcessMemory failed");
    }

    public string Teleport(ulong gameAssemblyBase)
    {
        ulong sceneClass = U64(gameAssemblyBase + 0x16A3788);
        ulong sceneStatic = U64(sceneClass + 0xB8);
        ulong scene = U64(sceneStatic + 0x50);
        ulong player = U64(scene + 0xC0);
        ulong svObject = U64(player + 0x78);
        float playerX = F32(player + 0xCC);
        float playerY = F32(player + 0xD0);

        ulong managerClass = U64(gameAssemblyBase + 0x16A37B8);
        ulong managerStatic = U64(managerClass + 0xB8);
        ulong manager = U64(managerStatic);
        ulong dictionary = U64(manager + 0x10);
        ulong entries = U64(dictionary + 0x18);
        int capacity = I32(entries + 0x18);

        bool found = false;
        double nearest = Double.MaxValue;
        float targetX = 0, targetY = 0, targetZ = 0;
        for (int index = 0; index < Math.Min(Math.Max(capacity, 0), 4096); index++)
        {
            ulong entry = entries + 0x20UL + (ulong)index * 0x18UL;
            if (I32(entry) < 0) continue;
            ulong obj = U64(entry + 0x10);
            if (obj == 0) continue;
            ulong core = U64(obj + 0x58);
            string name = core == 0 ? "" : ManagedString(U64(core + 0x10));
            if (!name.StartsWith("act_gmk_ITEMSTATUE_GOLD", StringComparison.Ordinal)) continue;
            float x = F32(obj + 0xCC), y = F32(obj + 0xD0), z = F32(obj + 0xD4);
            double dx = x - playerX, dy = y - playerY;
            double distance = dx * dx + dy * dy;
            if (distance < nearest) { nearest = distance; targetX = x; targetY = y; targetZ = z; found = true; }
        }
        if (!found) throw new InvalidOperationException("No gold target was found");
        if (svObject == 0) throw new InvalidOperationException("The player's SVObject was null");

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

            return String.Format(CultureInfo.InvariantCulture,
                "Called SVObject.Teleport on 0x{0:X16} with ({1:F3},{2:F3},{3:F3})", svObject, targetX, targetY, targetZ);
        }
        finally { VirtualFreeEx(process, remote, UIntPtr.Zero, 0x8000); }
    }

    public void Dispose() { if (process != IntPtr.Zero) CloseHandle(process); }
}
'@

if (-not ('NativeActTeleportTester' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

$targetProcess = Get-Process -Id $ProcessId -ErrorAction Stop
$module = $targetProcess.Modules | Where-Object ModuleName -eq 'GameAssembly.dll' | Select-Object -First 1
if (-not $module) { throw 'GameAssembly.dll was not loaded.' }

$tester = [NativeActTeleportTester]::new($ProcessId)
try {
    $tester.Teleport([UInt64]$module.BaseAddress.ToInt64())
}
finally {
    $tester.Dispose()
}
