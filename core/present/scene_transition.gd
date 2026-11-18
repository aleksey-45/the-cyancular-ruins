class_name SceneTransition
extends RefCounted

const REAP_BUDGET_US := 3000
static var _switching := false
static var _reap_queue: Array[Node] = []

static func change(tree: SceneTree, path: String) -> void:
	if _switching:
		return
	_switching = true
	# 信号回调尚未退出时，旧场景必须留在树中。
	await tree.process_frame
	var old: Node = tree.current_scene
	var next: Node = load(path).instantiate()
	tree.root.add_child(next)
	tree.current_scene = next
	if old != null and old != next:
		tree.root.remove_child(old)
		_collect_preorder(old, _reap_queue)
		var reap := _reap_step.bind(tree)
		if not tree.process_frame.is_connected(reap):
			tree.process_frame.connect(reap)
	_switching = false

# 旧场景离树后分帧释放，先子后父。暂停时 process_frame 仍会发出。
static func _reap_step(tree: SceneTree) -> void:
	var deadline := Time.get_ticks_usec() + REAP_BUDGET_US
	while not _reap_queue.is_empty() and Time.get_ticks_usec() < deadline:
		var n: Node = _reap_queue.pop_back()
		if is_instance_valid(n):
			n.free()
	if _reap_queue.is_empty():
		tree.process_frame.disconnect(_reap_step.bind(tree))

static func _collect_preorder(n: Node, out: Array[Node]) -> void:
	out.append(n)
	for c in n.get_children():
		_collect_preorder(c, out)
