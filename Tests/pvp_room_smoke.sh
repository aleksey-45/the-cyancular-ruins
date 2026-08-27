#!/usr/bin/env bash
# loopback 冒烟:起服务器 + 建房客户端 + 加入客户端,断言开局流程。
set -e
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
cd "$(dirname "$0")/.."

echo "== 启动服务器 =="
"$GODOT" --headless --path . res://server/server_main.tscn > /tmp/pvp_server.log 2>&1 &
SERVER_PID=$!
sleep 3

echo "== 客户端 A 建房(后台,等 match_start 才退出) =="
"$GODOT" --headless --path . res://Tests/pvp_smoke_client.tscn -- --role create > /tmp/pvp_a.log 2>&1 &
A_PID=$!

# 轮询 A 打印的房间号(最长 15s)
CODE=""
for i in $(seq 1 30); do
  CODE=$(grep -oP 'ROOM_CODE=\K[0-9]+' /tmp/pvp_a.log | head -1)
  [ -n "$CODE" ] && break
  sleep 0.5
done
if [ -z "$CODE" ]; then
  echo "SMOKE FAIL: 建房客户端未拿到房间号"; cat /tmp/pvp_a.log; kill $SERVER_PID $A_PID 2>/dev/null; exit 1
fi
echo "房间号=$CODE"

echo "== 客户端 B 加入 =="
"$GODOT" --headless --path . res://Tests/pvp_smoke_client.tscn -- --role join --code "$CODE" > /tmp/pvp_b.log 2>&1 &
B_PID=$!

# 轮询 B 收到 match_start(最长 15s)
OK=""
for i in $(seq 1 30); do
  grep -q "match_start" /tmp/pvp_b.log && { OK=1; break; }
  sleep 0.5
done

wait $A_PID 2>/dev/null || true
wait $B_PID 2>/dev/null || true
kill $SERVER_PID 2>/dev/null || true

if [ -n "$OK" ]; then
  echo "SMOKE PASS"
  exit 0
else
  echo "SMOKE FAIL: B 未收到 match_start"
  cat /tmp/pvp_a.log; cat /tmp/pvp_b.log; cat /tmp/pvp_server.log
  exit 1
fi
