extends SceneTree

# tint 跨语言 parity 守卫:TerrainAtlas.tint_color 必须与 level_editor/tint.js 逐字节一致。

const EXPECTED_CHECKS := 3

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	# ① golden 表(一行一个手推值;整表一条断言 = D9 口径)。逐字节相等而不是 ±1 容差:tint_color 输出本来就
	#    落在字节上(浮点会漂的话 golden 也对不上),放宽容差只会让"取整规则从 round 变 floor"这种真缺陷漏网。
	var golden := [
		[[255, 0, 0, 255], _desc(1, 5, 4, 7, 7), [255, 64, 0, 255]],        # H=5(+15°):x=0.25 → round(63.75)=64
		[[255, 0, 0, 255], _desc(1, 3, 4, 7, 7), [255, 0, 64, 255]],        # H=3(−15°):h'=345,扇区 5
		[[255, 0, 0, 255], _desc(1, 0, 4, 7, 7), [255, 0, 255, 255]],       # H=0(−60°):h'=300,色相环绕
		[[255, 0, 0, 255], _desc(1, 7, 4, 7, 7), [255, 191, 0, 255]],       # H=7(+45°):x=0.75
		[[255, 255, 255, 255], _desc(1, 4, 2, 4, 7), [204, 204, 204, 255]], # 白 ×0.8 亮度
		[[128, 128, 128, 255], _desc(1, 4, 2, 4, 7), [102, 102, 102, 255]], # 中灰 ×0.8(乘法;加法会得 77)
		[[255, 0, 0, 255], _desc(1, 4, 4, 0, 7), [255, 102, 102, 255]],     # S=0(×0.6)
		[[255, 255, 255, 255], _desc(1, 4, 4, 0, 7), [255, 255, 255, 255]], # s=0 时饱和度档无效
		[[255, 0, 0, 255], _desc(1, 4, 4, 7, 7), [255, 0, 0, 255]],         # s 已满 ×1.3 被 clamp
		[[255, 0, 0, 255], _desc(1, 4, 4, 4, 3), [255, 0, 0, 109]],         # alpha 档 3 = 255×3/7
		[[255, 0, 0, 255], _desc(1, 4, 4, 4, 0), [255, 0, 0, 0]],           # alpha 档 0 = 全透明
		[[255, 0, 0, 255], MapFormatV4.neutral_descriptor(1), [255, 0, 0, 255]],  # 中性 = 恒等
	]
	var bad: Array[String] = []
	for g in golden:
		var cin: Array = g[0]
		var out := TerrainAtlas.tint_color(
				Color(cin[0] / 255.0, cin[1] / 255.0, cin[2] / 255.0, cin[3] / 255.0), int(g[1]))
		var got := [_byte_of(out.r), _byte_of(out.g), _byte_of(out.b), _byte_of(out.a)]
		var want: Array = g[2]
		if got != want:
			bad.append("in=%s desc=0x%X → %s(期望 %s)" % [str(cin), int(g[1]), str(got), str(want)])
	_chk(bad.is_empty(), "golden 表(%d 行,内嵌自 tint.js 测试)%s" % [golden.size(),
			"" if bad.is_empty() else ":" + "; ".join(bad)])

	# ② 中性描述符对全部 8 位输入逐字节恒等(13^4 组;JS 端同一张 vals 表)——去掉"中性档偏移 = 0"
	#    (如 hue 偏移误写成 k*15)或 HSV 往返有损 ⇒ 红。
	var vals := [0, 1, 2, 3, 17, 63, 64, 127, 128, 129, 191, 254, 255]
	var neutral := MapFormatV4.neutral_descriptor(1)
	var mismatches := 0
	var total := 0
	for r in vals:
		for g2 in vals:
			for b in vals:
				for a in vals:
					total += 1
					var o := TerrainAtlas.tint_color(Color(r / 255.0, g2 / 255.0, b / 255.0, a / 255.0), neutral)
					if _byte_of(o.r) != r or _byte_of(o.g) != g2 or _byte_of(o.b) != b or _byte_of(o.a) != a:
						mismatches += 1
	_chk(mismatches == 0, "中性描述符对 %d 组 8 位输入逐字节恒等(%d 组不符)" % [total, mismatches])

	# ③ 输出落在字节上(取整规则 round(clamp01*255) 的唯一落地点在 tint_color 内):
	#    把量化删掉、直接返回连续浮点 ⇒ 通道 ×255 出现 63.75 这类非整数 ⇒ 红。
	var q := TerrainAtlas.tint_color(Color(1.0, 0.0, 0.0, 1.0), _desc(1, 5, 4, 7, 7))
	var quantized := true
	for ch in [q.r, q.g, q.b, q.a]:
		if absf(ch * 255.0 - round(ch * 255.0)) > 0.001:
			quantized = false
	_chk(quantized, "tint_color 输出必须已按 round(clamp01*255) 落在字节上(实得 g=%s)" % str(q.g * 255.0))

	if _checks != EXPECTED_CHECKS:
		_fails.append("实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("TINT PARITY OK(%d 条断言):golden 表 · 中性恒等穷举 · 字节量化" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("TINT PARITY FAILED: %d 处" % _fails.size())
		quit(1)


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


# packDesc(texture, hue, bright, sat, alpha) —— 位域与 level_editor/core/90_desc.js 逐字一致。
func _desc(tex: int, hue: int, bri: int, sat: int, alpha: int) -> int:
	return (tex << 12) | ((alpha & 7) << 9) | ((sat & 7) << 6) | ((bri & 7) << 3) | (hue & 7)


func _byte_of(x: float) -> int:
	return clampi(int(round(clampf(x, 0.0, 1.0) * 255.0)), 0, 255)
