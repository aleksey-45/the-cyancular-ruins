class_name PvpSession
extends RefCounted

# 会话配置(菜单→匹配→对局 间传递)。静态 RefCounted,非 autoload(遵循项目惯例)。
#
# - 本类只放**真的有人读**的字段。2026-09-14 删掉了 4 个"只写不读"的字段
#   (`port` / `room_code` / `royale` / `disabled_weapons`)——它们制造了一个假象:
#   读的人以为找到了权威入口,而那个入口根本没人在用。各自的真权威见下方注释。
#   规则:**加字段前先 grep 确认有读者**;只写不读的字段一律不要加。
#   (这 4 个都是"上游写了、下游其实从别处拿"的残留,与 match_sync 落地前的交接层同源。)

const DEFAULT_PORT := 7777
static var server_address: String = "127.0.0.1"   # 本地回环(EasyTier 隧道及本地服务端)
static var server_port: int = DEFAULT_PORT
static var role: int = 1          # 1=P1(大乱斗里是第 N 人)。真读者多:出生点/副本/输入上报
static var player_name: String = "Anon"   # 匹配界面输入的昵称(默认 Anon;头上显示;会话内不清)
static var map_path: String = ""       # 服务器定图:worker 在 match_start 里下发,对局场景加载同名文件
static var spawn: Vector2i = Vector2i(-1, -1)   # 本端出生点(match_sync 下发,与服务器同源)

# ── 断线重连(2026-09-17)──
# - 与本文件的其他字段一样:**加之前先 grep 确认有读者**。
#   token      : 大厅生成、随 session_token 下发;claim 时报给 worker;重连时用来 reclaim
#   worker_port: 客户端重连要直连**同一个端口**,不重新走大厅(局内自动重连那条路径)
static var token: String = ""
static var worker_port: int = 0

# ── 「回大厅后回局」(路径乙)的两个字段(2026-09-21,阶段 2-B)──
# - 与上面两条相同设计约束规范:**加字段前先 grep 确认有读者**。两个都有:
#   room_code : ① 回局请求要带上它(大厅按它**交叉核对**凭据;主键仍是 token);
#               ② **行可点性的那一半判据**(`can_rejoin_to` 拿它比"这一行是不是我的房")。
#               - 它当年被删过一次(只写不读)—— 现在有读者了才回来。
#   rejoin    : 一次性开关:下一次 `go_match` 是**回局**(认领 role 走 `reclaim_role`,
#               而不是 `claim_role`)。置位点是 `LobbyPage.try_rejoin_row()`(列表里点自己那间房)。
static var room_code: String = ""
static var rejoin: bool = false

# 时间玩法(Beta,2026-09-28 P2):本局是否从主菜单「Beta」页进来。语义上有两重:
# ①大厅侧——beta 房与普通房**互不可进**(创建带 beta 标,加入按本标校验,列表按本标过滤);
# ②对局侧——worker/宿主据此启用时间玩法(TimeRules,见 PvP 时间玩法计划)。
# - 放 reset() 里复位:主菜单那颗联机入口走 reset(),天然把它清掉。
static var beta_mode := false

const MODE_PVP := "pvp"
const MODE_ROYALE := "royale"
const MODE_TEAM := "team"

# 凭据**属于哪个模式**。-  它取代了原先的 `mode` + `enter_mode()`:那套的写入点是
# 主菜单的联机入口,而合一后凭据的归属改由"记房号"那一拍确定
# (`note_room(code, mode)`)。三张注册表的房号空间共用这个前提一个字没变  ->  判据必须留着。
static var room_mode: String = ""

# 进大厅时预选的**筛选**模式(Beta 页写、统一大厅读)。空串 = 不预选(从主菜单直接进来)。
# 注意： 它**不是** `room_mode` —— 那个是**凭据**的模式,`can_rejoin_to()` 拿它判"这一行是
#   不是我的房"。两个量语义不同,别合并。
static var entry_mode: String = ""


# 手里还攥着**某一局**的凭据吗?(粗判据:三个字段齐。)
static func can_rejoin() -> bool:
	return token != "" and worker_port > 0 and room_code != ""


# 「**这一行**是不是我的房、而且我还能回去?」—— 房间列表每一行渲染时与行被按下时**共用**
# 这**一个**判据(两处各写一遍是漂的成因:漏一处就是"看着可点、点了没用"或反过来)。
# - 为什么必须带房号:光判 `can_rejoin()` 会让**别人那间对局中的房**也可点。
# - 为什么必须带**模式**:三张注册表的房号空间共用(见 `room_mode` 上方那段),只看房号会让
#   同号的另一模式的房看起来像我的。
static func can_rejoin_to(code: String, mode: String) -> bool:
	return can_rejoin() and room_code == code and room_mode == mode


# 清掉回局凭据(大厅答"回不去了" / 回局超时 / **换模式**时调)。
# - 与 `reset()` **分开**:`reset()` 会把 `server_address` 也拨回云默认 —— 在人家的自建服上
#   调它等于把玩家踢到另外一台机器去。
# 注意： **凭据真正死掉的地方就是本函数的调用点**(2026-09-22 定案,C1 之后)。全部三处:
#   ① `note_room()` —— 换了**房号或模式**(房号空间三种模式共用,不清就会串模式,见 `room_mode` 那段);
#   ② `LobbyPage._on_rejoin_denied()` —— 大厅答"回不去了"(凭据失效 / 房号不符 / 对局已结束);
#   ③ `LobbyPage._tick_rejoin_timeout()` —— 大厅 15s 没应答(它已经不可用了)。
#   - **不在这里的**:回主菜单、以及"同模式"再进大厅页 —— 那两步**刻意**保留凭据。
#     曾经的 `reset()` 会在那里把四个字段一起清,于是"回到大厅后自己那间房是灰的、
#     回不去"(整条路径乙在生产里不可达)。**别再往 `reset()` 里加回那四行。**
static func clear_rejoin() -> void:
	token = ""
	worker_port = 0
	room_code = ""
	rejoin = false


# 「我现在进的是**这一间**房」—— 三页记房号的**唯一**入口(`_on_room_created` / `_on_room_joined` /
# `_on_room_state` 都调它;别的地方不要再写 `PvpSession.room_code = …`)。
# - 换了**房号或模式**  ->  上一间的凭据到此为止:此刻手里那份 token/worker_port 属于**上一局**,
#   而"这一间"还没开局(token 由大厅在开局前才发) ->  留着它只会让**上一局的**(甚至同号的
#   别人的、或**同号的另一模式的**)房看起来像"我的房"(点下去必然收到一句与眼前这间房无关的拒绝)。
# - 房号**没变**时不清:大乱斗/3v3 的等待室每收到一次房间状态就会走一遍本函数,而
#   "同一间房的状态刷新"不该把刚拿到的凭据抹掉(那会把路径乙在本局开局后弄坏)。
#   - 副作用(已知、可接受):若"上一局那间房"与"这一间"**恰好同号**,本函数判不出区别 ——
#     那种情况下凭据会留到玩家点那一行时被大厅按"凭据失效"拒掉,一次点击后自愈
#     (`_on_rejoin_denied` → `clear_rejoin`)。概率极低且只多一次点击。
static func note_room(code: String, mode: String) -> void:
	if code != room_code or mode != room_mode:
		clear_rejoin()
	room_code = code
	room_mode = mode

# ── 「本局禁了哪些枪」的权威在哪(2026-09-14 加,别再四处找)──
#   - 联机对局:**服务器 MatchHost**。客户端侧的真生效点是
#     `player.weapons.set_enabled_types(disabled)` —— 在 `pvp_client._apply_match_options` /
#     `royale_game._apply_match_options` 里,紧跟载荷解析那一行。载荷来自 match_sync 的 options
#     (服务器按 role1 的 player_options 生效)。
#   - 单机:**`RunOptions.disabled_weapons`**(菜单写入,`level_0.gd:94` 读)。
#   - `Settings.pvp_disabled_weapons` / `Settings.sp_disabled_weapons` 是**本机持久化的选择**,
#     不是权威 —— 它们只是下次开面板时的回显默认值。
#   原先还有一个 `PvpSession.disabled_weapons` 静态镜像,已删(只写不读,且让人误以为它是权威)。

# ── 「是不是大乱斗局」的判据 ──
#   靠**从哪个场景/哪个模式进来**(统一大厅 `mp_lobby` → `royale_game`),没有静态标记。
#   原先的 `PvpSession.royale` 已删(两处赋 true、全仓无读)。

# ── 「开局三载荷的跨场景交接」已删除(2026-09-12)──
# 原先 worker 在 match_start 同一批 flush 里**推** peer_info/peer_hues/match_options,而客户端
# 那一刻正在帧末切场景 → 订阅方一个都不存在 → 静默丢失(自检 B2:对手颜色不生效 / 昵称表空到
# 连自己头顶 ID 都建不出来 / 禁用武器校验逻辑未生效)。当时的解法是大厅先接住、缓存成本文件的
# pending_* 静态字段、新场景进场景时取用。
# 现在改成**进场拉取**(`NetBus.match_sync`):新场景建好、订阅齐了才开口要,时序不敏感。
# 于是缓存这一层连同 pending_* 一并删除 —— 只留一条投递路径,也就不存在"只改一条"的错法。
# 守卫:`tests/probe/match_sync_probe` 的反向断言,全仓不得再出现这些标识符。

# 「进大厅页」的复位:**不碰回局凭据**(那四行 2026-09-22 已删 —— 见 `clear_rejoin` 上面那段)。
# 注意： 曾经它在末尾清 `token` / `worker_port` / `room_code` / `rejoin`,而主菜单那颗联机入口
#   每按一次就调它一次  ->  玩家从对局按 ESC 回主菜单、再从这个入口进来时,凭据**正好在那一拍**
#   被抹掉 → `can_rejoin_to()` 恒 false → 自己那间"对局中"的房在列表里恒为灰、点不动
#   (**整条路径乙在生产里不可达**,而真链路探针因为绕过了主菜单那一步,一直是绿的)。
#   - 凭据该在哪里死见 `clear_rejoin` 的三处清单;**别再把这四行加回来**。
# - 它仍然要清的:role/spawn/map_path(每次进页本来就该复位)。
# 注意： `server_address` **不再**在这里回云默认(2026-09-22 终审的 Important 项)。原先那行的
#   理由是"选择服务器是地址框属于地址输入步骤的逻辑,由 `_with_lobby` 重新赋"—— 它本身没错,**但它与
#   回局直接冲突**:回局要求"回到**同一台**服务器上的原局",而每按一次主菜单按钮就把地址
#   打回云默认  ->  自建服的玩家再进大厅页时,地址框是云的、**他那间房根本不在列表里**,
#   表现与他刚被修掉的那个 bug 一模一样。
#   - 更坏的是**真链路探针在结构上看不见这一条**:`rejoin_watcher` 恰恰因为**主菜单的
#     联机入口**会重置地址,才手动把它改回探针自己的 29300  ->  探针测试全部通过而自建服不可用。
#    ->  现在的语义是"大厅页记得你**这次会话**上一次用的服务器"。跨会话的持久化是另一件事
#     (`Settings` 里没有地址字段,未做)。-  别再把这行加回来,除非同时给回局换一条路。
static func reset() -> void:
	role = 1
	map_path = ""
	spawn = Vector2i(-1, -1)
	beta_mode = false   # 时间玩法(Beta)来源标记:只有主菜单 Beta 页进来才置真(见 beta_menu)
	entry_mode = ""     # 进大厅的**筛选**模式:每次进页预选复位(与**凭据**的 room_mode 无关)
