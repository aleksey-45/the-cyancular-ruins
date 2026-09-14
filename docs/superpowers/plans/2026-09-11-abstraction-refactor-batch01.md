# 抽象收敛批次 0+1 实施计划（低风险清理 + 纯函数抽取）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除 8 处「本应抽象而未抽象」的重复与 3 处文档漂移，全程不触碰联机协议、不改变任何运行时行为。

**Architecture:** 只做两类动作——(a) 删除死代码/修正文档；(b) 把逐字重复的**纯函数**提到静态助手类，调用点改为转发。不涉及任何类层次重构、不改文件职责边界、不动 `MatchHost`/`RoyaleHost` 覆写关系、不动 C2 rollback 契约。

**Tech Stack:** Godot 4.7.1 标准版（非 mono），GDScript，无单测框架（冒烟 = `extends SceneTree` 的 `-s` 脚本 + 场景模式探针）。

## Global Constraints

- **Godot 可执行文件绝对路径**（不在 PATH）：
  `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`
- **新建带 `class_name` 的文件后必须先刷全局类缓存**，否则引用处 Parse Error：
  `..." --headless --path . --import`
- **探针判据必须是 grep 文本 `ALL-OK`**，不能只看退出码（中途报错时 `--quit-after` 仍 exit 0 且不打印 ALL-OK）。
- **字号实参必须是 16 的倍数**（`kh_l5_probe` 全仓扫描，含 `res://core`、`res://scenes`、`res://tests`）。
- **测试由用户自己跑。** 本计划里的验证命令是给实施者自查用的；每个 Task 末尾不要自动代跑整套冒烟，把「待用户验收」的命令列出来即可。
- **不要动**（本计划范围外，已有裁定）：`NetBus`/`NetBusExt` 的 RPC 样板、`core/net_bus_ext.gd` 里同名的 `beam_fired`、`RoyaleHost._init` 顺序与 `_spawned_once` 闩锁、开局三载荷的两条投递路径、`weapon_base.gd` 的 `@export` 参数表、`kh_l*_probe` 的断言体。
- 每个 Task 独立提交。提交信息用中文，与仓库既有风格一致。

---

### Task 1: 删除死代码 `Settings._apply_binding`

**Files:**
- Modify: `core/settings.gd:166-170`

**Interfaces:**
- Consumes: 无
- Produces: 无（纯删除）

- [ ] **Step 1: 确认无调用者**

```bash
grep -rn "_apply_binding" --include=*.gd . | grep -v "^./.godot"
```

Expected: 只有 `core/settings.gd:166` 这一行（函数定义本身）。**若出现任何调用点，停止本 Task**，改为保留函数并记录到计划末尾的「未预期发现」。

- [ ] **Step 2: 删除该函数**

删除 `core/settings.gd` 中这 5 行（连同前面的空行）：

```gdscript
func _apply_binding(action: String, ev: InputEvent) -> void:
	if ev == null or not action in InputMap.get_actions():
		return
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, ev)
```

不要删除紧邻的 `_make_key` / `_make_mouse`（它们被 `load_settings` 里 `:162`/`:164` 调用）。

- [ ] **Step 3: 启动自检**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90
```

Expected: 退出码 0，输出无 `SCRIPT ERROR` / `Parse Error`。

- [ ] **Step 4: 提交**

```bash
git add core/settings.gd
git commit -m "chore(settings): 删除死代码 _apply_binding——已被 set_binding 取代,全仓无调用者"
```

---

### Task 2: 武器格 Label 走 UiFactory（补字体）

**Files:**
- Modify: `scenes/player/weapon_component.gd:76-79`

**Interfaces:**
- Consumes: `UiFactory.label(text: String, size: int, color: Color = Color.WHITE) -> Label`（`ui/ui_factory.gd:46`，已存在）
- Produces: 无

**背景：** 当前只设了字号没设字体，导致武器格文字落回默认主题字体，而同页面（`matchmaking.gd`/`royale_lobby.gd` 的禁用武器面板）其他 Label 都是像素字体。`UiFactory.label` 同时写 `font_size` + `font` 两个 override，是本仓「字体唯一来源」的正规入口。

- [ ] **Step 1: 替换**

把 `weapon_component.gd` 中：

```gdscript
	var l := Label.new()
	l.text = "%d %s" % [slot, DISPLAY_NAMES[slot]]
	l.add_theme_font_size_override("font_size", font_size)
	cell.add_child(l)
```

改为：

```gdscript
	# 走 UiFactory:它同时写 font 与 font_size 两个 override。原先只写字号 → 本行文字
	# 落回默认主题字体,与同页面其它 Label(像素字体)不一致。
	var l := UiFactory.label("%d %s" % [slot, DISPLAY_NAMES[slot]], font_size)
	cell.add_child(l)
```

`font_size` 形参保持原名与位置不变（调用方 `matchmaking.gd:171` / `royale_lobby.gd:213` 按位置传参）。

- [ ] **Step 2: 确认没有探针钉住旧写法**

```bash
grep -rn "add_theme_font_size_override" tests/ | head
```

Expected: 命中的是探针**扫描器自身**的匹配模式（`kh_l5_probe` 的字号扫描），不是针对 `make_weapon_check` 的断言。若出现 `make_weapon_check` 字样的断言，停止并记录。

- [ ] **Step 3: 视觉自检（用户执行）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90
```

Expected: 退出码 0。肉眼确认留给用户：进「大乱斗 → 建房」面板，武器勾选格的文字应与页面其他文字同为像素字体。

- [ ] **Step 4: 提交**

```bash
git add scenes/player/weapon_component.gd
git commit -m "fix(ui): 武器格 Label 补字体 override——原先只设字号致其落回默认主题字体,与同页面其它 Label 不一致;改走 UiFactory.label"
```

---

### Task 3: 修正 CLAUDE.md 三处文档漂移

**Files:**
- Modify: `CLAUDE.md:74-75`、`CLAUDE.md:76`、`CLAUDE.md:95`

**Interfaces:**
- Consumes: 无
- Produces: 无

**背景（已逐条对照源码核实）：** `core/tile_defs.json` 不存在，`TileDefs.PATH`（`core/tile_defs.gd:12`）指向 `res://data/tile_defs.json`；`editor/` 目录不存在，实际是 `level_editor/`；树叶/树干的实际 hp 见 `data/tile_defs.json:20-25`。

- [ ] **Step 1: 修 tile_defs.json 路径（两行）**

`CLAUDE.md:74`：

```markdown
### 砖块属性与破坏(core/tile_defs.json)
```

改为：

```markdown
### 砖块属性与破坏(data/tile_defs.json)
```

`CLAUDE.md:75` 行首：

```markdown
- **属性表** `core/tile_defs.json` 是单一来源:
```

改为：

```markdown
- **属性表** `data/tile_defs.json` 是单一来源:
```

（该行其余内容不动；`level_editor/tile_defs.js` 由 `node level_editor/sync-tiles.js` 生成这句本来就是对的。）

- [ ] **Step 2: 修 hp 数值（同一行 `CLAUDE.md:76`）**

```markdown
15-18 树叶(墙,hp20,子弹/爆炸可破,弹性弱弹玩家);19-20 树干竖/横(墙,hp80,爆炸可破)
```

改为：

```markdown
15-18 树叶(墙,hp8,子弹/爆炸可破,弹性弱弹玩家);19-20 树干竖/横(墙,hp30,爆炸可破)
```

- [ ] **Step 3: 修编辑器目录名（`CLAUDE.md:95`，一行内两处）**

```markdown
`editor/structure-editor.html` + `editor/smoke.js` 是独立浏览器地图编辑器
```

改为：

```markdown
`level_editor/structure-editor.html` + `level_editor/smoke.js` 是独立浏览器地图编辑器
```

同行末：

```markdown
`node editor/smoke.js` 跑 Core 测试。
```

改为：

```markdown
`node level_editor/smoke.js` 跑 Core 测试。
```

- [ ] **Step 4: 复核全仓再无残留**

```bash
grep -n "core/tile_defs\.json\|editor/structure-editor\|editor/smoke\.js\|hp20\|hp80" CLAUDE.md
```

Expected: 无输出。

- [ ] **Step 5: 提交**

```bash
git add CLAUDE.md
git commit -m "docs(CLAUDE.md): 修三处漂移——tile_defs.json 实际在 data/(已核 core/tile_defs.gd:12 的 PATH);编辑器目录实为 level_editor/;树叶/树干 hp 实为 8/30(对照 data/tile_defs.json:20-25)"
```

---

### Task 4: 抽 `core/math_util.gd`，收敛 `_approach` 的 3 份活副本 + 删 1 份死副本

**Files:**
- Create: `core/math_util.gd`
- Modify: `scenes/enemies/enemy_base.gd:184-185`（删定义）、`:198`、`:200`（改调用）
- Modify: `scenes/player/player.gd:184-185`（删定义）、`:199`、`:201`、`:303`、`:305`、`:308`、`:310`（改调用）
- Modify: `scenes/player/swim_component.gd:11-12`（删定义）、`:28`（改调用）
- Modify: `scenes/player/climb_component.gd:107-109`（**纯删除** —— 这份是死代码，无调用者）

**Interfaces:**
- Consumes: 无
- Produces: `MathUtil.approach(current: float, target: float, rate: float, delta: float) -> float`

**背景（已核实）：** `_approach` 的实现 4 份逐字相同：`return lerp(current, target, 1.0 - exp(-rate * delta))`。其中 `climb_component.gd:108` 的定义**全仓零调用**（`grep -n "_approach(" scenes/player/climb_component.gd` 只回定义那一行），是死代码，直接删、不必迁移。

- [ ] **Step 1: 建 `core/math_util.gd`**

```gdscript
class_name MathUtil
extends RefCounted

# 通用数学助手。纯静态、无实例状态、不引 autoload:可被任何场景/工具直接调用,
# 也能在 `-s` 冒烟阶段安全引用(同 core/collision_builder.gd / core/water.gd 的风格)。


# 指数缓动:朝目标值逼近。rate 越大越跟手;
# 起步快后渐缓、松键带滑行、转身平滑穿过 0,避免线性 move_toward 的生硬。
# 原本在 enemy_base / player / swim_component 各抄一份(逐字相同),此处收为单一来源。
static func approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))
```

- [ ] **Step 2: 刷全局类缓存**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import
```

Expected: 无 Parse Error。**这一步不能省** —— 新建 `class_name` 后不刷缓存，下一步的引用处会报 Parse Error。

- [ ] **Step 3: 改 `enemy_base.gd`**

删掉 `:184-185`：

```gdscript
func _approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))
```

把 `:198` 与 `:200` 的 `_approach(` 改成 `MathUtil.approach(`（两处形参顺序不变）：

```gdscript
		velocity.y = MathUtil.approach(velocity.y, target_vy, EnemyParams.shared.bird_water_damp, delta)
```

```gdscript
		velocity.x = MathUtil.approach(velocity.x, dir.x * EnemyParams.shared.bird_swim_speed,
			EnemyParams.shared.bird_water_damp, delta)
```

- [ ] **Step 4: 改 `player.gd`**

删掉 `:184-185` 的同名定义（连同其上 `:182-183` 的两行说明注释一起删 —— 它们已移到 `math_util.gd`），并把 `:199`、`:201`、`:303`、`:305`、`:308`、`:310` 六处的 `_approach(` 改成 `MathUtil.approach(`。

- [ ] **Step 5: 改 `swim_component.gd`**

删掉 `:11-12`：

```gdscript
func _approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))
```

`:28` 改为：

```gdscript
	parent.velocity.x = MathUtil.approach(parent.velocity.x, target_vx, PlayerParams.player_swim_accel, delta)
```

- [ ] **Step 6: 删 `climb_component.gd` 的死副本**

删掉 `:107-109`：

```gdscript
# 指数缓动(根移动逻辑同款,仅用于攀爬时把横速归零)。
func _approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))
```

（该函数无调用者。**不要**改成 `MathUtil.approach` —— 没有调用点要改。）

- [ ] **Step 7: 确认无残留**

```bash
grep -rn "_approach" --include=*.gd . | grep -v "^./.godot"
```

Expected: 无输出。

- [ ] **Step 8: 提交**

```bash
git add core/math_util.gd core/math_util.gd.uid scenes/enemies/enemy_base.gd scenes/player/player.gd scenes/player/swim_component.gd scenes/player/climb_component.gd
git commit -m "refactor(core): 抽 MathUtil.approach 收敛指数缓动——enemy_base/player/swim 三份逐字相同;climb_component 那份是零调用死代码,直接删"
```

---

### Task 5: 抽 `MazeGenerator.toroidal_lerp`，收敛两处副本位置插值

**Files:**
- Modify: `core/maze_generator.gd`（在 `toroidal_delta_px` 之后新增静态函数）
- Modify: `scenes/player/player_replica.gd:104-108`
- Modify: `scenes/enemies/enemy_replica.gd:83-87`

**Interfaces:**
- Consumes: `MazeGenerator.toroidal_delta_px(a, b, w, h) -> Vector2`、`MazeGenerator.wrap_to_range(pos, w, h) -> Vector2`（均已存在于 `core/maze_generator.gd:107` / `:134`）
- Produces: `MazeGenerator.toroidal_lerp(a: Vector2, b: Vector2, alpha: float, w: float, h: float) -> Vector2`

**背景（已核实）：** 两个副本类的 `_sample_position` 末三行逐字相同。这是环面数学族天然缺的一员，放 `toroidal_delta_px` 旁边。**只抽末三行**，`_pos_hist` / `_tick_list` / 时钟推进等缓冲逻辑留在各自类里（`KEEP_TICKS` 与时钟变量名本就不同，不为统一而统一）。

- [ ] **Step 1: 在 `core/maze_generator.gd` 的 `toroidal_delta_px`（`:107-114`）之后插入**

```gdscript
# 环面线性插值:沿 a→b 的最短向量按 alpha 取点,再取模回 [0,w)×[0,h)。
# 供 PvP 副本位置插值用——相邻快照在环面上可能跨接缝,直接 lerp 会横穿整幅地图。
static func toroidal_lerp(a: Vector2, b: Vector2, alpha: float, w: float, h: float) -> Vector2:
	return wrap_to_range(a + toroidal_delta_px(a, b, w, h) * alpha, w, h)
```

- [ ] **Step 2: 改 `player_replica.gd`**

把 `_sample_position` 末尾（`:104-108`）：

```gdscript
	var alpha := clampf((clock - float(a)) / float(b - a), 0.0, 1.0)
	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var d := MazeGenerator.toroidal_delta_px(pa, pb, w, h)
	return MazeGenerator.wrap_to_range(pa + d * alpha, w, h)
```

改为：

```gdscript
	var alpha := clampf((clock - float(a)) / float(b - a), 0.0, 1.0)
	return MazeGenerator.toroidal_lerp(pa, pb, alpha, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
```

- [ ] **Step 3: 改 `enemy_replica.gd`**

同一段（`:83-87`）做完全相同的替换。该文件 `_sample_position` 的其余部分（`_clock` 变量名等）不动。

- [ ] **Step 4: 确认无残留**

```bash
grep -rn "toroidal_delta_px" --include=*.gd scenes/ | grep -i replica
```

Expected: 无输出（两个副本类不再直接调 `toroidal_delta_px`）。

- [ ] **Step 5: 提交**

```bash
git add core/maze_generator.gd scenes/player/player_replica.gd scenes/enemies/enemy_replica.gd
git commit -m "refactor(core): 抽 MazeGenerator.toroidal_lerp——player_replica/enemy_replica 的副本插值末三行逐字相同;环面数学族的缺员,放 toroidal_delta_px 旁"
```

---

### Task 6: 抽 `CombatFeedback.attribute_hit`，收敛 4 对「归因 + 命中标记」

**Files:**
- Modify: `scenes/effects/combat_feedback.gd`（在 `attribute` 之后新增静态函数）
- Modify: `scenes/weapons/bullet_base.gd:179-181`
- Modify: `core/explosion.gd:28` + `:32`
- Modify: `scenes/weapons/laser_weapon_base.gd:222` + `:226`、`:236` + `:238`

**Interfaces:**
- Consumes: `CombatFeedback.attribute(victim, attacker) -> void`（`:60`）、`CombatFeedback.hit_marker() -> void`（`:36`）
- Produces: `CombatFeedback.attribute_hit(victim: Node, attacker: Node) -> void`

**⚠️ 只收 4 对，第 5 处不动：** `core/explosion.gd:55` 的玩家分支**只有 `attribute` 没有 `hit_marker`**（与敌人分支 `:28`+`:32` 不同）。这是现状行为，本计划**不改变它** —— 保持只写归因。

- [ ] **Step 1: 在 `combat_feedback.gd` 的 `attribute`（`:60-66`）之后插入**

```gdscript
## 归因 + 命中标记的一体入口:武器命中实体时的统一收尾。
## ★两件事必须都在**伤害调用之前**完成 —— EnemyBase.hurt()/take_hit 可能同帧判死,
## 死亡播报当场读 last_damager 的 meta(见 attribute 的注释)。散写成两行时极易漏掉先后顺序,
## 故收为一处。headless 服务器进程无 CombatFeedback 实例 → hit_marker 空操作,无副作用。
static func attribute_hit(victim: Node, attacker: Node) -> void:
	attribute(victim, attacker)
	hit_marker()
```

- [ ] **Step 2: 改 `bullet_base.gd`**

`:179-181` 的三行：

```gdscript
	# 归因写端统一入口(含射手无效/自伤守卫 + 归因时效戳,CombatFeedback 据此丢弃「蹭过一下」的旧归因)
	CombatFeedback.attribute(target, who)
	CombatFeedback.hit_marker()
```

改为：

```gdscript
	# 归因 + 命中标记的一体入口(含射手无效/自伤守卫 + 归因时效戳)
	CombatFeedback.attribute_hit(target, who)
```

`who` 的取值逻辑（`:176-178` 的 `shooter` 回落 `source`）保持不动。

- [ ] **Step 3: 改 `core/explosion.gd`（敌人分支）**

`:28` 与 `:32` 合成一处，插到 `e.hurt(...)`（`:30-31`）**之前**：

```gdscript
		# 归因 + 命中标记(一体入口;必须在 hurt 之前 —— 一击致死时 hurt 同帧判死,
		# _begin_death 当场读 last_damager 播报,写在之后则 meta 尚不存在 → 播报静默丢失)
		CombatFeedback.attribute_hit(e, shooter)
		# set_velocity=true:爆炸击退覆盖原速度,严格沿爆心→目标径向(不叠加鸟自身飞行速度带偏)
		e.hurt(int(dmg), _outward_dir(center, (e as Node2D).global_position),
				_falloff(d, radius, max_knockback) * cover * wmult, true)
```

即删除原 `:28` 那行与 `:32` 那行，只加一行 `attribute_hit`。**`:55` 的玩家分支保持 `CombatFeedback.attribute(pp, shooter)` 不变**（无 `hit_marker`）。

- [ ] **Step 4: 改 `laser_weapon_base.gd`（两处）**

`_apply_to_enemy` 里的 `:222` + `:226` 合为一行，位置排在 `t.hurt(...)`（`:229`）之前：

```gdscript
	CombatFeedback.attribute_hit(t, player)
```

`_apply_to_player` 里的 `:236` + `:238` 合为一行，位置排在 `p.take_hit(...)`（`:241`）之前：

```gdscript
	CombatFeedback.attribute_hit(p, player)
```

两处的 `# 击杀归因…必须写在 hurt 之前` 长注释块可精简为一行指回 `attribute_hit` 的文档注释；`:246-248` 的 `notify_direct_hit` 调用**保持不动**。

- [ ] **Step 5: 确认调用点数**

```bash
grep -rn "CombatFeedback\.\(attribute\|hit_marker\)(" --include=*.gd . | grep -v "^./.godot" | grep -v "^./tests"
```

Expected（生产代码恰好 5 处）：

```
core/explosion.gd:        attribute_hit ×1 + attribute ×1(玩家分支,无 hit_marker)
scenes/weapons/bullet_base.gd:      attribute_hit ×1
scenes/weapons/laser_weapon_base.gd: attribute_hit ×2
server/royale_host.gd:    attribute ×1(击杀归因,不属本次范围)
scenes/pvp_client.gd / scenes/royale_game.gd: hit_marker ×1 each(消费端,不属本次范围)
```

- [ ] **Step 6: 回归冒烟（用户执行）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`，退出码 0。

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/feedback_probe.gd
```

Expected: 通过（该探针直接测 `CombatFeedback.attribute` 的三条守卫：正常/自伤/无射手）。

- [ ] **Step 7: 提交**

```bash
git add scenes/effects/combat_feedback.gd scenes/weapons/bullet_base.gd core/explosion.gd scenes/weapons/laser_weapon_base.gd
git commit -m "refactor(feedback): 抽 CombatFeedback.attribute_hit 收「归因+命中标记」4 对调用点——两件事都必须在伤害调用之前,散写极易漏序;爆炸的玩家分支保持只有归因(现状无 hit_marker),不改变行为"
```

---

### Task 7: 敌人死亡流程收口（`_on_death()` 虚钩 + `_apply_charge_impact` 上提）

**Files:**
- Modify: `scenes/enemies/enemy_base.gd:223-231`（`_begin_death` 加虚钩调用）、新增 `_on_death()` 与 `_apply_charge_impact()`
- Modify: `scenes/enemies/enemy_black_bird.gd:360-366`（**删 `hurt()`**）、`:337-348`（`_apply_charge_impact` 改转发）
- Modify: `scenes/enemies/enemy_jump_bird.gd:113-123`（删 `hurt()`）、新增 `_on_death()`
- Modify: `scenes/enemies/enemy_fly_bird.gd:193-200`（**删 `hurt()`**）、`:203-213`（`_die_self` 瘦身）、`:419-430`（`_apply_charge_impact` 改转发）

**Interfaces:**
- Consumes: `EnemyBase._begin_death()`（`:223`）、`EnemyBase._apply_hit(...)`（`:150`）、`EnemyBase._apply_knock_only(...)`（`:163`）
- Produces:
  - `EnemyBase._on_death() -> void`（空虚钩；子类覆写）
  - `EnemyBase._smash_player(p: Node, impact: float, impact_up: float) -> void`
    （**名字不能叫 `_apply_charge_impact`** —— 见 Step 2 的说明）

**背景（已核实）：** `EnemyBase.hurt()`（`:138-145`）与 `BlackBird.hurt()`（`:360-366`）**逐字相同**；`JumpBird.hurt()`（`:113-123`）是基类 + `_anim.play("dead")`；`FlyBird.hurt()`（`:193-200`）是基类但调 `_die_self()`。四份 `hurt` 的分叉点只在**死亡那一刻的附加动作**，正该由虚钩承载。`_apply_charge_impact` 在两个鸟里除参数常量外逐字相同（含 `away == Vector2.ZERO` 回退）。

- [ ] **Step 1: `enemy_base.gd` 加虚钩**

把 `_begin_death()`（`:223-231`）末尾改为调用虚钩：

```gdscript
func _begin_death() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
	# 击杀播报(CombatFeedback):只有玩家造成的死亡才出「击杀 XXX」文字+音效
	# (子弹/爆炸命中时写入的 last_damager meta 归因;溺水等环境死安静销毁)
	CombatFeedback.notify_enemy_killed(self)
	_death_timer = EnemyParams.shared.death_flash_time
	_on_death()


# 死亡瞬间的附加动作虚钩(基类空实现)。子类在此追加专属处理:
# JumpBird 播 dead 动画、FlyBird 清冲撞速度并开重力 —— 这样各子类不必再整份覆写 hurt()。
# 调用点在 _death_timer 赋值之后:白闪计时已成立,子类里改 velocity/use_gravity 不影响它。
func _on_death() -> void:
	pass
```

- [ ] **Step 2: `enemy_base.gd` 加 `_smash_player`**

> ⚠ **修正（执行期实测）**：原计划让基类方法沿用 `_apply_charge_impact` 这个名字，**是错的**。
> 两个子类各自持有同名但**两参**的包装方法，而 GDScript 不允许子类以不同签名覆写父类方法：
> 会 `Parse Error: The function signature doesn't match the parent`，**子类脚本整份加载失败**。
> 后果特别隐蔽 —— `-s` 冒烟里 `_initialize()` 抛错后永远走不到 `quit()`，SceneTree 空转，
> 表现为**挂死**（`timeout` 返回 124）而不是报错退出，日志里只有一行 Parse Error 混在退出期噪声里。
> 故基类另起名 `_smash_player`，子类形如 `super.` 的调用一律改为直接转调它。

在 `_on_death()` 之后插入：

```gdscript
# 冲锋冲击力:沿远离本体的方向猛推玩家(覆盖 take_hit 的普通击退,冲锋更狠)。
# 原本 FlyBird / BlackBird 各抄一份(除常量外逐字相同),收为基类单一来源。
# away 为 0(与玩家完全重合)时回退:朝玩家背向推,拿不到 get_facing 就用 LEFT。
# ★名字刻意不叫 _apply_charge_impact:两个子类各自持有同名但**两参**的包装方法,而
#   GDScript 不允许子类以不同签名覆写父类方法(会 Parse Error,且整个子类脚本加载失败
#   → `-s` 冒烟里 _initialize 抛错、永不 quit = 挂死)。故基类另起名,子类包装转调这里。
func _smash_player(p: Node, impact: float, impact_up: float) -> void:
	var p2 := p as Node2D
	if p2 == null:
		return
	var away := (p2.global_position - global_position).normalized()
	if away == Vector2.ZERO:
		away = Vector2.LEFT
		if p2.has_method("get_facing"):
			away.x = -float(p2.get_facing())
	p2.velocity = away * impact
	p2.velocity.y -= impact_up
```

- [ ] **Step 3: `enemy_black_bird.gd` 删 `hurt()`**

删除 `:360-366` 整段：

```gdscript
func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		_apply_knock_only(knock_dir, knock_strength, set_velocity)
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		_begin_death()
```

（与基类逐字相同，无需任何替代 —— 基类版本直接生效。）

- [ ] **Step 4: `enemy_black_bird.gd` 的 `_apply_charge_impact` 改转发**

把 `:337-348` 整段：

```gdscript
# 冲锋冲击力:沿远离黑鸟的方向猛推玩家(覆盖 take_hit 的普通击退,冲锋更狠,同飞鸟)。
func _apply_charge_impact(p: Node) -> void:
	var p2 := p as Node2D
	if p2 == null:
		return
	var away := (p2.global_position - global_position).normalized()
	if away == Vector2.ZERO:
		away = Vector2.LEFT
		if p2.has_method("get_facing"):
			away.x = -float(p2.get_facing())
	p2.velocity = away * EnemyParams.BlackBird.charge_impact
	p2.velocity.y -= EnemyParams.BlackBird.charge_impact_up
```

改为：

```gdscript
# 冲锋冲击力:沿远离黑鸟的方向猛推玩家(实现收在 EnemyBase,同飞鸟)。
func _apply_charge_impact(p: Node) -> void:
	_smash_player(p, EnemyParams.BlackBird.charge_impact, EnemyParams.BlackBird.charge_impact_up)
```

`:329-334` 的 `_on_charge_hit_player()` 调用点不用改（方法名与签名不变）。

- [ ] **Step 5: `enemy_jump_bird.gd` 换虚钩**

把 `:113-123` 整段 `hurt()` 改为：

```gdscript
# 死亡:基类走 _begin_death → 本虚钩;播一次性死亡动画。
# 死亡不清击退速度、保留碰撞箱、物理与生前一致(重力/摩擦照常)。
func _on_death() -> void:
	_anim.play("dead")
```

- [ ] **Step 6: `enemy_fly_bird.gd` 删 `hurt()`、瘦身 `_die_self()`、换虚钩**

删除 `:193-200` 整段 `hurt()`。

把 `:203-213` 的 `_die_self()` 改为：

```gdscript
# 死亡:白闪后销毁(冲撞自毁与受击死亡同走本方法)。附加拿冲撞速度/开重力在 _on_death。
func _die_self() -> void:
	_begin_death()  # 内置 is_dead 守卫;死亡白闪计时 + 到期销毁由基类统一
```

并新增：

```gdscript
# 死亡瞬间:冲撞中死(含被打死/超时)清冲撞速度,尸体不再续冲。撞墙/撞玩家的死亡已由
# move_and_slide 抵消速度,归零无副作用;普通受击仍保留击退滑出感。
# 其余死亡保留击退速度 + 开重力,带白闪飞出后消失(不像 JumpBird 清速度定格)。
func _on_death() -> void:
	if state == State.CHARGE:
		velocity = Vector2.ZERO
	use_gravity = true
```

- [ ] **Step 7: `enemy_fly_bird.gd` 的 `_apply_charge_impact` 改转发**

`:419-430` 整段改为：

```gdscript
# 冲撞冲击力:沿远离鸟的方向猛推玩家(实现收在 EnemyBase,同黑鸟)。
func _apply_charge_impact(p: Node) -> void:
	_smash_player(p, EnemyParams.FlyBird.charge_impact, EnemyParams.FlyBird.charge_impact_up)
```

- [ ] **Step 8: 确认四份 hurt 已收敛**

```bash
grep -rn "^func hurt" --include=*.gd scenes/ | grep -v "^./.godot"
```

Expected: 只剩 `scenes/enemies/enemy_base.gd:138`（`EnemyFlyBase` 若有覆写也应消失 —— 当前无）。

- [ ] **Step 9: 回归冒烟（用户执行）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`，退出码 0。

**行为等价性必须由用户确认的三点**（探针覆盖不到）：① 跳跳鸟死亡仍播 `dead` 动画；② 飞鸟冲撞中死仍清冲撞速度；③ 黑鸟受击/死亡与原先一致。

- [ ] **Step 10: 提交**

```bash
git add scenes/enemies/enemy_base.gd scenes/enemies/enemy_black_bird.gd scenes/enemies/enemy_jump_bird.gd scenes/enemies/enemy_fly_bird.gd
git commit -m "refactor(enemies): 死亡附加动作收进 _on_death 虚钩 + _apply_charge_impact 上提基类——四个 hurt() 的分叉点只在死亡那一刻(JumpBird 播 dead / FlyBird 清冲撞速度),黑鸟那份与基类逐字相同直接删;冲锋冲击力两只鸟除常量外逐字相同"
```

---

### Task 8: 抽 `core/collision_aabb.gd`，收敛三处「扫子碰撞体求世界 AABB」

**Files:**
- Create: `core/collision_aabb.gd`
- Modify: `core/water.gd:95-116`（`_feet_offset_compute` 改转发；`_feet_signature` 与 `feet_offset` 的缓存**保持不动**）
- Modify: `scenes/weapons/laser_weapon_base.gd:160-184`（`_body_half` 改转发）
- Modify: `scenes/enemies/enemy_fly_base.gd:172-220`（`_collision_rect_of` 改转发，末尾的 `anchor_to_nearest` 留在调用方）

**Interfaces:**
- Consumes: 无
- Produces:
  - `CollisionAabb.world_rect(n: Node2D) -> Rect2`（只并**启用**的碰撞体；无任何启用碰撞体时返回以 `n.global_position` 为中心的 0 尺寸矩形）
  - `CollisionAabb.has_any(n: Node2D) -> bool`

**背景（已核实）：** 三处各写一遍「遍历子节点 → 跳过 disabled → Polygon 逐点 `to_global` / RectangleShape2D 取角 → 合并」。`enemy_fly_base` 的版本多支持 `CircleShape2D`（是超集），故统一版支持圆。三处兜底值**各不相同且各自调过**，必须由调用方自备，不能收进共享函数。

**⚠️ 行为差异提示：** `water._feet_offset_compute` 与 `laser._body_half` 原先**忽略** `CircleShape2D`；统一版会把它算进去。当前 `Player.tscn` 与敌人场景均无圆形碰撞体，故实际无差异 —— 但这是本 Task 唯一的行为面，需在提交信息里写明。

- [ ] **Step 1: 建 `core/collision_aabb.gd`**

```gdscript
class_name CollisionAabb
extends RefCounted

# 从任意节点求「启用中的碰撞体」在世界系的几何。纯静态、不引 autoload(-s 可空跑),
# 与 core/collision_builder.gd 同风格。
#
# ★只并**启用**的碰撞体(disabled 跳过):姿态碰撞箱(玩家蹲/站/飞、飞鸟站/飞两套)
# 运行时靠 disabled 切换,合并禁用箱会把命中框/避障框/脚底偏移撑得比实际碰撞体大一圈。
#
# 原本在 water / laser_weapon_base / enemy_fly_base 各写一遍,合并为单一来源。
# 兜底值(水 24px / 激光 18px / 鸟 40×40)是各自的调参结果,**由调用方自备**,不在这里统一。


# 该节点是否有任何启用中的碰撞体。
static func has_any(n: Node2D) -> bool:
	for child in n.get_children():
		if child is CollisionShape2D and not (child as CollisionShape2D).disabled:
			return true
	return false


# 启用中碰撞体的世界 AABB(多边形顶点 / 矩形角 / 圆的外接方框)。无启用碰撞体时返回
# 以 n.global_position 为中心的 0 尺寸矩形(调用方据此判 has_any 走自己的兜底)。
static func world_rect(n: Node2D) -> Rect2:
	var rect := Rect2(n.global_position, Vector2.ZERO)
	var has := false
	for child in n.get_children():
		# CollisionPolygon2D 继承自 CollisionShape2D,先判多边形,否则走 shape 分支会被跳过。
		if not (child is CollisionShape2D):
			continue
		if (child as CollisionShape2D).disabled:
			continue
		var r: Rect2
		if child is CollisionPolygon2D:
			var cp := child as CollisionPolygon2D
			var pts := cp.polygon
			if pts.size() == 0:
				continue
			var mn := cp.to_global(pts[0])
			var mx := mn
			for pt in pts:
				var wp := cp.to_global(pt)
				mn = mn.min(wp)
				mx = mx.max(wp)
			r = Rect2(mn, mx - mn)
		else:
			var cs := child as CollisionShape2D
			var shape := cs.shape
			if shape == null:
				continue
			if shape is RectangleShape2D:
				var size := (shape as RectangleShape2D).size * cs.global_scale
				r = Rect2(cs.global_position - size * 0.5, size)
			elif shape is CircleShape2D:
				var rad := (shape as CircleShape2D).radius * maxf(cs.global_scale.x, cs.global_scale.y)
				r = Rect2(cs.global_position - Vector2(rad, rad), Vector2(rad, rad) * 2.0)
			else:
				continue
		rect = r if not has else rect.merge(r)
		has = true
	return rect
```

- [ ] **Step 2: 刷全局类缓存**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import
```

Expected: 无 Parse Error。

- [ ] **Step 3: 改 `core/water.gd`**

`_feet_signature`（`:86-92`）与 `feet_offset`（`:75-83`）的缓存逻辑**原样保留**，只替换 `_feet_offset_compute`（`:95-116`）：

```gdscript
# 实体脚底相对原点偏移(世界 px):取启用碰撞箱底边;找不到回退 24。
# 该值只随「启用的碰撞体集合」变化(纯平移/固定几何下相对偏移不变),故按签名缓存(见 feet_offset)。
static func _feet_offset_compute(body: Node) -> float:
	var b := body as Node2D
	if b == null or not CollisionAabb.has_any(b):
		return 24.0
	return maxf(24.0, CollisionAabb.world_rect(b).end.y - b.global_position.y)
```

- [ ] **Step 4: 改 `scenes/weapons/laser_weapon_base.gd`**

把 `_body_half`（`:160-184`）整段替换为：

```gdscript
# 目标在世界系的半身(px)。兜底 18px(近似半身)。几何取自 CollisionAabb(只并启用中的碰撞体,
# 兼容玩家/飞鸟的多姿态碰撞箱)。
func _body_half(n: Node2D) -> Vector2:
	if not CollisionAabb.has_any(n):
		return Vector2(18, 18)
	return CollisionAabb.world_rect(n).size * 0.5
```

- [ ] **Step 5: 改 `scenes/enemies/enemy_fly_base.gd`**

把 `_collision_rect_of`（`:172-220`）替换为：

```gdscript
# 求一个节点的世界碰撞 AABB。几何取自 CollisionAabb(只并**激活**的碰撞体:disabled 跳过 ——
# 飞行鸟的站立箱运行时被禁用,合并它会把障碍箱撑得比实际碰撞体大一圈)。
# 返回前把矩形中心锚到本鸟坐标的环面副本,与 BFS 候选格同帧(见 _bird_can_pass)。
func _collision_rect_of(n: Node2D) -> Rect2:
	var rect: Rect2
	if CollisionAabb.has_any(n):
		rect = CollisionAabb.world_rect(n)
	else:
		rect = Rect2(n.global_position - Vector2(20, 20), Vector2(40, 40))
	var center := rect.get_center()
	var anchored := MazeGenerator.anchor_to_nearest(center, global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return Rect2(anchored - rect.size * 0.5, rect.size)
```

- [ ] **Step 6: 确认三处旧实现已消失**

```bash
grep -rn "to_global(pts\[0\])\|for corner in \[Vector2(-hs" --include=*.gd core/ scenes/ | grep -v "^./.godot" | grep -v "collision_aabb"
```

Expected: 无输出（逐点扫多边形的写法只剩 `collision_aabb.gd` 自己那一份，故排除它）。

- [ ] **Step 7: 回归冒烟（用户执行）**

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
```

Expected: `SMOKE OK`，退出码 0。

```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/laser_weapon_smoke.gd
```

Expected: `SMOKE OK`，退出码 0（**实测成功串就是 `SMOKE OK`**，21 条 ok；原计划写的 `LASER SMOKE OK` 是错的）。
该冒烟验 `_emit_beam` 三缝与命中几何，会走到 `_body_half`。另可加跑 `-s res://tests/water_probe.gd`（成功串 `WATER OK`），覆盖 `Water.feet_offset` 的改点。

- [ ] **Step 8: 提交**

```bash
git add core/collision_aabb.gd core/collision_aabb.gd.uid core/water.gd scenes/weapons/laser_weapon_base.gd scenes/enemies/enemy_fly_base.gd
git commit -m "refactor(core): 抽 CollisionAabb 收「扫子碰撞体求世界 AABB」三处副本——water 脚底偏移/激光命中半身/飞鸟避障矩形各写一遍,「只并启用中的碰撞体」这条语义散在三处;兜底值(24/18/40×40)仍由调用方自备。注:统一版多支持 CircleShape2D,当前无场景使用圆形碰撞体,实际无行为差异"
```

---

## 批次收尾

- [ ] **跑全文检索确认无遗留副本**

```bash
grep -rn "_approach\|toroidal_delta_px(pa, pb" --include=*.gd core/ scenes/ | grep -v "^./.godot"
```

- [ ] **跑全部 KH 探针（用户执行，判据是 grep `ALL-OK`）**

```bash
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
"$GODOT" --headless --path . --quit-after 600 res://tests/kh_l1_probe.tscn 2>&1 | grep ALL-OK
"$GODOT" --headless --path . --quit-after 600 res://tests/kh_l3_probe.tscn 2>&1 | grep ALL-OK
"$GODOT" --headless --path . --quit-after 600 res://tests/kh_l4_probe.tscn 2>&1 | grep ALL-OK
"$GODOT" --headless --path . --quit-after 600 res://tests/kh_l5_probe.tscn 2>&1 | grep ALL-OK
"$GODOT" --headless --path . --quit-after 600 res://tests/kh_l6_probe.tscn 2>&1 | grep ALL-OK
```

Expected: 五条各打印一行 `ALL-OK`。任何一条没有输出即失败（**不要**只看退出码）。

- [ ] **真机验收（用户执行）**：进单机跑一局（打树叶/树干、落水、被黑鸟冲锋），确认击杀播报、命中 X 标记、溺水扣血、敌人死亡表现无变化。

---

## 本计划明确不做的事（后续独立计划）

以下来自同一份审查，但**不属本批次**，各自需要独立的计划与决策：

1. **批次 2（最高价值，被探针卡住）**：`pvp_client.gd` ↔ `royale_game.gd` 的事件消费层合并（约 200 行）、`matchmaking.gd` ↔ `royale_lobby.gd` 的连接状态机合并（约 180 行）。**前置**：先决定 `kh_l6_probe` 这类「钉源码文本」的探针怎么办 —— 它们会因合并变红（如 `NetBus.local_beam_fired` 必须恰好在 `pvp_client.gd` 出现 1 次、C2 组包字典必须留在 `_physics_process` 内）。
2. **批次 3**：四个玩家组件各加 `capture_state/restore_state`（键名一字不改）→ 再抽 `PlayerNetSync`；`enemy_logic_smoke.gd` 那个 861 行的 `_initialize()` 按章节切分。
3. **批次 4**：`core/maze_generator.gd`（696 行）委托式拆 `grid_pathfinder.gd` + `map_format.gd`；`weapon_base.gd`（545 行）拆 `weapon_preview.gd` + `weapon_reload.gd`；`match_host.gd` 的 `ENABLE_BIRDS=false` 鸟链（84 行）搬到 `server/bird_roster.gd`。
4. **测试脚手架**：`tests/lib/scan_util.gd` + `probe_base.gd`（`kh_l*_probe` 的扫描工具函数已复制 5 遍）。注意 `kh_l5_probe.gd:44` 的 `ALL_DIRS` **含 `res://tests`**，新增的 lib 源码不得含被扫的字面量（如非 16 倍数字号）。
5. **生成物守卫**：给 `level_editor/sync-tiles.js` 加 `--check` 模式（改了 `data/tile_defs.json` 忘跑脚本会静默漂移）。
6. **`UiFactory` 补齐（决策：本批次故意不做）**：缺 `check` / `line_edit` / `slider_row` / `apply_font_recursive`，导致 `settings_menu.gd:157-183`、`matchmaking.gd:207-235`、`royale_lobby.gd:152-155,258-273` 各自造包装、同一段注释抄三遍。**不放进批次 1 的原因**：三个调用点里有两个（`matchmaking` / `royale_lobby`）正是批次 2 要整体重构的文件 —— 现在改会在合并时产生无谓冲突。**等批次 2 落地后再做**，届时调用点只剩 `settings_menu` 与新抽出的面板类。
7. **睡眠/唤醒状态机上提（决策：本批次故意不做）**：`enemy_fly_bird.gd:75-91`、`enemy_black_bird.gd:78-104`、`enemy_jump_bird.gd:47-58` 三处同构。**不放进批次 1 的原因**：它会一并触及 `enemy_base.gd:175` 那个隐式契约 —— `_is_far_sleeping()` 硬编码 `state != 0`，隐含「所有子类 `State.SLEEP == 0`」，抽睡眠逻辑时**必须同时把这个契约显式化**（否则新敌人一旦 SLEEP≠0 会静默失去睡眠优化）。这已超出「纯函数搬运、行为零变化」的批次 1 边界。建议单独立项。
8. **未纳入本计划的既有小项**（各自独立、可随时做）：`world_label.gd` 绕过 `PixelFont.shared()` 自建字体；`combat_feedback` 的 `_streak_label` 未走 `UiFactory`；`enemies/_water_swim_dir` 与 `_align_contact_area` 的跨子类同构；`player.gd` 的氧气计量与 `EnemyBase._apply_water` 是同一逻辑两份实现；`_disk_overlaps_solid` 的 1 生产 + 3 探针副本。

## 已排除的伪发现（勿重复排查）

- **`data/tile_defs.json` 未列入 `export_presets.cfg` 的 `include_filter`** —— 看似漏打包，实测**不是问题**：按内容判定（用 JSON 独有的 `"name": "水", "type": "liquid"` 间距串）该文件确实在导出 exe 内。`.json` 是 Godot 认得的资源类型，只有 `.cyrm`/`.js` 才需要显式白名单；`data/enemies.json` 那一条是冗余但无害。
- **`server/match_host.gd` 的 `_dbg_kill_t` / `kill_dbg.txt` 调试残留** —— 审查过程中该代码已被移除，全仓 `grep "_dbg_kill\|kill_dbg\|\[TEMP\]"` 无命中，**无需处理**。
