class_name SceneTransition
extends RefCounted

const RETURN_LABELS := {
	"res://scenes/main_menu.tscn": "正在返回主菜单…",
	"res://scenes/mp_lobby.tscn": "正在返回大厅…",
}
const RETURN_SECONDS := 0.16

static var _switching := false


static func change(tree: SceneTree, path: String) -> void:
	await change_with_builder(tree, func() -> Node:
		var scene := load(path) as PackedScene
		return scene.instantiate() if scene != null else null,
		RETURN_LABELS[path], RETURN_SECONDS)


static func change_with_builder(tree: SceneTree, builder: Callable, title: String, min_seconds := 0.0) -> void:
	if _switching:
		return
	_switching = true
	var started := Time.get_ticks_msec()
	var screen := LoadingScreen.mount(tree)
	screen.show_loading(title)
	# 让加载提示先显示一帧，再开始主线程上的构建。
	await tree.process_frame
	await tree.process_frame
	var next: Node = builder.call()
	if next == null:
		screen.show_failure("载入失败，请返回重试")
		_switching = false
		return
	screen.show_loading("正在进入场景…")
	await tree.process_frame
	tree.change_scene_to_node(next)
	await tree.scene_changed
	var remaining := min_seconds - (Time.get_ticks_msec() - started) / 1000.0
	if remaining > 0.0:
		await tree.create_timer(remaining).timeout
	screen.queue_free()
	_switching = false
