#!/usr/bin/env bash
# Build the saipan kernel with the DVFS-segment override as well.
#
# Same kernel as build-ksu.sh, plus build/patch_cpu_level.py, which adds
#
#     mtk_cpufreq.level=N      0 = FY, 1 = B20G, 2 = B24G
#
# as a kernel command line option. Nothing changes unless the boot image's cmdline
# asks for it, so this image is a strict superset of the other one - which is why
# boot-saipan-ksu-level.img is the one I run on the handset.
#
# Measured here (sysbench pinned to cpu6, median of 3 x 10s):
#   FY   2,203,000 kHz  529.2 events/s   stock, fastest
#   B20G 2,000,000 kHz  480.5 events/s   -9.2%, exactly 2000/2203
#   B24G 2,400,000 kHz  288.2 events/s   ~45% SLOWER, rejected - see docs/CPU-CLOCK.md
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/build-ksu.sh" --level "$@"
