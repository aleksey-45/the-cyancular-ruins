extends SceneTree

# 对局得分与排名计算规则冒烟测试：
# 验证纯逻辑层面的击杀得分、团队计分规则、自伤/队友伤害过滤以及 MVP 计算逻辑。

func _initialize() -> void:
	var script = load("res://core/sim/score_rules.gd")
	if script == null:
		print("SCORE RULES: FAIL(load res://core/sim/score_rules.gd 失败 —— 文件还没建?)")
		quit(1)
		return
	var fails: Array[String] = []
	# 直接通过静态方法调用：ScoreRules 全由 static func 构成
	var SR: GDScript = script

	# ① 击杀更多  ->  ACS 更高
	var a_k = SR.acs(SR.kscore(1, 0, 0, 0), 1)
	var b_k = SR.acs(SR.kscore(3, 0, 0, 0), 1)
	if not (b_k > a_k):
		fails.append("★ 击杀更多 ⇒ ACS 更高 不成立(%f → %f)" % [a_k, b_k])

	# ② 死亡更多  ->  ACS 更低(今天不成立;这条是新性质,也是"MVP 常在败方"的防御性校验)
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

	var d0 = SR.acs(SR.kscore(0, 0, 100, 0), 2)     # 总伤害 100、2 局
	var d1 = SR.acs(SR.kscore(0, 0, 200, 0), 2)     # 只多 100 伤害
	var want_delta := 100.0 / float(SR.DAMAGE_PER_POINT) / 2.0
	if absf((d1 - d0) - want_delta) > 0.0001:
		fails.append("★ 伤害只被计入一次:期望 ACS 增量 %f,实得 %f(差值 %f)—— 差得更大就是双计"
				% [want_delta, d1 - d0, (d1 - d0) - want_delta])

	# ⑥ 惩罚的构成:队友/自己伤害按同倍率(与伤害 1:1 冲销),击杀队友另加一份重罚
	var p_dmg = SR.penalty(50, 50, 0)               # (50+50)/5 = 20
	var p_kill = SR.penalty(0, 0, 1)                # 0 + 1×TEAM_KILL_PENALTY
	if p_dmg != 50 / int(SR.DAMAGE_PER_POINT) * 2:
		fails.append("★ 惩罚的伤害项应 = (友伤+自伤)/5(50+50 → 20),实得 %d" % p_dmg)
	if p_kill != int(SR.TEAM_KILL_PENALTY):
		fails.append("★ 惩罚的击杀队友项应 = TEAM_KILL_PENALTY,实得 %d" % p_kill)

	# ⑦ 局数下限兜底：0 局时按 1 局计算，防止除零错误
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
