# B 档:六条「登记不修」边界的修复设计(2026-09-28)

## 0. 定位与本批的由来

用户 2026-09-28 裁定:**开始修此前登记为「已知边界 / 登记不修」的那批条目**(原话:「用户现在开始
修这些问题了(它们以为用户暂时不会修)」)。⇒ 本批里凡是引"某年某月已裁定不修"的注释,**都要一并
订正**,不能留下与原裁定冲突的墓碑。

本批只做**用户清单里的 B 档六项**:单点、行为面明确、能配判据。清单其余项分档如下,不在本批:

| 档 | 项 | 为什么不在本批 |
|---|---|---|
| C | 弹数无纠正路径 / `_pending_input` 上限 / 快照体积 | 都要先出设计(#4 的丢弃策略直接顶着 C2「每 tick 恰消费 1 包」的锚点,#5 要先压测) |
| D | 容量·把数按能力分叉 / 服务器只拆不加砖 | 阻塞在「能力系统」「加砖功能」,现在做只能做空壳 |
| E | `--ai-roles` 无端到端 | 要真起 AI 局,属另行安排 |

★ **`channel 0` 与「私密房回局」不在用户给的清单里**,本批不碰(用户另有一句"三条旧裁定全部推翻"
经 peer 转述,但那两条既不在清单内、也没有落点,本批按"不在范围"处理并登记)。

## 1. 范围与分层

* 本批改动落在 **`server/` 与两个具名 `scenes/` 文件**(`scenes/player/weapon_component.gd` +
  `scenes/weapons/weapon_base.gd` —— 经 peer 具名让渡;用户的并发分层是 `server/**` 归本会话、
  `scenes/ ui/ tests/ docs/` 归 peer)。
* **`tests/` 也归 peer**:本批新增的判据若落在 `tests/` 下的**新文件**,由本批自带并声明;
  对**既有** `tests/` 文件的改动一律先与 peer 打招呼(见 §4 的判据落点逐个标注)。

## 2. 六项设计

### #2 未入树的 `tick()` 把权威 `_reloading = false` 冲成 true

**现状与根因**(比登记文字更具体,已核对到行):

* `scenes/player/weapon_component.gd:258-259`:`body.weapon_slot.call_deferred("add_child", _weapon)`
  之后**紧跟**一行同步的 `_weapon.equip(body, inherit_cd)`。
  ⇒ **入树是 deferred 的,而 `player` 是同步写好的**。
* 于是那个窗口里 `WeaponBase._player_ok()`(`scenes/weapons/weapon_base.gd`)为**真** ⇒
  `WeaponComponent.tick()` → `WeaponBase.tick()` 照跑。
* 而 `mag_ammo` 此刻仍是**声明初值 0**(`weapon_base.gd:176` 的 `_ready()` 才置 `mag_size`)⇒
  `fire()` 走到 `weapon_base.gd:277` 的 `if mag_ammo <= 0:` ⇒ `start_reload()` ⇒
  **把 `_apply_weapon_state` 刚写下的权威 `_reloading = false` 冲成 true**,并多播一次没按键的
  `Sfx.play("reload")`。错到下一次 `restore_state` 才回正;若活过 `reload_time`,`tick()` 的常规
  收尾还会写 `mag_ammo = mag_size`(白送一个满弹夹)。

**修法**:新增 `_mag_ready`(默认 false,`_ready()` 里置 true),只让**依赖弹数的那个判断**在弹数
未落定前失效:

```gdscript
if mag_ammo <= 0:
    if _mag_ready:
        start_reload()
    return
```

**为什么不是 `is_inside_tree()` 守卫**(那条**已被明文否决**,见 `CLAUDE.md` 的同窗口残留登记):
它会丢帧,并会把 `_auto_aim()` 的朝向**一起冻住** ⇒ 那本身造成**真分歧**,比它修掉的问题更坏。
本修法**不动 `tick()` 的其余任何一行**(含 `_auto_aim()`),只让一个**读假前提**的分支失效。

**修后的可观察行为**:窗口里 `fire()` 彻底惰性(`mag_ammo` 恒 0 ⇒ 永远在 `:277` return)—— 与今天
「打不出枪」的可见表现**一致**,只少了那笔假状态与假音效。

**判据**:`tests/ammo_rollback_probe.tscn` 加一相 —— 造一个「未入树 + 权威 `rld=false` + 按住开火」的
武器实例,步进一帧,断言 `is_reloading() == false` 且 `mag_ammo` 未被写。反证:把 `_mag_ready` 判断
去掉 ⇒ 该相红。
★ 该文件属 `tests/`(peer 层)⇒ 动手前先打招呼。

### #6a `_left_round` 记的是「宽限到点」而非「断开时刻」

**现状与根因**:`server/team_host.gd:514` 在 `mark_disconnected` 里写
`_left_round[role] = _round_num`,而 `mark_disconnected` 由 `server/server_main.gd` 的
`_expire_graces` **在宽限期(60s)到点**时调。这 60s 若跨过一次换局,离开者的分母就**多算一局**
⇒ 他的 ACS 被**压低**,与「已离开者分母更小 ⇒ 更容易胜出」(用户裁定的取向)恰好**相反**。

**修法**:

* `server/match_state.gd` 新增 `var _leave_round: Dictionary = {}` 与
  `func note_disconnect_round(role: int) -> void: _leave_round[int(role)] = _round_num`。
  ★ **覆盖写、不需要在 reclaim 时清**:reclaim 之后若再次掉线,本函数会写上新局号;若不再掉线,
  `mark_disconnected` 根本不会被调,那条记录是惰性的。
* `server/server_main.gd:262` 的 `_enter_grace` 里调 `_host.note_disconnect_round(role)`。
* `TeamHost.mark_disconnected` 改读 `int(_leave_round.get(role, _round_num))`(缺省回落,**保证
  没有任何调用路径**会比旧行为更差)。

**判据**:**场景探针**(不能走 `-s` —— `Host` 链要 autoload,而 `-s` 阶段 autoload 尚未实例化):
真建宿主、`role_peers` 传空,手工摆 `players`,照 `tests/team_host_probe.tscn` 的手法;round 1 掉线
→ `_start_next_round()` → 宽限到期 → 断言 `_rounds_for(role) == 1`。反证:旧实现给 2 ⇒ 红。

### #6b MATCH_OVER 之后倒地仍进 `_stats`

**现状与根因**:倒地边沿块(掉落 + `_record_down` + 击杀 + `_broadcast_round_state`)排在
`match _round_state:` **之前**、且**不看状态** ⇒ 终局之后残留的爆炸致死仍会:

1. `deaths += 1`(真的写进 `_stats`);
2. `_drop_all_but_one` 在终局后再掉一次武器;
3. **再广播一次终局载荷**,且带着**新算出来的 `mvp`**。

**★ 要修的是两处,不是一处**(设计期核对到,原稿只写了 1v1):

| 模式 | 倒地边沿住在哪 | 现状 |
|---|---|---|
| 1v1 | `server/match_round.gd:8-42`,在 `match` **之前** | **有病** |
| 3v3 | `server/team_host.gd:302-…`,在 `match` **之前** | **有病** |
| 大乱斗 | `server/royale_host.gd:196` 起,**整支 `_match_round_tick` 就是一个 `match`**,倒地边沿住在 `RoundState.PLAYING` 分支里 | **天然免疫,不需要改** |

**修法**:在两个有病的地方各加同一道闸(位置:循环体最前,`players[role]` 之前):

```gdscript
	for role in players:
		# ★ MATCH_OVER 之后不再产生任何记账(终局后残留爆炸仍会把玩家打倒地):
		#   没有这道闸,`deaths` 会 +1、尸体再掉一次武器、并**再广播一次带新 mvp 的终局载荷**。
		#   大乱斗那一支**天然没有这个问题**(它的倒地边沿住在 `RoundState.PLAYING` 分支里)
		#   —— 两处形状一致是**刻意**的(同一契约的三份落地),别把这句当成多余而删掉。
		if _round_state == RoundState.MATCH_OVER:
			continue
```

**范围边界(照实登记,本批不改)**:只排除 `MATCH_OVER`。**`ROUND_OVER` 期间倒地照旧入账** ——
那是既有行为,不在本项里。将来若要收紧,判据应改成 `!= PLAYING`,但那是另一条决定。

**判据**:新场景探针 `tests/late_match_probe.tscn`(见 §4),**每个模式两相**:

* **反向对照(必须先有)**:`PLAYING` 里制造一次倒地 ⇒ `deaths == 1`。没有它,"把整块删掉"
  也能让下面那条通过。
* **本项**:`MATCH_OVER` 里制造一次倒地 ⇒ `deaths == 0`(1v1 另断言 `_scores` 未动)。
* ★ 两相各用**一具新宿主**(`_down_counted` 闩与 `_stats` 都留在宿主上,复用会互相污染)。

### #7 `_match_winner` 的并列候选集

**现状与根因**:`server/royale_host.gd:278` 的候选 = `players ∪ _scores`。一个**0 杀**的离开者
**两边都不在**(`mark_disconnected` 会把他从 `players` 里 `erase`,`_scores` 里也没有他的条目)
⇒ 少一个并列候选 ⇒ **全场 0 杀**时"多人并列 ⇒ 平局"被**翻转**成幸存者独胜。
`scenes/royale_game.gd:221` 那道 `and not _match_ended` 门正是为挡这次翻转而立的
(它的注释写着「要删先修 `_match_winner`」—— 本项就是那次修)。

**修法**:候选并上 `_left`(0 杀离开者**唯一**的痕迹):

```gdscript
for role in _left:
    candidates[int(role)] = true
```

**逐档推演(已在设计期核过,只在第 3 档改变结果)**:

| 场面 | 旧 | 新 |
|---|---|---|
| A 有分、B(0 杀)已离开 | A 胜 | A 胜(同) |
| A(0)、B 有分已离开、C(0)在场 | B 胜 | B 胜(同) |
| **全部 0 杀、且离开者让幸存者只剩 1 人** | **幸存者胜(错)** | **平局 0(对)** |

★ **第三档的人数必须写清(本行原稿漏了,是 spec 的一处错)**:平局要成立得有 **≥2 个候选**共享最高分,
所以"少一个并列候选"只有在**幸存者恰好 1 人**时才翻转结果。
- **2 人局掉 1 个** ⇒ 幸存者 1 人 ⇒ 老实现**独胜**(错)✔ 本行描述的就是这一档;
- **3 人局掉 1 个** ⇒ 幸存者 **2 人**,他们**彼此**已在 0 杀上并列 ⇒ 老实现**照样判平局**,
  本项在该 fixture 上**修前就是绿的**(实现期实测:`实得 0`)。

⇒ 判断此修复时必须把人数钉死;`tests/late_match_probe.gd` 的 ④ 用的是**掉到只剩一人**(等价于 2 人局掉 1 个),
而那也是生产里"最后一个对手离开 ⇒ `_finish_match()`"的真正落点。

**连带(登记,不在本批改)**:`scenes/royale_game.gd:221` 的门在本项落地后**失去理由**,但它在
**peer 的层**,本批**不动**。是否删除由 peer/用户决定;删之前要先确认 `_match_winner` 的修复已落。

**判据**:真建 `RoyaleHost`(`role_peers` 传空)的探针加一相:3 人全 0 杀、其中 1 人
`mark_disconnected` ⇒ 断言 `match_winner() == 0`。
★ **必须有反向对照**:制造分差时仍判分高者 —— 没有它,"恒返回 0"也能过。

### #8 `same_team` 的死代码半句

**现状与根因**:`server/match_state.gd:353` 的助攻过滤写成

```gdscript
if not same_team(attacker, killer_role) or same_team(attacker, victim_role):
    continue
```

前半句**唯一承重**;后半句**永不改变结果** —— 因为上面那道
`if same_team(killer_role, victim_role): … return` 早退已保证**击杀者与受害者异队**,
而"attacker 是受害者的队友" ⇒ attacker 与 killer **必定不同队** ⇒ 前半句早已为真。
登记还记着:只删后半句,**没有任何断言察觉**。

**修法**:删掉后半句,并把**它依赖的那个前提显式写进注释**(冗余表达式 → 一条写明前提的规则)。

**为什么删得掉**:那个前提本身有**行为面**守卫 —— `tests/team_host_probe.gd` 的
(k4)(`_down(_host, 2, 1)`,受害者的**队友**补刀 ⇒ 谁都不记助攻 + 记 `team_kills`)钉住的正是
"同队击杀即早退"这条路径。⇒ 删的是**冗余**,不是**守卫**。

**判据**:**本条刻意不新增断言**。理由是前提已有行为守卫,而再加一条"源码里不得出现
`same_team(attacker, victim_role)`"的文本守卫,恰好是本仓点过名的**失明高发形态**
(`tests/lib/probe_base.gd` 与 `CLAUDE.md` 的源码文本守卫条目)。计划里要写明"这条没有新判据",
免得后来的人以为漏了。

### #10 1v1 worker 没有报到梯

**现状与根因**:`server/server_main.gd:334-351` 的报到梯只有三支 ——
`_team_mode`(30s 退出)、`_royale` 且 `_claims >= 2`(20s 降级开局)、`_royale` 且 `< 2`(10s 退出)。
**纯 1v1(`not _royale and not _team_mode`)一支都没有** ⇒ "大厅配对完成、worker 已拉起,但两个
客户端都没 `claim_role`"(转连失败 / 都在 `go_match` 后立刻消失)时,worker **永驻**、端口白占到
**2h 超龄兜底**。

**修法**:加第四支

```gdscript
elif not _royale and not _team_mode and not _match_started and _host == null:
    _understaffed_wait += delta
    if _understaffed_wait > 30.0:
        print("worker: 1v1 报到超时(%d/2),退出释放端口" % _claims.size())
        get_tree().quit(0)
```

**30s 的来历(承重,不是随手取)**:客户端侧的内建兜底是 **12s 转连 / 25s claim**
⇒ worker **必须晚于**它们退 —— 否则客户端还在重试,端口已经没了(那会把"转连慢"变成"连不上")。
30s 与 3v3 那一支同值,也与"客户端已经放弃之后"这个语义一致。

★ 这一支同时覆盖两种子情形:**一个 claim 都没有**、以及**只到一个**(1v1 要 2 人齐才开),因为
判据是 `not _match_started and _host == null`。AI 对战(`--ai-roles`)下单人即可开局,故正常路径
不会走到这一支。

**判据**:照 `tests/team_spawn_smoke.gd` 的先例 —— 真拉起一个 1v1 worker、不给任何 claim,
断言它**在 ~30s 后退出且退出码 0**、并打印那一行。★ 这条是**真链路**(起独立进程),
按本仓纪律属"用户跑"那一类,计划里要标出来。

★ **连带登记**:`CLAUDE.md` 的「`--ai-roles` 从未真机跑过」与本条**不是同一件事**(那条要的是
AI 局端到端),本批不覆盖。

### #11 royale 的「在局宽限」缺口

**现状与根因**:`server/room_manager.gd:408` 的在局宽限取
`SWEEP_INTERVAL + RoyaleHost.MATCH_TIME`(300s)。而 `MATCH_TIME` 只是**默认值** —— 房主可在建房页
用「一局限时」滑块改本局时长,该值经 `NetBusExt.player_options` 的 `match_time` 随 role1 报到进
`RoyaleHost._cfg_match_time`(*`RoyaleHost` 内部*把 `_match_time` 换成它)。
⇒ **一个等了近 2h 才开局、又配了长时长的房**,其对局进行到 300s 之后的那次 tick 仍会判它超龄、
**连 worker 一起杀掉**。缺口最大约 1500s。

**修法**:在 `server/room_manager.gd` 里与 `TEAM_MATCH_ESTIMATE` 并列新立一个**可证的上界**常量,
并**就地**把谓词里那一个常量换掉(不抽函数 —— 见下):

```gdscript
# 大乱斗一局长度的**可证上界**:Settings.royale_match_min 在 core/config/settings.gd:147 的
# 装载钳位是 [1.0, 30.0] 分钟 ⇒ 秒数上界 1800。(建房页滑块只到 15,但 settings.cfg 可到 30。)
# ★ 跨文件不变量:钳位一旦放宽到这里以下,本上界**静默失效**(不再覆盖) —— 改钳位要回来一起改。
#   守卫:`tests/room_sweep_smoke.gd` 会去读 settings.gd 的钳位行,钳位变了就红。
const ROYALE_MATCH_TIME_CEILING := 1800.0
```

```gdscript
		var in_match_grace := (SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING) if rr.in_match else 0.0
```

**★ 为什么刻意不走「把 `match_time` 随 `royale_create` 存到房上」那条看起来更准的路**:
`_player_options()` 是**报到那一刻**才读 `Settings`,`royale_create` 是**更早的另一刻**
(实测 `server/lobby_rooms.gd:427` 起的 `royale_create` **压根不转发** `match_time`)⇒ 存下来的那个
数是**下界**,缺口照留。而硬上界是**保守**的(永不误杀活局),代价只是泄漏的房多留 ~25 分钟
(房间数量与端口池 500 相比微不足道)。⇒ **保守 + 可证**胜过**精确但可错**。

**★ 为什么也不抽成纯静态函数**(设计期改动,原稿写的是抽函数):抽了之后,行为断言只能拿
`SWEEP_INTERVAL + ROYALE_MATCH_TIME_CEILING` 去比它自己 —— 两边读同一对常量,**近乎同义反复**;
而真正的风险(常量被改回默认值 / 钳位被放宽)两边都是**文本**面。⇒ 就地换常量 + 文本断言更小、
更准,且不新增一个"抽了函数但生产没接"的失明面。

**★ 顺带必须改的三处文案**(不改就会**说谎**,不是风格问题):

1. `server/room_manager.gd:433` —— 清扫日志里的 `MAX_ROOM_AGE + SWEEP_INTERVAL + RoyaleHost.MATCH_TIME`
   打印的是**判据用的那个界**,不改就等于日志报了个假的界。
2. `tests/room_sweep_smoke.gd:398` —— **既有断言**要求谓词行含 `RoyaleHost.MATCH_TIME`;
   换常量后它**当场红**。这一截改成认 `ROYALE_MATCH_TIME_CEILING`。
3. `tests/room_sweep_smoke.gd:664` 的 OK 串与 `:5` / `:14` 的文件头描述里都写着
   "大乱斗 RoyaleHost.MATCH_TIME",一并订正。

**★ 该项名字里的「端口延迟」那半已自动闭合,不需要改常量**:房活到 worker 退出、端口只在
`teardown_room` 里归还 ⇒ 三档 `*_PORT_REUSE_DELAY` 的计时起点是 **worker 退出**,不再是"房间拆除"。
故"宽限期内重连的客户端手里那个端口还在不在"由**凭据里的 `worker_pid`** 精确回答,与那三个常量
取多少无关。计划里要写明这条**为什么不改**,免得后人照旧说法去调那个数。

**范围**:**3v3 不动**(它用的是 `TEAM_MATCH_ESTIMATE`,是另一条已登记的估值,不在用户清单里);
**`ROYALE_PORT_REUSE_DELAY` 不动**(理由见上)。

**判据**(`tests/room_sweep_smoke.gd`,`-s`,三条都在既有的 `_check()` 体内,**不新增该文件的检查项**):

1. `room_manager.gd` 源码里 `const ROYALE_MATCH_TIME_CEILING := 1800.0` 在位。
2. 谓词行那一截:含 `ROYALE_MATCH_TIME_CEILING`、**不再**含 `RoyaleHost.MATCH_TIME`
   (原断言那一截的反转),同时保留既有的 `rr.in_match` 与 `SWEEP_INTERVAL` 两截。
3. **前提钉在它住的地方**:`core/config/settings.gd` 的装载钳位行仍含 `1.0, 30.0`
   —— 钳位一放宽,第 1/2 条仍绿而缺口复现,这条是唯一会红的那一处。

反证:把谓词改回 `RoyaleHost.MATCH_TIME` ⇒ 第 2 条红;把钳位放宽到 60 ⇒ 第 3 条红。

## 3. 不做的事(明确排除)

* **不碰** `channel 0`(引擎侧噪音,用户已裁定不修,且不在清单里)。
* **不碰**「私密房回局」(不在清单里;落点跨 `server/lobby_rooms.gd` 与 `scenes/lobby_page.gd`,
  要动必须先与 peer 对齐)。
* **不删** `scenes/royale_game.gd:221` 的 `and not _match_ended` 门(peer 的层)。
* **不改** `ROYALE_PORT_REUSE_DELAY` / `TEAM_MATCH_ESTIMATE` / 1v1 的在局宽限不对称。
* **不收窄** `ROUND_OVER` 期间的倒地记账。
* 本批**不新增** `mcp`/协议字段;`#2 #6 #7 #8 #10 #11` 全部是**服务端/本地逻辑**,
  **协议零改动**。

## 4. 判据落点逐个标注(与 peer 的分层对齐)

peer 已于 2026-09-28 放行 `tests/`(**唯一例外:`tests/team_match_*`,本批一个字不碰**)。
为减少撞车,除两处必要落点外**一律新建文件**;`tests/royale_c2_probe*` 留给 peer 的阶段 3。

| 项 | 判据落点 | 处置 |
|---|---|---|
| #2 | `tests/ammo_rollback_probe.tscn` 加一相 | **既有文件**(该 bug 的专用探针,无更合适的家) |
| #6a | `tests/late_match_probe.tscn` ③ | **新文件** |
| #6b | `tests/late_match_probe.tscn` ①② | **新文件**(1v1 + 3v3 各两相) |
| #7 | `tests/late_match_probe.tscn` ④⑤ | **新文件**;★ **刻意不碰 `tests/royale_c2_probe*`** |
| #8 | —— | **无新判据**(见 §2 #8) |
| #10 | `tests/duel_spawn_timeout_smoke.gd` | **新文件**(`-s`,照 `team_spawn_smoke` 先例;拉起真 worker) |
| #11 | `tests/room_sweep_smoke.gd` 的既有 `_check()` | **既有文件**,三条断言,不新增检查项 |

⇒ 实际会动的既有 `tests/` 文件**只有两个**:`ammo_rollback_probe.tscn` 与 `room_sweep_smoke.gd`;
其余是 `tests/late_match_probe.{gd,tscn}` 与 `tests/duel_spawn_timeout_smoke.gd` 两个新文件。

★ `#2` 的探针**不需要真世界**:`WeaponBase._aim_world_dir()` 在 `get_viewport() == null` 时
早退(实测 `scenes/weapons/weapon_base.gd:508`),故入树前的 `tick()` 是安全的 —— 探针只需一个
`WeaponBase` 实例 + `equip()` 出的 `player` 引用 + 一个受控输入源。

## 5. 已知风险

1. **#6b 的早退会不会吃掉正当记账** —— `MATCH_OVER` 之后本就无"正当记账",且复活调度在
   `PLAYING` 之外本来就不发生(`match_round.gd:15`),故早退不改变任何其他行为。判据要**同时**
   断言"MATCH_OVER 后不记账";反向对照是"PLAYING 中照常记账"(否则"整块删掉"也能过)。
2. **#10 的 30s 一旦短于客户端兜底**,会把"转连慢"变成"连接被拒" —— 这是本批**唯一**一处
   时间常数耦合(客户端 12s/25s)。计划里要把它写成一条**显式不变量注释**并注明三处必须同源。
   ★ 该判据是 `-s` 冒烟(只 spawn 进程 + 读日志,**不需要 autoload**)⇒ 与 `team_spawn_smoke`
   同档:**agent 可跑**,用池外端口,收尾按端口杀。
   ★★ **跨会话次序**:peer 的阶段 3 计划 Task 3 也要在 `server/server_main.gd` 的 `_process`
   里插 1~2 行(`_sync_grace_snapshot()`),**与本项同段**。已约定:**本项先落**、落完通知 peer;
   两边按名 `git add`、各自提交,不合并。
3. **#11 的 1800 依赖 `settings.gd:147` 的钳位**。若哪天钳位放宽到 60 分钟,这个上界**静默失效**
   (不再覆盖)。⇒ 判据第 3 条就是钉这个前提的那一处;改钳位时它会红。
4. **#2 的 `_mag_ready` 是"弹数已落定"的标记**,不是"开火是否允许"。别把它顺手用到别的判断上 ——
   它只在 `_ready()` 置真一次,语义是"`mag_ammo` 不再是声明初值"。
