# CPU clocks: three DVFS segments, and what the 2.4 GHz table actually does

**Short version, corrected.** MT6833's cpufreq driver carries three OPP tables and picks one at
boot from an efuse segment code. I made the choice switchable from the boot image cmdline and
measured all three. The 2.4 GHz table is **not** a working overclock on this handset: the
hardware never leaves 2.203 GHz, so throughput does not move, while the core voltage rises by
43.75 mV. It is a no-op with a real cost, and the handset runs the stock segment.

> **This page corrects itself.** An earlier version of this write-up reported the overclock as
> **45 % slower** than stock. That figure does not reproduce and was wrong - the details, and
> what I think went wrong, are in [§5](#5-the-earlier-45-claim-was-wrong). The result below is
> stable across repeated runs and is backed by a hardware frequency readback, which is what the
> earlier session did not have.

---

## 1. Where the three tables come from

MT6833's cpufreq driver picks an OPP table at boot from an efuse segment code in
`_mt_cpufreq_get_cpu_level()`:

```c
val = get_devinfo_with_index(7) & 0xF;
if (val == 1 || val == 2)      lv = CPU_LEVEL_0;   /* FY   */
else if (val == 6)             lv = CPU_LEVEL_2;   /* B24G */
else                           lv = CPU_LEVEL_1;   /* B20G */
```

| level | name | big cluster (A76) top OPP | Vproc at that OPP |
|---|---|---|---|
| 0 | `FY` | 2,203,000 kHz | 79,375 µV |
| 1 | `B20G` | 2,000,000 kHz | 75,000 µV |
| 2 | `B24G` | 2,400,000 kHz | 83,750 µV |

This handset's efuse reports `val=1`, so it is an **FY** part. The 2.4 GHz table is present in the
source anyway; it belongs to a differently binned part.

## 2. The override

`build/patch_cpu_level.py` adds one `__setup` in
`drivers/misc/mediatek/base/power/cpufreq_v1/src/mach/mt6833/mtk_cpufreq_platform.c`:

```
mtk_cpufreq.level=N       0 = FY, 1 = B20G, 2 = B24G
```

The default is `0xFF`, meaning "use the efuse value", so the option is inert unless asked for.
That is why `boot-saipan-ksu-level.img` flashed with no cmdline change behaves exactly like the
stock choice, and one kernel build covers all three configurations.

It works because the boot image's own cmdline reaches the kernel - verified on the device, where
`/proc/cmdline` contains the boot header's `bootopt=64S3,32N2,64N2 buildvariant=user`. Repacking
the boot image is the whole mechanism; there is no rebuild per configuration.

| image | cmdline tail |
|---|---|
| `v2-fy.img` | `mtk_cpufreq.level=0` |
| `v2-b20g.img` | `mtk_cpufreq.level=1` |
| `v2-b24g.img` | `mtk_cpufreq.level=2` |

Those are not separate downloads - they are the same `Image.gz` repacked with a different
cmdline, and `build/pack-boot.ps1` reproduces any of them in one command.

## 3. How it was measured

This matters more than the result, because the earlier session got it wrong with a plausible
harness.

* **Workload**: `sysbench cpu --cpu-max-prime=20000 --time=10 run`, **pinned to cpu6** with
  `taskset -c 6`. Pinning matters: unpinned, the scheduler moves work between a 2.0 GHz little
  cluster and the big cluster and you end up measuring scheduler decisions. Three runs per
  configuration, median reported.
* **What the driver says**: `/sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq`.
* **What the hardware says**: `/proc/cpufreq/MT_CPU_DVFS_L/cpufreq_freq` and
  `/proc/cpufreq/MT_CPU_DVFS_L/cpufreq_volt`. This is MediaTek's own DVFS interface; it reports
  the PLL frequency and the Vproc/Vsram regulators. `cpufreq_oppidx` prints the OPP table
  actually in use, with the voltage for every entry.

> **`cpuinfo_cur_freq` is not a hardware readback on this driver.** It mirrors
> `scaling_cur_freq` exactly, so it cannot be used to check whether the requested clock was
> really applied. That is exactly the kind of thing that let the earlier wrong result stand.
> `/proc/cpufreq/MT_CPU_DVFS_L/` is the honest source.

The harness validates itself on the underclock row: 2000/2203 = 0.9079 and the measured
throughput ratio is 841.2/927.9 = 0.9066, an agreement of 0.15 %.

## 4. Results

Three runs each, median, pinned to cpu6:

| config | driver reports | **hardware PLL** | Vproc | sysbench | vs FY |
|---|---|---|---|---|---|
| **FY (efuse, stock)** | 2,203,000 | **2,202,000** | 793,750 µV | **927.9 events/s** | - |
| B20G (underclock) | 2,000,000 | **1,999,000** | 750,000 µV | 841.2 events/s | −9.3 % |
| B24G ("overclock") | 2,400,000 | **2,202,000** | 837,500 µV | 929.6 events/s | +0.2 % |

Sampled once a second for the whole run, all three configurations hold their reading for the
full window - nothing is throttling back:

```
FY     t=1..9s   scaling=2203000  cpuinfo=2203000  hw=2202000 KHz  Vproc: 793750 uV
B20G   t=1..9s   scaling=2000000  cpuinfo=2000000  hw=1999000 KHz  Vproc: 750000 uV
B24G   t=1..9s   scaling=2400000  cpuinfo=2400000  hw=2202000 KHz  Vproc: 837500 uV
```

**Read the B24G row carefully.** The same driver reports two different things at once:

* through cpufreq (`scaling_cur_freq`, `cpuinfo_cur_freq`): **2,400,000 kHz**, and the B24G OPP
  table really is the one in use - `cpufreq_oppidx` prints index 0 as `(2400000, 83750)`;
* through its own DVFS interface, which reads the PLL: **2,202,000 kHz** - byte-for-byte the FY
  clock.

The PLL never moves. Throughput confirms it: 929.6 against 927.9 events/s is +0.2 %, inside the
run-to-run spread. What *does* move is the regulator: **+43,750 µV of Vproc (+5.5 %)** for
nothing.

### Why the PLL does not reach 2.4 GHz

The cpufreq driver does not ask for a frequency in Hz. It selects one by writing a **PLL divider
position and a clock divider**, from a per-bin table of `FP(POS, CLK)` pairs -
`opp_tbl_method_L_FY`, `opp_tbl_method_L_B20G`, `opp_tbl_method_L_B24G` in
`src/mach/mt6853/mtk_cpufreq_opp_table.h`. The nominal kHz values come from a separate
per-level list and are what the cpufreq layer reports; they are not read back from the hardware.

The three tables are not the same plan at different speeds - they have different lengths and
different POS distributions:

| table | entries | POS=1 | POS=2 | POS=4 |
|---|---|---|---|---|
| `opp_tbl_method_L_FY` | 19 | 6 | 9 | 4 |
| `opp_tbl_method_L_B24G` | 16 | 6 | 8 | 2 |

Selecting B24G installs a clock plan written for a part binned to reach 2.4 GHz. On this
FY-binned silicon the top entry lands on the same PLL output FY uses, so the requested 2.4 GHz
simply is not produced, and the only effect of the larger table is the higher voltage that comes
with it.

I am labelling that last paragraph as the explanation rather than a proof: I verified the PLL
output and the voltage directly, and I verified that the B24G table is the one loaded, but I did
not instrument the PLL write itself. What is not in doubt is the outcome - the same real clock,
a higher voltage, and no throughput change.

## 5. The earlier 45 % claim was wrong

The first version of this page reported:

| config | (earlier, wrong) |
|---|---|
| FY | 529.2 events/s |
| B20G | 480.5 events/s (−9.2 %) |
| B24G | **288.2 events/s (−45 %)** |

The underclock row was correct and validated the harness. The B24G row was not, and I do not
have a proven cause. What I can say:

* It does not reproduce. Three runs today give 929.6 / 928.2 / 932.4, a spread of 0.4 %, against
  927.9 for FY.
* The hardware readback agrees with the throughput, which is independent confirmation that the
  clock is unchanged. The earlier session had no such readback - it had only
  `scaling_cur_freq`, which reports the requested value and would have looked identical in both
  the real and the bad measurement.
* The most likely cause is that the phone was busy with something else during that one run. It
  was taken shortly after the container had been rebuilt, with Docker and the package manager
  still settling, and the whole point of pinning to cpu6 is defeated if other runnable work is
  competing for it.

I am recording the correction rather than quietly replacing the number, because anyone who read
the first version and decided against the overclock for the wrong reason should know the real
reason.

## 6. What this means in practice

**Do not select B24G.** It is not a small win and it is not a loss - it is nothing, paid for in
voltage. On a handset that lives on a charger, 43.75 mV of extra core voltage is heat and battery
ageing with no return.

The overclock the driver *appears* to offer does not exist on this silicon, and no kernel-side
change can create it: the OPP table is selected from an efuse value, and the PLL does not
produce the frequency when asked. If you have a B24G-binned unit, its efuse already selects the
B24G table and there is nothing to do.

**Underclocking to B20G does work** and is exactly the 9.1 % clock reduction it claims. I left
the handset at stock anyway: at the load a container server puts on this phone there is no
thermal headroom to buy (battery temperature sat at 28.6-29.2 °C across all configurations), so
trading 9 % of peak for nothing is not worth it. If you run something that pins the big cores it
becomes a real lever - `extras/saipan-tuning/tuning-uc.conf` sets it.

## 7. Re-measuring after a change

```sh
# the workload, pinned, with the same parameters the table above used
taskset -c 6 sysbench cpu --cpu-max-prime=20000 --time=10 run    # three times, take the median

# what the driver claims
cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq

# what the hardware is actually doing - the one that matters
cat /proc/cpufreq/MT_CPU_DVFS_L/cpufreq_freq
cat /proc/cpufreq/MT_CPU_DVFS_L/cpufreq_volt

# which OPP table is loaded, and its per-index voltages
cat /proc/cpufreq/MT_CPU_DVFS_L/cpufreq_oppidx

# which level the kernel chose
dmesg | grep 'mtk_cpufreq: CPU level'
```
