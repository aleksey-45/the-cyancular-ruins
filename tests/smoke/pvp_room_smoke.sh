#!/usr/bin/env bash
# loopback 冒烟:起服务器 + 建房客户端 + 加入客户端,断言开局流程。
set -e
# 引擎路径($GODOT,可用环境变量覆盖)+ cd 到仓库根 + kill_procs/kill_port
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"

# ★★ 2026-10-15:7777 上有**活大厅**就**拒跑**(原写"那种情况下本脚本本来也 bind 不上 7777"是错的:
#   服务器 `_ready` 会先 `kill_udp_port(7777)` 再 bind,名族守卫又放行 Godot ⇒ 照跑 = 端掉别人的对局)。
if lobby_alive; then
  echo "[gate1] REFUSED: 7777 上有活大厅(可能有人在打)—— 本支会先杀属主再 bind,故拒跑。"
  echo "         先停掉那个大厅,或按 AGENTS.md §1 先问用户。"
  exit 2
fi
# 没有活大厅 ⇒ 端口池里的一定是上一支(或崩掉的那支)遗留的,不清的话本支的新 worker 会撞上它、
# 报"监听失败 20",然后**静默挂住**(理由与实测见 env.sh 的 kill_port_range)。
kill_port_range 7800 8300

# ★★ 2026-10-15:按**命令行**杀本支自己的客户端(实现共享在 env.sh,理由见那里的注释)。
#   本支原先**没有**这一段 ⇒ 早退路径上客户端会活下来(它走**临时出站端口**,`kill_port*` 够不着),
#   而入口的"跑后 Godot 必须为 0"判 FAIL ⇒ **整批中止在第 2 支**(与 team_match 那次孤儿事故同形)。
kill_my_clients() { kill_clients_by_cmdline 'pvp_smoke_client.tscn'; }

echo "== 启动服务器 =="
"$GODOT" --headless --path . res://server/server_main.tscn > /tmp/pvp_server.log 2>&1 &
SERVER_PID=$!
# ★★ 2026-10-15(照 §五.9 的纪律改):固定 `sleep 3` → **有界轮询 + 存活判据**。
#   固定的 sleep 不保证服务器起完了(加载稍慢就假红,而真因只是"还没加载完");进程提前退出时
#   也只能等到 grep 失败,判词还会指向错嫌疑人。兄弟支 pvp_match_smoke.sh 已改成这个形状。
SERVER_WAIT=${SERVER_WAIT:-20}
_deadline=$(( $(date +%s) + SERVER_WAIT ))
while [ "$(date +%s)" -lt "$_deadline" ]; do
  if grep -q "服务器就绪" /tmp/pvp_server.log 2>/dev/null; then break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "SMOKE FAIL: 服务器进程提前退出(见 /tmp/pvp_server.log)"
    cat /tmp/pvp_server.log 2>/dev/null
    kill_procs "$SERVER_PID"; kill_port; kill_my_clients; exit 1
  fi
  sleep 0.5
done
if ! grep -q "服务器就绪" /tmp/pvp_server.log 2>/dev/null; then
  echo "SMOKE FAIL: ${SERVER_WAIT}s 内服务器未就绪"
  cat /tmp/pvp_server.log 2>/dev/null
  kill_procs "$SERVER_PID"; kill_port; kill_my_clients; exit 1
fi

echo "== 客户端 A 建房(后台,等 match_start 才退出) =="
"$GODOT" --headless --path . res://tests/harness/pvp_smoke_client.tscn -- --role create > /tmp/pvp_a.log 2>&1 &
A_PID=$!

# 轮询 A 打印的房间号(有界 + 存活判据;理由同上面的 §五.9 那条)
ROOM_WAIT=${ROOM_WAIT:-30}
CODE=""
_deadline=$(( $(date +%s) + ROOM_WAIT ))
while [ "$(date +%s)" -lt "$_deadline" ]; do
  CODE=$(grep -oP 'ROOM_CODE=\K[0-9]+' /tmp/pvp_a.log 2>/dev/null | head -1 || true)
  if [ -n "$CODE" ]; then break; fi
  if ! kill -0 "$A_PID" 2>/dev/null; then
    echo "SMOKE FAIL: 建房客户端提前退出(没走到 create_room)"
    break
  fi
  sleep 0.5
done
if [ -z "$CODE" ]; then
  # ★ 判词点名真嫌疑:原文案「建房客户端未拿到房间号」在真因是"客户端还没加载完"时把人引去查服务器。
  echo "SMOKE FAIL: ${ROOM_WAIT}s 内没看到房间号(= 建房客户端没走到 create_room,不是服务器没起)"
  cat /tmp/pvp_a.log 2>/dev/null; cat /tmp/pvp_server.log 2>/dev/null
  # ★★ 早退路径必须与正常路径一样收干净:客户端走临时端口(只有按命令行杀得到)+ 扫 worker 池
  #   (worker 是大厅 `OS.create_process` 起的孙进程,不属于任何记下的 PID)。
  kill_procs "$SERVER_PID" "$A_PID"; kill_port; kill_port_range 7800 8300; kill_my_clients; exit 1
fi
echo "房间号=$CODE"

echo "== 客户端 B 加入 =="
"$GODOT" --headless --path . res://tests/harness/pvp_smoke_client.tscn -- --role join --code "$CODE" > /tmp/pvp_b.log 2>&1 &
B_PID=$!

# 轮询 B 收到 match_start(有界 + 存活判据)
MATCH_WAIT=${MATCH_WAIT:-30}
OK=""
_deadline=$(( $(date +%s) + MATCH_WAIT ))
while [ "$(date +%s)" -lt "$_deadline" ]; do
  if grep -q "match_start" /tmp/pvp_b.log 2>/dev/null; then OK=1; break; fi
  if ! kill -0 "$B_PID" 2>/dev/null; then
    echo "SMOKE FAIL: B 客户端提前退出(见 /tmp/pvp_b.log)"
    break
  fi
  sleep 0.5
done

wait $A_PID 2>/dev/null || true
wait $B_PID 2>/dev/null || true
kill_procs $SERVER_PID $A_PID $B_PID
kill_port
kill_my_clients   # ★ 客户端走临时出站端口 ⇒ 只有按命令行杀得到(见 env.sh 的 kill_clients_by_cmdline)
# ★ 大厅已杀 ⇒ 它的 worker 现在是孤儿(它是 `OS.create_process` 起的**孙进程**,不在上面
#   那串 PID 里)。不收就说不上"清理干净",下一支真链路测试会被它毒到。
kill_port_range 7800 8300

if [ -n "$OK" ]; then
  echo "SMOKE PASS"
  exit 0
else
  echo "SMOKE FAIL: B 未收到 match_start"
  cat /tmp/pvp_a.log; cat /tmp/pvp_b.log; cat /tmp/pvp_server.log
  exit 1
fi
