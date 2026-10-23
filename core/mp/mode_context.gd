class_name ModeContext
extends RefCounted

# worker argv 解析 + 校验(纯函数、不引 autoload ⇒ `-s` 可测)。
#
# 为什么收在这里:`server_main._ready` 里"模式开关互斥 / --roles 与 --teams 等长 / role 上界"
# 原本与开关解析混在同一个 match 循环里,而 role 上界是**字面量 8** —— 大厅把上限提到 16 时
# 只改了大厅/UI/色板,worker 仍卡 8(16 人房第 9 人起被当串线踢;X1)。收成纯函数后:
#   · 上界只认 `ModeDefs.ROLE_MAX`;
#   · 越界/非法 token 从"静默丢"改成**拒绝启动**(静默丢正是 X1 活到今天的原因);
#   · 上面三条校验都能用最便宜的 `-s` 冒烟钉住。
#
# 返回字典(全部键恒存在):
#   ok:bool / error:String / worker:bool / royale:bool / team:bool / port:int
#   roles:Array[int] / ai_roles:Array[int] / teams:Array[int] / team_of:Dictionary(role -> 队号)
# ★ `default_port` 由调用方给(`server_main` 传 `NetBus.DEFAULT_PORT`)—— 本文件不引 autoload。

const FLAG_WORKER := "--worker"
const FLAG_ROYALE := "--royale"
const FLAG_TEAM := "--team"
const FLAG_PORT := "--port"
const FLAG_ROLES := "--roles"
const FLAG_AI_ROLES := "--ai-roles"
const FLAG_TEAMS := "--teams"

const TEAM_MIN := 1
const TEAM_MAX := 2


static func from_args(args: PackedStringArray, default_port: int = 7777) -> Dictionary:
	var ctx := {
		"ok": true,
		"error": "",
		"worker": false,
		"royale": false,
		"team": false,
		"port": default_port,
		"roles": [] as Array[int],
		"ai_roles": [] as Array[int],
		"teams": [] as Array[int],
		"team_of": {},
	}
	var roles: Array[int] = []
	var ai_roles: Array[int] = []
	var teams: Array[int] = []
	for i in args.size():
		var a := args[i]
		match a:
			FLAG_WORKER:
				ctx["worker"] = true
			FLAG_ROYALE:
				ctx["royale"] = true
			FLAG_TEAM:
				ctx["team"] = true
			FLAG_PORT:
				if i + 1 < args.size():
					ctx["port"] = int(args[i + 1])
			FLAG_ROLES:
				_parse_int_list(args, i, ModeDefs.ROLE_MAX, "role", roles, ctx)
			FLAG_AI_ROLES:
				_parse_int_list(args, i, ModeDefs.ROLE_MAX, "AI role", ai_roles, ctx)
			FLAG_TEAMS:
				_parse_int_list(args, i, TEAM_MAX, "队号", teams, ctx)
	ctx["roles"] = roles
	ctx["ai_roles"] = ai_roles
	ctx["teams"] = teams

	if not bool(ctx["worker"]):
		return ctx   # 大厅不校验这些(它不参战)

	# ★ 模式开关互斥:两边同时为真手敲会走 royale 那支开局,而 _team_of_role 永不填充、
	#   _begin_match 却按 _team_mode 去建 TeamHost → 空 teams → spawns[role] 全员缺键。
	if bool(ctx["royale"]) and bool(ctx["team"]):
		_fail(ctx, "--royale 与 --team 不能同时为真(模式开关互斥)")
		return ctx
	if bool(ctx["royale"]):
		if roles.is_empty():
			_fail(ctx, "大乱斗 worker 缺 --roles(本局参战 role 集合);不猜集合 —— 猜错 = 静默踢真客户端")
		return ctx
	if bool(ctx["team"]):
		if roles.is_empty() or roles.size() != teams.size():
			_fail(ctx, "3v3 worker 的 --roles 与 --teams 必须等长且非空(%d vs %d);猜默认队号会把整局分成错的队"
					% [roles.size(), teams.size()])
			return ctx
		# teams 的键必须覆盖本局全部参战 role:TeamHost 的摆位表按 teams.keys() 出键,
		# 缺键会让那个 role 静默生在 (-1,-1)。
		var team_of := {}
		for idx in range(roles.size()):
			team_of[roles[idx]] = teams[idx]
		ctx["team_of"] = team_of
		return ctx
	# 1v1:手工调用兜底(大厅路径不带 --roles)。
	if roles.is_empty():
		ctx["roles"] = [1, 2] as Array[int]
	return ctx


static func _parse_int_list(args: PackedStringArray, i: int, max_value: int, label: String,
		out: Array[int], ctx: Dictionary) -> void:
	if i + 1 >= args.size():
		_fail(ctx, "缺 %s 值" % label)
		return
	for tok in str(args[i + 1]).split(","):
		var s := tok.strip_edges()
		if not s.is_valid_int():
			_fail(ctx, "%s 不是整数: %s" % [label, s])
			return
		var v := int(s)
		if v < 1 or v > max_value:
			_fail(ctx, "%s 越界(允许 1..%d): %d" % [label, max_value, v])
			return
		out.append(v)


static func _fail(ctx: Dictionary, why: String) -> void:
	if bool(ctx["ok"]):
		ctx["ok"] = false
		ctx["error"] = why
