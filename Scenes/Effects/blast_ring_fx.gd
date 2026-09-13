extends Node2D

# 引信白环(引力核心 pr_attraction / 排斥弹头 pr_knockback 特殊要求):
# 首撞引信期间循环出像素白环,标示作用范围;方向由 outward 决定(BulletBase 按 blast_force
# 符号设置:吸<0=收缩 / 推>0=外扩),起爆仍归 BulletBase,本节点只负责画环。
#  - 收缩(outward=false):从影响范围最外端不断出环向爆心收拢,由虚(淡)变实(亮);
#    最后一环收束至最中心的一刻 = 引信走完。
#  - 外扩(outward=true):由爆心一圈圈向外释放,到作用范围边缘消散;
#    最后一环到达最外沿的一刻 = 引信走完。
# 两方向同构:环 i 在 i/n·duration 时出现,各自在剩余引信时间内线性走完全程,
# 引信走完的一刻全部环同时抵达端点(中心 / 外沿)。

const TEX_SIZE: int = 256      # 环贴图边长(整幅映射到影响直径)
const GRID: int = 64           # 烘焙栅格:64 格,每格 4px;最近邻放大保持像素颗粒
const RING_PERIOD: float = 0.1 # 出环间隔(秒):约每 0.1s 一环

var radius: float = 300.0   # 影响半径(=爆炸半径;环在 0 与 radius 之间走)
var duration: float = 0.5   # 引信时长(与子弹引信同源,首撞起算)
var outward: bool = false   # false=外缘向爆心收缩(引力核心)/ true=由爆心向外扩到边缘消散(排斥弹头)

var _tex: Texture2D = null
var _elapsed: float = 0.0

func _ready() -> void:
	texture_filter = TEXTURE_FILTER_NEAREST
	_tex = _bake_ring()

func _process(delta: float) -> void:
	# 挂在投掷物下(跟着爆心走),但 rotation 是世界对齐:投掷物 rotation 随速度变化,
	# 不归零的话烘焙的像素环会被带着转、像素网格与世界错位(反弹瞬间整幅环旋转)。
	global_rotation = 0.0
	_elapsed += delta
	if _elapsed >= duration:
		queue_free()   # 环走完(收缩归心/外扩到缘);起爆归 BulletBase 管
		return
	queue_redraw()

func _draw() -> void:
	if _tex == null:
		return
	var n := maxi(2, ceili(duration / RING_PERIOD))
	for i in range(n):
		var start := duration * float(i) / float(n)
		var span := duration - start
		if span <= 0.0:
			continue
		var p := (_elapsed - start) / span
		if p <= 0.0 or p >= 1.0:
			continue
		var r := radius * (p if outward else 1.0 - p)
		if r < 2.0:
			continue
		# 收缩=虚→实(引力核心)/ 外扩=实→虚、到作用范围边缘消散(排斥弹头)
		var alpha := lerpf(1.0, 0.3, p) if outward else lerpf(0.25, 1.0, p)
		draw_texture_rect(_tex, Rect2(-r, -r, r * 2.0, r * 2.0), false,
				Color(1, 1, 1, alpha))

# 烘焙像素环:白环 1 格 + 内外各 1 格深色描边(暗底亮边同款风格),环贴着贴图外缘,
# draw 时整幅映射到 [-r, r],缩放即环半径。
func _bake_ring() -> Texture2D:
	var cell := TEX_SIZE / GRID
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := GRID * 0.5 - 0.5
	var ring_r := GRID * 0.5 - 1.0
	for gy in range(GRID):
		for gx in range(GRID):
			var dd := absf(Vector2(float(gx) - c, float(gy) - c).length() - ring_r)
			var col := Color(0, 0, 0, 0)
			if dd <= 0.5:
				col = Color(1, 1, 1, 1)
			elif dd <= 1.5:
				col = Color(0.07, 0.1, 0.16, 0.65)   # 深色描边
			if col.a <= 0.0:
				continue
			for py in range(cell):
				for px in range(cell):
					img.set_pixel(gx * cell + px, gy * cell + py, col)
	return ImageTexture.create_from_image(img)
