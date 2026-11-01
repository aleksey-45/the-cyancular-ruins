# 联机测试 Bot 初步实现 Plan(先跑通一条真实客户端链路)

> **写于 2026-11-01。只出计划,未开始实现。** 依据 [`docs/superpowers/specs/2026-10-30-联机测试bot-design.md`](../specs/2026-10-30-联机测试bot-design.md) 的修订版,只做**最小切片**:一个真实客户端 Bot 在 1v1 真链路里自己进局、移动、交火、被击杀 / 复活,并在日志里说清它知道什么、为什么这么做。
>
> ★ 这不是完整智能的实现计划。阶段 1 跑通后再逐阶段补导航、战术、武器与场景编排。本计划刻意简单:少量文件、少量任务、每步可停。
>
> **进度(2026-11-01):** B1 / B2 的核心代码已落盘(`tests/harness/bot/` 三个模块 + `tests/smoke/bot_brain_smoke.gd`),**尚未跑验证**;B0 接线与 B3 真实客户端跑通待做。

**Goal:** 证明“Bot 能作为真实客户端把一段 1v1 对局玩起来,且感知受限、行为可解释、失败可归因”。

**Architecture(最小):**

```
真客户端进程(1v1 pvp_game)
  └─ BotWatcher(root 级,跨换场存活)
       ├─ 每物理帧采样 → Observation[]      (只读副本 + 摄像机 + 小地图规则)
       ├─ BotBrain.decide(obs) → Intent      (纯逻辑,可 -s 测)
       └─ 写 BotInput(PlayerInput 子类)      (全部读口实现)
```

**Tech Stack:** Godot 4.7.1 标准版 / GDScript。

**必读:**
- [`scenes/pvp_match_client.gd`](../../../scenes/pvp_match_client.gd)(输入采样 / C2 预测 / 上行组合件)
- [`core/net/player_input.gd`](../../../core/net/player_input.gd)(输入接口与 `frozen` 契约)
- [`tests/harness/team_match_watcher.gd`](../../harness/team_match_watcher.gd)+ [`tests/harness/team_bot_input.gd`](../../harness/team_bot_input.gd)(既有真链路观察者与哑手柄形态)
- [`ui/hud/minimap.gd`](../../../ui/hud/minimap.gd)(雷达半径与筛选规则)
- [`core/present/camera_2d.gd`](../../../core/present/camera_2d.gd)(连续空间跟随 / 缩放 / 前瞻)
- [`core/sim/step_jump.gd`](../../../core/sim/step_jump.gd)(≤1 格台阶已自动处理)

---

## Global Constraints

- 判据一律 **grep 判词文本**;退出码不是判据。
- 跑测试先问用户;任何占 7777 的步骤先查 `lobby_alive`;真链路批前后 Godot 进程必须为空。
- 逐文件 `git add`;提交信息 `type(scope): 中文一句话`;推送先问用户。
- 档位:本切片涉及输入注入与真实客户端,按**档 3(承重面)**对待——先跑通、再补守卫、逐任务评审;但**不新增无意义冒烟**,守卫只挡真实会发生的缺陷。
- Bot 手柄必须实现**全部**读口(含带参 `is_action_pressed("attack"/"up"/"down")`、三个开火边沿),否则本地能动、服务器侧不动且 C2 每帧回滚(见 `team_bot_input.gd` 文件头教训)。
- 决策层不得直接持有远端节点 / 原始快照 / 服务器对象;只消费 `Observation`。

---

## 任务(5 步,每步可停)

### B0 · 可行性确认:1v1 本地玩家能否替换输入源

**问题:** `pvp_game.gd` 的本地玩家默认是 `LocalInputSource`;能否在运行时换成 Bot 手柄,且 C2 预测 / 上行包 / 服务器重放仍然一致?

**做什么:**
- [ ] `grep` 确认本地玩家的 `set_input_source` 调用点与 `PlayerInput.Kind` 分支(移动/瞄准/开火是否全走接口)。
- [ ] 写一个**临时**最小手柄(复制 `team_bot_input.gd` 形状),在 headless 单机 1v1 场景里注入:只做“左走 200 帧 + 开火 60 帧”。
- [ ] 观察:C2 回滚计数是否暴涨、服务器侧是否真的收到移动/开火(看 worker 日志)。
- [ ] 把结论写回本计划(可行 / 需要改哪个装配点)。

**验收:** 明确回答“注入点在哪、是否可逆、有无协议面副作用”;不满足就停,先修装配点。

**不做:** 不做决策;不改协议。

---

### B1 · 观察层最小集(纯逻辑)

**做什么:**
- [x] 新 `tests/harness/bot/bot_observation.gd`(RefCounted,无 `class_name`;由 watcher preload)。
- [x] 三个来源各一个采样函数(主画面 / 雷达 / 记忆;本实现是 `in_view` / `in_radar` / `build`)。
- [x] 输出统一 `Observation` 字典:身份 / 来源 / 敌我 / 位置 / 时间 / 不确定性 / 已观察动作。
- [x] 守卫:纯 `-s` 冒烟(`tests/smoke/bot_brain_smoke.gd`)带 `EXPECTED_CHECKS` 条数闸。

**验收:** 冒烟 `ALL-OK`(待跑);变异(把雷达半径判据写错 / 记忆永不过期)⇒ 红。

---

### B2 · 决策最小集(纯逻辑)

**做什么:**
- [x] 新 `tests/harness/bot/bot_brain.gd`(RefCounted)。
- [x] 主树最小形态(不可行动 / 搜索 / 交战;紧急与脱困先留空壳)。
- [x] 战术评分最小版:距离 + 主画面来源加成;队友支援先留接口不实现。
- [x] 滞回:新目标评分需超过 `SWITCH_MARGIN` 才切换。
- [x] 输出 `Intent`:移动轴 / 是否跳 / 瞄准 / 是否开火 / 换弹 / 切枪 / 拾取 / reason。
- [x] 守卫:`-s` 冒烟用构造局面断言——多敌人选近者、记忆不开火、无敌人走搜索、卡住会跳。

**验收:** 冒烟 `ALL-OK`(待跑);变异(去掉滞回 / 忽略雷达来源)⇒ 红。

---

### B3 · 手柄与接线(真实客户端)

**做什么:**
- [x] 新 `tests/harness/bot/bot_input.gd`:真实 `PlayerInput` 子类,实现全部读口与边沿(参照 `team_bot_input.gd`),`source_kind()` 返回 `Kind.AI`。
- [ ] 新 `tests/harness/bot/bot_watcher.gd`:挂 root、跨换场存活;每物理帧:采样观察 → `bot_brain.decide` → 写手柄;`_release()` 清空输入。
- [ ] 接线**不改产品代码**:探针场景挂真 `mp_lobby.tscn` 驱动建房 / 加入 / 开局,换场后 root 上的 watcher 接管真 `pvp_game`(与 `team_match_watcher.gd` 同一范式)。
- [ ] 证据日志:每 0.5s 一行 JSON——观察到的角色数 / 来源分布 / 当前意图 / 放弃原因 / 距上次推进时长。

**验收:** headless 1v1 真链路里,Bot 自己进局、移动、开火;日志能回答“它看到了谁、为什么开火”。

**不做:** 不接 3v3 / 大乱斗;不做拟人化;不在 `pvp_game` / `PvpMatchClient` 里加 Bot 分支。

---

### B4 · 判定分离(先跑通再谈守卫)

**做什么:**
- [ ] 明确“Bot 自己的日志”与“裁判读的证据”分开:裁判只读客户端日志 + worker 日志(可加 `--diag`),不看 Bot 内部状态当结论。
- [ ] 定义本切片的最小判据:进局成功 / 有移动位移 / 有开火命中事件 / 死亡后按规则复活 / 无持续回滚风暴。
- [ ] 失败分类输出:`bot_nav_failed` / `bot_missing_input` / `client_server_divergence` / `match_abnormal_exit`。
- [ ] 跑两次同配置(噪声与信号分不清时同配置跑两次),结论附日志位置与关键行。

**验收:** 一次完整 1v1 跑出“通过 / 失败 + 类别 + 日志证据”;失败能落到具体类别。

**不做:** 不把本切片结论包装成完整端到端守卫。

---

## 本切片完成标准

- 一个真实客户端 Bot 在 1v1 真链路里自主完成:进局 → 移动 → 交火 → 死亡 → 复活 → 继续。
- 观察层可证明“窗口外雷达内只获得雷达信息”。
- 决策可解释:日志能回答“为什么打这个、为什么放弃上一个”。
- 失败可归因:能区分 Bot 自身失败与联机异常。
- 结论附日志位置与关键行;同配置跑两次。

## 明确不做

- 不做 3v3 / 大乱斗接入(留到下一计划)。
- 不做攀爬 / 跨接缝完整导航(下一计划)。
- 不做队友支援评分(下一计划)。
- 不新增成批冒烟;守卫只挡本切片真实发生的缺陷。
- 不宣称网络对局完全确定性复现。
