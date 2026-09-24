# Android boot image (header v0..v2) unpack/repack for the Motorola saipan device.
# Pure PowerShell, no external tools. Handles the 2048-byte page size and the
# appended-DTB layout that MTK boot images use.
#
# Usage:
#   .\bootimg.ps1 -Action unpack -BootImg <in.img> -OutDir <dir>
#   .\bootimg.ps1 -Action pack   -OutImg <out.img> -InDir <dir> [-Kernel <path>]
#
param(
  [Parameter(Mandatory=$true)][ValidateSet('unpack','pack','info')][string]$Action,
  [string]$BootImg,
  [string]$OutImg,
  [string]$OutDir,
  [string]$InDir,
  [string]$Kernel,
  [string]$Cmdline
)

$ErrorActionPreference = 'Stop'

# .NET file APIs use the PROCESS working directory, which Set-Location does not change.
# Resolve every incoming path against PowerShell's current location so relative paths work.
function Abs([string]$p) {
  if ([string]::IsNullOrEmpty($p)) { return $p }
  if ([IO.Path]::IsPathRooted($p)) { return [IO.Path]::GetFullPath($p) }
  return [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $p))
}
$BootImg = Abs $BootImg
$OutImg  = Abs $OutImg
$OutDir  = Abs $OutDir
$InDir   = Abs $InDir
$Kernel  = Abs $Kernel

function Read-BootHeader([string]$path) {
  $fs = [IO.File]::OpenRead($path)
  try {
    $hdr = New-Object byte[] 2048
    $n = $fs.Read($hdr, 0, 2048)
    if ($n -lt 2048) { throw "short read" }
  } finally { $fs.Close() }
  $magic = [Text.Encoding]::ASCII.GetString($hdr[0..7])
  if ($magic -ne 'ANDROID!') { throw "$path is not an Android boot image (magic='$magic')" }
  $u32 = { param($o) [BitConverter]::ToUInt32($hdr, $o) }
  $u64 = { param($o) [BitConverter]::ToUInt64($hdr, $o) }
  $h = [ordered]@{
    Magic          = $magic
    KernelSize     = & $u32 8
    KernelAddr     = & $u32 12
    RamdiskSize    = & $u32 16
    RamdiskAddr    = & $u32 20
    SecondSize     = & $u32 24
    SecondAddr     = & $u32 28
    TagsAddr       = & $u32 32
    PageSize       = & $u32 36
    HeaderVersion  = & $u32 40
    OsVersion      = & $u32 44
    Name           = [Text.Encoding]::ASCII.GetString($hdr[48..63]).Trim([char]0)
    Cmdline        = ([Text.Encoding]::ASCII.GetString($hdr[64..575])  -split "`0")[0]
    Id             = $hdr[576..607]
    ExtraCmdline   = ([Text.Encoding]::ASCII.GetString($hdr[608..1631]) -split "`0")[0]
    RecoveryDtboSize = & $u32 1632
    RecoveryDtboOff  = & $u64 1636
    HeaderSize       = & $u32 1644
    DtbSize          = & $u32 1648
    DtbAddr          = & $u64 1652
    HeaderBytes      = $hdr
  }
  return $h
}

function Get-Layout($h) {
  $p = [int]$h.PageSize
  $kp = [int][Math]::Ceiling($h.KernelSize  / $p)
  $rp = [int][Math]::Ceiling($h.RamdiskSize / $p)
  $sp = [int][Math]::Ceiling($h.SecondSize  / $p)
  $dp = [int][Math]::Ceiling($h.DtbSize     / $p)
  $kernelOff  = $p
  $ramdiskOff = $kernelOff  + $kp * $p
  $secondOff  = $ramdiskOff + $rp * $p
  $dtbOff     = $secondOff  + $sp * $p
  $end        = $dtbOff     + $dp * $p
  return [ordered]@{
    PageSize=$p; KernelOff=$kernelOff; RamdiskOff=$ramdiskOff; SecondOff=$secondOff; DtbOff=$dtbOff
    KernelPages=$kp; RamdiskPages=$rp; SecondPages=$sp; DtbPages=$dp; End=$end
  }
}

function Copy-Range([string]$src, [long]$offset, [long]$count, [string]$dest) {
  $fs = [IO.File]::OpenRead($src)
  try {
    $fs.Position = $offset
    $out = [IO.File]::Create($dest)
    try {
      $buf = New-Object byte[] (1MB)
      $left = $count
      while ($left -gt 0) {
        $want = [Math]::Min($buf.Length, $left)
        $got = $fs.Read($buf, 0, $want)
        if ($got -le 0) { throw "unexpected EOF copying $count bytes at $offset" }
        $out.Write($buf, 0, $got)
        $left -= $got
      }
    } finally { $out.Close() }
  } finally { $fs.Close() }
}

function Describe-Blob([string]$path, [string]$label) {
  if (-not (Test-Path $path)) { return }
  $fs = [IO.File]::OpenRead($path)
  $b = New-Object byte[] 8
  $null = $fs.Read($b,0,8); $fs.Close()
  $hex = ($b | ForEach-Object { $_.ToString('x2') }) -join ' '
  $kind = 'unknown'
  if ($b[0] -eq 0x1f -and $b[1] -eq 0x8b) { $kind = 'gzip' }
  elseif ($b[0] -eq 0x04 -and $b[1] -eq 0x22 -and $b[2] -eq 0x4d -and $b[3] -eq 0x18) { $kind = 'lz4' }
  elseif ($b[0] -eq 0x28 -and $b[1] -eq 0xb5 -and $b[2] -eq 0x2f -and $b[3] -eq 0xfd) { $kind = 'zstd' }
  elseif ($b[0] -eq 0xfd -and $b[1] -eq 0x37 -and $b[2] -eq 0x7a -and $b[3] -eq 0x58) { $kind = 'xz' }
  elseif ($b[0] -eq 0x5d -and $b[1] -eq 0x00) { $kind = 'lzma' }
  elseif ($b[0] -eq 0x41 -and $b[1] -eq 0x4e -and $b[2] -eq 0x44 -and $b[3] -eq 0x52) { $kind = 'ANDROID-vendor-ramdisk' }
  elseif ($b[0] -eq 0xd0 -and $b[1] -eq 0x0d -and $b[2] -eq 0xfe -and $b[3] -eq 0xed) { $kind = 'dtb (FDT)' }
  $sz = (Get-Item $path).Length
  "{0,-10} {1,12:N0} bytes  magic=[{2}]  -> {3}" -f $label, $sz, $hex, $kind
}

switch ($Action) {

  'info' {
    $h = Read-BootHeader $BootImg
    $h.GetEnumerator() | Where-Object { $_.Key -ne 'HeaderBytes' -and $_.Key -ne 'Id' } | ForEach-Object {
      "{0,-18} {1}" -f $_.Key, $_.Value
    }
    $l = Get-Layout $h
    "---"
    $l.GetEnumerator() | ForEach-Object { "{0,-14} {1}" -f $_.Key, $_.Value }
  }

  'unpack' {
    if (-not $OutDir) { throw "-OutDir required for unpack" }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $h = Read-BootHeader $BootImg
    $l = Get-Layout $h
    Copy-Range $BootImg $l.KernelOff  $h.KernelSize  (Join-Path $OutDir 'kernel')
    Copy-Range $BootImg $l.RamdiskOff $h.RamdiskSize (Join-Path $OutDir 'ramdisk')
    if ($h.DtbSize -gt 0) { Copy-Range $BootImg $l.DtbOff $h.DtbSize (Join-Path $OutDir 'dtb') }
    if ($h.SecondSize -gt 0) { Copy-Range $BootImg $l.SecondOff $h.SecondSize (Join-Path $OutDir 'second') }
    # store the original header verbatim so repack can reuse every field
    [IO.File]::WriteAllBytes((Join-Path $OutDir 'header.bin'), $h.HeaderBytes)
    $h | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $OutDir 'header.json')
    "unpacked $BootImg -> $OutDir"
    Describe-Blob (Join-Path $OutDir 'kernel')  'kernel'
    Describe-Blob (Join-Path $OutDir 'ramdisk') 'ramdisk'
    Describe-Blob (Join-Path $OutDir 'dtb')     'dtb'
    if ($h.SecondSize -gt 0) { Describe-Blob (Join-Path $OutDir 'second') 'second' }
  }

  'pack' {
    if (-not $OutImg) { throw "-OutImg required for pack" }
    if (-not $InDir)  { throw "-InDir required for pack" }
    $h = Read-BootHeader (Join-Path $InDir 'header.bin')
    $l = Get-Layout $h
    $kPath = if ($Kernel) { $Kernel } else { Join-Path $InDir 'kernel' }
    if (-not (Test-Path $kPath)) { throw "kernel not found: $kPath" }
    $rPath = Join-Path $InDir 'ramdisk'
    $dPath = Join-Path $InDir 'dtb'

    $kBytes = [IO.File]::ReadAllBytes($kPath)
    $rBytes = [IO.File]::ReadAllBytes($rPath)
    $dBytes = if (Test-Path $dPath) { [IO.File]::ReadAllBytes($dPath) } else { @() }

    $p = [int]$h.PageSize
    $hdr = $h.HeaderBytes.Clone()
    [BitConverter]::GetBytes([uint32]$kBytes.Length).CopyTo($hdr, 8)
    [BitConverter]::GetBytes([uint32]$rBytes.Length).CopyTo($hdr, 16)
    [BitConverter]::GetBytes([uint32]$dBytes.Length).CopyTo($hdr, 1648)

    # boot header cmdline lives at offset 64, 512 bytes, NUL padded.
    # Verified on-device that this reaches the kernel: /proc/cmdline contains
    # "bootopt=64S3,32N2,64N2 buildvariant=user", which is the stock cmdline here.
    if ($Cmdline) {
      New-Object byte[] 512 | ForEach-Object { $_ } | Out-Null
      $cb = New-Object byte[] 512
      $bytes = [Text.Encoding]::ASCII.GetBytes($Cmdline)
      [Array]::Copy($bytes, 0, $cb, 0, [Math]::Min($bytes.Length, 511))
      [Array]::Copy($cb, 0, $hdr, 64, 512)
      Write-Host ("  cmdline  : {0}" -f $Cmdline)
    }

    function PadTo($stream, $page) {
      $rem = $stream.Length % $page
      if ($rem -ne 0) {
        $pad = New-Object byte[] ($page - $rem)
        $stream.Write($pad, 0, $pad.Length)
      }
    }

    $out = [IO.File]::Create($OutImg)
    try {
      $out.Write($hdr, 0, $p)          # header occupies exactly one page
      $out.Write($kBytes, 0, $kBytes.Length); PadTo $out $p
      $out.Write($rBytes, 0, $rBytes.Length); PadTo $out $p
      if ($dBytes.Length -gt 0) { $out.Write($dBytes, 0, $dBytes.Length); PadTo $out $p }
    } finally { $out.Close() }

    $total = (Get-Item $OutImg).Length
    "packed -> $OutImg"
    "  kernel  $($kBytes.Length) bytes"
    "  ramdisk $($rBytes.Length) bytes"
    "  dtb     $($dBytes.Length) bytes"
    "  total   $total bytes"
    if ($total -gt 41943040) { "  !! WARNING: exceeds the 41,943,040-byte boot partition by $($total - 41943040) bytes" }
    else { "  fits in 41,943,040 (slack $((41943040 - $total)))" }
    # header sanity
    (Read-BootHeader $OutImg).GetEnumerator() | Where-Object { $_.Key -in @('KernelSize','RamdiskSize','DtbSize','PageSize','HeaderVersion') } | ForEach-Object { "  verify $($_.Key)=$($_.Value)" }
  }
}
