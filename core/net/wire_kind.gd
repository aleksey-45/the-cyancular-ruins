class_name WireKind
extends RefCounted

# 协议 v5 消息种类登记表 = 联机协议的**唯一真相源**:每条消息一行,kind 值、方向、通道、
# 接收侧信号全在这一行声明。wire.gd 的发送与派发、tests/smoke/net_wire_smoke.gd 的对账
# 都读这里;任何地方不得另抄通道号/可靠性(可靠性由通道唯一决定,见下)。
#
# 与 v4 的关系:RPC 字符串方法表(net_bus / net_bus_ext 两份、冻结、beam_fired 重名)废止;
# 死协议三条不迁 —— peer_info / match_options / peer_hues(发送端与消费端均已不存在,
# 2026-10-29 重构时逐条 grep 核实)。
#
# 通道纪律(通道数两端一致,connect 握手协商):
#   CH_SESSION=0  reliable —— 大厅/生命周期/回合状态等一切须**互相保序**的会话消息
#   CH_INPUT=1    reliable —— 输入上行专用道(与会话隔离,防输入突发把会话消息压队)
#   CH_STATE=2    unreliable(FLAG_UNSEQUENCED|FLAG_UNRELIABLE_FRAGMENT)—— 快照专用道,
#                 独占通道 ⇒ 不再与会话消息同道混发(v4 快照挤在 ch0)
#   CH_EVENT=3    reliable —— 战斗事件(bullet/beam/hit/kill/tile/sub/weapon)
# 规则:只有 CH_STATE 上的两条快照走 unreliable,其余一律 reliable ⇒ 可靠性无需逐条登记。
#
# 帧格式(wire.gd 组帧):[u8 PROTO=5][u8 kind][u16 seq(LE,仅诊断)][payload]。
# payload:binary 条目 = 手打包的 PackedByteArray 直通(NetCodec 三 kind);其余 = var_to_bytes(args)。

const PROTO := 5

const DIR_C2S := 1   # 客户端 → 服务器
const DIR_S2C := 2   # 服务器 → 客户端

const CH_SESSION := 0
const CH_INPUT := 1
const CH_STATE := 2
const CH_EVENT := 3
const CHANNELS := 4


# ── 客户端 → 服务器 ───────────────────────────────────────────────────────────
const CREATE_ROOM := 1        # 建房(1v1)
const JOIN_ROOM := 2          # 加入房间
const LIST_ROOMS := 3         # 拉取房间列表
const LOBBY_NAME := 4         # 连上大厅报昵称
const SEND_INPUT := 5         # 输入上行(30Hz;binary,CH_INPUT 专用道)
const CLAIM_ROLE := 6         # worker:报到角色 + 昵称
const MATCH_SYNC := 7         # worker:进场拉取(应答 = MATCH_SYNC_DATA)
const PING := 8               # 应用层测速(应答 = PONG)
const PLAYER_OPTIONS := 9     # worker:上报本端选项
const SUICIDE_REQUEST := 10   # 自杀请求
const ROYALE_CREATE := 11     # 大乱斗建房
const ROYALE_JOIN := 12       # 大乱斗加入
const ROYALE_LEAVE := 13      # 大乱斗离房
const ROYALE_LIST := 14       # 大乱斗列表(token = 回局凭据,私密房照列自己那间)
const ROYALE_START := 15      # 大乱斗房主开局
const AI_DUEL := 16           # 1v1 房主请求 AI 对战(实验)
const ROYALE_START_AI := 17   # 大乱斗房主请求 AI 补位开局(实验)
const TEAM_CREATE := 18       # 3v3 建房
const TEAM_JOIN := 19         # 3v3 加入
const TEAM_PICK := 20         # 3v3 选边(队伍不由服务器推导)
const TEAM_LEAVE := 21        # 3v3 离房
const TEAM_START := 22        # 3v3 房主开局
const TEAM_LIST := 23         # 3v3 列表(token 同上)
const ROOM_MAP := 24          # 房主上报本房地图(列表缩略图;定图的仍是 player_options.map)
const REPORT_TOKEN := 25      # worker:报到回局令牌
const RECLAIM_ROLE := 26      # worker:宽限期内重新认领 role
const REJOIN_REQUEST := 27    # 大厅:回大厅后回局
const PVP_START := 28         # 1v1 房主点「开始游戏」(2026-10-24 起不再两人凑齐自动开)

# ── 服务器 → 客户端 ───────────────────────────────────────────────────────────
const SNAPSHOT_WORLD := 32    # 世界包(binary;CH_STATE)
const SNAPSHOT_OWN := 33      # 本人包(binary;CH_STATE)
const BULLET_SPAWN := 34      # 子弹视觉副本
const BEAM_FIRED := 35        # 即时光束(激光)整条折线;v4 双份重名合一,只有这一条
const MATCH_SYNC_DATA := 36   # MATCH_SYNC 的应答(一次性完整进场载荷)
const HIT_EVENT := 37         # 受击(白闪/击退;血量以快照为权威)
const TILE_DESTROYED := 38    # 拆砖(格)
const ROUND_STATE := 39       # 回合状态机迁移
const WEAPON_SPAWNED := 40    # 地面武器多了一件
const WEAPON_REMOVED := 41    # 地面武器少了一件
const KILL_EVENT := 42        # 击杀播报
const ROOM_CREATED := 43      # 1v1 建房回执
const ROOM_JOINED := 44       # 加入回执(分到的 role)
const ROOM_LIST := 45         # 房间列表
const MATCH_START := 46       # 建局(role/spawn/map;重连路径复用同一条)
const GO_MATCH := 47          # 大厅配对完:去连 worker(role/port)
const SERVER_MESSAGE := 48    # 通用提示(踢人/失败原因/连接失败与断开也经它)
const PONG := 49              # PING 应答
const OPPONENT_LEFT := 50     # 对局中途对手断线(1v1 收场)
const HIT_CONFIRM := 51       # 射手命中确认(只发射手本人)
const SUB_DESTROYED := 52     # 拆砖(16px 子格,Beta 玩法)
const TIME_STATE := 53        # Beta 时间经济态
const ROYALE_ROOMS := 54      # 大乱斗列表
const ROYALE_ROOM_STATE := 55 # 大乱斗等待室实时状态
const PVP_ROOM_STATE := 56    # 1v1 等待室实时状态(须排在 ROOM_CREATED/JOINED 之后)
const TEAM_ROOMS := 57        # 3v3 列表
const TEAM_ROOM_STATE := 58   # 3v3 等待室/选边实时状态
const SESSION_TOKEN := 59     # 回局令牌(必须早于 GO_MATCH 到达)
const REJOIN_DENIED := 60     # 回局被拒(失败路径必须显式告知,客户端才不会干等 GO_MATCH)


# ── 登记表本体 ────────────────────────────────────────────────────────────────
# 每条:dir(方向)/ ch(通道)/ sig(接收侧信号名;空串 = wire.gd 内联处理,不外发信号)。
# c→s 信号一律以 caller(peer id)为首参;s→c 信号参数与载荷字段一一对应。
const TABLE := {
	CREATE_ROOM: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "room_create_requested"},
	JOIN_ROOM: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "room_join_requested"},
	LIST_ROOMS: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "room_list_requested"},
	LOBBY_NAME: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "lobby_name_set"},
	SEND_INPUT: {"dir": DIR_C2S, "ch": CH_INPUT, "sig": "input_received", "bin": "input"},
	CLAIM_ROLE: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "role_claimed"},
	MATCH_SYNC: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "match_sync_received"},
	PING: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": ""},
	PLAYER_OPTIONS: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "player_options_received"},
	SUICIDE_REQUEST: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "suicide_requested"},
	ROYALE_CREATE: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "royale_create_requested"},
	ROYALE_JOIN: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "royale_join_requested"},
	ROYALE_LEAVE: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "royale_leave_requested"},
	ROYALE_LIST: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "royale_list_requested"},
	ROYALE_START: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "royale_start_requested"},
	AI_DUEL: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "ai_duel_requested"},
	ROYALE_START_AI: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "royale_start_ai_requested"},
	TEAM_CREATE: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "team_create_requested"},
	TEAM_JOIN: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "team_join_requested"},
	TEAM_PICK: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "team_pick_requested"},
	TEAM_LEAVE: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "team_leave_requested"},
	TEAM_START: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "team_start_requested"},
	TEAM_LIST: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "team_list_requested"},
	ROOM_MAP: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "room_map_requested"},
	REPORT_TOKEN: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "token_reported"},
	RECLAIM_ROLE: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "reclaim_requested"},
	REJOIN_REQUEST: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "rejoin_requested"},
	PVP_START: {"dir": DIR_C2S, "ch": CH_SESSION, "sig": "pvp_start_requested"},

	SNAPSHOT_WORLD: {"dir": DIR_S2C, "ch": CH_STATE, "sig": "local_snapshot_world", "bin": "world"},
	SNAPSHOT_OWN: {"dir": DIR_S2C, "ch": CH_STATE, "sig": "local_snapshot_own", "bin": "own"},
	BULLET_SPAWN: {"dir": DIR_S2C, "ch": CH_EVENT, "sig": "local_bullet_spawn"},
	BEAM_FIRED: {"dir": DIR_S2C, "ch": CH_EVENT, "sig": "local_beam_fired"},
	MATCH_SYNC_DATA: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_match_sync"},
	HIT_EVENT: {"dir": DIR_S2C, "ch": CH_EVENT, "sig": "local_hit_event"},
	TILE_DESTROYED: {"dir": DIR_S2C, "ch": CH_EVENT, "sig": "local_tile_destroyed"},
	ROUND_STATE: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_round_state"},
	WEAPON_SPAWNED: {"dir": DIR_S2C, "ch": CH_EVENT, "sig": "local_weapon_spawned"},
	WEAPON_REMOVED: {"dir": DIR_S2C, "ch": CH_EVENT, "sig": "local_weapon_removed"},
	KILL_EVENT: {"dir": DIR_S2C, "ch": CH_EVENT, "sig": "local_kill_event"},
	ROOM_CREATED: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_room_created"},
	ROOM_JOINED: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_room_joined"},
	ROOM_LIST: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_room_list"},
	MATCH_START: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_match_start"},
	GO_MATCH: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_go_match"},
	SERVER_MESSAGE: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_server_message"},
	PONG: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": ""},
	OPPONENT_LEFT: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_opponent_left"},
	HIT_CONFIRM: {"dir": DIR_S2C, "ch": CH_EVENT, "sig": "local_hit_confirm"},
	SUB_DESTROYED: {"dir": DIR_S2C, "ch": CH_EVENT, "sig": "local_sub_destroyed"},
	TIME_STATE: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_time_state"},
	ROYALE_ROOMS: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_royale_rooms"},
	ROYALE_ROOM_STATE: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_royale_room_state"},
	PVP_ROOM_STATE: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_pvp_room_state"},
	TEAM_ROOMS: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_team_rooms"},
	TEAM_ROOM_STATE: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_team_room_state"},
	SESSION_TOKEN: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_session_token"},
	REJOIN_DENIED: {"dir": DIR_S2C, "ch": CH_SESSION, "sig": "local_rejoin_denied"},
}
