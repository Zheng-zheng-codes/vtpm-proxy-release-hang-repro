# Minimal C reproducer for the vtpm_proxy_fops_release hang

`syz-prog2c` on the 49/78-program state-construction sequence produces a
multi-megabyte C file, so instead these are two hand-written minimal
test cases aimed at the same code path. Both are self-contained
(~100 lines, no dependency on linux/vtpm_proxy.h being installed).

## The two test cases

### 1. `vtpm-hang-minimal.c` — reproduces the hang (exit-time close)

1. `open("/dev/vtpmx", O_RDWR)` (needs `CONFIG_TCG_VTPM_PROXY=y`, root);
2. create N vTPM proxy devices via `VTPM_PROXY_IOC_NEW_DEV`
   (`flags = 0`, TPM 1.2 mode — the register work then runs the long
   timeout/capability probing path), keeping every fd the ioctl
   returns open;
3. `exit(0)` WITHOUT closing them — `__fput()` then runs
   `vtpm_proxy_fops_release()` -> `vtpm_proxy_work_stop()` ->
   `flush_work()` on every fd at exit, and that path hangs.

Build:   `gcc -O2 -static -o vtpm-hang-minimal vtpm-hang-minimal.c`
Run:     `./vtpm-hang-minimal`  (N defaults to 32; see reliability below)

### 2. `vtpm-close-minimal.c` — the explicit-close CONTROL experiment

Same as above, but instead of exiting it `close()`es each
ioctl-returned server-side fd explicitly, printing a timestamped line
before and after every close. This exists to answer the question
"are you closing the server-side fd returned by the ioctl? If you
close it, it should clear STATE_OPENED_FLAG and wake up any client."

Build:   `gcc -O2 -static -o vtpm-close-minimal vtpm-close-minimal.c`
Run:     `./vtpm-close-minimal [N]`  (default 32, as root)

## Results (kernel 7.3.0-kernsight-kasan #1, full layout, KVM)

| run | test case | mode | result |
|-----|-----------|------|--------|
| run A | `vtpm-hang-minimal.c` | auto, N=4 | **hang**: `INFO: task vtpm-hang-minim:9364 blocked for more than 143 seconds.` — the hung task IS this process; stack `vtpm_proxy_fops_release+0xa8 -> __flush_work`; serial repeats `tpm tpm0/tpm1: Operation Timed out` |
| run 1 | `vtpm-hang-minimal.c` | auto, N=32 | **hang**: `INFO: task vtpm-hang-minim:9397 blocked for more than 143 seconds.` — follow-up report shows it STILL blocked at 286 s (log ends there) |
| run 2 | `vtpm-hang-minimal.c` | auto, N=32, same boot as run 1 (no reboot) | **hang**: third report ~120 s after run 1's |
| run 3 | `vtpm-hang-minimal.c` | auto, N=32 (auto-only build, fresh boot) | **hang**: `INFO: task vtpm-hang-minim:9492 blocked for more than 143 seconds.` |
| control 1 | `vtpm-close-minimal.c` | explicit close, N=4 | all four `close()` calls returned in ~0 s, no block |
| control 2 | `vtpm-close-minimal.c` | explicit close, N=32 | all 32 `close()` calls returned in ~0 s, no block |

Reliability of the hang reproducer: **4/4 runs hung** (N=4 once, N=32
three times — the last two on the same guest without a reboot, and the
last one with the final auto-only build). Smaller N is racy: N=1 and
N=2 attempts did not hang (the release can complete before the overlap
happens), which is why the default is N=32.

## Answer to "are you closing the server-side fd from the ioctl?"

**Yes** — both by relying on exit-time close (`vtpm-hang-minimal.c`)
and by explicit `close()` (`vtpm-close-minimal.c`). And when the hang
occurs, the closing task is itself stuck in
`vtpm_proxy_fops_release()` -> `vtpm_proxy_work_stop()` ->
`flush_work()`. Note `vtpm_proxy_work_stop()` calls
`vtpm_proxy_fops_undo_open()` BEFORE `flush_work()` — i.e.
STATE_OPENED_FLAG is cleared and `wake_up_interruptible(&wq)` runs
before the wait — yet in the hanging runs the wait still persisted
>143 s (and >286 s in the follow-up report) while the worker sat in
`tpm_transmit()` (see the sysrq dumps).

The control runs show the flip side: closing well after creation lets
the cancel path (`req_canceled` checks STATE_OPENED_FLAG) win and every
close returns immediately; N=1/N=2 attempts also did not hang. Whether
the cancel path can miss the wake-up for some interleavings is exactly
the kind of question we would like the maintainer's analysis on.

Real-world relevance: any vTPM emulator process that is SIGKILLed or
exits while its chip-register work is running produces exactly this
state — exit-time release is the normal kernel teardown path, not a
test-only construct.

## Folder layout

```
vtpm-hang-minimal.c                 hang reproducer (auto, default N=32)
vtpm-close-minimal.c                explicit-close control experiment
n32-auto-hang/                      N=32 hang runs (3 serials + 2 sysrq;
                                    run 1's sysrq was not captured)
n4-auto-hang/                       run A (N=4): serial + sysrq
explicit-close/                     control runs: serials + close logs
                                    (N=4 and N=32; all closes ~0 s)
small-n-miss/                       N=1 / N=2 attempts: no hang within the
                                    monitoring window (serial slices +
                                    console log of the automated runs)
```

Caveat (unchanged): in every log the window ends while the task is
still blocked, so we do not claim a permanent deadlock.
