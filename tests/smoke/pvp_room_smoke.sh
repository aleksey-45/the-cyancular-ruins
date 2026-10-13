#!/usr/bin/env bash
# 双人完整对局、断线重连及原房间返回，由多进程测试器管理动态端口和进程。
set -e
source "$(dirname "${BASH_SOURCE[0]}")/../env.sh"
python tests/network/run_matches.py --godot "$GODOT" --count 2 --drop
