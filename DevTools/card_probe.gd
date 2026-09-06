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
	if fails.is_empty():
		print("CARDS-PROBE OK(schema/校验/往返/状态/占位图 全部通过)")
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
