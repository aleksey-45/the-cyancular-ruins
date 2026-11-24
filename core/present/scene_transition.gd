class_name SceneTransition
extends RefCounted

# 场景切换的单一入口。
# ★ 兼容契约:change(tree, path) 的旧时序必须保留 —— "先等一帧,再实例化,挂上新场景,再等一帧,释放旧场景"。
#   tests/prediction_case.gd 依赖这一段:它在 change 之后立刻发一个 MATCH_EVENT,要求事件先落进
#   PvpSession.match_events,再由新客户端的 _ready 取走一次。改时序会破坏网络事件交接。
# ★ 两档入口:
#   · change(tree, path, title = "")           普通换场景;回到菜单/大厅这类轻目标附短遮罩(兜底 P1 归属文件里
#                                              现成的 change 调用点,不改那些文件也能看到载入);
#   · change_with_builder(tree, builder, title) 重场景构建:先显示 v2 载入界面,再执行 builder,按阶段推进进度。
# ★ 进度策略(计划 P0 §2.2):GDScript 构建是同步的,没有资源级回调,所以只报阶段:
#   0.00 显示遮罩 → 0.15 已进入构建 → 0.55 构建产物就绪 → 0.85 已挂载 → 1.00 隐藏。
#   每个阶段之间 await process_frame,保证 UI 至少渲染一帧;不伪造不存在的细粒度进度。
# ★ 防重入沿用静态 _switching;载入期间 LoadingScreen 负责 process_mode=ALWAYS 与输入拦截。

# 回到轻场景时默认给个短遮罩(值 = 状态行文案);重场景请走 change_with_builder。
const SHORT_OVERLAY := {
	"res://scenes/main_menu.tscn": "正在返回主菜单…",
	"res://scenes/mp_lobby.tscn": "正在返回大厅…",
}
# 短遮罩最短停留:0.16s ≈ 10 帧,足以被看见,又不会让"返回"变慢。
const SHORT_OVERLAY_MIN_SECONDS := 0.16

static var _switching := false


## 普通换场景。旧调用(tests / 网络事件回调)原样可用;可选 title 只影响遮罩文案。
static func change(tree: SceneTree, path: String, title := "") -> void:
	if _switching:
		return
	_switching = true
	var label := title
	if label.is_empty():
		label = str(SHORT_OVERLAY.get(path, ""))
	var screen: LoadingScreen = null
	var started := Time.get_ticks_msec()
	if not label.is_empty():
		screen = LoadingScreen.mount(tree)
		if screen != null:
			screen.show_loading(label)
			screen.set_progress(0.0, label)
	# 旧时序:第一帧留给 UI/网络事件回调(见文件头说明)。
	await tree.process_frame
	var old := tree.current_scene
	var packed := load(path) as PackedScene
	if packed == null:
		_switching = false
		if screen != null:
			screen.show_failure("无法载入场景：%s" % path.get_file())
		return
	var next: Node = packed.instantiate()
	if old != null:
		tree.root.remove_child(old)
	tree.root.add_child(next)
	tree.current_scene = next
	if screen == null:
		# 无遮罩路径:与改造前逐行等价。
		_switching = false
		await tree.process_frame
		old.queue_free()
		return
	screen.set_progress(0.85, "正在进入场景…")
	# 短遮罩至少停留 SHORT_OVERLAY_MIN_SECONDS,否则只闪一两帧,用户读不到。
	while Time.get_ticks_msec() - started < int(SHORT_OVERLAY_MIN_SECONDS * 1000.0):
		await tree.process_frame
	screen.set_progress(1.0)
	await tree.process_frame
	screen.hide_loading()
	_switching = false
	await tree.process_frame
	old.queue_free()


## 重场景入口:先显示载入界面,再执行 builder 得到下一场景的根节点,挂上后按阶段推进到完成。
## builder 返回 null 视为失败:保持遮罩并显示错误 + 返回按钮(不白屏),由玩家自行返回重试。
static func change_with_builder(tree: SceneTree, builder: Callable, title := "") -> void:
	if _switching:
		return
	_switching = true
	var label := title if not title.is_empty() else "正在载入…"
	var screen := LoadingScreen.mount(tree)
	if screen != null:
		screen.show_loading(label)
		screen.set_progress(0.0, label)
	# 0.00:先把遮罩画出来(构建开始后 UI 线程被同步构建占住,期间不可能再刷新)。
	await tree.process_frame
	if screen != null:
		screen.set_progress(0.15, "正在准备…")
	await tree.process_frame
	var next: Node = null
	if builder.is_valid():
		next = builder.call() as Node
	if next == null:
		_switching = false
		if screen != null:
			screen.show_failure("载入失败，请返回重试")
		return
	if screen != null:
		screen.set_progress(0.55, "正在构建场景…")
	# 0.55 先渲染出来,再进入同步构建(新场景 _ready 里的地形/角色/视图都在这段发生)。
	await tree.process_frame
	var old := tree.current_scene
	if old != null:
		tree.root.remove_child(old)
	tree.root.add_child(next)
	tree.current_scene = next
	if screen == null:
		_switching = false
		await tree.process_frame
		if old != null:
			old.queue_free()
		return
	# 0.85:新场景已挂载(同步 _ready 已跑完),再让 UI 收一次阶段更新。
	screen.set_progress(0.85, "正在挂载视图…")
	await tree.process_frame
	screen.set_progress(1.0, "就绪")
	await tree.process_frame
	screen.hide_loading()
	_switching = false
	await tree.process_frame
	if old != null:
		old.queue_free()
