#!/bin/bash
# boot.sh <dir> <smp-value> <append-file> <port> <name>
D=$1
S2=$2
A=$3
P=$4
N=$5
cd /workspace/vtpm-jarkko-style/$D || exit 1
exec qemu-system-x86_64 -vga none -m 6144M,slots=2,maxmem=8192M -smp $S2 -display none \
  -no-reboot -name $N -serial file:serial.log -accel kvm -cpu host -device virtio-rng-pci \
  -device e1000,netdev=net0 -netdev user,id=net0,restrict=on,hostfwd=tcp:127.0.0.1:$P-:22 \
  -drive file=root.qcow2,if=ide,format=qcow2 \
  -kernel /workspace/vtpm-patched-test/bzImage-unpatched-7.3 \
  -append "$(cat /workspace/vtpm-jarkko-style/$A)" \
  -drive file=scratch-a.qcow2,if=virtio,format=qcow2 \
  -drive file=scratch-b.qcow2,if=virtio,format=qcow2 \
  -drive file=scratch-c.qcow2,if=virtio,format=qcow2 \
  -drive file=scratch-d.qcow2,if=virtio,format=qcow2 \
  -drive file=scratch-e.qcow2,if=virtio,format=qcow2 \
  -drive file=scratch-logwrites.qcow2,if=virtio,format=qcow2 \
  -drive file=scratch-f.qcow2,if=virtio,format=qcow2 \
  -drive file=scratch-g.qcow2,if=virtio,format=qcow2 \
  -drive file=scratch-h.qcow2,if=virtio,format=qcow2 \
  -object memory-backend-file,id=kspmem0,share=on,mem-path=pmem-0.img,size=1G \
  -device nvdimm,id=kspmemdev0,memdev=kspmem0,node=0 \
  -object memory-backend-file,id=kspmem1,share=on,mem-path=pmem-1.img,size=1G \
  -device nvdimm,id=kspmemdev1,memdev=kspmem1,node=0 \
  -machine nvdimm=on \
  -object memory-backend-ram,id=ksnuma0,size=3072M \
  -object memory-backend-ram,id=ksnuma1,size=3072M \
  -numa node,nodeid=0,cpus=0-1,memdev=ksnuma0 \
  -numa node,nodeid=1,cpus=2-3,memdev=ksnuma1
