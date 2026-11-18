class_name SceneTransition
extends RefCounted

static var _switching := false

static func change(tree: SceneTree, path: String) -> void:
	if _switching:
		return
	_switching = true
	await tree.process_frame
	var old := tree.current_scene
	var next: Node = load(path).instantiate()
	tree.root.remove_child(old)
	tree.root.add_child(next)
	tree.current_scene = next
	_switching = false
	# 把旧场景的释放和新场景的加载分到两个渲染帧。
	await tree.process_frame
	old.queue_free()
