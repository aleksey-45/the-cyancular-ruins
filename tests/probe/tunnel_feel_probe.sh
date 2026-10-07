#!/usr/bin/env bash
# P2P 隧道多实例网络性能基准测试脚本 —— 支持 1v1 / 大乱斗 / 3v3。
#
# 用法:
#   bash tests/probe/tunnel_feel_probe.sh                          # 默认 1v1（2 实例）
#   bash tests/probe/tunnel_feel_probe.sh --mode=royale --guests=3
#   bash tests/probe/tunnel_feel_probe.sh --mode=team  --guests=5   # 3v3 满员 6 人
#   bash tests/probe/tunnel_feel_probe.sh --seconds=60
#   bash tests/probe/tunnel_feel_probe.sh --analyze-only            # 仅根据已有日志生成分析报告
#
# 测试判据: 各实例日志输出包含 `TUNNEL FEEL [<side>]: OK`。
#
# 目录隔离架构:
#   测试运行于 `tests/multiplayer/<mode>/inst<N>/` 独立子目录下，分别存放：
#     - 客户端与服务端二进制可执行文件（优先创建硬链接，失败时复制）
#     - easytier 组件及 relay.txt 配置文件
#   各实例切换至各自独立的工作目录运行，防止日志文件覆盖与运行时状态冲突。
#
# 环境重置原则:
#   每次测试全量覆盖部署实例目录下的组件与二进制，确保各实例版本严格一致。
set -u

# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── easytier 四件套 + 带节点的 relay.txt(从既有导出包复用,可用 ASSET_SRC 覆盖)──
ASSET_SRC="${ASSET_SRC:-/c/Users/siri/Documents/The Cyancular Ruins v.1.1.4 202610070112}"

EXE_CLIENT="The Cyancular Ruins.exe"
EXE_SERVER="Cyancular Ruins Server.exe"

MODE="duel"
GUESTS=""
SECONDS_PLAY=60
ANALYZE_ONLY=0
for a in "$@"; do
  case "$a" in
    --mode=*)    MODE="${a#*=}" ;;
    --guests=*)  GUESTS="${a#*=}" ;;
    --seconds=*) SECONDS_PLAY="${a#*=}" ;;
    --analyze-only) ANALYZE_ONLY=1 ;;
    *) echo "[feel] 未知参数 $a"; exit 2 ;;
  esac
done

case "$MODE" in
  duel)   [ -n "$GUESTS" ] || GUESTS=1 ;;
  royale) [ -n "$GUESTS" ] || GUESTS=3 ;;
  team)   [ -n "$GUESTS" ] || GUESTS=5 ;;   # 3v3 满员 6 人(房主 + 5 客机)
  *) echo "[feel] --mode 只能是 duel / royale / team(实得 $MODE)"; exit 2 ;;
esac

RUN_DIR="${REPO}/tests/multiplayer/${MODE}"
OUT="${REPO}/tests/probe/feel_out"
mkdir -p "$OUT"

die() { echo "[feel] **失败**:$*"; exit 1; }

if [ "$ANALYZE_ONLY" = "0" ]; then
  echo "[feel] === ① 铺环境(模式 $MODE,$((GUESTS + 1)) 个实例,每次整份重铺) ==="
  LATEST_BUILD=$(ls -dt "${REPO}"/builds/*/ 2>/dev/null | head -1 || true)
  [ -n "$LATEST_BUILD" ] || die "builds/ 下没有构建产物 —— 先跑:python tools/build_release.py"
  SRC_CLIENT="${REPO}/${EXE_CLIENT}"
  SRC_SERVER="${LATEST_BUILD}${EXE_SERVER}"
  [ -f "$SRC_CLIENT" ] || die "没有客户端产物:$SRC_CLIENT"
  [ -f "$SRC_SERVER" ] || die "没有服务端产物:$SRC_SERVER"

  # inst0 = 房主,inst1..N = 客机
  for i in $(seq 0 "$GUESTS"); do
    d="${RUN_DIR}/inst${i}"
    mkdir -p "$d/easytier"
    cp -f "$ASSET_SRC/easytier/"{easytier-core.exe,easytier-cli.exe,Packet.dll,wintun.dll,relay.txt} "$d/easytier/" \
      || die "复制 easytier 组件失败 -> $d/easytier(源 $ASSET_SRC/easytier)"
    # 硬链接优先:省空间,且各实例必然是同一次导出的同一份字节。
    # - 失败(跨卷/文件系统不支持)就退回复制 —— 不做事前检测,`ln` 的成败自己说明结果。
    ln -f "$SRC_CLIENT" "$d/$EXE_CLIENT" 2>/dev/null || cp -f "$SRC_CLIENT" "$d/$EXE_CLIENT" || die "铺客户端失败 -> $d"
    ln -f "$SRC_SERVER" "$d/$EXE_SERVER" 2>/dev/null || cp -f "$SRC_SERVER" "$d/$EXE_SERVER" || die "铺服务端失败 -> $d"
    echo "[feel]   $d"
  done
  echo "[feel]   环境就绪(源:仓库根 + $LATEST_BUILD)"
fi

if [ "$ANALYZE_ONLY" = "0" ]; then
  echo
  echo "[feel] === ② 跑(模式 $MODE,每侧 ${SECONDS_PLAY}s) ==="

  # - 起跑前清残留:两个 exe 都持有日志文件,残留进程会让新进程"截断 + 旧进程按旧偏移续写",
  #   日志里于是出现空洞与陈旧行(与仓里各探针同一条纪律)。
  rm -f "$OUT"/*.log

  # 日志走 **shell 重定向**而不是 Godot 的 `--log-file`:`--log-file` 是**带缓冲**的,
  # 房号那行在轮询窗口内可能还没落盘 -> 拿到空房号 -> 整跑白等(实测踩过)。
  # 任务控制关掉(`set +m`)以免 job 通知混进日志。
  start_inst() {   # $1=序号,其余=探针参数;回显 pid
    local i="$1"; shift
    ( cd "${RUN_DIR}/inst${i}" && ./"$EXE_CLIENT" -- "$@" ) >"$OUT/inst${i}.log" 2>&1 &
    echo $!
  }

  HOST_PID=$(start_inst 0 --side=host --mode="$MODE" --expect=$((GUESTS + 1)) --team=1 --seconds="$SECONDS_PLAY" --netstat)
  echo "[feel] 起房主(pid=$HOST_PID)"

  # - 等房号:房主建完房会打「PROBE[host]: 房间号 = NNNNN」。客机必须拿**真房号**去加入
  #   (手敲假号会走"房间不存在",而那条路**不会**起隧道 -> 客机永远进不去,像隧道坏了)。
  echo "[feel] 等房主建房(最多 60s)…"
  CODE=""
  for _ in $(seq 1 120); do
    kill -0 "$HOST_PID" 2>/dev/null || break
    CODE=$(grep -aoE "房间号 = [0-9]+" "$OUT/inst0.log" 2>/dev/null | head -1 | grep -oE "[0-9]+$")
    [ -n "$CODE" ] && break
    sleep 0.5
  done
  if [ -z "$CODE" ]; then
    echo "[feel] 错误：60s 内未能获取房间号。主机端日志尾部："
    tail -30 "$OUT/inst0.log" 2>/dev/null
    kill_procs "$HOST_PID" 2>/dev/null || true
    exit 1
  fi
  echo "[feel] 房间号 = $CODE"

  # 客机串行拉起（间隔 2s），避免并发集中加入造成的瞬间拥塞扰乱网络时延采样；
  # 3v3 模式按实例编号交替分配队伍（奇数 1 队，偶数 2 队）。
  PIDS="$HOST_PID"
  for i in $(seq 1 "$GUESTS"); do
    team=$(( i % 2 == 1 ? 1 : 2 ))
    p=$(start_inst "$i" --side=guest --mode="$MODE" --code="$CODE" --team="$team" --seconds="$SECONDS_PLAY" --netstat)
    PIDS="$PIDS $p"
    echo "[feel] 启动客机实例 inst$i (pid=$p, 队伍 $team)"
    sleep 2
  done

  for p in $PIDS; do wait "$p" 2>/dev/null || true; done
  kill_procs $PIDS 2>/dev/null || true
  echo "[feel] 所有测试实例已退出"
fi

echo
echo "[feel] === ③ 测试结论 ==="
OK=1
for i in $(seq 0 "$GUESTS"); do
  V=$(grep -aoE "TUNNEL FEEL \[[a-z]+\]: (OK|NO-[A-Z]+)" "$OUT/inst${i}.log" 2>/dev/null | tail -1)
  echo "[feel]   inst$i:$V"
  [ -n "$V" ] || OK=0
done
# 汇总报告比对主机端与首个客机端数据
python "$(dirname "${BASH_SOURCE[0]}")/tunnel_feel_report.py" \
  "$OUT/inst0.log" "$OUT/inst1.log" "${RUN_DIR}/inst0/log/server.log" || exit 1

[ "$OK" = "1" ] || { echo "[feel] 存在未输出结论日志的实例，请检查 $OUT/instN.log"; exit 1; }
echo "[feel] 结论：所有实例均成功进入对局并运行满 ${SECONDS_PLAY}s，完整度量数据见 $OUT/"
exit 0
