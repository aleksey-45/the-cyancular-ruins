class_name SmokeZone
extends Node2D

# 烟雾区(道具:烟雾弹):冷调像素烟团——原作 effects.png 烟团帧同款画法:
# 深海军描边 + 青蓝烟体 + 块状深浅斑 + 近白高光,4px 粗颗粒最近邻烘焙(零外部素材)。
# 烘 3 帧 metaball 烟团硬切轮播 = 翻涌感(像素动画,不做渐变交叉淡化)。
# 存续 duration 秒后淡出自毁;显隐规则在 Globals/smoke.gd(本节点只负责"看起来是烟"与登记 smoke_zone 组)。

const TEXEL := 4            # 像素颗粒:世界像素/纹素(同 blast_ring_fx 的 4px 粗颗粒最近邻)
const MAX_GRID := 200       # 烘焙栅格边长上限(纹素),防超大半径烘焙过慢
const FRAME_COUNT := 3      # 烟团帧数(逐帧抖动圆丘布局,翻涌各不同)
const FRAME_PERIOD := 0.42  # 帧切换间隔(秒):整轮 ~1.26s,慢涌

# 冷调色板(对齐原作 effects.png 烟团帧:描边深海军 → 暗边深青 → 烟体青 → 亮斑浅青 → 高光近白)
const C_OUTLINE := Color8(21, 42, 58)
const C_SHADE := Color8(47, 122, 148)
const C_BODY := Color8(88, 198, 220)
const C_LIGHT := Color8(150, 226, 240)
const C_HIGHLIGHT := Color8(214, 244, 248)

var radius := 220.0
var duration := 6.0

var _frames: Array[Texture2D] = []
var _sprite: Sprite2D
var _frame := 0
var _frame_t := 0.0
var _age := 0.0
var _base_alpha := 0.85


func _ready() -> void:
	add_to_group("smoke_zone")
	z_index = 60   # 盖在角色/子弹上;近实心——烟雾内实体本就按规则对所有观察者隐藏
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(int(position.x)) + "_" + str(int(position.y)))
	for i in range(FRAME_COUNT):
		_frames.append(_bake_frame(rng))
	_sprite = Sprite2D.new()
	_sprite.texture_filter = TEXTURE_FILTER_NEAREST
	_sprite.texture = _frames[0]
	add_child(_sprite)
	# 落点蓬起:0.7 → 1.0 快速弹出(纹理 1 纹素 = TEXEL 世界像素)
	_sprite.scale = Vector2.ONE * TEXEL * 0.7
	var tw := _sprite.create_tween()
	tw.tween_property(_sprite, "scale", Vector2.ONE * TEXEL, 0.2) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _process(delta: float) -> void:
	_age += delta
	# 翻涌:烟团帧硬切轮播(切帧即换texture,像素动画的利落感)
	_frame_t += delta
	if _frame_t >= FRAME_PERIOD:
		_frame_t = fmod(_frame_t, FRAME_PERIOD)
		_frame = (_frame + 1) % _frames.size()
		_sprite.texture = _frames[_frame]
	# 淡入(0.25s)→ 存续 → 末尾 0.8s 淡出
	var a := _base_alpha
	if _age < 0.25:
		a = _base_alpha * (_age / 0.25)
	var remain := duration - _age
	if remain < 0.8:
		a *= maxf(remain / 0.8, 0.0)
	_sprite.modulate.a = a
	if _age >= duration:
		queue_free()


# 烘焙一帧烟团:metaball 圆丘簇(中心一团 + 外圈七团,逐帧抖动布局出翻涌差异),
# 场强 f = Σ (r/d)² ≥ 1 为烟体。烟体外沿 1 纹素深色描边;贴描边内侧 field<1.35 一圈深青暗边
# (原作"深描边+暗底"读法);内部按 4 纹素粗格噪声铺烟体/亮斑(块状,界带棋盘抖动),
# 噪声最亮格整块撒近白高光。整体直径 ≈ 0.94×烟雾直径,纹理纹素对齐世界像素网格。
func _bake_frame(rng: RandomNumberGenerator) -> ImageTexture:
	var g := mini(ceili(radius * 2.0 / TEXEL), MAX_GRID)
	var mid := float(g) * 0.5 - 0.5
	# 圆丘簇:中心一团撑体量,外圈七团抖出云边起伏(半径与距离控制在半幅内,不出硬裁切直边)
	var lobes: Array[Vector3] = [Vector3(mid, mid, g * 0.24)]
	for i in range(7):
		var ang := TAU * float(i) / 7.0 + rng.randf_range(-0.22, 0.22)
		var d := g * rng.randf_range(0.22, 0.27)
		var lr := g * rng.randf_range(0.16, 0.20)
		lobes.append(Vector3(mid + cos(ang) * d, mid + sin(ang) * d, lr))
	# 场强图(纹素级)
	var field := PackedFloat32Array()
	field.resize(g * g)
	for y in range(g):
		for x in range(g):
			var acc := 0.0
			for lb in lobes:
				var dx := float(x) - lb.x
				var dy := float(y) - lb.y
				var dd := dx * dx + dy * dy
				acc += 100.0 if dd < 0.0001 else lb.z * lb.z / dd
			field[y * g + x] = acc
	# 粗格噪声(4 纹素一格的块状深浅斑,帧间不同 → 斑块随翻涌爬动)
	var nc := ceili(float(g) / 4.0)
	var noise := PackedFloat32Array()
	noise.resize(nc * nc)
	for i in range(nc * nc):
		noise[i] = rng.randf()

	# PackedByteArray 直写 + create_from_data:替代逐像素 set_pixel(811K 次调用阻塞主线程,单机使用道具时的卡顿根因)
	var data := PackedByteArray()
	data.resize(g * g * 4)   # RGBA8
	for y in range(g):
		var row_off := y * g * 4
		for x in range(g):
			var f := field[y * g + x]
			if f < 1.0:
				continue
			var col := C_BODY
			if f < 1.35:
				col = C_SHADE   # 贴边暗圈(外沿另有描边,合成两阶粗描边)
			else:
				var n := noise[(y / 4) * nc + (x / 4)]
				if n > 0.80:
					col = C_HIGHLIGHT   # 整块近白高光
				elif n > 0.58:
					col = C_LIGHT
				elif absf(n - 0.58) < 0.07 and (x + y) % 2 == 0:
					col = C_LIGHT   # 界带棋盘抖动,像素风的过渡质感
			# 描边:任一 4 邻居出烟体(含图像边界) → 深海军 1 纹素
			if x == 0 or y == 0 or x == g - 1 or y == g - 1 \
					or field[y * g + x - 1] < 1.0 or field[y * g + x + 1] < 1.0 \
					or field[(y - 1) * g + x] < 1.0 or field[(y + 1) * g + x] < 1.0:
				col = C_OUTLINE
			var off := row_off + x * 4
			data[off]     = int(col.r * 255.0)
			data[off + 1] = int(col.g * 255.0)
			data[off + 2] = int(col.b * 255.0)
			data[off + 3] = 255
	var img := Image.create_from_data(g, g, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(img)
