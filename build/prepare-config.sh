#!/usr/bin/env bash
# Show exactly what this project changes in the kernel config, starting from the
# config the handset actually shipped with (build/saipan-stock.config).
#
# This is a diagnostic, not part of the build - build-ksu.sh applies the same
# options and asserts them. Run this when a build behaves differently than
# expected and you want to see the config delta on its own.
#
# Nothing here is written to the source tree; everything goes to $OUT.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
KSRC="${KSRC:-$HOME/saipan/kernel-mtk}"
OUT="${OUT:-$HOME/saipan/out-config}"
TC="${TC:-$HOME/saipan/toolchain}"
STOCK_CFG="${STOCK_CFG:-$REPO/build/saipan-stock.config}"
TP="${TARGET_PRODUCT:-saipan_retail}"

export PATH="$TC/clang-r383902/bin:$TC/gcc49/bin:$PATH"
export LD_LIBRARY_PATH="$TC/clang-r383902/lib64:${LD_LIBRARY_PATH:-}"
export LC_ALL=C

cd "$KSRC"
printf '+' > .scmversion

# The toolchain has to be here for BOTH passes. LTO_CLANG / CFI_CLANG / THINLTO are
# gated on cc-option probes; with the host gcc they vanish and struct module changes.
KARGS=(O="$OUT" ARCH=arm64 TARGET_PRODUCT="$TP"
       CC=clang LD=ld.lld NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump
       STRIP=llvm-strip READELF=llvm-readelf
       CROSS_COMPILE=aarch64-linux-android- CLANG_TRIPLE=aarch64-linux-gnu-)

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$STOCK_CFG" "$OUT/.config"
echo "[i] seeded $OUT/.config from $STOCK_CFG ($(wc -l < "$OUT/.config") lines)"

make "${KARGS[@]}" olddefconfig >/dev/null 2>&1

"$KSRC/scripts/config" --file "$OUT/.config" \
  -e DEVTMPFS -e CGROUP_DEVICE -e POSIX_MQUEUE -e IPC_NS -e USER_NS \
  -e CGROUP_PIDS -e CGROUP_NET_PRIO -e TMPFS_XATTR -e TMPFS_POSIX_ACL \
  -e NF_TABLES -e NETFILTER_XT_MATCH_ADDRTYPE -e BRIDGE_NETFILTER \
  -e KPROBES -e KPROBE_EVENTS -e KSU -e KSU_MANUAL_HOOK \
  -d KSU_KPROBES_HOOK -d SYSVIPC -d DEVTMPFS_MOUNT -d MODULE_SIG

make "${KARGS[@]}" olddefconfig >/dev/null 2>&1

echo
echo "===== toolchain-ABI critical options (must match stock) ====="
for o in LTO LTO_CLANG THINLTO LTO_NONE CFI CFI_CLANG CFI_CLANG_SHADOW \
         MODVERSIONS MODULES MODULE_UNLOAD ARM64_SSBD CMDLINE CMDLINE_FROM_BOOTLOADER; do
  printf '  %-32s %s\n' "$o" "$(grep -E "^CONFIG_${o}=" "$OUT/.config" || echo '(absent)')"
done

echo
echo "===== Droidspaces additions ====="
for o in DEVTMPFS CGROUP_DEVICE POSIX_MQUEUE POSIX_MQUEUE_SYSCTL IPC_NS USER_NS \
         CGROUP_PIDS CGROUP_NET_PRIO TMPFS_XATTR TMPFS_POSIX_ACL NF_TABLES \
         NETFILTER_XT_MATCH_ADDRTYPE BRIDGE_NETFILTER OVERLAY_FS VETH BRIDGE; do
  printf '  %-32s %s\n' "$o" "$(grep -E "^CONFIG_${o}=" "$OUT/.config" || echo '(absent)')"
done

echo
echo "===== must be off ====="
grep -E '^# CONFIG_(SYSVIPC|DEVTMPFS_MOUNT|MODULE_SIG) is not set' "$OUT/.config" || true

echo
echo "===== full diff against the shipped stock config ====="
CFGDIFF="$OUT/cfgdiff.txt"
diff <(sort "$STOCK_CFG") <(sort "$OUT/.config") > "$CFGDIFF" || true
echo "  lines only in STOCK : $(grep -c '^<' "$CFGDIFF" || true)"
echo "  lines only in OURS  : $(grep -c '^>' "$CFGDIFF" || true)"
echo "  --- removals ---"
grep '^<' "$CFGDIFF" | grep -vE '^< #' | head -30 || true
echo "  --- additions ---"
grep '^>' "$CFGDIFF" | grep -vE '^> #' | head -40 || true
echo "  (full diff: $CFGDIFF)"

echo
echo -n "kernelrelease = "; make -s "${KARGS[@]}" kernelrelease
