# vTPM proxy release-path hang (`vtpm_proxy_fops_release`) — reproducer

This repository contains the reproducer and logs for:

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
| manual replay of the same sequence in the same QEMU environment | 2 | yes, 2/2 (`logs/serial-7.3-manual-repro.log`, `logs/serial-verify3.log`) |
| bare fresh VM (no scratch disks / pmem / NUMA layout), same sequence | 4 | no (`logs/serial-7.3-bare-no-trigger-*.log`) |

The reproducer appears timing sensitive: it reproduced reliably in the
syzkaller QEMU environment but did not trigger on a bare VM. We have not
isolated which environmental factors matter. A minimized single program
does not reproduce on its own either; the state built by the preceding
programs of the sequence is required, so the reproducer is the full
sequence below.

## Reproduction steps

1. Build / obtain the kernel above and boot a guest from it. Use the
   command line from `cmdline/cmdline-7.3.txt` (or the
   `cmdline/cmdline-7.3-retest.txt` variant, `hung_task_panic=0`, to
   inspect the hang live). The guest needs no extra setup.

2. From the host, copy the two executor binaries and the reproducer
   sequence into the guest:

   ```bash
   scp syz-execprog syz-executor repro.kernsight.prog root@guest:/tmp/
   ssh root@guest
   cd /tmp && chmod +x syz-execprog syz-executor
   ```

3. Run the sequence with a single executor process, one pass:

   ```bash
   ./syz-execprog -executor=/tmp/syz-executor -procs=1 -repeat=1 /tmp/repro.kernsight.prog
   ```

   `repro.kernsight.prog` contains 49 programs, replayed one at a time in
   file order (`procs=1`, `repeat=1`, `sandbox=none`). The sequence first
   creates several vTPM proxy devices (and other state), then the final
   program's process exits.

4. Expected timeline (see `logs/serial-7.3-manual-repro.log`):

   - t≈135 s: the sequence finishes executing; the executor process exits
     and closes its vtpm fds.
   - t≈260 s: the hung-task monitor reports

     ```
     INFO: task syz.0.33:10854 blocked for more than 143 seconds.
           Blocked by coredump.
     ```

     with the release path stuck in `flush_work()` (trace below).
   - t≈470 s: `tpm tpm3: Operation Timed out` / `tpm tpm31: Operation
     Timed out`; the transmit retries are exhausted, the work finishes,
     `flush_work()` returns and the reproducer exits normally
     (`EXIT:0`). Recovery after minutes is reproducible.

5. While the task is blocked (between the 143 s report and the recovery),
   capture what the chip-register work is doing from inside the guest:

   ```bash
   echo t > /proc/sysrq-trigger
   dmesg > dump.txt
   ```

   Expected (see `logs/vtpm-sysrq-t-all-tasks.txt`): a kworker named
   `kworker/X:Y+tpm-vtpm` in state `D`:

   ```
   Workqueue: tpm-vtpm vtpm_proxy_work
   Call Trace:
     tpm_transmit+0x4bf/0xb90                <- retry loop (usleep_range_state)
     tpm_transmit_cmd+0x62/0x1f0
     vtpm_proxy_request_locality+0x140/0x280 <- locality via the proxy
     tpm_chip_start+0x18f/0x340
     tpm_chip_bootstrap+0x80/0x1c0
     tpm_chip_register+0x27/0x4d0
     vtpm_proxy_work+0x41/0x100
     process_one_work+0xa9c/0x1dc0
   ```

   while the exiting task is blocked in
   `vtpm_proxy_fops_release() -> vtpm_proxy_delete_device() ->
   vtpm_proxy_work_stop() -> flush_work()`
   (drivers/char/tpm/tpm_vtpm_proxy.c:239/590/470/471).

## Notes

- The hang is timing sensitive: it reproduced reliably in the syzkaller
  QEMU environment (with scratch disks and pmem/NUMA layout) but not on a
  bare VM. If a run does not hang, simply re-run the sequence.
- The sequence creates several vtpm devices; the recovery log shows two
  chips ("tpm3" and "tpm31") timing out.
- A generated C reproducer for this sequence compiles but does not
  reproduce the hang (it loops in a single process and does not go
  through the executor's exit path); it is therefore not included.
  See `logs/serial-7.3-c-repro-no-trigger.log` for the negative runs.

## Repository layout

```
repro/repro.kernsight.prog        49-program sequence (the reproducer)
logs/vtpm-sysrq-t-all-tasks.txt   sysrq-t task dump with the kworker stack
logs/serial-7.3-manual-repro.log  manual replay: hung task + tpm timeouts + recovery
logs/serial-7.3-auto-repro.log    automated state-primed reproduction (verified=true)
logs/serial-verify3.log, logs/dmesg-sysrq-verify3.txt  second manual replay + task dump
logs/serial-7.3-c-repro-no-trigger.log  C reproducer runs (no trigger)
logs/serial-7.3-bare-no-trigger-*.log   4 bare-VM runs (no trigger)
logs/report-7.3-*.txt, logs/log-7.3-*.txt  the 4 campaign instances
logs/crash-title.txt              crash title
kernel/kernel-7.3.config          kernel configuration
cmdline/cmdline-7.3.txt           kernel command line (syzkaller standard set)
cmdline/cmdline-7.3-retest.txt    verification variant (hung_task_panic=0)
verify.sh                         re-checks the numbers quoted in this report
MANIFEST.sha256                   sha256 of every file
```
