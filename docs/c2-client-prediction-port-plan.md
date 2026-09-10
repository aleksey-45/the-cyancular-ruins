# C2「客户端物理模拟 + 权威锚定回滚」移植方案(KH_v1_1_2)

> 对象:原作者 origin/main 的联机优化(70e4c75「C2 客户端预测 rollback 落地并启用」,
> 及配套 2046143 输入按序消费 / 1dd213e 快照时序 / COUNTDOWN 冻结补洞)。
> 现状:KH_v1_1_2 全联机模式 =「服务器渲染本地玩家(server_rendered)」,与 C2 方案无任何交集
> (merge-base 与 origin/main 停在 2026-09-04,网络层只 cherry-pick 过榴弹/激光/冲刺等局部修复)。
> 本文档 = 移植设计,供评审后再动代码。

---

## 0. 结论摘要

- **收益判定:有效,但对低延迟场景边际、对高延迟/跨网场景显著**。C2 把「本地玩家的移动/跳跃/爬梯手感」从
  「每步都要等服务器往返(≈RTT)」变成「本地即时响应 + 仅分歧时回滚纠偏」;同时消除 server_rendered 下
  本地角色被 60Hz 快照直写带来的跳变/延迟感。
- **风险判定:可控,但有历史包袱**。本仓库曾实装过一版 C2 因梯/链等「边沿+位置敏感」机制大量回拉而放弃
  (AGENTS.md 有记录),才改走 server_rendered。原作者新版 C2 对当年三个根因(输入边沿丢失、ack/快照错拍、
  倒计时冻结漂移)逐一打补丁,理论上更成熟;但**移植到 KH_v1_1_2 的梯/水/冲刺/倒地组件上是否仍确定,
  必须用"确定性双 sim 探针"先验证,再上真机**。
- **结论:值得移植,分四期推进,全程保留 server_rendered 兜底开关**;若纠偏频率(rollback_count)过高或
  手感回退,可一键回到现状,无不可逆改动。

---

## 1. 方案分层的目标架构(对照现状)

| 层面 | 现状(KH_v1_1_2) | 目标(C2 启用时) |
|---|---|---|
| 本地玩家 | `set_server_rendered(true)`,快照直写位置,不开本地物理 | **不设 server_rendered**,走真实输入本地全量物理(与单机同路径);位置/姿态由本地 sim 产出 |
| 权威锚定 | 无 | 服务器快照带该 role 的 `ack_seq` + `c2`(capture_state 整态);客户端 ring 存每 tick 预测态,权威到则 trim 或 restore+重放未确认输入 |
| 输入 | 每 tick 打包发送,服务器**整队列**应用 | 输入包带单调 `seq`;服务器**每物理 tick/role 恰好消费 1 包**(1:1 同序),回带 ack |
| 服务器快照 | 宿主回调末尾广播(先于子节点步进,天然滞后一拍) | 权威整态须在「该 role 第 N 号输入已被模拟完」之后采样(对齐 ack=N),再广播 |
| 冻结/COUNTDOWN | 服务器清缓冲不喂输入 | 客户端 `InputSource.frozen`(移动+开火全冻结)+ 服务器冻结期不消费也不推 ack,双端 seq 账本不动 |
| 回合/换局 | — | 换局基线(拆砖/清子弹)与快照 ack 对齐,新局 seq 语义延续不漂 |
| 模式覆盖 | 1v1 / 大乱斗 / AI 均 server_rendered | 1v1 与**大乱斗**都切 C2(本地 sim 对 N 人局同样收益);AI 是服务器端 Bot 注入输入,不涉及客户端预测 |
| 网络承载 | NetBus 逐字节不变;扩展走 NetBusExt | 不变。新字段全部加在既有 `send_input`/`snapshot` 的 **dict payload 内**,不改任何 NetBus RPC 签名 |

---

## 2. 前置修复(建议先做,作为 Phase 0)

1. **royale 激光光束链路缺口**:`royale_game.gd` 未订阅 `NetBusExt.local_beam_fired`
   (1v1 `pvp_client.gd:77` 有),而服务器 `match_host._broadcast_beam_fired` 对所有模式广播。
   后果:大乱斗中非射手端看不到别人激光束。C2 上线后本地开火与回滚都依赖「本地光束 + 远端广播」对账,
   此缺口必须先补。做法:在 royale_game 镜像 `_on_beam_fired`(排除自己 role、锚到对应 PlayerReplica)。
2. **输入包构建/快照消费双份代码收敛**:pvp_client 与 royale_game 各自维护输入打包与快照分支,
   已造成 beam 这类漂移。趁 C2 引入,把「构建输入包 + 收快照 + C2 控制器」抽成共享组件
   (如 `Globals/client_match_net.gd`),两个场景共用,杜绝再次分叉。

---

## 3. 移植工作分解

### Phase A — 基础件 + 1v1 接入(开关默认 OFF)

A1. 移植 `PredictionRollback` 纯逻辑控制器(参考 origin/main `core/prediction_rollback.gd`,
    按 KH 目录放 `Globals/c2_rollback.gd`,逻辑与引擎解耦:ring/trim/restore+重放/rollback_count)。
A2. 玩家侧 `capture_state()/restore_state()`:
    - 只覆盖**影响下一帧模拟判定的关键量**(对齐 main"只比影响判定的关键量"):canonical 坐标、速度、
      朝向/瞄准侧、pose(下蹲/冲刺/charge_timer)、跳跃缓冲/土狼/可变高跳标志与计时、攀爬/锁链格锁存、
      水中状态、爆炸击退向量、iframes/倒地标记。
    - **不纳入**(视觉/服务器权威层,避免纠偏跳变):血/氧数值、弹夹/换弹、准星视角、后坐、特效/音效/相机、
      敌人 AI(服务器端才跑)。
    - 逐字段核对清单见 §5(落地时逐个勾)。
A3. 输入侧:为 `InputSource` 增加 `frozen`(冻结移动+开火,供 COUNTDOWN/换局)与
    `apply_replay_packet(pkt)`(回滚重放窗口内按已存 pkt 喂输入,逐帧 1 包)。
A4. 服务器 `match_host`:
    - 每 role 改为「每物理 tick 恰好消费 1 个 FIFO 输入包」,记录 `consumed_seq[role]`;
    - 快照每玩家条目增 `ack_seq` 与 `c2`(该玩家 `capture_state()`),**采样时机 = 该包已模拟完之后**
      (见 §4 时序);散字段保留(副本插值/兼容用);
    - COUNTDOWN/换局冻结期间不消费、不推 ack。
A5. `pvp_client` 接 C2(开关 `LOCAL_PREDICTION_ENABLED`,默认 **false** 先对齐协议与回滚链路):
    - 开=true:不 `set_server_rendered`,本地玩家引擎自步进读真实输入;
      每物理帧(玩家步进前)`note_post_step(prev_seq, capture)` → `reconcile()`;
      发包时 `note_input(seq,pkt)`;收快照取自己 role 的 `ack_seq/c2` → `on_authoritative()`。
    - 关=false:走现有 server_rendered,逐字节行为不变 → 天然 A/B 对照组。
A6. 确定性探针(照 main 思路,放 Tests/):
    - `c2_twin_probe`:capture→restore 往返一致 + 双 sim(服务器步进 vs 本地步进)同输入同步断言;
    - `c2_reconcile_probe`:人为 ack 延迟 + 外部传送事件 → 断言一次收敛、常态 rollback_count≈0;
    - `pvp_match_smoke` 补 ack 推进断言。

### Phase B — 1v1 真机验证并启用

B1. 开关开,自建服 1v1:A/B 对比 server_rendered vs C2(手感/纠偏打点)。打点:每局打印 `rollback_count`。
B2. 验收门槛:回拉次数低、手感无劣化、无蓝屏/脚本错;不达标 → 保持 OFF 并回炉 A 阶段,不阻塞发布。
B3. 通过后在 1v1 默认开。

### Phase C — 大乱斗接入(含 Phase 0 的 beam 修复)

C1. 共享组件后,royale_game 切同一条 C2 路径(本地 sim + rollback),仅角色对应关系不同
    (快照按 role 取自己的 c2;副本仍按各自 role 插值)。
C2. `royale_probe` 全链路 + 多端快照含 ack/c2 断言;大乱斗 N 人 GUI 试玩(机器人/真人混局)。

### Phase D — 收尾与纪律

D1. AGENTS.md/CLAUDE.md 更新:撤销「C2 已放弃」旧记录 → 写明新版 C2 的启用状态、回退方式、
    以及为何首次放弃但新版启用(根因逐条对照:输入边沿/快照错拍/冻结)。
D2. 版本信息面板/分支纪律同步;exe 重导出(embed_pck)后再实测。

---

## 4. 关键时序语义(移植时最容易错,单独成节)

现状 `match_host._physics_process` 顺序:
`清边沿 → 应用缓冲(整队列)→ [子节点玩家 _physics_process 步进] → 子弹裁决 → 光束广播 → 回合推进 → 快照广播`。
问题:C2 权威整态必须满足「snapshot 的 c2 对应 ack_seq 已被模拟」。若快照仍在宿主回调末尾(早于子节点本帧步进),
c2 采到的是上一帧末状态 → ack 与状态错一拍(正是 main 1dd213e 修的坑)。移植要求:

- 方案一(推荐):把玩家步进改为**宿主显式调度**——apply 第 N 包后立刻 `step_player(role)`(调玩家模拟)
  再进下一个 role;全部步进完再做裁决/快照。时序闭环、不依赖树的父先子后顺序,便于断言。
- 方案二:维持树自动步进,但把快照采样移到「所有玩家步进完成后」(如借 `physics_frame` 回调或把玩家移出宿主子树
  使子先父后)。二者择一,并在探针里对「ack 与 c2 严格对齐」加断言。

---

## 5. 确定性核对清单(逐字段勾,防回拉主战场)

玩家模拟入口在 `Scenes/Player/player.gd::_physics_process`(server_rendered=false 分支)与
`climb/combat/swim/weapons` 组件。C2 要求:**相同初始 capture + 相同输入序列 ⇒ 相同输出 capture**。

- [ ] 只用物理 `delta`(固定步长),不读 `process_frame`/墙钟/随机数进入判定;
- [ ] 跳跃:缓冲计时、土狼时间、可变高度(松开跳键)全程输入+状态推导,无外部时间;
- [ ] 冲刺 `is_charge/charge_timer`:start 由 just_pressed 边沿触发(输入包必须保留边沿,现有 FIFO 已保);
- [ ] 攀爬/锁链:进入/脱离判据、`climb_ledge` 碰撞条、上/下行、到顶跳离——逐行审计是否纯状态+输入;
- [ ] 水:入水/没顶判定、游动、防水扣减(数值不参与模拟判定,但 submerged 状态参与物理→纳入 capture);
- [ ] 爆炸击退 `knock_velocity`(服务器 AoE 注入点)→ 纳入 capture;本地 AoE 触发与服务器注入顺序要对齐;
- [ ] 倒地 `downed`:复活/倒地由服务器广播 → 客户端 apply;replay 期间不重复本地触发;
- [ ] 武器:开火判定服务器权威;本地仅视觉(激光/子弹视觉副本),replay 不重放开火伤害;但**换弹/残弹等 UI
      不随 rollback 跳变**(不进 capture);
- [ ] 环面:capture 用 canonical 坐标,纠偏后仍走 `toroidal_*` 归位,禁止裸坐标差;
- [ ] `apply_server_snapshot` 的散字段(血/氧/武器/倒地)仍即时采纳,与 c2 移动态分开,互不覆盖。

---

## 6. 验收与回退

- 开关:1v1 与 royale 各一个启用位(建议先并后分),`const` 便于构建期 A/B。
- 冒烟由用户跑;代理跑 §A6 探针 + 现有 enemy_logic/royale_probe/feedback 回归。
- 回退:任何阶段把开关翻回即回 server_rendered;旧路径代码保留不删,避免大爆炸式重构。

## 7. 范围外/边界

- NetBus 逐字节不变;与原作者新版 worker(其 NetBus 已含 beam 等)混连会静默丢 RPC —— 不在本方案解决,
  联机请两端同版本(现状纪律)。
- 敌人 AI、子弹、爆炸、拆砖仍 100% 服务器权威;客户端只预测「自己」。
- 单机模式、PvPvE 中立鸟(默认关)不受影响。
