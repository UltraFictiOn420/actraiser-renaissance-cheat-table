param(
    [Parameter(Mandatory = $true)]
    [string]$ImagePath,
    [Parameter(Mandatory = $true)]
    [UInt64]$RelativeAddress
)

$source = @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class WindowsSymbolResolver
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    private struct SYMBOL_INFO
    {
        public UInt32 SizeOfStruct;
        public UInt32 TypeIndex;
        public UInt64 Reserved1;
        public UInt64 Reserved2;
        public UInt32 Index;
        public UInt32 Size;
        public UInt64 ModBase;
        public UInt32 Flags;
        public UInt64 Value;
        public UInt64 Address;
        public UInt32 Register;
        public UInt32 Scope;
        public UInt32 Tag;
        public UInt32 NameLen;
        public UInt32 MaxNameLen;
    }

    [DllImport("dbghelp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool SymInitialize(IntPtr process, string searchPath, bool invadeProcess);
    [DllImport("dbghelp.dll", SetLastError = true)]
    private static extern bool SymCleanup(IntPtr process);
    [DllImport("dbghelp.dll", SetLastError = true)]
    private static extern uint SymSetOptions(uint options);
    [DllImport("dbghelp.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern ulong SymLoadModuleEx(IntPtr process, IntPtr file, string imageName, string moduleName, ulong baseOfDll, uint dllSize, IntPtr data, uint flags);
    [DllImport("dbghelp.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    private static extern bool SymFromAddr(IntPtr process, ulong address, out ulong displacement, IntPtr symbol);

    public static string Resolve(string imagePath, ulong relativeAddress, string cachePath)
    {
        IntPtr process = Process.GetCurrentProcess().Handle;
        SymSetOptions(0x00000004 | 0x00000002 | 0x00000010 | 0x00000040);
        string search = "srv*" + cachePath + "*https://msdl.microsoft.com/download/symbols";
        if (!SymInitialize(process, search, false))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SymInitialize failed");
        try
        {
            ulong moduleBase = SymLoadModuleEx(process, IntPtr.Zero, imagePath, null, 0, 0, IntPtr.Zero, 0);
            if (moduleBase == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SymLoadModuleEx failed");

            int headerSize = Marshal.SizeOf(typeof(SYMBOL_INFO));
            IntPtr buffer = Marshal.AllocHGlobal(headerSize + 2048);
            try
            {
                for (int i = 0; i < headerSize + 2048; i++) Marshal.WriteByte(buffer, i, 0);
                SYMBOL_INFO info = new SYMBOL_INFO();
                info.SizeOfStruct = (uint)headerSize;
                info.MaxNameLen = 2048;
                Marshal.StructureToPtr(info, buffer, false);
                ulong displacement;
                if (!SymFromAddr(process, moduleBase + relativeAddress, out displacement, buffer))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "SymFromAddr failed");
                info = (SYMBOL_INFO)Marshal.PtrToStructure(buffer, typeof(SYMBOL_INFO));
                IntPtr nameAddress = IntPtr.Add(buffer, headerSize);
                string name = Marshal.PtrToStringAnsi(nameAddress, (int)info.NameLen);
                return String.Format("{0}+0x{1:X} (module base 0x{2:X}, symbol address 0x{3:X})", name, displacement, moduleBase, info.Address);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        finally { SymCleanup(process); }
    }
}
'@

if (-not ('WindowsSymbolResolver' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

$cache = Join-Path $PSScriptRoot 'symbols'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
[WindowsSymbolResolver]::Resolve($ImagePath, $RelativeAddress, $cache)
