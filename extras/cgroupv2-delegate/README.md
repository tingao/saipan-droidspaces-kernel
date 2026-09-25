# cgroup v2 memory delegation

Makes the memory controller reachable for each Droidspaces container, which is the
precondition for any container memory cap existing at all on this handset.

```sh
# install as a KernelSU module
cp -r extras/cgroupv2-delegate /data/adb/modules/saipan-cgroupv2
sh /data/adb/modules/saipan-cgroupv2/service.sh &     # or just reboot
```

## The problem

In cgroup v2 a controller is only usable in a cgroup if the **parent** lists it in
`cgroup.subtree_control`. A container's cgroup is

```
/sys/fs/cgroup/droidspaces/<name>
```

so **both** levels have to carry `+memory` before the leaf gets its files:

```
/sys/fs/cgroup                      cgroup.subtree_control = memory
└── droidspaces/                    cgroup.subtree_control = memory
    └── bagda/                      memory.max, memory.swap.max,
                                    memory.current, memory.events, memory.stat
```

Without it the container cgroup's `cgroup.controllers` is empty, Droidspaces'
`ds_cgroup_apply_limits()` finds no `memory` and gives up:

```
[CGROUP] 'memory' controller not supported, limit skipped.
```

and the container simply has no cap.

## Why this cannot live inside the container

The container runs in its own cgroup namespace, so **its `/sys/fs/cgroup` *is* its own
subtree**. Its parent is not visible to it, let alone writable. Only the host can
reach `cgroup.subtree_control` one level up. Droidspaces does not do this either — its
`cgroup.c` only *reads* `cgroup.controllers` to decide whether a limit is possible.

## Why it loops

`/sys/fs/cgroup/droidspaces` is created when a container starts and removed when it
stops, so the delegation has to be re-established, not set once at boot. The script
re-checks every 5 s; it rewrites nothing that is already correct.

## Verified

```
root subtree_control        : memory
droidspaces controllers     : memory
bagda controllers           : memory
bagda memory.max            : 3457220608      (90% of RAM, set by the container's own guard)
bagda memory.swap.max       : 2592911360      (90% of swap)
```

and a workload that then exceeded the container cap was killed by the kernel:

```
Memory cgroup out of memory: Kill process 16592 (python3) score 613 or sacrifice child
Killed process 16592 (python3) total-vm:177852kB, anon-rss:163212kB
```

with the container and its other services untouched.
