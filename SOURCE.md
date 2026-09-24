# Where the source comes from, and what I redistribute

## Short version

This repository contains **changes to the kernel only**. The Linux kernel base is Motorola's
own published source, which you get from Motorola. I do not mirror it here.

```sh
# 1. get Motorola's source for this device
git clone https://github.com/MotorolaMobilityLLC/kernel-mtk
cd kernel-mtk
git checkout android-12-release-s1rs32.38-20-9

# 2. get KernelSU-Next and drop it in (see build/README.md)
git clone -b legacy https://github.com/KernelSU-Next/KernelSU-Next
cp -r KernelSU-Next/kernel drivers/kernelsu

# 3. build (the script applies this repo's patches itself)
KSRC=$PWD /path/to/repo/build/build-ksu-level.sh
```

---

## The licences in play

| component | licence | redistributable? |
|---|---|---|
| Linux kernel source | **GPLv2** | **yes**, with source + licence + notices |
| Motorola's additions to the kernel tree | **GPLv2** (they are in-tree) | yes, same terms |
| My patches, scripts, config, READMEs | **GPLv2** | yes |
| AOSP `clang` prebuilt toolchain | Apache-2.0 with LLVM exceptions | yes |
| **Stock vendor kernel modules** (`/vendor/lib/modules/*.ko`) | proprietary | **NO** |
| **Firmware blobs** (`/vendor/firmware*`) | proprietary | **NO** |
| **Motorola's ramdisk** (`init`, `init.rc`, … inside `boot.img`) | proprietary | **legally grey, see below** |
| The rest of `/vendor` and Motorola's userspace | proprietary | **NO** |

Nothing in the "NO" rows is included in this repository. **I never redistribute vendor modules
or firmware**, and you do not need them: the whole point of the CRC patch is that the modules
already on your phone keep working unchanged.

## Why I do not mirror Motorola's kernel tree

Not because GPLv2 forbids it - it does not. The reasons are practical:

1. **Size.** The tree is multiple gigabytes with history. A repository whose point is two
   flashable images does not need it.
2. **Licence hygiene.** Motorola's drop is not one licence. It carries in-tree code under
   other terms - dual BSD/GPL drivers, third-party and MediaTek vendor code, files with extra
   notices. Mirroring it means carrying and maintaining every one of those correctly.
3. **Freshness.** Motorola publishes drops for each build train. My patches are written
   against one specific revision, and pinning the base by reference keeps that unambiguous.
   The branch is one patch level away from the build my handset actually shipped, which is
   precisely the problem [docs/KERNEL-NOTES.md](docs/KERNEL-NOTES.md) §3 is about - pinning it
   matters here more than usual.
4. **It is trivially available.** Motorola publishes it publicly for exactly this purpose.

**If you do want a full-source fork**, fork their tree on the right branch and apply my
patches to it. That is a valid approach and keeps the GPL obligations simple. I took the other
route deliberately.

## GPLv2 compliance for the prebuilt images

This ships GPLv2 **binaries** (`boot-saipan-*.img`). GPLv2 requires that recipients can get
the corresponding source. That is met by publishing my complete delta as patches and scripts
in [`build/`](build/), and by documenting the exact base revision so the corresponding source
is reproducible.

If you redistribute these images, keep this repository (or an equivalent offer of the source)
reachable. That is what the licence asks for.

## Exact base

| | |
|---|---|
| Device | `saipan` / XT2149-1 (moto g(50) 5G, MediaTek MT6833 / Dimensity 700) |
| Motorola build the kernel was validated against | `S1RSS32.38-20-7-16` |
| Source repository | <https://github.com/MotorolaMobilityLLC/kernel-mtk> |
| Branch used | `android-12-release-s1rs32.38-20-9` |
| Kernel version string | `4.14.186+` |

Note the mismatch between the build number and the branch, because it is the crux of this
project: my device runs `…-20-7-16`, and `…-20-9` is the only published branch for that train.
Everything in [docs/KERNEL-NOTES.md](docs/KERNEL-NOTES.md) §3 follows from that one patch level.

Pick the branch matching your device's build number (Settings → About phone → Build number).
A nearby revision usually applies; a distant one may not, and if the vendor modules stop
loading that is the reason.

## Verifying you have the right base

The Python patchers refuse to write anything when their anchor is not found exactly once, so a
wrong base fails loudly rather than producing a subtly broken kernel. After a build, check:

```sh
# release string must be exactly this
grep -a -o -E "4.14.186\+ SMP preempt mod_unload modversions aarch64" out-level/vmlinux

# and these must all be =y in out/.config
grep -E '^CONFIG_(LTO_CLANG|CFI_CLANG|THINLTO|MODVERSIONS)=' out-level/.config
```

If the release string is wrong, or LTO/CFI are missing, **do not flash** - the vendor modules
will be rejected and you will lose Wi-Fi, Bluetooth, touch, fingerprint and GPS.

## The ramdisk problem

Read this if you plan to redistribute images.

A boot image is `kernel + ramdisk`. My kernel is GPLv2 code I built. The **ramdisk is
Motorola's** - the stock `init`, `init.rc` and friends, taken unmodified from the device's
original `boot` partition. You can see that in the sizes: the `RamdiskSize` field is
14,368,137 bytes in both the stock image and mine.

* **For personal use**, flashing an image here is no different from flashing a Motorola OTA.
* **For redistribution**, the ramdisk is proprietary Motorola userspace and I cannot grant you
  any rights to it. Most custom-kernel projects ignore this. I would rather you knew.

**Clean alternative: build the boot image from your own stock firmware.** Unpack your own
`boot.img` with `build/pack-boot.ps1`, swap in the `Image.gz` you built, and repack. Your
ramdisk, my kernel, nothing proprietary moving between machines:

```
.\pack-boot.ps1 -Action unpack -BootImg my-stock-boot.img -OutDir bootparts
.\pack-boot.ps1 -Action pack   -OutImg boot-mine.img -InDir bootparts -Kernel Image.gz
```

## Not legal advice

This document explains what I do and why. It is not legal advice. If you intend to use this
commercially, sell devices, ship it in a product or redistribute at scale, talk to someone
qualified about GPLv2 source-offer obligations and about Motorola's terms.
