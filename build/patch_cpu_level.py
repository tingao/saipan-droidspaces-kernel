#!/usr/bin/env python3
"""
Make the MT6833 CPU DVFS segment selectable from the kernel command line.

Why: _mt_cpufreq_get_cpu_level() in mtk_cpufreq_platform.c picks the OPP table from an
efuse segment code:

    val = get_devinfo_with_index(7) & 0xF;
    val 1..2  -> CPU_LEVEL_0 = FY    big cluster tops out at 2203000 kHz  (our chip)
    val == 6  -> CPU_LEVEL_2 = B24G  big cluster tops out at 2400000 kHz
    else      -> CPU_LEVEL_1 = B20G  big cluster tops out at 2000000 kHz

So the driver already contains a 2.4 GHz table; it is simply not selected on an FY-binned
part. Rather than hard-wire a choice into the kernel, this adds:

    mtk_cpufreq.level=N     (N = 0 FY, 1 B20G, 2 B24G)

which the boot image's own cmdline can carry -- /proc/cmdline on this device shows the
boot.img header cmdline is passed through. That means ONE kernel build covers baseline,
underclock and overclock, tested by repacking the boot image only, and the default remains
the efuse value so flashing this kernel changes nothing by itself.

It also prints both the efuse value and the effective level, so the running configuration is
verifiable from dmesg instead of assumed.
"""
import re
import sys

PATH = ("drivers/misc/mediatek/base/power/cpufreq_v1/src/mach/mt6833/"
        "mtk_cpufreq_platform.c")

src = open(PATH, encoding="utf-8", errors="surrogateescape").read()

if "mtk_cpufreq.level=" in src:
    print("  already patched")
    sys.exit(0)

# ---------------------------------------------------------------- 1. the override hook
anchor = "unsigned int _mt_cpufreq_get_cpu_level(void)\n{"
if src.count(anchor) != 1:
    print(f"  !! anchor found {src.count(anchor)} times (expected 1)")
    sys.exit(1)

hook = '''/* --- saipan: DVFS segment override ------------------------------------------
 * Default 0xFF means "use the efuse value", so this is inert unless the boot image
 * cmdline asks for something else. 0=FY, 1=B20G, 2=B24G.
 */
static unsigned int mt_cpufreq_level_override = 0xFF;

static int __init mt_cpufreq_level_override_setup(char *str)
{
	if (!str)
		return 1;
	mt_cpufreq_level_override = (unsigned int)simple_strtoul(str, NULL, 0);
	return 1;
}
__setup("mtk_cpufreq.level=", mt_cpufreq_level_override_setup);

''' + anchor

src = src.replace(anchor, hook, 1)

# ---------------------------------------------------------------- 2. apply it
tail = """#ifdef MTK_5GCM_PROJECT
	lv = CPU_LEVEL_1;
#endif
"""
if src.count(tail) != 1:
    print(f"  !! #ifdef MTK_5GCM_PROJECT tail found {src.count(tail)} times (expected 1)")
    sys.exit(1)

tail_new = tail + '''
	/* --- saipan: honour the cmdline override, if one was given --- */
	if (mt_cpufreq_level_override < NUM_CPU_LEVEL) {
		pr_info("mtk_cpufreq: CPU level OVERRIDDEN %u -> %u (efuse segment val=%d)\\n",
			lv, mt_cpufreq_level_override, val);
		lv = mt_cpufreq_level_override;
	} else {
		pr_info("mtk_cpufreq: CPU level %u from efuse (segment val=%d), no override\\n",
			lv, val);
	}
'''

src = src.replace(tail, tail_new, 1)

open(PATH, "w", encoding="utf-8", errors="surrogateescape").write(src)
print("  --- patched ok ---")

# show the result
m = re.search(r'unsigned int _mt_cpufreq_get_cpu_level\(void\)\n\{.*?\n\}', src, re.S)
if m:
    print("  --- resulting function ---")
    for line in m.group(0).splitlines():
        print("    " + line)
