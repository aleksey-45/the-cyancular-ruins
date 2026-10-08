extends SceneTree
# 帧周期生命周期回调顺序验证探针：
# 测量同一帧内 _unhandled_input / _physics_process / _process 的调用执行先后顺序，
# 用于排查开火输入响应与物理更新之间的朝向状态同步时序。

class Probe extends Node:
	var tree: SceneTree
	var marks: Array[String] = []
	var _f := 0
	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventKey and event.keycode == KEY_SPACE and event.pressed:
			marks.append("input@%d" % _f)
	func _physics_process(_delta: float) -> void:
		marks.append("physics@%d" % _f)
	func _process(_delta: float) -> void:
		marks.append("process@%d" % _f)
		_f += 1
		if _f == 3:
			tree.print_marks()
			tree.quit(0)

var probe: Probe

func print_marks() -> void:
	print("回调顺序:")
	for m in probe.marks:
		print("  " + m)

func _initialize() -> void:
	probe = Probe.new()
	probe.tree = self
	probe._f = 0
	root.add_child(probe)
	# 模拟注入空格键按下事件，供下一帧输入阶段进行事件派发
	var ev := InputEventKey.new()
	ev.keycode = KEY_SPACE
	ev.pressed = true
	Input.parse_input_event(ev)
