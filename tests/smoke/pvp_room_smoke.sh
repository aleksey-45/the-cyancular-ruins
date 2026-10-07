#!/usr/bin/env bash
# 本地回环联机对局完整流程冒烟测试：启动服务端，创建房间并加入客户端，验证对局就绪与匹配开局流程。
set -e
# 导入通用测试环境变量（$GODOT 引擎路径、工作目录切换及进程与端口清理函数）
# shellcheck source=../env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"

# 单进程单端口架构下，对局运行在大厅进程内，无需清理额外的 worker 子进程与端口范围。

echo "== 启动服务器 =="
"$GODOT" --headless --path . res://server/server_main.tscn > /tmp/pvp_server.log 2>&1 &
SERVER_PID=$!
sleep 3

echo "== 启动建房客户端 A（后台运行，接收 match_start 信号后退出）=="
"$GODOT" --headless --path . res://tests/harness/pvp_smoke_client.tscn -- --role create > /tmp/pvp_a.log 2>&1 &
A_PID=$!

# 轮询建房客户端 A 输出的房间号（超时保护 15 秒）
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
"$GODOT" --headless --path . res://tests/harness/pvp_smoke_client.tscn -- --role join --code "$CODE" > /tmp/pvp_b.log 2>&1 &
B_PID=$!

# 轮询加入客户端 B 是否收到 match_start 对局开始信号（超时保护 15 秒）
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
