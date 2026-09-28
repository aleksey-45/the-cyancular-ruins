# UI 调色板单一来源（底板色 + 队色）

> **上游**：`docs/superpowers/specs/2026-09-25-team-faction-fixes-design.md` §7 第一条（原文把它列为「另立计划」）。
> **状态**：设计定稿（2026-09-28），待写实现计划。
> **性质**：纯重构 —— **不该改变任何一个像素**。

---

## 1. 背景与现状

### 1.1 这份 spec 解决什么

上游 spec §7 把「队伍色与常量的单一来源」列为**后续独立计划**，理由是它「与本 spec 的『认不出谁是谁』是**两回事**（那些是维护性冗余，不是可读性缺陷）」。

逐处核过之后：那条 bullet 列的四样东西里，**只有两样是真的冗余**，另两样要么已经单一来源、要么近色是刻意的（§1.4）。本设计只处理**真的那两样**，并把**结构上无法派生**的落点用守卫兜住。

### 1.2 真的冗余（一）：底板色 `Color(0, 0, 0, 0.1)` 共 **6 处**，**零守卫**

| # | 落点 | 形态 |
|---|---|---|
| 1 | `ui/hud.gd:38` | `const PLATE_COLOR`（外加 `:28-37` 一整段 WCAG 对比度推导注释） |
| 2 | `ui/weapon_slots.gd:33` | `const PLATE_COLOR` |
| 3 | `ui/world_label.gd:15` | `const PLATE_COLOR` |
| 4 | `ui/royale_hud.gd:90` | `_plate_box()` 里的**内联字面量** |
| 5 | `ui/pvp_hud.tscn:7` | `StyleBoxFlat` 的 `bg_color = Color(0, 0, 0, 0.1)` |
| 6 | `ui/team_hud.tscn:7` | 同上 |

**今天没有任何守卫。** 现行纪律写在 `CLAUDE.md` 的 §UI：「改一处要改齐（下列是已知落点，**不是完备枚举**）」，并附一条 grep 命令让人**手工**对账 —— 也就是说**漏改是静默的**，只靠人记得跑那条命令。

三处注释自己就承认了这笔债：`ui/hud.gd:28-32`、`ui/royale_hud.gd:83-86`（「改一处就得改齐三处」）、`ui/world_label.gd:13-14`（「与单机 HUD 的 `PLATE_COLOR`、`pvp_hud.tscn` 的 `Plate` 同值」）。

### 1.3 真的冗余（二）：`C_TEAM_A` 与 `BODY_BASE_COLOR` 逐位相同，**两份字面量**

- `ui/ui_factory.gd:132` `const C_TEAM_A := Color(99.0 / 255.0, 155.0 / 255.0, 1.0)` —— `#639BFF`，调色板里的**队 1 token**
- `scenes/pvp_match_client.gd:67` `const BODY_BASE_COLOR := Color(99.0 / 255.0, 155.0 / 255.0, 1.0)` —— `#639BFF`，`player.png` 的**本体主色**，被 `_apply_tint` 用作 modulate 比值的**分母**

两者**来源不同、值必须相等**。今天由 `tests/hue_tint_probe.gd` 的**守卫 D** 钉着 `C_TEAM_A == BODY_BASE_COLOR == player.png 众数` ⇒ 冗余**不静默**（改一处会红），但仍是**两个源**：改调色板必须同时改本体常量（或反过来），没有单向派生。

### 1.4 查过、**不需要动**的三处（别再当冗余去改）

1. **`NAME_COLOR`**（`scenes/pvp_game.gd:23` = `Color(0.94, 0.95, 0.98, 1.0)`）
   **已经是单一来源**：一处定义、**两处读点**（`:323` / `:324`）、**都在同一个文件里**。
   而且它有一条**刻意的**守卫 —— `tests/kh_l6_probe.gd:802-820`（第 15 条，U1 决策「保留 main 的**中性亮白**头顶名、不采纳 KH 的按角色双色」）断言的正是：「`pvp_game.gd` 的文本里有 `const NAME_COLOR := Color(...)` **字面量**」+「`nm_self` / `nm_opp` 两个标签都用它上色」+「全仓零 `ROLE_COLOR`」。
   ⇒ **搬进调色板会破坏那条守卫，却买不到任何单一来源的收益。不动。**

2. **`SELF_COLOR`**（`ui/minimap.gd:36` = `#99F2FF`）与 **`C_TEAM_B`**（`ui_factory.gd:133` = `#80F4FF`）
   两者近色（Δ=(25, 2, 0)，同属蓝-青系）是**有意的、不是重复**：3v3 下「自己那个点」取**队色** + 一圈**白描边**（`RING_SELF_PX`，与颜色**正交** —— 同队同色时颜色本身分不出「我」与队友）；1v1 / 大乱斗不传 `self_color_provider` ⇒ 退回 `SELF_COLOR`、描边不可见。
   合并这两个值 = 把「分不清自己与队友」换成「**完全**分不清哪个是自己」。守卫：`tests/minimap_circle_probe` 相⑥ / ⑦。

3. **`ui/royale_hud.gd` 的 `_board_bg`（排行榜玩家栏）单独是 0.25**
   用户 2026-09-15 点名把它**排除**在那轮统一下调之外（玩家名次表要更实的底）。**它不在本设计的 6 处里**，别顺手统一。

### 1.5 已排除的伪发现（勿重复排查）

- **全屏压暗罩不是底板**：`pvp_hud` 的 `Mask`、royale 的 `_mask`（0.3）、暂停菜单（0.55）、`enemy_hp_bar.gd` 的底（0.45）。它们语义不同，与本设计的 6 处无关，**别一起改**。
- **`ui_factory.gd:115` 那段「与底板对比 ≥3:1 当年就没量过」**是**队色**对底板的对比度订正，不是本设计的重复项。它里面那句「与 `ui/hud.gd` 的 `PLATE_COLOR` 注释同一套算法」是本设计要顺手修掉的**跨文件指路**（§3.1 把那段算法搬进调色板后，就变成同文件引用了）。

---

## 2. 目标与非目标

**目标**

1. 底板色**只有一个数值来源**；改它一处，4 个 `.gd` 落点**全部**跟着变。
2. 两个 `.tscn` 落点**结构上派生不了** ⇒ 让「改漏」**响亮地红**，而不是静默。
3. `BODY_BASE_COLOR` 与 `C_TEAM_A` 收敛为**一份**。
4. 顺带把三处「改一处要改齐 N 处」的注释改成「这是唯一源 / 这是必须同步的副本」。

**非目标**

- 不引入 Theme / `.tres` / 运行时覆写来让 `.tscn` 也派生（见 §7）。
- 不碰任何 HUD 版式、渲染初始化顺序、或 `.tscn` 的其它字段。
- 不改 `C_TEAM_A` / `C_TEAM_B` / `SELF_COLOR` / `NAME_COLOR` 的**值**。
- 不「顺手统一」全屏压暗罩或 `_board_bg` 的 0.25。

---

## 3. 设计

### 3.1 调色板新增 `C_PLATE`（唯一源）

`ui/ui_factory.gd` 新增：

```gdscript
# 底板:黑 0.1 —— HUD 元素一律垫它。★★ **唯一的数值源**:
#   `ui/hud.gd` / `ui/weapon_slots.gd` / `ui/world_label.gd` / `ui/royale_hud.gd` 四处的
#   `PLATE_COLOR` 都是它的**别名**;`ui/pvp_hud.tscn` / `ui/team_hud.tscn` 的 `bg_color`
#   是**结构上无法派生**的副本,由 `tests/ui_palette_single_source_smoke.gd` 钉住与它逐位相等。
const C_PLATE := Color(0, 0, 0, 0.1)
```

并把 `ui/hud.gd:28-37` 那段 WCAG 推导（alpha `0` / `0.10` / `0.15` / `0.45` 四档对比度表 + 「0.1 是用户看过实图后定的**审美值**，不是按对比度算出来的」那句）**整体搬到这里**；`ui/hud.gd:38` 原地留**一行**指路注释。

★ 命名按调色板既有前缀惯例（`C_BG` / `C_SURFACE` / `C_ROW` / `C_FIELD` / `C_ACCENT` / `C_WARN` …）。

### 3.2 四个 `.gd` 落点 → 别名（**保留各自的名字**）

```gdscript
const PLATE_COLOR := UiFactory.C_PLATE
```

- 落点：`ui/hud.gd:38`、`ui/weapon_slots.gd:33`、`ui/world_label.gd:15`；`ui/royale_hud.gd:90` 是内联写法，改成 `sb.bg_color = UiFactory.C_PLATE`。
  ★ 顺带一个佐证：`ui/royale_hud.gd` **已经引 `UiFactory` 11 处** —— 那处内联字面量在同文件里是**唯一**没走调色板的，本就该改。
- **为什么留别名、而不是让读点直接写 `UiFactory.C_PLATE`**：
  ① 保住既有的**外部**读者 —— `tests/kh_l3_visual_probe.gd:132` 读的是 `WeaponSlots.PLATE_COLOR`；
  ② 与既有写法同款（`server/match_state.gd:80` 的 `const HIT_RADIUS := BulletBase.PLAYER_HIT_RADIUS`）。
  ★ 别名**不构成第二个源** —— 它里面**没有字面量**，值只能来自调色板。
- **依赖方向是正常的,不必论证**:`ui/world_label.gd` 是 UI 控件、`UiFactory` 是 UI 调色板 —— 控件引用调色板正是 `CLAUDE.md` §UI 那句「各页面一律引用」的方向;`scenes/pvp_match_client.gd`（§3.4）同理,`UiFactory` 是纯静态 `class_name`、零 autoload 依赖、也不反向引用任何 UI 控件。★ 只登记一个事实:这两个文件**今天**对 `UiFactory` 是零引用,改完各新增一处。
- `ui/royale_hud.gd:83-86` 那段「改一处就得改齐三处」的注释**要改写**（不再有三处手工同步）。**同文件 `_board_bg` 的 0.25 一字不动。**

### 3.3 两个 `.tscn` → 保留字面量 + 守卫

`.tscn` **引用不到** GDScript 的 `const`（`bg_color` 是 `StyleBoxFlat` 上的**属性**，不是资源引用）。本设计**不改渲染初始化**（那是 §7 排除的），改为：

1. `ui/pvp_hud.tscn:7` / `ui/team_hud.tscn:7` 的 `bg_color` **原样保留**；
2. 各加一行注释：`; ★ 这是副本:唯一源是 ui/ui_factory.gd 的 C_PLATE,由 tests/ui_palette_single_source_smoke.gd 钉住相等`;
3. **新守卫读这两个文件的文本**，断言与 `C_PLATE` **逐位相等**（§3.5 ④）。

### 3.4 `BODY_BASE_COLOR` → 别名

`scenes/pvp_match_client.gd:67`：

```gdscript
const BODY_BASE_COLOR := UiFactory.C_TEAM_A   # #639BFF(本体主色 == 队 1 token)
```

两处读点（`:102-104` 的 modulate 比值）**不变**。★ `hue_tint_probe` 守卫 D **保留** —— 它钉的第三维（**`player.png` 的众数色**）仍是独立的一维：换了精灵素材而没改调色板时，它照样红。

### 3.5 新守卫 `tests/ui_palette_single_source_smoke.gd`（`-s`、headless）

`extends SceneTree` + `ScanUtil`（读文本 + `code_only` 剥注释）。

| # | 断言 | 它红了意味着什么 |
|---|---|---|
| ① | `ui/ui_factory.gd` 有 `const C_PLATE := Color(0, 0, 0, 0.1)` | 源没了 / 值被改 |
| ② | 四个 `.gd` 落点**引用 `UiFactory.C_PLATE`**（判据：该行含 `UiFactory.C_PLATE`） | 有人把别名换回了字面量 = 回到 6 个源 |
| ③ | `scenes/pvp_match_client.gd` 的 `BODY_BASE_COLOR` 引用 `UiFactory.C_TEAM_A` | 同上，队色那一半 |
| ④ | **两个 `.tscn` 的 `bg_color` 逐位等于 `C_PLATE`** | ★ **这就是「改漏 `.tscn`」的唯一信号** |
| ⑤ | 反向：全仓**再无**游离的 `Color(0, 0, 0, 0.1)` 字面量（白名单 = 调色板那一行 + 两个 `.tscn`） | 将来新加第 7 个落点时它先红 |

★ 判据一律**剥注释后**匹配（`ScanUtil.code_only`）—— 否则 `ui/hud.gd` 里那段「这是唯一源」的说明文字会把它自己判红。
★ `.tscn` 不是 GDScript、`code_only` 不适用 ⇒ 那一处**读原文**，按 `bg_color = Color(...)` 的形状取（**要能容忍空格差异**）。
★ **为什么另立 `-s` 而不并进 `hue_tint_probe`**：后者是**真渲染**探针（headless 下 `get_image()` 给 null ⇒ 直接 FAIL 并 return），源码级断言不该寄生在它里面。

---

## 4. 已知边界与残余（登记，不修）

1. **`.tscn` 那一维仍是「两份值」**，只是改漏会红。要真派生得改渲染初始化（§7）。
2. **`.tscn` 的字面量在 Godot 编辑器里拖色仍会静默改**（编辑器不知道有守卫）—— 只有**跑守卫**才知道。
3. 守卫只钉这 **6 处**，不是「完备枚举」：将来新增第 7 处底板时，⑤ 的反向断言会红 —— **前提是它写成 `Color(0, 0, 0, 0.1)` 字面量**；若写成第三种 `const` 名字，⑤ 抓不到（② 只钉那四个具名落点）。⇒ 这是**已知的判据上限**，如实登记。
4. 注释搬家后，`CLAUDE.md` §UI 里那条「已知落点 + grep 命令」的段落**必须同步改写**，否则文档会指着一个已经不存在的「6 处」。

---

## 5. 验收判据

1. **单向派生成立**：把 `UiFactory.C_PLATE` 改成别的值 ⇒ 四个 `.gd` 落点**全部**跟着变（守卫 ② 即可证明，不必真改色出图）。
2. **改漏会红**：只改 `ui/pvp_hud.tscn` 的 `bg_color`（不动 `team_hud.tscn`）⇒ 守卫 ④ **红**；还原 ⇒ 绿。
3. **既有守卫全绿**：`hue_tint_probe`（守卫 D）/ `kh_l3_visual_probe`（读 `WeaponSlots.PLATE_COLOR`）/ `combat_hud_visual_probe` / `kh_l6_probe`（第 15 条 —— 它钉的 `NAME_COLOR` **本设计不动**）/ `kh_l4_probe` / `kh_l5_probe`（字号与归属扫描，扫描面含 `res://ui` 与 `res://tests`）。
4. **人眼验收**：`kh_l3_visual_probe` / `combat_hud_visual_probe` 出的图 —— **底板观感必须不变**（本设计不该改变任何像素）。

---

## 6. 计划拆分

**一份计划**，四个 Task：

| Task | 内容 |
|---|---|
| 1 | **守卫先行** —— 新 `-s` 冒烟。今天应 **① ② ③ ④ ⑤ 全红**（源与别名都还不存在），先看着它红 |
| 2 | 调色板加 `C_PLATE` + WCAG 注释搬家 + 四个 `.gd` 落点改别名 |
| 3 | `BODY_BASE_COLOR` 改别名 + 两个 `.tscn` 加注释行 |
| 4 | 回归 + 改写 `CLAUDE.md` §UI 那段（「已知落点 + grep 命令」→ 指向唯一源与守卫） |

---

## 7. 本设计明确不做的事（后续独立计划）

- **让 `.tscn` 也派生**：运行时在 `_ready` 覆写 `bg_color`，或把 `StyleBoxFlat` 抽成共享 `.tres` —— 两条都要碰 HUD 的**渲染初始化 / 版式资源**，收益只是「少一处手工副本」，风险面大得多。
- 把**全部** UI 颜色收进一份强类型调色板（今天 `UiFactory` 已是唯一工厂与唯一调色板，够用）。
- **全屏压暗罩**（0.3 / 0.55 / 0.45）的统一 —— 它们不是底板，语义不同。

---

## 附：事实核验清单（全部本机实测，2026-09-28）

| 事实 | 读数 |
|---|---|
| `Color(0, 0, 0, 0.1)` 落点 | **恰好 6 处**（排除 `docs/`、`.superpowers/` 副本后 grep） |
| `C_TEAM_A` 与 `BODY_BASE_COLOR` 的表达式 | **逐位相同**（`Color(99.0 / 255.0, 155.0 / 255.0, 1.0)`） |
| `NAME_COLOR` 读点 | **2 处**（`scenes/pvp_game.gd:323` / `:324`），都在同一文件 |
| `kh_l6_probe` 第 15 条钉的判据串 | 「`const NAME_COLOR := Color(`」**必须出现在 `pvp_game.gd` 的文本里** |
| `ui/world_label.gd` 现有 `UiFactory` 引用数 | **0** |
| `scenes/pvp_match_client.gd` 现有 `UiFactory` 引用数 | **0** |
| `ui/ui_factory.gd` 是否引用 `WorldLabel` / `Hud` | **否**（调色板不反向引用控件 ⇒ 依赖方向单向干净） |
| `WeaponSlots.PLATE_COLOR` 的外部读者 | `tests/kh_l3_visual_probe.gd:132` |
| `hue_tint_probe` 是否需要真渲染 | **是**（headless 下截图给 null ⇒ 直接 FAIL），故新守卫另立 `-s` |
