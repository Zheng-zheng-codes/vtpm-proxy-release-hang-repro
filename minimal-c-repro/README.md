# Minimal C reproducer for the vtpm_proxy_fops_release hang

`syz-prog2c` on the 49/78-program state-construction sequence produces a
multi-megabyte C file, so instead this is a hand-written minimal
reproducer aimed at the same code path.

## The reproducer (`vtpm-hang-minimal.c`, ~100 lines, self-contained)

1. `open("/dev/vtpmx", O_RDWR)` (needs `CONFIG_TCG_VTPM_PROXY=y`, root);
2. create N vTPM proxy devices via `VTPM_PROXY_IOC_NEW_DEV`
   (`flags = 0`, TPM 1.2 mode — the register work then runs the long
   timeout/capability probing path), keeping every fd returned by the
   ioctl open;
3. two close modes:
   - auto (default): `exit(0)` without closing — `__fput()` runs
     `vtpm_proxy_fops_release()` on every fd at exit;
   - `close` argument: `close()` each ioctl-returned fd explicitly,
     printing a timestamped line before and after every close
     (directly answers the question "is the ioctl-returned server fd
     closed, and does that stop the wait?").

Build: `gcc -O2 -static -o vtpm-hang-minimal vtpm-hang-minimal.c`

## Results (kernel 7.3.0-kernsight-kasan #1, full layout, KVM)

| run | mode | result |
|-----|------|--------|
| run A (`serial-minimal-c.log`, `sysrq-t-minimal.txt`) | auto, N=4 | **hang reproduced**: `INFO: task vtpm-hang-minim:9364 blocked for more than 143 seconds.` — the hung task IS this process; stack `vtpm_proxy_fops_release+0xa8 -> __flush_work`; serial repeats `tpm tpm0/tpm1: Operation Timed out` |
| run B (`serial-explicit-close.log`, `explicit-close-log.txt`) | explicit close, N=4 | all four `close()` calls returned in ~0 s, no block (close happened well after creation) |
| run 1 (`serial-N32-run2.log`, `N32-run2-sysrq.txt`) | auto, N=32 | **hang reproduced**: `INFO: task vtpm-hang-minim:9397 blocked for more than 143 seconds.`; still blocked at 286 s in the follow-up report |
| run 2 (`serial-N32-run3.log`, `N32-run3-sysrq.txt`) | auto, N=32, same boot as run 1 (no reboot) | **hang reproduced**: third hung-task report appears ~120 s later |

Reliability: with N=32 the reproducer triggered in 3/3 runs (runs A, 1, 2 —
the last two on the same guest without a reboot, i.e. not dependent on a
fresh boot). Smaller N is racy: N=1/N=2 attempts did not hang (the release
can complete before the overlap happens), which is why the default is 32.

So the answer to "are you closing the server-side fd from the ioctl?"
is: **yes** — both by relying on exit-time close and by explicit
`close()` — and when the hang occurs the closing task is itself stuck
in `vtpm_proxy_fops_release()` -> `vtpm_proxy_work_stop()` ->
`flush_work()`. Note `vtpm_proxy_work_stop()` calls
`vtpm_proxy_fops_undo_open()` BEFORE `flush_work()`, i.e.
STATE_OPENED_FLAG is cleared and `wake_up_interruptible(&wq)` runs
before the wait — yet in the hanging runs the wait still persisted
>143 s (and >286 s in the follow-up report) while the worker sat in
`tpm_transmit()` (see `sysrq-t-minimal.txt`).

Run B shows the flip side: closing well after creation lets the cancel
path (`req_canceled` checks STATE_OPENED_FLAG) win and every close
returns immediately. The same non-determinism explains why N=1/N=2
attempts did not hang while N=4/N=32 and the syzkaller/priming runs
did. Whether the cancel path can miss the wake-up for some
interleavings is exactly the kind of question we would like the
maintainer's analysis on.

## Files

```
vtpm-hang-minimal.c          the minimal reproducer (two close modes,
                             default N=32)
serial-minimal-c.log         run A serial: hung-task report, blocked task
                             = this process, "Operation Timed out" repeats
sysrq-t-minimal.txt          run A sysrq-t: workqueue tpm-vtpm backlog
serial-N32-run2.log          N=32 run: hung-task report (143 s) + follow-up
                             report (still blocked at 286 s)
serial-N32-run3.log          N=32 rerun on the same boot: third report
N32-run2-sysrq.txt / N32-run3-sysrq.txt   sysrq-t captures
serial-explicit-close.log    run B serial (explicit close, no block)
explicit-close-log.txt       run B: all closes returned in ~0 s
```

Same caveat as the main README: the logs end while the task is still
blocked; we do not claim a permanent deadlock.
