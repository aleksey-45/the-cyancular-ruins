#!/usr/bin/env bash
# loopback 冒烟:起服务器 + 建房客户端 + 加入客户端,断言开局流程。
set -e
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
cd "$(dirname "$0")/.."

# Windows 下 bash `kill` 杀不死 headless Godot 进程(会留僵尸占 7777),改用 taskkill 强杀。
kill_procs() {
	for p in "$@"; do
		taskkill //F //PID "$p" >/dev/null 2>&1 || true
	done
}
# 按端口强杀服务器:Git Bash 的 $! 不一定等于 Windows 进程 PID(实测 taskkill 按 $! 杀不掉),
# 用 netstat 找持有 7777 的 PID 才是权威。
kill_port() {
	for pid in $(netstat -ano 2>/dev/null | grep -i ":7777" | awk '{print $NF}' | sort -u); do
		taskkill //F //PID "$pid" >/dev/null 2>&1 || true
	done
}

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
