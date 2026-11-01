# vTPM proxy release-path stall (`vtpm_proxy_fops_release`) — reproducer

This repository contains the reproducer and logs for:

```
INFO: task hung in vtpm_proxy_fops_release
```

A process closing the "server side" of a vTPM proxy device blocks in
`vtpm_proxy_fops_release()` -> `vtpm_proxy_work_stop()` -> `flush_work()`
while `vtpm_proxy_work` (the chip-register work,
`tpm_chip_register()`) is still running inside a `tpm_transmit()` loop
(`tpm_chip_start() -> vtpm_proxy_request_locality()`). The guest serial
log shows repeated `tpm tpm3: Operation Timed out` /
`tpm tpm31: Operation Timed out` lines while the release is blocked.

Additional observations from the sysrq-t task dumps:

- The full call stack of the running chip-register work was captured in
  the first dump (`logs/vtpm-sysrq-t-all-tasks.txt`); in the two later
  dumps the kworker stack no longer fit in the kernel log buffer, but the
  workqueue state shows the backlog:

  ```
  workqueue tpm-vtpm: flags=0x40108
    pwq 6: cpus=1 node=0 active=1 refcnt=33
      in-flight: 24:vtpm_proxy_work for 75s
      inactive: 4*vtpm_proxy_work BAR(10837), 26*vtpm_proxy_work
  ```

  (`logs/dmesg-sysrq-verify4.txt`: `in-flight: ... for 109s`,
  `inactive: 29*vtpm_proxy_work BAR(10857)`.) Because of the backlog we
  cannot tell which queued work the blocked release is actually waiting
  for.

- The blocked release was observed through two different entry paths:
  process exit (`do_exit()` -> `task_work_run()` -> `__fput()`) in the
  campaign reports, the automated reproduction, manual replays A and C;
  and a `close_range()` returning to user space
  (`task_work_run()` -> `__fput()`) in manual replay B
  (`logs/dmesg-sysrq-verify3.txt`).

Whether the release eventually completes was **not** captured: the logs
end while the task is still blocked. We are not claiming a permanent
deadlock either; the duration of the stall beyond the log window is
unknown.

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

| Run | Record of the hang |
|---|---|
| syzkaller campaign, standard QEMU environment (4 instances over a multi-day campaign) | `logs/log-7.3-*.txt`, `logs/report-7.3-*.txt` |
| automated replay of the stored sequence (`syzkaller -mode repro`); observed hang | `logs/serial-7.3-auto-repro.log` |
| manual replay A | `logs/serial-7.3-manual-repro.log`, sysrq-t dump `logs/vtpm-sysrq-t-all-tasks.txt` |
| manual replay B | sysrq-t dump `logs/dmesg-sysrq-verify3.txt` |
| manual replay C | `logs/serial-verify4.log`, syz-execprog output `logs/execprog-verify4.out`, sysrq-t dump `logs/dmesg-sysrq-verify4.txt` |
| two-step reproduction (state construction, then the crashing testcase; hang at the step-1 executor exit) | `logs/serial-twostep.log`, `logs/execprog-twostep-step1.out`, sysrq-t dump `logs/dmesg-sysrq-twostep.txt` |
| bare fresh VMs, different command line, no scratch disks / pmem / NUMA layout (4 runs) | no hang recorded (`logs/serial-7.3-bare-no-trigger-*.log`) |

The bare-VM runs differ from the positive runs in the kernel command line
as well as in the QEMU device layout, so they only show that no hang was
recorded in those runs; the effect of the environment cannot be isolated
from them.

## Reproduction steps

Two equivalent ways have been verified. Method B (two-step) is the
simplest: the hang appears when the state-construction sequence's
executor process exits.

1. Build / obtain the kernel above and boot a guest from it. Use the
   command line from `cmdline/cmdline-7.3.txt` (or the
   `cmdline/cmdline-7.3-retest.txt` variant, `hung_task_panic=0`, to
   inspect the hang live). The guest needs no extra setup.

2. From the host, copy the executor binaries and the reproducer programs
   into the guest (all files below are in this repository, see
   `MANIFEST.sha256`):

   ```bash
   scp syz-execprog syz-executor repro.priming.prog repro.prog root@guest:/tmp/
   ssh root@guest
   cd /tmp && chmod +x syz-execprog syz-executor
   ```

### Method B (two-step, verified 1/1 -- `logs/serial-twostep.log`)

3. Run the state-construction sequence (49 programs) once:

   ```bash
   ./syz-execprog -executor=/tmp/syz-executor -procs=1 -repeat=1 /tmp/repro.priming.prog
   ```

   It parses as 49 programs, runs for ~20 s and exits normally
   (`EXIT:0`, `logs/execprog-twostep-step1.out`). When its executor
   process exits, the vtpm fds it holds are released, and the release
   path hangs: the hung-task monitor reports

   ```
   INFO: task syz.0.33:10843 blocked for more than 143 seconds.   (t≈267 s)
   ```

   while `ps` shows `kworker/X:Y+tpm-vtpm` and the executor task both in
   state `D` (see `logs/dmesg-sysrq-twostep.txt`). The serial log shows
   `tpm tpm1/tpm2: Operation Timed out` while the release is blocked.

4. Optionally run the crashing testcase afterwards
   (`./syz-execprog -executor=/tmp/syz-executor -procs=1 -repeat=1
   /tmp/repro.prog`); on the already-blocked VM it simply runs and exits.

### Method A (single sequence file, verified 3/3: automated 1/1, manual 2/2)

Run the full sequence (state construction + crashing testcase as the
50th program) with a single executor process, one pass:

   The file is `repro/repro.kernsight.prog` (sha256 `b9740e789ed9...`,
   byte-identical to the file used in the runs whose logs are included).
   It parses as 50 programs (`logs/execprog-verify4.out`: `parsed 50
   programs`) and is replayed one at a time in file order (`procs=1`,
   `repeat=1`, `sandbox=none`). Programs run sequentially, but a program
   can leave asynchronous kernel-side work (workqueues, timers, devices)
   behind. The sequence creates several vTPM proxy devices and
   closes/exits over them; the hang appears when a closing task's
   release path races a still-running (or queued) chip-register work.

4. Expected timeline (see `logs/serial-verify4.log`):

   - the sequence finishes executing; the closing task blocks in
     `flush_work()` (drivers/char/tpm/tpm_vtpm_proxy.c:471, reached from
     `vtpm_proxy_fops_release()`:239).
   - t≈480 s: the hung-task monitor reports

     ```
     INFO: task syz.0.33:10857 blocked for more than 143 seconds.
     ```

     (t≈504 s: the 163 s report).
   - the task remains blocked while
     `tpm tpm3: Operation Timed out` / `tpm tpm31: Operation Timed out`
     lines appear in the log. When the log window ends (all included
     logs) the task is still blocked; we have no log evidence of the
     release completing.

5. While the task is blocked, capture what the chip-register work is
   doing from inside the guest:

   ```bash
   echo t > /proc/sysrq-trigger
   dmesg > dump.txt
   ```

   Expected (see the dumps): a kworker named `kworker/X:Y+tpm-vtpm` in
   state `D`:

   ```
   Workqueue: tpm-vtpm vtpm_proxy_work
   Call Trace:
     tpm_transmit+0x4bf/0xb90
     tpm_transmit_cmd+0x62/0x1f0
     vtpm_proxy_request_locality+0x140/0x280
     tpm_chip_start+0x18f/0x340
     tpm_chip_bootstrap+0x80/0x1c0
     tpm_chip_register+0x27/0x4d0
     vtpm_proxy_work+0x41/0x100
     process_one_work+0xa9c/0x1dc0
   ```

   plus the workqueue backlog shown above, and the blocked release in
   `vtpm_proxy_fops_release()`.

## Notes

- The hang is timing sensitive: it reproduced in the syzkaller QEMU
  environment in every attempt, but not in 4 runs on a bare VM whose
  command line and device layout differed (see the caveat above). If a
  run does not hang, re-run the sequence.
- The hang was observed through two entry paths (process exit and
  `close_range()`); we have not established which entry paths can or
  cannot trigger it beyond these runs.
- What each dump shows:
  - manual replay A (`logs/vtpm-sysrq-t-all-tasks.txt`): full stack of the
    running register work (kworker/2:3) + blocked release + backlog
    (`in-flight: 9703:vtpm_proxy_work for 38s`,
    `inactive: 24*vtpm_proxy_work BAR(10900)`).
  - manual replay B (`logs/dmesg-sysrq-verify3.txt`): backlog + blocked
    release; the running worker's stack had rotated out of the kernel log
    buffer (`ps` at that moment showed `kworker/1:0+tpm-vtpm` in state D).
  - manual replay C (`logs/dmesg-sysrq-verify4.txt`): backlog
    (`in-flight: ... for 109s`, `inactive: 29*vtpm_proxy_work
    BAR(10857)`) + blocked release; the log lists the running worker as
    `locks held by kworker/3:2/1235: 2, on CPU#3`. Because of the
    backlog, the correspondence between the blocked release and any
    specific queued work is unconfirmed.
- `vtpm_proxy_tpm_req_canceled()` (the transmit cancel callback) already
  exists in the driver; from the captured stacks we cannot tell why the
  wait nevertheless persists. See the question in the report mail.

## Repository layout

```
repro/repro.priming.prog          state-construction sequence (49 programs)
repro/repro.prog                  crashing testcase (use after the priming run)
repro/repro.kernsight.prog        single-file form: priming + testcase (50 programs)
logs/vtpm-sysrq-t-all-tasks.txt   sysrq-t dump: kworker stack + backlog (run 1)
logs/dmesg-sysrq-verify3.txt      sysrq-t dump: backlog, close_range entry path
logs/dmesg-sysrq-verify4.txt      sysrq-t dump: backlog, do_exit entry path
logs/serial-7.3-auto-repro.log    automated state-primed reproduction
logs/serial-7.3-manual-repro.log  manual replay, run 1
logs/serial-verify4.log           manual replay, run 2 (serial)
logs/serial-twostep.log, logs/execprog-twostep-step1.out  two-step reproduction
logs/dmesg-sysrq-twostep.txt      sysrq-t dump of the two-step run
logs/execprog-verify4.out         syz-execprog stdout ("parsed 50 programs")
logs/serial-7.3-bare-no-trigger-*.log  4 bare-VM runs (no hang recorded)
logs/report-7.3-*.txt, logs/log-7.3-*.txt  the 4 campaign instances
logs/crash-title.txt              crash title
kernel/kernel-7.3.config          kernel configuration
cmdline/cmdline-7.3.txt           kernel command line (syzkaller standard set)
cmdline/cmdline-7.3-retest.txt    verification variant (hung_task_panic=0)
verify.sh                         re-checks the numbers quoted in this report
MANIFEST.sha256                   sha256 of every file (except itself)
```
