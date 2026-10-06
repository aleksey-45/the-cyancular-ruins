extends SceneTree
# 探针:实测一帧内 _unhandled_input / _physics_process / _process 的调用先后,
# 用于确认"开火时向反方向行走弹道出问题"是否源于直接开火路径读到被移动覆盖的旧 facing。

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
	# 注入一个空格按下事件,等下一帧输入阶段派发
	var ev := InputEventKey.new()
	ev.keycode = KEY_SPACE
	ev.pressed = true
	Input.parse_input_event(ev)
