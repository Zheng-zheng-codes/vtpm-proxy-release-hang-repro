#!/usr/bin/env bash
# ============================================================================
# vtpm-hang-trigger.sh — one-shot trigger + observation of the vTPM
#                        release-path hang
#
# Expected phenomenon: after the state-construction sequence's executor
#   process exits and releases the /dev/vtpm "server side" fds, the
#   release path blocks in
#     vtpm_proxy_fops_release() -> vtpm_proxy_work_stop() -> flush_work()
#   while the chip-register work on the tpm-vtpm workqueue keeps timing
#   out in tpm_transmit() (the serial log repeats "tpm tpmN: Operation
#   Timed out"); after ~143 s the hung-task monitor reports
#     INFO: task ... blocked for more than 143 seconds.
#
# Usage:
#   bash vtpm-hang-trigger.sh              # container mode (default)
#   bash vtpm-hang-trigger.sh -k           # shut the VM down when done
#   MODE=native bash vtpm-hang-trigger.sh  # run on your own host
#
# Environment variables:
#   MODE=container|native   container: QEMU/ssh run via docker exec (default)
#   CONTAINER=kernsight     container name (container mode)
#   PORT=12740              guest ssh port (hostfwd)
#   PANIC=1                 guest cmdline uses hung_task_panic=1 (kernel
#                           panics with the full report as evidence)
#   MONITOR_MIN=15          serial monitoring window after priming (min)
#   -k                      kill the VM when finished (evidence kept)
#
# NOTE: the run is timing sensitive. If a pass does not trigger the hang,
#       simply run the script again (full configuration: 9/9 triggered).
# ============================================================================
# ============================================================================
# !!! PATHS YOU MUST REVIEW / EDIT — the repo does NOT ship these files !!!
#
# KIMG   kernel bzImage to boot.
#          - MODE=container: a path *inside the container*. The original
#            test host kept its files under a directory mounted at
#            /workspace, hence the /workspace/... defaults below.
#          - MODE=native: a path on your machine, e.g.
#            KIMG=$PWD/arch/x86/boot/bzImage
#        -> Point this at the UNPATCHED v7.3.0 kernel for the reported
#           behavior. To test the PATCHED kernel use
#           vtpm-hang-trigger-patched.sh (which only changes the KIMG
#           default), or point KIMG at your own patched build.
# GIMG   guest root image, RAW format. The script creates a qcow2 overlay
#        on top of it so the image itself stays pristine. The original
#        test host used a Debian trixie syzkaller image (trixie.img) with
#        root ssh access.
# KEY    ssh private key matching the root account inside GIMG.
# SYZDIR directory containing syz-execprog and syz-executor.
# PROG   the state-construction sequence. DEFAULT: the repo's own
#        <script-dir>/../repro/repro.priming.prog — no edit needed as long
#        as that path is visible where scp runs (container-visible in
#        container mode).
#
# => CLONED REPO = NOT DIRECTLY RUNNABLE. On any machine other than the
#    original test host you MUST override at least KIMG/GIMG/KEY/SYZDIR,
#    e.g.:
#      MODE=native KIMG=./bzImage GIMG=./root.raw KEY=./id_rsa \
#        SYZDIR=./syzkaller/bin/linux_amd64 bash vtpm-hang-trigger.sh
#    In container mode the paths must be valid *inside the container*
#    (e.g. put the files under the directory that is bind-mounted into
#    the container).
# ============================================================================
set -u

MODE=${MODE:-container}
CONTAINER=${CONTAINER:-kernsight}
PORT=${PORT:-12740}
MONITOR_MIN=${MONITOR_MIN:-15}
PANIC=${PANIC:-0}
KILL_AFTER=0
for a in "$@"; do [ "$a" = "-k" ] && KILL_AFTER=1; done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TS=$(date +%Y%m%d-%H%M%S)
if [ "$MODE" = container ]; then
  BASE=${BASE:-/data/zhengzheng/kernsight}  # host path == container /workspace
  WORK=$BASE/vtpm-trigger-$TS
  VM=$WORK/vm
  VM_C=/workspace/vtpm-trigger-$TS/vm       # container-side view of $VM
  # vvv test-host defaults, see "PATHS YOU MUST REVIEW / EDIT" above vvv
  KIMG=${KIMG:-/workspace/vtpm-patched-test/bzImage-unpatched-7.3}
  GIMG=${GIMG:-/workspace/vm/trixie.img}
  KEY=${KEY:-/workspace/vtpm-patched-test/trixie.id_rsa}
  SYZDIR=${SYZDIR:-/workspace/syzkaller/bin/linux_amd64}
  PROG=${PROG:-/workspace/validation/vtpm-retest-ws/crash-34b4d156/repro.priming.prog}
else
  WORK=${WORK:-$PWD/vtpm-trigger-$TS}
  VM=$WORK/vm
  VM_C=$VM
  : ${KIMG:?native mode requires KIMG (path to the kernel bzImage)}
  : ${GIMG:?native mode requires GIMG (raw guest root image)}
  : ${KEY:?native mode requires KEY (guest root ssh private key)}
  : ${SYZDIR:?native mode requires SYZDIR (dir with syz-execprog/syz-executor)}
  PROG=${PROG:-$SCRIPT_DIR/../repro/repro.priming.prog}   # repo's own copy
fi

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "FATAL: $*"; exit 1; }

if [ "$MODE" = container ]; then
  run() { docker exec "$CONTAINER" "$@"; }
  run_bg() { docker exec -d "$CONTAINER" bash -c "$1"; }
else
  run() { "$@"; }
  run_bg() { bash -c "$1" & }
fi

# ---------- 0. preflight ----------
if [ "$MODE" = container ]; then
  docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
    || die "container $CONTAINER is not running"
  run test -e /dev/kvm || die "no /dev/kvm inside the container"
  # In container mode every path must be container-visible. If a host-side
  # path happens to live under BASE (host path mounted at /workspace),
  # rewrite it to its container-side form automatically.
  for v in KIMG GIMG KEY SYZDIR PROG; do
    P=${!v}
    if ! run test -r "$P"; then
      C=${P/#$BASE//workspace}
      if run test -r "$C"; then export "$v=$C"; fi
    fi
  done
  run test -r "$KIMG" || die "kernel bzImage not readable in container: $KIMG (set KIMG)"
  run test -r "$PROG" || die "priming program not readable: $PROG (set PROG)"
  run test -r "$SYZDIR/syz-execprog" || die "syz-execprog not found in: $SYZDIR (set SYZDIR)"
  run test -r "$KEY" || die "ssh key not readable: $KEY (set KEY)"
  run test -r "$GIMG" || die "guest image not readable: $GIMG (set GIMG)"
else
  [ -e /dev/kvm ] || die "/dev/kvm does not exist"
  command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed"
  [ -r "$KIMG" ] || die "KIMG not readable: $KIMG"
  [ -r "$GIMG" ] || die "GIMG not readable: $GIMG"
  [ -r "$KEY" ] || die "KEY not readable: $KEY"
  [ -x "$SYZDIR/syz-execprog" ] || die "missing $SYZDIR/syz-execprog"
  [ -r "$PROG" ] || die "priming program not readable: $PROG"
fi
(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":$PORT " \
  && die "port $PORT already in use"
[ -e "$WORK" ] && die "workdir already exists: $WORK"
free -g | awk 'NR==2{exit !($7>=6)}' || die "less than 6G of free memory"
log "preflight OK: mode=$MODE port=$PORT work=$WORK"

# ---------- 1. full disk layout (sizes are part of the trigger recipe) ------
mkdir -p "$VM"
if [ "$MODE" = container ]; then
  run qemu-img create -q -f qcow2 -b "$GIMG" -F raw "$VM_C/root.qcow2" \
    || die "failed to create root overlay"
else
  qemu-img create -q -f qcow2 -b "$GIMG" -F raw "$VM/root.qcow2" \
    || die "failed to create root overlay"
fi
for n in a b; do qemu-img create -q -f qcow2 "$VM/scratch-$n.qcow2" 16G; done
for n in c d e logwrites f g h; do
  qemu-img create -q -f qcow2 "$VM/scratch-$n.qcow2" 12G
done
truncate -s 1G "$VM/pmem-0.img" "$VM/pmem-1.img"
log "disk layout ready (root overlay + 2x16G + 7x12G + 2x1G pmem)"

# ---------- 2. boot the VM (full layout + full cmdline) ----------------------
# guest cmdline = repo cmdline/cmdline-7.3-retest.txt; PANIC=1 -> hung_task_panic=1
HTP=0; [ "$PANIC" = 1 ] && HTP=1
GUEST_CMDLINE="root=/dev/sda console=ttyS0 fstab=no rw earlyprintk=serial net.ifnames=0 oops=panic panic_on_warn=1 panic=86400 hung_task_panic=$HTP softlockup_panic=1 nmi_watchdog=panic sysctl.kernel.hung_task_all_cpu_backtrace=1 sysctl.kernel.panic_on_rcu_stall=1 sysctl.kernel.max_rcu_stall_to_panic=1 rcupdate.rcu_expedited=1 rcupdate.rcu_cpu_stall_cputime=1 no_hash_pointers page_owner=on sysctl.vm.nr_hugepages=4 sysctl.vm.nr_overcommit_hugepages=4 secretmem.enable=1 msr.allow_writes=off coredump_filter=0xffff vsyscall=native kvm-intel.nested=1 spec_store_bypass_disable=prctl nopcid vivid.n_devs=64 vivid.multiplanar=1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2 netrom.nr_ndevs=32 rose.rose_ndevs=32 smp.csd_lock_timeout=100000 watchdog_thresh=55 workqueue.watchdog_thresh=140 sysctl.net.core.netdev_unregister_timeout_secs=140 dummy_hcd.num=16 max_loop=32 nbd.nbds_max=32 comedi.comedi_num_legacy_minors=4 kunit.autorun=0 vcan.echo=1"

QEMU_ARGS="-vga none -m 6144M,slots=2,maxmem=8192M -smp 4 -display none \
 -no-reboot -name vtpm-trigger-$TS -serial file:serial.log -pidfile qemu.pid \
 -accel kvm -cpu host -device virtio-rng-pci -device e1000,netdev=net0 \
 -netdev user,id=net0,restrict=on,hostfwd=tcp:127.0.0.1:$PORT-:22 \
 -drive file=root.qcow2,if=ide,format=qcow2 -kernel $KIMG \
 -append '$GUEST_CMDLINE'"
for n in a b c d e; do QEMU_FULL="$QEMU_FULL -drive file=scratch-$n.qcow2,if=virtio,format=qcow2"; done
QEMU_FULL="$QEMU_ARGS$QEMU_FULL -drive file=scratch-logwrites.qcow2,if=virtio,format=qcow2"
for n in f g h; do QEMU_FULL="$QEMU_FULL -drive file=scratch-$n.qcow2,if=virtio,format=qcow2"; done
QEMU_FULL="$QEMU_FULL \
 -object memory-backend-file,id=kspmem0,share=on,mem-path=pmem-0.img,size=1G \
 -device nvdimm,id=kspmemdev0,memdev=kspmem0,node=0 \
 -object memory-backend-file,id=kspmem1,share=on,mem-path=pmem-1.img,size=1G \
 -device nvdimm,id=kspmemdev1,memdev=kspmem1,node=0 -machine nvdimm=on \
 -object memory-backend-ram,id=ksnuma0,size=3072M \
 -object memory-backend-ram,id=ksnuma1,size=3072M \
 -numa node,nodeid=0,cpus=0-1,memdev=ksnuma0 \
 -numa node,nodeid=1,cpus=2-3,memdev=ksnuma1"

run_bg "cd $VM_C && exec qemu-system-x86_64 $QEMU_FULL > qemu.out 2>&1"
sleep 8
if [ -s "$VM/qemu.out" ]; then head -5 "$VM/qemu.out"; die "QEMU failed to start (see above)"; fi
run bash -c "kill -0 \$(cat $VM_C/qemu.pid)" 2>/dev/null || die "QEMU process is not alive"
log "QEMU started, waiting for guest ssh (~2 min)..."

# ---------- 3. ssh/scp helpers + wait for the guest ---------------------------
# container mode: ssh/scp must run inside the container (hostfwd binds there)
if [ "$MODE" = container ]; then
  SSH_STR="ssh -i $KEY -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
  SCP_STR="scp -i $KEY -P $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  sshexec() { docker exec "$CONTAINER" bash -c "$SSH_STR $SSHTARGET \"\$@\"" _ "$@"; }
  scpcmd()  { docker exec "$CONTAINER" bash -c "$SCP_STR \"\$@\"" _ "$@"; }
else
  SSH_STR="ssh -i $KEY -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
  SCP_STR="scp -i $KEY -P $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  sshexec() { $SSH_STR $SSHTARGET "$@"; }
  scpcmd()  { $SCP_STR "$@"; }
fi
SSHTARGET=root@127.0.0.1
UP=0
for i in $(seq 1 30); do
  sleep 10
  if sshexec true 2>/dev/null; then UP=1; break; fi
done
[ "$UP" = 1 ] || die "guest ssh not reachable within 300 s"
log "guest ssh is up"

# ---------- 4. copy tools + run the state-construction sequence (step 1) ----
scpcmd "$SYZDIR/syz-execprog" "$SYZDIR/syz-executor" "$PROG" "$SSHTARGET:/tmp/"
sshexec "chmod +x /tmp/syz-execprog /tmp/syz-executor"
log "running the state-construction sequence (~20 s - 3 min, expect PRIMING_EXIT:0)"
PRIMING_OUT=$(sshexec "cd /tmp && ./syz-execprog -executor=/tmp/syz-executor -procs=1 -repeat=1 /tmp/repro.priming.prog; echo PRIMING_EXIT:\$?")
echo "$PRIMING_OUT" | grep -E "PRIMING_EXIT|executed programs" | sed 's/^/  /'
echo "$PRIMING_OUT" | grep -q "PRIMING_EXIT:0" \
  || log "WARNING: priming did not end with EXIT:0, continuing but the result is doubtful"
log "priming done, the executor released the vtpm fds - monitoring serial ($MONITOR_MIN min)"

# ---------- 5. watch the serial log for the hung-task report ------------------
SERIAL=$VM/serial.log
HIT=0
for i in $(seq 1 $((MONITOR_MIN*4))); do
  sleep 15
  N1=$(grep -c "blocked for more than" "$SERIAL" 2>/dev/null); N1=${N1:-0}
  N2=$(grep -c "Operation Timed out"  "$SERIAL" 2>/dev/null); N2=${N2:-0}
  log "monitor ${i}/$((MONITOR_MIN*4)): hung-report=$N1 tpm-timeout=$N2"
  if [ "$N1" -gt 0 ]; then HIT=1; break; fi
done

# ---------- 6. verdict + on-the-spot evidence --------------------------------
if [ "$HIT" = 1 ]; then
  log "================= PHENOMENON CONFIRMED ================="
  grep -m1 -A3 "blocked for more than" "$SERIAL" | sed 's/^/  /'
  sshexec "echo t > /proc/sysrq-trigger; sleep 2; dmesg > /tmp/dump.txt" 2>/dev/null
  scpcmd "$SSHTARGET:/tmp/dump.txt" "$VM_C/../sysrq-t-dump.txt"
  log "--- running chip-register work stack (sysrq-t) ---"
  grep -m1 -A14 "Workqueue: tpm-vtpm vtpm_proxy_work" "$WORK/sysrq-t-dump.txt" \
    | grep -E "Workqueue|tpm_|vtpm_|chip_" | sed 's/^/  /' | head -10
  log "--- tpm-vtpm workqueue backlog ---"
  grep -A4 "workqueue tpm-vtpm" "$WORK/sysrq-t-dump.txt" | head -6 | sed 's/^/  /'
  log "evidence: serial=$SERIAL  sysrq=$WORK/sysrq-t-dump.txt"
else
  log "================= NOT REPRODUCED (this pass) ================="
  log "the hang is timing sensitive - just rerun the script;"
  log "if it keeps missing, verify the layout/cmdline were not altered"
fi

# ---------- 7. cleanup --------------------------------------------------------
if [ "$KILL_AFTER" = 1 ] && [ -f "$VM/qemu.pid" ]; then
  if [ "$MODE" = container ]; then
    run bash -c "kill -9 \$(cat $VM_C/qemu.pid) 2>/dev/null"
  else
    kill -9 "$(cat "$VM/qemu.pid")" 2>/dev/null
  fi
  log "VM shut down (evidence kept in $WORK)"
else
  log "VM left running for live inspection; to stop it:"
  log "  container mode: docker exec $CONTAINER sh -c 'kill -9 \$(cat $VM_C/qemu.pid)'"
  log "  native mode:    kill -9 \$(cat $VM/qemu.pid)"
fi
[ "$HIT" = 1 ] && exit 0 || exit 1
