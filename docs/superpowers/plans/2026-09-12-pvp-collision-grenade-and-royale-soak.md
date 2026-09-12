# 玩家互相碰撞 + 榴弹命中玩家 + 大乱斗压力勘察（实施计划）

> 日期：2026-09-12 · 分支：`refactor/abstraction-batch01`
> 设计：`docs/superpowers/specs/2026-09-12-pvp-collision-grenade-and-royale-soak-design.md`（本计划的判据全在那边）
> 约定：Godot 不在 PATH，用 `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`。
> **测试由用户自跑为主**；本次 D 块是用户点名要我压的，故由我跑并出报告。

---

## 批次 1：玩家互相碰撞（A 块）

| # | 文件 | 改动 | 反证方式 |
|---|---|---|---|
| 1.1 | `scenes/player/player_replica.gd` | `_ready()` 里用现成的 `Player.tscn` 临时实例抄 5 个姿态多边形，建 `StaticBody2D`（layer 2 / mask 0）；入 `player_replica` 组；`apply_snapshot` 按 pose 启停（downed 不动）；改头注释（不再是"纯视觉"） | 把 `collision_layer` 置 0 → 探针 C1-1 必须红 |
| 1.2 | `scenes/pvp_client.gd` | `_ready()`：`_local.collision_mask \|= 2` | 删掉 → C1-2 的回滚判据必须红 |
| 1.3 | `scenes/royale_game.gd` | 同上 | 同上（由 C1-3 源码守卫兜） |
| 1.4 | `tests/replica_ghost_probe.tscn/.gd` | 新建：几何 / C2 回滚 / 源码守卫三条 | 见 C1 的反证列 |

## 批次 2：榴弹命中玩家（B 块）

| # | 文件 | 改动 | 反证方式 |
|---|---|---|---|
| 2.1 | `scenes/weapons/bullet_base.gd` | 新增 `PLAYER_HIT_RADIUS` / `start_player_fuse()` / `_check_player_contact()`；`_physics_process` 里在引信未启动时检测 | 把半径改 0 → C2 断言必须红 |
| 2.2 | `server/match_host.gd` | `HIT_RADIUS` 改引用 `BulletBase.PLAYER_HIT_RADIUS`；`explodes` 分支改走 `_adjudicate_grenade` + `_grenade_direct_hit` | 恢复 `continue` → 直接伤/短引信断言必须红 |
| 2.3 | `tests/grenade_smoke.gd` | 加"碰玩家起 0.15s"、"长引信不缩短但直接伤照结算"、"视觉副本也起短引信"三条 | 各自见上 |

## 批次 3：文档回写

| # | 文件 | 改动 |
|---|---|---|
| 3.1 | `docs/superpowers/plans/2026-09-11-royale-netplay-1v1-alignment.md` | 修正 §3.2b 的 `collision_mask = 5 已含 2` 事实错误；§2 差距表"对手副本"行标注幽灵体已提前落地 |
| 3.2 | `CLAUDE.md` | §武器与子弹加榴弹对玩家；§网络与 PvP 加幽灵碰撞体；测试段加两个新探针；副本描述"纯视觉"改为"纯视觉 + 幽灵碰撞体" |

## 批次 4：大乱斗压力勘察（D 块）

| # | 文件 | 改动 |
|---|---|---|
| 4.1 | `tests/soak_bot_input.gd` | 新建：`extends InputSource` 的脚本机器人（无 `class_name`，走 preload） |
| 4.2 | `tests/royale_soak_probe.tscn/.gd` | 新建：大厅/裁判 + N 客户端全链路 + 埋点写结果文件 |
| 4.3 | `tests/royale_soak_probe.sh` | 新建：收尾 `taskkill` + `kill_port`（Windows 下 bash `kill` 杀不死 headless Godot，会留僵尸占 7777） |
| 4.4 | `docs/royale-soak-2026-09-12.md` | 实测数字 + 源码审计定位 + 分级（崩溃 / 大卡顿 / 轻微） |
| 4.5 | `tests/royale_hud_cost_probe.tscn/.gd` | 新建（执行期追加）：单独量 `RoyaleHud._on_round_state` 重建耗时，把"每秒卡一下"从猜测变成数字 |
| 4.6 | `tests/grenade_player_hit_probe.tscn/.gd` | 新建（执行期追加）：钉 `MatchHost._adjudicate_grenade` —— `-s` 的 `grenade_smoke` 只够测引信那半，权威直接伤此前零覆盖 |

### 4.4 报告必须包含的三栏边界说明（照设计 §D4 抄）

- headless 无渲染 → 量不到画面成本；
- 输入积压在 localhost 量不到（大乱斗输入包无 `seq`），只出代码级机制说明；
- 崩溃判据 = 客户端结果文件缺失 / worker 进程消失，不是"没看见报错"。

## 顺序与依赖

批次 1 与批次 2 相互独立，可并行；批次 3 在 1/2 落地后写；批次 4 独立（跑之前先确认 7777 空闲）。

## 批次 5：勘察发现的「能修的」修复（用户指示「能修的先修了」）

| # | 文件 | 改动 | 守卫 | 反证实跑 |
|---|---|---|---|---|
| 5.1 | `scenes/royale_hud.gd` | 排行榜复用行、只改文字（不再每秒重建 N 个 Label 与 layout） | `royale_hud_cost_probe`：行 instance_id 跨更新不变 + 文字仍跟数据走 | 改回"每次重建"→ 红 |
| 5.2 | `scenes/royale_game.gd` | MATCH_OVER 当场销毁暂停菜单 + 定时器 lambda 补 `is_inside_tree()` 早退 | `kh_l6_probe` 第 9b 条不变量 | 两处改回原样 → 红 |
| 5.3 | `server/match_host.gd` | `_seen_bullets` 每帧按在场子弹剪枝 | `match_host_hygiene_probe`（60 轮生成/销毁） | 去掉剪枝 → 累积到 63，红 |
| 5.4 | `server/room_manager.gd` | `_flush_royale_state` 发送前再判 `in_match`；`royale_leave` 同款守卫 | 压测数 `channel 0` 次数 | 2 人 1→**0** ✅；4 人 7→3（**残余已排除大厅，未定位**） |

**明确不修**（写进勘察报告 §5，理由是该改联机模型、属 2026-09-11 那份对齐计划）：
快照 O(N²)/超 MTU 分片（§3.2）、输入队列无上限（§3.3）。
**也不修**开局副本集中建（§3.7，收益一次性、风险是行为变化）。

## 已知需要用户裁决的悬留项

无。用户已就四个决策点给出裁定（两端都加 / 直接伤 5 + 短引信 / 视觉副本自行判定 / 起大厅+worker 压一局）。
D 块若报出**崩溃级**问题，另开一问。
