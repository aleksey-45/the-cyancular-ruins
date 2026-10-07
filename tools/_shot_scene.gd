extends Node

# 【一次性校验工具】把任意 `.tscn` 当子节点挂上、跑几帧、存一张图。
# 用途:把 `tools/gen_menu_scene` 导出的基础结构框架**画出来**,与改前的基线图逐像素比对
# —— 这是"迁移 = 外观不变"唯一的判据(静态检查看不出渲染差异)。
#
# 用法(-  **不带 `--headless`** —— headless 下 root 视口纹理是空壳,取图静默为空):
#   "<GODOT>" --path . res://tools/_shot_scene.tscn -- <res://场景> <输出名.png> [指令 ...]
#   输出固定落在 `res://.superpowers/sdd/_gen/<输出名.png>`(gitignored 的 scratch,
#   **不是**持久记录 —— 持久记录是计划文档「已知边界」里那份文件名 + md5)。
#
# 指令(按给出的顺序执行):
#   <方法名> | call=<方法名>   在挂上的根节点上按序调一次(`callv`)
#   args=<JSON 数组>          给**紧前**那一条方法当实参(JSON 解析后传进 `callv`)
#   addr=<host>               实例化**之前**把 `PvpSession.server_address` 钉成 <host>
#   --help | -h               打印这段用法并退出
#
# - 为什么要有"调方法"这半:大厅那三个弹层是"启动即建、默认隐藏"的 —— 要取到
#   「加入面板开 / 创建弹层开 / 等待室开」这三张**打开态**的图,只能像玩家那样先调一次
#   打开方法(`_toggle_join_panel` / `_open_create_dialog` / `_show_wait_room`)。
#   **按顺序**调、每个之间等 2 帧(方法里可能改可见性/尺寸,同帧连调会读到中间态)。
#   - 四条坏输入路径都**当场判失败退出、绝不存图**:方法不存在 · 实参个数对不上 ·
#   `args=` 不是合法 JSON · `args=` 不是数组。理由只有一条:**静默跳过(或存下一张错的图)
#   就等于"取了一张没打开任何东西的图",而它与真·打开态在文件名上分不出来** ——
#   那是本仓最贵的一类假证据(存的图看起来"正常",判据保持测试通过)。
#   - 实参个数那一跳:光靠 `callv` 抓不到 —— 个数不对时它只打一条引擎 ERROR、**探针不红**、
#   图照存。故调用前先用 `get_script_method_list()` 的 `args`/`default_args` 算允许区间,
#   对不上就红;取不到元数据时只退回"方法存在性"检查(宁可不判,也不虚假失败（测试用例误报）)。
#
# - `args=<JSON>` 为什么存在(2026-10-03,最终整体评审 Important 4):此前"带实参的相"
#   只能靠 `.superpowers/sdd/_gen/` 下的一份**一次性驱动脚本**喂实参  ->  那个态的权威图对
#   **在仓库内复现不了**(驱动是 gitignored 的 scratch)。JSON 数组是命令行能携带的、
#   且 `callv` 直接就收的形状:于是"带参调用"回到**入库的**这一个工具里。
#   例(**中性**):`... -- res://某个.tscn a.png call=某个方法 'args=[1,"二",{"k":3},[4]]'`
#   - shell 里**要引号**:JSON 含空格/花括号,不引会被拆成多个 argv。
#   - **具体某个屏的夹具不写在这里**:大厅四个验收态的完整命令 + 等待室那一相的实参
#     (逐字照抄 `tests/probe/lobby_wait_room_probe.gd` 的 `_royale_state`)记在计划文档的
#     「已知边界」第 16 条 —— 本工具只提供**通用机制**,不携带任何屏的夹具(否则它就得跟着屏幕改)。
#
# - `addr=` 为什么存在:大厅状态栏那一行文案是**网络驱动**的 —— 生产默认地址是云服,
#   而取图只等几帧  -> 「连上了、列房应答还没回来」与「没连上」这两相之间由**网络时序**决定,
#   同一份代码两次取图可以落同一相,而改前/改后那一对**各落一相**(实测差一整行)。钉到本机
#   死地址(`127.0.0.1`) ->  状态栏确定地停在"没连上"那一相,改前/改后各两遍才可比。
#   - 必须在**实例化之前**钉(场景 `_ready` 里就读它) ->  实现上"先扫全表、再实例化、最后调用"。
#   - 它只改**本进程内**的会话字段,不碰任何生产默认值;两侧命令都给同一个 `addr=` 才叫同输入。
#
# - 通用性:本工具**实现里没有任何按场景名 / 节明确提示 / 方法名分叉的代码** —— `call=`/`args=` 是通用反射,
#   `addr=` 只钉一个通用会话字段;"取哪一相"完全由命令行给(上面那几条大厅的话只是**用法举例**,
#   行为与场景名无关:换成任何 `.tscn` + 任何方法名都同一条代码路径)。

const OUT_DIR := "res://.superpowers/sdd/_gen/"

const USAGE := """用法(★ 不带 --headless):
  "<GODOT>" --path . res://tools/_shot_scene.tscn -- <res://场景> <输出名.png> [指令 ...]
指令:
  <方法名> | call=<方法名>   按序在根节点上调一次
  args=<JSON 数组>          给紧前那一条方法的实参(不合法/不是数组 ⇒ FAIL + quit(1))
  addr=<host>               钉 PvpSession.server_address(须与对侧同给,才叫同输入)
  --help | -h               打印本用法
输出:res://.superpowers/sdd/_gen/<输出名.png>"""


func _ready() -> void:
	var argv := OS.get_cmdline_user_args()
	if argv.has("--help") or argv.has("-h"):
		print(USAGE)
		get_tree().quit(0)
		return
	if argv.size() < 2:
		_fail("用法 `-- <res://场景> <输出名.png> [指令 ...]`(`-- --help` 打全用法)")
		return
	var src := str(argv[0])
	var out := str(argv[1])

	# ── 先扫全表:`addr=` 必须在**实例化之前**生效,故调用表与地址分两趟收 ──
	var addr := ""
	var calls: Array = []          # [{ "name": String, "args": Array }]
	var ai := 2
	while ai < argv.size():
		var tok := str(argv[ai])
		if tok.begins_with("addr="):
			var host := tok.substr(5)
			if host.is_empty():
				_fail("`addr=` 少了主机名:%s" % tok)
				return
			if not addr.is_empty():
				_fail("`addr=` 只许给一次(第二个是 %s)" % tok)
				return
			addr = host
		elif tok.begins_with("call="):
			var m := tok.substr(5)
			if m.is_empty():
				_fail("`call=` 少了方法名")
				return
			calls.append({"name": m, "args": []})
		elif tok.begins_with("args="):
			if calls.is_empty():
				_fail("`args=` 必须紧跟在一个方法名/`call=` 之后(它只作用于紧前那一条):%s" % tok)
				return
			var last: Dictionary = calls[calls.size() - 1]
			if not (last["args"] as Array).is_empty():
				_fail("`%s` 已经有实参了,`args=` 一条方法只许给一次" % last["name"])
				return
			var parsed = _parse_args(tok.substr(5))
			if parsed == null:
				return
			last["args"] = parsed
		elif tok.contains("="):
			# 认不出来的 `k=v` 一律判失败:若当成方法名去调,判词会是"无此方法 a=b"(误导)。
			_fail("不认识的参数 `%s`(只认 addr= / call= / args=;方法名里不会含 `=`)" % tok)
			return
		else:
			# - 裸方法名 = 无实参的 `call=`(同一个代码路径,不是第二套语法)。
			calls.append({"name": tok, "args": []})
		ai += 1

	if not addr.is_empty():
		PvpSession.server_address = addr

	var ps: PackedScene = load(src)
	if ps == null:
		_fail("读不到 %s" % src)
		return
	var root: Node = ps.instantiate()
	add_child(root)
	# 实例化即 `add_child`:下面这些方法都假定自己已加入场景树(锚点/尺寸依赖父级尺寸)。
	for c in calls:
		var m := str(c["name"])
		var cargs: Array = c["args"]
		if not root.has_method(m):
			_fail("无此方法 %s(静默跳过 = 取一张没打开任何东西的图)" % m)
			return
		var arity := _arity_of(root, m)
		if arity.size() == 2 and (cargs.size() < int(arity[0]) or cargs.size() > int(arity[1])):
			_fail("`%s` 要 %s 个实参,`args=` 给了 %d 个(callv 在这种情形只打引擎 ERROR、探针不红)"
					% [m, _arity_text(arity), cargs.size()])
			return
		root.callv(m, cargs)
		for f in 2:
			await get_tree().process_frame
	for i in 4:
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		_fail("取不到视口纹理")
		return
	var path := OUT_DIR + out
	var err := img.save_png(path)
	print("SHOT: %s → %s(err=%d, %dx%d)" % [src.get_file(), path, err, img.get_width(),
			img.get_height()])
	get_tree().quit(0 if err == OK else 1)


# `args=` 的 JSON 解析。返回实参数组;任何坏输入都**打一句可读的判词并返回 null**
# (调用方立刻退出  ->  不会走到存图那一步)。
func _parse_args(text: String) -> Variant:
	if text.strip_edges().is_empty():
		_fail("`args=` 后面没有 JSON")
		return null
	var j := JSON.new()
	if j.parse(text) != OK:
		# `get_error_line()` 对单行输入返回 0  ->  只在 >0 时报行号(报"第 0 行"像 bug)。
		var where := "" if j.get_error_line() <= 0 else "第 %d 行:" % j.get_error_line()
		_fail("`args=` 不是合法 JSON(%s%s):%s" % [where, j.get_error_message(), text])
		return null
	if not (j.data is Array):
		# 单给一个 object/标量是最容易犯的错(`callv` 要的是**实参表**) ->  断言信息需明确说明原因。
		_fail("`args=` 必须是 JSON **数组**(= 实参表),实得 %s" % str(j.data))
		return null
	return j.data


# 方法能收几个实参  ->  `[最少, 最多]`(带默认值的参数使两者不等);取不到元数据  ->  `[]`。
# - 为什么值得单列一跳:`callv` 实参个数不对时**只打引擎 ERROR、不返回错误码**,外面看起来
#   与"调成功"没有区别 —— 图会照存。故在调用前用元数据判一次(本仓"守卫能给的保证总是比它
#   读起来少"那条纪律的落点)。
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
