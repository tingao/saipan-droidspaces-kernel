# cgroup v2 device-controller tests

Two standalone programs that check whether this kernel can do what `runc` needs on a
cgroup v2 host. They exist because the original failure —
`bpf_prog_query(BPF_CGROUP_DEVICE) failed: invalid argument` — can be produced by several
different causes, and a bare "it works now" is not evidence. Both programs include control
cases, so a pass cannot be confused with "the test did nothing".

See [../../docs/CGROUP-V2.md](../../docs/CGROUP-V2.md) for the backport itself.

## Build

Needs an aarch64 cross-compiler. The Android NDK works:

```sh
CC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang
$CC -O2 -Wall -o cgdev-query  cgdev-query.c
$CC -O2 -Wall -o cgdev-attach cgdev-attach.c
$CC -O2 -Wall -o hog3        hog3.c
```

Do **not** link with `-static`: on Android 12 a static NDK binary trips bionic's
"executable's TLS segment is underaligned" check and aborts.

Both programs deliberately carry their own copy of `union bpf_attr` instead of including a
libc header. Fields added after 4.14 (`batch`, `iter`, `link`, `btf`, …) shift the offsets of
everything after them, so a modern header would put `query.target_fd` at the wrong offset and
the test would be measuring nothing.

## Run

`/data/local/tmp` is executable; run these as root:

```sh
adb push cgdev-query /data/local/tmp/
adb shell su -c "chmod 755 /data/local/tmp/cgdev-query; /data/local/tmp/cgdev-query /sys/fs/cgroup"
```

Note the `su -c` trap: `su -c "a; b"` elevates only `a`, because the `;` is consumed by the
outer `adb shell`. Put the commands in a script and elevate the script.

### `cgdev-query`

Makes the exact call `runc` makes and reports the result for `BPF_CGROUP_DEVICE`, for two
attach types that are definitely valid, and for two arguments that are definitely invalid.

**The controls are the point.** On the original kernel every line returned `EINVAL`, including
`BPF_CGROUP_INET_INGRESS` — an attach type that has existed since 4.10. That is what proved
the `EINVAL` was about the *command* being unknown (this tree had no `BPF_PROG_QUERY` at all),
not about the attach type.

Expected on a working kernel: the four real queries succeed, both controls fail with `EINVAL`,
and it exits 0.

### `cgdev-attach`

Goes further: loads a real `BPF_PROG_TYPE_CGROUP_DEVICE` program, attaches it, and checks that
it actually decides whether a device can be opened.

It creates a scratch cgroup (`<mount>/cgdev-attach-test`), moves itself into it, and walks four
phases:

| phase | attached program | opening `/dev/null` must |
|---|---|---|
| 0 | none | succeed |
| 1 | returns 1 (allow) | succeed |
| 2 | returns 0 (deny) | **fail with EPERM** |
| 3 | detached | succeed |

Phase 2 is the real proof — an `EPERM` that only appears while the deny program is attached
can only come from the kernel running it.

It cleans up after itself: moves back to the root cgroup, detaches, and removes the scratch
cgroup. `detach(allow): No such file or directory` in the output is expected and harmless —
attaching the deny program with flags `0` *replaced* the allow program, so there is nothing
left to detach under that fd.

## What a pass does and does not mean

A pass here means the kernel implements the cgroup v2 device controller: programs load, attach,
and are consulted. It does **not** mean cgroup v2 can apply resource limits on this phone. It
cannot — Android binds all ten controllers to cgroup v1, so a v2 cgroup has no `memory.max`.
That is covered in [../../docs/CGROUP-V2.md](../../docs/CGROUP-V2.md) §7.

---

## `hog3` — the workload for memory-limit testing

A separate thing, and it exists because of a trap that cost four invalid measurements.

`hog3 <megabytes> [microseconds-per-MB]` allocates and **touches** a target amount of memory,
paced so the allocation is slow enough to observe, then holds it.

## Why not just `malloc` + `memset`

Because clang deletes it. The first version of this workload wrote each 1 MB buffer with
`memset()` and never read it back. At `-O2` that is a dead store, so the compiler removed it:
the program "allocated 192 MB" 192 times while its own `VmRSS` stayed at **2.6 MB**. Every
cgroup measurement taken against it was measuring an empty process, and the numbers looked
plausible enough to believe.

`hog3` stores through a `volatile` pointer and reads a byte back from each buffer, so neither
the allocation nor the stores can be removed.

## Always sanity-check the workload first

Before believing any limit result, run it with **no limit** and confirm VmRSS climbs to about
the target:

```sh
adb shell su -c '/data/local/tmp/hog3 192 20000 & sleep 6; grep VmRSS /proc/$!/status'
# expect VmRSS around 190000 kB. If it is a few thousand, the workload is not allocating.
```

Then compare the process's own `VmRSS` against the cgroup's `memory.current` while it is alive.
When they disagree by two orders of magnitude, the problem is the measurement, not the kernel.

## What it established here

With `cgroup_no_v1=memory` and `memory.max = 64 MB`:

- `memory.current` pinned at exactly `67108864` — **the cap binds**
- `memory.events` = `max 213311 oom 30472 oom_kill 0` — the OOM path ran 30,472 times and
  **killed nothing**; the process spun in state `R` at the cap
- with swap left uncapped, the same 192 MB allocation was absorbed instead (`memory.swap.current`
  reached 129 MB, `memory.current` peaked at 63 MB)

On cgroup v1 this kernel *does* kill. That difference is why the container stays on v1 — see
[../../docs/CGROUP-V2.md](../../docs/CGROUP-V2.md) §7.2.
