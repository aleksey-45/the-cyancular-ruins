# 三模式联机代码统一 · 设计 spec

> 状态:**待评审**(只到 spec;评审通过后才写实施 plan,再逐任务改)。
> 日期:2026-10-22。范围:1v1 / 3v3 / 大乱斗三个联机模式的**重复真相源收敛**。
> 关联:本轮的 bug 报告 [`.superpowers/bughunt/REPORT.md`](../../../.superpowers/bughunt/REPORT.md)(17 条)与
> [`docs/eng/modes.md`](../../eng/modes.md)(三模式规则语义的权威登记)。

---

## 0. 一句话

把"三模式各写一份"的**重复实现**收敛到单一来源(方案 A 必做、B 视 A 的验收结果再定、C 只取一个低风险切片),
**不改协议、不改玩家可见行为**;模式规则语义(1v1 三局两胜 / 3v3 换边与队分 / 大乱斗死斗与无 ACS)保持三分。

## 1. 为什么要做:本轮 bug 里有一整类是"改一处忘一处"

| 本轮 bug | 形态 |
|---|---|
| X1 16 人上限只改了一半(`--roles` 仍 `<=8`) | 同一个数(上限)写在三处,迁移时只 grep 到常量、漏了字面量 |
| X5 3v3 藏了禁用武器控件、却仍上发设置 | 选项下发没有"按模式取键"的单一来源 |
| 历史:宽限到期/自杀闸/全员走光漏收 `_team_mode` | `server_main` 的 `_royale`/`_team_mode` 引用各 19 行(共 38 行),靠人记 |
| 3v3 换局双重建(客户端 reset + resync 又 reset) | 同一条"换局复位"在两个调用点各做一遍 |
| 1v1/3v3/大乱斗结算与 MATCH_OVER 三份实现 | 客户端三份 `_on_round_state`,一处刻意不对称(`and not _match_ended`) |

**目标(可验证)**:
1. 三种模式的客户端**不再各写一份** `_on_round_state`(只留差异钩子);
2. 选项下发只由一张**模式→键**表决定,不再出现某个模式"藏了控件却仍上发";
3. 大厅入住/建房/退出只走**一个入口校验**(六个 RPC 名保留);
4. `server_main` 的模式判断只读一个**一次性算好的只读上下文**;
5. 以上每条都有"去掉什么才会红"的守卫;三模式真链路判决与改前**逐条同形**(不要求转绿)。

**非目标(刻意不做)**:
- 不改协议字段、通道号、worker argv、房间号空间、端口池、结算列集;
- **不统一模式规则语义**(那是产品差异,统一会变成条件分支地狱,`docs/eng/modes.md` 已把"三模式计分三种组合"登记为有意差异);
- 不重写服务端 6 层继承链(`MatchState→Ground→Snapshot→Combat→Round→Host`);
- 不以"代码行数下降"为成功判据 —— 只以**单一来源**为判据。

## 2. 现状地图(量化,数字可复核)

复核命令(仓库根):`git grep -n '^func ' -- scenes/{pvp_game,royale_game,team_game}.gd`;
`git grep -n '_current_mode' -- scenes/mp_lobby.gd`;
`git grep -c '_royale\|_team_mode' -- server/server_main.gd`;
`git grep -n 'class Room\|var rooms\|royale_rooms\|team_rooms' -- server/lobby/lobby_rooms.gd`。

| 层 | 现状 | 重复形态 | 风险 |
|---|---|---|---|
| **客户端三子类** | `pvp_game.gd` 12 个 func / `royale_game.gd` 18 / `team_game.gd` 27 | `_on_round_state` 三份(`pvp:134` / `royale:185` / `team:303`);`_build_result_payload` 三份;`_ready` 各自装配三连(`_subscribe_tile_events` / `_subscribe_ground_weapons` / `_subscribe_reconnect`) | MATCH_OVER 幂等/输入锁/结算挂载改一处漏两处 ⇒ 卡结算页或输入不解锁(零报错) |
| **客户端基类** | `pvp_match_client.gd` 66KB,已承担订阅/重连/拾取/拆砖/结算挂载/C2 | 钩子已有:`_apply_peer_hues_or_team`、`_build_result_payload`、`_refresh_input_lock`、`_show_result` | 已接近模板方法,只差 `_on_round_state` 的四态公共段 |
| **大厅房间** | `lobby_rooms.gd` 45KB:`Room`(:26)/`RoyaleRoom`(:46)/`TeamRoom`(:74) 三个类 + 三张表(:42/:69/:93) | 六个起手入口(:213/:238/:375/:413/:558/:586)+ 退出/选边(:453/:624/:641);`mp_lobby.gd` 里 `_current_mode` **29 处** | 新增模式/改入口要同时改六处互斥 ⇒ 双重 `go_match`、幽灵房、端口不归还(历史发生过) |
| **选项下发** | `lobby_page.gd:337` 基类(必须覆写)→ `mp_lobby.gd:1027` | 无模式分支:三模式共用一份 `Settings` 快照 | X5 已实锤;同族:`time`/`map`/`match_time` 只在部分模式有意义 |
| **服务端入口** | `server/server_main.gd`:`_royale` **19 行**、`_team_mode` **19 行**(共 38 行引用) | 判断/合取散落在宽限/自杀/收齐/退场 | 历史 bug 全是"漏一处" |
| **对局宿主** | 6 层链共 ~85KB;`TeamHost` 20 个 func、`RoyaleHost` 10 个 | 覆写虚方法(`_match_round_tick`/`_broadcast_round_state`/`_finish_match`/`_match_winner`/`_attributed_killer` 等) | 基类加钩子/改签名时覆写方静默不跟上(虚分派漏覆写=行为退化) |
| **已统一(不动)** | 协议/编解码、输入、预测回滚、结算适配、计分、世界/拆砖/出生池 | 单一来源:`SnapshotCodec`、`PacketInputSource`/`PlayerInput`、`PredictionRollback`、`MatchResultPayload`、`ScoreRules`、`TileDefs`/`SpawnPicker`/`WorldBuilder` | —— |

**判断**:统一度已经约七成;剩下的重复**正好集中在"改一处忘一处"的高发区**。

## 3. 方案

### A · 收敛重复真相源(必做,低风险)

**A1 选项表驱动**
- 落点:`scenes/lobby_page.gd`(基类)+ `scenes/mp_lobby.gd:1027`(覆写)。
- 形状:`MODE_OPTION_KEYS := {MODE_PVP: ["hue","round_full_heal","disabled_weapons","map","time"], MODE_ROYALE: [...], MODE_TEAM: [...]}`;
  `_player_options()` 遍历当前 `_current_mode` 的键表从 `Settings` 取值(值构造函数表 `OPTION_VALUE`),不再写死字典。
- 判据:纯函数 `-s` 冒烟断言"3v3 的 options 不含 `disabled_weapons`";变异:把键表里 3v3 加回该键 ⇒ 红。
- 修 X5;**收益**:以后加模式只改表。

**A2 客户端 `_on_round_state` 模板方法**
- 落点:`scenes/pvp_match_client.gd`(基类新增模板)+ 三子类删各自实现。
- 形状:基类实现四态公共段(COUNTDOWN 清子弹 / 新一轮复位 / 输入锁刷新 / MATCH_OVER 销毁暂停菜单 + 挂载或刷新结算页),子类只覆写:
  - `_on_countdown_round(round:int)`(3v3 额外 `reset_destructibles()` + 拉 `match_sync`;1v1 `reset_destructibles()`;大乱斗空);
  - `_on_match_over_extra(data)`(3v3 的第二条载荷刷新,保留它"刻意没有 `and not _match_ended`"的现状);
  - `_result_payload(data)`(A5 的列集表)。
- **最小侵入备选**(评审时可换):保留三份 `_on_round_state`,但把公共段抽成 `_common_round_state(data) -> int` 由三处各调一次;工作量更小、行为面更窄。
- 判据:新增"第二条 MATCH_OVER 载荷必须刷新结算页"的行为断言(现零守卫)+ 三模式真链路同形。

**A3 大厅入住校验单一入口**
- 落点:`scenes/mp_lobby.gd` / `server/lobby/lobby_rooms.gd` 的六个入口。
- 形状:`_enter_check(mode, code) -> String`(返回拒绝理由,空=可进),由 `MODE_TABLE`(每模式:房型/创建 RPC/加入 RPC/退出 RPC/是否选边/是否公开列表)决定;六个入口保留 RPC 名、内部只调它。
- 判据:`-s` 纯函数冒烟(`mode_table_smoke`):任意 mode 在另一模式的房里被拒;未知 mode 被拒;变异:去掉某一条双向判断 ⇒ 红。

**A4 `ModeContext`(server_main 收口)**
- 落点:`server/server_main.gd`。
- 形状:启动解析后一次性算出只读 `_ctx`(`{worker, royale, team, roles, ai_roles, team_of, human_count}`),38 行 `_royale`/`_team_mode` 引用(其中是判断/合取的那些)改成读 `_ctx`;启动期一次断言"互斥/等长/非空"(现状逻辑收进来,不新加行为)。
- 判据:`-s` 纯函数冒烟(`mode_context_smoke`):`--royale --team` 互斥被拒、`--roles` 与 `--teams` 不等长被拒、role 上界(与本轮 X1 的单一常量同源)。
- **收益**:以后加模式只改解析与表;漏收一项会被"唯一入口"挡住,而不是在 38 处里各查一遍。

**A5 结算列集表**
- 落点:`ui/screens/match_result_payload.gd`。
- 形状:保留 `for_duel/for_royale/for_team` 三个纯函数(现已被三个客户端与文档引用),新增 `for_mode(state, mode, ...)` 内部分派;列集常量不变。
- **该层今天零守卫**:`match_result_payload_smoke` 已在 2026-10-09 删除(`git grep MatchResultPayload -- tests/` 为空)⇒ A5 实际是**补守卫**,不是"保持守卫"。
- 判据:新增 `-s` 冒烟 `match_result_mode_smoke`:① 每个 mode 走 `for_mode` 的结果与对应旧适配器逐键相同;② 每个列键都能在 `COLUMN_TITLES` 里查到标题(缺标题是"渲染成空列"的静默缺陷);变异:把 `for_mode` 的 team 分派改成 duel ⇒ 红。

### B · 大厅单注册表(选项,等 A 验收后按真链路判决再定)

- `Room` 加 `mode` 字段;三张表合一(`rooms_of(mode)` 只读访问器);`teardown_room` 的三态判定从 `room is RoyaleRoom` 改成读 `room.mode`;
- 六个入口收敛成 `_create(mode)` / `_join(mode)` / `_leave(mode)` / `_pick_team(mode)`,**RPC 名保留**(`royale_*`/`team_*` 转发);
- 房间规则表 `MODE_ROOM_RULES`:`{min_players, max_players, team_size, start_requires_full, port_return_s, visible_in_match, freeze_roster}` —— 把现在散在 `room_sweep_lint` 里钉的字面量收成数据;
- **协议零变化**,但**行为面**(端口归还/回收梯/回局可见性)必须逐条对照
  [`room-lifecycle-conventions.md`](../../eng/room-lifecycle-conventions.md),这是本方案最高风险处;
- 判据:`room_sweep_lint` 改读表 + 三模式真链路 + "未知 mode 被拒"冒烟。

### C · 服务端规则组合(不做,只留切片)

- 为什么不做:两 Host 的 30 个覆写里有大量"刻意保留的写点"(`modes.md` 明确"别删,删了作废整段登记"),重写成 `MatchModeRules` 组合的回归面 = 全部三模式对局 + 计分/结算/掉线;而本轮没有"加新模式"的时间压力。
- 唯一切片:**A4 的 `ModeContext`**(它同时是 B/C 的前置,所以放进 A 做)。

## 4. 统一后的数据流(明确"什么没有变")

```
客户端 → NetBus* RPC(名字不变) → 大厅统一入口 _enter_check(mode) → MODE_TABLE 校验
      → 房间记录(Room.mode) → 拉起 worker(argv 不变) → go_match
worker → _ctx 一次性算好 → 建 host(类型不变:MatchHost/RoyaleHost/TeamHost) → 共用 6 层链
客户端 → PvpMatchClient._on_round_state(模板) → 子类钩子 → 结算 for_mode
```

**变的是实现落点;不变的是**:协议字段/通道号、worker argv、房间号空间、端口池、结算列集、三种模式的规则语义。

## 5. 错误处理与兼容

- 启动期:未知模式 / `--royale --team` 互斥 / `--roles` 与 `--teams` 不等长 / role 越界 ⇒ `push_error` + `quit(1)`(现状已有,收进 A4 一次性断言;越界从"静默丢"改成"报错",与本轮 X1 修法一致)。
- 回局凭据:`PvpSession.room_mode` 不变,B 合并表后 `can_rejoin_to(code, mode)` 语义不变。
- 版本兼容:A/B **不动协议** ⇒ 新旧大厅/客户端可混连(仅内部实现不同);C 不做,所以没有"必须两端同版本"的新增约束。

## 6. 守卫与测试(每条都要能回答"去掉什么才会红")

| 守卫 | 桶 | 去掉什么才会红 |
|---|---|---|
| `mode_options_smoke`(`-s`) | 冒烟 | 3v3 键表加回 `disabled_weapons` / 某模式漏键 |
| `mode_table_smoke`(`-s`) | 冒烟 | 去掉某一条跨模式互斥 / 未知 mode 放行 |
| `mode_context_smoke`(`-s`) | 冒烟 | 互斥组合不再拒启动 / roles-teams 不等长放行 / role 上界回退 |
| `match_result_mode_smoke`(`-s`) | 冒烟 | `for_mode` 分派错(team→duel)/ 某个列键没有标题 |
| 第二条 MATCH_OVER 刷新(行为) | 场景探针 | 基类把"每次刷新"写成 `if _result != null: return` |
| 三模式真链路判决 | 真链路 | 与改前同形 = 通过;任何一条新增 FAIL = 红 |

- 新写 `-s` 冒烟必须带 `EXPECTED_CHECKS` 条数闸(本仓纪律);
- **不新写**"数值/时序/观感"类守卫(D3),不拿源码文本断言替代行为(D6);
- 真链路回归清单(判据一律 grep 文本):
  1. `bash tests/smoke/pvp_match_smoke.sh` → `SMOKE PASS`
  2. `bash tests/smoke/pvp_room_smoke.sh` → `SMOKE PASS`
  3. `bash tests/probe/rejoin_probe.sh` → `REJOIN PROBE: ALL-OK`
  4. `bash tests/probe/royale_soak_probe.sh` → `SOAK: ALL-OK(4/4)`
  5. `bash tests/probe/team_match_probe.sh` → 与改前**同形**(目前 `TEAM MATCH PROBE: 3 条失败`,全部在探针相③;不要求因本重构转绿)
- 跑批纪律照旧:三支真链路串行、`lobby_alive` 先行、收尾无残留 Godot。

## 7. 分阶段与工作量(粗估,供评审砍)

| 阶段 | 内容 | 估时 | 风险 |
|---|---|---|---|
| **A** | A1 选项表(0.5d)+ A2 客户端模板(0.5–1d)+ A3 大厅入口表(0.5d)+ A4 ModeContext(0.5d)+ A5 列集(0.25d)+ 守卫/回归(0.5d) | **1.5–2.5 d** | 中(A2 改执行顺序) |
| **B** | 表合并(1.5d)+ 入口收敛(1d)+ teardown 读表(0.5d)+ 回归(1d) | **2.5–4 d** | 高(端口归还/回收梯) |
| **C** | 不做(仅 A4 切片) | 0 | —— |

**建议顺序**:A 单独一个 commit 批次 → 真链路判决存档 → 再决定 B 是否开工。C 在本轮之后另议。

**plan 边界**:实施 plan 先只覆盖 **A**(单一 plan、可独立验收);B 若拍板要做,**另起一份 plan**(它动端口归还/回收梯,必须单独评审)。

## 8. 风险与回滚

- **A2 风险**:把四态公共段提到基类会改变三个模式的执行顺序(例如"清子弹 → 复位砖 → 拉 match_sync"的相对顺序是 3v3 的承重顺序)。对策:模板里**保持现有顺序逐字不动**,只把代码搬家;三模式真链路与改前同形作为硬判据。
- **B 最高风险**:`teardown_room` 三态 + `_release_port_later`(120s/360s) + RoomManager 回收梯。对策:先写"端口归还/注册表删除只能出现在两处"的 lint 已存在(`room_sweep_lint`),B 改动后必须让它继续绿 + 真链路。
- **共享工作树**:另一条工作线在 `server_main.gd` / `mp_lobby.gd` / 服务端面板上有未提交改动(2026-10-21 的 server 事件日志)。A3/A4 会碰 `server_main.gd` / `mp_lobby.gd` ⇒ **开工前需协调**:等那条线落盘,或本 spec 只做不冲突的 A1/A2/A5 先行。

## 9. 待评审时拍板的问题

1. **B 做不做**?(建议:先只做 A,拿真链路判决后再议)
2. **A2 用"模板方法"还是"最小侵入备选"**?(后者保留三份 `_on_round_state`,只抽公共函数,工作量减半、行为面更窄)
3. **A3 保留六个 RPC 名**?(建议保留 —— 改协议不在本轮)
4. **A4 是否提到 A 的第一项做**?(它挡住 B/C,且能顺手把 X1 的 role 上界收口)
5. **与另一条工作线(`server_main.gd` 未提交改动)的排期**:等它落盘,还是先做不冲突的 A1/A2/A5?
