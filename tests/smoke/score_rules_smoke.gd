extends SceneTree

# 计分口径的**性质**冒烟(纯逻辑,无 autoload)。
# 跑法: source tests/env.sh && "$GODOT" --headless --path . -s res://tests/smoke/score_rules_smoke.gd
# 通过 = `SCORE RULES: ALL-OK` 退出 0。
#
# 注意： 本文件**刻意不钉权重数值**(100/50/5/50/100 是首版默认值、预期会被调,见 spec §3.2),
#   钉的是**性质**:击杀更多  ->  ACS 更高 / 死亡更多  ->  ACS 更低 / 惩罚  ->  ACS 更低 /
#   助攻  ->  ACS 更高 / **伤害只被计入一次**。
#   调权重不该让本文件变红;把某一项从公式里删掉**必须**让它变红(见 Task 3 Step 1 的反证)。
#
# - 空载守卫:load 失败立刻 quit(1),否则抛错走不到 quit() → 进程永久挂起。

func _initialize() -> void:
	var script = load("res://core/sim/score_rules.gd")
	if script == null:
		print("SCORE RULES: FAIL(load res://core/sim/score_rules.gd 失败 —— 文件还没建?)")
		quit(1)
		return
	var fails: Array[String] = []
	# 直取静态口:本文件不 `new()`,全部是 static func。
	var SR: GDScript = script

	# ① 击杀更多  ->  ACS 更高
	var a_k = SR.acs(SR.kscore(1, 0, 0, 0), 1)
	var b_k = SR.acs(SR.kscore(3, 0, 0, 0), 1)
	if not (b_k > a_k):
		fails.append("★ 击杀更多 ⇒ ACS 更高 不成立(%f → %f)" % [a_k, b_k])

	# ② 死亡更多  ->  ACS 更低(今天**不成立**;这条是新性质,也是"MVP 常在败方"的守卫)
	var a_d = SR.acs(SR.kscore(3, 0, 0, 0), 1)
	var b_d = SR.acs(SR.kscore(3, 0, 0, 3), 1)
	if not (b_d < a_d):
		fails.append("★ 死亡更多 ⇒ ACS 更低 不成立(%f → %f);★ 反证用:把 kscore 里的死亡项删掉即红"
				% [a_d, b_d])

	# ③ 惩罚 > 0  ->  ACS 更低
	var a_p = SR.acs(SR.kscore(3, 0, 0, 0, 0, 0, 0), 1)
	var b_p = SR.acs(SR.kscore(3, 0, 0, 0, 0, 0, 1), 1)   # 击杀队友 1 次
	if not (b_p < a_p):
		fails.append("★ 惩罚 > 0 ⇒ ACS 更低 不成立(%f → %f)" % [a_p, b_p])

	# ④ 助攻  ->  ACS 更高
	var a_a = SR.acs(SR.kscore(2, 0, 0, 0), 1)
	var b_a = SR.acs(SR.kscore(2, 2, 0, 0), 1)
	if not (b_a > a_a):
		fails.append("★ 助攻 ⇒ ACS 更高 不成立(%f → %f)" % [a_a, b_a])

	# ⑤ 注意： **伤害只被计入一次**(spec §1.4 那条必须写死的口径)
	#   构造"只把伤害 +100、其余全同"的两个 case,断言 ACS 的增量**恰好**等于
	#   `100 ÷ DAMAGE_PER_POINT ÷ 局数` —— 而不是它再加上那 100 伤害本身。
	#   - 两个数(2 局):`d0 = (0 + 100/5)/2 = 10`、`d1 = (0 + 200/5)/2 = 20`
	#      ->  期望增量 = `100/5/2` = **10**。
	#   - 测试有效性:`acs = (kscore + dealt) / 局数` 那种双计实现给出 `d0 = (20+100)/2 = 60`、
	#     `d1 = (40+200)/2 = 120`  ->  增量 **60**(不是 10) ->  直接断言失败。
	var d0 = SR.acs(SR.kscore(0, 0, 100, 0), 2)     # 总伤害 100、2 局
	var d1 = SR.acs(SR.kscore(0, 0, 200, 0), 2)     # 只多 100 伤害
	var want_delta := 100.0 / float(SR.DAMAGE_PER_POINT) / 2.0
	if absf((d1 - d0) - want_delta) > 0.0001:
		fails.append("★ 伤害只被计入一次:期望 ACS 增量 %f,实得 %f(差值 %f)—— 差得更大就是双计"
				% [want_delta, d1 - d0, (d1 - d0) - want_delta])

	# ⑥ 惩罚的构成:队友/自己伤害按**同倍率**(与伤害 1:1 冲销),击杀队友另加一份重罚
	var p_dmg = SR.penalty(50, 50, 0)               # (50+50)/5 = 20
	var p_kill = SR.penalty(0, 0, 1)                # 0 + 1×TEAM_KILL_PENALTY
	if p_dmg != 50 / int(SR.DAMAGE_PER_POINT) * 2:
		fails.append("★ 惩罚的伤害项应 = (友伤+自伤)/5(50+50 → 20),实得 %d" % p_dmg)
	if p_kill != int(SR.TEAM_KILL_PENALTY):
		fails.append("★ 惩罚的击杀队友项应 = TEAM_KILL_PENALTY,实得 %d" % p_kill)

	# ⑦ 局数下限 1:0 局不得除零(既有口径 `maxi(rounds, 1)`)
	if SR.acs(SR.kscore(1, 0, 0, 0), 0) != float(SR.kscore(1, 0, 0, 0)):
		fails.append("★ 局数 0 时必须按 1 局算(不得除零/不得给 0)")

	if fails.is_empty():
		print("SCORE RULES: ALL-OK")
		quit(0)
	else:
		print("SCORE RULES: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
