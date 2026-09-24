# Flashing

**These images replace your kernel. Get it wrong and the phone will not boot.** Read the whole
page before you start. Everything here touches **only** the `boot` partition.

## Before you begin

| requirement | how to check |
|---|---|
| Bootloader unlocked | `fastboot getvar securestate` → `flashing_unlocked` |
| Root or fastboot | the `dd` route needs a root shell; the fastboot route needs neither |
| **A backup of your current `boot` partition** | see below, do this first |

Confirm you have the right device. Everything here is for **`saipan` / XT2149-1** only:

```sh
adb shell getprop ro.product.device      # saipan
adb shell getprop ro.product.model       # moto g(50) 5G
adb shell getprop ro.boot.hardware.sku   # XT2149-1
```

Do **not** flash these on any other Motorola MTK device. The codename is what matters, not the
marketing name - Motorola reuses "moto g" across several unrelated SoCs.

> **Never relock the bootloader.** On a Motorola MTK device, relocking programs an efuse. It
> does not simply restore the stock state; it can leave you with a phone that will not flash
> anything, including official firmware. There is no way back from that with the tools in this
> repository.

## Step 0: back up your current boot partition

From a root shell on the device:

```sh
su -c 'dd if=/dev/block/by-name/boot of=/sdcard/boot-backup.img'
adb pull /sdcard/boot-backup.img
```

Or, without root, read it out of your own firmware package. Either way, pull it somewhere safe.
This file is your undo button for everything below.

The partition is 41,943,040 bytes (40 MiB). Both published images are smaller than that, which
is expected - the partition is zero-padded past the end of the image.

## Route A: `fastboot flash boot`

This is the route I used. It needs no root on the device.

```sh
adb reboot bootloader
fastboot getvar current-slot          # note it; this device uses boot_a
fastboot flash boot boot-saipan-ksu-level.img
fastboot reboot
```

Do **not** pass `--set-active`. Slot B is blank on this unit and switching to it is how you
get a phone that boots nothing.

## Route B: `dd` from a root shell

```sh
adb push boot-saipan-ksu-level.img /data/local/tmp/new-boot.img
adb shell
su
# verify the push actually completed before writing anything
md5sum /data/local/tmp/new-boot.img        # compare with the published md5

dd if=/data/local/tmp/new-boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync
sync
```

Note the KernelSU quirk if you script this: **inline `su -c "a; b; c"` does not preserve shell
state on this device.** A `cd` or a variable assignment in one part of the chain does not
survive into the next, and the failure looks exactly like a permissions problem because the
write lands at `/`, which really is read-only. Put multi-step logic in a script file and run
`su -c "sh /path/script.sh"`, or keep every command self-contained with absolute paths.

## Verifying the write landed

Whatever route you used, read the partition back and compare:

```sh
su -c 'dd if=/dev/block/by-name/boot of=/data/local/tmp/readback.img bs=1024 count=27882'
su -c 'md5sum /data/local/tmp/readback.img'
```

`count=27882` is 28,551,168 / 1024, the size of `boot-saipan-ksu-level.img`. Use the matching
count for the image you flashed. Only reboot once the hash matches - if it does not, re-flash
your Step 0 backup immediately.

`build/flash-boot.ps1` does the whole sequence and then waits for `sys.boot_completed`:

```
.\flash-boot.ps1 -Image ..\releases\boot-saipan-ksu-level.img
.\flash-boot.ps1 -Image .\stock-boot.img -Restore      # back to stock
```

## After flashing

* First boot takes noticeably longer than usual. Give it a few minutes.
* Open the KernelSU-Next manager and confirm the home screen reports the kernel rather than
  *"Unsupported | Not integrated"*. Nothing is granted root by default - you choose.
* On mine, `su` only appeared after launching the manager once **and rebooting**. If
  `/system/bin/su` is missing right after the flash, that is why.

## If something goes wrong

| symptom | what to do |
|---|---|
| Boot loop | reflash your Step 0 backup |
| Black screen, no fastboot | `blankflash_saipan.zip` and a MediaTek BROM session - the last resort, and the reason to keep that file |
| Wi-Fi, Bluetooth, touch, fingerprint or GPS dead | the vendor modules were rejected. This means the image does not match your source revision or your config lost LTO/CFI. Restore your backup and read [docs/KERNEL-NOTES.md](docs/KERNEL-NOTES.md) §2-3. |
| Wi-Fi dead but everything else fine | check `dmesg` for `disagrees about version of symbol`. Same cause. |

## Safety notes

* **`dtbo` is never touched by anything in this repository.** If you follow advice elsewhere
  that patches GPU power levels, that means flashing `dtbo`, a different and riskier procedure
  that I do not use.
* Keep your Step 0 backup until you are sure you are happy. Keep the blankflash too.
* A custom kernel and an unlocked bootloader can affect warranty, banking apps and anything
  else that checks device integrity. That is true of any custom kernel on this device and is
  not specific to these images.
