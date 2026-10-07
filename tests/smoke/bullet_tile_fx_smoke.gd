extends SceneTree
# PvP 打墙命中反馈——源码级结构检查(仿 player_contract_smoke 读源码断言风格):
# 锁住 bullet_base.gd 的关键结构不被回退——
#  1) `_damage_tile_at` 内 TileHitFx.spawn 在 `if apply_damage:` 之前(播碎片无条件);
#  2) `damage_tile(cell,` / `damage_sub(` 调用被 `apply_damage` 守住(damage 只在权威侧);
#  3) 撞墙 else 分支直接调 `_damage_tile_at`,不受 `if apply_damage:` 包裹(视觉副本也走)。
# 跑法:用户自跑(bullet_tile_fx_smoke.sh)。通过 = SMOKE_BULLET_TILE_FX OK。

var _fail := ""

func _initialize() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/weapons/bullet_base.gd")
	if src.is_empty():
		_fail = "无法读取 bullet_base.gd"
		_finish()
		return
	_check(src)
	_finish()

func _check(src: String) -> void:
	# 取 _damage_tile_at 函数体(从 func 声明到下一个 `\nfunc `)
	var fn_start := src.find("func _damage_tile_at")
	if fn_start < 0:
		_fail = "未找到 _damage_tile_at"
		return
	var fn_body_start := src.find("\n", fn_start)
	var fn_end := src.find("\nfunc ", fn_body_start)
	if fn_end < 0:
		fn_end = src.length()
	var body := src.substr(fn_body_start, fn_end - fn_body_start)
	var spawn_idx := body.find("TileHitFx.spawn")
	# - 2026-10-02 合并订正:KH 的 cyrm v4 把破坏下沉到 **16px 子格**  ->  `_damage_tile_at` 长出
	#   **两条**路径(子格 / 网格回落),伤害调用从单一的 `damage_tile(cell` 变成
	#   `damage_tile(cell` 与 `damage_sub(` 两种,且两条**不在**同一个 `if apply_damage:` 之下
	#   (子格那条是独立 `if`,网格那条是 `and apply_damage` 复合条件)。
	#   旧断言"在**首个** `if apply_damage:` 之后"因此失真 —— 它把回落路径那次调用当成了违规。
	#   - **意图一字未变**:任何一条瓦片伤害调用都只能在权威侧发生。
	#    ->  改成**逐调用**检查(见下),而不是比两个位置。
	var dmg_idx: Array[int] = []
	for needle in ["damage_tile(cell", "damage_sub("]:
		var from := 0
		while true:
			var i := body.find(needle, from)
			if i < 0:
				break
			dmg_idx.append(i)
			from = i + 1
	var guard_idx := body.find("if apply_damage:")
	if spawn_idx < 0:
		_fail = "_damage_tile_at 内无 TileHitFx.spawn"
		return
	if dmg_idx.is_empty():
		_fail = "_damage_tile_at 内无瓦片伤害调用(damage_tile(cell / damage_sub()"
		return
	if guard_idx < 0:
		_fail = "_damage_tile_at 内无 `if apply_damage:`"
		return
	if spawn_idx > guard_idx:
		_fail = "TileHitFx.spawn 出现在 `if apply_damage:` 之后(播碎片被权威开关挡住,应无条件)"
		return
	# 每一次伤害调用,往前 120 字符内必须看得到 `apply_damage`(覆盖 `if apply_damage:` 单独一行
	# 与 `… and apply_damage:` 复合条件两种写法)。改无条件扣除生命值、或换个名字绕过,照样红。
	for di in dmg_idx:
		var back := maxi(di - 120, 0)
		var ctx := body.substr(back, di - back)
		if not ctx.contains("apply_damage"):
			_fail = "瓦片伤害调用未被 apply_damage 守住(前 120 字符内无该守卫):…%s" % body.substr(di, 40)
			return
	# 撞墙分支调用 _damage_tile_at 前 80 字符内不应有 `if apply_damage:`(否则视觉副本走不到)
	var call_idx := src.find("_damage_tile_at(col.get_position()")
	if call_idx < 0:
		_fail = "未找到撞墙分支的 _damage_tile_at 调用"
		return
	var ctx := src.substr(maxi(0, call_idx - 80), call_idx - maxi(0, call_idx - 80))
	if ctx.find("if apply_damage:") >= 0:
		_fail = "撞墙分支 _damage_tile_at 仍被 `if apply_damage:` 包住(视觉副本走不到)"
		return

func _finish() -> void:
	if not _fail.is_empty():
		print("SMOKE_BULLET_TILE_FX FAIL: %s" % _fail)
		quit(1)
		return
	print("SMOKE_BULLET_TILE_FX OK: spawn 无条件、damage 守权威、视觉副本走撞墙分支")
	quit(0)
