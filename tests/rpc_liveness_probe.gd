extends ProbeBase

# 「**定向发送前一律先判活**」这条硬纪律的**常驻源码级守卫**(场景模式;`--headless` 即可)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/rpc_liveness_probe.tscn
# 判据:末行 `KH RPC-LIVE PROBE: ALL-OK`(grep 文本,不看退出码)。
#
# ═══ 守的是什么 ═══
# 引擎那条 `Unable to send packet on channel 0, max channels: 0`
# (`enet_packet_peer.cpp:64`,判据 = **目标 peer 的 ENet 通道数为 0**,即"往一个 ENet 已拆掉、
#  MultiplayerAPI 还没忘掉的 peer 发包")只可能由**定向/广播的发送**打出。本探针把 `server/` 与
#  `core/net/` 下**每一处**发送点收进来,要求它落在一条**活的判据**里:
#
#   ① 定向发送(`rpc_id(` / `callv("rpc_id"`) —— 需要**包围它的**判据含
#      `NetBus.is_peer_live` / `is_peer_online(` / `can_send_to_server` / `all_peers_sendable`
#      (或直接走 `NetBus.reply(` —— 那本身就是"答复 caller"的收口,体内先判活);
#   ② **广播**(`NetBus.rpc(` / `NetBusExt.rpc(`)—— 只认 `all_peers_sendable()`:
#      广播在 ENet 层是**逐 peer** 发包,表里只要还剩一个处于"队列已拆"窗口的 peer 就会报错,
#      **单个 peer 判活不够用**(2026-09-21 定位:`_broadcast_snapshot` 每帧一发,
#      每拒绝一次错的 reclaim 就报一对 channel 0 / channel 1 —— 见 `match_snapshot.gd` 的注释)。
#
# ═══ 判据是「包围它的那一层」,不是"整文件出现过" ═══
# 这是本探针最容易写成假绿的地方,所以算法写死成两条(**都在**同一个函数体内、且**都在**站点
# **之前**):
#   · 块头判据:`if`/`elif` 的条件里含判据词,而**它的块体里就包着这个站点**;或
#   · 早退判据:同款条件的块体里有 `return` / `continue` / `break`(站点在它**之后**)。
# 两条都要求 `块头缩进 ≤ 站点缩进` —— **缩进更深**的 `if`(例如
# `if a:` 里套的 `if not is_peer_live(p): return`)**不算**,因为只有 `a` 成立时才早退,
# 而站点在两条路之外 ⇒ 那种写法照旧报红。
# ★ 这一条挡的正是 brief 点名的坑:整文件 `contains("is_peer_live")` 会让
#   "判据写在**别的分支**上"的实现照旧全绿。
#
# ═══ 盲区自检(不写就是"扫描器瞎了也全绿")═══
#   · `MIN_SITES`:站点总数下限(改名 / 改写法让扫描器**认不出**发送点时必须报红);
#   · `MUST_HAVE`:必须**至少各贡献一处**发送点的文件(逐文件下限,同款理由);
#   · 例外表里的条目**必须命中**:陈旧例外(写法变了、站点没了)一律报红 —— 否则"加一条例外"
#     就等于把规则对那一处**永久关掉**,而没人会再回来看它。
#
# ═══ 例外表(空 = 今天没有一处需要例外)═══
# 现在**是空的**,这是有意的:审计(2026-09-21)下来 `server/` + `core/net/` 的每一处发送点
# 都能落在一条活判据里。将来真出现"结构上没法判活"的站点,加一条带**理由**的例外 ——
# 而不是把规则对全部站点放松。
const EXCEPTIONS := []

# 判据词(出现在 `if`/`elif` 条件里才算)
# ★ 两种写法都要认:`server/` 里一律是 `NetBus.is_peer_live(...)`,而 `core/net/net_bus.gd`
#   自己体内是裸的 `is_peer_live(...)`(它就是那个方法的家)—— 只认带前缀那种会把
#   `reply()` / `ping()` 里的**正确**实现判成裸站点(实测踩到)。
const GUARD_TOKENS := ["is_peer_live(", "is_peer_online(", "can_send_to_server(", "all_peers_sendable("]
# 广播**只认**这一条(单个 peer 判活不够,见文件头)
const BROADCAST_TOKEN := "all_peers_sendable("
# 走这个助手 = 已判活(它体内首行就是 `if not is_peer_live(id): return false`)
const REPLY_HELPER := "NetBus.reply("

const DIRS := ["res://server", "res://core/net"]
# ★ **扫描面的边界(照实登记)**:`scenes/` **不在**这里面。客户端那侧的同一类站点
#   (`lobby_page` / 三个对局场景 / `pvp_match_client` 的上行)2026-09-21 一并审计过、该补的
#   也补了(见 `.superpowers/sdd/tint-and-channel-report.md` 的审计表),但客户端站点的判据
#   形态是 `NetBus.can_send_to_server()`,而其中几处(claim / player_options / report_token)
#   是**事件驱动**的(`connected_to_server` 回调里发,那一刻连接必然可用)⇒ 把它们一起收进本
#   探针需要一张更长的例外表,而这轮没做。**别把"本探针全绿"读成"客户端那侧也有常驻守卫"**。
const MIN_SITES := 20
const MUST_HAVE := [
	"res://server/match/match_snapshot.gd",     # 60Hz 世界包广播 + 本人包定向
	"res://server/match/match_state.gd",        # `_rpc_all` 样板(广播的单一出口)
	"res://server/match/match_combat.gd",       # 交火时最密的一处定向发送
	"res://server/lobby/lobby_rooms.gd",        # 大厅:答复 caller + 逐成员状态广播
	"res://server/lobby/room_manager.gd",       # 转连前的会话令牌
	"res://server/server_main.gd",        # match_sync 应答
	"res://core/net/net_bus.gd",          # ping/pong + reply 收口
]


func probe_id() -> String:
	return "RPC-LIVE"


func _ready() -> void:
	var sites := _collect_sites()
	_check(sites.size() >= MIN_SITES,
			"扫描到的发送点只有 %d 处(下限 %d)—— 目录/写法变了、扫描器认不出发送点了?"
			% [sites.size(), MIN_SITES])
	for f in MUST_HAVE:
		_check(_count_in_file(sites, f) > 0,
				"%s 一处发送点都没扫到 —— 它里面明明有(扫描器瞎了 / 文件被改名)" % f)

	var used_exceptions := {}
	var bare: Array[String] = []
	for s in sites:
		var verdict := _verdict(s)
		if verdict == "":
			continue
		var ex := _exception_for(s)
		if ex.is_empty():
			bare.append(verdict)
		else:
			used_exceptions[ex] = true

	_check(bare.is_empty(), "★ %d 处发送点没有活判据(通道数 0 那条错误的唯一来源类):\n    %s"
			% [bare.size(), "\n    ".join(bare)])
	for ex in EXCEPTIONS:
		_check(used_exceptions.has(ex),
				"★ 例外表里这条**一处都没命中**(站点没了 / 写法变了)—— 陈旧例外等于把规则对那一处永久关掉: %s"
				% str(ex))

	print("[%s] 扫描面 %s;发送点 %d 处(定向 %d / 广播 %d),例外 %d 条(命中 %d)"
			% [probe_id(), str(DIRS), sites.size(), _count_kind(sites, "directed"),
			_count_kind(sites, "broadcast"), EXCEPTIONS.size(), used_exceptions.size()])
	_finish()


# ── 取发送点 ──
# 判据:剥注释后的代码行里出现 `rpc_id(` / `"rpc_id"`(定向;后者兜住 `callv("rpc_id", …)`)
# 或 `NetBus.rpc(` / `NetBusExt.rpc(` / `multiplayer.rpc(`(广播)。
# ★ 必须用**保留缩进**的视图(`code_view`):下面的包围判据全靠缩进定块。
func _collect_sites() -> Array:
	var sites: Array = []
	for path in _collect(DIRS):
		if not path.ends_with(".gd"):
			continue
		var lines := _lines_of(_read(path))
		var fn_start := -1
		for i in range(lines.size()):
			var ln: Dictionary = lines[i]
			var t: String = ln["text"]
			if t.begins_with("func ") or t.begins_with("static func "):
				fn_start = i
				continue
			var kind := ""
			if t.contains("rpc_id(") or t.contains("\"rpc_id\""):
				kind = "directed"
			elif t.contains("NetBus.rpc(") or t.contains("NetBusExt.rpc(") or t.contains("multiplayer.rpc("):
				kind = "broadcast"
			if kind != "":
				sites.append({"path": path, "line": int(ln["line"]), "text": t,
						"indent": int(ln["indent"]), "fn_start": fn_start, "kind": kind})
	return sites


# 每行 -> {text(去缩进), indent, line(文件里的真实行号)}。空行 / 纯注释行去掉。
# ★ 两件必须做的事:
#   · 用**原始文件行号**(不是"剥注释视图里的第几行")—— 报告里点名要看的是文件的行号;
#   · **续行折叠**(行尾 `\`):GDScript 的 `if` 条件可以跨行写,而判据词常落在**第二行**上
#     (实测:`if shooter_role != 0 and peer_by_role.has(shooter_role) \` / `and NetBus.is_peer_live(...)`)
#     —— 不折的话那处**正确**的判据会被判成裸站点(假红)。
func _lines_of(src: String) -> Array:
	var out: Array = []
	var pending := ""
	var pending_indent := 0
	var pending_line := 0
	var raw_lines := src.split("\n")
	for idx in range(raw_lines.size()):
		var raw := String(raw_lines[idx])
		var s := _strip_line_comment(raw)
		if s.strip_edges().is_empty():
			continue
		var indent := s.length() - s.lstrip(" \t").length()
		var text := s.strip_edges()
		if pending == "":
			pending_indent = indent
			pending_line = idx + 1
			pending = text
		else:
			pending += " " + text
		if pending.ends_with("\\"):
			pending = pending.substr(0, pending.length() - 1).strip_edges()   # 续行:接着攒
			continue
		out.append({"text": pending, "indent": pending_indent, "line": pending_line})
		pending = ""
	if pending != "":
		out.append({"text": pending, "indent": pending_indent, "line": pending_line})
	return out


# ── 判定一处站点 ──
# 返回 ""(有活判据)或一句人话(为什么它裸着)。
func _verdict(site: Dictionary) -> String:
	var t: String = site["text"]
	# Reply 助手:体内首行就判活(它本身就是"答复 caller"的收口)
	if t.contains(REPLY_HELPER):
		return ""
	var tokens: Array = [BROADCAST_TOKEN] if site["kind"] == "broadcast" else GUARD_TOKENS
	# 站点行自己就是判据(如 `if NetBus.is_peer_live(x): NetBus.rpc_id(...)` 单行写)
	if _mentions(t, tokens):
		return ""
	var path: String = site["path"]
	var lines := _lines_of(_read(path))
	var si := _index_of_line(lines, int(site["line"]))   # 站点在 lines 里的下标(按文件行号找)
	var fn_start: int = site["fn_start"]
	var si_indent: int = site["indent"]
	for j in range(maxi(fn_start, 0), si):
		var head: Dictionary = lines[j]
		var ht: String = head["text"]
		if int(head["indent"]) > si_indent:
			continue                       # 比站点更深的块头:它的条件不保证成立
		if not (ht.begins_with("if ") or ht.begins_with("elif ")):
			continue
		if not _mentions(ht, tokens):
			continue
		var body_end := j + 1
		while body_end < lines.size() and int(lines[body_end]["indent"]) > int(head["indent"]):
			body_end += 1
		# ① 块体里就包着这个站点 ⇒ 走这条路时判据成立
		if si > j and si < body_end:
			return ""
		# ② 早退型:块体里有 return / continue / break(站点在它之后)
		for k in range(j + 1, body_end):
			var bt: String = lines[k]["text"]
			if bt == "return" or bt.begins_with("return ") or bt == "continue" or bt == "break":
				return ""
	return "%s:%d  %s [%s]" % [path, int(site["line"]), t, site["kind"]]


func _mentions(line: String, tokens: Array) -> bool:
	for tk in tokens:
		if line.contains(tk):
			return true
	return false


func _index_of_line(lines: Array, line_no: int) -> int:
	for i in range(lines.size()):
		if int(lines[i]["line"]) == line_no:
			return i
	return -1


func _exception_for(site: Dictionary) -> Dictionary:
	for ex in EXCEPTIONS:
		if str(ex.get("file", "")) == str(site["path"]) and site["text"].contains(str(ex.get("marker", ""))):
			return ex
	return {}


func _count_in_file(sites: Array, path: String) -> int:
	var n := 0
	for s in sites:
		if str(s["path"]) == path:
			n += 1
	return n


func _count_kind(sites: Array, kind: String) -> int:
	var n := 0
	for s in sites:
		if str(s["kind"]) == kind:
			n += 1
	return n
