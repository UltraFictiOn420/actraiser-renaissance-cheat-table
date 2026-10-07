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
if (-not ('Iced.Intel.Decoder' -as [type])) {
    Add-Type -Path $icedPath
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

$decoder = [Iced.Intel.Decoder]::Create(
    64,
    $bytes,
    $VirtualAddress,
    [Iced.Intel.DecoderOptions]::None)
$formatter = [Iced.Intel.IntelFormatter]::new()
$formatter.Options.DigitSeparator = '`'
$formatter.Options.FirstOperandCharIndex = 10
$endAddress = $VirtualAddress + [UInt64]$bytes.Length

while ($decoder.IP -lt $endAddress) {
    $start = $decoder.IP
    $instruction = $decoder.Decode()
    $output = [Iced.Intel.StringOutput]::new()
    $formatter.Format([ref]$instruction, $output)
    '{0:X16}  {1}' -f $start,$output.ToString()
    if ($instruction.Code -eq [Iced.Intel.Code]::INVALID) {
        break
    }
}
