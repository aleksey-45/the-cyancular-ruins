#!/usr/bin/env python3
"""UDP 网络延迟与抖动模拟代理工具（测试专用）：

将客户端发送至 `--listen` 端口的数据包，延迟 `--delay-ms` ± `--jitter-ms` 后转发至
`--to-host:--to-port`；双向数据流均进行同等延迟模拟。底层基于 UDP 协议直接转发载荷。

注意：每个客户端需独立运行一个代理实例。
ENet 依赖网络四元组（源 IP、源端口、目的 IP、目的端口）识别 Peer 节点。
若多个客户端共用同一个代理实例的回程 Socket，服务端识别到的源地址将完全相同，导致节点状态混淆。
正确用法：客户端 1 监听 7800，客户端 2 监听 7801，两者分别代理转发至目标服务端 Worker 端口。

用法示例：
    python tests/harness/net_lag_proxy.py --listen 7800 --to-port 8811 --delay-ms 70 --jitter-ms 15
"""
import argparse
import heapq
import random
import select
import socket
import time


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, required=True, help="前端端口(客户端连这个)")
    ap.add_argument("--to-host", default="127.0.0.1")
    ap.add_argument("--to-port", type=int, required=True, help="后端端口(worker 真实端口)")
    ap.add_argument("--delay-ms", type=float, default=0.0, help="单向基础延迟")
    ap.add_argument("--jitter-ms", type=float, default=0.0, help="单向均匀抖动半径")
    ap.add_argument("--seed", type=int, default=20260922)
    a = ap.parse_args()

    rng = random.Random(a.seed)
    front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    front.bind(("127.0.0.1", a.listen))
    back = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    back.bind(("127.0.0.1", 0))
    server = (a.to_host, a.to_port)

    client = None
    queue = []          # [(due_monotonic, seq, dir, data)]  dir: "up"=客户端→服务器
    seq = 0
    n_up = n_dn = 0

    def due() -> float:
        d = a.delay_ms
        if a.jitter_ms > 0.0:
            d += rng.uniform(-a.jitter_ms, a.jitter_ms)
        return time.monotonic() + max(d, 0.0) / 1000.0

    print("[proxy] 127.0.0.1:%d <-> %s:%d  单向 %gms ±%gms(RTT ≈ %gms)"
          % (a.listen, a.to_host, a.to_port, a.delay_ms, a.jitter_ms, a.delay_ms * 2),
          flush=True)

    last_stat = time.monotonic()
    while True:
        now = time.monotonic()
        timeout = 0.02
        if queue:
            timeout = max(0.0, min(timeout, queue[0][0] - now))
        ready, _, _ = select.select([front, back], [], [], timeout)
        for s in ready:
            data, addr = s.recvfrom(65535)
            if s is front:
                client = addr
                n_up += 1
                heapq.heappush(queue, (due(), seq, "up", data))
            else:
                n_dn += 1
                heapq.heappush(queue, (due(), seq, "dn", data))
            seq += 1
        now = time.monotonic()
        while queue and queue[0][0] <= now:
            _, _, direction, data = heapq.heappop(queue)
            if direction == "up":
                back.sendto(data, server)
            elif client is not None:
                front.sendto(data, client)
        if now - last_stat >= 5.0:
            last_stat = now
            print("[proxy:%d] 上行 %d 包 / 下行 %d 包 / 排队 %d"
                  % (a.listen, n_up, n_dn, len(queue)), flush=True)


if __name__ == "__main__":
    main()
