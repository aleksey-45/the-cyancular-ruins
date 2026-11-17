extends Node

const MARKER := "LEVEL0 BOOT PROBE: ALL-OK"
const EXPECTED_CHECKS := 24
const MAP := "res://maps/newfactory.cyrm"
const WATER_SHADER := "res://scenes/effects/water_surface_batch.gdshader"
const FORM_SHADER := "res://core/present/form_light.gdshader"
const POST_SHADER := "res://core/present/post_process.gdshader"
const BOOT_TIMEOUT_MS := 30000

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	MazeGenerator.set_map_file(MAP)
	var ps := load("res://scenes/level_0.tscn") as PackedScene
	_chk(ps != null, "★ 读不到 res://scenes/level_0.tscn")
	if ps == null:
		_finish()
		return
	var level := ps.instantiate()
	add_child(level)
	_chk(level is Level0, "★ 实例化根节点不是 Level0(场景脚本丢了?)")
	var booted: bool = await _wait_boot()
	_chk(booted, "★ 载入未在 %dms 内完成(仍在 pause / 载入屏未收)" % BOOT_TIMEOUT_MS)
	if not booted:
		_finish()
		return
	for _i in 3:
		await get_tree().process_frame

	var grid := MazeGenerator.current_grid
	var cells := MazeGenerator.world_cells()
	_chk(grid.size() > 0 and not grid[0].is_empty()
			and MazeGenerator.current_subgrid.size() > 0 and MazeGenerator.current_subdesc.size() > 0,
			"★ 世界数据没灌进 MazeGenerator(grid/subgrid/subdesc 有空的)")
	_chk(cells.x > 0 and cells.y > 0, "★ world_cells 必须 > 0,实得 %s" % str(cells))

	var vp := level.get_node_or_null("WorldViewport") as SubViewport
	_chk(vp != null and vp.transparent_bg and vp.size.x > 0 and vp.size.y > 0,
			"★ WorldViewport 必须是 transparent_bg 且尺寸 > 0(天空靠 alpha=0 合成)")
	if vp == null:
		_finish()
		return
	var glow_vp := level.get_node_or_null("GlowViewport") as SubViewport
	var glow_cam := level.get_node_or_null("GlowViewport/GlowCamera") as Camera2D
	_chk(glow_vp != null and glow_vp.transparent_bg and glow_cam != null
			and glow_vp.size == vp.size / 2,
			"★ GlowViewport / GlowCamera 缺失,或尺寸不是世界视口的一半")
	var ui_vp := level.get_node_or_null("UiViewport") as SubViewport
	_chk(ui_vp != null and ui_vp.transparent_bg and ui_vp.size == vp.size,
			"★ UiViewport 缺失,或尺寸与世界视口不一致")
	var terrain_vp := level.get_node_or_null("TerrainViewport") as SubViewport
	var terrain_layer := level.get_node_or_null("TerrainViewport/TerrainLayer") as TileMapLayer
	_chk(terrain_vp != null and terrain_vp.transparent_bg
			and terrain_vp.size == vp.size / 2
			and terrain_vp.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
			"★ TerrainViewport 缺失/不是透明底半分辨率/不是每帧更新(地形剪影通道)")

	var wall := Level0.wall_layer
	_chk(wall != null and wall.tile_set != null and wall.get_used_cells().size() > 0,
			"★ 墙体没铺出来(WallLayer 无 tile_set 或 used_cells=0)")
	var mirror_ok: bool = wall != null and terrain_layer != null \
			and terrain_layer.tile_set == wall.tile_set \
			and terrain_layer.get_used_cells().size() == wall.get_used_cells().size()
	_chk(mirror_ok, "★ 地形剪影层与墙层不一致(TileSet 或格数):铺贴写点漏镜像")
	var batches: Array = []
	if Level0.water_surface_layer != null:
		for n in Level0.water_surface_layer.get_children():
			if n is WaterSurfaceBatch:
				batches.append(n)
	var batches_ok := batches.size() > 0
	for b in batches:
		var mi: MeshInstance2D = null
		for c in b.get_children():
			if c is MeshInstance2D:
				mi = c
				break
		if mi == null:
			batches_ok = false
			break
		var bmat := mi.material as ShaderMaterial
		var tex = bmat.get_shader_parameter("surf") if bmat != null else null
		var tex_ok := tex is Texture2D \
				and (tex as Texture2D).get_height() == GameParameters.TILE_SIZE * 2 \
				and (tex as Texture2D).get_width() == GameParameters.TILE_SIZE
		if mi.mesh == null or bmat == null or bmat.shader == null \
				or not str(bmat.shader.resource_path).ends_with(WATER_SHADER) or not tex_ok:
			batches_ok = false
			break
	_chk(batches_ok, "★ 水体合批没建出来,或网格/材质/shader/两行图集对不上(%d 个 batch)" % batches.size())

	var pp := get_tree().get_first_node_in_group("post_process") as CanvasLayer
	var rect: ColorRect = null
	if pp != null:
		rect = pp.get_node_or_null("ShaderRect") as ColorRect
	var mat: ShaderMaterial = null
	if rect != null:
		mat = rect.material as ShaderMaterial
	if mat == null or pp == null or pp.world_viewport != vp or mat.shader == null \
			or not str(mat.shader.resource_path).ends_with(POST_SHADER):
		_chk(false, "★ PostProcess 没挂上/没绑世界视口/合成 shader 不是 post_process.gdshader")
	else:
		_chk(true, "")
	if mat == null:
		_chk(false, "★ 合成材质没建出来,通道与掩码无法校验")
		_chk(false, "★ 合成材质没建出来,通道与掩码无法校验")
		_chk(false, "★ 合成材质没建出来,通道与掩码无法校验")
		_finish()
		return
	var glow_tex = mat.get_shader_parameter("glow_tex")
	var ui_tex = mat.get_shader_parameter("ui_tex")
	_chk(mat.get_shader_parameter("glow_gain") == 1.0 and glow_tex is Texture2D,
			"★ 发光通道没接上(glow_gain/glow_tex)")
	_chk(mat.get_shader_parameter("ui_gain") == 1.0 and ui_tex is Texture2D,
			"★ UI 辅助通道没接上(ui_gain/ui_tex)")
	var mask_grid = mat.get_shader_parameter("mask_grid")
	var mask_ok: bool = mat.get_shader_parameter("mask_gain") == 1.0 \
			and mat.get_shader_parameter("terrain_mask") is Texture2D \
			and mask_grid is Vector2 and (mask_grid as Vector2) == Vector2(cells) \
			and float(mat.get_shader_parameter("cam_zoom")) > 0.0
	_chk(mask_ok, "★ 地形掩码没烘/尺寸与世界格数不一致(mask_grid=%s, 期望 %s)" % [
			str(mask_grid), str(Vector2(cells))])
	_chk(mat.get_shader_parameter("terrain_occ_gain") == 1.0
			and mat.get_shader_parameter("terrain_tex") is Texture2D,
			"★ 地形剪影通道没接上(terrain_occ_gain/terrain_tex)")

	var cam := vp.get_node_or_null("Camera2D") as Camera2D
	var player := vp.get_node_or_null("Player") as Node2D
	var cam_ok: bool = cam != null and player != null and cam.target == player
	if cam_ok:
		cam_ok = cam.zoom.x > 0.0 and cam.zoom.x == cam.zoom.y
	_chk(cam_ok, "★ 相机缺失/没跟玩家/zoom 不是均匀正数")
	var sync_ok: bool = glow_cam != null and cam != null \
			and glow_cam.global_position == cam.global_position \
			and glow_cam.zoom == cam.zoom * 0.5
	_chk(sync_ok, "★ 发光相机没跟世界相机同步(位置或半分辨率 zoom)")
	var terrain_cam := level.get_node_or_null("TerrainViewport/TerrainCamera") as Camera2D
	var terrain_sync: bool = terrain_cam != null and cam != null \
			and terrain_cam.global_position == cam.global_position \
			and terrain_cam.zoom == cam.zoom * 0.5 \
			and terrain_cam.rotation == cam.rotation
	_chk(terrain_sync, "★ 地形剪影相机没跟世界相机同步(位置/半分辨率 zoom/rotation)")
	_chk(_has_form_light(player), "★ 玩家形体光没挂上(没有 animator 用 form_light.gdshader 的材质)")

	var walls := vp.get_node_or_null("WallCollision") as StaticBody2D
	var chunk_count := 0
	for n in vp.get_children():
		if n is StaticBody2D and str(n.name).begins_with("DestructibleChunk_"):
			chunk_count += 1
	_chk(walls != null and walls.get_child_count() > 0 and chunk_count > 0,
			"★ 碰撞没建出来(永久墙 shapes=%d,可破坏块=%d)" % [
				walls.get_child_count() if walls != null else -1, chunk_count])
	_chk(not get_tree().paused and not LoadingScreen.visible,
			"★ 收尾状态不对(树仍 pause 或载入屏仍在)")

	# 拾取端口:Player 不再向上找 Level0,接线由 Level0 注入。删掉 level_0.gd 里那行 bind_pickup_host ⇒ 本断言红。
	# ★ 这是"运行时对象图"断言(不是读源码文本):按 F 永远捡不起枪,且没有任何报错。
	var pl := level.get_node_or_null("WorldViewport/Player")
	_chk(pl != null and pl.pickup != null and pl.pickup.host == level,
			"★ 拾取端口没接线(pickup.host ≠ Level0)⇒ 单机按 F 永远捡不起枪,且静默无报错")

	_finish()


func _wait_boot() -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < BOOT_TIMEOUT_MS:
		await get_tree().process_frame
		if not get_tree().paused and not LoadingScreen.visible:
			return true
	return false


func _has_form_light(root: Node) -> bool:
	if root == null:
		return false
	for c in root.get_children():
		if c is AnimatedSprite2D:
			var m := (c as AnimatedSprite2D).material as ShaderMaterial
			if m != null and m.shader != null and str(m.shader.resource_path).ends_with(FORM_SHADER):
				return true
		if _has_form_light(c):
			return true
	return false


func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("%s(%d 条断言):世界数据 · 四视口 · 墙体铺贴 · 地形剪影镜像 · 水体合批 · PostProcess 通道 · 地形掩码与剪影通道 · 相机与通道相机同步 · 形体光 · 碰撞 · 收尾状态"
				% [MARKER, _checks])
		get_tree().quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("LEVEL0 BOOT PROBE: FAIL(%d 处)" % _fails.size())
		get_tree().quit(1)
