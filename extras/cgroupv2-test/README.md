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
