extends SceneTree

# 卡编辑器诊断探针(DevTools,headless,代理可跑):
#   1) 默认卡(干员/武器)校验全绿;篡改卡按预期报错
#   2) apply_defaults 补全缺失字段
#   3) save→load 往返一致(落盘后读回 rev/name/skills),验完清理
#   4) .state.json 读写的往返
#   5) 占位徽章纹理可生成、尺寸正确
# 跑法: Godot_console --headless --path . -s res://DevTools/card_probe.gd

func _initialize() -> void:
	var fails: Array[String] = []
	_check_defaults(fails)
	_check_validation(fails)
	_check_roundtrip(fails)
	_check_state(fails)
	_check_placeholder(fails)
	_check_templates(fails)
	_check_cli_bat(fails)
	if fails.is_empty():
		print("CARDS-PROBE OK(schema/校验/往返/状态/占位图/模板/CLI启动器 全部通过)")
		quit(0)
	else:
		print("CARDS-PROBE FAIL | " + "; ".join(fails))
		quit(1)


func _check_defaults(fails: Array[String]) -> void:
	for type in CardSchema.CARD_TYPES:
		var card := CardSchema.make_default(type, "probe_default")
		card["name"] = "探针默认卡"   # 新建卡在表单里命名;make_default 的空名本就该被校验拦下
		var errs := CardSchema.validate(card)
		if not errs.is_empty():
			fails.append("%s 默认卡校验失败:%s" % [type, ", ".join(errs)])


func _check_validation(fails: Array[String]) -> void:
	# 坏 id
	var c := CardSchema.make_default(CardSchema.TYPE_OPERATOR, "Bad-Id")
	if CardSchema.validate(c).is_empty():
		fails.append("坏 id 未被拦截")
	# 空名(默认卡 name 为空,应恰好报这一项)
	c = CardSchema.make_default(CardSchema.TYPE_OPERATOR, "op_x")
	var name_errs := CardSchema.validate(c)
	if name_errs.size() != 1 or not name_errs[0].contains("名称"):
		fails.append("空名称未按预期报错:%s" % ", ".join(name_errs))
	# 4 条技能 + 坏 key + 重复 key
	c = CardSchema.make_default(CardSchema.TYPE_OPERATOR, "op_x")
	c["name"] = "测试"
	c["skills"] = [
		{"name": "a", "key": "skill_1", "cooldown": 1.0, "desc": "x"},
		{"name": "b", "key": "skill_1", "cooldown": 1.0, "desc": "x"},
		{"name": "c", "key": "skill_9", "cooldown": 1.0, "desc": "x"},
		{"name": "d", "key": "skill_2", "cooldown": 1.0, "desc": "x"},
	]
	var errs := CardSchema.validate(c)
	if errs.size() < 3:
		fails.append("技能越界/坏 key/重复 key 应至少报 3 项,实际:%s" % ", ".join(errs))
	# 武器坏 kind / slot
	c = CardSchema.make_default(CardSchema.TYPE_WEAPON, "wp_x")
	c["name"] = "测试枪"
	c["kind"] = "sword"
	c["slot"] = -1
	errs = CardSchema.validate(c)
	if errs.size() < 2:
		fails.append("武器坏 kind/负 slot 应至少报 2 项,实际:%s" % ", ".join(errs))
	# 补全:删掉 stats 与 kind_params 再读,应补回默认
	c = CardSchema.make_default(CardSchema.TYPE_OPERATOR, "op_x")
	c.erase("stats")
	c["skills"] = [{"name": "s", "key": "skill_1", "cooldown": 2.0, "desc": "d"}]
	var full := CardSchema.apply_defaults(c)
	if not full.has("stats") or float(full["stats"]["jump_mult"]) != 1.0:
		fails.append("apply_defaults 未补全 stats")
	if int(full["rev"]) != 1 or str(full["card_type"]) != "operator":
		fails.append("apply_defaults 破坏了 envelope")


func _check_roundtrip(fails: Array[String]) -> void:
	var id := "op_probe_roundtrip"
	CardStore.delete_card(CardSchema.TYPE_OPERATOR, id)   # 清历史残留
	var card := CardSchema.make_default(CardSchema.TYPE_OPERATOR, id)
	card["name"] = "往返测试"
	card["skills"] = [{"name": "冲锋", "key": "skill_1", "cooldown": 12.0, "desc": "向前突进"}]
	var errs := CardStore.save_card(card)
	if not errs.is_empty():
		fails.append("保存失败:%s" % ", ".join(errs))
		return
	var back := CardStore.load_card(CardSchema.TYPE_OPERATOR, id)
	if back.is_empty():
		fails.append("读回为空")
	elif int(back["rev"]) != 2 or str(back["name"]) != "往返测试":
		fails.append("往返不一致:rev=%s name=%s" % [str(back.get("rev")), str(back.get("name"))])
	elif (back["skills"] as Array).size() != 1 or str((back["skills"] as Array)[0]["name"]) != "冲锋":
		fails.append("技能往返不一致")
	# 清理(无论断言结果,不留残留)
	CardStore.delete_card(CardSchema.TYPE_OPERATOR, id)
	if CardStore.list_ids(CardSchema.TYPE_OPERATOR).has(id):
		fails.append("删除卡后文件仍在")
	# 校验失败时不落盘
	card["name"] = ""
	errs = CardStore.save_card(card)
	if errs.is_empty():
		fails.append("校验失败的卡不应保存成功")


func _check_state(fails: Array[String]) -> void:
	var original := CardStore.load_state()
	var st := {"operator_skeleton_done": true, "slot6_refactor_done": false}
	CardStore.save_state(st)
	var back := CardStore.load_state()
	if bool(back.get("operator_skeleton_done", false)) != true:
		fails.append(".state.json 往返不一致")
	CardStore.save_state(original)   # 还原现场


func _check_placeholder(fails: Array[String]) -> void:
	var t := PortraitView.make_placeholder(CardSchema.TYPE_OPERATOR, "probe")
	if t == null:
		fails.append("占位徽章生成失败")
	elif t.get_size() != Vector2(12 * 16, 12 * 16):
		fails.append("占位徽章尺寸不符:%s" % t.get_size())
	# 同种子恒定:两次生成像素一致
	var t2 := PortraitView.make_placeholder(CardSchema.TYPE_OPERATOR, "probe")
	if t.get_image().get_data() != t2.get_image().get_data():
		fails.append("占位徽章同种子不同图")


func _check_templates(fails: Array[String]) -> void:
	# 分派矩阵:干员 FIRST/NEXT 由 operator_skeleton_done 决定
	var op := CardSchema.make_default(CardSchema.TYPE_OPERATOR, "op_probe_tmpl")
	op["name"] = "模板探针"
	var r := PromptBuilder.build(op, {"operator_skeleton_done": false})
	if str(r["template"]) != "OPERATOR_FIRST":
		fails.append("骨架未完成应派 OPERATOR_FIRST,实际 %s" % str(r["template"]))
	if not (r["set_flags"] as Array).has("operator_skeleton_done"):
		fails.append("OPERATOR_FIRST 应回传 operator_skeleton_done 标记")
	r = PromptBuilder.build(op, {"operator_skeleton_done": true})
	if str(r["template"]) != "OPERATOR_NEXT" or not (r["set_flags"] as Array).is_empty():
		fails.append("骨架完成后应派 OPERATOR_NEXT 且无新标记")
	# 武器三态:纯设计稿 / 扩槽 FIRST / NEXT
	var wp := CardSchema.make_default(CardSchema.TYPE_WEAPON, "wp_probe_tmpl")
	wp["name"] = "模板探针枪"
	wp["slot"] = 0
	r = PromptBuilder.build(wp, {})
	if str(r["template"]) != "WEAPON_DESIGN":
		fails.append("slot=0 应派 WEAPON_DESIGN,实际 %s" % str(r["template"]))
	wp["slot"] = 6
	r = PromptBuilder.build(wp, {"slot6_refactor_done": false})
	if str(r["template"]) != "WEAPON_FIRST":
		fails.append("slot>5 且未重构应派 WEAPON_FIRST,实际 %s" % str(r["template"]))
	if not (r["set_flags"] as Array).has("slot6_refactor_done"):
		fails.append("WEAPON_FIRST 应回传 slot6_refactor_done 标记")
	r = PromptBuilder.build(wp, {"slot6_refactor_done": true})
	if str(r["template"]) != "WEAPON_NEXT":
		fails.append("重构后应派 WEAPON_NEXT,实际 %s" % str(r["template"]))
	# 近战分支(未做过近战 → 模板附带近战段与标记)
	wp["slot"] = 2
	wp["kind"] = "melee"
	r = PromptBuilder.build(wp, {"melee_branch_done": false})
	if not (r["set_flags"] as Array).has("melee_branch_done"):
		fails.append("近战卡应回传 melee_branch_done 标记")
	# 公共骨架:每份提示词都必须含 id / 完成标记 / 提交纪律(git)
	for card in [op, wp]:
		var p := str(PromptBuilder.build(card, {"operator_skeleton_done": true, "slot6_refactor_done": true, "melee_branch_done": true})["prompt"])
		if not p.contains(str(card["id"])):
			fails.append("%s 提示词缺自身 id" % str(card["id"]))
		if not p.contains("CARD-DONE"):
			fails.append("%s 提示词缺 CARD-DONE 回报约定" % str(card["id"]))
		if not p.contains("git"):
			fails.append("%s 提示词缺提交纪律段" % str(card["id"]))


func _check_cli_bat(fails: Array[String]) -> void:
	var bat := PromptBuilder.build_cli_bat("C:/repo", "C:/p.md", "C:/l.log", "--allowed-tools \"Read\"")
	for needle in ["claude -p", "--permission-mode acceptEdits", PromptBuilder.HEAD_MARK, "< \"C:/p.md\"", "> \"C:/l.log\"", "setlocal enabledelayedexpansion", "cd /d \"C:/repo\""]:
		if not bat.contains(needle):
			fails.append("bat 启动器缺关键片段:%s" % needle)
	if not bat.contains("\r\n"):
		fails.append("bat 启动器必须 CRLF 换行")
	# 全自动档位:permission-mode 被替换而非追加
	var bat2 := PromptBuilder.build_cli_bat("C:/repo", "C:/p.md", "C:/l.log", "", "bypassPermissions")
	if not bat2.contains("--permission-mode bypassPermissions") or bat2.contains("acceptEdits"):
		fails.append("bypassPermissions 档位未正确替换 acceptEdits")
