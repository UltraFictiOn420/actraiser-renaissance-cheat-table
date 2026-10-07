param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [UInt64]$FileOffset,

    [Parameter(Mandatory = $true)]
    [UInt64]$VirtualAddress,

    [int]$ByteCount = 256
)

$icedPath = Join-Path $PSScriptRoot 'tools\iced\lib\netstandard2.0\Iced.dll'
if (-not (Test-Path $icedPath)) {
    throw "Iced.dll was not found at $icedPath"
}

if (-not ('CodexDisassembler' -as [type])) {
    Add-Type -Path $icedPath
    $source = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using Iced.Intel;

public static class CodexDisassembler
{
    private sealed class TextOutput : FormatterOutput
    {
        private readonly StringBuilder builder = new StringBuilder();
        public override void Write(string text, FormatterTextKind kind) { builder.Append(text); }
        public override string ToString() { return builder.ToString(); }
    }

    public static string[] Decode(byte[] bytes, ulong ip)
    {
        var reader = new ByteArrayCodeReader(bytes);
        var decoder = Iced.Intel.Decoder.Create(64, reader);
        decoder.IP = ip;
        var formatter = new IntelFormatter();
        formatter.Options.DigitSeparator = "`";
        formatter.Options.FirstOperandCharIndex = 10;
        var lines = new List<string>();

        while (reader.Position < bytes.Length)
        {
            ulong start = decoder.IP;
            decoder.Decode(out var instruction);
            var output = new TextOutput();
            formatter.Format(instruction, output);
            lines.Add(String.Format(CultureInfo.InvariantCulture, "{0:X16}  {1}", start, output.ToString()));
            if (instruction.Code == Code.INVALID)
                break;
        }
        return lines.ToArray();
    }
}
'@
    $frameworkReferences = ([string][AppContext]::GetData('TRUSTED_PLATFORM_ASSEMBLIES')).Split([IO.Path]::PathSeparator)
    Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies ($frameworkReferences + $icedPath)
}

$stream = [IO.File]::OpenRead($FilePath)
try {
    $null = $stream.Seek([Int64]$FileOffset, [IO.SeekOrigin]::Begin)
    $bytes = New-Object byte[] $ByteCount
    $read = $stream.Read($bytes, 0, $bytes.Length)
    if ($read -lt $bytes.Length) {
        $trimmed = New-Object byte[] $read
        [Array]::Copy($bytes, $trimmed, $read)
        $bytes = $trimmed
    }
}
finally {
    $stream.Dispose()
}

[CodexDisassembler]::Decode($bytes, $VirtualAddress)
