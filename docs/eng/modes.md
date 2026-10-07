# 多人对战模式与结算系统 (1v1 / 3v3 团队赛 / 大乱斗 / 结算面板)

> 本文档规范 Cyber Ruins (CyR) 的多人玩法模式规则、阵营碰撞、计分体系与结算流程。
> 返回索引：[`CLAUDE.md`](../../CLAUDE.md)。

---

## 一、对战模式概览

游戏目前支持三种多人对战模式：
1. **1v1 经典决斗 (Duel)**：双人单挑，回合制积分，率先达到 5 次击杀或赢得指定局数者胜。
2. **3v3 团队对抗 (Team Deathmatch)**：两队各 3 人对抗，支持友军伤害规避、助攻判定与惩罚分机制。
3. **大乱斗模式 (Royale)**：支持 2~8 名玩家自由混战（支持 AI 玩家补位），在 300 秒限时内按总击杀数决出胜负。

---

## 二、3v3 团队模式设计规范

### 1. 服务端配置与队伍映射
- 启动参数：`--worker --team --port P --roles r1,r2,... --teams t1,t2,...`。
- 角色与队伍为显式等长映射（`teams[i]` 对应 `roles[i]`），队伍信息随 `match_sync` 下发。严禁通过角色 ID 的奇偶性推导队伍。
- 满员判定以队伍表中已分配玩家数量为准，两队人数对等时才允许开局。

### 2. 团队伤害与贯穿机制
- **投射物穿透友军**：常规子弹与激光武器穿透己方队友，不会被队友身躯阻挡，穿过队友后可正常命中敌方（参见 `MatchCombat._adjudicate_bullets` 与 `LaserWeaponBase._damage_path_targets`）。
- **爆炸范围伤害判定**：爆炸范围伤害（AoE）会对友军生效并造成伤害。
- **友军免伤判据**：通过 `MatchState.same_team(role_a, role_b)` 判定。若任一角色队伍编号为 0（未划分），判为非同一队伍，防止 1v1 模式中被误判为友军。

### 3. 分队物理碰撞分层 (`TeamHost._apply_team_layers` & `team_game._apply_team_collision`)
为实现“队友间不发生物理阻挡推挤，但敌方互相阻挡”的物理交互：
- 队伍 1 物理碰撞层为默认角色层；队伍 2 物理碰撞层为 `TeamHost.TEAM_ENEMY_LAYER`（第 16 层）。
- 各客户端的 `PlayerReplica` 幽灵阻挡体根据其代表玩家的队伍动态配置碰撞层（`layer`），并将 `mask` 设为 0。
- 本地角色将本方队伍的碰撞层从检测掩码（`collision_mask`）中剔除，将敌方队伍碰撞层纳入检测掩码中，确保预测步进时仅与敌方发生物理阻挡。

### 4. 助攻、自伤与惩罚分计分体系
- **助攻判定**：受害者倒地前 3 秒时间窗口内（`ATTRIB_WINDOW`），除最终击杀者外，所有对受害者造成过伤害的同队攻击者均计 1 次助攻（`assists += 1`）。
- **自伤记录**：玩家被自身武器或爆炸击中时，通过专用通道记录自伤点数（`CombatFeedback.note_self_hit`）。
- **惩罚分公式**：在 `core/sim/score_rules.gd` 中统一计算：
  $$\text{penalty} = \frac{\text{team\_damage} + \text{self\_damage}}{5} + \text{team\_kills} \times 100$$
  惩罚分从最终战斗评分（`kscore`）中扣除。

---

## 三、大乱斗模式 (Royale) 架构

### 1. 独立宿主与生命周期 (`server/hosts/royale_host.gd`)
- 继承自 `MatchHost`，统一覆写生成点计算、胜者判定、回合流转与击杀归因。
- 开局等待机制：若已连接玩家 $\ge 2$ 人且等待 20 秒仍未满员，降级以当前人数直接开局；未满员角色名额可指定由 AI 补位（`AINavigator`）。

### 2. 动态出生点与复活选择 (`core/sim/spawn_picker.gd`)
- **开局散点分布**：所有玩家出生点之间的环面欧氏距离须满足 $\ge 15$ 格（`SPAWN_CLEARANCE`）。
- **动态安全复活点**：玩家阵亡后 2 秒复活，复活算法三级分层筛选：
  1. 候选点需满足头顶净空 2 格、左右通畅，且所在连通区域面积达到阈值（`OPEN_AREA_MIN`），且与所有存活玩家保持 $\ge 8$ 格安全距离（`RESPAWN_CLEARANCE`）。
  2. 若无完全符合候选点，降级选择连通区域合格的常规地面点。
  3. 最终保底：连通区域 $\ge 2$ 格的任意非孤立地面格。

---

## 四、对战结果结算系统 (`MatchResult`)

### 1. 架构解耦
- **通用展示层 (`ui/screens/match_result.gd`)**：继承 `CanvasLayer`，位于高层级（Layer 150），负责通用列表渲染、动画排版与退出交互。
- **数据适配层 (`ui/screens/match_result_payload.gd`)**：针对三种模式分别提供适配器：
  - `for_duel`：展示击杀（Kills）、阵亡（Deaths）、造成伤害（Dealt）、承受伤害（Taken）、战斗评分（ACS）。
  - `for_royale`：展示击杀、阵亡、造成伤害、承受伤害。
  - `for_team`：展示击杀、阵亡、助攻（Assists）、造成伤害、承受伤害、战斗评分（ACS）。

### 2. 战斗评分与平均分公式 (`core/sim/score_rules.gd`)
统一计分模型：
$$\text{kscore} = \text{Kills} \times 100 + \text{Assists} \times 50 + \frac{\text{Dealt}}{5} - \text{Deaths} \times 50 - \text{Penalty}$$
$$\text{acs} = \frac{\text{kscore}}{\text{Rounds}}$$

### 3. 场景迁移安全性
结算界面触发返回主菜单时，统一调用 `Level0.safe_change_scene` 执行异步析构，避免同步卸载大型复杂物理碰撞世界时触发底层段错误。

---

## 五、核心自动化测试用例
- `tests/smoke/score_rules_smoke.gd`：计分与评分公式纯逻辑单元测试。
- `tests/smoke/match_result_payload_smoke.gd`：结算载荷适配与数据字段对齐测试。
- `tests/probe/team_table_probe.tscn`：3v3 队伍映射与友军伤害判定集成测试。
- `tests/probe/laser_team_probe.tscn`：激光武器穿透友军并命中敌方测试。
- `tests/probe/stats_delivery_probe.tscn`：三模式结算统计广播与分发验证。
- `tests/probe/match_result_probe.tscn`：结算 UI 场景渲染与排版验证。
