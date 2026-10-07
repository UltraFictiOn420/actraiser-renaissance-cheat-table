param(
    [Parameter(Mandatory = $true)]
    [int]$OwnerProcessId,

    [Parameter(Mandatory = $true)]
    [int]$TargetProcessId
)

$source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class ProcessHandleInspector
{
    [DllImport("ntdll.dll")]
    private static extern int NtQuerySystemInformation(int infoClass, IntPtr info, int length, out int returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr sourceHandle, IntPtr targetProcess,
        out IntPtr targetHandle, uint desiredAccess, bool inheritHandle, uint options);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern uint GetProcessId(IntPtr process);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static bool HasProcessHandle(int ownerProcessId, int targetProcessId)
    {
        IntPtr owner = OpenProcess(0x0040, false, ownerProcessId); // PROCESS_DUP_HANDLE
        if (owner == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the handle-owning process");

        IntPtr buffer = IntPtr.Zero;
        try
        {
            int size = 0x10000;
            int needed;
            int status;
            do
            {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                buffer = Marshal.AllocHGlobal(size);
                status = NtQuerySystemInformation(64, buffer, size, out needed); // SystemExtendedHandleInformation
                if (status == unchecked((int)0xC0000004)) size = Math.Max(size * 2, needed + 0x1000);
            } while (status == unchecked((int)0xC0000004));

            if (status < 0) throw new InvalidOperationException("NtQuerySystemInformation failed: 0x" + status.ToString("X8"));

            long count = Marshal.ReadIntPtr(buffer).ToInt64();
            int headerSize = IntPtr.Size * 2;
            int entrySize = IntPtr.Size == 8 ? 40 : 28;
            IntPtr current = GetCurrentProcess();

            for (long i = 0; i < count; i++)
            {
                IntPtr entry = IntPtr.Add(buffer, headerSize + checked((int)(i * entrySize)));
                long pid = Marshal.ReadIntPtr(entry, IntPtr.Size).ToInt64();
                if (pid != ownerProcessId) continue;

                IntPtr sourceHandle = Marshal.ReadIntPtr(entry, IntPtr.Size * 2);
                IntPtr duplicate;
                if (!DuplicateHandle(owner, sourceHandle, current, out duplicate, 0, false, 0x2)) continue;
                try
                {
                    if (GetProcessId(duplicate) == (uint)targetProcessId) return true;
                }
                finally
                {
                    CloseHandle(duplicate);
                }
            }
            return false;
        }
        finally
        {
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            CloseHandle(owner);
        }
    }
}
'@

if (-not ('ProcessHandleInspector' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

[ProcessHandleInspector]::HasProcessHandle($OwnerProcessId, $TargetProcessId)
