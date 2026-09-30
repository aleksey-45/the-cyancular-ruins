extends SceneTree

# 回局凭据表(`server/rejoin_registry.gd`)的纯逻辑冒烟。
# 跑法: "$GODOT" --headless --path . -s res://tests/rejoin_registry_smoke.gd
# 通过 = `REJOIN REGISTRY: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 这张表的错法全是**静默**的:TTL 边界取 > 会让"正好到点"永不过期(表只增不减);
#   判据顺序写反会把"凭据根本不存在"报成"房间号不符"(玩家看到的提示是错的、排查方向也是错的);
#   作废时按**前缀/房号**匹配会把别的局的凭据一起翻掉(那一局的玩家再也回不去,而没有任何日志);
#   `end_match(0)` 当成"通配"会一次翻掉**整张表**(0 只出现在"还没开局"的房上)。
#   ★ 2026-09-21:归键从**房间号**改成 **worker 端口**(`drop_port`)—— 房号空间在三张注册表之间
#     是重叠的,按 code 作废会误伤**同号**的另一间房(同一个"范围比该有的大"的错,只是换了一层)。
#   ★★ 单进程单端口之后端口不再标识任何一局,归键改成 **局号 `match_id`**(`end_match(match_id)`):
#     局号由 `RoomManager` 唯一递增分配、**永不复用**;而"这一局还在不在"就记在条目自己的
#     `alive` 字段上(会话结束那一刻由 `RoomManager._on_session_finished` 翻),不再去问进程/端口。
# ★ 空载守卫:load 失败立刻 quit(1),否则抛错走不到 quit() → 进程永久挂起。
#
# ★★ 断言段计数(2026-09-21):`ALL-OK` 只证明"没有失败",**不证明"全都跑了"**(本仓咬过四次)——
#   整段被删掉时上面一条 fails 都不会有,于是静默打印 ALL-OK。故每段开头 `_ran += 1`,
#   收尾核对段数与 `_SECTIONS` 相符,并把实际段数打进裁决里。

const _SECTIONS := 8     # ① ② ②b ③ ④ ⑤ ⑤b ⑥

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
	# `grant(token, code, role, match_id, now_ms)` —— 第 4 个参数是**局号**(原先放 worker 端口)
	r.grant("tk_a", "48207", 1, 101, 0)
	var e: Dictionary = r.lookup("tk_a", 0)
	if e.is_empty():
		fails.append("★ 登记后查不到凭据")
	else:
		if str(e.get("code", "")) != "48207":
			fails.append("凭据的 code 字段不对:%s" % str(e.get("code", "")))
		if int(e.get("role", 0)) != 1:
			fails.append("凭据的 role 字段不对:%s" % str(e.get("role", 0)))
		if int(e.get("match_id", 0)) != 101:
			fails.append("凭据的 match_id 字段不对:%s" % str(e.get("match_id", 0)))
		# ★ `alive` 是"这一局还在不在"的判据(端口时代那问题由 worker pid 回答,现在当场可问):
		#   登记发生在开局那一刻,那一局当然还活着 —— 登记完就是 false 的话回局会被当场拒掉。
		if not bool(e.get("alive", false)):
			fails.append("★ 刚登记的凭据 alive 必须是 true(否则回局当场被拒、且没有任何别处会翻回来)")
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
	#   ("清掉 1 条" / "剩 1 条(tk_b)" / "不得动没过期的")与 ⑤("tk_b 必须活到 ⑤")、⑥
	#   都要求 tk_b 活过 `ttl`。故把登记时刻改成 `ttl`(tk_b 是**后来**登记的),本段意图不变。
	r.grant("tk_b", "48208", 2, 102, ttl)
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
	if r.decision({}, "48208", true) == "":
		fails.append("★ 凭据不存在必须拒绝(不能放行)")
	# ★★ brief 原文这条是 `.contains("凭据")` —— 它**拦不住**它自己写明的那个错:两条拒绝理由
	#   ("凭据已失效(对局可能已结束)" 与 "房间号与凭据不符")**都含「凭据」二字**,
	#   顺序写反照样全绿(2026-09-21 实测:按 brief 的变异②对调两条分支 ⇒ 冒烟仍 ALL-OK,
	#   即这条守卫等于不存在)。故拆成两条:
	#   ① **措辞无关**的结构判据 —— 两种拒绝必须给**不同**的理由;
	#   ② 这个理由必须讲"失效"(即凭据那一支的语义)。
	var why_empty: String = r.decision({}, "48208", true)
	var why_code: String = r.decision(live, "99999", true)
	if why_empty == why_code:
		fails.append("★ 「凭据不存在」与「房间号不符」必须给**不同**的理由(顺序写反/合并成同一条会让玩家看到错的提示、排查方向也跟着错)")
	if not why_empty.contains("失效"):
		fails.append("★ 凭据不存在时给的**理由**必须是「凭据失效」那一支(顺序写反会报成「房间号不符」、把人引向错方向),实得:%s" % why_empty)
	if r.decision(live, "99999", true) == "":
		fails.append("★ 房间号不符必须拒绝")
	# ★ 第三个入参的语义是"**那一局还在不在**"(不再是 worker_alive):false ⇒ 拒绝
	if r.decision(live, "48208", false) == "":
		fails.append("★ 那一局已结束必须拒绝(否则会把客户端送回一局已经结束的对局)")
	if r.decision(live, "48208", true) != "":
		fails.append("★ 三者都对必须放行,实得理由:%s" % r.decision(live, "48208", true))

	# ── ⑤ end_match 只作废**那一局**的凭据(同号的另一局、以及别的局的都必须还在)──
	# ★★ 归键是 **局号 `match_id`**,不是房间号:三张注册表(`rooms` / `royale_rooms` /
	#   `team_rooms`)的房号空间**重叠** —— 三处都只用 `_generate_code()` 的 5 位号、且各查各的
	#   `has(code)`,所以"1v1 的 48208"与"大乱斗的 48208"可以**同时存在**。
	#   故下面 tk_b / tk_c **故意同号不同局**:tk_b 是"要结束的那一局",tk_c 是"同号的另一间房"
	#   —— 按 code 作键时它会跟着 tk_b 一起作废(损坏有界但**一行日志都没有**)。
	_ran += 1
	r.grant("tk_c", "48208", 1, 103, 0)   # ★ 与 tk_b **同号**、不同局号
	r.grant("tk_d", "48209", 1, 104, 0)
	var ended: int = r.end_match(102)   # 同上:不能 `:=`
	if ended != 1:
		fails.append("end_match(102) 应作废 1 条(tk_b),实得 %d" % ended)
	# ★ end_match **只翻 alive、不删条目**:条目留着,回局查询仍看得见它、由 `alive` 回答"没了"
	#   (查不到与"局已结束"是两回事,提示语也不同)。
	if bool(r.lookup("tk_b", 0).get("alive", true)):
		fails.append("★ end_match 必须把该局凭据的 alive 翻成 false")
	if not bool(r.lookup("tk_c", 0).get("alive", false)):
		fails.append("★ end_match 不得动**同号的另一局**的凭据(房号空间重叠 —— 按 code 作键就是这个下场)")
	if not bool(r.lookup("tk_d", 0).get("alive", false)):
		fails.append("★ end_match 不得动别的局的凭据")
	if r.size() != 3:
		fails.append("end_match 只翻 alive、不删条目,size 应仍为 3,实得 %d" % r.size())

	# ── ⑤b 幂等 + 局号 <= 0 不许当成"通配" ──
	# ★ 为什么幂等要单独钉:同一局的结束可能由两条梯子到达(`MatchSession._finish` 自带 `_done` 闸,
	#   而"超龄清扫"也会 `abort()` 到同一处)。重复结束**不许**牵连别的局,也不许把条目删掉
	#   (条目没了 ⇒ "局已结束"与"凭据不存在"两种拒绝混成一条,提示与排查方向一起错)。
	_ran += 1
	r.end_match(102)
	var b_dead := not bool(r.lookup("tk_b", 0).get("alive", true))
	var c_alive := bool(r.lookup("tk_c", 0).get("alive", false))
	var d_alive := bool(r.lookup("tk_d", 0).get("alive", false))
	if not (b_dead and c_alive and d_alive and r.size() == 3):
		fails.append("★ end_match 重复调用必须幂等(该局仍已作废、别的局与条数都不许变)")
	# ★ 反向:0 / 负数**不是合法的局号**(0 只出现在"还没开局"的房上),当成通配会一次翻掉整张表。
	#   ★ 为了让这条**不空转**,下面这份凭据的 match_id 就是 0 —— 没有 `match_id <= 0` 那道闸时,
	#   `end_match(0)` 会当场把它翻成 false(旧实现 `drop_port(0)` 的同款病)。
	r.grant("tk_zero", "48210", 1, 0, 0)
	var z0: int = r.end_match(0)
	var zneg: int = r.end_match(-1)
	if z0 != 0 or zneg != 0:
		fails.append("★ end_match(0)=%d / end_match(-1)=%d 必须什么都不清(0 不是合法局号)" % [z0, zneg])
	if not bool(r.lookup("tk_zero", 0).get("alive", false)):
		fails.append("★ end_match(0) 翻了 match_id=0 的凭据 —— `match_id <= 0` 那道闸没了,一次通配能翻掉整张表")
	if r.size() != 4:
		fails.append("end_match(0)/(-1) 不得改变表,实得 size=%d" % r.size())

	# ── ⑥ drop_token 只掉那一个(同一局里还有另一个人的凭据)──
	_ran += 1
	r.grant("tk_e", "48209", 2, 104, 0)   # ★ 与 tk_d **同一局**、同号:一局里两份凭据
	r.drop_token("tk_e")
	if not r.lookup("tk_e", 0).is_empty():
		fails.append("drop_token 之后不该还查得到")
	if r.lookup("tk_d", 0).is_empty() or not bool(r.lookup("tk_d", 0).get("alive", false)):
		fails.append("★ drop_token 不得误伤别的凭据(同一局里另一个人的那份也还在)")

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
