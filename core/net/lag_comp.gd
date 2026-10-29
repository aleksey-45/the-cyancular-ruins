class_name LagComp
extends RefCounted

# 命中补偿(favor-the-shooter)的纯逻辑:受害者位置回溯环 + 射手感知滞后折算。
# ★ 纯静态 + 状态由调用方持有 ⇒ `-s` 冒烟(lag_comp_smoke)可以直接测,不引任何 autoload。
# 语义:射手看到的对手比权威晚(RTT/2 传播 + ~67ms playout 插值缓冲),瞄准的就是那个过去;
# 裁决时把受害者按感知滞后回放再测距,治「提前量打空」。上限 REWIND_TICKS:再大会
# 打出「隔墙打死转角后的人」。⚠ 已知边界:复活/换边后 150ms 内环里是死前位置,极端时序下
# 可能吃一记「尸体残影」命中(登记债,不值得为它加复位钩子)。

const REWIND_TICKS := 9            # ≈150ms @60Hz
const SHOOTER_LAG_BASE_MS := 67    # 对手副本的 playout 缓冲(PLAYOUT_TICKS=4),与渲染侧同源口径

# rings: role -> {"pts": PackedVector2Array(REWIND_TICKS), "head": int, "tick": int}
# tick 由调用方给(每物理 tick +1);环只认「最新一拍 == 当前 tick」的记录(错拍 = 视为未跟上)。
static func record(rings: Dictionary, role: int, pos: Vector2, tick: int) -> void:
	var ring: Dictionary = rings.get(int(role), {})
	if ring.is_empty():
		var pts := PackedVector2Array()
		pts.resize(REWIND_TICKS)
		ring = {"pts": pts, "head": -1, "tick": tick, "n": 0}
		rings[int(role)] = ring
	var pts: PackedVector2Array = ring["pts"]
	ring["head"] = (int(ring["head"]) + 1) % REWIND_TICKS
	pts[int(ring["head"])] = pos
	ring["tick"] = tick
	ring["n"] = mini(int(ring["n"]) + 1, REWIND_TICKS)


# 回溯位置:ticks_back 钳到 [0, 环里已有的最老一拍](开局头几拍自然退化为少回溯几拍)。
# 环缺位/错拍 ⇒ 返回 fallback(调用方给受害者当前位置)。
static func rewound(rings: Dictionary, role: int, tick: int, ticks_back: int, fallback: Vector2) -> Vector2:
	var ring: Dictionary = rings.get(int(role))
	if ring == null or int(ring["tick"]) != tick:
		return fallback
	var tb: int = clampi(ticks_back, 0, int(ring.get("n", REWIND_TICKS)) - 1)
	var idx: int = (int(ring["head"]) - tb + REWIND_TICKS * 2) % REWIND_TICKS
	return (ring["pts"] as PackedVector2Array)[idx]


# 感知滞后 → 回溯 tick 数:RTT/2 + playout 缓冲,钳 [0, REWIND_TICKS-1]。
# 无 peer(AI 补位)= 0:AI 读的就是权威当前态,没有感知滞后可补。
static func delay_ticks(rtt_ms: int, has_peer: bool) -> int:
	if not has_peer:
		return 0
	var ms := SHOOTER_LAG_BASE_MS + rtt_ms / 2
	return clampi(int(round(ms / (1000.0 / 60.0))), 0, REWIND_TICKS - 1)
