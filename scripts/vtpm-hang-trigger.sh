#!/usr/bin/env bash
# ============================================================================
# vtpm-hang-trigger.sh — 一键触发并观察 vTPM release-path hang
#
# 现象(预期): 状态构造序列的 executor 进程退出、释放 /dev/vtpm 服务端 fd 后,
#   release 路径阻塞在 vtpm_proxy_fops_release() -> vtpm_proxy_work_stop()
#   -> flush_work(); tpm-vtpm workqueue 上的 chip-register work 在
#   tpm_transmit() 里反复超时, serial 反复出现 "tpm tpmN: Operation Timed
#   out"; 约 143s 后 khungtaskd 报:
#     INFO: task ... blocked for more than 143 seconds.
#
# 用法:
#   bash vtpm-hang-trigger.sh              # 容器模式(默认), 跑完保留 VM 供检查
#   bash vtpm-hang-trigger.sh -k           # 结束后自动关 VM (证据目录保留)
#   MODE=native bash vtpm-hang-trigger.sh  # 开发者本机直跑(需 /dev/kvm)
#
# 可用环境变量:
#   MODE=container|native   container=经 docker exec 跑 QEMU/ssh(默认);
#                           native=开发者本机直接跑
#   CONTAINER=kernsight     容器名(container 模式)
#   PORT=12740              guest ssh 端口(hostfwd)
#   KILL_AFTER=1 (-k)       结束后关 VM
#   PANIC=1                 guest cmdline 改用 hung_task_panic=1(自动留 panic 证据)
#   MONITOR_MIN=15          priming 退出后监控时长(分钟)
#
# native 模式需另设(容器模式用内置默认值):
#   KIMG=/path/bzImage      未打补丁内核
#   GIMG=/path/root.raw     guest 根镜像(raw 格式)
#   KEY=/path/id_rsa        guest root@ 的 ssh 私钥
#   SYZDIR=/path/bin        含 syz-execprog / syz-executor 的目录
#   PROG=/path/repro.priming.prog   状态构造序列(49 个程序)
#   WORK=/path/workdir      工作目录(默认 $PWD/vtpm-trigger-<时间戳>)
#
# 前提: /dev/kvm; 空闲内存>=7G; 磁盘>=20G; 端口未占用。
# 注意: 必须完整布局+完整 cmdline(2x2 实验: bare 布局 0/2 不触发)。
# 时序敏感: 单次未触发请直接重跑(历史上完整配置下 9/9 触发)。
# ============================================================================
set -u

MODE=${MODE:-container}
CONTAINER=${CONTAINER:-kernsight}
PORT=${PORT:-12740}
MONITOR_MIN=${MONITOR_MIN:-15}
PANIC=${PANIC:-0}
KILL_AFTER=0
for a in "$@"; do [ "$a" = "-k" ] && KILL_AFTER=1; done

TS=$(date +%Y%m%d-%H%M%S)
if [ "$MODE" = container ]; then
  BASE=/data/zhengzheng/kernsight            # 宿主机路径 = 容器内 /workspace
  WORK=$BASE/vtpm-trigger-$TS
  VM=$WORK/vm
  VM_C=/workspace/vtpm-trigger-$TS/vm        # 容器内路径
  KIMG_C=${KIMG:-${KERNEL:-/workspace/vtpm-patched-test/bzImage-unpatched-7.3}}
  KEY_C=/workspace/vtpm-patched-test/trixie.id_rsa
  SYZ_C=/workspace/syzkaller/bin/linux_amd64
  PROG_C=/workspace/validation/vtpm-retest-ws/crash-34b4d156/repro.priming.prog
  GIMG_C=/workspace/vm/trixie.img
else
  KIMG=${KIMG:-${KERNEL:-}}
  : ${KIMG:?native 模式需设 KIMG}; : ${GIMG:?native 模式需设 GIMG}
  : ${KEY:?native 模式需设 KEY};   : ${SYZDIR:?native 模式需设 SYZDIR}
  : ${PROG:?native 模式需设 PROG}
  WORK=${WORK:-$PWD/vtpm-trigger-$TS}
  VM=$WORK/vm
  VM_C=$VM
fi

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "FATAL: $*"; exit 1; }

# 统一执行通道: 容器模式经 docker exec, native 直接执行
if [ "$MODE" = container ]; then
  run() { docker exec "$CONTAINER" "$@"; }
  run_bg() { docker exec -d "$CONTAINER" bash -c "$1"; }
else
  run() { "$@"; }
  run_bg() { bash -c "$1" & }
fi

# ---------- 0. 前置检查 ----------
if [ "$MODE" = container ]; then
  docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
    || die "容器 $CONTAINER 未运行"
  run test -e /dev/kvm || die "容器内无 /dev/kvm"
  run test -r "$KIMG_C"    || die "内核不可读: $KIMG_C"
  run test -r "$PROG_C"    || die "复现程序不存在: $PROG_C"
  run test -r "$SYZ_C/syz-execprog" || die "syz-execprog 不存在"
  run test -r "$KEY_C"    || die "SSH 私钥不存在: $KEY_C"
else
  [ -e /dev/kvm ] || die "/dev/kvm 不存在"
  command -v qemu-system-x86_64 >/dev/null || die "缺少 qemu-system-x86_64"
  [ -r "$KIMG" ] && [ -r "$GIMG" ] && [ -r "$KEY" ] || die "KIMG/GIMG/KEY 不可读"
  [ -x "$SYZDIR/syz-execprog" ] || die "缺少 $SYZDIR/syz-execprog"
  [ -r "$PROG" ] || die "复现程序不存在: $PROG"
fi
(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":$PORT " \
  && die "端口 $PORT 已被占用"
[ -e "$WORK" ] && die "工作目录已存在: $WORK"
free -g | awk 'NR==2{exit !($7>=6)}' || die "可用内存不足 6G"
log "前置检查通过: mode=$MODE port=$PORT work=$WORK"

# ---------- 1. 完整磁盘布局(大小勿改, 是触发条件之一) ----------
mkdir -p "$VM"
if [ "$MODE" = container ]; then
  run qemu-img create -q -f qcow2 -b "$GIMG_C" -F raw "$VM_C/root.qcow2" \
    || die "root overlay 创建失败"
else
  qemu-img create -q -f qcow2 -b "$GIMG" -F raw "$VM/root.qcow2" \
    || die "root overlay 创建失败"
fi
for n in a b; do qemu-img create -q -f qcow2 "$VM/scratch-$n.qcow2" 16G; done
for n in c d e logwrites f g h; do qemu-img create -q -f qcow2 "$VM/scratch-$n.qcow2" 12G; done
truncate -s 1G "$VM/pmem-0.img" "$VM/pmem-1.img"
log "磁盘布局完成 (root overlay + 2x16G + 7x12G + 2x1G pmem)"

# ---------- 2. 启动 VM ----------
# guest cmdline = 仓库 cmdline/cmdline-7.3-retest.txt; PANIC=1 时 hung_task_panic=1
HTP=0; [ "$PANIC" = 1 ] && HTP=1
GUEST_CMDLINE="root=/dev/sda console=ttyS0 fstab=no rw earlyprintk=serial net.ifnames=0 oops=panic panic_on_warn=1 panic=86400 hung_task_panic=$HTP softlockup_panic=1 nmi_watchdog=panic sysctl.kernel.hung_task_all_cpu_backtrace=1 sysctl.kernel.panic_on_rcu_stall=1 sysctl.kernel.max_rcu_stall_to_panic=1 rcupdate.rcu_expedited=1 rcupdate.rcu_cpu_stall_cputime=1 no_hash_pointers page_owner=on sysctl.vm.nr_hugepages=4 sysctl.vm.nr_overcommit_hugepages=4 secretmem.enable=1 msr.allow_writes=off coredump_filter=0xffff vsyscall=native kvm-intel.nested=1 spec_store_bypass_disable=prctl nopcid vivid.n_devs=64 vivid.multiplanar=1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2,1,2 netrom.nr_ndevs=32 rose.rose_ndevs=32 smp.csd_lock_timeout=100000 watchdog_thresh=55 workqueue.watchdog_thresh=140 sysctl.net.core.netdev_unregister_timeout_secs=140 dummy_hcd.num=16 max_loop=32 nbd.nbds_max=32 comedi.comedi_num_legacy_minors=4 kunit.autorun=0 vcan.echo=1"

QEMU_ARGS="-vga none -m 6144M,slots=2,maxmem=8192M -smp 4 -display none \
 -no-reboot -name vtpm-trigger-$TS -serial file:serial.log -pidfile qemu.pid \
 -accel kvm -cpu host -device virtio-rng-pci -device e1000,netdev=net0 \
 -netdev user,id=net0,restrict=on,hostfwd=tcp:127.0.0.1:$PORT-:22 \
 -drive file=root.qcow2,if=ide,format=qcow2"

if [ "$MODE" = container ]; then
  QEMU_FULL="$QEMU_ARGS -kernel $KIMG_C -append '$GUEST_CMDLINE'"
else
  QEMU_FULL="$QEMU_ARGS -kernel $KIMG -append '$GUEST_CMDLINE'"
fi
for n in a b c d e; do QEMU_FULL="$QEMU_FULL -drive file=scratch-$n.qcow2,if=virtio,format=qcow2"; done
QEMU_FULL="$QEMU_FULL -drive file=scratch-logwrites.qcow2,if=virtio,format=qcow2"
for n in f g h; do QEMU_FULL="$QEMU_FULL -drive file=scratch-$n.qcow2,if=virtio,format=qcow2"; done
QEMU_FULL="$QEMU_FULL -object memory-backend-file,id=kspmem0,share=on,mem-path=pmem-0.img,size=1G \
 -device nvdimm,id=kspmemdev0,memdev=kspmem0,node=0 \
 -object memory-backend-file,id=kspmem1,share=on,mem-path=pmem-1.img,size=1G \
 -device nvdimm,id=kspmemdev1,memdev=kspmem1,node=0 -machine nvdimm=on \
 -object memory-backend-ram,id=ksnuma0,size=3072M \
 -object memory-backend-ram,id=ksnuma1,size=3072M \
 -numa node,nodeid=0,cpus=0-1,memdev=ksnuma0 \
 -numa node,nodeid=1,cpus=2-3,memdev=ksnuma1"

run_bg "cd $VM_C && exec qemu-system-x86_64 $QEMU_FULL > qemu.out 2>&1"
sleep 8
if [ -s "$VM/qemu.out" ]; then head -5 "$VM/qemu.out"; die "QEMU 启动报错(见上)"; fi
run bash -c "kill -0 \$(cat $VM_C/qemu.pid)" 2>/dev/null || die "QEMU 进程未存活"
log "QEMU 已启动, 等待 guest ssh (约 2 分钟)..."

# ---------- 3. ssh/scp 封装 + 等 ssh 通 ----------
# 容器模式下 ssh/scp 必须在容器内执行(hostfwd 绑定在容器侧)
if [ "$MODE" = container ]; then
  SSH_STR="ssh -i $KEY_C -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
  SCP_STR="scp -i $KEY_C -P $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
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
[ "$UP" = 1 ] || die "guest ssh 300s 未通"
log "guest ssh 已通"

# ---------- 4. 拷工具 + 跑状态构造序列(两步法第 1 步) ----------
if [ "$MODE" = container ]; then
  scpcmd "$SYZ_C/syz-execprog" "$SYZ_C/syz-executor" "$PROG_C" "$SSHTARGET:/tmp/"
else
  scpcmd "$SYZDIR/syz-execprog" "$SYZDIR/syz-executor" "$PROG" "$SSHTARGET:/tmp/"
fi
sshexec "chmod +x /tmp/syz-execprog /tmp/syz-executor"
log "开始跑状态构造序列 (49 个程序, 正常应 ~20s-3min 且 PRIMING_EXIT:0)"
PRIMING_OUT=$(sshexec "cd /tmp && ./syz-execprog -executor=/tmp/syz-executor -procs=1 -repeat=1 /tmp/repro.priming.prog; echo PRIMING_EXIT:\$?")
echo "$PRIMING_OUT" | grep -E "PRIMING_EXIT|executed programs" | sed 's/^/  /'
echo "$PRIMING_OUT" | grep -q "PRIMING_EXIT:0" || log "警告: priming 未以 EXIT:0 结束, 继续监控但结果存疑"
log "priming 已退出, executor 释放 vtpm fd —— 开始监控 serial ($MONITOR_MIN 分钟)"

# ---------- 5. 监控 serial, 等待 hung 报告 ----------
SERIAL=$VM/serial.log
HIT=0
for i in $(seq 1 $((MONITOR_MIN*4))); do
  sleep 15
  N1=$(grep -c "blocked for more than" "$SERIAL" 2>/dev/null); N1=${N1:-0}
  N2=$(grep -c "Operation Timed out"  "$SERIAL" 2>/dev/null); N2=${N2:-0}
  log "监控 ${i}/$((MONITOR_MIN*4)): hung-report=$N1 tpm-timeout=$N2"
  if [ "$N1" -gt 0 ]; then HIT=1; break; fi
done

# ---------- 6. 结果判定 + 现场取证 ----------
if [ "$HIT" = 1 ]; then
  log "================= PHENOMENON CONFIRMED ================="
  grep -m1 -A3 "blocked for more than" "$SERIAL" | sed 's/^/  /'
  sshexec "echo t > /proc/sysrq-trigger; sleep 2; dmesg > /tmp/dump.txt" 2>/dev/null
  scpcmd "$SSHTARGET:/tmp/dump.txt" "$VM_C/../sysrq-t-dump.txt"
  log "--- 在跑的 chip-register work 栈 (sysrq-t) ---"
  grep -m1 -A14 "Workqueue: tpm-vtpm vtpm_proxy_work" "$WORK/sysrq-t-dump.txt" \
    | grep -E "Workqueue|tpm_|vtpm_|chip_" | sed 's/^/  /' | head -10
  log "--- tpm-vtpm workqueue 积压 ---"
  grep -A4 "workqueue tpm-vtpm" "$WORK/sysrq-t-dump.txt" | head -6 | sed 's/^/  /'
  log "证据文件: serial=$SERIAL  sysrq=$WORK/sysrq-t-dump.txt"
else
  log "================= NOT REPRODUCED (本次) ================="
  log "该 hang 对时序敏感, 请直接重跑本脚本; 若多次未触发, 检查布局/cmdline 是否被改动"
fi

# ---------- 7. 清理 ----------
if [ "$KILL_AFTER" = 1 ] && [ -f "$VM/qemu.pid" ]; then
  if [ "$MODE" = container ]; then
    run bash -c "kill -9 \$(cat $VM_C/qemu.pid) 2>/dev/null"
  else
    kill -9 "$(cat "$VM/qemu.pid")" 2>/dev/null
  fi
  log "VM 已关闭 (证据保留在 $WORK)"
else
  log "VM 保留运行中, 可现场检查; 手动关闭:"
  log "  container 模式: docker exec $CONTAINER sh -c 'kill -9 \$(cat $VM_C/qemu.pid)'"
  log "  native 模式:    kill -9 \$(cat $VM/qemu.pid)"
fi
[ "$HIT" = 1 ] && exit 0 || exit 1
