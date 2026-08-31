#!/usr/bin/env bash
# B2 loopback 冒烟:起服务器 + 建房/加入客户端,断言输入→模拟→快照→子弹广播链路。
set -e
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
cd "$(dirname "$0")/.."

echo "== 启动服务器 =="
"$GODOT" --headless --path . res://server/server_main.tscn > /tmp/pvp2_server.log 2>&1 &
SERVER_PID=$!
sleep 3

echo "== 客户端 A 建房(后台,移动+开火) =="
"$GODOT" --headless --path . res://Tests/pvp_match_smoke.tscn -- --role create > /tmp/pvp2_a.log 2>&1 &
A_PID=$!
sleep 2

# 从服务器日志取房间号
CODE=$(grep -oP '房间 \K[0-9]+' /tmp/pvp2_server.log | head -1)
if [ -z "$CODE" ]; then
  echo "SMOKE FAIL: 服务器未建房间"; cat /tmp/pvp2_server.log; kill $SERVER_PID $A_PID 2>/dev/null; exit 1
fi
echo "房间号=$CODE"

echo "== 客户端 B 加入 =="
"$GODOT" --headless --path . res://Tests/pvp_match_smoke.tscn -- --role join --code "$CODE" > /tmp/pvp2_b.log 2>&1 &
B_PID=$!

wait $A_PID 2>/dev/null || true
wait $B_PID 2>/dev/null || true
kill $SERVER_PID 2>/dev/null || true

if grep -q "SMOKE_MATCH OK create" /tmp/pvp2_a.log && grep -q "SMOKE_MATCH OK join" /tmp/pvp2_b.log; then
  echo "SMOKE PASS"
  exit 0
else
  echo "SMOKE FAIL"
  cat /tmp/pvp2_server.log; cat /tmp/pvp2_a.log; cat /tmp/pvp2_b.log
  exit 1
fi
