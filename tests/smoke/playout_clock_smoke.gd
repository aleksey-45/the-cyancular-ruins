extends SceneTree

# PlayoutClock 的三条规则(配「副本位置改 playout 缓冲插值」)。
# ★ 为什么这一支值一个新文件:PlayoutClock 是新的纯逻辑件(RefCounted),现有 4 支冒烟都不覆盖它;而它三条规则治的是一个已经发生过的缺陷 —— 2026-09-22 那套「双快照 tick 域 alpha 插值」退化的根因就是每收一包把渲染时钟重置到 latest - 1(⇒ 缓冲深度 0 ⇒ 画的就是最新包原值 ⇒ 用户报的「位置一跳一跳,看起来敌方掉帧」)。见 scenes/player/player_replica.gd 的文件头。
# 通过 = PLAYOUT CLOCK OK(n 条断言),判据 grep 文本(不看退出码)。
# ⚠ -s 脚本一旦解析/运行出错就走不到 quit()、进程永久挂起 ⇒ 跑它一律套外层 timeout。

const EXPECTED_CHECKS := 4
const PLAYOUT_TICKS := 3
const DT := 1.0 / 60.0

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ── ① 每帧推进 ≈1 tick(稳态)──
	# ★ 抓两个相反的实现错误:每包重置(推进量会出现 0 或跳变)与冻结(推进量恒 0)。★ 先喂一个 tick 把时钟启动掉:第一个包上 render_tick 会被初始化到 latest - playout(从 0 跃到那里),那是初始化、不是「一帧的推进」⇒ 不能算进统计(否则这条断言自己假红)。
	var c := PlayoutClock.new(PLAYOUT_TICKS)
	c.on_snapshot(0)
	var prev := c.render_tick
	var min_a := 1e9
	var max_a := -1e9
	for i in 200:
		if i < 120:
			c.on_snapshot(i + 1)          # 每帧恰好一个快照
		c.advance(DT)
		var d := c.render_tick - prev
		prev = c.render_tick
		min_a = minf(min_a, d)
		max_a = maxf(max_a, d)
	# 前 120 帧稳态,后 80 帧**没有快照**(模拟丢包停流):两段都要 ≈1 tick/帧。
	_chk(min_a > 0.5 and max_a < 1.5,
			"每帧推进必须落在 0.5~1.5 tick(实得 %.4f~%.4f;=1.0 是稳态)" % [min_a, max_a])

	# ── ② 抖动/乱序到达下单调 + 停流后仍在推进 ──
	# ★★ 夹具必须抖动 + 乱序,否则这条断言是空转的(实测核对过):「每收一包就重置时钟」那种错法在稳态 1 包/帧(甚至 0/2 交替)下与正确实现数值自洽 ⇒ 必须让到达节奏与 tick 节奏错开,并且掺迟到的旧包(世界包走 unreliable = UNSEQUENCED,乱序真会发生)才露馅:旧包把 latest 往回带 ⇒ 重置式实现会把渲染时刻往回拽(画面倒退),正确实现用 maxi 忽略它。
	var c2 := PlayoutClock.new(PLAYOUT_TICKS)
	c2.on_snapshot(0)                     # 先启动,把初始化跃变排除在单调性统计之外
	var monotone := true
	var p2 := c2.render_tick
	var tick := 0
	var min_b := 1e9
	var max_b := -1e9
	for i in 90:                          # 90 帧喂出 90 个 tick(均值 1/帧):0,0,+1,+1,+3
		match i % 5:
			2:
				tick += 1
				c2.on_snapshot(tick)
			3:
				tick += 1
				c2.on_snapshot(tick)
			4:
				tick += 3
				c2.on_snapshot(tick)
				c2.on_snapshot(tick - 1)   # ★ 迟到的旧包(乱序)
			_:
				pass                       # 这一帧没有包
		c2.advance(DT)
		var d2 := c2.render_tick - p2
		min_b = minf(min_b, d2)
		max_b = maxf(max_b, d2)
		if d2 < -1e-6:
			monotone = false
		p2 = c2.render_tick
	var frozen_at := c2.render_tick
	for i in 30:                          # 30 帧一个包都没有
		c2.advance(DT)
		if c2.render_tick < p2 - 1e-6:
			monotone = false
		p2 = c2.render_tick
	_chk(monotone and min_b > 0.5 and max_b < 1.5 and c2.render_tick > frozen_at + 20.0,
			"抖动/乱序到达下必须单调且每帧推进 0.5~1.5 tick(实得 %.4f~%.4f,单调=%s),停流 30 帧仍推进 +%.2f" % [
					min_b, max_b, str(monotone), c2.render_tick - frozen_at])

	# ── ③ 纠偏:服务器比渲染快 1% ⇒ 1 秒内必须把差拉回 ≤1 tick ── ★ 抓「不纠偏」:不纠偏时偏差会线性累积(300 帧后 ≈5 tick ⇒ 缓冲要么穿底要么涨爆)。
	var c3 := PlayoutClock.new(PLAYOUT_TICKS)
	c3.on_snapshot(0)
	for i in 300:
		var t3 := int(round(float(i) * 1.0167))       # 60 帧喂出 ~61 tick
		if t3 > 0:
			c3.on_snapshot(t3)
		c3.advance(DT)
	# ★ 断言改成「时钟必须跟上它自己的参考」(而不是硬编码 300×1.0167 − playout):深度现在是抖动驱动的(到达延迟 95 分位,见 playout_clock.gd ③)⇒ 参考的绝对值会随夹具变化,硬编码会变成一条「改深度就红」的脆判据。
	#   真正要钉的不变量是「别让误差失控增长」。突变体(去掉纠偏)会线性累积到 ~5 tick ⇒ 这条照样抓得住(实测 M12 CAUGHT)。
	_chk(absf(c3.target_tick() - c3.render_tick) <= 2.0,
			"快 1%% 的服务器下,300 帧后时钟须跟上**自己的参考** ±2 tick(参考 %.2f、时钟 %.2f、差 %.2f)" % [
					c3.target_tick(), c3.render_tick, c3.target_tick() - c3.render_tick])

	# ── ④ 参考不许是「最新收到的包」── 抓的缺陷:把参考换回 latest − playout(latest = 最新已收到 tick)。
	#   那样在停流期间参考一个 tick 都不动(它只能跟着包走),而正确实现(按本地时间推进 + 窗口最小延迟选样)在停流期间照样按 ≈1 tick/帧 走 —— 这正是「抖动能被吸收」的前提。
	#   ★ 依据:没有任何一手来源主张目标 = 最新样本(NTP RFC 5905 §10 是窗口挑最小 delay;Valve/Bernier 2003 明说「向最新目标移动」的方案在包间隔不固定时更差);逐条出处见 docs/eng/netcode-playout-clock-sync-sources.md。
	var c4 := PlayoutClock.new(PLAYOUT_TICKS)
	c4.on_snapshot(0)
	for i in 40:                          # 先喂满窗口,让参考稳下来
		c4.on_snapshot(i + 1)
		c4.advance(DT)
	var ref_at := c4.target_tick()
	for i in 25:                          # 25 帧**一个包都没有**
		c4.advance(DT)
	_chk(c4.target_tick() > ref_at + 20.0,
			"停流 25 帧后**参考**(target_tick)仍须按 ≈1 tick/帧 推进(实得 +%.2f;追最新包时这里恒为 0)" % [
					c4.target_tick() - ref_at])

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [
				_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("PLAYOUT CLOCK OK(%d 条断言:每帧推进/单调停流/纠偏/参考非最新)" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("PLAYOUT CLOCK FAILED: %d 处" % _fails.size())
		quit(1)
