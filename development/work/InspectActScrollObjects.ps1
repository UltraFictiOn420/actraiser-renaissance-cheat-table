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

public sealed class ActScrollInspector : IDisposable
{
    private readonly IntPtr process;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer, UIntPtr size, out UIntPtr bytesRead);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public ActScrollInspector(int processId)
    {
        process = OpenProcess(0x0010 | 0x0400, false, processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess failed");
    }

    private bool TryRead(ulong address, int length, out byte[] value)
    {
        value = new byte[length];
        UIntPtr read;
        return ReadProcessMemory(process, new IntPtr((long)address), value, (UIntPtr)(uint)length, out read) &&
               read.ToUInt64() == (ulong)length;
    }

    private ulong U64(ulong address)
    {
        byte[] bytes;
        return TryRead(address, 8, out bytes) ? BitConverter.ToUInt64(bytes, 0) : 0;
    }

    private int I32(ulong address)
    {
        byte[] bytes;
        return TryRead(address, 4, out bytes) ? BitConverter.ToInt32(bytes, 0) : 0;
    }

    private float F32(ulong address)
    {
        byte[] bytes;
        return TryRead(address, 4, out bytes) ? BitConverter.ToSingle(bytes, 0) : Single.NaN;
    }

    private byte U8(ulong address)
    {
        byte[] bytes;
        return TryRead(address, 1, out bytes) ? bytes[0] : (byte)0;
    }

    private string ManagedString(ulong address)
    {
        if (address == 0) return "";
        int length = I32(address + 0x10);
        if (length <= 0 || length > 512) return "";
        byte[] bytes;
        if (!TryRead(address + 0x14, length * 2, out bytes)) return "";
        return Encoding.Unicode.GetString(bytes);
    }

    public string[] Inspect(ulong gameAssemblyBase)
    {
        var output = new List<string>();

        ulong sceneClass = U64(gameAssemblyBase + 0x16A3788);
        ulong sceneStatic = U64(sceneClass + 0xB8);
        ulong scene = U64(sceneStatic + 0x50);
        ulong player = U64(scene + 0xC0);
        float playerX = F32(player + 0xCC);
        float playerY = F32(player + 0xD0);
        float playerZ = F32(player + 0xD4);
        output.Add(String.Format(CultureInfo.InvariantCulture,
            "PLAYER object=0x{0:X16} pos=({1:F3},{2:F3},{3:F3})", player, playerX, playerY, playerZ));

        ulong managerClass = U64(gameAssemblyBase + 0x16A37B8);
        ulong managerStatic = U64(managerClass + 0xB8);
        ulong manager = U64(managerStatic);
        ulong dictionary = U64(manager + 0x10);
        ulong entries = U64(dictionary + 0x18);
        int length = I32(entries + 0x18);
        output.Add(String.Format(CultureInfo.InvariantCulture,
            "REGISTRY manager=0x{0:X16} dictionary=0x{1:X16} entries=0x{2:X16} capacity={3}",
            manager, dictionary, entries, length));

        var marked = new List<Tuple<double, string>>();
        var nearby = new List<Tuple<double, string>>();
        int limit = Math.Min(Math.Max(length, 0), 4096);
        for (int index = 0; index < limit; index++)
        {
            ulong entry = entries + 0x20UL + (ulong)index * 0x18UL;
            int hash = I32(entry);
            ulong key = U64(entry + 0x08);
            ulong obj = U64(entry + 0x10);
            if (hash < 0 || obj == 0) continue;

            float x = F32(obj + 0xCC);
            float y = F32(obj + 0xD0);
            float z = F32(obj + 0xD4);
            if (Single.IsNaN(x) || Single.IsNaN(y) || Single.IsNaN(z)) continue;
            double dx = x - playerX;
            double dy = y - playerY;
            double distance = Math.Sqrt(dx * dx + dy * dy);
            string keyText = ManagedString(key);
            string uidText = ManagedString(U64(obj + 0x80));
            ulong objectCore = U64(obj + 0x58);
            string coreName = ManagedString(U64(objectCore + 0x10));
            ulong objectSetting = U64(objectCore + 0x18);
            string animationName = ManagedString(U64(objectSetting + 0x10));
            string groupName = ManagedString(U64(objectSetting + 0x18));
            ulong nowAction = U64(obj + 0x68);
            string actionName = ManagedString(U64(nowAction + 0x10));
            string motionName = ManagedString(U64(nowAction + 0x20));
            ulong marker = U64(obj + 0x150);
            string basic = String.Format(CultureInfo.InvariantCulture,
                "dist={0:F3} idx={1} object=0x{2:X16} pos=({3:F3},{4:F3},{5:F3}) key='{6}' uid='{7}' core='{8}' group='{9}' animation='{10}' action='{11}' motion='{12}' marker=0x{13:X16}",
                distance, index, obj, x, y, z, keyText, uidText, coreName, groupName, animationName, actionName, motionName, marker);

            if (distance <= 64.0)
                nearby.Add(Tuple.Create(distance, basic));

            if (marker != 0)
            {
                int flagId = I32(marker + 0x18);
                byte useFalse = U8(marker + 0x1C);
                int falseItem = I32(marker + 0x20);
                byte useTrue = U8(marker + 0x24);
                int trueItem = I32(marker + 0x28);
                int specialItem = I32(marker + 0x2C);
                string detail = basic + String.Format(CultureInfo.InvariantCulture,
                    " flagId={0} useFalse={1} falseItem={2} useTrue={3} trueItem={4} specialItem={5}",
                    flagId, useFalse, falseItem, useTrue, trueItem, specialItem);
                marked.Add(Tuple.Create(distance, detail));
            }
        }

        marked.Sort((a, b) => a.Item1.CompareTo(b.Item1));
        nearby.Sort((a, b) => a.Item1.CompareTo(b.Item1));
        output.Add("MARKED OBJECTS:");
        foreach (var item in marked) output.Add(item.Item2);
        output.Add("NEARBY OBJECTS (within 64 units):");
        foreach (var item in nearby) output.Add(item.Item2);
        return output.ToArray();
    }

    public void Dispose()
    {
        if (process != IntPtr.Zero) CloseHandle(process);
    }
}
'@

if (-not ('ActScrollInspector' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

$targetProcess = Get-Process -Id $ProcessId -ErrorAction Stop
$module = $targetProcess.Modules | Where-Object ModuleName -eq 'GameAssembly.dll' | Select-Object -First 1
if (-not $module) {
    throw 'GameAssembly.dll was not loaded in the target process.'
}

$inspector = [ActScrollInspector]::new($ProcessId)
try {
    $inspector.Inspect([UInt64]$module.BaseAddress.ToInt64())
}
finally {
    $inspector.Dispose()
}
