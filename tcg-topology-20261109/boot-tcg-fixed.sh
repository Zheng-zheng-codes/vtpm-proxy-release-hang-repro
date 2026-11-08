#!/bin/bash
# TCG (no KVM) boot test with QEMU 10.2.1 — check for the llc-sibling warning
cd /workspace/vtpm-tcg-test/vm || exit 1
exec qemu-system-x86_64 -vga none -m 6144M,slots=2,maxmem=8192M -smp 4,sockets=2,cores=2,threads=1 -display none \
  -no-reboot -name vtpm-tcg-test -serial file:serial.log -pidfile qemu.pid \
  -accel tcg,thread=multi -cpu max -device virtio-rng-pci \
  -device e1000,netdev=net0 -netdev user,id=net0,restrict=on \
  -drive file=root.qcow2,if=ide,format=qcow2 \
  -kernel /workspace/vtpm-patched-test/bzImage-unpatched-7.3 \
  -append "$(cat /workspace/vtpm-q26/cmdline-7.3-guest.txt)" \
  -machine nvdimm=on \
  -object memory-backend-file,id=kspmem0,share=on,mem-path=/dev/shm/tcg-pmem0,size=1G \
  -device nvdimm,id=kspmemdev0,memdev=kspmem0,node=0 \
  -object memory-backend-ram,id=ksnuma0,size=3072M \
  -object memory-backend-ram,id=ksnuma1,size=3072M \
  -numa node,nodeid=0,cpus=0-1,memdev=ksnuma0 \
  -numa node,nodeid=1,cpus=2-3,memdev=ksnuma1
