# docs/archive —— 历史快照（不是真相源）

> **本目录是历史快照，只用于追溯当时的结论；任何当前事实以源码与 [`docs/eng/`](../eng/) 为准；不要把它当依据引用、也不要当成现行状态。**
> 里面有过期数值、已改掉的协议、已删除的文件路径和已废弃的流程；照它改代码会改错。新写的结论一律进 [`docs/eng/`](../eng/)，不要往这里补。
> 归档日期统一为 **2026-11-01**（迁入本目录的日期，不是文档写作日期）。除路径外，归档文件内容**未改写**；文件间的相对链接已按新位置重算，以便需要时仍能点开。
> 本目录带 `.gdignore`：归档里的历史 `.gd` / `.tscn` 取图驱动**不参与** Godot 资源导入；`tools/check_naming.py` 的规则 C 也**刻意不覆盖**归档目录（历史路径是记录，不是错误）。

## 归档清单与当前替代真相源

| 归档路径 | 原路径 | 归档日期 | 当前替代真相源（查现状读这些，不读归档） |
|---|---|---|---|
| [`audit/2026-10-26/`](audit/2026-10-26/00-总览与结论.md)（九项考察） | `docs/audit/2026-10-26/` | 2026-11-01 | 已落地为代码 + 逐批登记：[`docs/eng/registered-debt.md`](../eng/registered-debt.md) §十二（联机拆砖粒子）/ §十三（碰撞箱与受击判定分离）/ §十四（子弹最小破坏单位）/ §十五（时间域解耦 + 命中手感 P0）；域现状见 [`player.md`](../eng/player.md) / [`weapons.md`](../eng/weapons.md) / [`world.md`](../eng/world.md) / [`netcode-snapshots.md`](../eng/netcode-snapshots.md)。自动跳跃的现行口径见 [`player.md`](../eng/player.md) 与 §四十九 |
| [`audit/2026-10-27-ui/`](audit/2026-10-27-ui/00-总览与结论.md)（UI 排版审计 P0/P1） | `docs/audit/2026-10-27-ui/` | 2026-11-01 | P0/P1 结论已落成代码：[`ui/components/header_strip_panel.tscn`](../../ui/components/header_strip_panel.tscn)（+`.gd`）、`ui/screens/*.tscn`、[`ui/theme/menu_theme.tres`](../../ui/theme/menu_theme.tres)（由 [`tools/gen_menu_theme.gd`](../../tools/gen_menu_theme.gd) 生成）；版式/组件契约的现行口径 = [`docs/eng/ui.md`](../eng/ui.md)。截图与取图驱动是一次性证据，不再维护 |
| [`audit/2026-10-30-联机验证审计.md`](audit/2026-10-30-联机验证审计.md)（缺什么 / 滥用什么） | `docs/audit/2026-10-30-联机验证审计.md` | 2026-11-01 | 处置已落地：A1 删 `pvp_room_smoke` → [`registered-debt.md`](../eng/registered-debt.md) §二十七；真链路首跑与 BUG-25 → §三十七。测试面现行口径 = [`tests.md`](../eng/tests.md) / [`test-economy.md`](../eng/test-economy.md) / [`tests/README.md`](../../tests/README.md)。未落地的 A2/A3 属登记债（§二十三 / §二十五），**不是**现行契约 |
| [`audit/2026-10-30-netplay/`](audit/2026-10-30-netplay/00-总览与结论.md)（联机模块审查：总览 / 代码审查 / bug 台账） | `docs/audit/2026-10-30-netplay/` | 2026-11-01 | 台账 24 条已全部修完并逐批登记在 [`docs/eng/registered-debt.md`](../eng/registered-debt.md)：§二十五（审查登记）/ §二十六（B1）/ §二十九（B2）/ §三十（B3）/ §三十一（B4 协议批 v7）/ §三十二 / §三十三（B5/B6 收尾）/ §三十四（B8）。联机现状见 [`netplay.md`](../eng/netplay.md)、[`netplay-rooms.md`](../eng/netplay-rooms.md)、[`netplay-reconnect.md`](../eng/netplay-reconnect.md) 与 `docs/eng/netcode-*.md` |
| [`superpowers/plans/2026-10-24-packet-codec-handpack.md`](superpowers/plans/2026-10-24-packet-codec-handpack.md)（包体手打包 / 编码器重写计划） | `docs/superpowers/plans/2026-10-24-packet-codec-handpack.md` | 2026-11-01 | 已落地为 [`core/net/net_codec.gd`](../../core/net/net_codec.gd)（现行 `PROTO_VERSION = 8`）与 [`core/net/input_wire.gd`](../../core/net/input_wire.gd)；输入上行现行口径 = [`netcode-input-uplink.md`](../eng/netcode-input-uplink.md)；字节/量化误差 = [`netcode-delta-and-quantization-details.md`](../eng/netcode-delta-and-quantization-details.md) §6；后续改动登记 §十七 / §十八 / §五十一 |
| [`superpowers/plans/2026-10-27-ui-components.md`](superpowers/plans/2026-10-27-ui-components.md)（UI 组件场景化 P1 计划） | `docs/superpowers/plans/2026-10-27-ui-components.md` | 2026-11-01 | 已落地为 `ui/components/` + `ui/screens/*.tscn` + `ui/theme/`（主题 `.tres` 由生成器产出）；组件契约 / 菜单语汇 / 标题带规则的现行口径 = [`docs/eng/ui.md`](../eng/ui.md) |
| [`superpowers/plans/2026-10-28-hit-event-align.md`](superpowers/plans/2026-10-28-hit-event-align.md)（受击事件时刻对齐计划） | `docs/superpowers/plans/2026-10-28-hit-event-align.md` | 2026-11-01 | 已落地：[`core/sim/hit_lag_history.gd`](../../core/sim/hit_lag_history.gd) + `server/match/match_combat.gd` 的 `_replay_hurt_rect`；命中回放现行口径 = [`netcode-snapshots.md`](../eng/netcode-snapshots.md) §2.1；边界 = §十五 / §二十三 |
| [`superpowers/specs/2026-10-27-ui-components-design.md`](superpowers/specs/2026-10-27-ui-components-design.md)（UI 组件 P1 设计） | `docs/superpowers/specs/2026-10-27-ui-components-design.md` | 2026-11-01 | 同上一行：设计已落成 `ui/` 场景化组件；现行组件契约与主题单一来源 = [`docs/eng/ui.md`](../eng/ui.md) |

## 不算「当前口径」的几条（读归档时最容易踩的坑）

- 2026-10-30 前后文档里的 **30Hz 输入发包 / 一包两条记录 / `INPUT_BATCH_TICKS = 2` / `PROTO_VERSION 7`** 全部过期：现状是 **输入记录 60Hz、发包 60Hz（一包一条记录，28 B/包）**，`INPUT_BATCH_TICKS := 1`，`PROTO_VERSION := 8`。见 [`netcode-input-uplink.md`](../eng/netcode-input-uplink.md) 与 [`registered-debt.md`](../eng/registered-debt.md) §五十一。
- 归档里的测试计数（`RUN_ALL OK(n runs / m gated-assertions)`、`ALLSCRIPT: OK(N)`）都是**当时**的读数；现行以 `bash tests/run_all.sh --list` 与 [`tests/README.md`](../../tests/README.md) 为准。
- 归档里的「计划保存到 `docs/superpowers/...`」「证据归档到 `docs/audit/...`」只是当时的路径记录；这些文件现在都在本目录下。
