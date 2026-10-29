#!/usr/bin/env bash
# B2 loopback 冒烟:起服务器 + 建房/加入客户端,断言输入→模拟→快照→子弹广播链路。
set -e
# 引擎路径($GODOT,可用环境变量覆盖)+ cd 到仓库根 + kill_procs/kill_port
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"

# ★★ 2026-10-15:7777 上有**活大厅**就**拒跑**,不再"不动它然后照跑"。
#   为什么:服务器 `_ready` 会先 `kill_udp_port(7777)` 再 bind,而它的名族守卫放行 Godot 进程
#   ⇒ 本脚本一跑就会**端掉用户正在进行的对局**。原注释"那时本脚本本来也 bind 不上"是错的。
#   与 AGENTS.md §1 的硬规则一致:任何占 7777 的步骤先查 lobby_alive,为真则**跳过并问**。
if lobby_alive; then
  echo "[gate1] REFUSED: 7777 上有活大厅(可能有人在打)—— 本支会先杀属主再 bind,故拒跑。"
  echo "         先停掉那个大厅,或按 AGENTS.md §1 先问用户。"
  exit 2
fi
# 没有活大厅 ⇒ 池里那些一定是上一支/崩掉那支遗留的孤儿 worker,清掉(理由见 env.sh 的 kill_port_range)。
kill_port_range 7800 8300

# ★★ 2026-10-08(新增):按**命令行**杀本支自己的 Godot 客户端。
#   为什么必须另开一条:`kill_port` 只认固定端口(客户端用的是**临时出站端口**)、`kill_port_range`
#   只扫 worker 池,而 `kill_procs "$A_PID"` 在 Git Bash 下**不可靠**(env.sh 里实测:MSYS 的 `$!`
#   不一定是 Windows PID,taskkill 按它杀不掉)。⇒ 早退路径上客户端会**活下来**,而入口
#   `run_real.sh` 的"跑后 Godot 必须为 0"那条闸会判 FAIL ⇒ **整批中止在第 1 支**。
#   ★ 匹配串用 **`pvp_match_smoke.tscn`**(不是脚本名):bash 自己那条命令行含 `.sh` 路径,
#     用 `.sh` 名字去匹会**把本脚本自己杀掉**;`.tscn` 只出现在客户端的命令行里(服务器是 `server_main.tscn`)。
# ★ 2026-10-15:实现提到 `env.sh` 共享(另一支 `pvp_room_smoke.sh` 也要同一段);这里只留别名。
kill_my_clients() { kill_clients_by_cmdline 'pvp_match_smoke.tscn'; }

echo "== 启动服务器 =="
"$GODOT" --headless --path . res://server/server_main.tscn > /tmp/pvp2_server.log 2>&1 &
SERVER_PID=$!

# ★★ 2026-10-08(closeout 批修复 registered-debt.md §五.9):**用有界轮询取代固定 `sleep`**。
#   原实现:起服务器后 `sleep 3`(不管它起没起)、起建房客户端后 `sleep 2`,然后直接 grep 房间号
#   ⇒ 客户端/引擎加载稍慢就假红「服务器未建房间」,而**真因是还没加载完**
#   (实测:同一棵树、同配置连红三次;把 `sleep 3`/`sleep 2` 改成 `12`/`12` 后**一次就绿**)。
#   现在:服务器最多等 SERVER_WAIT 秒出现"服务器就绪",建房最多等 ROOM_WAIT 秒出现房间号。
#   ★ 两边都**有界** ⇒ 真挂住仍会红(而且把两份日志打出来),不会退化成"永远等下去"。
#   ★ 额外好处:进程若**提前退出**会立刻收摊并打印它的日志 —— 原来那种情况只能等到 grep 失败,
#     拿到的是"服务器未建房间"这句**指向错误嫌疑人**的判词。
SERVER_WAIT=${SERVER_WAIT:-20}
ROOM_WAIT=${ROOM_WAIT:-30}
_deadline=$(( $(date +%s) + SERVER_WAIT ))
while [ "$(date +%s)" -lt "$_deadline" ]; do
  if grep -q "服务器就绪" /tmp/pvp2_server.log 2>/dev/null; then break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "SMOKE FAIL: 服务器进程提前退出(见 /tmp/pvp2_server.log)"
    cat /tmp/pvp2_server.log 2>/dev/null
    kill_procs "$SERVER_PID"; kill_port; kill_my_clients; exit 1
  fi
  sleep 0.5
done
if ! grep -q "服务器就绪" /tmp/pvp2_server.log 2>/dev/null; then
  echo "SMOKE FAIL: ${SERVER_WAIT}s 内服务器未就绪"
  cat /tmp/pvp2_server.log 2>/dev/null
  kill_procs "$SERVER_PID"; kill_port; kill_my_clients; exit 1
fi

echo "== 客户端 A 建房(后台,移动+开火) =="
"$GODOT" --headless --path . res://tests/smoke/pvp_match_smoke.tscn -- --role create > /tmp/pvp2_a.log 2>&1 &
A_PID=$!

# 从**建房客户端**日志取房间号(有界轮询,见上面的理由)。
# ★ 2026-10-24 修:原写法 grep `/tmp/pvp2_server.log` 里的 `"event":"room_created"` —— 但 `NetDiag.audit()` 只写
#   `user://logs/ops-*.jsonl`、**从不进 stdout** ⇒ 那条 grep 永远为空 ⇒ 真链路批 30s 后假红(实测:房间其实已建成,
#   客户端也收到了 `SMOKE_ROOM_CODE=9744`)。改为从建房客户端日志取 —— 那是"本端拿到了哪个房号"的直接证据。
CODE=""
_deadline=$(( $(date +%s) + ROOM_WAIT ))
while [ "$(date +%s)" -lt "$_deadline" ]; do
CODE=$(sed -n 's/.*SMOKE_ROOM_CODE=\([0-9][0-9]*\).*/\1/p' /tmp/pvp2_a.log 2>/dev/null | head -1 || true)
  if [ -n "$CODE" ]; then break; fi
  if ! kill -0 "$A_PID" 2>/dev/null; then
    echo "SMOKE FAIL: 建房客户端提前退出(没走到 create_room)"
    break
  fi
  sleep 0.5
done
if [ -z "$CODE" ]; then
  # ★ 判词**点名真嫌疑**:§五.9 抱怨的正是原判词「服务器未建房间」在真因是"客户端还没加载完"时
  #   把人引去查服务器/网络。现在把两侧都写出来,并把两份日志一起打(下面两行)。
  echo "SMOKE FAIL: ${ROOM_WAIT}s 内没看到房间号(= 建房客户端没走到 create_room,不是服务器没起)"
  cat /tmp/pvp2_server.log 2>/dev/null; cat /tmp/pvp2_a.log 2>/dev/null
  # ★★ 早退路径**必须与正常路径(下方 `kill_port_range 7800 8300`)一样扫池** —— §五.9 第二条:
  #   worker 是大厅 `OS.create_process` 起的**孙进程**,不属于任何脚本记下的 PID;漏扫 ⇒ 孤儿毒占
  #   端口 ⇒ 入口的"跑后 Godot 必须为 0"那条闸判 FAIL ⇒ **整批 `run_real` 中止在第 1 支**
  #   (2026-10-08 实测 **3/3** 次,判词 `RUN_REAL FAIL(entries: ok=0 fail=1 ; gate-failures=1)`)。
  kill_procs "$SERVER_PID" "$A_PID"
  kill_port
  kill_my_clients
  kill_port_range 7800 8300
  exit 1
fi
echo "房间号=$CODE"

echo "== 客户端 B 加入 =="
"$GODOT" --headless --path . res://tests/smoke/pvp_match_smoke.tscn -- --role join --code "$CODE" > /tmp/pvp2_b.log 2>&1 &
B_PID=$!

wait $A_PID 2>/dev/null || true
wait $B_PID 2>/dev/null || true
kill_procs $SERVER_PID $A_PID $B_PID
kill_port
kill_my_clients   # ★ 同上:客户端不占固定端口,kill_procs 按 $! 又不可靠
# ★ 大厅已杀 ⇒ 它的 worker 现在是孤儿(`OS.create_process` 起的**孙进程**,不在上面那串 PID 里)。
kill_port_range 7800 8300

if grep -q "SMOKE_MATCH OK create" /tmp/pvp2_a.log && grep -q "SMOKE_MATCH OK join" /tmp/pvp2_b.log; then
  echo "SMOKE PASS"
  exit 0
else
  echo "SMOKE FAIL"
  cat /tmp/pvp2_server.log; cat /tmp/pvp2_a.log; cat /tmp/pvp2_b.log
  exit 1
fi
