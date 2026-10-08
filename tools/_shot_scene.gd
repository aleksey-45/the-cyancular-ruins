extends Node

# 场景视觉渲染截图工具。
# 用于加载指定场景、按序触发方法并捕获视口画面，支持像素比对与界面验证。
# 注意：非无头模式运行（无头模式下视口纹理为空）。
#
# 用法:
#   godot --path . res://tools/_shot_scene.tscn -- <场景路径> <输出文件名.png> [指令 ...]
# 输出目录默认为 res://.superpowers/sdd/_gen/
#
# 指令参数说明:
#   <方法名> | call=<方法名>   在实例化的根节点上按序调用一次该方法
#   args=<JSON 数组>          为紧邻的前一个方法提供调用实参数组
#   addr=<host>               在场景实例化前设置 PvpSession.server_address
#   --help | -h               输出使用说明并退出

const OUT_DIR := "res://.superpowers/sdd/_gen/"

const USAGE := """用法（需在带图形窗口环境下运行）:
  godot --path . res://tools/_shot_scene.tscn -- <res://场景> <输出名.png> [指令 ...]
指令:
  <方法名> | call=<方法名>   按序在根节点上调用一次
  args=<JSON 数组>          紧随方法后提供调用实参数组
  addr=<host>               预先设置 PvpSession.server_address 地址
  --help | -h               打印本帮助信息
输出目录: res://.superpowers/sdd/_gen/<输出名.png>"""


func _ready() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.has("--help") or argv.has("-h"):
		print(USAGE)
		get_tree().quit(0)
		return
	if argv.size() < 2:
		_fail("用法: -- <res://场景> <输出名.png> [指令 ...] (-- --help 查看完整用法)")
		return
	var src := str(argv[0])
	var out := str(argv[1])

	# 先扫描参数，确保网络地址在场景实例化前生效
	var addr := ""
	var calls: Array = []          # [{ "name": String, "args": Array }]
	var ai := 2
	while ai < argv.size():
		var tok := str(argv[ai])
		if tok.begins_with("addr="):
			var host := tok.substr(5)
			if host.is_empty():
				_fail("addr= 参数未指定主机名: %s" % tok)
				return
			if not addr.is_empty():
				_fail("addr= 参数仅允许指定一次 (重复参数: %s)" % tok)
				return
			addr = host
		elif tok.begins_with("call="):
			var m := tok.substr(5)
			if m.is_empty():
				_fail("call= 参数缺少方法名")
				return
			calls.append({"name": m, "args": []})
		elif tok.begins_with("args="):
			if calls.is_empty():
				_fail("args= 必须紧跟在方法名或 call= 之后: %s" % tok)
				return
			var last: Dictionary = calls[calls.size() - 1]
			if not (last["args"] as Array).is_empty():
				_fail("方法 %s 已指定实参，args= 参数不能重复提供" % last["name"])
				return
			var parsed = _parse_args(tok.substr(5))
			if parsed == null:
				return
			last["args"] = parsed
		elif tok.contains("="):
			_fail("未知参数 %s (仅支持 addr= / call= / args=)" % tok)
			return
		else:
			# 独立方法名作为无参调用记录
			calls.append({"name": tok, "args": []})
		ai += 1

	if not addr.is_empty():
		PvpSession.server_address = addr

	var ps: PackedScene = load(src)
	if ps == null:
		_fail("读取场景失败: %s" % src)
		return
	var root: Node = ps.instantiate()
	add_child(root)
	# 挂载到场景树后依序调用指定方法并等待帧渲染
	for c in calls:
		var m := str(c["name"])
		var cargs: Array = c["args"]
		if not root.has_method(m):
			_fail("未找到方法: %s" % m)
			return
		var arity := _arity_of(root, m)
		if arity.size() == 2 and (cargs.size() < int(arity[0]) or cargs.size() > int(arity[1])):
			_fail("方法 %s 需要 %s 个实参，args= 提供了 %d 个"
					% [m, _arity_text(arity), cargs.size()])
			return
		root.callv(m, cargs)
		for f in 2:
			await get_tree().process_frame
	for i in 4:
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		_fail("获取视口纹理失败")
		return
	var path := OUT_DIR + out
	var err := img.save_png(path)
	print("SHOT: %s → %s(err=%d, %dx%d)" % [src.get_file(), path, err, img.get_width(),
			img.get_height()])
	get_tree().quit(0 if err == OK else 1)


func _parse_args(text: String) -> Variant:
	if text.strip_edges().is_empty():
		_fail("args= 未包含有效 JSON 内容")
		return null
	var j := JSON.new()
	if j.parse(text) != OK:
		var where := "" if j.get_error_line() <= 0 else "第 %d 行: " % j.get_error_line()
		_fail("args= 不是合法 JSON (%s%s): %s" % [where, j.get_error_message(), text])
		return null
	if not (j.data is Array):
		_fail("args= 必须是 JSON 数组实参列表，实际获取: %s" % str(j.data))
		return null
	return j.data


func _arity_of(root: Node, m: String) -> Array:
	var infos: Array = []
	var script: Script = root.get_script()
	if script != null:
		infos = script.get_script_method_list()
	if infos.is_empty():
		infos = root.get_method_list()
	for info in infos:
		if str(info.get("name", "")) == m:
			var total := (info.get("args", []) as Array).size()
			var defaults := (info.get("default_args", []) as Array).size()
			return [total - defaults, total]
	return []


func _arity_text(arity: Array) -> String:
	return str(arity[0]) if int(arity[0]) == int(arity[1]) else "%d~%d" % [arity[0], arity[1]]


func _fail(msg: String) -> void:
	print("SHOT: FAIL %s" % msg)
	get_tree().quit(1)

