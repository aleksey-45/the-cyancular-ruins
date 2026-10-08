extends SceneTree

# 探针:注入宿主下「**每把真枪 × 三种开火模式**」的边沿出弹判定(审计 §2.6 / Plan B Task 8)。
#
# ★ 来源:Task 2(`1215845`)清掉 `weapon_base.gd` 三处"兜底读全局输入"时,它的**行为证据**
#   是一条**跑完即删的临时 `-s` 守卫**(文本留在 `.superpowers/` 的日志里)⇒ 对回归**零保护**。
#   本探针把那套断言**入库**并参数化:不再是"在 `pistol_test` 上把旗标置起来"的推断,而是
#   **6 把真 `tscn` 逐个实例化 × 三种模式**,这正是 `docs/eng/registered-debt.md` §六 第 5 条
#   写下的"什么时候能销"。
#
# 判据(仓内纪律):grep 本行文本 `WEAPON INJECTED FIRE PROBE: ALL-OK` **且**条数闸不红。
# ★★ 为什么还必须有条数闸:"grep 到 ALL-OK"只证明**没有任何断言失败**,**不证明每条都跑过**
#   —— GDScript 的脚本错误只让**出错的那个函数当场结束**、调用方继续,于是后面那些断言被
#   静默跳过、裁决照样打 ALL-OK(权威表述见 `tests/lib/probe_base.gd` 文件头)。本探针把
#   每把枪的每格都放进 `_run_case()` 里调,一处脚本错误就会让**那一格**的所有断言消失 ⇒
#   `_checks != EXPECTED_CHECKS` 当场红。用 `!=` 而不是 `<`:少了是覆盖缺口,**多了**是覆盖变了
#   (得有人过目 EXPECTED_CHECKS)—— 同 `tests/probe/allscript_probe.gd` 的口径。
#
# ── 形状(Running 前先看这条)──
# `extends SceneTree` ⇒ 用 `-s` 跑,不是 `.tscn`:
#   timeout 90 "$GODOT" --headless --path . -s res://tests/probe/weapon_injected_fire_probe.gd
# (本仓在"`extends SceneTree` 却用 `.tscn` 跑"上栽过两次,见 AGENTS.md。)
#
# ── 这份守卫**测得到**什么 ──
# ① 注入宿主(三边沿各自可置真、并记录**被问了几次**)下,每把真枪 × 每种模式:
#    · 无输入相(阴性对照):**不开火**;
#    · 正相:注入**该模式那一个(些)边沿** ⇒ **同帧**耗 1 发弹 + 冷却置满 + 真的产出弹丸/光束;
#    · 边沿独占:该模式**不问**另外的边沿(全自动不会去问 just_pressed,半自动不会去问 pressed…)。
# ② 每把真 `tscn` **自己声明**的开火旗标(`full_auto` / `heavy_aim`)与定位表一致 ——
#    把"哪把枪是哪种模式"从文献变成机器可查的事实。
#
# ── 这份守卫**测不到**什么(照实登记)──
# · **真链路**:注入 `attack=true` 的宿主在端到端对局里真的出弹 —— 那是 PvP 机器人的事,
#   归用户跑(见 registered-debt §六 第 6 条),本探针一个网络包都不发。
# · **"缺注入接口的宿主 ⇒ 点名报错 + 不开火"**那条形状:它在 `kh_l3_probe` 有**源码守卫**
#   (剥注释后 `weapon_base.gd` 不许出现全局输入查询),够用。**不在这里补行为断言** ——
#   headless 下全局输入恒 false ⇒ "它没凭全局 Input 出弹"**恒真、无牙**
#   (Task 2 实测过的教训:那条病只有源码文本守卫抓得住)。
# · 弹道/伤害/散布/换弹/冷却时长:既有武器冒烟与探针的领域,本探针只问"开不开这一枪"。
# · 枪自己被覆写开火判定:今天没有;本探针的边沿独占断言会让"覆写成别的边沿"当场红,
#   但"覆写成不读注入输入"仍要靠上面那条源码守卫。
#
# ★ 依赖提示:本探针不动全局输入(不 `Input.action_press`),全部经注入宿主驱动。

const DT := 1.0 / 60.0

# 真枪清单 = `data/weapons.json` 的 6 个 `scene`(2026-10-04 grep 复核;别照抄文档里的枚举)。
# `native` = 该 `tscn` **出厂**声明的开火模式(由 tscn 里的 `full_auto` / `heavy_aim` 决定),
# 与下面的旗标断言互为凭据。
const GUNS := [
	{"path": "res://scenes/weapons/pistol_test.tscn", "name": "Pistol", "native": "semi"},
	{"path": "res://scenes/weapons/rifle_test.tscn", "name": "Rifle", "native": "auto"},
	{"path": "res://scenes/weapons/m82a1.tscn", "name": "M82A1", "native": "heavy"},
	{"path": "res://scenes/weapons/s686.tscn", "name": "S686", "native": "semi"},
	{"path": "res://scenes/weapons/grenade_launcher.tscn", "name": "Grenade Launcher", "native": "heavy"},
	{"path": "res://scenes/weapons/laser_gun.tscn", "name": "Laser Gun", "native": "auto"},
]
const MODES := ["semi", "auto", "heavy"]

# ★ 覆盖闸:加了断言就把它一起改;对不上 ⇒ 裁决行红并点名两个数。
const EXPECTED_CHECKS := 158

var _fails: Array[String] = []
var _checks := 0


# 注入宿主:三边沿各自可置真,并**记录被问了几次**(边沿独占断言的唯一凭据)。
# ★ 这里有 `is_attack_*` ⇒ 武器走"注入路径";缺方法的宿主那条形状不在这里测(见文件头)。
class InjectedHost extends Node2D:
	var pressed := false
	var just_pressed := false
	var just_released := false
	var n_pressed := 0
	var n_just_pressed := 0
	var n_just_released := 0

	func clear_edges() -> void:
		pressed = false
		just_pressed = false
		just_released = false

	func reset_counts() -> void:
		n_pressed = 0
		n_just_pressed = 0
		n_just_released = 0

	func get_facing() -> int:
		return 1

	func set_facing(_v: int) -> void:
		pass

	func is_downed() -> bool:
		return false

	func is_attack_pressed() -> bool:
		n_pressed += 1
		return pressed

	func is_attack_just_pressed() -> bool:
		n_just_pressed += 1
		return just_pressed

	func is_attack_just_released() -> bool:
		n_just_released += 1
		return just_released


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("  ok: " + msg)
	else:
		_fails.append(msg)
		printerr("  FAIL: " + msg)


func _initialize() -> void:
	TileDefs.load_defs()
	# 空网格(无墙无水):弹丸不会撞墙消失、光束走满射程 ⇒ 产出计数可预期。
	MazeGenerator.current_grid = _empty_grid(40, 20)

	# ★ 脚本一律在 `_initialize()` 里 load(不在顶层 preload):`-s` 阶段碰会解析 autoload 名的
	#   脚本会把编译期 Parse Error 拖进来(同 `laser_weapon_smoke.gd` 的口径)。
	var bullet_script: Script = load("res://scenes/weapons/bullet_base.gd")
	var beam_script: Script = load("res://scenes/weapons/laser_beam.gd")
	_check(bullet_script != null, "读得到 bullet_base.gd 脚本(读不到 ⇒ 弹丸计数断言恒 0、后续全假)")
	_check(beam_script != null, "读得到 laser_beam.gd 脚本(读不到 ⇒ 光束计数断言恒真)")

	var arena := Node2D.new()
	root.add_child(arena)

	# 先把 6×3 个 (宿主, 武器) 全建好,再统一 `await` 让它们真的入树 ——
	# ★ `SceneTree.root` 在 `_initialize()` 早期**还不在树里**(实测:`root.is_inside_tree()==false`),
	#   子节点要等第一帧才入树、`_ready()` 才会跑(那时 `mag_ammo` 才会被置成 `mag_size`)。
	#   同款注释见 `tests/manual/aim_direction_probe.gd`。
	#   入树后**不再 await**:所有相在一次帧内跑完 ⇒ 弹丸不移动、读数确定。
	var cases: Array = []
	for gun in GUNS:
		var ps: PackedScene = load(gun["path"])
		_check(ps != null, "枪场景可 load:" + gun["path"])
		if ps == null:
			continue   # 少了这一格的断言 ⇒ 条数闸红(失败方向是红,不是静默绿)
		for mode in MODES:
			var host := InjectedHost.new()
			host.global_position = Vector2(300, 300)
			arena.add_child(host)
			var w = ps.instantiate()
			# 原生模式那一格**不动 tscn 的旗标**(证明"出厂就是这模式"也跑得对);
			# 另外两格改旗标(把三条分支都在**这把真枪**上跑一遍)。
			if mode != gun["native"]:
				w.full_auto = mode == "auto"
				w.heavy_aim = mode == "heavy"
			host.add_child(w)
			w.equip(host)
			cases.append({
				"gun": gun, "mode": mode, "host": host, "w": w,
				"native_case": mode == gun["native"],
			})
	await physics_frame
	await physics_frame

	# ── ① 出厂旗标(把定位表变成机器可查的事实)──
	for c in cases:
		if not c["native_case"]:
			continue
		var gun: Dictionary = c["gun"]
		var w = c["w"]
		_check(w.full_auto == (gun["native"] == "auto"),
				"%s 的 tscn 声明 full_auto=%s(定位表说 native=%s;改了 tscn 就得改定位表)"
				% [gun["name"], w.full_auto, gun["native"]])
		_check(w.heavy_aim == (gun["native"] == "heavy"),
				"%s 的 tscn 声明 heavy_aim=%s(定位表说 native=%s;改了 tscn 就得改定位表)"
				% [gun["name"], w.heavy_aim, gun["native"]])

	# ── ② 6 把真枪 × 三种模式 ──
	for c in cases:
		_run_case(c, bullet_script, beam_script)

	arena.free()

	# ★ 条数闸(见文件头):少了 = 有断言被静默跳过;多了 = EXPECTED_CHECKS 该改。
	var gate_ok := _checks == EXPECTED_CHECKS
	if not gate_ok:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(少了=有断言被静默跳过;"
				% [_checks, EXPECTED_CHECKS] + "多了=新加的断言没登记进 EXPECTED_CHECKS)")
	if _fails.is_empty():
		print("WEAPON INJECTED FIRE PROBE: ALL-OK(%d 条断言,6 把真 tscn × 3 模式)" % _checks)
		quit(0)
	else:
		print("WEAPON INJECTED FIRE PROBE: FAIL(%d/%d 条) | %s" % [_fails.size(), _checks, "; ".join(_fails)])
		quit(1)


# 一格 = 一把真枪 × 一种模式。★ 全同步(无 await)⇒ 弹丸不会在相与相之间移动。
func _run_case(c: Dictionary, bullet_script: Script, beam_script: Script) -> void:
	var gun: Dictionary = c["gun"]
	var mode: String = c["mode"]
	var host = c["host"]
	var w = c["w"]
	var tag := "%s/%s" % [gun["name"], mode]
	var is_laser: bool = w.has_method("_emit_beam")
	var expected_out: int = 1 if is_laser else w.pellet_count
	print("── %s(%s;%s)" % [tag, "tscn 原生旗标" if c["native_case"] else "强制旗标",
			"光束" if is_laser else "%d 弹丸/发" % w.pellet_count])

	_check(w.mag_ammo == w.mag_size, "%s 起点:满弹夹(= %d)" % [tag, w.mag_size])

	# ── 相 1:无输入(**阴性对照**)──
	# ★ 没有这一相,"边沿查询恒 true"这种变异能骗过下面所有正相断言(Task 2 实测的教训)。
	host.clear_edges()
	host.reset_counts()
	var mag0: int = w.mag_ammo
	w.tick(DT)
	_check(w.fire_cd_timer == 0.0, "%s 无输入相:不开火(冷却未置)" % tag)
	_check(w.mag_ammo == mag0, "%s 无输入相:不耗弹(仍 %d)" % [tag, mag0])

	# ── 相 2:注入该模式驱动开火的那一个(些)边沿 ──
	host.reset_counts()
	var out0: int = _output_count(w, beam_script, is_laser)
	var mag1: int = w.mag_ammo
	var edge := ""
	match mode:
		"semi":
			host.just_pressed = true
			edge = "just_pressed"
		"auto":
			host.pressed = true
			edge = "pressed"
		"heavy":
			# 重武器:按下只进预瞄,松开的**当帧**才发射。
			host.just_pressed = true
			w.tick(DT)
			_check(w.is_previewing(), "%s heavy_aim:按下只进预瞄(is_previewing()=true)" % tag)
			_check(w.mag_ammo == mag1 and w.fire_cd_timer == 0.0, "%s heavy_aim:按下当帧不出弹" % tag)
			host.just_pressed = false
			host.just_released = true
			host.reset_counts()   # 只统计"松开那一帧"问过谁
			edge = "just_released"
	w.tick(DT)

	_check(w.mag_ammo == mag1 - 1, "%s 正相:注入 %s ⇒ 同帧耗弹 1 发(实 %d→%d)"
			% [tag, edge, mag1, w.mag_ammo])
	_check(is_equal_approx(w.fire_cd_timer, w.fire_cooldown),
			"%s 正相:同帧把冷却置满(= 真的开了这一枪)" % tag)
	var out1: int = _output_count(w, beam_script, is_laser)
	_check(out1 == out0 + expected_out, "%s 正相:同帧真的产出 %d 个%s(实 %d→%d)"
			% [tag, expected_out, "光束" if is_laser else "弹丸", out0, out1])

	# ── 相 3:边沿独占 —— 该模式**不许**问另外的边沿 ──
	# (这条是"只问该枪种那一个边沿"的机器版本;`weapon_base.tick()` 三条分支各问各的。)
	# ★ 用**精确计数**而不是 `>= 1`:"多问一次"与"少问一次"都要红,所以三个数逐个钉死。
	match mode:
		"semi":
			_check(host.n_just_pressed == 1 and host.n_pressed == 0 and host.n_just_released == 0,
					"%s 边沿独占:本相只问 just_pressed 一次(实 pressed/just_pressed/just_released = %d/%d/%d)"
					% [tag, host.n_pressed, host.n_just_pressed, host.n_just_released])
		"auto":
			_check(host.n_pressed == 1 and host.n_just_pressed == 0 and host.n_just_released == 0,
					"%s 边沿独占:本相只问 pressed 一次(实 pressed/just_pressed/just_released = %d/%d/%d)"
					% [tag, host.n_pressed, host.n_just_pressed, host.n_just_released])
		"heavy":
			# 重武器**合法地**问两个边沿(按下=预瞄、松开=发射),但**绝不**问 pressed。
			_check(host.n_just_released == 1 and host.n_just_pressed == 1 and host.n_pressed == 0,
					"%s 边沿独占:发射那一帧问 just_pressed/just_released 各一次、不问 pressed(实 %d/%d/%d)"
					% [tag, host.n_pressed, host.n_just_pressed, host.n_just_released])


# "出膛产物"计数:激光 = 挂在视口上的光束节点;其余 = 归属本武器的在飞弹丸。
# ★ 用**前后差值**(不是绝对值):上一格留下的弹丸/光束不清场,绝对值会被它们污染。
func _output_count(w, beam_script: Script, is_laser: bool) -> int:
	if is_laser:
		var n := 0
		for c in w.get_viewport().get_children():
			if c.get_script() == beam_script:
				n += 1
		return n
	return w._live_projectiles()


func _empty_grid(cols: int, rows: int) -> Array[Array]:
	var g: Array[Array] = []
	for y in range(rows):
		var row: Array[int] = []
		row.resize(cols)
		row.fill(MazeGenerator.EMPTY)
		g.append(row)
	return g
