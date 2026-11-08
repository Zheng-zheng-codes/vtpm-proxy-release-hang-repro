# QEMU 10.2.1 (Ubuntu 26.04) parity run (2026-11-08)

Jarkko Sakkinen reported (2026-11-01) that booting the suggested QEMU
command line fails on his side with a CPU-topology warning:

    sched: CPU #2's llc-sibling CPU #0 is not on the same node! [node: 1 != 0]
    WARNING: arch/x86/kernel/smpboot.c:329 at topology_sane.isra.0
    Hardware name: QEMU Ubuntu 26.04 PC (i440FX + PIIX, 1996),
                   BIOS 1.17.0-debian-1.17.0-1ubuntu1

We built a QEMU stack as close to his as visible from his report — Ubuntu
26.04.1 container, QEMU 10.2.1 (Debian 1:10.2.1+ds-1ubuntu3.3, the version
currently shipped by the 26.04 archive), seabios 1.17.0-1ubuntu1 — and
re-ran his attempt verbatim: unpatched 7.3.0-kernsight-kasan #1, flat
"-smp 4", the full device layout and the original suggested guest command
line (cmdline-7.3.txt, i.e. hung_task_panic=1). Note his exact QEMU
micro-version is not visible in his report: the "Hardware name" string
pins the distro (Ubuntu 26.04) and the BIOS version string pins seabios
1.17.0-1ubuntu1 (identical to ours), but not the QEMU package version.
Two results:

1. The topology warning does NOT appear on our host: the guest boots
   clean (no "llc-sibling" / topology_sane messages anywhere in the
   serial log) even though QEMU and BIOS now match his versions
   byte-for-byte ("Hardware name: QEMU Ubuntu 26.04 PC (i440FX + PIIX,
   1996), BIOS 1.17.0-debian-1.17.0-1ubuntu..."), so distro and BIOS
   match his report (his exact QEMU micro-version is unknown). Combined
   with the
   earlier check (jarkko-style-boot-20261107/): forcing the cross-node
   LLC condition explicitly on QEMU 6.2 also produces no warning. Since
   we could not reproduce the warning even with this QEMU stack, we
   cannot determine its exact cause from our side; it may
   be specific to his host environment. UPDATE (2026-11-09): reproduced
   without KVM acceleration - see tcg-topology-20261109/. The one-line
   mitigation ("-smp 4,sockets=2,cores=2,threads=1") boots clean on our
   hosts and is a reasonable thing to try.

2. The hang reproduces on his exact QEMU version anyway, and — because
   the suggested command line has hung_task_panic=1 — the guest panics
   with the full report:

     t=350s INFO: task syz.0.26:10729 blocked for more than 143 seconds.
            7.3.0-kernsight-kasan #1
            blocked in vtpm_proxy_fops_release() -> __flush_work()
     t=350s Kernel panic - not syncing: hung_task: blocked tasks

   (two-step reproduction: repro/repro.priming.prog, procs=1, repeat=1;
   the hang appears when the priming executor process exits.)

Side note for anyone re-running from cmdline/: the file
cmdline/cmdline-7.3.txt is the captured full QEMU invocation (its
-append value is the guest command line), not a bare kernel command
line. Feeding the whole file to -append makes the guest command line
2049 bytes, which trips a fortify check in the kernel
("strlen: detected buffer overflow: 2049 byte read of buffer size 2048",
lib/string_helpers.c, kernel BUG at boot) before anything else runs.
Use only the -append value.

## Files

```
serial-q26-jarkko-flat-smp4.log  Ubuntu 26.04 / QEMU 10.2.1 run: clean boot,
                                 no topology warning, hang + hung_task panic
                                 at t=350s (unpatched 7.3.0-kernsight-kasan #1)
boot-q26.sh                      exact QEMU launch wrapper (only delta vs.
                                 cmdline/qemu-args-full-layout.txt: -serial
                                 file:... instead of stdio; no SOCKSYZ chardev,
                                 which is manager RPC and not needed)
```

Guest command line = the -append value of cmdline/cmdline-7.3.txt
(hung_task_panic=1). Environment: Ubuntu 26.04.1 container, QEMU 10.2.1,
seabios 1.17.0-1ubuntu1, KVM, host Intel Xeon Gold 6326 (-cpu host),
full device layout per cmdline/qemu-args-full-layout.txt.
