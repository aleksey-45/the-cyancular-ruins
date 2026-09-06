# PvP 打墙命中反馈(TileHitFx)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PvP 客户端视觉副本子弹撞可破坏砖(树叶/树干)时本地播一次 TileHitFx 碎片(纯视觉),与单机一致的命中反馈;damage 仍只由权威裁决,客户端不拆本地 grid。

**Architecture:** 只改 `scenes/weapons/bullet_base.gd` 两个点:①撞墙 else 分支去掉 `if apply_damage:` 包裹;②`_damage_tile_at` 内把 `TileHitFx.spawn` 移出 `if apply_damage`(改成 damage_tile 加守卫)。单机/服务器 `apply_damage=true` 行为不变。

**Tech Stack:** Godot 4.7.1 GDScript。headless 冒烟(SceneTree / scene 模式)。

## Global Constraints

- Godot 4.7.1 标准编辑器,headless 跑冒烟。
- **幽灵墙纪律(硬约束)**:视觉副本(apply_damage=false)**绝不**调 `TileDefs.damage_tile`,不改本地 `MazeGenerator.current_grid` / hp_grid——拆墙渲染只由服务器 `tile_destroyed` 事件驱动客户端刷新。
- 撞不可破坏墙(石头)仍无粒子(探格非 bullet_destroyable 即 return)。
- 爆炸路径 `Explosion._damage_tiles` 不纳入本次。
- 不改协议 / 不加 RPC。
- 完成后跑回归:enemy_logic + pvp_reconcile/twin/match 须绿。

---

## File Structure

- **Modify** `scenes/weapons/bullet_base.gd`
  - 撞墙 else 分支(现 95-106):去 `if apply_damage:` 包裹 → 恒调 `_damage_tile_at`。
  - `_damage_tile_at`(现 136-154):`TileHitFx.spawn` 无条件;`TileDefs.damage_tile` 加 `if apply_damage:` 守卫;更新注释。
- **Create** `tests/bullet_tile_fx_smoke.gd` / `.tscn` / `.sh`(可选做,若实现成本过高可退化为源码级检查,见 Task 2)。

---

### Task 1: bullet_base 拆"播碎片"与"damage"

**Files:**
- Modify: `scenes/weapons/bullet_base.gd:95-106`(撞墙 else 分支)
- Modify: `scenes/weapons/bullet_base.gd:135-154`(`_damage_tile_at`)

**Interfaces:**
- Produces: 视觉副本(apply_damage=false)撞 bullet_destroyable 砖 → 播 TileHitFx、不 damage;apply_damage=true 行为不变。

- [ ] **Step 1: 撞墙 else 分支去掉 apply_damage 包裹**

现 95-106:
```gdscript
		else:
			# 撞墙:可破坏(树叶/树干)→ 扣血;不可破坏墙 → 子弹消失。延迟销毁确保破坏回调跑完。
			# PvP 视觉子弹副本(apply_damage=false)不裁决伤害,也不准拆本地瓦片:
			# 若在此拆,客户端 grid/子格会跑在服务器权威之前——双方随机散布/瞄准时点不同,
			# 客户端常拆掉服务器从未破坏的树叶 → 本地看着是缺口、服务器那侧碰撞还在(幽灵墙)。
			# 拆墙一律只由服务器 tile_destroyed 事件驱动客户端刷新。
			if apply_damage:
				_damage_tile_at(col.get_position(), col.get_normal())
			set_physics_process(false)
			velocity_vec = Vector2.ZERO
			get_tree().create_timer(0.05).timeout.connect(queue_free)
			return
```
改为:
```gdscript
		else:
			# 撞墙:可破坏(树叶/树干)→ 播受击碎片 + (权威侧)扣血;不可破坏墙 → 子弹消失。
			# 延迟销毁确保破坏回调跑完。
			# PvP 视觉子弹副本(apply_damage=false)也走这里——只播碎片(即时命中反馈),
			# 但 damage_tile 只在 apply_damage(权威侧)执行,客户端绝不自拆本地瓦片(幽灵墙纪律,
			# 拆墙渲染只由服务器 tile_destroyed 事件驱动刷新)。
			_damage_tile_at(col.get_position(), col.get_normal())
			set_physics_process(false)
			velocity_vec = Vector2.ZERO
			get_tree().create_timer(0.05).timeout.connect(queue_free)
			return
```

- [ ] **Step 2: `_damage_tile_at` 内 damage 加守卫、spawn 无条件**

现 135-154:
```gdscript
# 撞墙处理:若该格可子弹破坏(树叶/树干)则扣血 + 受击粒子;破坏后变空气(Level0 刷新渲染/碰撞)。
func _damage_tile_at(pos: Vector2, normal: Vector2) -> void:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return
	var ts: int = GameParameters.TILE_SIZE
	var cols := grid[0].size()
	var rows := grid.size()
	# 候选格:碰撞点、沿法线推入墙内 0.5/1 格 —— 处理贴边命中/边界浮点映射到墙前空格。
	# normal 指向远离墙(朝子弹),-normal 即推入墙内。
	var probes := [Vector2.ZERO, -normal * (ts * 0.5), -normal * ts]
	for off in probes:
		var cell := MazeGenerator.cell_of(pos + off, ts, cols, rows)
		var v: int = grid[cell.y][cell.x]
		if v != 0:
			var tex: int = v / 16
			if TileDefs.bullet_destroyable(tex):
				TileDefs.damage_tile(cell, hit_damage, "bullet")
				TileHitFx.spawn(get_viewport(), pos, tex)
			return
```
改为:
```gdscript
# 撞墙处理:命中可子弹破坏的格(树叶/树干)→ 播受击碎片(无条件,单机/PvP 视觉副本同款即时反馈);
# damage_tile 扣血只在权威侧(apply_damage=true)执行,破坏后变空气(Level0 刷新渲染/碰撞)。
# 视觉副本(apply_damage=false)只播碎片、绝不拆本地 grid——拆墙渲染由服务器 tile_destroyed 事件驱动。
func _damage_tile_at(pos: Vector2, normal: Vector2) -> void:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return
	var ts: int = GameParameters.TILE_SIZE
	var cols := grid[0].size()
	var rows := grid.size()
	# 候选格:碰撞点、沿法线推入墙内 0.5/1 格 —— 处理贴边命中/边界浮点映射到墙前空格。
	# normal 指向远离墙(朝子弹),-normal 即推入墙内。
	var probes := [Vector2.ZERO, -normal * (ts * 0.5), -normal * ts]
	for off in probes:
		var cell := MazeGenerator.cell_of(pos + off, ts, cols, rows)
		var v: int = grid[cell.y][cell.x]
		if v != 0:
			var tex: int = v / 16
			if TileDefs.bullet_destroyable(tex):
				TileHitFx.spawn(get_viewport(), pos, tex)   # 纯反馈:命中即可破坏砖就播
				if apply_damage:
					TileDefs.damage_tile(cell, hit_damage, "bullet")
			return
```

- [ ] **Step 3: 验证解析**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --import`
Expected: 退出 0,无 parse error。

- [ ] **Step 4: Commit**

```bash
git add scenes/weapons/bullet_base.gd
git commit -m "feat: 子弹撞可破坏砖播碎片解耦 apply_damage——PvP 视觉副本也播命中反馈但不拆格"
```

---

### Task 2: 源码级结构检查冒烟(播碎片无条件 + damage 守卫权威)

**Files:**
- Create: `tests/bullet_tile_fx_smoke.gd`
- Create: `tests/bullet_tile_fx_smoke.tscn`(占位,便于 .sh 统一跑法)

**Interfaces:**
- Consumes: Task 1 的行为。
- Produces: `SMOKE_BULLET_TILE_FX OK`(退出 0)/ `FAIL`(退出 1)。

> **为何选源码级而非物理造弹**:本改动是"结构正确性"——`TileHitFx.spawn` 无条件、`damage_tile` 只在权威侧。物理冒烟(造真实子弹飞行撞墙、统计 viewport 下 CPUParticles2D)在 headless 依赖碰撞/生命周期/渲染节点,脆弱且无法断言"这粒粒子是不是 TileHitFx 播的"。读源码断言结构更稳、直接锁住防回退点,参考 `tests/player_contract_smoke.gd`(已是读源码保接口风格)。

- [ ] **Step 1: 写 `tests/bullet_tile_fx_smoke.gd`**

```gdscript
extends SceneTree
# PvP 打墙命中反馈——源码级结构检查(仿 player_contract_smoke 读源码断言风格):
# 锁住 bullet_base.gd 的关键结构不被回退——
#  1) `_damage_tile_at` 内 TileHitFx.spawn 在 `if apply_damage:` 之前(播碎片无条件);
#  2) `damage_tile(cell,` 调用被 `if apply_damage:` 包住(damage 只在权威侧);
#  3) 撞墙 else 分支直接调 `_damage_tile_at`,不受 `if apply_damage:` 包裹(视觉副本也走)。
# 跑法:用户自跑。通过 = SMOKE_BULLET_TILE_FX OK。

var _fail := ""

func _init() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/weapons/bullet_base.gd")
	if src.is_empty():
		_fail = "无法读取 bullet_base.gd"
		_finish()
		return
	_check(src)
	_finish()

func _check(src: String) -> void:
	# 1) spawn 无条件:在 _damage_tile_at 体内,spawn 行必须先于第一个 `if apply_damage:`。
	#    取 _damage_tile_at 函数体(从 func 声明到下一个 func)。
	var fn_start := src.find("func _damage_tile_at")
	if fn_start < 0:
		_fail = "未找到 _damage_tile_at"; return
	var fn_body_start := src.find("\n", fn_start)
	var fn_end := src.find("\nfunc ", fn_body_start)
	if fn_end < 0:
		fn_end = src.length()
	var body := src.substr(fn_body_start, fn_end - fn_body_start)
	var spawn_idx := body.find("TileHitFx.spawn")
	var damage_idx := body.find("damage_tile(cell")
	var guard_idx := body.find("if apply_damage:")
	if spawn_idx < 0:
		_fail = "_damage_tile_at 内无 TileHitFx.spawn"; return
	if damage_idx < 0:
		_fail = "_damage_tile_at 内无 damage_tile(cell"; return
	if guard_idx < 0:
		_fail = "_damage_tile_at 内无 `if apply_damage:`"; return
	if spawn_idx > guard_idx:
		_fail = "TileHitFx.spawn 出现在 `if apply_damage:` 之后(播碎片被权威开关挡住了,应无条件)"; return
	if damage_idx < guard_idx:
		_fail = "damage_tile(cell 出现在 `if apply_damage:` 之前(damage 未守权威)"; return
	# 2) 撞墙 else 分支直接调 _damage_tile_at,不受 apply_damage 包裹。
	#    粗查:全文里 `_damage_tile_at(col.get_position()` 不应紧跟 `if apply_damage:` 之前两行内。
	var call_idx := src.find("_damage_tile_at(col.get_position()")
	if call_idx < 0:
		_fail = "未找到撞墙分支的 _damage_tile_at 调用"; return
	# 该调用若被 `if apply_damage:` 包住,源码里 call 之前 40 字符内会含那个 if;断言不含。
	var ctx := src.substr(maxi(0, call_idx - 80), call_idx - maxi(0, call_idx - 80))
	if ctx.find("if apply_damage:") >= 0:
		_fail = "撞墙分支 _damage_tile_at 仍被 `if apply_damage:` 包住(视觉副本走不到)"; return

func _finish() -> void:
	if not _fail.is_empty():
		print("SMOKE_BULLET_TILE_FX FAIL: %s" % _fail)
		quit(1)
		return
	print("SMOKE_BULLET_TILE_FX OK: spawn 无条件、damage 守权威、视觉副本走撞墙分支")
	quit(0)
```

- [ ] **Step 2: 写 `tests/bullet_tile_fx_smoke.tscn`**

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/bullet_tile_fx_smoke.gd" id="1"]

[node name="BulletTileFxSmoke" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 3: 写 `tests/bullet_tile_fx_smoke.sh`**

```bash
#!/usr/bin/env bash
# 打墙命中反馈——源码级结构检查。通过 = SMOKE_BULLET_TILE_FX OK 退出 0。用户自跑。
set -u
GODOT="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
LOG="tests/bullet_tile_fx_smoke.log"
"$GODOT" --headless --path . res://tests/bullet_tile_fx_smoke.tscn 2>&1 | tee "$LOG"
if grep -q "SMOKE_BULLET_TILE_FX OK" "$LOG"; then
  echo "[bullet_tile_fx] PASS"
  exit 0
else
  echo "[bullet_tile_fx] FAIL —— 见 $LOG"
  exit 1
fi
```

- [ ] **Step 4: 跑冒烟**

Run: `timeout 90 bash tests/bullet_tile_fx_smoke.sh`
Expected: `SMOKE_BULLET_TILE_FX OK` 退出 0。若 FAIL,按消息回到 Task 1 核对实际代码与计划是否一致(若实现正确但断言太脆,放宽断言范围到"spawn 先于 guard / damage 后于 guard",以能锁住结构为准)。

- [ ] **Step 5: Commit**

```bash
git add tests/bullet_tile_fx_smoke.gd tests/bullet_tile_fx_smoke.tscn tests/bullet_tile_fx_smoke.sh
git commit -m "test: 打墙命中反馈源码级冒烟(spawn 无条件、damage 守权威、视觉副本走撞墙)"
```

---

### Task 3: 回归

**Files:**
- 回归 4 个既有冒烟 + 本功能冒烟。

- [ ] **Step 1: 跑全量回归**

Run:
```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
bash tests/pvp_reconcile_smoke.sh
bash tests/pvp_twin_smoke.sh
bash tests/pvp_match_smoke.sh
bash tests/bullet_tile_fx_smoke.sh   # 或 -s 源码路线
```
Expected: 各自 OK / PASS。任一失败停下排查。

- [ ] **Step 2: Commit(若有文档/后续微调)**

无额外改动可不提交;若冒烟最终路线有取舍说明,补进测试文件注释后一起已在 Task 2 提交。

---

## Self-Review

- **Spec coverage:** 播碎片无条件(Task1 Step2)、damage 守卫权威(Task1 Step2)、视觉副本走撞墙分支(Task1 Step1)、单机不变(apply_damage=true 仍 damage+spawn)、撞永久墙无粒子(探格逻辑未动)、爆炸不纳入(未改 explosion.gd)。测试→Task2,回归→Task3。
- **Placeholder scan:** 无 TBD/TODO。Task2 定为源码级结构检查(有 player_contract_smoke 先例),无物理造弹占位。
- **Type/名称一致性:** 全程 `_damage_tile_at`/`apply_damage`/`TileHitFx.spawn`/`TileDefs.damage_tile`/`bullet_destroyable`,与现代码一致。
