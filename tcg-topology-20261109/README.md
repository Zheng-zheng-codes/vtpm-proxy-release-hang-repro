# TCG (no KVM) reproduces the reported boot failure exactly (2026-11-09)

While trying to reproduce Jarkko Sakkinen's boot failure (reported
2026-11-01) we first ran the same stack WITH KVM acceleration — QEMU 6.2
and QEMU 10.2.1 (Ubuntu 26.04), full layout, same command lines — and it
never appeared (clean boots every time). The missing variable turned out
to be the accelerator, not the host:

  KVM  (-accel kvm -cpu host):  boots clean, no topology warning
  TCG  (-accel tcg,thread=multi -cpu max):  the warning appears

Both runs below use the same QEMU 10.2.1 (Ubuntu 26.04) stack, the same
unpatched 7.3.0-kernsight-kasan #1 kernel, the same i440FX + NUMA split
(cpuk 0-1 / 2-3 on node 0 / 1) and the same guest command line
(panic_on_warn=1, hung_task_panic=1); only the accelerator and the -cpu
model differ. With TCG the boot fails exactly as reported:

  sched: CPU #2's llc-sibling CPU #0 is not on the same node!
         [node: 1 != 0]. Ignoring dependency.
  WARNING: arch/x86/kernel/smpboot.c:329 at topology_sane.isra.0+0xa3/0xb0,
           CPU#2: swapper/2/0
  Hardware name: QEMU Ubuntu 26.04 PC (i440FX + PIIX, 1996),
                 BIOS 1.17.0-debian-1.17.0-1ubuntu1
  -> Kernel panic (panic_on_warn=1), boot aborted

This is byte-for-byte the warning from the 2026-11-01 report, including
the WARNING offset and the Hardware name. Explanation: with -cpu host
under KVM the cache-topology CPUID leaves largely pass through our host
CPU (Intel Xeon Gold 6326) and the kernel never sees cross-node LLC
siblings; under TCG QEMU synthesizes the topology itself, the guest does
see LLC siblings spanning both NUMA nodes, and topology_sane() warns.

The mitigation holds in TCG as well: with
"-smp 4,sockets=2,cores=2,threads=1" each socket's LLC stays within one
NUMA node, the boot proceeds with no warning
(serial-tcg-fixed-topology.log). So the one-line -smp change makes the
boot robust regardless of the accelerator.

Whether Jarkko's machine ran TCG (no usable /dev/kvm -> no -accel kvm or
a fallback) or a host CPU whose KVM CPUID passthrough enumerates LLC
differently cannot be determined from his report, but the TCG condition
above reproduces his failure exactly on our side and is a concrete,
checkable hypothesis.

## Files

```
serial-tcg-hit.log             TCG boot: topology warning + panic (the
                               reported failure, reproduced)
serial-tcg-fixed-topology.log  TCG boot with sockets=2/cores=2: clean boot
boot-tcg.sh                    TCG launch wrapper (flat -smp 4)
boot-tcg-fixed.sh              TCG launch wrapper with the -smp mitigation
```

Update (same day): this TCG condition is the concrete reproduction of the reported boot failure; see above.

Scratch disks were omitted in these boot-only tests (the warning fires
during SMP bringup, long before any block device matters); everything
else matches the full layout used by the scripts in ../scripts/.
