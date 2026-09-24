#!/usr/bin/env bash
# ===========================================================================
# Build the saipan (moto g50 5G / MT6833) kernel.
#
#   shipped stock config  (build/saipan-stock.config, pulled from /proc/config.gz)
# + Droidspaces' non-GKI container options
# + KernelSU-Next in MANUAL HOOK mode
# + the vendor-module CRC tolerance patch
#
# Optional: pass --level to also add the mtk_cpufreq.level= DVFS-segment override
# (that is what build-ksu-level.sh does).
#
# Output: $OUT/arch/arm64/boot/Image.gz
# Pack it into a flashable boot image with build/pack-boot.ps1 - see build/README.md.
# ===========================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KSRC="${KSRC:-$HOME/saipan/kernel-mtk}"
OUT="${OUT:-$HOME/saipan/out-ksu}"
TC="${TC:-$HOME/saipan/toolchain}"
STOCK_CFG="${STOCK_CFG:-$REPO/build/saipan-stock.config}"
TP="${TARGET_PRODUCT:-saipan_retail}"

WITH_LEVEL=0
[ "${1:-}" = "--level" ] && WITH_LEVEL=1

export PATH="$TC/clang-r383902/bin:$TC/gcc49/bin:$PATH"
export LD_LIBRARY_PATH="$TC/clang-r383902/lib64:${LD_LIBRARY_PATH:-}"
export LC_ALL=C

[ -d "$KSRC" ] || { echo "!! KSRC not found: $KSRC" >&2; exit 1; }
[ -x "$TC/clang-r383902/bin/clang" ] || { echo "!! clang not found under $TC/clang-r383902" >&2; exit 1; }
cd "$KSRC"

# Deterministic release string. scripts/setlocalversion prints .scmversion verbatim,
# so this gives exactly 4.14.186+ no matter what git thinks. Do NOT also set
# CONFIG_LOCALVERSION="+" - you would get two of them.
printf '+' > .scmversion

KARGS=(O="$OUT" ARCH=arm64 TARGET_PRODUCT="$TP"
       CC=clang LD=ld.lld NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump
       STRIP=llvm-strip READELF=llvm-readelf
       CROSS_COMPILE=aarch64-linux-android- CLANG_TRIPLE=aarch64-linux-gnu-)

echo "===== 1. reset the files this project patches ====="
if [ -d .git ]; then
  git checkout -- kernel/module.c fs/exec.c fs/read_write.c fs/open.c fs/stat.c kernel/reboot.c 2>/dev/null \
    && echo "  reverted to pristine" || echo "  (nothing to revert / not tracked here)"
fi

echo
echo "===== 2. KernelSU-Next 4.14 integration ====="
# KernelSU-Next needs four things it does not get for free on a 4.14 tree:
#   fs/namespace.c + fs/internal.h      path_umount(), used by ksud to unmount
#   include/linux/seccomp.h             atomic_t filter_count in struct seccomp
#   security/selinux/*                  selinux_cred()/selinux_inode() indirection
#   drivers/Kconfig, drivers/Makefile   hook the drivers/kernelsu directory in
if grep -q "path_umount" fs/internal.h 2>/dev/null; then
  echo "  ksu-next-4.14.patch already applied"
else
  git apply "$REPO/build/patches/ksu-next-4.14.patch"
  echo "  applied build/patches/ksu-next-4.14.patch"
fi

if [ ! -d drivers/kernelsu ]; then
  echo "!! drivers/kernelsu is missing. Clone KernelSU-Next on the 'legacy' branch"
  echo "   and copy its kernel/ directory there, see build/README.md."
  exit 1
fi

# 4.14.186 predates strscpy_pad() (added in 4.14.222).
F=drivers/kernelsu/policy/allowlist.c
if grep -q 'strscpy_pad(domain, KSU_DEFAULT_SELINUX_DOMAIN' "$F" 2>/dev/null; then
  sed -i 's/\bstrscpy_pad(domain, KSU_DEFAULT_SELINUX_DOMAIN/__strscpy_pad(domain, KSU_DEFAULT_SELINUX_DOMAIN/' "$F"
  echo "  strscpy_pad -> __strscpy_pad in $F"
else
  echo "  strscpy_pad already fixed at that call site"
fi

echo
echo "===== 3. source patches written for this device ====="
python3 "$REPO/build/patch_module.py"       | tail -1
python3 "$REPO/build/patch_module2.py"      | tail -1
python3 "$REPO/build/patch_manual_hooks.py" | tail -6
if [ "$WITH_LEVEL" = 1 ]; then
  python3 "$REPO/build/patch_cpu_level.py"  | head -1
fi

echo
echo "===== 4. configuration ====="
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$STOCK_CFG" "$OUT/.config"

# Both olddefconfig passes carry the full toolchain. This is not optional: LTO_CLANG,
# CFI_CLANG and THINLTO are gated on compiler capability probes, so a kconfig run with
# the host gcc silently selects LTO_NONE, drops CFI, changes struct module, and moves
# the module_layout CRC - which makes every prebuilt vendor module unloadable.
# See docs/KERNEL-NOTES.md.
make "${KARGS[@]}" olddefconfig >/dev/null 2>&1
"$KSRC/scripts/config" --file "$OUT/.config" \
  -e DEVTMPFS -e CGROUP_DEVICE -e POSIX_MQUEUE -e IPC_NS -e USER_NS \
  -e CGROUP_PIDS -e CGROUP_NET_PRIO -e TMPFS_XATTR -e TMPFS_POSIX_ACL \
  -e NF_TABLES -e NETFILTER_XT_MATCH_ADDRTYPE -e BRIDGE_NETFILTER \
  -e KPROBES -e KPROBE_EVENTS -e KSU -e KSU_MANUAL_HOOK \
  -d KSU_KPROBES_HOOK -d SYSVIPC -d DEVTMPFS_MOUNT -d MODULE_SIG
make "${KARGS[@]}" olddefconfig >/dev/null 2>&1

echo "----- assertions -----"
fail=0
req() { v=$(grep -E "^CONFIG_${1}=" "$OUT/.config" || true); [ -z "$v" ] && { echo "  MISSING $1"; fail=1; } || echo "  ok $v"; }
off() { grep -qE "^CONFIG_${1}=" "$OUT/.config" && { echo "  UNEXPECTED $1"; fail=1; } || echo "  ok # $1 not set"; }
for s in LTO_CLANG CFI_CLANG CFI_CLANG_SHADOW THINLTO MODULES MODVERSIONS ARM64_SSBD \
         DEVTMPFS CGROUP_DEVICE POSIX_MQUEUE IPC_NS USER_NS CGROUP_PIDS CGROUP_NET_PRIO \
         TMPFS_XATTR TMPFS_POSIX_ACL NF_TABLES NETFILTER_XT_MATCH_ADDRTYPE OVERLAY_FS \
         VETH BRIDGE SECCOMP SECCOMP_FILTER NAMESPACES PID_NS UTS_NS NET_NS \
         KSU KSU_MANUAL_HOOK; do req "$s"; done
for s in LTO_NONE SYSVIPC MODULE_SIG KSU_KPROBES_HOOK; do off "$s"; done
[ $fail -ne 0 ] && { echo "!! ASSERT FAILED - not building"; exit 1; }
echo -n "  kernelrelease: "; make -s "${KARGS[@]}" kernelrelease

echo
echo "===== 5. build ====="
LOG="${LOG:-$HOME/saipan/build-ksu.log}"
set +e
make "${KARGS[@]}" -j"$(nproc)" Image > "$LOG" 2>&1
rc=$?
set -e
[ $rc -eq 0 ] && echo "  [OK]" || { echo "  [FAIL] rc=$rc"; grep -nE "error:" "$LOG" | tail -20; }

if [ $rc -eq 0 ]; then
  echo
  echo "===== 6. verify the artifact ====="
  ls -l "$OUT/arch/arm64/boot/Image"
  echo -n "  vermagic : "; grep -a -o -E "4.14.186\+ SMP preempt mod_unload( modversions)? aarch64" "$OUT/vmlinux" | head -1
  echo -n "  ksu syms : "; "$TC/gcc49/bin/aarch64-linux-android-nm" "$OUT/vmlinux" 2>/dev/null | grep -c 'ksu_' || true
  if [ "$WITH_LEVEL" = 1 ]; then
    echo -n "  level override present: "
    grep -c 'mtk_cpufreq.level=' drivers/misc/mediatek/base/power/cpufreq_v1/src/mach/mt6833/mtk_cpufreq_platform.c
  fi
  gzip -9 -n -c "$OUT/arch/arm64/boot/Image" > "$OUT/arch/arm64/boot/Image.gz"
  echo -n "  Image.gz : "; ls -l "$OUT/arch/arm64/boot/Image.gz" | awk '{print $5}'
  echo -n "  md5      : "; md5sum "$OUT/arch/arm64/boot/Image.gz" | cut -d' ' -f1
fi
exit $rc
