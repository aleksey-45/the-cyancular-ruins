extends SceneTree

# 回局凭据表(`server/rejoin_registry.gd`)的纯逻辑冒烟。
# 跑法: "$GODOT" --headless --path . -s res://tests/rejoin_registry_smoke.gd
# 通过 = `REJOIN REGISTRY: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 这张表的错法全是**静默**的:TTL 边界取 > 会让"正好到点"永不过期(表只增不减);
#   判据顺序写反会把"凭据根本不存在"报成"房间号不符"(玩家看到的提示是错的、排查方向也是错的);
#   `drop_room` 按前缀匹配会把别的房的凭据一起清掉(那一局的玩家再也回不去,而没有任何日志)。
# ★ 空载守卫:load 失败立刻 quit(1),否则抛错走不到 quit() → 进程永久挂起。
#
# ★★ 断言段计数(2026-09-21):`ALL-OK` 只证明"没有失败",**不证明"全都跑了"**(本仓咬过四次)——
#   整段被删掉时上面一条 fails 都不会有,于是静默打印 ALL-OK。故每段开头 `_ran += 1`,
#   收尾核对段数与 `_SECTIONS` 相符,并把实际段数打进裁决里。

const _SECTIONS := 7     # ① ② ②b ③ ④ ⑤ ⑥

var _ran := 0


func _initialize() -> void:
	var S: GDScript = load("res://server/rejoin_registry.gd")
	if S == null:
		print("REJOIN REGISTRY: FAIL(加载 rejoin_registry.gd 失败)")
		quit(1)
		return
	var G: GDScript = load("res://core/net/grace_window.gd")
	if G == null:
		print("REJOIN REGISTRY: FAIL(加载 grace_window.gd 失败)")
		quit(1)
		return
	var fails: Array[String] = []
	var r = S.new()

	# ── ① 登记 → 查得到,字段逐一对上 ──
	_ran += 1
	r.grant("tk_a", "1234", 1, 29001, 4242, 0)
	var e: Dictionary = r.lookup("tk_a", 0)
	if e.is_empty():
		fails.append("★ 登记后查不到凭据")
	else:
		if str(e.get("code", "")) != "1234":
			fails.append("凭据的 code 字段不对:%s" % str(e.get("code", "")))
		if int(e.get("role", 0)) != 1:
			fails.append("凭据的 role 字段不对:%s" % str(e.get("role", 0)))
		if int(e.get("worker_port", 0)) != 29001:
			fails.append("凭据的 worker_port 字段不对:%s" % str(e.get("worker_port", 0)))
		if int(e.get("worker_pid", 0)) != 4242:
			fails.append("凭据的 worker_pid 字段不对:%s" % str(e.get("worker_pid", 0)))
	if r.size() != 1:
		fails.append("登记一条后 size 应为 1,实得 %d" % r.size())

	# ── ② TTL 边界(与 GraceWindow 同口径:**含边界**)──
	_ran += 1
	var ttl := int(float(S.TOKEN_TTL_SECONDS) * 1000.0)
	if r.lookup("tk_a", ttl - 1).is_empty():
		fails.append("★ TTL 到期前 1ms 不该失效")
	if not r.lookup("tk_a", ttl).is_empty():
		fails.append("★ 正好到点(now == expires_at)必须失效 —— 取 > 会让它永不过期、表只增不减")
	if r.size() != 1:
		fails.append("★ lookup 不得改变表(GC 只走 prune),实得 size=%d" % r.size())

	# ── ②b 跨文件不变量:凭据的 TTL 必须**不短于**宽限期 ──
	# ★ 为什么这条要在这里钉:宽限期内玩家手里那份凭据必须是有效的。TTL 短于宽限期会让一个
	#   **还在宽限期里**的玩家被大厅以「凭据已失效」拒掉,而那条拒绝与"对局真的结束了"
	#   在日志与提示上一模一样(玩家与排查者都会读成"这局没了")。
	_ran += 1
	if float(S.TOKEN_TTL_SECONDS) < float(G.DEFAULT_SECONDS):
		fails.append("★ 凭据 TTL(%.0fs)不得短于宽限期(%.0fs)—— 宽限期内凭据必须有效"
				% [float(S.TOKEN_TTL_SECONDS), float(G.DEFAULT_SECONDS)])

	# ── ③ prune:清过期的、不动没过期的、返回清掉的条数 ──
	_ran += 1
	# ★★ brief 原文这里写的是 `..., 4243, 0)`(与 tk_a 同一时刻登记)—— 那样 tk_b 的到期时刻
	#   与 tk_a 相同(都 = ttl),`prune(ttl)` 会把**两条一起**清掉,而本段下面三条断言
	#   ("清掉 1 条" / "剩 1 条(tk_b)" / "不得动没过期的")与 ⑤ 的"drop_room 应清 2 条(tk_b + tk_c)"
	#   都要求 tk_b 活过 `ttl`。故把登记时刻改成 `ttl`(tk_b 是**后来**登记的),本段意图不变。
	r.grant("tk_b", "5678", 2, 29002, 4243, ttl)
	# ★ `r` 是 `S.new()` 的结果(无静态类型)⇒ 这里**不能用 `:=`**:返回值是 Variant,
	#   Godot 会直接 Parse Error("Cannot infer the type of n variable"),整个冒烟一行都跑不到。
	var n: int = r.prune(ttl)
	if n != 1:
		fails.append("prune 应清掉 1 条过期凭据,实得 %d" % n)
	if r.size() != 1:
		fails.append("prune 之后应剩 1 条(tk_b),实得 %d" % r.size())
	if r.lookup("tk_b", ttl).is_empty():
		fails.append("★ prune 不得动没过期的凭据")

	# ── ④ 判据:三种拒绝 + 放行,且**优先级**是对的 ──
	_ran += 1
	var live: Dictionary = r.lookup("tk_b", 0)
	if r.decision({}, "5678", true) == "":
		fails.append("★ 凭据不存在必须拒绝(不能放行)")
	# ★★ brief 原文这条是 `.contains("凭据")` —— 它**拦不住**它自己写明的那个错:两条拒绝理由
	#   ("凭据已失效(对局可能已结束)" 与 "房间号与凭据不符")**都含「凭据」二字**,
	#   顺序写反照样全绿(2026-09-21 实测:按 brief 的变异②对调两条分支 ⇒ 冒烟仍 ALL-OK,
	#   即这条守卫等于不存在)。故拆成两条:
	#   ① **措辞无关**的结构判据 —— 两种拒绝必须给**不同**的理由;
	#   ② 这个理由必须讲"失效"(即凭据那一支的语义)。
	var why_empty: String = r.decision({}, "5678", true)
	var why_code: String = r.decision(live, "9999", true)
	if why_empty == why_code:
		fails.append("★ 「凭据不存在」与「房间号不符」必须给**不同**的理由(顺序写反/合并成同一条会让玩家看到错的提示、排查方向也跟着错)")
	if not why_empty.contains("失效"):
		fails.append("★ 凭据不存在时给的**理由**必须是「凭据失效」那一支(顺序写反会报成「房间号不符」、把人引向错方向),实得:%s" % why_empty)
	if r.decision(live, "9999", true) == "":
		fails.append("★ 房间号不符必须拒绝")
	if r.decision(live, "5678", false) == "":
		fails.append("★ worker 已退必须拒绝(否则会把客户端送到一个可能已经属于别人的端口)")
	if r.decision(live, "5678", true) != "":
		fails.append("★ 三者都对必须放行,实得理由:%s" % r.decision(live, "5678", true))

	# ── ⑤ drop_room 只掉那一间房的凭据(另一间房的必须还在)──
	_ran += 1
	r.grant("tk_c", "5678", 1, 29003, 4244, 0)
	r.grant("tk_d", "7777", 1, 29004, 4245, 0)
	var dropped: int = r.drop_room("5678")   # 同上:不能 `:=`
	if dropped != 2:
		fails.append("drop_room(5678) 应清掉 2 条(tk_b + tk_c),实得 %d" % dropped)
	if r.lookup("tk_d", 0).is_empty():
		fails.append("★ drop_room 不得动别的房的凭据(按 code **全等**比,不是前缀/包含)")
	if r.size() != 1:
		fails.append("drop_room 之后 size 应为 1,实得 %d" % r.size())

	# ── ⑥ drop_token 只掉那一个 ──
	_ran += 1
	r.grant("tk_e", "7777", 2, 29004, 4245, 0)
	r.drop_token("tk_e")
	if not r.lookup("tk_e", 0).is_empty():
		fails.append("drop_token 之后不该还查得到")
	if r.lookup("tk_d", 0).is_empty():
		fails.append("★ drop_token 不得误伤别的凭据")

	# ── 覆盖核对 ──
	if _ran != _SECTIONS:
		fails.append("断言段没跑全:%d/%d(有整段被跳过或删除 —— 上面一条 fails 都不会有)"
				% [_ran, _SECTIONS])
	print("REJOIN REGISTRY: 断言段 %d/%d" % [_ran, _SECTIONS])

	if fails.is_empty():
		print("REJOIN REGISTRY: ALL-OK")
		quit(0)
	else:
		print("REJOIN REGISTRY: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
