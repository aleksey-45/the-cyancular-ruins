# 对局结算画面 —— 设计（2026-09-20）

> 用户原话：「3v3和大乱斗的排行榜一直无法显示，大乱斗还是会显示输赢」，澄清后 = **游戏结束后本该出现的结算画面**（不是对局中那块榜）。

## 0. 问题

**今天没有结算画面。** MATCH_OVER 那一刻，三个客户端各自：

1. 把中央的「胜/败」大字挂上去；
2. 锁住输入（`_match_ended` / `_round_locked`）；
3. 销毁暂停菜单（防"定时器到点再切一次场景"）；
4. **起一个 6 秒定时器，到点自动 `safe_change_scene` 回主菜单**。

于是玩家看到的是：一片大字 → 6 秒 → 已经在主菜单了。**没有名次、没有昵称、没有逐人数字**，也**没有任何"我打得怎么样"的回顾**。

## 1. 目标与非目标

**目标**
- MATCH_OVER 后进入一个**真正的结算页**：不自动走，玩家自己退。
- 三个模式（1v1 / 大乱斗 / 3v3）**行为一致**且**版式只有一份**。
- 结算页显示**每个模式现有的**数据：不硬造该模式没有的列。

**非目标（明写，别顺手做）**
- ❌ 「再来一局」按钮 —— 今天不支持"同一批人再开一局"，那要重走建房/匹配，是另一个特性。
- ❌ 给大乱斗补 `dmg`/`acs` 生产者（那是把 3v3 的数据面复制一份）。
- ❌ 对局中（PLAYING 期间）的榜 —— 3v3 对局中仍只有按队记分条；大乱斗对局中那块榜照旧。
- ❌ 版式定稿 —— 这一版是**可用**版式；联机 UI 与排版重做那份会把它一起重做。

## 2. 已知的既有问题（本设计**不修**，仅登记）

- 大乱斗对局中的榜（`ui/royale_hud.tscn`）在节点顺序上是 `BoardBg → BoardBox → **Mask** → Center`，即**全屏 0.3 的遮罩画在榜之上**、而"输赢广播"画在遮罩之上 ⇒ **倒计时期间榜被压暗**。终局那一拍本设计接管后不再相关。0.3 的遮罩下榜仍可读，故不构成"看不见"。
- 3v3 对局中**没有**榜（只有记分条），这是 B 册"最小可用"版式的既定范围。

## 3. 架构

### 3.1 一个模式无关的控件

新文件 `ui/match_result.tscn` + `ui/match_result.gd`（`class_name MatchResult extends CanvasLayer`）。

**单一职责**：吃一份**模式无关的载荷**（§4）、画出来、发一个 `leave_requested` 信号。
它**不知道任何模式的规则**：不读 `NetBus`、不读 `Settings`、不 import 任何 `*Host`。谁能被 `grep` 到跨过这条线，谁就是缺陷。

- **层位 150** —— 三个 HUD 都是 `layer=130`、小地图 131、暂停菜单 145 ⇒ 盖住一切。
- **输入**：自己吃 ESC → 发 `leave_requested`；`_unhandled_input` 只在可见时开。
- **版式口径**：一律走 `UiFactory`（本项目唯一调色板与控件工厂）、字号只用 16 的倍数、榜底用项目统一的 `黑 0.1`。
  ★ **把 `0.1` 收成 `UiFactory` 的一个具名常量再引用**，不要再写一个裸字面量 —— 上一批刚把"这个值到底有几处"那个会漂的计数改成"以 grep 为准"，别立刻又添一处落点。

### 3.2 三个适配器（留在各模式里，不新起类）

`scenes/pvp_game.gd` / `scenes/royale_game.gd` / `scenes/team_game.gd` 各一个 `_build_result_payload() -> Dictionary`。

- 它们**只读**已有状态（`_names` / `round_state` 的载荷 / `_teams`），**不碰节点树**。
- ★ 这样切分后：**模式规则留在模式里，版式只有一份**。

### 3.3 挂载与离场（三个客户端同款）

MATCH_OVER 分支：

1. **删掉那条 6 秒 `create_timer`**。
2. **保留**现在的「锁输入 + 销毁暂停菜单」两行（后者有理由，见 §5.3）。
3. `add_child(MatchResult)` 并接 `leave_requested`。
4. 收到信号 → 仍走 `Level0.safe_change_scene("res://scenes/main_menu.tscn")`，**防重入那套一个字不动**。

★ `royale_game` 的 `_match_ended`（"锁住结算画面"）语义**保留** —— 结算页不是能跑动的画面。

## 4. 载荷契约（三个模式共用的那一个形状）

```
{
  "title":    String,          # "胜利!" / "失败" / "平 局"
  "subtitle": String,          # 可空，如 "A 队 先到 9 杀" / "3 局 2 胜"
  "columns":  Array[String],   # ★ 列的存在性由数据决定：["kills","deaths","dmg","acs"] 的子集
  "sections": [ { "label": String, "color": Color, "rows": [ row, … ] } ],
  "mvp":      Dictionary,      # 可空；{ "section": i, "row": j }
}
row = { "rank": int, "name": String, "kills": int, "deaths": int,
        "dmg": int, "acs": int, "mvp": bool }
```

★ **没数据的列不进 `columns`，对应字段也不去读。** 这是"不硬造"这条纪律的落点。

| 模式 | `columns` | `sections` | `mvp` |
|---|---|---|---|
| 1v1 | `["kills"]` | 1 节，2 行 | 空 |
| 大乱斗 | `["kills","deaths"]` | 1 节，N 行，中性色 | 空（自由混战没有 MVP，榜首即 `rank` 1） |
| 3v3 | `["kills","deaths","dmg","acs"]` | **2 节**（A/B 队，各用队色） | 指向 ACS 最高者 |

## 5. 数据来源与缺口

### 5.1 昵称：**不是缺口**（★ 别再去服务端补一张表）

`match_sync` 的应答里**本来就带 `names`**（`server_main.gd` 的 `_claim_names`，`role → 昵称`），`scenes/pvp_match_client.gd` 的 `_on_match_sync` 已经把它交给各子类的 `_apply_peer_names` ⇒ **三个客户端手里都有一份 role→昵称**。

服务端那份 `_host.set_display_names(...)`（`server_main.gd`，只在 `--royale` 时注入）是给 **`RoyaleHost` 对局中那块榜**用的，与本设计无关。**本设计零服务端改动。**

### 5.2 逐模式的数据与它的后果

| 模式 | 有 | 没有 ⇒ 不列 |
|---|---|---|
| 1v1 | `scores`（role→击杀）、昵称、`rounds_won` | 逐人阵亡（⇒ `columns` 只有 `kills`） |
| 大乱斗 | `names`/`scores`/`deaths`/`alive`/`left` | `dmg`/`acs` |
| 3v3 | `scores`/`rounds_won`（**按队号**）、`stats`（role→`{kills,deaths,dmg,kscore,acs}`）、`mvp`（role）、`names`（来自 `match_sync`） | —— |

- **键空间**：`stats` 按 role、`names` 也按 role ⇒ 直接可拼。
- ★ **某 role 没有 `stats` 条目**（中途加入 / 掉线 / 只打了一部分）：**跳过该行，不硬造 0**。理由：一个全是 0 的行会被读成"这人打了但什么都没干"，而事实是他根本没在统计里。
- ★ **平局**：3v3 的 `match_winner == 0`（两队都走光）要映射成 `title = "平 局"`。**复用 `ui/team_hud.gd` 已有的口径判断，不要另写一份** —— 那个分支在 `pvp_hud.gd` 里是**错的**（它对 0 用 1v1 兜底，会把平局念成「P2 获胜」）。

### 5.3 1v1 的 `scores` 语义须现场核对

1v1 的 `columns` 只放 `kills`，前提是 `_scores` 在 1v1 里数的是**击杀**。实施第一步就是核对这一点；**若它其实不是击杀**，就按它真实的语义命名列（例如「局胜」），别把标签写成"击杀"。

## 6. 边界与错误处理

1. **载荷缺键或为空**：每个键都取默认（空 `sections` ⇒ 只画 `title`）。**绝不因缺一个键就崩** —— 结算页崩了，玩家就卡在对局里出不去。
2. **`leave_requested` 要防重入**：按钮连点、按钮与 ESC 同时 —— `safe_change_scene` 自己有 `_switching` 守卫，但**结算页这一侧也要置位**，否则会连发两次信号。
3. ★ **ESC 是双重语义**：对局中 ESC = 暂停菜单；结算页上 ESC = 返回主菜单。今天**天然不冲突**，因为 MATCH_OVER 时暂停菜单**已被销毁**。**要在注释里钉住这个依赖** —— 谁将来删了"销毁暂停菜单"那两行，ESC 就会同时触发两件事。
4. ★ **"起定时器前先捕获 tree/netbus"那条纪律随定时器一起消失**，但 `is_inside_tree()` 早退**要保留**。删旧代码时别把这条一并当垃圾清掉。
5. **网络**：MATCH_OVER 之后 `NetBus` 已停，结算页不依赖网络 ⇒ 这期间断网无影响。
6. `_match_ended` 的输入锁**保留**。

## 7. 测试

1. **新场景探针 `tests/match_result_probe.tscn`（不占端口）**
   - 喂**三份**构造载荷（1v1 单行 / 大乱斗 N 行 / 3v3 两节含 `mvp`），各取一张 PNG。
   - 断言：列数随 `columns` 变；两节时画两栏；`mvp` 高亮**只出现一次**；**空载荷不崩**；**`leave_requested` 连点两次只发一次**。
   - ★ 取图由**实施者自己读一遍**再给用户（本仓纪律：视觉探针的图要自己读，那一步抓到过两个数值全绿的 bug）。
2. **适配器当纯函数测**：三个 `_build_result_payload()` 只读状态、不碰节点 ⇒ 可在既有探针里喂**假 `round_state`** 直接断言载荷形状（照 `tests/combat_hud_visual_probe.gd` 喂假 state 的先例）。
3. **离场路径**：三个客户端的 MATCH_OVER 分支改动是典型的「改了不报错」（定时器没了、改成信号）。源码级断言只能钉"形状"，**更硬的是真链路跑一次看它到底回不回主菜单** —— 现成的 `royale_soak_probe` / `team_match_probe` 本来就会跑到 MATCH_OVER，顺带就验了。
4. ★ **已知会被本改动带红的既有断言**：`tests/kh_l6_probe.gd` 的第 9 / 9b 条守的是"MATCH_OVER 退场块（菜单失效 + `is_inside_tree()` 早退）"。动那两块必须**同步改它**，**不许放宽**。
5. **三个模式零回归**：结算页只在 MATCH_OVER 那一拍介入，PLAYING / COUNTDOWN 一条路径都不该被碰到。

## 8. 交付物清单

| 文件 | 新建/修改 | 责任 |
|---|---|---|
| `ui/match_result.tscn` + `ui/match_result.gd` | **新建** | 结算控件（版式 + 一个信号） |
| `ui/ui_factory.gd` | 修改 | `黑 0.1` 收成具名常量（若尚无）+ 结算页要用的控件工厂方法 |
| `scenes/pvp_game.gd` | 修改 | `_build_result_payload()` + MATCH_OVER 分支改挂结算页 |
| `scenes/royale_game.gd` | 修改 | 同上 |
| `scenes/team_game.gd` | 修改 | 同上（两节 + `mvp`） |
| `tests/match_result_probe.tscn/.gd` | **新建** | 版式 + 信号行为的守卫 |
| `tests/kh_l6_probe.gd` | 修改 | 第 9 / 9b 条随改动同步（**不放宽**） |
| `CLAUDE.md` | 修改 | 记录结算页与它的三条纪律（层位/信号防重入/ESC 双重语义的依赖） |

## 9. 自检

- **占位符扫描**：无 TBD / TODO。
- **内部一致性**：§4 的表格与 §5.2 的"没有⇒不列"逐行对齐；§3.3 的删定时器与 §6.4 的"纪律随定时器消失"一致。
- **范围**：单一实施计划可覆盖（1 个新控件 + 3 个适配器 + 1 个探针 + 1 个既有探针同步 + 文档）。
- **歧义**：§5.3 把"1v1 的 `scores` 到底是不是击杀"写成**实施第一步要核**的事，而不是含糊过去。
