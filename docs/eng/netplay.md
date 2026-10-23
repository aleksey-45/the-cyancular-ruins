# 联机基础(大厅 / 匹配 / 房间 / 重连)

> ★ **2026-10-09 测试面削减 90%**:本文件里凡标着 `（已删·2026-10-09）` 的守卫**都已不存在**。
> 那一批删了什么、留了什么、代价是什么 —— 台账
> [`docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md`](../superpowers/specs/2026-10-09-test-surface-cut-90-design.md)。
> ★ 读法:**不要**因为路径还在句子里就以为守卫还在 —— 标了就是没有了。

> 从 [`CLAUDE.md`](../../CLAUDE.md) 拆出(2026-10-03,**原文逐字未改**)。返回索引:[`CLAUDE.md`](../../CLAUDE.md)。
> ★ **快照管线专题**(60Hz 全量编码、丢弃规则、输入队列的延迟累加、与 Gaffer/Valve 的对照、实测带宽账):[`netcode-snapshots.md`](netcode-snapshots.md)。
> 本文件覆盖:网络与 PvP(匹配进图 + 对局互通 + 回合制) · 匹配进图 · 阶段 3:可见性 + 击杀播报缺省 · 对局中的房:回合 / 中场研究 / 拾取与拒绝 · 回到大厅(阶段 2-B:凭据表 / 座位表 / 自建房间)。
> ★ 文档会过期 —— **任何冲突以源码为准**,读之前先 `grep` 复核。

### 网络与 PvP(匹配进图 + 对局互通 + 回合制)

- 服务器:`server/server_main.tscn` 入口(headless)。**双模式**:无参=大厅(默认 7777),`--worker --port P`=对局 worker。**一服多局**:大厅的**房间账本**在 `server/lobby/lobby_rooms.gd`(`LobbyRooms extends Node`:**做成 Node 是因为要用 `multiplayer` 与 `get_tree()`**),**进程编排与清扫**在 `server/lobby/room_manager.gd`(`RoomManager`:拉 worker、让玩家转连、每 10min 清扫超龄房)。两者**单向依赖**:`lobby` 不知道 RoomManager;1v1 凑齐两人由 `pairing_ready` **信号**上去(避免 back-reference)。
- 建房/配对(2 人就绪)→ 给每局拉起一个独立 worker 子进程(`OS.create_process`,同 exe `--headless --worker --port P`;开发=editor 带 `--path`+场景,导出 exe 靠 `main_scene.dedicated_server`)→ 发 `go_match(role,port)` 让两端转连。**worker 内跑 `server_main.gd`(worker 分支)**:独占 UDP 端口,等 `claim_role` 收齐 → `MatchBootstrap.start_on`(static:重算地图尺寸、发 `match_start`、建 `MatchHost`)→ 权威对局。各局=独立进程 → **内存隔离**,共享全局不跨局互踩。★ 端口分配用「唯一递增 + 占用集合」(`WorkerLauncher.pick_port`,基准 7800)**不要**在本进程 bind 探测空闲(worker 是独立进程,大厅探测看不到别的进程已占端口,并发会把同端口发给两个 worker)。
- **`MatchHost`(每房间一个)**:建世界(WorldBuilder 只碰撞不渲染)+ 两个 `scenes/player/player.tscn` 注入 `NetworkInputSource`;**每物理 tick 每 role 恰好消费 1 个 FIFO 输入包**(按 seq 序,1:1 同序 = C2 rollback 锚点;队列空=沿用上一包 held)并回带 `ack_seq`、60Hz 广播快照(带 `tick` + `ack_seq` + `c2` 权威整态)、裁决子弹命中并广播 `bullet_spawn`/`hit_event`。
  - ★ **爆炸弹(榴弹)不走玩家半径补刀销毁**(伤全靠落地引信 AoE;按普通弹半径补刀结算+销毁会吞掉引信致无爆炸;故 `explodes` 弹改走 `_adjudicate_grenade`:**只结算一次直接命中、不销毁**)。
  - ★ 即时光束权威开火经 `_broadcast_pending_beams()` 轮询 `collect_pending_beam_report()` → `beam_fired` 广播给**非射手端**。
  - ★ 开局 pin PvP 地图后要调 `GameParameters.refresh_map_size()` 重算世界尺寸(_ready 时算的是随机 demo 图,工厂图 9600 宽不同,不重算则环面回绕按错边界出现空气墙)。
- **回合制**:`_match_round_tick` 状态机 COUNTDOWN→PLAYING→ROUND_OVER→MATCH_OVER;**击杀定义:对方死亡都算**——每物理帧倒地转换检测(`is_downed` 边沿)不分死因一律给对方 +1(弃用旧的射手归因);局内死亡 2s 复活(`_respawn_player`:死者回本方出生点、满血/防水、武器回 1);**每次击杀后活着的胜方也立刻回本方出生点但保留当前血量**(`_reset_survivor`,防复活点连杀);每局先到 5 击杀赢、三局两胜、局间 `_side_swap` 换边。
  - **换局纪律**:进新局前 `_reset_world_and_clear_dynamics()` 把可破坏砖/碰撞整层还原为建局基线(`_base_grid` 深拷贝)+ 清光场上子弹(`bullet` 组)+ 重置 `_seen_bullets`;客户端收到新一轮 COUNTDOWN 同刻 `Level0.reset_destructibles()`(用 `_pristine_grid` 重铺)+ 清本地视觉子弹 → 两端每局从同一基线出发,无幽灵墙/跨局残留。
  - **COUNTDOWN 3 秒双端禁移动/开火**:服务器不喂输入(清空缓冲 + `NetworkInputSource.reset_state()` 连 held/axis 一起清,防上一包方向让冻结期漂移);客户端 `player.set_controls_locked` **连带冻结整个 input_source**(`InputSource.frozen`),锁住移动+开火。进 PLAYING 解锁。
- 客户端流程:`main_menu` → **`mp_lobby`**(统一大厅:建房/输房间号;配对完成收到 `go_match` 后**断开大厅、转连该局 worker 并 `claim_role`**)→ `pvp_game`。**本地玩家 = C2 客户端预测(rollback)**:玩家由引擎自步进读真实 Input(aim/手感=单机);`pvp_game` 每帧在玩家步进前 `note_post_step(prev_seq)` + `reconcile()`(见 `core/net/prediction_rollback.gd`),输入包带单调 `seq`,服务器每物理 tick FIFO 消费 1 包并回带 `ack_seq` + 权威整态 `capture_state()`;分歧 → `restore_state` 权威态 + 重放未确认输入。复盘见 `docs/pvp-c2-retrospective.md`。**★ 2026-09-12:旧的 `server_rendered` 保底一族与 `LOCAL_PREDICTION_ENABLED` 开关已整体删除** —— 全项目只剩这一条联机链路。守卫:`tests/probe/royale_c2_probe`（已删·2026-10-09） 的 A①「生产目录零残留」。
- 远端对手 = `PlayerReplica` 视觉副本(显示对手当前武器并按快照 `aim` 摆枪,经 `weapon_base.drive_remote_visual` 驱动,不开火不读鼠标)。★ 快照的 `weapon` 是**武器类型 id**、**`0` = 空手**(服务器侧把**最后一把**丢出去的那一刻是唯一成因):副本必须认这个 0 —— `apply_snapshot` 的守卫是 `if slot != _weapon_slot_int`,**别写成 `slot > 0 and …`**(写了的话对手丢光枪后我方视角里他**一直举着那把已经不存在的枪**)。守卫 `tests/probe/ground_client_probe`（已删·2026-10-09） ⑦。
  - ★ **它不是"纯视觉"**:副本还挂一个**幽灵碰撞体**(`StaticBody2D`,`collision_layer=2`/`mask=0`,5 份姿态 `CollisionPolygon2D` 从 `Player.tscn` 现抄;按快照 `pose` 切换,`downed` 时不切与服务器一致;副本入 `player_replica` 组供榴弹接触判定用)。**为什么必须有**:C2 只步进自己的玩家,客户端世界里没有对手身体 = "对手挡住我"这条信息在预测侧不存在 → 本地预测穿过去、服务器挡住 → 每帧分歧每帧回滚(**无限回滚循环,不是调参能缓解的**)。配套两端客户端 `_ready` 各补一行 `_local.collision_mask |= 2`(服务器侧 `match_host` 早就给每个玩家设了;**不能改 `scenes/player/player.tscn` 的场景常量**——`enemy_logic_smoke`（已删·2026-10-09） 有 `player mask == 5` 断言)。验收按"回滚次数下降多少"量:`replica_ghost_probe.tscn`（已删·2026-10-09） 给对照读数(在位 0 回滚/摘掉 277 回滚)。
  - ★ **对手的预瞄红线看不到**(用户裁定):heavy_aim 预瞄线**只有使用者本人可见**,`drive_remote_visual` 显式把副本武器的 `_aiming` 压回 false;服务端快照仍带 `previewing` 字段但客户端刻意不消费。回归钉在 `preview_visibility_probe.tscn`（已删·2026-10-09）(双向)。
  - ★★ **副本位置平滑**:走**自身差分指数追赶** —— 每帧把目标(`_opponent_canonical` 锚到本地玩家最近副本)与当前渲染位置**各锚进同一副本空间**,再按 `1 - exp(-INTERP_RATE·Δ)`(`INTERP_RATE = 12.0`)收敛;首次定位由 `_placed` **直落**。姿态/朝向/aim/倒地/武器仍按最新快照即时。★★ **两个 `anchor_to_nearest` 是承重的** —— 旧方案的致命缺陷:渲染位置与目标相隔整幅地图时最短向量=0,副本一旦落远就永远留在那 → 对手渲染到屏幕外「看不见」。★ 2026-09-22 用户裁定**从「双快照 tick 域 alpha 插值」改回本方案**(那条路在 60fps 渲染 + 60Hz 快照下画的就是最新包原值,到达抖动时会出现"零位移 + 单帧走 2~3 个包的距离" ⇒ 用户报「位置一跳一跳」)。快照插值模块(`snapshot_interp.gd`,原在 `core/net/`)与其冒烟已删除。守卫 `replica_smoothness_probe.tscn`（**2026-10-09 从历史取回并补相 D**：相 A 零位移占比/单帧最大位移、相 B 跨接缝不卡远副本、相 C 幽灵体解耦、**相 D 大跳变阈值两侧**）。★★ **2026-10-09 补一档**：误差 > `SNAP_DIST`（**128px**）时**不追赶、一帧直落** —— 回溯（2026-09-29 加）、大乱斗重生、换局换边都是**设计好的瞬移**，交给指数追赶会被演成弹射（300px 误差首帧就走 ≈54px ≈ 3200px/s，十倍移速）。阈值依据**全为本仓实测**：常态滞后 `v/k` = 25px，探针实测 **±0ms 22.6 / ±8ms 29.7 / ±16ms 37.2px** ⇒ 必须远高于 37px，否则常态抖动被硬跳；丢包误差 ≈ 5px/tick（200ms 才 60px）⇒ 那段仍该追赶；回溯/重生是几百~几千 px ⇒ 128px 两侧各留 ≈2× 余量。**判据是"锚进同一副本空间之后"的误差**（整幅地图的偏移已归一，不算大跳变）⇒ 相 B 那条守卫不受影响。
  - ★★ **2026-10-09：位置平滑改走 playout 缓冲插值**（取代上面那段"指数追赶"；该段其余内容——**两个 `anchor_to_nearest` 承重**、2026-09-22 那次裁定的**原因**、幽灵体解耦——**仍然有效**）。机制：客户端 `PlayoutClock`（**只在第一个包上初始化一次，之后再不重置**）+ 每个副本一份位置历史环（存 **canonical**），渲染时刻 = `latest − PLAYOUT_TICKS`（**4 tick ≈ 67ms**），在夹住它的两个样本之间**线性插值**；underrun / 太老都**冻结**（不外插、不倒退）；相邻样本差 > `SNAP_DIST` 就**清历史**（瞬移不许被插值横穿）。★ 当年那套 tick 域插值坏在**每包重置时钟 ⇒ 缓冲深度 0**（见 `playout_clock.gd` 文件头），不是机制错。★★ **实测未全胜**：±0/±8/±16 ms 滞后 **20.0 / 27.1 / 44.3 px**（旧追赶 22.6 / 29.7 / **37.2**）⇒ ±16ms 档更差，见 [`registered-debt.md`](registered-debt.md) §8.12；**手感未过人眼**。判据：`playout_clock_smoke`(3 条) + 探针相 D/E。
  - ★★ **幽灵体不跟着平滑走**:幽灵体跟的是**未经平滑的原始权威位置**,只有**渲染位置**才走指数追赶。幽灵体的唯一职责是让「预测所依据的世界」与权威世界一致,它要的是**最小陈旧**;而指数追赶是个低通滤波器 —— 目标以 300px/s 移动时它额外落后 `v / INTERP_RATE ≈ 25px`,那 25px 会直接变成「本地预测撞在一个位置不对的对手身上」。★ 这条还保证:**预测路径与「改回指数追赶」之前逐位相同**(探针实测:幽灵体距权威位置 **0.000 px**)。
  - ★ **接触期自适应容差**:贴身缠斗的每帧回滚由 `PredictionRollback._close_enough` 的**位置容差**决定,故分两档 —— 非接触期恒 `pos_tol`(2.0),**接触期**用 `contact_pos_tol`(`DEFAULT_CONTACT_POS_TOL` = **8.0**)。**接触判据**是 `Player.touching_player()`:扫本步滑动碰撞里有没有**非地形层**(`(co.collision_layer & ~1) != 0`)。★ **本地 mask 里并不只有地形**:场景常量是 **5** = 地形(1)+ **敌人层(4)**,PvP 客户端再补 `|= 2` 把对手幽灵体那层收进来 ⇒ 判据对**敌人层**的身体也会报"接触",今天无害**只因为 PvP 模式没有敌人**。★ **接线只有一处**(`pvp_match_client` 在 `note_post_step()`/`reconcile()` **之前**写 `_rollback.in_contact`);`in_contact` **不进 `capture_state()`、不上行**。★ **已实测:贴身回滚次数由容差决定、不由幽灵体精度决定**(摘除 75px / 准确 2px / 推歪 77px 都是 ~220 次)⇒ 放宽容差近似纯赚。守卫:`tests/probe/rollback_fidelity_probe.tscn`(★ 今天唯一还在的那一支)+ `replica_ghost_probe`（已删·2026-10-09） ⑤⑥ + `brawl_rollback_probe`（已删·2026-10-09） 的 CONTACT 族。★ **2026-09-23 用户裁定**:CONTACT 族的第三条判据「确实买到了东西」**只在已采纳的 `CONTACT8` 上打分**;16/32px 两档照旧打印读数、只是不判(读数**不删**是因为**探针是扫描仪器**)。
  - ★ **已知边界(登记不修)**:① 接触提示在玩家步进**之前**读,反映的是**上一个**物理步的碰撞,差一帧、无害;② 3v3 队友:本地 mask 里**没有队友身体那个层** ⇒ 队友永不判接触(与"队友不互挡"一致)。
- **PvP 客户端的 KH 加成(L6)**:对手头顶血条(`Settings.pvp_show_enemy_hp`)/小地图/子弹拖尾(`pvp_show_trajectories`)/击杀播报(`kill_event`)/命中 X 标记(`hit_confirm`)/对局生效选项(`match_sync` 的 `options` → `weapons.set_enabled_types`;权威是服务器 MatchHost)/对手身体色相(`peer_hues`,**只染身体、头顶名保持中性亮白 `NAME_COLOR`**)。
  - ★ **节点分工是故意不对称的,别"统一"**:`hit_confirm`/`match_options`/`peer_hues` 走 **`NetBusExt`**,而 **`beam_fired` 走 `NetBus`** —— 发送端 `MatchHost._broadcast_beam_fired` 用的是 `NetBus.rpc_id`,接收端也必须 `NetBus.local_beam_fired`;改到 `NetBusExt` 会**静默 no-op**(对手激光视觉消失且不报错)。`core/net/net_bus_ext.gd` 里的同名 `beam_fired` 是 KH 遗留重复。
  - ★ **开局载荷改为「客户端进场主动拉取」**:对局场景 `_ready` 末尾主动 `NetBus.rpc_id(1,"match_sync")` 拉一次,worker 的 `_on_match_sync` 按 role 回 `match_sync_data({names,hues,options,roles,spawns})`。方向反转 ⇒ 不再有"推给正在切场景的客户端"这个竞态类,出生点随之下发、两端同源。`PvpSession.pending_*` 与两个 `_consume_pending_payloads`、两个大厅的 `_cache_*` 都已删除。**不要照旧描述去加第二条投递路径**;守卫 `match_sync_probe.tscn`（已删·2026-10-09） 带反向断言:那些交接标识符一个都不许复活。
  - ★ **三条离开对局世界的路径全部走 `Level0.safe_change_scene`**(ESC/暂停菜单、MATCH_OVER、对手离开)。两条定时器在**起定时器前**捕获 `tree`/`netbus`,并在 `not is_inside_tree()` 时早退。`safe_change_scene` 自身带**防重入**(`_switching`)—— 它首行 `await` 一帧,两次调用可同时在飞,无守卫时第二次会把**刚建出来的新场景**当 old 摘掉。★ **`_retired`(退役挂起、永不释放)已整个删除**,改为摘树后**立刻分帧拆除**(`Level0.start_reap` + 挂在 root 的 `WorldReaper`,逆前序、按时间预算每帧拆一批)。★ 为什么必须删:挂起的那具世界**退出时从不释放** → SubViewport 的 RID 全泄漏 → 渲染器析构**段错误**(exit 139)、进程拖 ~1.5s 才死(用户报的"玩好一局后点退出要等 1s")。**只在导出 exe 上才复现** —— 这类"只在发布版现形"的问题,量的必须是发布产物。
- 协议(经 `NetBus` autoload RPC;对局权威=该局 **worker**,非 7777 大厅):握手——大厅→客户端 `go_match(role,port)`,客户端→worker `claim_role(role)`;输入包(60Hz reliable,`send_input`:轴/held/pressed/released 位掩码(**含 `BIT_RELOAD`=16 换弹位**;PvP 换弹开放后 R 的按下边沿必须上行)+切枪+瞄准方向)、快照包(60Hz unreliable,每玩家 pos/vel/facing/pose/weapon/hp/waterproof/downed/aim/previewing)、事件包(reliable,`bullet_spawn`/`beam_fired`/**`tile_destroyed`**(服务器拆墙广播,客户端 `TileDefs.damage_tile` 触发清瓦片渲染,否则建筑"看着没被炸坏")/`round_state`/`kill_event`)。**环面纪律**:协议只传 canonical 坐标、渲染各端归最近副本、插值走 `toroidal_delta_px` 最短路径。
  - ★ **定向发送前一律先判活:`NetBus.is_peer_live(id)`**(`_rpc_all` 的 `live_only` 默认已是 **true**)。判据是 **ENet peer 自己**的 state + **通道数**(`get_peer(id).get_state() == STATE_CONNECTED and .get_channels() > 0`,后者正是引擎 `ENetPacketPeer::send` 会检查的那个量);**别用 `multiplayer.get_peers()`** —— 它比 ENet 真实状态**晚**,挡不住"往 ENet 已拆掉、API 还没忘掉的 peer 发定向包" → `ERROR: Unable to send packet on channel 0, max channels: 0`。★ **广播前的判据是 `NetBus.all_peers_sendable()`**(表里**每一个** peer 都能收包;空表 = false),唯一调用点在 `server/match/match_snapshot.gd`(广播在 ENet 层是**逐 peer** 发包,表里只要还剩**一个**处于"队列已拆、API 还没忘掉"窗口的 peer 就会报)。★ **常驻守卫 `rpc_liveness_probe.tscn`（已删·2026-10-09）**(源码级):扫 `server/` + `core/net/` 的每一处发送点 —— 定向要求判据**包围着**它,广播只认 `all_peers_sendable()`;例外表是空的,且**陈旧例外会红**。★ **大厅侧"答复 caller"的发送一律走 `NetBus.reply(id, method, …)`**(`server/lobby/lobby_rooms.gd` + `room_manager.gd`):请求与断开常挤在**同一次 poll** 里 —— ENet 处理 DISCONNECT 命令时**当场**把通道数清零。★ **已知残留**:每踢一次连接约 1 条**引擎自己**的定向发送报错(**无 GDScript backtrace**,从 GDScript 够不着)⇒ **不修,照实登记**;别把它读成"功能坏了"。
  - **击退方向走 toroidal 最短向量**:命中源(服务器子弹/爆心)锚在射手副本、可能与该玩家 canonical 相差整幅地图,绝对相减会得出**反向击退**(跨接缝对枪被打向射手)——统一用 `toroidal_delta_px(source_pos, body)`(直击/爆炸/本地反馈同源)。
- 输入抽象:`InputSource` 基类(本地委托真实 Input;`frozen`=PvP 冻结时所有读口返回中性值)+ `NetworkInputSource`(消费输入包,服务器唯一消费方;`reset_state()` 连 held/axis 一起清)。★ `NetworkInputSource.get_axis` **垂直轴由 held 位推导、水平轴返回 `ax`**(输入包只传水平轴;曾一律返回水平轴致服务器挂梯不动)。`weapon_base` 攻击经 player 查询(has_method 守卫回退 Input);`BulletBase.apply_damage=false` = 客户端视觉副本(不裁决,伤害由服务器裁决)。
- PvP 固定地图 `maps/newfactory.cyrm`(150×100 **v4 二进制**,`# player 23 43` + `# player2 26 9`;两出生点环面相距 **34 格 ≈ 2176px**,超视野)+ 单机用的 `maps/demo.cyrm`。★ 早先文档里的 `factory_1V1(260827).cyrm` 是**历史别名**;而旧定图 `factory1v1` **已于 2026-10-02 退役删除**(用户裁定,文件已不在 `maps/` 下,可从 legacy 分支取回)。
- PvP HUD:`ui/hud/pvp_hud.tscn`(`class_name PvpHud`,CanvasLayer layer=130 盖在 PostProcess 128 / 单机 HUD 129 之上)显示双方击杀/局胜/局号(**记分条在顶部正中**,用户指定)+ 中央状态。摆放位置由 `pvp_hud_layout_probe.tscn`（已删·2026-10-09） 钉住。复活视觉:`combat.revive()` 已补 `post_process.set_downed(false)`。
- **服务端 exe 默认带运维面板(2026-10-17)**:`Dedicated Server` 预设改成 `custom_features="serverui"` + 主场景 feature 覆盖 —— **不再用 `dedicated_server` 标记**,因为引擎会对它强制空显示驱动(`main.cpp:2285-2288`),`--headless` 仍然有效且面板在 headless 下**不实例化**。面板挂在 `server/server_main.tscn` 上、只读大厅状态(房间/端口/worker 存活/名单),唯一的写操作是「关闭房间」且走 `teardown_room` 单一收口。★ 几何/字号/判据规则见 [`docs/superpowers/specs/2026-10-16-server-console-gui-design.md`](../superpowers/specs/2026-10-16-server-console-gui-design.md) —— **别在本文件手抄数字,会漂**。
- **服务端运维审计日志(2026-10-21)**:`NetDiag.audit()` 常开(仅非 client 进程),一行一 JSON 写 `user://logs/ops-<role>-<pid>-<时间戳>.jsonl`;关窗会优雅拆房并写 `lobby_stop`;每局 worker 引擎日志按端口归档。事件清单/保留策略/边界见 [`docs/superpowers/specs/2026-10-21-server-event-logging-design.md`](../superpowers/specs/2026-10-21-server-event-logging-design.md) —— **别在本文件手抄事件表,会漂**。
- 测试:`tests/smoke/pvp_room_smoke.sh`(建房/加入/开局)/ `pvp_match_smoke.sh`(输入→模拟→快照→子弹广播 + round_state 广播 + ack_seq 推进 + 快照 c2 全态与散字段一致)/ `pvp_reconcile_smoke.sh`（已删·2026-10-09）(rollback 控制器 in-process 冒烟)/ `pvp_twin_smoke.sh`（已删·2026-10-09）(capture/restore 完整性)。

- ★ **`#### 断线重连` 已搬到 [`netplay-reconnect.md`](netplay-reconnect.md)**（2026-10-13 按 64KB 判据拆出；内容逐字未改）。
- ★ **`#### 阶段 3:可见性 + 两个既有缺陷` 已搬到 [`netplay-reconnect.md`](netplay-reconnect.md)**（同上）。
- ★ **`#### 对局中的房:寿命 / 回收判据 / 可见性与拒绝` 已搬到 [`netplay-rooms.md`](netplay-rooms.md)**（同上）。
- ★ **`#### 回大厅后回局(阶段 2-B:凭据表 / 「列表里自己那间房」)` 已搬到 [`netplay-rooms.md`](netplay-rooms.md)**（同上）。
- ★ **`### RPC 通道划分表(★ 单一来源)` 已搬到 [`netplay-rpc-channels.md`](netplay-rpc-channels.md)**（同上；**通道号以那份为准**）。

---

## 实测读数与不变量（2026-10-13 从**代码注释**搬出）

> **为什么在这里**：同日的注释瘦身把注释压到 ≤15%，**成套实测与不变量**按配方搬进域文档。
> 原始台账（每条带原行号与出处）：[`2026-10-13-comment-diet-ledger.md`](../2026-10-13-comment-diet-ledger.md)
> §2（server_main）/ §4（mp_lobby）/ §5（pvp_match_client）/ §7（server/**）。
> ★ 这些是**读数与不变量**，不是规范：改联机面之前先在这里查依据。

### 1. 重连的时间尺度（本机实测，决定了重试预算）

- 尝试 @**0.15s** → `connection_failed` @**31.81s** → tick 在 ~**33.8s** 判超时（当年宽限期恰好 30s）。
  ⇒ **ENet 自身的连接超时约 31.8s**，比 30s 宽限期还长 —— 宽限期到点前，客户端往往还在"连"。
- 一次成功握手 ≈ **2~3 × RTT** ⇒ 5s 的 `RECONNECT_ATTEMPT_TIMEOUT_MS` 覆盖到 **~1.6s RTT**。
- ★ **reclaim 只发一次** 的不变量：worker 接受第一次时 `_grace.leave(role)`，第二次必然不成立 ⇒ **踢连接**。
  症状 = "刚重连上几秒又断"，而且 **token 是对的** ⇒ **查 token 查不出这个 bug**。

### 2. `server_disconnected` 为什么不发（订正史，别按"常识"改）

`NetBus.stop()` 会把 `multiplayer_peer` 置空 ⇒ 引擎的 `set_multiplayer_peer` 先 `clear()`、
`last_connection_status` **当场复位** ⇒ CONNECTED→DISCONNECTED **从未被观测到** ⇒
**`server_disconnected` 不会发**。`PauseMenu.go_menu()` 走直接 `NetBus.stop()`、**连 `toggled` 都不经过**
⇒ 当年"ESC 会引发重连"这个说法**不存在**。（`ui/pvp_hud` 那侧的菜单守卫即由此改写。）

### 3. 共享收口与声明位置（两条都踩过）

- **共享基类收口的量化**（2026-09-14）：客户端与服务端有 **7 个函数、合计 58 行逐字相同**；
  `_physics_process` 上挂着 **C2 心跳** ⇒ 它不是空跑。
- **`_rw_on` / `_rw_trail` 必须声明在根基类**：子类里声明的符号**编译期解析不了**（类型收窄时的经典坑）。

### 4. 层位与通道（碰撞层是协议的一部分）

| 层 | 用途 |
|---|---|
| 1 | 地形 |
| 2 | 玩家 |
| 4 | 敌人 |
| 8 | 掉落物 |
| 16 | 队 B 身体层 |

★ **客户端子弹的 `collision_mask = 5`**（层 1 + 层 4）而对手是**层 2 的幽灵体** ⇒ 物理上**永不接触**；
观感是"伤害算到了却像穿透"。判据与服务器裁决**同常量同公式**（`HIT_RADIUS` + 环面最短距离）。
★ **`NetBusExt` 里有一个同名遗留的 `beam_fired`**：挂错节点 = 静默 no-op（对手的枪凭空消失/永不再现）。
通道号的**唯一来源**见 [`netplay-rpc-channels.md`](netplay-rpc-channels.md)。

### 5. 端口池与建局引导（单一来源）

- **端口段单一来源 = `server/lobby/worker_launcher.gd`**：`WORKER_PORT_BASE = 7800`、`WORKER_PORT_SPAN = 500`
  ⇒ 实际池 **[7800, 8300)**。★ 旧页面手写过 "7800~7999" —— **照它放行防火墙会漏掉半个池子**。
- 三档端口归还延迟（`*_PORT_REUSE_DELAY`）**不再与宽限期绑定**：承重的是"worker 进程活着 ⇒ 房与它占的端口都还在"
  （房活到 worker 退出）。历史教训：**30 → 120** 的那次调整不是让延迟承重，而是承认延迟测不准。
- **建局引导已搬到 `server/match/match_bootstrap.gd`**，调用点在 `server/server_main.gd`。

### 6. 几个"看起来该红却没红"的实测

- **拾取插桩的两种成因分类**（判据:玩家 400px 内每 30 物理帧一行，`canon` / `render` 两栏是重点）：
  ① 静默 `return` 没建出枪；② `canonical_pos` 与画出来的位置分家。
- **幻影空洞**：顺序必须是"**先还原 + 再应用 == 服务器的 grid**"（不上线任何新字节）；**反过来症状与
  "根本没还原"逐字相同**。`reset_destructibles()` 只重铺瓦片层 + 重建碰撞（**不碰**玩家/子弹/地面武器）。
- **菜单守卫的"探针兼容访问口"已清理**（2026-10-15）：`ui/hud/pvp_hud.gd` / `team_hud.gd` 里为已删探针
  留的四个转发（`_mask` / `_big` / `_sub`）**全仓零读者**（连内部都不用）⇒ 删除；同族一并清掉
  `core/net/playout_clock.gd` 的 `error_ticks()` / `offset_min_ms()` / `started()` / `playout_ticks()`
  与 `server/lobby/rejoin_registry.gd` 的 `size()`（读它们的探针 2026-10-09 已删）。
