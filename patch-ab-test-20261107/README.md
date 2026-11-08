# Patch A/B test + v7.4-rc1 check (2026-11-07)

Follow-up to the release-path stall report (`INFO: task hung in
vtpm_proxy_fops_release`). Two questions were tested with the same
two-step reproduction (49-program state-construction sequence,
`repro/repro.priming.prog`, `procs=1`, `repeat=1`) and the same full QEMU
layout / kernel command line as the main report:

1. Does Stefan Berger's patch
   "tpm: tpm_vtpm_proxy: Set STATE_OPENED_FLAG before inode is created"
   (`0001-tpm-tpm_vtpm_proxy-Set-STATE_OPENED_FLAG-before-inod.patch`,
   forwarded by Jarkko Sakkinen on 2026-11-01) fix the hang?
2. Is v7.4-rc1 affected as well?

## Results

| run                     | kernel                          | result |
|-------------------------|---------------------------------|--------|
| patched A               | 7.3.0-kernsight-kasan #3 + patch | hang, 1/1 run |
| unpatched control A     | 7.3.0-kernsight-kasan #1         | hang, 1/1 run |
| v7.4-rc1                | 7.4.0-rc1-kernsight-kasan+ #3    | hang, 1/1 run |

All three runs hung with the same signature: the executor process exits,
`__fput()` -> `vtpm_proxy_fops_release()` -> `__flush_work()` blocks,
the chip-register work keeps sleeping in `tpm_transmit()` (<-
`vtpm_proxy_request_locality()`, with `__pfx_vtpm_proxy_tpm_req_canceled`
visible in the stack - the cancel callback is registered for the transmit
wait (the stack alone does not tell whether or how often it executed),
behind a workqueue
backlog of dozens of `vtpm_proxy_work` instances, while the serial log
shows repeated `tpm tpmN: Operation Timed out`.

- patched run:     t=414s first hung-task report (143 s), t=434s (163 s)
- unpatched run:   t=387s first hung-task report (143 s)
- v7.4-rc1 run:    t=376s `tpm tpm0: Operation Timed out`,
                   t=402s first hung-task report (143 s)

Conclusion: the patch does not eliminate this hang. Our reproducer gives
no evidence that the udev / STATE_OPENED_FLAG race is involved in this run
(it never opens the server-side anon-inode fd from another process),
though other orderings cannot be ruled out. The current mainline
(v7.4-rc1) is affected as well. `drivers/char/tpm/tpm_vtpm_proxy.c` is
byte-identical between v7.3.0 and v7.4-rc1 (empty diff).

Note: an earlier ~30h automated campaign on v7.4-rc1 that did not hit the
hang used a bare QEMU layout (root disk only); per the 2x2 experiment in
the main README a bare layout does not reproduce this hang, so that
negative result is not meaningful. The v7.4-rc1 run above uses the full
layout.

## Files

```
TEST-REPORT.txt                   full test report (Chinese), incl. build details
0001-tpm-tpm_vtpm_proxy-Set-STATE_OPENED_FLAG-before-inod.patch  tested patch
serial-7.3-patched.log            patched-kernel run (two hung-task reports)
sysrq-t-7.3-patched-excerpts.txt  worker stack + workqueue backlog (patched;
                                  captured live, excerpt form)
serial-7.3-unpatched-ctrl.txt     unpatched control run (same session)
sysrq-t-7.3-unpatched-ctrl.txt    control sysrq-t dump
serial-7.4-rc1.log                v7.4-rc1 run (hung-task report)
sysrq-t-7.4-rc1.txt               v7.4-rc1 sysrq-t dump
```

## Build / environment details

- Patch applied to vanilla 7.3.0; `drivers/char/tpm/tpm_vtpm_proxy.c` was
  the only modified file. Same kernel configuration as the main report
  (`kernel/kernel-7.3.config`), built with gcc 11.4.0 (Ubuntu 22.04).
- v7.4-rc1 kernel: `7.4.0-rc1-kernsight-kasan+ #3`, built 2026-11-04 from
  the v7.4-rc1 tree with the same toolchain family (pre-existing build,
  not rebuilt for this test; driver identical to v7.3.0).
- QEMU 6.2.0, SeaBIOS 1.15.0-1, i440FX; full layout
  (`cmdline/qemu-args-full-layout.txt`), guest command line
  `cmdline/cmdline-7.3-retest.txt` (`hung_task_panic=0`) for all runs.

The same caveat as the main README applies: in every log the log window
ends while the release task is still blocked, so whether the release
eventually completes once the backlog drains is not captured; we do not
claim a permanent deadlock.
