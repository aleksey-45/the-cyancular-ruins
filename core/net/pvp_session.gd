class_name PvpSession
extends RefCounted

# 会话配置(菜单→匹配→对局 间传递)。静态 RefCounted,非 autoload(遵循项目惯例)。
#
# ★ 本类只放**真的有人读**的字段。2026-09-14 删掉了 4 个"只写不读"的字段
#   (`port` / `room_code` / `royale` / `disabled_weapons`)——它们制造了一个假象:
#   读的人以为找到了权威入口,而那个入口根本没人在用。各自的真权威见下方注释。
#   规则:**加字段前先 grep 确认有读者**;只写不读的字段一律不要加。
#   (这 4 个都是"上游写了、下游其实从别处拿"的残留,与 match_sync 落地前的交接层同源。)

static var server_address: String = "120.53.107.140"   # 默认服务器(云)
static var role: int = 1          # 1=P1(大乱斗里是第 N 人)。真读者多:出生点/副本/输入上报
static var player_name: String = "Anon"   # 匹配界面输入的昵称(默认 Anon;头上显示;会话内不清)
static var map_path: String = ""       # 服务器定图:worker 在 match_start 里下发,对局场景加载同名文件
static var spawn: Vector2i = Vector2i(-1, -1)   # 本端出生点(match_sync 下发,与服务器同源)

# ── 断线重连(2026-09-17)──
# ★ 与本文件的其他字段一样:**加之前先 grep 确认有读者**。
#   token      : 大厅生成、随 session_token 下发;claim 时报给 worker;重连时用来 reclaim
#   worker_port: 客户端重连要直连**同一个端口**,不重新走大厅(局内自动重连那条路径)
static var token: String = ""
static var worker_port: int = 0

# ── 「回大厅后回局」(路径乙)的两个字段(2026-09-21,阶段 2-B)──
# ★ 与上面两条同款纪律:**加字段前先 grep 确认有读者**。两个都有:
#   room_code : ① 回局请求要带上它(大厅按它**交叉核对**凭据;主键仍是 token);
#               ② **行可点性的那一半判据**(`can_rejoin_to` 拿它比"这一行是不是我的房")。
#               ★ 它当年被删过一次(只写不读)—— 现在有读者了才回来。
#   rejoin    : 一次性开关:下一次 `go_match` 是**回局**(认领 role 走 `reclaim_role`,
#               而不是 `claim_role`)。置位点是 `LobbyPage.try_rejoin_row()`(列表里点自己那间房)。
# ★★ **原稿里的第三个字段 `mode` 已删除**:它的唯一用途是"那颗按钮要把玩家送回哪个大厅页"
#   的路由(`main_menu._rejoin_scene_path()`),而**用户裁定取消那颗按钮** —— 玩家自己在
#   对应的那页找房间 ⇒ 没有读者。本仓纪律:没读者的字段不立(它自己就是我们当年删掉
#   `room_code` 的理由)。★ 别再"顺手把它加回来留念":那会让 `reconnect_smoke` 的反向断言红。
static var room_code: String = ""
static var rejoin: bool = false


# 手里还攥着**某一局**的凭据吗?(粗判据:三个字段齐。)
static func can_rejoin() -> bool:
	return token != "" and worker_port > 0 and room_code != ""


# 「**这一行**是不是我的房、而且我还能回去?」—— 房间列表每一行渲染时与行被按下时**共用**
# 这**一个**判据(两处各写一遍是漂的成因:漏一处就是"看着可点、点了没用"或反过来)。
# ★ 为什么必须带上房号:光判 `can_rejoin()` 会让**别人那间对局中的房**也可点 —— 点下去发出的是
#   回局请求,而凭据里的房号对不上,玩家看到的是"回局被拒"(一句与眼前那间房无关的话)。
static func can_rejoin_to(code: String) -> bool:
	return can_rejoin() and room_code == code


# 清掉回局凭据(大厅答"回不去了" / 回局超时时调)。
# ★ 与 `reset()` **分开**:`reset()` 会把 `server_address` 也拨回云默认 —— 在人家的自建服上
#   调它等于把玩家踢到另外一台机器去。
static func clear_rejoin() -> void:
	token = ""
	worker_port = 0
	room_code = ""
	rejoin = false

# ── 「本局禁了哪些枪」的权威在哪(2026-09-14 加,别再四处找)──
#   · 联机对局:**服务器 MatchHost**。客户端侧的真生效点是
#     `player.weapons.set_enabled_slots(disabled)` —— 在 `pvp_client._apply_match_options` /
#     `royale_game._apply_match_options` 里,紧跟载荷解析那一行。载荷来自 match_sync 的 options
#     (服务器按 role1 的 player_options 生效)。
#   · 单机:**`RunOptions.disabled_weapons`**(菜单写入,`level_0.gd:94` 读)。
#   · `Settings.pvp_disabled_weapons` / `Settings.sp_disabled_weapons` 是**本机持久化的选择**,
#     不是权威 —— 它们只是下次开面板时的回显默认值。
#   原先还有一个 `PvpSession.disabled_weapons` 静态镜像,已删(只写不读,且让人误以为它是权威)。

# ── 「是不是大乱斗局」的判据 ──
#   靠**从哪个场景进来**(`royale_lobby` → `royale_game`),没有静态标记。
#   原先的 `PvpSession.royale` 已删(两处赋 true、全仓无读)。

# ── 「开局三载荷的跨场景交接」已删除(2026-09-12)──
# 原先 worker 在 match_start 同一批 flush 里**推** peer_info/peer_hues/match_options,而客户端
# 那一刻正在帧末切场景 → 订阅方一个都不存在 → 静默丢失(自检 B2:对手颜色不生效 / 昵称表空到
# 连自己头顶 ID 都建不出来 / 禁武器闸门没上)。当时的解法是大厅先接住、缓存成本文件的
# pending_* 静态字段、新场景进场景时取用。
# 现在改成**进场拉取**(`NetBus.match_sync`):新场景建好、订阅齐了才开口要,时序不敏感。
# 于是缓存这一层连同 pending_* 一并删除 —— 只留一条投递路径,也就不存在"只改一条"的错法。
# 守卫:`tests/match_sync_probe` 的反向断言,全仓不得再出现这些标识符。

static func reset() -> void:
	server_address = "120.53.107.140"
	role = 1
	map_path = ""
	spawn = Vector2i(-1, -1)
	token = ""
	worker_port = 0
	room_code = ""
	rejoin = false
