# 二、重复的真相源(该改成生成式)

> **本文件从 [`registered-debt.md`](../registered-debt.md) 拆出**（2026-10-13，原文件 888 行 / 126KB 越过了 `CLAUDE.md:5` 那条 64KB 上下文线）。返回索引：[`registered-debt.md`](../registered-debt.md)。
> ★ 文档会过期 —— **任何冲突以源码为准**，读之前先 `grep` 复核；`文件:行号` 与本仓自述一致地会漂。

## 二、重复的真相源(该改成生成式)

**判据**:同一个值必须**抄两处以上**,而且已经有一条守卫盯着它们是否相等 —— 那就是"重复 + 守卫"的永久税。优先改成「单一来源 + 生成器 + `--check`」。

| 重复的东西 | 现在的形态 | 打算怎么改 |
|---|---|---|
| HUD 底板色 `C_PLATE`(黑 0.1) | 唯一源在 `ui/factory/ui_factory.gd`;两个 `.tscn`(`ui/hud/pvp_hud.tscn` / `ui/hud/team_hud.tscn` 的 `Plate`)存**字面量**,由 `ui_palette_single_source_smoke.gd`（已删·2026-10-09） 钉住逐位相等 | 仿 `tools/gen_menu_theme.gd`:由调色板**生成**这两个 stylebox,守卫改成 `--check`。★ **别碰 HUD 视觉**(用户冻结令),只改"这个值是怎么来的"。★ **2026-10-04 补**:别照 `gen_menu_theme.gd` 现在的样子抄 —— 它自己也手抄了 `UiFactory` 的 `64/46`(`tools/gen_menu_theme.gd:218-221` vs `ui_factory.gd:305`),抄它会把同一笔税再交一次;正确姿势是调**生产入口**(`F.call("skin_menu_panel", …)`)再读回 stylebox。★ **2026-10-13 订正**:原写"镜像守卫 `menu_theme_mirror_smoke.gd:190/200` 正是这么取值的" —— **该守卫已删·2026-10-09**(见 `docs/eng/debt/test-cut-2026-10-09.md`)⇒ 这个"正确姿势"今天**没有可读的示例代码**,只能照上面这句描述做 |
| 菜单 Theme `ui/theme/menu_theme.tres` | **生成链已建成**:`tools/gen_menu_theme.gd` 生成 + 镜像守卫(带条数下限,读**生产产出**)。★ **2026-10-04 校正**:称它"**范本**"过头了 —— 它只做到"生成物与守卫对账",没做到"**单一来源**"(上面那条手抄就是缺口)。★★ **2026-10-13 再订正**:那条**镜像守卫也已随 2026-10-09 的削减删除** ⇒ 今天只剩**生成器**、**没有对账守卫**(改生成器与 `.tres` 不再有人替你比对) | —— |
| 编辑器内嵌的敌人注册表 | **已完成,留作范本**:`node level_editor/sync-enemies.js`(+ `--check` 只校验不写盘) | —— |
| `allscript_probe` 的 `SKIP_DIRS` ↔ `path_integrity_allow.txt` 的豁免清单(**R25**;owner 未认领;最后复核 **2026-10-05**) | **两份手工同步的真相源**:`tests/probe/allscript_probe.gd` 的 `SKIP_DIRS`(10 项)与 `tests/path_integrity_allow.txt` 里那 8 条"同上的 SKIP_DIRS 豁免行"。**症状(实证,不是假想)**:2026-10-03 把 `res://_crashtest` 加进 `SKIP_DIRS` 时**漏同步**豁免表 ⇒ 该目录 2026-10-04 被整个删除后,`path_integrity_probe` 一跑就红(`[FAIL] [res://tests/probe/allscript_probe.gd] res://_crashtest`);**是聚合入口第一次真跑那支探针才暴露的**(2026-10-05,`a992a12` 补上了那一行) | **翻案条件 = 改成生成式或单一来源**(任一):① 豁免表由 `SKIP_DIRS` **生成**(或反过来);② 让 `path_integrity_probe` 直接读 `allscript_probe` 的 `SKIP_DIRS` 常量当豁免源(**单一来源**);③ 把 `SKIP_DIRS` 缩到"只列**已存在**的目录",缺项交给 `DirAccess.open == null` 自然跳过。★ 在那之前,**每一次 `SKIP_DIRS` 增删都必须同时改豁免表** —— 而今天**没有任何东西会提醒你**(这就是本条要还的税) |

★ 新代码遇到"同一个值要抄两处"时,**直接上生成式**,别再补一条守卫。
