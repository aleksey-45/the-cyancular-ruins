extends Node

# 菜单流转自动探针(挂 root,穿越 change_scene 存活):
# 模拟 主菜单→(单人面板→开始探索 / 多人 / 设置) 的真实按钮点击流转,
# 验证场景切换、渲染链与暂停层;带窗口运行时把玩家所见截图存到 user://。
# 由 main_menu._ready 在命令行含 --autotest-* 时挂载,平时零开销:
#   -- --autotest-sp     主菜单→单机面板→开始探索→(Esc 暂停/恢复验证)→回主菜单→截图
#   -- --autotest-mp     主菜单→多人匹配页→截图
#   -- --autotest-royale 主菜单→大乱斗大厅→截图
#   -- --autotest-set    主菜单→设置页→截图
#   -- --autotest-level  直接切 Level0(只验世界加载,不经过菜单流转)
#   -- --autotest-ver    主菜单→版本信息面板(弹层,**不切场景**,故无场景硬断言,见 _run)→截图
#   -- --autotest-switch 连做**两趟**「进单机 → 回主菜单」往返(量换场耗时;配合 --perf-switch)
#   -- --autotest-play   进单机 → **打枪 + 打炮**(真的开火、引爆、拆砖)→ 回主菜单 → 退出游戏

var mode := ""   # sp / mp / set / level / ver / switch / play(由 main_menu 经 cmdline 参数注入)

func _ready() -> void:
	_run()


func _run() -> void:
	var tree := get_tree()
	await tree.create_timer(1.2).timeout   # 等浮现动画
	if mode == "switch":
		await _run_switch_roundtrips(tree)
		print("AUTOTEST[switch]: DONE")
		tree.quit(0)
		return
	if mode == "play":
		await _run_play_session(tree)
		return
	if mode == "level":
		tree.change_scene_to_file("res://scenes/level_0.tscn")
	elif mode == "sp":
		_press_by_text(tree.current_scene, "单 人 模 式")
		await tree.create_timer(0.4).timeout
		_press_by_text(tree.current_scene, "开 始 探 索")
	elif mode == "mp":
		_press_by_text(tree.current_scene, "多 人 对 战")
	elif mode == "royale":
		_press_by_text(tree.current_scene, "大 乱 斗")
	elif mode == "set":
		_press_by_text(tree.current_scene, "设 置")
	elif mode == "ver":
		_press_by_text(tree.current_scene, "版 本 信 息")
	await tree.create_timer(1.5).timeout
	var cur := tree.current_scene
	print("AUTOTEST[%s]: 当前场景 = %s" % [mode, cur.scene_file_path if cur != null else "<null>"])
	_dump_render_chain(tree, cur)
	# ★ 硬断言:每个**会切场景**的模式都必须真的抵达目标场景。
	# 少了这条,本探针会「假通过」:末尾唯一的硬断言是「回主菜单后 = main_menu.tscn」,
	# 而"从没离开过主菜单"(菜单文案被改 → 找不到按钮 → 一次都没点到)正好满足它 ——
	# mp/set 原先只 print 到达情况,文案一变就静默 DONE。
	# sp 那句原本内联在此,现与 mp/set 共用同一个函数(同形,不抄三遍)。
	# ver **不列在此**:版本信息是弹层,全程不切场景 —— 对它断言 scene 路径是同义反复
	# (「停在 main_menu」正是它该有的样子,连"一次都没点到按钮"也照样满足),不是硬断言。
	var must_reach := {
		"sp": "level_0.tscn",
		"mp": "matchmaking.tscn",
		"set": "settings_menu.tscn",
		"royale": "royale_lobby.tscn",
	}
	if must_reach.has(mode) and not _require_scene(tree, str(must_reach[mode])):
		return
	if mode == "sp":
		await _verify_pause(tree)
		await _verify_go_menu(tree)
	await _shot(tree, "autotest_%s.png" % mode)
	print("AUTOTEST[%s]: DONE" % mode)
	tree.quit(0)


# ── switch 模式:两趟「进单机 → 回主菜单」,把 safe_change_scene 的两条路径都走到 ──
# 为什么要两趟:`Level0.safe_change_scene` 的收尾有两个动作,付账时机不同 ——
#   · `remove_child(old)`(整棵旧世界递归摘树):**每趟都付**,第 1 趟也付;
#   · `_retired.free()`(同步销毁上一整具世界):**第 2 趟起才付**(第 1 趟 _retired 还是空)。
# 用户报的"有些时候才卡"正指向后者,而项目自己的 recon 把这条列为**从未实测**(见
# .superpowers/sdd/l4-recon.md 的"第 2 次及以后退出")。本模式就是把它变成可测的。
# 数字由 level_0.gd 的 `_perf_log` 打,需同带 `-- --perf-switch`(不带则只有流程、没有数字)。
func _run_switch_roundtrips(tree: SceneTree) -> void:
	for i in range(2):
		_press_by_text(tree.current_scene, "单 人 模 式")
		await tree.create_timer(0.4).timeout
		_press_by_text(tree.current_scene, "开 始 探 索")
		await tree.create_timer(1.5).timeout
		var lvl := tree.current_scene
		var lvl_path := str(lvl.scene_file_path) if lvl != null else "<null>"
		if not lvl_path.ends_with("level_0.tscn"):
			print("AUTOTEST[switch]: 第 %d 趟未进入 level_0.tscn(实际 %s)" % [i + 1, lvl_path])
			tree.quit(1)
			return
		print("AUTOTEST[switch]: 第 %d 趟已进单机 —— 下面这组 [perf-switch] = 第 %d 次退出" % [i + 1, i + 1])
		_press_esc()
		await tree.create_timer(0.4).timeout
		_press_by_text(tree.current_scene, "回到主菜单")
		# ★ 量**用户看得见的东西**:换场后 90 帧的**帧间隔**,而不是 safe_change_scene 内部
		#   各步骤的耗时 —— 内部步骤加起来只有几十毫秒,而"卡不卡"取决于有没有一帧被拖长。
		#   逐帧打点还顺带回答"分帧拆除器本身会不会把卡顿摊成一串小顿"(预算 3ms/帧)。
		var worst := 0.0
		var total := 0.0
		var worst_at := -1
		var prev := Time.get_ticks_usec()
		for fi in range(90):
			await tree.process_frame
			var now := Time.get_ticks_usec()
			var dt := float(now - prev) / 1000.0
			prev = now
			total += dt
			if dt > worst:
				worst = dt
				worst_at = fi
		print("AUTOTEST[switch]: 第 %d 趟换场后 90 帧帧间隔 —— 最大 %.1f ms(第 %d 帧),平均 %.1f ms" % [
				i + 1, worst, worst_at, total / 90.0])
		var cur := tree.current_scene
		var cur_path := str(cur.scene_file_path) if cur != null else "<null>"
		if not cur_path.ends_with("main_menu.tscn"):
			print("AUTOTEST[switch]: 第 %d 趟未回到 main_menu.tscn(实际 %s)" % [i + 1, cur_path])
			tree.quit(1)
			return
		print("AUTOTEST[switch]: 第 %d 趟已回主菜单" % [i + 1])


# ── play 模式:真的打一局再退 —— 这是用户的复现路径 ──
# 为什么必须有它:`switch` 模式只做菜单往返,**一枪没开**。真实游玩后世界状态完全不同 ——
# 场上有子弹(入 "bullet" 组)、有 explosion 动画节点、有 TileHitFx 粒子、有被炸碎并重建过
# 碰撞分块的砖、有敌人尸体。退役那一刻要拆的东西比一具干净世界多得多。
# 用户报的正是"玩好一局以后"才卡,所以量它的必须是一个**打过**的世界。
func _run_play_session(tree: SceneTree) -> void:
	_press_by_text(tree.current_scene, "单 人 模 式")
	await tree.create_timer(0.4).timeout
	_press_by_text(tree.current_scene, "开 始 探 索")
	await tree.create_timer(1.5).timeout
	var lvl := tree.current_scene
	if lvl == null or not str(lvl.scene_file_path).ends_with("level_0.tscn"):
		print("AUTOTEST[play]: 未进入 level_0.tscn")
		tree.quit(1)
		return
	var player: Node = tree.get_first_node_in_group("player")
	if player == null:
		print("AUTOTEST[play]: 场上没有 player 组的节点,无法开火")
		tree.quit(1)
		return
	print("AUTOTEST[play]: 已进单机,开始打枪")
	# 打枪:手枪连点(直接驱动武器,确定性 —— 不走 Input 注入,免得受全局输入状态影响)
	for _i in range(6):
		_fire_once(player)
		await tree.create_timer(0.12).timeout
	# 打炮:切第 5 槽(榴弹发射器)轰两发,等引信炸开 + 碎砖落定
	player.weapons.equip("5")
	await tree.create_timer(0.4).timeout
	for _i in range(2):
		_fire_once(player)
		await tree.create_timer(0.8).timeout
	await tree.create_timer(1.2).timeout
	print("AUTOTEST[play]: 打枪打炮完毕(场上子弹 %d / 敌人 %d)" % [
			tree.get_nodes_in_group("bullet").size(), tree.get_nodes_in_group("enemies").size()])
	# ── 榴弹自杀:把注入瞄准压成"朝正下方",让榴弹在脚下炸开 ──
	# 用 AiInputSource 而不是直接 take_hit:要的就是**真的走一遍**榴弹那条路
	# (出膛→撞地→引信→AoE→玩家掉 50 血→倒地),它才会留下爆炸动画/碎砖/废墟。
	var prev_src = player.input_source
	var suicide_src := AiInputSource.new()
	suicide_src.aim = Vector2(0.0, 1.0)   # 正下方
	player.set_input_source(suicide_src)
	player.weapons.equip("5")
	await tree.create_timer(0.4).timeout
	for _i in range(4):
		_fire_once(player)
		await tree.create_timer(0.7).timeout
		if player.is_downed():
			break
	await tree.create_timer(0.6).timeout
	print("AUTOTEST[play]: 榴弹自杀 → 倒地=%s(hp=%d)" % [str(player.is_downed()), player.hp])
	player.set_input_source(prev_src)
	# ── 倒地按 R:单机原地复位(restart_single = 还原砖/碰撞 + 清弹 + 重刷敌人)──
	# 这条路径本身就重建过整层碰撞,是"玩好一局"里状态最重的一步。
	_press_key("R")
	await tree.create_timer(2.0).timeout
	player = tree.get_first_node_in_group("player")
	if player == null:
		print("AUTOTEST[play]: 复位后找不到玩家")
		tree.quit(1)
		return
	print("AUTOTEST[play]: 按 R 复位后 倒地=%s,敌 %d,场上子弹 %d" % [
			str(player.is_downed()), tree.get_nodes_in_group("enemies").size(),
			tree.get_nodes_in_group("bullet").size()])
	# ── 再开两枪(用户指定的最后一段操作)──
	player.weapons.equip("1")
	await tree.create_timer(0.4).timeout
	for _i in range(2):
		_fire_once(player)
		await tree.create_timer(0.12).timeout
	await tree.create_timer(0.5).timeout
	print("AUTOTEST[play]: 复位后两枪已开,准备回主菜单")
	# ★ `-- --perf-quit-ingame`:走到这里**直接在局内退**(等价于按窗口叉号)—— 这一条
	#   和"回主菜单"是完全不同的成本:引擎同步销毁**整棵在树场景**(整具世界 +
	#   2208×1728 的 SubViewport),而回主菜单那条是把世界退役挂起、不付这笔。
	#   用户报的"玩好一局以后点退出/叉号卡"极可能就是这条,此前从没量过。
	if OS.get_cmdline_user_args().has("--perf-quit-ingame"):
		print("AUTOTEST[play]: MARK-QUIT-INGAME %d ms" % Time.get_ticks_msec())
		await tree.create_timer(0.3).timeout
		tree.quit()
		for _i in range(180):
			await tree.process_frame
		print("AUTOTEST[play]: quit() 后 180 帧进程仍在")
		return
	# 回主菜单:量帧间隔(用户看得见的东西)
	_press_esc()
	await tree.create_timer(0.4).timeout
	_press_by_text(tree.current_scene, "回到主菜单")
	await _measure_frames(tree, "回主菜单", 90)
	var cur := tree.current_scene
	if cur == null or not str(cur.scene_file_path).ends_with("main_menu.tscn"):
		print("AUTOTEST[play]: 未回到 main_menu.tscn(实际 %s)" % (
				str(cur.scene_file_path) if cur != null else "<null>"))
		tree.quit(1)
		return
	# 退出游戏:打点后点「退 出」,进程随即结束 —— 这段尾巴的耗时由外部计时得到
	print("AUTOTEST[play]: MARK-QUIT %d ms" % Time.get_ticks_msec())
	await tree.create_timer(0.3).timeout
	_press_by_text(tree.current_scene, "退 出")
	for _i in range(180):
		await tree.process_frame
	print("AUTOTEST[play]: 点了「退 出」但 180 帧后进程仍在(quit 未生效?)")
	tree.quit(0)


func _fire_once(player: Node) -> void:
	var w = player.weapons.current_weapon()
	if w == null:
		return
	w.fire_cd_timer = 0.0
	w.fire()


# 量"用户看得见的东西":N 帧的**帧间隔**,不是 safe_change_scene 内部各步骤的耗时 ——
# 内部步骤加起来几十毫秒,而"卡不卡"取决于有没有一帧被拖长。逐帧打点还顺带回答
# "分帧拆除器会不会把一次卡顿摊成一串小顿"(预算 3ms/帧)。
func _measure_frames(tree: SceneTree, tag: String, n: int) -> void:
	var worst := 0.0
	var total := 0.0
	var worst_at := -1
	var prev := Time.get_ticks_usec()
	for fi in range(n):
		await tree.process_frame
		var now := Time.get_ticks_usec()
		var dt := float(now - prev) / 1000.0
		prev = now
		total += dt
		if dt > worst:
			worst = dt
			worst_at = fi
	print("AUTOTEST[play]: %s 后 %d 帧帧间隔 —— 最大 %.1f ms(第 %d 帧),平均 %.1f ms" % [
			tag, n, worst, worst_at, total / float(n)])


# ★ 硬断言:点了按钮必须**真的换了场景**(sp=「开始探索」→Level0、mp/set=直接跳页)。
# 返回 false 时本函数已 quit(1),调用方只需 return —— 不能继续走到末尾的「DONE」。
func _require_scene(tree: SceneTree, want: String) -> bool:
	var cur := tree.current_scene
	var actual: String = cur.scene_file_path if cur != null else "<null>"
	if cur != null and actual.ends_with(want):
		return true
	print("AUTOTEST[%s]: 未抵达 %s(实际 %s)——菜单流转断在按钮文案上?" % [mode, want, actual])
	tree.quit(1)
	return false


# 渲染链诊断:WorldViewport 尺寸/子节点、PostProcess、WallLayer 单元数
func _dump_render_chain(tree: SceneTree, cur: Node) -> void:
	if cur != null and cur.get_node_or_null("WorldViewport") != null:
		var wv: SubViewport = cur.get_node("WorldViewport")
		print("AUTOTEST: WorldViewport size=", wv.size, " update_mode=", wv.render_target_update_mode)
		for c in wv.get_children():
			print("  world child: ", c.name, " [", c.get_class(), "]")
		var wl: TileMapLayer = wv.get_node_or_null("WallLayer")
		print("AUTOTEST: WallLayer used_cells=", wl.get_used_cells().size() if wl != null else "null")
	var pp := tree.get_first_node_in_group("post_process")
	print("AUTOTEST: post_process=", pp)


# 暂停层验证:注入 Esc → 树应暂停;再 Esc → 恢复
func _verify_pause(tree: SceneTree) -> void:
	_press_esc()
	await tree.create_timer(0.5).timeout
	print("AUTOTEST: Esc后 paused=", tree.paused, "(应为 true)")
	await tree.process_frame
	await tree.process_frame
	_save_root_png(tree, "user://autotest_sp_pause.png")
	_press_esc()
	await tree.create_timer(0.5).timeout
	print("AUTOTEST: 再Esc后 paused=", tree.paused, "(应为 false)")


# 回主菜单验证(safe_change_scene 路径):开暂停层点「回 到 主 菜 单」,场景应回到 main_menu
func _verify_go_menu(tree: SceneTree) -> void:
	_press_esc()
	await tree.create_timer(0.4).timeout
	_press_by_text(tree.current_scene, "回到主菜单")
	await tree.create_timer(1.5).timeout
	var cur := tree.current_scene
	var ok := cur != null and cur.scene_file_path.ends_with("main_menu.tscn")
	print("AUTOTEST: 回主菜单后场景 = %s %s" % [
		cur.scene_file_path if cur != null else "<null>", "(OK)" if ok else "(失败!应回到 main_menu.tscn)"])
	if not ok:
		tree.quit(1)


# 注入一次 Esc(ui_cancel)
func _press_esc() -> void:
	_press_key("ui_cancel")


# 注入一次按键动作(与 _press_esc 同款,供倒地后的 R 复位等用)
func _press_key(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)


# 截取玩家所见(root 视口)存档;headless 无视口纹理,安全跳过
func _shot(tree: SceneTree, file: String) -> void:
	await tree.process_frame
	await tree.process_frame
	# 只有真的存下去了才报「已存」——headless 跳过时不该声称存了(原实现无条件打印)
	if _save_root_png(tree, "user://" + file):
		print("AUTOTEST: 截图已存 user://" + file)


# 存 root 视口 PNG;返回是否真的写了文件(调用方据此决定要不要报「已存」)。
func _save_root_png(tree: SceneTree, path: String) -> bool:
	# headless(dummy 渲染后端)的 root 视口纹理是空壳:get_image() 会在引擎侧打
	#   ERROR: Parameter "t" is null
	# 污染 CI 的 `grep -ci error` 判读(该判据本要用来抓"场景报错"),故先行跳过。
	# 该分支只在 headless 成立 → 带窗口跑 GUI 的行为完全不受影响。
	if DisplayServer.get_name() == "headless":
		print("AUTOTEST: headless(dummy 后端)无视口纹理,跳过截图 ", path)
		return false
	var tex := tree.root.get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		print("AUTOTEST: 取不到视口纹理,跳过截图 ", path)
		return false
	img.save_png(path)
	return true


# 按文字前缀找按钮并触发(去空格匹配;浮现动画不阻塞 pressed)
func _press_by_text(n: Node, prefix: String) -> void:
	if n == null or not is_instance_valid(n):
		return
	for c in n.get_children():
		if c is Button and str((c as Button).text).replace(" ", "").begins_with(prefix.replace(" ", "")):
			print("AUTOTEST: 点击 \"%s\"" % (c as Button).text)
			(c as Button).pressed.emit()
			return
		_press_by_text(c, prefix)
