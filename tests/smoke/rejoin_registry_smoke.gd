extends SceneTree

# 断线重连凭据注册表纯逻辑冒烟测试：
# 验证 RejoinRegistry 中基于角色与局号（match_id）的凭据签发、时效验证与注销机制。
# 运行方式：
#   "$GODOT" --headless --path . -s res://tests/smoke/rejoin_registry_smoke.gd

const _SECTIONS := 8     # ① ② ②b ③ ④ ⑤ ⑥ ⑦(⑦ = owns,B1 甲案)

var _ran := 0


func _initialize() -> void:
	var S: GDScript = load("res://server/lobby/rejoin_registry.gd")
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

	# ── ① 登记 -> 查得到,字段逐一对上 ──
	_ran += 1
	r.grant("tk_a", "1234", 1, 29001, 0)
	var e: Dictionary = r.lookup("tk_a", 0)
	if e.is_empty():
		fails.append("★ 登记后查不到凭据")
	else:
		if str(e.get("code", "")) != "1234":
			fails.append("凭据的 code 字段不对:%s" % str(e.get("code", "")))
		if int(e.get("role", 0)) != 1:
			fails.append("凭据的 role 字段不对:%s" % str(e.get("role", 0)))
		if int(e.get("match_id", 0)) != 29001:
			fails.append("凭据的 match_id 字段不对:%s" % str(e.get("match_id", 0)))
		# 新登记的凭证状态初始值应为 alive = true。
		if not bool(e.get("alive", false)):
			fails.append("★ 刚登记的凭据 alive 必须为 true(默认 false 会让回局必被拒)")
	if r.size() != 1:
		fails.append("登记一条后 size 应为 1,实得 %d" % r.size())

	# ── ② TTL 边界(与 GraceWindow 同口径:含边界)──
	_ran += 1
	var ttl := int(float(S.TOKEN_TTL_SECONDS) * 1000.0)
	if r.lookup("tk_a", ttl - 1).is_empty():
		fails.append("★ TTL 到期前 1ms 不该失效")
	if not r.lookup("tk_a", ttl).is_empty():
		fails.append("★ 正好到点(now == expires_at)必须失效 —— 取 > 会让它永不过期、表只增不减")
	if r.size() != 1:
		fails.append("★ lookup 不得改变表(GC 只走 prune),实得 size=%d" % r.size())

	# ── ②b 跨文件不变量:凭据的 TTL 必须不短于宽限期 ──
	# - 为什么这条要在这里钉:宽限期内玩家手里那份凭据必须是有效的。TTL 短于宽限期会让一个
	#   还在宽限期里的玩家被大厅以「凭据已失效」拒掉,而那条拒绝与"对局真的结束了"
	#   在日志与提示上一模一样(玩家与排查者都会读成"这局没了")。
	_ran += 1
	if float(S.TOKEN_TTL_SECONDS) < float(G.DEFAULT_SECONDS):
		fails.append("★ 凭据 TTL(%.0fs)不得短于宽限期(%.0fs)—— 宽限期内凭据必须有效"
				% [float(S.TOKEN_TTL_SECONDS), float(G.DEFAULT_SECONDS)])

	# ── ③ prune:清过期的、不动没过期的、返回清掉的条数 ──
	_ran += 1
	# 注意事项：brief 原文这里写的是 `..., 4243, 0)`(与 tk_a 同一时刻登记)—— 那样 tk_b 的到期时刻
	#   与 tk_a 相同(都 = ttl),`prune(ttl)` 会把两条一起清掉,而本段下面三条断言
	#   ("清掉 1 条" / "剩 1 条(tk_b)" / "不得动没过期的")与 ⑤("tk_b 必须是 end_match 的目标")、⑥
	#   都要求 tk_b 活过 `ttl`。故把登记时刻改成 `ttl`(tk_b 是后来登记的),本段意图不变。
	r.grant("tk_b", "5678", 2, 29002, ttl)
	# - `r` 是 `S.new()` 的结果(无静态类型) ->  这里不能用 `:=`:返回值是 Variant,
	#   Godot 会直接 Parse Error("Cannot infer the type of n variable"),整个冒烟一行都跑不到。
	var n: int = r.prune(ttl)
	if n != 1:
		fails.append("prune 应清掉 1 条过期凭据,实得 %d" % n)
	if r.size() != 1:
		fails.append("prune 之后应剩 1 条(tk_b),实得 %d" % r.size())
	if r.lookup("tk_b", ttl).is_empty():
		fails.append("★ prune 不得动没过期的凭据")

	# ── ④ 验收标准：三种拒绝 + 放行,且优先级是对的 ──
	_ran += 1
	var live: Dictionary = r.lookup("tk_b", 0)
	if r.decision({}, "5678", true) == "":
		fails.append("★ 凭据不存在必须拒绝(不能放行)")
	# 注意事项：brief 原文这条是 `.contains("凭据")` —— 它拦不住它自己写明的那个错:两条拒绝理由
	#   ("凭据已失效(对局可能已结束)" 与 "房间号与凭据不符")都含「凭据」二字,
	#   顺序写反照样全部断言通过(2026-09-21 实测:按 brief 的变异②对调两条分支  ->  冒烟仍 ALL-OK,
	#   即这条防御性校验等于不存在)。故拆成两条:
	#   ① 措辞无关的结构判定条件 —— 两种拒绝必须给不同的理由;
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
		fails.append("★ 对局已结束必须拒绝(否则会把客户端送回一个已经没有对局的房)")
	if r.decision(live, "5678", true) != "":
		fails.append("★ 三者都对必须放行,实得理由:%s" % r.decision(live, "5678", true))

	# ── ⑤ end_match 精确标记指定对局凭证为已结束 ──
	# 凭证索引使用 match_id，隔离不同房间类型的房间号命名冲突。
	# end_match 仅将 alive 字段标记为 false，不直接删除条目，以便区分“凭证失效”与“对局已结束”。
	_ran += 1
	r.grant("tk_c", "5678", 1, 29003, 0)   # 与 tk_b 同号、不同局号
	r.grant("tk_d", "7777", 1, 29004, 0)
	var ended: int = r.end_match(29002)   # 同上:不能 `:=`
	if ended != 1:
		fails.append("end_match(29002) 应标记 1 条(tk_b),实得 %d" % ended)
	if bool(r.lookup("tk_b", 0).get("alive", true)):
		fails.append("★ 那一局结束了 -> tk_b 的 alive 必须翻成 false")
	if not bool(r.lookup("tk_c", 0).get("alive", false)):
		fails.append("★ end_match 不得动**同号的另一间房**的凭据(房号空间重叠 —— 按 code 键就是这个下场)")
	if not bool(r.lookup("tk_d", 0).get("alive", false)):
		fails.append("★ end_match 不得动别的局的凭据")
	if r.size() != 3:
		fails.append("★ end_match 只翻 alive、**不删条目**(回局要能回答「对局已结束」而不是「凭据失效」),size 应仍为 3,实得 %d" % r.size())
	# - 反向:局号 <= 0 不许当成"通配"(凭据的 match_id 恒 > 0,0 不可能是任何一条的键)
	if r.end_match(0) != 0:
		fails.append("★ end_match(0) 动了东西 —— 0 不是任何一条凭据的键,当成通配会一次翻掉整张表")
	if not bool(r.lookup("tk_c", 0).get("alive", false)) \
			or not bool(r.lookup("tk_d", 0).get("alive", false)):
		fails.append("end_match(0) 不得改变表")

	# ── ⑥ drop_token 只掉那一个 ──
	_ran += 1
	r.grant("tk_e", "7777", 2, 29004, 0)
	r.drop_token("tk_e")
	if not r.lookup("tk_e", 0).is_empty():
		fails.append("drop_token 之后不该还查得到")
	if r.lookup("tk_d", 0).is_empty():
		fails.append("★ drop_token 不得误伤别的凭据")

	# ── ⑦ owns:「这份凭据是不是这一间房的」(B1 甲案:私密房只对本人列出)──
	# - 它和 `decision()` 是两个不同的问法,别合并:`decision` 问"能不能放他进去"
	#   (还要 worker 活着),`owns` 只问"这份凭据属不属于这间房" —— 列表只该问后者
	#   (见 owns 的注释:多判一次 worker 活性只会让那一行提前消失)。
	# - 三种测试漏报都是静默的:恒 true(私密房对所有人列出 = "私密"没了)、恒 false
	#   (私密房永远不列 = B1 没做)、只看 token 非空(同号房的凭据也放行)。三条各断一次。
	_ran += 1
	r.grant("tk_own", "1234", 1, 29005, 0)
	if not r.owns("tk_own", "1234", 0):
		fails.append("★ owns:属于自己的那一间房必须 true(否 = 私密房永远不列 = B1 没做)")
	if r.owns("tk_own", "9999", 0):
		fails.append("★ owns:房号不符必须 false(否则同号的另一间房的凭据也放行)")
	# - 下面这一条今天是一根保险带:删掉 `owns` 里那个 `token.is_empty()` 提前返回,
	#   它还照样是 false(表里根本不会有空键);它挡的是"缺省值取 code"那类将来写法。
	#   留着是因为它便宜且描述的是契约,但别把它读成"提前返回为核心关键约束"。
	if r.owns("", "1234", 0):
		fails.append("★ owns:空 token 必须 false(`PvpSession.token` 的默认值就是空串)")
	if r.owns("tk_nonexistent", "1234", 0):
		fails.append("owns:表里没有的 token 必须 false")
	if r.owns("tk_own", "1234", ttl + 1):
		fails.append("★ owns:过期凭据必须 false(它走 lookup ⇒ 过期当不存在,与 ② 同口径)")

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
