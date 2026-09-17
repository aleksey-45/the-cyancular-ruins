class_name CombatFeedback
extends CanvasLayer

# 打击反馈层(KH-hit-feedback 分支):屏幕中心 FPS 式命中 X 标记 +「击杀 XXX」像素播报。
# 受击侧的微红/震屏在 PostProcess.flash_hit + 相机 shake(见 combat_component.take_hit),不在此层。
# 实例由各对局场景挂载(单机 Level0 / pvp_client / royale_game);静态入口在无实例时
# (服务器 headless 进程/主菜单)静默空操作,调用方(子弹/爆炸/敌死)无需判空。

const LAYER := 131        # PostProcess(128) < 单机 HUD(129) < PvpHud/RoyaleHud(130) 之上
const HIT_LIFE := 0.22    # X 标记存活时长(秒)
const KILL_FADE_IN := 0.08
const KILL_HOLD := 0.9    # 击杀文字停留时长(秒)
const KILL_FADE_OUT := 0.35
const STREAK_RESET := 6.0 # 连杀窗口:隔此秒数没有新击杀则连杀清零(秒)
const ATTRIB_WINDOW_MS := 3000 # 归因时效:距最后一次受击超过此毫秒数的死亡不再归因给该射手
# ★ 字体路径常量已删 —— 两个 Label 随布局迁进 ui/combat_feedback.tscn,字体在那里用
#   ext_resource 显式给(走 normal_font / normal_font_size,见 ui_factory.gd:33 的 caveat)。

static var current: CombatFeedback = null   # 当前对局的反馈层;null = 非对局/服务器,静态入口空转


## 由对局场景挂载(重复调用安全;换局由 _exit_tree 自清)
## 幂等判据不能只看 current 是否存在:换场时(safe_change_scene 先 add_child 新场景、后 remove_child 旧世界)
## 旧实例仍在树上且仍是 current,只看存在性会让新世界提前 return → 反馈层静默消失。
## 故须满足「current 有效 **且** 已是本 host 的后代」才幂等返回。
##
## ★ 用 load 而非 preload:本场景的 ext_resource 指回本脚本,preload 会构成
##   「脚本 → 场景 → 脚本」的循环引用,Godot 解析期直接报错。运行期 load 不参与解析,
##   且资源只载一次(引擎缓存)。同款的 B11 见 tests/hud_declarative_probe。
static func spawn(host: Node) -> void:
	if current != null and is_instance_valid(current) and host.is_ancestor_of(current):
		return
	var fx: CombatFeedback = load("res://ui/combat_feedback.tscn").instantiate() as CombatFeedback
	host.add_child.call_deferred(fx)


## 命中反馈:屏幕中心 X 标记(玩家子弹/爆炸命中实体时调用)
static func hit_marker() -> void:
	if current != null:
		current._show_hit()


## 击杀播报:屏幕中心「击杀 XXX」+ 音效(who = 被击杀者显示名);内部维护连杀计数
## (STREAK_RESET 秒内有新击杀则 +1,否则清零重计),同时闪现像素骷髅头 + 连杀数。
static func kill(who: String) -> void:
	if current != null:
		current._show_kill(who)


## 自己被击杀时连杀清零(PvP 客户端在 kill_event victim==自己 时调用;单机仅按时间窗清零)
static func reset_streak() -> void:
	if current != null:
		current._streak = 0
		current._last_kill_ms = -1


## 击杀归因(写端统一入口):记下"谁打的"与"何时打的",供 notify_enemy_killed 读。
## 必须写在**伤害调用之前** —— EnemyBase.hurt() 同帧同步判死并立刻调 notify_enemy_killed,
## 写在 hurt 之后则 meta 尚不存在,「击杀 XXX」会静默丢失(这是本合并修过的一个真 bug)。
## 只做元数据写入,不做任何判定/播报;victim == attacker 时不写(自伤不归因给自己)。
## 调用方负责传入正确的射手(玩家武器持有者 / 爆炸射手);是否算击杀由读端按 player 组 + 时效判定。
static func attribute(victim: Node, attacker: Node) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	if attacker == null or not is_instance_valid(attacker) or attacker == victim:
		return
	victim.set_meta("last_damager", attacker)
	victim.set_meta("last_damager_time", Time.get_ticks_msec())


## 归因 + 命中标记的一体入口:武器命中实体时的统一收尾(子弹/爆炸/激光共用)。
## ★两件事都必须在**伤害调用之前**完成 —— EnemyBase.hurt() / take_hit 可能同帧判死,
## 死亡播报当场读 last_damager 的 meta(见 attribute 的注释)。散写成两行时极易漏掉先后顺序。
## headless 服务器进程无 CombatFeedback 实例 → hit_marker 空操作,无副作用。
static func attribute_hit(victim: Node, attacker: Node) -> void:
	attribute(victim, attacker)
	hit_marker()


## EnemyBase._begin_death 调用:仅「玩家造成的死亡」才播报——读受害者 last_damager meta,
## 溺水/环境死(无射手)安静销毁,不再全局播 kill 音效。
static func notify_enemy_killed(victim: Node) -> void:
	if current == null or not victim.has_meta("last_damager"):
		return
	var killer: Node = victim.get_meta("last_damager")
	if killer == null or not is_instance_valid(killer) or not killer.is_in_group("player"):
		return
	# 归因时效:太久以前打过的伤害不再算这回的击杀(否则"蹭过一下、后溺水"也会播报)
	if not victim.has_meta("last_damager_time"):
		return
	# 边界取 >=:窗口边界本身即视为过期(同帧写入-读取的差值为 0,用 > 会让时效"永远不过期",
	# 常量取 0 时也永不为真 → 不可反证)
	if Time.get_ticks_msec() - int(victim.get_meta("last_damager_time")) >= ATTRIB_WINDOW_MS:
		return
	kill(enemy_display_name(victim))


## 敌人显示名(击杀播报用):唯一来源是 data/enemies.json 的 `display_name` 字段,经
## `EnemySpawner.display_name_of`(按**场景路径**查,自带惰性加载 —— 不依赖"调用前恰好有人
## 调过 load_types()")。查不到回落英文场景文件名。
## ★ 2026-09-14 前这里是一份手抄的 `const ENEMY_NAMES`(键 = 场景名去 Enemy 前缀),
##   与 enemies.json **两处维护**:加新敌人漏改这里就会静默显示英文名,且不报错。
static func enemy_display_name(victim: Node) -> String:
	return EnemySpawner.display_name_of(String(victim.scene_file_path))


# 两个**自绘**控件由代码建(见 _ready),故是普通成员;两个文本节点从场景取,
# 声明在下面 _ready 上方(@onready)。
var _marker: HitMarker = null
var _skull: KillSkull = null       # 击杀像素骷髅(与击杀播报同窗闪现)
var _streak := 0                   # 当前连杀数
var _last_kill_ms := -1            # 上次击杀时刻(连杀窗口判定;-1=无)
var _hit_age := -1.0    # <0 = 隐藏
var _kill_age := -1.0


# 布局段(root / 击杀播报 RichTextLabel / 连杀数 Label 的锚点与全部 theme override)
# 已迁进 ui/combat_feedback.tscn。上面 @onready 取回两个文本节点;两个**自绘**控件
# (HitMarker / KillSkull)保持内部类、由代码建,挂进场景预留的槽位。
# ★ 槽位的声明顺序 = z 序,必须与搬迁前的 add_child 顺序一致:
#   HitMarkerSlot(X 标记,最下) → KillLabel → SkullSlot → StreakLabel。
#   往槽位里 add_child 不走 move_child,顺序天然对齐。
@onready var _kill_label: RichTextLabel = $Root/KillLabel
@onready var _streak_label: Label = $Root/StreakLabel


func _ready() -> void:
	layer = LAYER
	current = self
	process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停时动画也能收尾
	# ★ 一次:共享字体关抗锯齿/微调/子像素并挂 CJK 回退链。场景里两个 Label 引用的就是
	#   同一个共享 FontFile 实例 —— 不调这句,它们带抗锯齿、且汉字没有回退字形
	#   (本层必画中文:「击杀 测试鸟」)。同 pvp_hud.gd:26。
	PixelFont.shared()
	# 命中 X:铺满全屏的自绘控件,画在正中心
	_marker = HitMarker.new()
	_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.visible = false
	$Root/HitMarkerSlot.add_child(_marker)
	# 击杀骷髅:屏幕正中央的像素骷髅头(8×8 像素画 ×8 放大),随击杀播报同窗闪现
	_skull = KillSkull.new()
	_skull.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_skull.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skull.visible = false
	$Root/SkullSlot.add_child(_skull)


func _exit_tree() -> void:
	if current == self:
		current = null


func _show_hit() -> void:
	_hit_age = 0.0
	_marker.t = 0.0
	_marker.visible = true
	_marker.queue_redraw()


func _show_kill(who: String) -> void:
	# 连杀计数:STREAK_RESET 窗口内续杀 +1,超窗清零重计
	var now := Time.get_ticks_msec()
	if _last_kill_ms < 0 or now - _last_kill_ms > int(STREAK_RESET * 1000.0):
		_streak = 0
	_last_kill_ms = now
	_streak += 1
	# 击杀名里的 "[" 去掉,防止用户昵称拼进 BBCode
	_kill_label.text = "击杀 [color=#ffd76e]%s[/color]" % who.replace("[", "")
	_skull.visible = true
	_streak_label.text = "x%d" % _streak
	_kill_age = 0.0
	Sfx.play("kill")


func _process(delta: float) -> void:
	if _hit_age >= 0.0:
		_hit_age += delta
		_marker.t = clampf(_hit_age / HIT_LIFE, 0.0, 1.0)
		_marker.queue_redraw()
		if _hit_age >= HIT_LIFE:
			_hit_age = -1.0
			_marker.visible = false
	if _kill_age >= 0.0:
		_kill_age += delta
		var a := 1.0
		if _kill_age < KILL_FADE_IN:
			a = _kill_age / KILL_FADE_IN   # 快速浮现
		elif _kill_age > KILL_HOLD:
			a = maxf(1.0 - (_kill_age - KILL_HOLD) / KILL_FADE_OUT, 0.0)
		_kill_label.modulate.a = a
		# 开局轻微回落 pop(围绕文字中心;全屏 rect 的 pivot 取屏幕中心即可)
		_kill_label.pivot_offset = _kill_label.size * 0.5
		var s := 1.0 + 0.22 * maxf(1.0 - _kill_age / 0.14, 0.0)
		_kill_label.scale = Vector2(s, s)
		# 骷髅 + 连杀数随击杀播报同窗淡入淡出 / pop(各围绕自身中心)
		for fx: Control in [_skull, _streak_label]:
			fx.modulate.a = a
			fx.pivot_offset = fx.size * 0.5
			fx.scale = Vector2(s, s)
		if _kill_age >= KILL_HOLD + KILL_FADE_OUT:
			_kill_age = -1.0
			_kill_label.modulate.a = 0.0
			for fx: Control in [_skull, _streak_label]:
				fx.modulate.a = 0.0
				fx.visible = false


# 命中 X 标记:四段斜线(中心留缺口),生命周期内缺口外扩 + 线段微收 + 淡出;
# 白芯 + 深色描边,任意背景下可见。
class HitMarker extends Control:
	var t := 0.0   # 0..1

	func _draw() -> void:
		var c := size * 0.5
		var gap := 6.0 + 5.0 * t
		var seg := 10.0 - 3.0 * t
		var a := 1.0 - t
		for u in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
			var d: Vector2 = (u as Vector2).normalized()
			var p0: Vector2 = c + d * gap
			var p1: Vector2 = c + d * (gap + seg)
			draw_line(p0, p1, Color(0.05, 0.05, 0.05, a * 0.9), 6.0)
			draw_line(p0, p1, Color(1, 1, 1, a), 3.0)


# 击杀骷髅:8×8 像素画(' #'骨白 / 'o'暗部)逐格绘制,深色描边垫底;纯视觉,随播报同窗显隐。
class KillSkull extends Control:
	const PX := 8.0
	const BONE := Color(0.96, 0.96, 0.92)
	const DARK := Color(0.07, 0.08, 0.11)
	const PIX := [
		"..####..",
		".######.",
		".######.",
		".#o##o#.",
		".######.",
		"..####..",
		"..####..",
		"..o##o..",
	]

	func _draw() -> void:
		var w := float(PIX[0].length()) * PX
		var h := float(PIX.size()) * PX
		var origin := (size - Vector2(w, h)) * 0.5
		for yy in range(PIX.size()):
			var row: String = PIX[yy]
			for xx in range(row.length()):
				var ch := row[xx]
				if ch == ".":
					continue
				var r := Rect2(origin + Vector2(float(xx) * PX, float(yy) * PX), Vector2(PX, PX))
				if ch == "#":
					# 深色描边垫底(外扩 1px,拼出像素风轮廓)
					draw_rect(Rect2(r.position - Vector2(1, 1), r.size + Vector2(2, 2)), DARK)
					draw_rect(r, BONE)
				else:
					draw_rect(r, DARK)
