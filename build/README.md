# Building

Two build scripts, differing by one patch:

| script | adds | produced image |
|---|---|---|
| `build-ksu.sh` | Droidspaces config + KernelSU-Next manual hooks + vendor-module CRC tolerance | `boot-saipan-ksu.img` |
| `build-ksu-level.sh` | the same, plus the `mtk_cpufreq.level=` DVFS-segment override | `boot-saipan-ksu-level.img` |

`prepare-config.sh` is a diagnostic: it applies the same config on its own and prints the
full diff against the config the handset shipped with, without building.

## What you need

1. **Motorola's kernel source for this device** - `MotorolaMobilityLLC/kernel-mtk`, branch
   `android-12-release-s1rs32.38-20-9`. See [../SOURCE.md](../SOURCE.md).
2. **The AOSP clang toolchain**: `clang-r383902` (which reports itself as *clang version
   11.0.1, 6443078 based on r383902* - the same string the handset's stock kernel banner
   carries) plus the `aarch64-linux-android-4.9` binutils.
3. **KernelSU-Next**, checked out on the **`legacy`** branch. The build I validated against
   is commit `194a4d0531bba5810a7a0d1014acbbf34d9ae284` (`v3.2.0-legacy-25-g194a4d05`).
4. A Linux host. I built on WSL2/Ubuntu; nothing here is host-specific.

## Expected layout

```
~/saipan/
    kernel-mtk/            <- Motorola source, patched
    toolchain/
        clang-r383902/
        gcc49/             <- aarch64-linux-android-4.9 binutils
    out-ksu/  out-level/   <- build output, created for you
<this repo>/build/         <- the scripts, run from anywhere
```

Override any of it with environment variables:

```sh
KSRC=/path/to/kernel-mtk TC=/path/to/toolchain OUT=/path/to/out ./build-ksu-level.sh
```

## Getting the KernelSU-Next source in place

The build expects KernelSU-Next at `drivers/kernelsu` in the kernel tree. This has to be
done once, by hand:

```sh
git clone -b legacy https://github.com/KernelSU-Next/KernelSU-Next
cp -r KernelSU-Next/kernel  <kernel-mtk>/drivers/kernelsu
```

`build-ksu.sh` then applies `patches/ksu-next-4.14.patch`, which carries the four tree edits
KernelSU-Next needs on a 4.14 kernel. See [patches/README.md](patches/README.md).

It also fixes one upstream call that cannot compile here: `drivers/kernelsu/policy/allowlist.c`
uses `strscpy_pad()`, which only exists from 4.14.222 onwards, and this tree is 4.14.186. The
script rewrites that one call to `__strscpy_pad()`.

## Patches

Two different mechanisms, deliberately separate:

* **`patches/ksu-next-4.14.patch`** - a real `git apply` diff. KernelSU-Next's own
  old-kernel integration edits (`path_umount`, the `selinux_cred()`/`selinux_inode()`
  indirection, `filter_count` in `struct seccomp`, and hooking `drivers/kernelsu` into the
  build). Kept as a patch because it is upstream's change, not mine.
* **The Python patchers** - `patch_module.py`, `patch_module2.py`,
  `patch_manual_hooks.py`, `patch_cpu_level.py`. Each one locates a specific anchor and
  refuses to write anything if that anchor is not found exactly once. That matters here: the
  edits they make are small and land in files where a wrong guess would compile but
  misbehave. `patch_module2.py` in particular has to find the `bad_version:` block inside
  `check_version()`, and there is more than one `return 0;` nearby.

Each patcher is idempotent - running the build twice does not double-apply anything.

## What a build does

1. `git checkout --` the six files this project patches and KernelSU hooks, so no stale edit
   leaks in from a previous run.
2. Apply `patches/ksu-next-4.14.patch` if it is not already there.
3. Fix the `strscpy_pad` call.
4. Run the four Python patchers.
5. Seed `out/.config` from `saipan-stock.config` - the config the handset shipped with,
   pulled off the device with `zcat /proc/config.gz`. That is the base deliberately: every
   option this project does not mean to change stays exactly as Motorola set it.
6. Turn on the Droidspaces options and KernelSU, turn off `SYSVIPC`.
7. Assert the result, and abort if anything is missing.
8. Build `Image`, check the vermagic, gzip it.

```sh
./build-ksu-level.sh
# -> ~/saipan/out-level/arch/arm64/boot/Image.gz
```

## Verifying a build before you flash it

The script does these checks itself and prints them; they are worth running again by hand if
you change anything:

```sh
# the release string must be exactly this, or vendor modules are rejected on vermagic
grep -a -o -E "4.14.186\+ SMP preempt mod_unload modversions aarch64" out-level/vmlinux

# KernelSU must actually be in the image
aarch64-linux-android-nm out-level/vmlinux | grep -c ksu_
```

**The one that matters most is the vermagic and the CRC situation.** If the release string
comes out as anything other than `4.14.186+`, or if `CONFIG_LTO_CLANG`/`CONFIG_CFI_CLANG`/
`CONFIG_THINLTO` are not all `=y` in `out/.config`, the kernel will reject every module in
`/vendor/lib/modules` and you lose Wi-Fi, Bluetooth, touch, fingerprint and GPS. That is not
a subtle failure - but it does not fail at build time either, which is why the assertions
exist. [../docs/KERNEL-NOTES.md](../docs/KERNEL-NOTES.md) has the whole story.

## Packing the boot image

I did this on Windows with `pack-boot.ps1` (unpack / pack / info for the Android boot header).
It is PowerShell and it is the tool the published images were actually built with, so I am
shipping it rather than an untested POSIX rewrite.

```
# one-off: unpack the stock boot image from your own firmware
.\pack-boot.ps1 -Action unpack -BootImg stock-boot.img -OutDir bootparts

# repack with the kernel you built
.\pack-boot.ps1 -Action pack -OutImg boot-saipan-ksu-level.img `
                -InDir bootparts -Kernel Image.gz

# add a DVFS-segment override to that boot image
.\pack-boot.ps1 -Action pack -OutImg boot-b20g.img -InDir bootparts -Kernel Image.gz `
                -Cmdline "bootopt=64S3,32N2,64N2 buildvariant=user mtk_cpufreq.level=1"
```

The layout on this device, for anyone doing it with their own tools instead:

| field | value |
|---|---|
| header version | 2 |
| page size | 2048 |
| kernel addr | `0x40080000` |
| ramdisk addr | `0x51100000` |
| tags / dtb addr | `0x47C80000` |
| header size | 1660 |
| boot partition | 41,943,040 bytes (40 MiB) |
| stock kernel size | 13,890,554 |
| ramdisk size | 14,368,137 |
| dtb size | 143,445 |
| stock cmdline | `bootopt=64S3,32N2,64N2 buildvariant=user` |

Two things about the format that are easy to get wrong here:

* **The kernel is plain `gzip`, and the DTB is not appended to it.** This tree builds
  `Image.gz` and carries the device tree in the boot header's separate `dtb` section, exactly
  as the stock image does. Do not tape the DTB onto the end of the kernel - MTK's bootloader
  reads it from the header offset.
* **`pack-boot.ps1` reuses the stock header verbatim.** It unpacks `header.bin` alongside the
  blobs and patches only `KernelSize`, `RamdiskSize`, `DtbSize` and (optionally) the cmdline
  at offset 64. Every other field - the addresses, `OsVersion`, `HeaderSize`, the board
  metadata - stays byte-for-byte as Motorola wrote it. That is deliberate: I have no way to
  verify a hand-built header on this bootloader, so I do not build one.

The stock ramdisk is reused unchanged in both published images. You can see that in the
numbers above: `RamdiskSize` is 14,368,137 in the stock image and in mine.

```sh
# sanity check the result
.\pack-boot.ps1 -Action info -BootImg boot-saipan-ksu-level.img
# End must be <= 41,943,040
```

Then flash it - see [../FLASHING.md](../FLASHING.md). `flash-boot.ps1` does the flash and
waits for `sys.boot_completed`, and takes `-Restore` to put the stock image back.
