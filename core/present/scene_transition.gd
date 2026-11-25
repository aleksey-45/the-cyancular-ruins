class_name SceneTransition
extends RefCounted

# 场景切换入口。返回菜单或大厅时显示短遮罩，进入对局时显示分阶段的加载界面。
# 加载界面先显示。回调创建场景实例，随后加入场景树并完成初始化，两段都在主线程同步执行。
# 进度条标记准备、构建、挂载和就绪阶段。阶段之间等待一帧，让界面有机会刷新。
# 切换期间由 NetSession 暂存对局消息。LoadingScreen 保持响应并拦截操作，_switching 防止重复切换。

# 返回这些场景时默认使用短遮罩，字典值为遮罩上的提示文字。
const SHORT_OVERLAY := {
	"res://scenes/main_menu.tscn": "正在返回主菜单…",
	"res://scenes/mp_lobby.tscn": "正在返回大厅…",
}
# 短遮罩至少显示 0.16 秒，避免切换较快时一闪而过。
const SHORT_OVERLAY_MIN_SECONDS := 0.16

static var _switching := false


## 加载并切换到指定场景。title 可覆盖默认遮罩文字。
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
	# 等待一帧，让遮罩和待处理的回调先执行。
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
		# 无遮罩时，在下一帧释放旧场景。
		_switching = false
		await tree.process_frame
		old.queue_free()
		return
	screen.set_progress(0.85, "正在进入场景…")
	# 保持遮罩到最短显示时间。
	while Time.get_ticks_msec() - started < int(SHORT_OVERLAY_MIN_SECONDS * 1000.0):
		await tree.process_frame
	screen.set_progress(1.0)
	await tree.process_frame
	screen.hide_loading()
	_switching = false
	await tree.process_frame
	old.queue_free()


## 先显示加载界面，再调用 builder 创建新场景并将其加入场景树。
## builder 返回 null 时，加载界面显示错误和返回按钮。
static func change_with_builder(tree: SceneTree, builder: Callable, title := "") -> void:
	if _switching:
		return
	_switching = true
	var label := title if not title.is_empty() else "正在载入…"
	var screen := LoadingScreen.mount(tree)
	if screen != null:
		screen.show_loading(label)
		screen.set_progress(0.0, label)
	# 等待一帧，让遮罩在主线程开始同步构建前显示。
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
	# 先显示构建阶段，再将新场景加入场景树并执行初始化。
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
	# 新场景已加入场景树。更新加载界面后再关闭遮罩。
	screen.set_progress(0.85, "正在挂载视图…")
	await tree.process_frame
	screen.set_progress(1.0, "就绪")
	await tree.process_frame
	screen.hide_loading()
	_switching = false
	await tree.process_frame
	if old != null:
		old.queue_free()
