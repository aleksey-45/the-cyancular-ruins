class_name GraceWindow
extends RefCounted

# 掉线宽限期表(纯逻辑、无 autoload、`-s` 可测)。
#
# 语义:某 role 掉线后 `enter`;宽限内它可以被 `reclaim_role` 重连;`expired` 报出到期仍未
# 回来的 role,由调用方走既有的"移出对局"语义。`leave` 是"这件事结束了"的完成信号
# (重连成功 / 主动移出 / 服务端收场,三处都调)。
#
# - **时间由调用方传入(ms),本类不读时钟** —— 否则冒烟只能靠 sleep。
# - 到期判据是 `now >= until`(**含边界**):取 > 会让"正好到点"永不算到期,
#   而时长取 0 时那条分支永不触发(同 CombatFeedback.ATTRIB_WINDOW_MS 的注释)。
# - 重复 enter 是**刷新**到期时刻,不叠加 —— 掉线两次不该得到两倍宽限。

# - 宽限期时长的唯一入口(改时长只改这里)。
# 注意： 2026-09-21:30 → **60**(设计约定:1v1 / 3v3 / 大乱斗三个模式统一,不再分档)。
#   改这一个数会同时动**两处**,改之前两处一起看:
#     ① `scenes/pvp_match_client.gd` 的重连重试预算(`_on_reconnect_retry_tick` 的第一条判据)
#        读的就是本常量 —— 单一来源,不会漂;60s 下 `RECONNECT_RETRY_MS`(2s)与
#        `RECONNECT_ATTEMPT_TIMEOUT_MS`(5s)不变,一次闪断里的重试次数由 ~15 变 ~30,
#        是"更从容"而不是行为变化。
#     ② **测试预算**:凡按"宽限期多久"算出来的窗口都要重算 —— `tests/probe/reconnect_probe.gd`
#        的 `GRACE_MIN/MAX` 与 `FINAL_TIMEOUT`、`tests/harness/team_match_watcher.gd` 的 `OBSERVE_MAX`、
#        `tests/probe/team_match_probe.gd` 的 `RESULT_WAIT`(它的头部注释要求**逐项求和**算,别凭印象)。
#        这三处是 Task 2。
# - 端口归还延迟(`WorkerLauncher` 的三个 `*_PORT_REUSE_DELAY`)**不再与本值绑定**:
#   核心关键点是"worker 进程活着  ->  房与它占的端口都还在"(房活到 worker 退出,见
#   `RoomManager._reclaim_finished_matches`)。守卫只留一条 belt 形式的宽松下界
#   (`tests/smoke/grace_window_smoke` ⑧),口径写在那一处。
const DEFAULT_SECONDS := 60.0

# ── 宽限期**到点之后**该做什么:纯分派(无 autoload、无副作用、可 `-s` 测)──
# 三个模式的答案就在这里,由 tests/smoke/grace_window_smoke 逐个钉住;调用方只做一次比较,
# **不得**再抄一遍 if/else —— 那种写法出过一次真事故:原先 server_main 只有"大乱斗 / 其余"
# 两支,`else` 把 1v1 **和 3v3** 一起吞了,于是 3v3 里第一个宽限到期的人会带着整局退进程
# (设计约定是"该队少人继续打"),而它当时不可达只因大厅还没有起 team worker 的入口。
const ACTION_REMOVE := 0     # 移出对局(身体销毁),其余人继续打 —— 大乱斗 / 3v3
const ACTION_TEARDOWN := 1   # 收场退进程 —— 1v1(对手走了就没人可打)


# is_royale / is_team 直接来自 worker 的模式开关。两者任一为真都走"移出对局":
# 大乱斗的自由混战与 3v3 的团队对抗都是"少一个人照样打得下去";1v1 少一个人就不成局。
static func expire_action(is_royale: bool, is_team: bool) -> int:
	return ACTION_REMOVE if (is_royale or is_team) else ACTION_TEARDOWN

var _until: Dictionary = {}     # role(int) -> 到期时刻 ms


# 进入宽限。seconds 默认走常量;重复调用刷新到期时刻。
func enter(role: int, now_ms: int, seconds: float = DEFAULT_SECONDS) -> void:
	_until[int(role)] = now_ms + int(seconds * 1000.0)


func has(role: int) -> bool:
	return _until.has(int(role))


# "这件事结束了":重连成功 / 主动移出 / 收场,三处都调它。
func leave(role: int) -> void:
	_until.erase(int(role))


# 已到期的 role,**按 role 升序**(字典迭代顺序不保证,排序是为了确定性)。
# 调用方拿到后应自行 `leave()` —— 本类不改调用方的对局状态。
func expired(now_ms: int) -> Array[int]:
	var out: Array[int] = []
	for r in _until:
		if now_ms >= int(_until[r]):
			out.append(int(r))
	out.sort()
	return out


# ── 阶段 3(2026-09-28):宽限期读数 —— 服务端下发 + 客户端本地倒计时更新 ──
# 三个助手都是**纯函数**(不读时钟、不碰节点、不引 autoload):`-s` 冒烟直接钉
# (tests/smoke/grace_window_smoke 的 ⑩⑪⑫)。

# 服务端:当前各 role 还剩多少秒。`{role(int) -> 剩余秒(float)}`。
# - 已到期的 role **仍在表里**(`expired()` 不改表,由调用方自行 `leave`)—— 这里照样报 **0.0**,
#   而不是把它省略:省略会让"刚好到点、还没被 leave"那一秒里客户端闪回「无掉线」。
# - 按 role 升序插入:字典迭代顺序虽然稳定,但本表要进网络载荷、也要被探针逐字比对,
#   排序让两端与日志可比(同 `expired()` 的理由)。
func remaining(now_ms: int) -> Dictionary:
	var roles: Array[int] = []
	for r in _until:
		roles.append(int(r))
	roles.sort()
	var out := {}
	for r in roles:
		var left_ms := int(_until[r]) - now_ms
		out[r] = 0.0 if left_ms <= 0 else float(left_ms) / 1000.0
	return out


# 服务端:把读数并进一个载荷 —— **非空才带键**(与 `destroyed` / `teams` / `stats` 相同设计约束规范:
# 没人掉线时一个字节都不多占,旧客户端忽略未知键)。
# - 收成静态纯函数而不是散在三个 `_broadcast_round_state` 里:三个生产者各写一遍必然漂,
#   而"空表也带上 `grace: {}`"这种漂法**不报错**,只是每局白背一个键。
# - **就地**改 `data`(调用方刚拼好的那份载荷),不返回新字典 —— 免得有人忘了接返回值。
static func merge_into(data: Dictionary, remaining_map: Dictionary) -> void:
	if not remaining_map.is_empty():
		data["grace"] = remaining_map


# 客户端:本地倒计时更新(服务器只在**状态转折**时广播 `grace`,两次之间由 HUD 自己减)。
# - 与 `ui/pvp_hud.gd` 的倒计时相同判定标准("服务器只在状态切换时广播一次 round_state")。
# - 钳到 0:不钳的话它会减成负数,而 HUD 上的 `ceil(-3.2) = -3` 会被念成「剩余 -3s」。
# - 键**原样保留**(不重建键!)—— GDScript 的字典按类型寻键,`1.0` 与 `1` 是两个键
#   (见 `weapon_inventory.gd` 那条同源注释),写成 `out[float(r)]` 会让下游 `.has(role)` 静默不命中。
static func tick_display(display: Dictionary, delta: float) -> Dictionary:
	var out := {}
	for r in display.keys():
		out[r] = maxf(0.0, float(display[r]) - delta)
	return out


func size() -> int:
	return _until.size()
