# CPU clocks: three DVFS segments, and why the overclock is a trap

The short version: the MT6833 cpufreq driver contains a 2.4 GHz OPP table for the big cluster.
This handset's efuse does not select it. I made the selection switchable from the boot image
cmdline, measured all three tables with a harness I first validated against a known ratio, and
**rejected the overclock** - it reports 2.4 GHz under load and delivers about 45 % *less*
throughput than stock. The handset runs the stock segment.

---

## Where the three tables come from

MT6833's cpufreq driver ships three OPP tables and picks one at boot from an efuse segment code
in `_mt_cpufreq_get_cpu_level()`:

```c
val = get_devinfo_with_index(7) & 0xF;
if (val == 1 || val == 2)      lv = CPU_LEVEL_0;   /* FY   */
else if (val == 6)             lv = CPU_LEVEL_2;   /* B24G */
else                           lv = CPU_LEVEL_1;   /* B20G */
```

| level | name | big cluster (A76) max |
|---|---|---|
| 0 | `FY` | 2,203,000 kHz |
| 1 | `B20G` | 2,000,000 kHz |
| 2 | `B24G` | 2,400,000 kHz |

So the 2.4 GHz table is *already in the source*. What is missing is any way to select it, and
the reason it is not selected on my unit is that the silicon is binned for 2.2 GHz.

## The override

`build/patch_cpu_level.py` adds one `__setup` in
`drivers/misc/mediatek/base/power/cpufreq_v1/src/mach/mt6833/mtk_cpufreq_platform.c`:

```
mtk_cpufreq.level=N       0 = FY, 1 = B20G, 2 = B24G
```

The default is `0xFF`, meaning "use the efuse value", so the option is inert unless asked for.
That matters: `boot-saipan-ksu-level.img` flashed with no cmdline change behaves exactly like
the stock choice, and one kernel build covers baseline, underclock and overclock.

This works because the boot image's own cmdline is passed through to the kernel - verified on
the device, where `/proc/cmdline` contains the boot header's `bootopt=64S3,32N2,64N2
buildvariant=user`. Repacking the boot image is the whole mechanism; there is no kernel rebuild
per configuration.

The patch also logs both the efuse value and the effective level, so the running configuration
is verifiable from `dmesg` instead of assumed:

```
mtk_cpufreq: CPU level 0 from efuse (segment val=1), no override
mtk_cpufreq: CPU level OVERRIDDEN 0 -> 2 (efuse segment val=1)
```

The command line used for each image, keeping the stock cmdline and appending to it:

| image | cmdline tail |
|---|---|
| `v2-fy.img` | `mtk_cpufreq.level=0` |
| `v2-b20g.img` | `mtk_cpufreq.level=1` |
| `v2-b24g.img` | `mtk_cpufreq.level=2` |

Those three are not published as separate downloads - they are the same `Image.gz` repacked
with a different cmdline, and `build/pack-boot.ps1` reproduces any of them in one command.

---

## Measuring it properly

My first attempt used `sha256sum` and `xz` over sub-second runs and reported the overclock as
**6 % faster**. That was wrong, and the reason is worth stating: those runs were too short and
too noisy to measure what I was changing. I threw that harness away.

The numbers below come from `sysbench cpu`, **pinned to cpu6** (a big-core, so the measurement
is not smeared across clusters) with **runs of 10 seconds, median of three**. The pinning
matters: unpinned, the scheduler moves work between a 2.0 GHz little cluster and a 2.2 GHz big
one and the result says more about the scheduler than the clock.

The harness proves itself on the underclock row: 2000/2203 = 0.9079, and the measured ratio is
480.5/529.2 = 0.9080. Agreement to 0.1 %. That is what makes the third row trustworthy - the
method tracks clock speed accurately, so when the number does not follow the clock, the clock
is not the thing that changed.

## Results

| config | big table | reported freq under load | sysbench, pinned cpu6 | all-core |
|---|---|---|---|---|
| **FY (stock)** | 2,203,000 | 2,203,000 | **529.2 events/s** | 2443 |
| B20G (underclock) | 2,000,000 | 2,000,000 | 480.5 events/s (−9.2 %) | 2316 |
| B24G (overclock) | 2,400,000 | 2,400,000 | **288.2 events/s (−45 %)** | 2446 |

`scaling_cur_freq` was sampled throughout each run and reports exactly the table's maximum for
the full 12-second window in all three cases. Nothing is throttling, nothing is dropping back.
The driver believes it is running at 2.4 GHz.

## Why the overclock is a trap

`B24G` is not "FY plus 200 MHz". It is a **different speed-bin's clock plan** - a different PLL
position and divider sequence (`opp_tbl_method_L_B24G` in the same file). Requesting that plan
on a part binned for FY gets you a frequency the silicon does not actually deliver. The register
values change, the reported clock changes, and throughput collapses to about 55 % of stock.

That is what makes it dangerous rather than merely pointless. A naive benchmark - or a
`scaling_cur_freq` reading, or a "is it running at 2.4 GHz" check - says the overclock worked.
Only a sustained throughput measurement says otherwise.

**If you take one thing from this page: do not enable `mtk_cpufreq.level=2` because the driver
offers it. It is a table for a different bin.** If you have a B24G-binned unit, the efuse
already selects it and there is nothing to do.

## Underclocking works, but buys nothing here

The B20G row behaves exactly as predicted, so the mechanism is sound and underclocking to
2.0 GHz is available with `mtk_cpufreq.level=1`. I left it at stock anyway, because there is no
thermal headroom to buy: battery temperature sat at **28.6-29.2 °C across all three
configurations**. At the load a container server actually puts on this phone, the big cluster is
idle most of the time and the ceiling is not what is keeping the device cool.

That would change if you ran something that pins the big cores. Then B20G is a real lever, and
the `extras/saipan-tuning` module will hold it for you.

## Re-measuring after a change

```sh
# in the container
sysbench cpu --cpu-max-prime=20000 --time=10 run        # once, unpinned, for a sanity check

# pinned to cpu6, median of three - what the table above used
for i in 1 2 3; do taskset -c 6 sysbench cpu --time=10 run | grep events; done
```

Watch `scaling_cur_freq` while it runs:

```sh
while :; do cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq; sleep 0.5; done
```

Confirm which level is actually active from the kernel log:

```sh
su -c 'dmesg | grep "mtk_cpufreq: CPU level"'
```
