# Jarkko-style boot check (2026-11-07): topology warning vs. the hang

Jarkko Sakkinen reported (2026-11-01) that booting with the suggested QEMU
command line fails for him with

    sched: CPU #2's llc-sibling CPU #0 is not on the same node! [node: 1 != 0]
    WARNING: arch/x86/kernel/smpboot.c:329 at topology_sane.isra.0

on "QEMU Ubuntu 26.04 ... BIOS 1.17.0-debian" — our suggested guest command
line contains panic_on_warn=1, so the warning aborts his boot before the
reproduction can run.

These runs separate the two variables on our side (QEMU 6.2.0, SeaBIOS
1.15.0-1; unpatched 7.3.0-kernsight-kasan #1 for both runs; full layout;
the exact guest command lines from cmdline/):

1. serial-nofix-sockets1.log — boot with `-smp 4,sockets=1,cores=4,threads=1`
   (forces all four CPUs into one socket/LLC domain while the NUMA split
   puts CPUs 0-1 / 2-3 on different nodes — the exact condition his QEMU
   warns about), with the original suggested guest command line
   (cmdline-7.3.txt, panic_on_warn=1).

   Result: no topology warning, boot proceeds (log ends mid-boot; the
   warning count is 0). On QEMU 6.2 the kernel does not see cross-node LLC
   siblings at all — the warning is a property of newer QEMU's cache
   topology enumeration, not of the bug and not of the guest command line.

2. serial-fix-topology.log + sysrq-t-fix-topology.txt — boot with the
   suggested fix `-smp 4,sockets=2,cores=2,threads=1` (each socket's LLC
   stays within one NUMA node), guest command line
   cmdline-7.3-retest.txt (hung_task_panic=0). Then the two-step
   reproduction (repro/repro.priming.prog).

   Result: boots clean (warning count 0) AND the hang still reproduces:
   t=426s `INFO: task syz.0.26:10754 blocked for more than 143 seconds.`
   with the release blocked in flush_work(); sysrq-t shows the tpm-vtpm
   workqueue backlog (in-flight 9816:vtpm_proxy_work for 101s,
   inactive: 64*vtpm_proxy_work BAR(12534)).

So: with the one-line QEMU change, Jarkko's boot failure goes away on any
QEMU version, and the hang reproduces under the fixed topology as well.
(QEMU 26.04-version parity was attempted — docker pull of ubuntu:26.04
succeeded, but its apt archive was unreachable from this network, so the
newer-QEMU side could not be run locally; run 1 above is the closest
achievable stand-in and supports the same conclusion from the other
direction.)

## Files

```
serial-nofix-sockets1.log   run 1: sockets=1,cores=4 topology, original
                            suggested cmdline — no topology warning (QEMU 6.2)
serial-fix-topology.log     run 2: sockets=2,cores=2 fix topology — clean boot,
                            hang reproduces (t=426s)
sysrq-t-fix-topology.txt    run 2 sysrq-t dump (workqueue backlog)
boot.sh                     exact QEMU launch wrapper used for both runs
                            (kernel: bzImage-unpatched-7.3 = 7.3.0-kernsight-kasan #1)
```

Guest command lines are byte-identical to `cmdline/cmdline-7.3.txt` (run 1)
and `cmdline/cmdline-7.3-retest.txt` (run 2); the only QEMU delta vs. the
main report's `cmdline/qemu-args-full-layout.txt` is the `-smp` value.

Same caveat as the main README: the log window ends while the release task
is still blocked; we do not claim a permanent deadlock.
