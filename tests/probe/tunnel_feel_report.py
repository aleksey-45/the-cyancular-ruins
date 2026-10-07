#!/usr/bin/env python3
"""汇总 P2P 隧道多实例基准测试日志（主机端与客机端），生成网络性能与帧耗时对比报告。

输入：主机端与客机端的测试运行日志。
输出指标：
  - 帧耗时统计：p50 / p95 / p99 / max 帧耗时及卡顿帧占比（源自 tunnel_feel_measure.gd 采样）
  - 网络指标：输入未确认积压、往返时延（ping）、回滚频率（源自客户端 [netstat] 遥测）
  - 服务端指标：输入队列待处理长度（源自服务端 [netstat-srv] 遥测）
"""
import re
import sys

NUM = r"[-+]?\d+(?:\.\d+)?"


def load(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def side_of(text, default="?"):
    m = re.search(r"^side=(\S+)", text, re.M)
    return m.group(1) if m else default


def detail(text):
    """探针打的 `  key=value` 明细块 -> dict。"""
    out = {}
    for m in re.finditer(r"^\s{2}([a-z_0-9]+)=(.*)$", text, re.M):
        out[m.group(1)] = m.group(2).strip()
    return out


def fnum(d, k, default=None):
    try:
        return float(d[k])
    except (KeyError, ValueError, TypeError):
        return default


def netstat(text):
    """客户端 `[netstat]` 逐秒读数。"""
    rows = []
    for m in re.finditer(
        r"\[netstat\] seq=(\d+) ack=(\d+) gap=(\d+)\(滞后 (" + NUM + r")ms\) \| ping=(" + NUM
        + r")ms \| 扣网后积压≈(" + NUM + r")ms \| 回滚累计=(\d+) \(\+(\d+)/s\)"
        r" \| pos=\((" + NUM + r"),(" + NUM + r")\) \| 物理步/秒=(\d+) 渲染fps=(\d+)",
        text,
    ):
        rows.append({
            "gap": int(m.group(3)), "lag_ms": float(m.group(4)), "ping": float(m.group(5)),
            "backlog_ms": float(m.group(6)), "rb_total": int(m.group(7)), "rb_rate": int(m.group(8)),
            "steps": int(m.group(11)), "fps": int(m.group(12)),
        })
    return rows


def netstat_srv(text):
    """服务端 `[netstat-srv] 待消费队列(包) 1=0, 2=3` 逐秒读数。"""
    rows = []
    for m in re.finditer(r"\[netstat-srv\] 待消费队列\(包\) (.*)$", text, re.M):
        q = {}
        for kv in m.group(1).split(","):
            p = kv.strip().split("=")
            if len(p) == 2 and p[1].strip().isdigit():
                q[p[0]] = int(p[1])
        if q:
            rows.append(q)
    return rows


def rng(rows, key):
    vals = [r[key] for r in rows if key in r]
    return (min(vals), max(vals), sum(vals) / len(vals)) if vals else None


def fmt(rows, key, unit=""):
    r = rng(rows, key)
    if not r:
        return "—"
    return "%.0f/%.0f/%.1f%s" % (r[0], r[1], r[2], unit)


def main():
    if len(sys.argv) < 3:
        print("用法: tunnel_feel_report.py <host.log> <guest.log> [server.log]")
        return 2
    host_txt, guest_txt = load(sys.argv[1]), load(sys.argv[2])
    # 服务端遥测不在房主的 stdout 里 —— 服务端是客户端 `LocalServer` **另起的子进程**,
    # Windows 下父进程看不到它的 stdout。它走 `GameLog` 落到 `<房主目录>/log/server.log`,
    # 故第三参由 `.sh` 指过去。缺它则下面那一栏为空(并写出成因)。
    srv_txt = load(sys.argv[3]) if len(sys.argv) > 3 else ""
    # 服务端日志每行带 `[HH:MM:SS] ` 时间戳前缀,解析器按行匹配故不受影响。

    print()
    print("=" * 78)
    print("P2P 隧道网络性能与流畅度度量报告（固定地图 + 确定性操作序列；同机双实例）")
    print("=" * 78)

    hd, gd = detail(host_txt), detail(guest_txt)
    sides = [(side_of(host_txt, "host"), hd, host_txt), (side_of(guest_txt, "guest"), gd, guest_txt)]

    print()
    print("%-26s %-22s %-22s" % ("指标项", "主机端", "客机端"))
    print("-" * 78)

    def row(label, key, unit=""):
        cells = []
        for _, d, _t in sides:
            v = fnum(d, key)
            cells.append("—" if v is None else ("%g%s" % (v, unit)))
        print("%-26s %-22s %-22s" % (label, cells[0], cells[1]))

    row("进入对局耗时(秒)", "enter_seconds", "s")
    row("测试运行时长(秒)", "seconds_played", "s")
    row("采样帧数", "frames")
    row("平均 fps", "fps_avg")
    print("-" * 78)
    row("帧耗时 p50 (ms)", "ft_p50")
    row("帧耗时 p95 (ms)", "ft_p95")
    row("帧耗时 p99 (ms)", "ft_p99")
    row("单帧最大耗时 (ms)", "ft_max")
    row("最大耗时出现时刻 (s)", "ft_max_at", "s")
    print("-" * 78)

    # 卡顿帧统计
    for label, key in (("卡顿帧 >16.7ms (掉1帧)", "stall_gt16_7"),
                       ("卡顿帧 >33.3ms (掉2帧)", "stall_gt33_3"),
                       ("严重卡顿帧 >50ms", "stall_gt50")):
        cells = []
        for _, d, _t in sides:
            v = fnum(d, key)
            fr = fnum(d, "frames")
            if v is None or not fr:
                cells.append("—")
            else:
                cells.append("%d (%.2f%%)" % (int(v), 100.0 * v / fr))
        print("%-26s %-22s %-22s" % (label, cells[0], cells[1]))
    print("-" * 78)

    print("%-26s %-22s %-22s" % ("耗时峰值最高的 5 秒",
          hd.get("worst_seconds", "—")[:21], gd.get("worst_seconds", "—")[:21]))
    print("-" * 78)
    print("%-26s %-22s %-22s" % ("EasyTier 转发端口",
          hd.get("tunnel_forward_port", "—"), gd.get("tunnel_forward_port", "—")))
    print("%-26s %-22s %-22s" % ("EasyTier 隧道可用性",
          hd.get("tunnel_available", "—"), gd.get("tunnel_available", "—")))
    print("%-26s %-22s %-22s" % ("本地服务端监听端口",
          hd.get("server_port", "—"), gd.get("server_port", "—")))
    print("%-26s %-22s %-22s" % ("客户端实际连接端口",
          hd.get("connected_port", "—") or "—", gd.get("connected_port", "—")))

    print()
    print("── 网络侧遥测指标（逐秒采样；格式：最小 / 最大 / 均值）──")
    print("%-26s %-22s %-22s" % ("指标项", "主机端", "客机端"))
    print("-" * 78)
    hn, gn = netstat(host_txt), netstat(guest_txt)
    if not hn and not gn:
        print("  (两侧均未检测到 [netstat] 日志行，请确认已传入 `--netstat` 诊断参数)")
    else:
        for label, key, unit in (
            ("往返时延 (ping)", "ping", "ms"),
            ("输入滞后 (gap)", "lag_ms", "ms"),
            ("扣除RTT后输入积压", "backlog_ms", "ms"),
            ("预测回滚频率 (+N/s)", "rb_rate", "/s"),
            ("待处理输入差值 (包)", "gap", ""),
            ("物理帧率 (steps/s)", "steps", ""),
            ("渲染帧率 (fps)", "fps", ""),
        ):
            print("%-26s %-22s %-22s" % (label, fmt(hn, key, unit), fmt(gn, key, unit)))
        tot = rng(hn, "rb_total")
        tot2 = rng(gn, "rb_total")
        print("%-26s %-22s %-22s" % ("累计回滚次数(期末值)",
              "%.0f" % tot[1] if tot else "—", "%.0f" % tot2[1] if tot2 else "—"))
        print()
        print("  指标解读说明（综合多维度评估，避免单看均值）：")
        print("    · 输入滞后：已发送但尚未确认的输入（网络传输中 + 服务端待处理缓冲）。均值代表稳态表现；")
        print("      最大值通常源于对局开局初期的突发补发阶段。")
        print("    · 扣除RTT后积压 = 输入滞后 − ping。该值持续偏高表明服务端消费处理存在瓶颈，")
        print("      需结合下方的服务端输入队列深度交叉验证。")
        print("    · 回滚频率直接影响操作流畅度：频率偏高表明本地预测被频繁修正（拉扯/橡皮筋现象）。")
        print("      主机端同时承担服务端模拟，计算负载高于客机端。")

    srv = netstat_srv(srv_txt)
    print()
    print("── 服务端待处理输入队列（逐秒各角色最大值）──")
    if not srv:
        print("  (未检测到 [netstat-srv] 日志行)")
        print("   - 排查建议：① 服务端进程未接收到 `--netstat` 参数；② 服务端日志未落盘；")
        print("     ③ 运行脚本未正确传入 server.log 路径。默认路径为 `<主机运行目录>/log/server.log`。")
    else:
        roles = sorted({r for row in srv for r in row})
        for r in roles:
            vals = [row[r] for row in srv if r in row]
            print("  角色 %s: 最小 %d / 最大 %d / 均值 %.2f 包"
                  % (r, min(vals), max(vals), sum(vals) / len(vals)))
        print("  - 归因分析：若队列深度保持低位，客户端延迟主要源自网络链路传输；")
        print("    若队列深度持续偏高，表明服务端模拟消费速率成为瓶颈。")
        print("  - 服务端按固定 1 包/物理 tick 速率消费（60/s）；稳态时队列应为 0 或个位数。")

    # 结论与运行环境说明
    print()
    print("=" * 78)
    for name, d in (("主机端", hd), ("客机端", gd)):
        v = d.get("verdict", "?")
        if v != "OK":
            print("  **%s 测试未完成**:%s" % (name, v))
    print("  说明：同机运行多实例共享 CPU 资源，帧耗时开销高于真实双机物理环境；")
    print("      本报告适用于版本架构横向对比，不作为绝对网络性能基线；")
    print("      同机测试无法完全模拟公网复杂 NAT 穿透场景（走中继转发链路）。")
    print("=" * 78)
    return 0


if __name__ == "__main__":
    sys.exit(main())
