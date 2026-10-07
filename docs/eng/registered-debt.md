# 已知技术缺陷与待重构清单 (Registered Technical Debt)

> 本文档统一记录项目中已知的不稳定测试用例、未完全定位的偶发问题以及待统一的数据源清单。
> 返回索引：[`CLAUDE.md`](../../CLAUDE.md)。
> 关联文档：[`tests.md`](tests.md) §测试体系 · [`world.md`](world.md) §环面拓扑。

---

## 一、已知不稳定或待排查测试用例

下列用例存在已知环境依赖或未修复缺陷，**严禁将其作为版本发布或功能验收的唯一通过依据**：

| 测试用例 | 现象与症状 | 保留原因与当前认知 | 预期关闭条件 |
|---|---|---|---|
| [`tests/probe/team_match_probe.sh`](../../tests/probe/team_match_probe.sh) | 执行失败且诊断日志存在矛盾：探针报告“等待 3v3 房间超时”，但同次运行的客户端日志显示房间已建立且客户端已进入等待室。 | 尚未彻底定位竞争条件：探针监听端口 29200，但客户端可能在特定网络生命周期中未正确完成全部握手流程。 | 定位端口竞争与握手竞态并修复，使真链路测试稳定通过。 |
| [`tests/probe/ground_net_probe.tscn`](../../tests/probe/ground_net_probe.tscn) | 存在随机抖动：机器人角色在随机加载的地图地形上偶发卡死。 | 抖动源于每次进程启动时随机挑选地图（参见 [`world.md`](world.md)）；测试脚本本身设计用于观察趋势。 | 为该测试固定基准地图（Pinned Map），消除随机地形阻挡差异。 |
| [`tests/probe/brawl_rollback_probe.tscn`](../../tests/probe/brawl_rollback_probe.tscn) | 贴身对抗测试用例在并发实体数 $N \ge 4$ 时读数存在波动，边界容差下存在偶发漏报。 | 保留用于监控近身缠斗状态下的预测回滚收敛趋势。 | 优化高并发实体下的容差收集算法，消除读数抖动。 |

---

## 二、单一真实来源 (Single Source of Truth) 优化项

针对需要多处手动同步硬编码的字段，逐步推进“单一来源定义 + 代码生成 / 静态校验”模式：

| 数据项 | 当前维护现状 | 规划优化方案 |
|---|---|---|
| HUD 统一底板色 `C_PLATE`（半透明黑） | 唯一定义于 `ui/factory/ui_factory.gd`；场景文件（`ui/hud/pvp_hud.tscn` 与 `ui/hud/team_hud.tscn`）中包含硬编码值，由 `tests/smoke/ui_palette_single_source_smoke.gd` 保证一致。 | 参考 `tools/gen_menu_theme.gd`，由调色板统一生成 StyleBox 资源，测试转为 `--check` 静态检查。 |
| 菜单主题样式 `ui/theme/menu_theme.tres` | **已完成优化**：由 `tools/gen_menu_theme.gd` 脚本根据调色板集中生成，配有镜像校验用例。 | 已成为工程范本。 |
| 编辑器内置敌人注册表 | **已完成优化**：通过 `node level_editor/sync-enemies.js` 统一从 `data/enemies.json` 单向生成。 | 已成为工程范本。 |

---

## 三、技术债清偿与核销流程

1. **缺陷修复**：完成代码修复后，在相同运行环境和参数下连续执行至少 2 次测试，确认结果稳定。
2. **文档同步**：从本清单中移除已修复条目，并在相应模块文档中更新其最新保证范围与边界。
