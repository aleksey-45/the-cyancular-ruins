# 注释瘦身落地批（2026-10-13）

> **这份文档是什么**：接 [`2026-10-13 审计记录`](2026-10-13-comment-doc-and-native-audit.md) 的**执行记录** —— 审计之后做了什么、留了什么证据、还剩什么。
> **为什么单独一份**：审计记录的性质是"一次性快照"（它自己的规则是"单文件不超过 64KB 上下文线"）；执行记录会随批次增长，两者不该混在一个文件里。规范正文在 [`docs/eng/comment-style.md`](eng/comment-style.md)。
> **本批只动注释与文档**，未改任何一行代码 —— 证据见 §4。

## 1. 落纸的规范

- 新建 [`docs/eng/comment-style.md`](eng/comment-style.md)：审计 §2.9 末尾那 7 条落成正式规范（不写 Markdown / `##`+BBCode / 黑话就地展开 / 只写不变量 / 单点 ≤5 行 / 旧结论直接删 / 守卫要标是否还在），附复算命令与基线表。
- 未进 `CLAUDE.md` 索引 —— 那张表由协调者维护；系统性修法见审计 §6 第 4 条（索引改生成式）。

## 2. 新发现并订正的文档错误（审计快照之后才查到的）

| 位置 | 错在哪 | 实测 | 处置 |
|---|---|---|---|
| `docs/eng/room-lifecycle-conventions.md` 前言 + `:140` ★★ | 写"2026-10-08 **把那份文件删掉了**"、"**下面这些约定今天没有任何自动化守卫**" | `tools/room_sweep_lint.gd` **仍在树里（837 行）**；`b5e3201` 是**移动**（`tests/smoke/` → `tools/`），`test-economy.md` 的处置栏写的也是"移出测试面" ⇒ 这是**反向的守卫幻觉：低报了覆盖** | 前言重写：说清"有一层**源码文本检查器**（按 `AGENTS.md` 的 D6 属代理判据、不算行为守卫）+ 真协议行为替代是 `pvp_room_smoke.sh`"；§1 标题与"827 行"一并订正 |
| `docs/eng/netplay.md:88` | 把 `tools/room_sweep_lint.sh` 当真协议回归入口 | 该包装脚本**不存在**（`tools/` 下没有任何 `.sh`） | 改成实际跑法 `"$GODOT" --headless --path . -s res://tools/room_sweep_lint.gd` |
| `docs/eng/ui.md:17` | "★ 冻结守卫在 `menu_style_probe`" | 该探针**已删**（`git ls-files` 0 命中）且**没打"已删"标** | 标注"已删·2026-10-09 ⇒ 色值冻结今天零守卫" |

## 3. 注释瘦身（3 个范式样本 + 2 处定点）

| 文件 | 前 → 后（行） | 做了什么 |
|---|---|---|
| `ui/hud/status_banner.gd` | 150 → **91** | 40 行常量小作文 → 5 行 + 指针；几何/字体度量**搬进** [`docs/eng/ui.md`](eng/ui.md) 新节「状态横幅的几何与层位」（数据一字未丢）；`**` 122 → **0** |
| `tests/probe/allscript_probe.gd` | 154 → **77** | 79 行 `EXPECTED_SCRIPTS` 历史台账 → 5 行数法 + 复算命令；`**` 180 → **0** |
| `tools/room_sweep_lint.gd` | 838 → **785** | 60 行编年史头 → 14 行（那部编年史本就在 `room-lifecycle-conventions.md` §1 的表里）；`**` 424 → **20**（余下 20 处在**代码行**上，见 §3.1） |
| `core/sim/world_rewind.gd` | 493 → 490 | 定点：删掉"`EXPECTED_SCRIPTS` 由 287 变 288"这个会随覆盖漂走的引用 |
| `ui/hud/pvp_hud.tscn` | 103 → 101 | 定点：两处指向 `status_banner.gd` 的注释 → 改指 `docs/eng/ui.md` 新节（否则新造死指针） |

### 3.1 一处必须照实说的返工

`**` 的**机械替换误伤了 8 行代码**（7 条 `_fail` / `print` 的**字符串判词** + 1 行行尾注释）—— 那会改运行时输出。发现方式 = "剥注释后代码 diff 必须为空"这条验证；**8 行已逐字恢复**。

⇒ **教训**：去 Markdown 只能动**整行注释**，不能对全文跑正则。同类机械替换（去全角括号、统一术语）都适用这一条。

## 4. 验证证据

| 判据 | 命令 | 结果 |
|---|---|---|
| **代码零变化**（本批最强判据） | 剥离 `#` / `;` 整行注释后与 `HEAD` 逐字节比对 | 5 个文件 **全部 IDENTICAL** |
| 代码行未被误改 | `git diff -U0 \| grep '^[-+][^-+]' \| grep -v '^[-+][[:space:]]*[#;]'` | **空** |
| EOL 未变 | HEAD 与工作树的 CRLF 行数对比 | 每个文件**满行 CRLF**（未转 LF） |
| 全仓脚本可解析 | `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/allscript_probe.tscn` | `ALLSCRIPT: OK(163 个脚本全部加载)` |
| 规范检查器仍自洽 | `"$GODOT" --headless --path . -s res://tools/room_sweep_lint.gd` | `SMOKE_ROOM_SWEEP OK: … 9 项检查全部跑到尾` |
| 命名/路径检查 | `python tools/check_naming.py` | `命名检查 OK`（rc=0） |
| 跑批前后环境 | `lobby_alive` + `tasklist \| grep -ci godot` | 前 `false`、后 **0**（未占 7777、无残留进程） |

★ 跑的是"用户认领后由 agent 跑"的两支 headless 检查（不碰端口、不弹窗）；**默认批未跑** —— 本批零代码改动，`run_all.sh` 的增量信息有限。

## 5. 全仓指标（改前 → 改后）

| 指标 | 审计时 | 现在 |
|---|---|---|
| `.gd` 注释行 | 11502 | **11310** |
| 注释占非空行 | 32% | **31%** |
| 含 Markdown 标记的注释行 | 6314 | **6050** |
| Markdown 标记总数 | 10758 | **10020** |
| 注释里的 `.superpowers/` 引用 | 12 | **11** |
| 最长单点注释块 | 79 行 | **60 行**（`scenes/player/player.gd`，本轮未动） |

⇒ **这只是三个样本**。`player.gd`、`mp_lobby.gd`、`pvp_match_client.gd`、`world_rewind.gd`、`team_host.gd` 等大头部文件**尚未逐个瘦身**；[`docs/eng/comment-style.md`](eng/comment-style.md) 附录 B 的基线表就是下一轮的量尺。

## 6. 下一轮的候选（按性价比）

1. `scenes/player/player.gd`（60 行单点注释 + 9 处全角括号 + 三个文件共用的错锚点 `player.gd:191`）。
2. `scenes/pvp_match_client.gd` / `scenes/mp_lobby.gd`（Markdown 最密：560 / 555 处；且是审计 §4.2 的拆分候选）。
3. 审计 §2.2 的**守卫幻觉**剩余各处（`pvp_match_client.gd:652`、`server_main.gd:261`、`match_combat.gd:13`、`royale_host.gd:415`、`team_host.gd:616`、`royale_game.gd:98`、`team_game.gd:92`、`ui/hud/{combat_feedback,broadcast,team_hud}.gd`）—— 一律补 `（已删·2026-10-09）` 或改成"零守卫"。
4. 审计 §2.3 的锚点错（同一错锚点被抄进多个文件那几组）。
