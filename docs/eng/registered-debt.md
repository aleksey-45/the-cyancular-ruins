# 已知边界与已知红

> 一行一项:**现象 + 规避 / 影响面**。销掉即删行。跑法与判据见 [`tests.md`](tests.md),取舍见 [`test-economy.md`](test-economy.md)。

## 已知红

- `tests/probe/team_match_probe.sh` —— 整跑判 `FAIL`,不可当 3v3 的端到端守卫;影响面 = 3v3 只能靠该支日志 + 人工试玩。
- `tests/known_red.txt` 基线当前 **0 条** —— 任何红都算新红,`run_all.sh` 退出码非 0。

## 已知边界

- [`tests/harness/menu_autotest.gd`](../../tests/harness/menu_autotest.gd) 被产品代码 [`scenes/main_menu.gd`](../../scenes/main_menu.gd) `load()`(菜单的 `-- --autotest-*` 钩子)—— 改名 / 删除 / 移动它,必须同批改产品代码,否则钩子失效。
- [`tools/gen_menu_theme.gd`](../../tools/gen_menu_theme.gd) 手抄 `UiFactory.menu_panel()` 的 64/46,镜像守卫用同一对字面量 —— 改 `menu_panel()` 默认值**不会红**,生成物与守卫一起静默用旧值;改默认值必须两处同改。
- 默认批多数支没有 `EXPECTED_CHECKS` 条数闸(`run_all.sh` 表里 `GATE` 栏为 `-`)—— 单支 `OK` 只证明"没有失败输出",不证明每条断言都跑过。
- [`tests/run_all.sh`](../../tests/run_all.sh) 的承重安全检查只读整行注释以外的文本,看不见经 helper 间接开端口 / 拉子进程的形状 —— 新增这类支必须手工进 `EXCLUDED`。
- [`tests/run_real.sh`](../../tests/run_real.sh) 的 R20 锁心跳只在**支间**刷新(`LOCK_STALE_SECS` = 600s)—— 单支预算调到 >600s 会把正在跑的批判成陈旧、锁失效。
- [`tests/probe/path_integrity_probe.gd`](../../tests/probe/path_integrity_probe.gd) 在 Windows 上不区分大小写 —— 路径大小写写错会通过(导出成 `.pck` 后区分大小写);它只答"有没有",不答"大小写对不对"。
- [`tests/probe/snapshot_size_probe.gd`](../../tests/probe/snapshot_size_probe.gd) 的世界包分片悬崖在 N≈29（`7+29×48=1399 B < 1400 B MTU`）—— 超 MTU 即 unreliable 分片，丢一片 = 整帧丢。

## 九、2026-10-24 默认批激进削减（20 → 6）—— **删了什么 = 欠了什么**

> 仓主裁决：默认批只留 4 支承重/元闸，其余全删；重建 2 支编码面守卫。真链路批**未动**。
> 此节是**覆盖缺口清单**（不是"已修好"）；翻案条件 = 下列任一面再次改坏且没有其它守卫能抓到。

**保留**：`allscript_probe`（全仓 `.gd` 加载 + `EXPECTED_SCRIPTS` 174）· `path_integrity_probe`（`res://` 字面量存在性）· `snapshot_size_probe`（线格式体积/最坏包/容量）· `rollback_fidelity_probe`（C2 回放保真）。
**新建**：`net_wire_smoke`（三 kind 版本/种类头 · 坏包一律空 · 三 kind 往返 · `INPUT_SCHEMA`↔`pack_record` 对齐）· `input_queue_smoke`（轴收口 · 有界+边沿 · 回复力 · 上限钳位）。两支都带 `EXPECTED_CHECKS`。

**删除的 16 支 → 各自留下的缺口**（逐条都曾挡过真实缺陷）：

| 删掉 | 原来挡什么 | 现在的覆盖 |
|---|---|---|
| `mode_defs` / `mode_options` / `mode_room_rules` | 模式常量/选项键/房间规则表的单一来源（3v3 曾上发 1v1 的禁用武器；16 人上限只改了一半） | **零守卫**，只能靠联机场景行为/试玩 |
| `mode_context` | worker argv 解析边界（`--` 之后、`--roles` 等长、role 0/17） | **零守卫** |
| `room_registry` | 同号跨模式不串、三表合一、`started`↔`in_match` 双向别名 | **零守卫** |
| `rpc_channel_contract` | 通道表 ↔ `@rpc` 声明文本对账（含 `beam_fired` 重名集合） | **零守卫**，见 [`netplay-rpc-channels.md`](netplay-rpc-channels.md) 已改口 |
| `server_input_sanitize` | 轴钳位 / 队列有界 / 丢包保边沿 / 抖动上限 | **已由 `input_queue_smoke` 接管**（24 条按 4 类压缩，覆盖面按类别等价；逐值细目不再断言） |
| `network_input` | `get_axis("up","down")` 由 held 推导（梯子回拉根因） | **零守卫** |
| `net_diag` / `ops_log` | `--diag` 开关零成本与落盘、审计文件命名/保留策略 | **零守卫** |
| `server_status` | 服务端面板数据层（端口三态/房间快照纯判据） | **零守卫** |
| `resync_world` | 重连补态「先还原基线、再应用 destroyed」 | **零守卫**，见 [`netplay-reconnect.md`](netplay-reconnect.md) 已改口 |
| `tile_collision` | 可破坏砖碰撞逐 16px 子格与游戏规则一致 | **零守卫** |
| `map_catalog` / `map_format_v4` | 地图目录/选图路径校验；cyrm v4 编解码/CRC 往返 | **零守卫**（存档/地图格式面） |
| `wrap_probe` | 鸟跟随玩家跨接缝回绕 | **零守卫**（原支本就零断言 = D2，删掉不减少保证） |

**未动**：真链路 6 支（`pvp_match` / `pvp_room` / `rejoin` / `soak` / `role_cap` / `team_match`），其中 `team_match` 仍登记为不可信（见本文件「已知红」）。
