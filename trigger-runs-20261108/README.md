# Automated trigger runs (2026-11-08): unpatched vs. patched kernel

Both one-shot trigger scripts (../scripts/) were executed back-to-back in
the kernsight container environment (QEMU 6.2.0, full layout, guest
command line per cmdline/cmdline-7.3-retest.txt with hung_task_panic=0,
two-step reproduction). Each run ends with the script's sysrq-t capture
when the hung-task report appears.

| run       | kernel                          | result | first hung-task report                    |
|-----------|---------------------------------|--------|-------------------------------------------|
| unpatched | 7.3.0-kernsight-kasan #1        | HIT    | t=437s: task syz.0.26:10767, 143 seconds  |
| patched   | 7.3.0-kernsight-kasan #3 (patch)| HIT    | t=453s: task syz.0.26:10779, 143 seconds  |

Both serial logs show repeated "tpm tpmN: Operation Timed out" while the
release is blocked; both sysrq dumps show the tpm-vtpm workqueue backlog
(unpatched: in-flight 54s + 15*vtpm_proxy_work BAR(10767); patched:
in-flight 48s + 62*vtpm_proxy_work BAR(10758) on one pwq, second pwq
active). This is consistent with the A/B result in
patch-ab-test-20261107/: Stefan Berger's STATE_OPENED_FLAG patch does not
change the outcome in this environment.

## Files

```
unpatched/serial-unpatched.log     guest serial log (kernel #1)
unpatched/sysrq-t-dump.txt         sysrq-t capture at detection (kernel #1)
unpatched/console-unpatched.log    script console output (monitoring timeline)
patched/serial-patched.log         guest serial log (kernel #3, patched)
patched/sysrq-t-dump.txt           sysrq-t capture at detection (kernel #3)
patched/console-patched.log        script console output
```

The scripts are in ../scripts/; run logs reference the workdir
/data/zhengzheng/kernsight/vtpm-trigger-<timestamp>/ on the test host.
