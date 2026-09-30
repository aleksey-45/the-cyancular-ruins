#!/usr/bin/env bash
# loopback 冒烟:起服务器 + 建房客户端 + 加入客户端,断言开局流程。
set -e
# 引擎路径($GODOT,可用环境变量覆盖)+ cd 到仓库根 + kill_procs/kill_port
# shellcheck source=tests/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# ★ 本支**只有一个进程**:服务端(单进程单端口,大厅与对局同进程,不拉任何子进程)——
#   故收尾按 PID 杀它就够,不需要按端口区间扫孤儿(那个区间是"每局一个 worker"时代的产物,
#   已随形态一起废除,见 docs/netplay.md)。★ 有服务端在 7777 上就**不动**它 —— 那种情况下
#   本脚本本来也 bind 不上,会自己报出来,不该顺手端掉别人正在跑的服务端。

echo "== 启动服务器 =="
"$GODOT" --headless --path . res://server/server_main.tscn > /tmp/pvp_server.log 2>&1 &
SERVER_PID=$!
sleep 3

echo "== 客户端 A 建房(后台,等 match_start 才退出) =="
"$GODOT" --headless --path . res://tests/pvp_smoke_client.tscn -- --role create > /tmp/pvp_a.log 2>&1 &
A_PID=$!

# 轮询 A 打印的房间号(最长 15s)
CODE=""
for i in $(seq 1 30); do
  CODE=$(grep -oP 'ROOM_CODE=\K[0-9]+' /tmp/pvp_a.log | head -1)
  [ -n "$CODE" ] && break
  sleep 0.5
done
if [ -z "$CODE" ]; then
  echo "SMOKE FAIL: 建房客户端未拿到房间号"; cat /tmp/pvp_a.log; kill_procs $SERVER_PID $A_PID; kill_port; exit 1
fi
echo "房间号=$CODE"

echo "== 客户端 B 加入 =="
"$GODOT" --headless --path . res://tests/pvp_smoke_client.tscn -- --role join --code "$CODE" > /tmp/pvp_b.log 2>&1 &
B_PID=$!

# 轮询 B 收到 match_start(最长 15s)
OK=""
for i in $(seq 1 30); do
  grep -q "match_start" /tmp/pvp_b.log && { OK=1; break; }
  sleep 0.5
done

wait $A_PID 2>/dev/null || true
wait $B_PID 2>/dev/null || true
kill_procs $SERVER_PID $A_PID $B_PID
kill_port

if [ -n "$OK" ]; then
  echo "SMOKE PASS"
  exit 0
else
  echo "SMOKE FAIL: B 未收到 match_start"
  cat /tmp/pvp_a.log; cat /tmp/pvp_b.log; cat /tmp/pvp_server.log
  exit 1
fi
