# Releases

Two boot images. Both reuse the stock Motorola ramdisk unmodified, and both are smaller than
the 41,943,040-byte (40 MiB) `boot` partition.

| # | file | size | md5 | hardware verified |
|---|---|---|---|---|
| 1 | `boot-saipan-ksu.img` | 28,549,120 | `6698b76d58dacb34669bfe29cd2646d4` | yes, flashed and validated |
| 2 | `boot-saipan-ksu-level.img` | 28,551,168 | `7c852300024f14f5b73e2f2fa8b23fda` | yes, flashed and validated - what runs on my handset |

## Which one do I want?

**Download `boot-saipan-ksu-level.img`.** Image 2 is a strict superset of image 1: it adds the
`mtk_cpufreq.level=` cmdline override, and with no such parameter on the cmdline it behaves
identically to image 1. Image 1 is published because it is the build that was flashed and
validated first, and keeping it makes the history honest.

## What was checked on both

```
size                  < 41,943,040 bytes
vermagic              == 4.14.186+ SMP preempt mod_unload modversions aarch64
LTO / CFI             == CONFIG_LTO_CLANG=y, CONFIG_CFI_CLANG=y, CONFIG_THINLTO=y
vendor modules        == 17 of 17 load; Wi-Fi, Bluetooth, touch, fingerprint, GPS, FM, sensors
SELinux               == Enforcing
root                  == KernelSU-Next, su -c id -> uid=0 context=u:r:ksu:s0
Docker in Droidspaces == Engine 29.8.1, overlay2, cgroup v1, hello-world rc=0
```

The `RamdiskSize` field is 14,368,137 bytes in both images and in the stock image, which is how
you can tell the ramdisk is untouched.

## Verifying before you flash

Check the md5 after downloading, and again after pushing to the device:

```sh
md5sum boot-saipan-ksu-level.img       # must match the table above
adb push boot-saipan-ksu-level.img /data/local/tmp/new-boot.img
adb shell su -c 'md5sum /data/local/tmp/new-boot.img'
```

A truncated push is the most common cause of a bad flash. Only write to the partition once both
hashes match.

## Rolling back

Flash your own `boot` backup, or the stock `boot.img` from your firmware for your build number.
See [../FLASHING.md](../FLASHING.md). Nothing in this project touches `dtbo`, `vbmeta`,
`vendor_boot` or `super`.

If fastboot is gone entirely, the last resort is a MediaTek BROM session with a blankflash
package for this device. Keep one on disk before you need it - you cannot download it after the
phone stops booting.
