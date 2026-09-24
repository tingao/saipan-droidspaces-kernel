# NOTICE: third-party components and the proprietary boundary

## What this repository contains

* Build scripts, patches, kernel config and documentation I wrote for this project, **GPLv2**
  (see [LICENSE](LICENSE)).
* Two prebuilt kernel boot images, built from those sources and from Motorola's published GPL
  kernel source.

## What this repository does NOT contain

| component | why |
|---|---|
| Motorola's kernel source tree | get it yourself, see [SOURCE.md](SOURCE.md) |
| Stock vendor kernel modules (`/vendor/lib/modules/*.ko`) | proprietary. Also unnecessary - the CRC patch exists so the modules already on your phone keep working |
| Firmware blobs (`/vendor/firmware*`) | proprietary |
| Motorola's userspace of any kind | proprietary |
| AOSP toolchain binaries | large; get them from AOSP or your distro |

**No vendor module, firmware blob or Motorola application is redistributed here.**

## The ramdisk caveat

Each published `boot-saipan-*.img` is `kernel + ramdisk`. The kernel is GPLv2 code I built.
The **ramdisk is Motorola's stock ramdisk**, taken unmodified from the device's original `boot`
partition, and it is proprietary. It is included so the images are ready to flash.

* For **personal use** this is no different from flashing a Motorola update.
* For **redistribution**, I cannot grant you rights to Motorola's ramdisk. If that matters to
  you, build the image from your own stock firmware with `build/pack-boot.ps1`, which produces
  an equivalent result without moving anything proprietary between machines. See
  [SOURCE.md](SOURCE.md), *The ramdisk problem*.

## Third-party projects

| project | used for | licence |
|---|---|---|
| [Linux kernel](https://kernel.org) | the kernel itself | GPLv2 |
| [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) | root solution, **legacy** branch | GPLv2 |
| [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) | the container runtime this kernel is tuned and tested for | see project |
| AOSP `clang-r383902` + `aarch64-linux-android-4.9` binutils | toolchain | Apache-2.0 with LLVM exceptions / GPL |

KernelSU-Next and Droidspaces are **not bundled**. `build/README.md` says which revision of
KernelSU-Next this was built against; Droidspaces is installed on the device, separately.

## Trademarks

"Motorola", "moto g" and "MediaTek" / "Dimensity" are trademarks of their respective owners.
"Android" is a trademark of Google LLC. This is an independent community project and is not
affiliated with, endorsed by, or supported by Motorola Mobility, Lenovo or MediaTek.

## No warranty

These images modify your device's kernel. They are provided as-is, with no warranty of any
kind. You are responsible for backing up your device, and for understanding that an unlocked
bootloader on a Motorola MTK handset cannot be safely relocked. See the licence for the full
disclaimer.
