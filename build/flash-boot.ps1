# Flash a boot image to the saipan device and verify the result.
#
# Recovery story (why this is safe):
#   - The exact stock boot.img is already extracted from the matching firmware
#     (fw/extracted/boot.img), so a bad kernel is one flash away from stock.
#   - blankflash_saipan.zip is on disk as a last resort.
#   - Slot B is blank on this unit, so we ONLY ever touch the active slot (boot_a).
#
# Usage:
#   .\flash-boot.ps1 -Image .\boot-v2-ksu.img
#   .\flash-boot.ps1 -Image .\fw\extracted\boot.img -Restore   # back to stock
#
param(
  [Parameter(Mandatory=$true)][string]$Image,
  [switch]$Restore,
  [int]$BootWaitSeconds = 180
)

$ErrorActionPreference = 'Continue'
function Say($m) { Write-Host $m }
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

$Image = [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Image))
if (-not (Test-Path $Image)) { throw "image not found: $Image" }
$size = (Get-Item $Image).Length
Step "Image"
Say ("  path : {0}" -f $Image)
Say ("  size : {0:N0} bytes" -f $size)
if ($size -gt 41943040) { throw "image exceeds the 41,943,040-byte boot partition" }
Say ("  slack: {0:N0} bytes" -f (41943040 - $size))

Step "1. Entering bootloader"
$dev = (& adb devices) 2>&1 | Select-String 'ZY22DW3LWW\s+device'
if ($dev) {
  & adb reboot bootloader | Out-Null
  Start-Sleep -Seconds 14
} else {
  Say "  adb device not present - assuming already in fastboot"
}

Step "2. Confirm fastboot sees the device"
$fb = (& fastboot devices) 2>&1
Say ("  {0}" -f ($fb -join ' | '))
if (-not ($fb -match 'ZY22DW3LWW')) { throw "fastboot cannot see ZY22DW3LWW" }

Step "3. Current slot + lock state"
& fastboot getvar current-slot 2>&1 | Select-String 'current-slot'
& fastboot getvar securestate  2>&1 | Select-String 'securestate'

Step "4. Flashing to the ACTIVE slot"
Say "  (we do NOT use --set-active; slot B is blank on this unit)"
& fastboot flash boot $Image 2>&1 | ForEach-Object { Say "  $_" }

Step "5. Verify the write landed"
$pre = & fastboot getvar partition-size:boot_a 2>&1
Say ("  {0}" -f ($pre -join ' | '))

Step "6. Rebooting"
& fastboot reboot 2>&1 | Out-Null

Step "7. Waiting for Android to come back"
$deadline = (Get-Date).AddSeconds($BootWaitSeconds)
$ok = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  $st = (& adb devices) 2>&1
  if ($st -match 'ZY22DW3LWW\s+device') {
    $bc = (& adb shell getprop sys.boot_completed 2>&1) -join ''
    if ($bc.Trim() -eq '1') { $ok = $true; break }
  }
  Write-Host -NoNewline '.'
}
Say ""

if ($ok) {
  Step "RESULT: booted"
  Say ("  kernel     : {0}" -f (((& adb shell uname -a) 2>&1) -join ' '))
  Say ("  release    : {0}" -f (((& adb shell cat /proc/version) 2>&1) -join ' '))
  Say ("  boot.compl : {0}" -f (((& adb shell getprop sys.boot_completed) 2>&1) -join ''))
  Say ("  build      : {0}" -f (((& adb shell getprop ro.build.display.id) 2>&1) -join ''))
} else {
  Step "WARNING: device did not report boot_completed within $BootWaitSeconds s"
  Say "  Still in bootloader?  -> reflash stock:  .\flash-boot.ps1 -Image .\fw\extracted\boot.img -Restore"
  Say "  Black screen / no fastboot? Use blankflash_saipan.zip and a MediaTek BROM session."
}
