# vTPM proxy release-path hang (`vtpm_proxy_fops_release`) — reproducers

This repository contains the reproducers and logs for:

```
INFO: task hung in vtpm_proxy_fops_release
```

A process closing the "server side" of a vTPM proxy device blocks in
`vtpm_proxy_fops_release()` -> `vtpm_proxy_work_stop()` -> `flush_work()`
while the chip-register work (`vtpm_proxy_work` -> `tpm_chip_register()`)
is still running inside a `tpm_transmit()` retry loop
(`tpm_chip_start() -> vtpm_proxy_request_locality()`), waiting for the
vtpm fd counterpart, which is the exiting process itself. The guest serial
log shows repeated `tpm tpm3: Operation Timed out` /
`tpm tpm31: Operation Timed out`; after the transmit retries are exhausted
the work completes with an error, `flush_work()` returns and the release
path finishes. We therefore observe a multi-minute stall of the release
path (hung-task reports at 143 s and 163 s) followed by recovery, not a
permanent deadlock.

## Tested kernels

| Kernel | Release | Notes |
|---|---|---|
| 7.3.0 | `7.3.0-kernsight-kasan #1` | vanilla 7.3.0 source (tarball sha256 `87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953`), KASAN/KCOV build |

No TPM changes were made for this testing
(`drivers/char/tpm/` matches vanilla apart from build artifacts).

Kernel config: `kernel/kernel-7.3.config`.
Kernel command lines: `cmdline/cmdline-7.3.txt` (syzkaller standard set)
and `cmdline/cmdline-7.3-retest.txt` (verification variant with
`hung_task_panic=0` so the hang can be inspected live).

## Observed results

| Environment | Runs | Hang observed |
|---|---|---|
| syzkaller campaign VM (standard QEMU environment) | 4 crash instances over a multi-day campaign | yes (log/report 0..3) |
| automated state-primed reproduction (syzkaller `-mode repro`) | 1 | yes, `verified=true` (`logs/serial-7.3-auto-repro.log`) |
| manual replay of the same sequence in the same QEMU environment | 1 | yes (`logs/serial-7.3-manual-repro.log`) |
| bare fresh VM (no scratch disks / pmem / NUMA layout), same sequence | 4 | no (`logs/serial-7.3-bare-no-trigger-*.log`) |

The reproducer appears timing sensitive: it reproduced reliably in the
syzkaller QEMU environment but did not trigger on a bare VM. We have not
isolated which environmental factors matter.

## How to reproduce

1. Boot a guest with the kernel above (command line in `cmdline/`;
   use `hung_task_panic=0` to inspect the hang live).
2. From the host, copy the executor and the reproducer sequence:

   ```bash
   scp syz-execprog syz-executor repro.kernsight.prog root@guest:/tmp/
   ssh root@guest
   cd /tmp && chmod +x syz-execprog syz-executor
   ./syz-execprog -executor=/tmp/syz-executor -procs=1 -repeat=1 /tmp/repro.kernsight.prog
   ```

3. The sequence contains 49 programs, replayed by a single executor process
   (`procs=1`, `repeat=1`, `sandbox=none`). The hang appears when the
   executor process exits: the hung-task monitor reports
   `INFO: task syz.0.33 ... blocked for more than 143 seconds` at
   t≈260-280 s (`logs/serial-7.3-manual-repro.log`).
4. While the task is blocked, capture the full task dump from inside the
   guest — this shows what the chip-register work is doing:

   ```bash
   echo t > /proc/sysrq-trigger
   dmesg > dump.txt       # see logs/vtpm-sysrq-t-all-tasks.txt
   ```

   Expected: `kworker/X:Y+tpm-vtpm` in state `D` with
   `tpm_transmit() <- vtpm_proxy_request_locality() <- tpm_chip_start()
   <- tpm_chip_bootstrap() <- tpm_chip_register() <- vtpm_proxy_work()`.
5. After the tpm transmit timeouts (`tpm tpmN: Operation Timed out`) the
   sequence exits normally (`EXIT:0` in the execprog output).

Notes:

- `repro/repro.prog` (the minimized syz program) does **not** trigger on
  its own; the state built by the preceding programs of the sequence is
  required. Use `repro/repro.kernsight.prog` (the full 49-program
  sequence, executed in file order).
- `repro/repro.cprog` is the generated C reproducer for the full sequence
  (compiles with `gcc -x c -O2 -pthread -o repro repro.cprog`).

## Repository layout

```
repro/repro.kernsight.prog        49-program sequence (the reproducer)
repro/repro.prog                  minimized syz program (does not trigger alone)
repro/repro.cprog                 generated C reproducer for the sequence
logs/vtpm-sysrq-t-all-tasks.txt   sysrq-t task dump with the kworker stack
logs/serial-7.3-manual-repro.log  manual replay: hung task + tpm timeouts + recovery
logs/serial-7.3-auto-repro.log    automated state-primed reproduction (verified=true)
logs/serial-7.3-bare-no-trigger-*.log  4 bare-VM runs (no trigger)
logs/report-7.3-*.txt, logs/log-7.3-*.txt  the 4 campaign instances
logs/crash-title.txt              crash title
kernel/kernel-7.3.config          kernel configuration
cmdline/cmdline-7.3*.txt          kernel command lines
verify.sh                         re-checks the numbers quoted in the report
MANIFEST.sha256                   sha256 of every file
```
