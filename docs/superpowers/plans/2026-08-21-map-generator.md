# 地图生成器实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把结构编辑器扩展成地图生成器——整图模式 + 环面预览 + spawn 放置;地图文件记录玩家/敌人生成;游戏从地图读取出生点;敌人种类由共享 JSON 单一来源。

**Architecture:** 地图格式用 `#` 注释元数据行记录 spawn,网格保持纯 0/1;`editor/enemies.json` 是敌人注册表单一来源,游戏 `EnemySpawner.TYPES` 从它加载,HTML 内嵌副本由 node 脚本重新生成;编辑器加"整图模式"勾选,开启后渲染整张地图、可开环面平铺预览、可放 spawn。

**Tech Stack:** Godot 4.7 GDScript、纯 HTML+JS 单文件编辑器、node 脚本(`sync-enemies.js` 生成器 + `smoke.js` 测试)、JSON。

## Global Constraints

- 项目约定:冒烟测试(node `smoke.js` 与 Godot `enemy_logic_smoke.gd`)由用户跑,实现者不代跑。
- 地图网格保持纯 `0/1`;spawn 用 `#` 注释元数据行。
- 敌人注册表唯一来源是 `editor/enemies.json`;别处不硬编码敌人列表。
- 无 spawn 元数据时,游戏必须回退现有随机出生逻辑(向后兼容)。
- 编辑器结构库模式(默认)行为不变;整图模式是勾选启用。
- 每 Task 结束独立 commit。

---

### Task 1: Godot 地图 spawn 元数据解析

**Files:**
- Modify: `Globals/maze_generator.gd`(在 `load_map_file` 后加两个函数)
- Test: `Tests/enemy_logic_smoke.gd`(加一个 Task 块)

**Interfaces:**
- Consumes: `MazeGenerator.MAP_FILE`、`FileAccess`
- Produces: `MazeGenerator.parse_spawn_metadata(lines: Array) -> Dictionary`、`MazeGenerator.load_spawns() -> Dictionary`

- [ ] **Step 1: 写失败测试**

在 `Tests/enemy_logic_smoke.gd` 的 `# ── Task: 地图 spawn 元数据解析 ──` 位置(放在现有武器/切枪 Task 之后)加:

```gdscript
	# ── Task: 地图 spawn 元数据解析 ──
	_check(MazeGenerator.parse_spawn_metadata([
			"# demo_2", "# player 12 34",
			"# enemy jump_bird 100 50", "# enemy fly_bird 200 60",
			"00110"]).get("player") == Vector2i(12, 34),
			"parse_spawn_metadata: player 解析")
	var meta_enemies: Array = MazeGenerator.parse_spawn_metadata([
			"# enemy jump_bird 100 50", "# enemy fly_bird 200 60"]).get("enemies", [])
	_check(meta_enemies.size() == 2 and meta_enemies[0]["type"] == "jump_bird"
			and meta_enemies[0]["cell"] == Vector2i(100, 50)
			and meta_enemies[1]["type"] == "fly_bird",
			"parse_spawn_metadata: enemies 列表")
	_check(MazeGenerator.parse_spawn_metadata(["# 纯注释", "000"]).is_empty(),
			"parse_spawn_metadata: 无 spawn 指令返回空")
	_check(MazeGenerator.parse_spawn_metadata(
			["# player 12 34", "# player 56 78"]).get("player") == Vector2i(56, 78),
			"parse_spawn_metadata: player 最后一行生效")
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
```
Expected: 新 4 条断言 FAIL(函数未定义)。**注意:这条命令由用户跑,实现者不代跑;确认失败改由用户反馈。**

- [ ] **Step 3: 实现**

在 `Globals/maze_generator.gd` 的 `load_map_file()` 之后加:

```gdscript
# 解析地图文件的 spawn 元数据行(坐标=格,空格分隔)。
# 支持:# player <col> <row> 与 # enemy <type_id> <col> <row>。
# 返回 {"player": Vector2i, "enemies": [{"type": String, "cell": Vector2i}]};
# 无任何 spawn 指令返回空 Dictionary。player 多行时最后一行生效。非法行 push_warning 跳过。
static func parse_spawn_metadata(lines: Array) -> Dictionary:
	var result := {}
	var enemies: Array = []
	for line in lines:
		var text := String(line).strip_edges()
		if not text.begins_with("#"):
			continue
		var parts := text.substr(1).strip_edges().split(" ", false)
		if parts.is_empty():
			continue
		match parts[0]:
			"player":
				if parts.size() >= 3:
					var x := int(parts[1])
					var y := int(parts[2])
					if x >= 0 and y >= 0:
						result["player"] = Vector2i(x, y)
					else:
						push_warning("MazeGenerator: 非法 player 坐标 %s" % text)
			"enemy":
				if parts.size() >= 4:
					var type_id := parts[1]
					var x := int(parts[2])
					var y := int(parts[3])
					if x >= 0 and y >= 0 and not type_id.is_empty():
						enemies.append({"type": type_id, "cell": Vector2i(x, y)})
					else:
						push_warning("MazeGenerator: 非法 enemy 行 %s" % text)
			_:
				pass  # 普通 # 注释,忽略
	if enemies.size() > 0:
		result["enemies"] = enemies
	return result


# 从地图文件读取 spawn 元数据(与 load_map_file 各自读一遍;小文件可接受)。
static func load_spawns() -> Dictionary:
	if not FileAccess.file_exists(MAP_FILE):
		push_error("MazeGenerator: 找不到地图文件 %s" % MAP_FILE)
		return {}
	var f := FileAccess.open(MAP_FILE, FileAccess.READ)
	var lines: Array = []
	while not f.eof_reached():
		lines.append(f.get_line())
	f.close()
	return parse_spawn_metadata(lines)
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 命令。Expected: 4 条新断言 PASS,整份冒烟全 PASS。

- [ ] **Step 5: Commit**

```bash
git add Globals/maze_generator.gd Tests/enemy_logic_smoke.gd
git commit -m "feat: MazeGenerator 解析地图 spawn 元数据(# player/# enemy)"
```

---

### Task 2: 共享敌人 JSON + node 同步脚本 + HTML 注册表内嵌

**Files:**
- Create: `editor/enemies.json`
- Create: `editor/sync-enemies.js`
- Modify: `editor/structure-editor.html`(在首个 `<script>` 前插入注册表标记块)
- Modify: `editor/smoke.js`(加注册表断言)

**Interfaces:**
- Consumes: 无
- Produces: `window.ENEMY_REGISTRY`(HTML 内嵌,`[{id,name,scene,color}]`)、`editor/sync-enemies.js`(node 可执行)、`editor/enemies.json`

- [ ] **Step 1: 写失败测试**

在 `editor/smoke.js` 的 `final review` 段前加:

```js
// ---- Task: 敌人注册表(HTML 内嵌,来自 enemies.json)----
ok(Array.isArray(fakeWindow.ENEMY_REGISTRY) && fakeWindow.ENEMY_REGISTRY.length >= 2,
  'ENEMY_REGISTRY 已内嵌且含敌人');
var regIds = (fakeWindow.ENEMY_REGISTRY || []).map(function (e) { return e.id; });
ok(regIds.indexOf('jump_bird') >= 0 && regIds.indexOf('fly_bird') >= 0,
  'ENEMY_REGISTRY 含 jump_bird / fly_bird');
ok((fakeWindow.ENEMY_REGISTRY || []).every(function (e) {
  return e.id && e.name && e.scene && e.color;
}), 'ENEMY_REGISTRY 每项含 id/name/scene/color');
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node editor/smoke.js`
Expected: 新 3 条 FAIL(HTML 尚无 `ENEMY_REGISTRY`)。

- [ ] **Step 3: 创建 enemies.json**

新建 `editor/enemies.json`:

```json
{
  "enemies": [
    { "id": "jump_bird", "name": "JumpBird", "scene": "res://scenes/Enemies/EnemyJumpBird.tscn", "color": "#6fae8f" },
    { "id": "fly_bird", "name": "FlyBird", "scene": "res://scenes/Enemies/EnemyFlyBird.tscn", "color": "#c96fb0" }
  ]
}
```

- [ ] **Step 4: 创建 sync-enemies.js**

新建 `editor/sync-enemies.js`:

```js
'use strict';
// 从 editor/enemies.json 重新生成 structure-editor.html 内嵌的敌人注册表
// (/*__ENEMY_REGISTRY_BEGIN__*/ ... /*__ENEMY_REGISTRY_END__*/ 之间)。
// 用法:node editor/sync-enemies.js
const fs = require('fs');
const path = require('path');

const dir = __dirname;
const jsonPath = path.join(dir, 'enemies.json');
const htmlPath = path.join(dir, 'structure-editor.html');

const json = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const enemies = (json.enemies || []).map(function (e) {
  return {
    id: String(e.id),
    name: String(e.name),
    scene: String(e.scene),
    color: String(e.color || '#999999')
  };
});
const block = '/*__ENEMY_REGISTRY_BEGIN__*/\nwindow.ENEMY_REGISTRY = ' +
  JSON.stringify(enemies, null, 2) + ';\n/*__ENEMY_REGISTRY_END__*/';

let html = fs.readFileSync(htmlPath, 'utf8');
const re = /\/\*__ENEMY_REGISTRY_BEGIN__\*\/[\s\S]*?\/\*__ENEMY_REGISTRY_END__\*\//;
if (!re.test(html)) {
  console.error('FAIL: 未在 HTML 找到注册表标记 /*__ENEMY_REGISTRY_BEGIN__*/');
  process.exit(1);
}
html = html.replace(re, block);
fs.writeFileSync(htmlPath, html);
console.log('ok: 敌人注册表已同步 ' + enemies.map(function (e) { return e.id; }).join(', '));
```

- [ ] **Step 5: 在 HTML 插入注册表标记块**

在 `structure-editor.html` 的 `</style>` 之后、第一个 `<script>`(`globalThis.Core...`)之前插入:

```html
  <script>
  /*__ENEMY_REGISTRY_BEGIN__*/
  window.ENEMY_REGISTRY = [];
  /*__ENEMY_REGISTRY_END__*/
  </script>
```

- [ ] **Step 6: 跑同步脚本填充注册表**

Run: `node editor/sync-enemies.js`
Expected: `ok: 敌人注册表已同步 jump_bird, fly_bird`

- [ ] **Step 7: 跑测试确认通过**

Run: `node editor/smoke.js`
Expected: 3 条新断言 PASS,全量 PASS。

- [ ] **Step 8: Commit**

```bash
git add editor/enemies.json editor/sync-enemies.js editor/structure-editor.html editor/smoke.js
git commit -m "feat: 敌人注册表共享 enemies.json + sync-enemies.js 生成 HTML 内嵌副本"
```

---

### Task 3: EnemySpawner.TYPES 从 JSON 加载 + 导出过滤

**Files:**
- Modify: `Scenes/Enemies/enemy_spawner.gd`(`const TYPES` 改为 static 变量 + `load_types()`)
- Modify: `export_presets.cfg`(include_filter 追加)
- Test: `Tests/enemy_logic_smoke.gd`(加断言)

**Interfaces:**
- Consumes: `res://editor/enemies.json`、`JSON`
- Produces: `EnemySpawner.load_types()`(静态方法)、`EnemySpawner.TYPES`(static Dictionary, id→scene)

- [ ] **Step 1: 写失败测试**

在 `Tests/enemy_logic_smoke.gd` 加:

```gdscript
	# ── Task: EnemySpawner.TYPES 从 enemies.json 加载 ──
	EnemySpawner.load_types()
	_check(EnemySpawner.TYPES.has("jump_bird") and EnemySpawner.TYPES.has("fly_bird")
			and EnemySpawner.TYPES.size() == 2, "EnemySpawner.TYPES 从 enemies.json 加载")
```

- [ ] **Step 2: 跑测试确认失败**

Run: `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd`
Expected: 新断言 FAIL(`load_types` 不存在)。实现者不代跑,由用户反馈。

- [ ] **Step 3: 改 enemy_spawner.gd**

把:

```gdscript
# 类型注册表:加新敌人 = 一个 .tscn + 一行(string 路径,load() 时取)。
const TYPES: Dictionary = {
	"jump_bird": "res://scenes/Enemies/EnemyJumpBird.tscn",
	"fly_bird": "res://scenes/Enemies/EnemyFlyBird.tscn",
}
```

改为:

```gdscript
# 敌人注册表(id → scene)。唯一来源 editor/enemies.json(与 HTML 编辑器共享)。
static var TYPES: Dictionary = {}

# 从 res://editor/enemies.json 加载注册表;缺文件/格式错 → push_error,表保持空。
static func load_types() -> void:
	TYPES = {}
	var json_text := FileAccess.get_file_as_string("res://editor/enemies.json")
	if json_text.is_empty():
		push_error("EnemySpawner: 读不到 res://editor/enemies.json")
		return
	var parsed: Variant = JSON.parse_string(json_text)
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed.get("enemies", []) is Array):
		push_error("EnemySpawner: enemies.json 格式非法")
		return
	for e in parsed["enemies"]:
		if typeof(e) == TYPE_DICTIONARY and e.has("id") and e.has("scene"):
			TYPES[str(e["id"])] = str(e["scene"])
```

- [ ] **Step 4: 改 export_presets.cfg**

`include_filter="map/*.txt"` 改为 `include_filter="map/*.txt,editor/enemies.json"`。

- [ ] **Step 5: 跑测试确认通过**

Run: 同 Step 2。Expected: 新断言 PASS,全量 PASS。

- [ ] **Step 6: Commit**

```bash
git add Scenes/Enemies/enemy_spawner.gd export_presets.cfg Tests/enemy_logic_smoke.gd
git commit -m "feat: EnemySpawner.TYPES 从 enemies.json 加载;导出含 editor/enemies.json"
```

---

### Task 4: 游戏读地图出生点(Level0 + EnemySpawner)

**Files:**
- Modify: `Scenes/level_0.gd`(`_ready` 与 `_place_player`)
- Modify: `Scenes/Enemies/enemy_spawner.gd`(`spawn_all` 加 `spawns` 参数 + 读地图分支)

**Interfaces:**
- Consumes: `MazeGenerator.load_spawns()`、`EnemySpawner.load_types()`、`EnemySpawner.TYPES`
- Produces: `Level0._place_player(grid: Array[Array], spawn_cell: Vector2i)`、`EnemySpawner.spawn_all(grid, player_pos, spawns: Dictionary)`

- [ ] **Step 1: 改 level_0.gd**

`_ready` 里把:

```gdscript
	_build_wall_collision(grid)
	_place_player(grid)
	$EnemySpawner.spawn_all(grid, $WorldViewport/Player.global_position)
```

改为:

```gdscript
	_build_wall_collision(grid)
	EnemySpawner.load_types()
	var spawns := MazeGenerator.load_spawns()
	_place_player(grid, spawns.get("player", Vector2i(-1, -1)))
	$EnemySpawner.spawn_all(grid, $WorldViewport/Player.global_position, spawns)
```

把 `_place_player` 改为接受 spawn_cell(哨兵 `(-1,-1)` 回退随机):

```gdscript
func _place_player(_grid: Array[Array], spawn_cell: Vector2i) -> void:
	var player: CharacterBody2D = $WorldViewport/Player
	var ts: int = GameParameters.TILE_SIZE
	var pos := Vector2i(-1, -1)
	if spawn_cell.x >= 0 and spawn_cell.y >= 0:
		pos = spawn_cell
	else:
		# 回退:随机空格(地图无 # player 时)
		var empty_cells: Array[Vector2i] = []
		for y in range(_grid.size()):
			for x in range(_grid[y].size()):
				if _grid[y][x] == MazeGenerator.EMPTY:
					empty_cells.append(Vector2i(x, y))
		if empty_cells.is_empty():
			push_error("No empty cells to place player!")
			return
		pos = empty_cells[randi() % empty_cells.size()]
	player.position = Vector2(pos.x * ts + ts / 2.0, pos.y * ts + ts / 2.0)
```

- [ ] **Step 2: 改 enemy_spawner.gd 的 spawn_all**

把 `spawn_all` 改为:

```gdscript
# Level0._ready 里调用。敌人加入 WorldViewport 子节点(与墙壁/玩家同空间)。
# spawns 为 MazeGenerator.load_spawns() 的字典;有 enemies 列表按地图生成,否则回退随机采样。
func spawn_all(grid: Array[Array], player_pos: Vector2, spawns: Dictionary = {}) -> void:
	var world := get_parent().get_node("WorldViewport")
	var ts: int = GameParameters.TILE_SIZE
	var enemies_meta: Array = spawns.get("enemies", [])
	if not enemies_meta.is_empty():
		for entry in enemies_meta:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var type_name: String = str(entry.get("type", ""))
			var cell: Variant = entry.get("cell")
			if type_name.is_empty() or typeof(cell) != TYPE_VECTOR2I:
				push_warning("EnemySpawner: 忽略非法 spawn 条目 %s" % str(entry))
				continue
			if not TYPES.has(type_name):
				push_warning("EnemySpawner: 未知敌人类型 %s" % type_name)
				continue
			var scene: PackedScene = load(TYPES[type_name])
			var e := scene.instantiate()
			world.add_child(e)
			e.global_position = Vector2(cell.x * ts + ts / 2.0, cell.y * ts + ts / 2.0)
			enemy_spawned.emit(e)
		print("[EnemySpawner] spawned %d enemies from map" % enemies_meta.size())
		return
	# 回退:随机采样(地图无 # enemy 时)
	var min_dist_cells := int(GameParameters.enemy_spawn_min_dist / ts)
	var player_cell := Vector2i(int(player_pos.x / ts), int(player_pos.y / ts))
	var cells := sample_spawn_cells(grid, player_cell,
			GameParameters.enemy_count, min_dist_cells)
	var type_names := TYPES.keys()
	for c in cells:
		if type_names.is_empty():
			break
		var type_name: String = type_names[randi() % type_names.size()]
		var scene: PackedScene = load(TYPES[type_name])
		var e := scene.instantiate()
		world.add_child(e)
		e.global_position = Vector2(c.x * ts + ts / 2.0, c.y * ts + ts / 2.0)
		enemy_spawned.emit(e)
	print("[EnemySpawner] spawned %d enemies" % cells.size())
```

- [ ] **Step 3: 验证(用户跑)**

Run: 冒烟测试 `res://tests/enemy_logic_smoke.gd` 全 PASS;再实际启动游戏(用户可 `--quit-after 90` 或直接玩),确认:地图无 spawn 元数据时行为不变(玩家随机、敌人随机)。

- [ ] **Step 4: Commit**

```bash
git add Scenes/level_0.gd Scenes/Enemies/enemy_spawner.gd
git commit -m "feat: 玩家/敌人生成从地图 spawn 元数据读取,无则回退随机"
```

---

### Task 5: 编辑器 Core 整图格式 parse/serialize

**Files:**
- Modify: `editor/structure-editor.html`(`Core` 内加 `parseMap`/`serializeMap`)
- Test: `editor/smoke.js`(加断言)

**Interfaces:**
- Consumes: 无
- Produces: `Core.parseMap(text: String) -> {grid, player, enemies, comments}`、`Core.serializeMap(map) -> String`

- [ ] **Step 1: 写失败测试**

在 `editor/smoke.js` 加:

```js
// ---- Task: 整图格式 parseMap / serializeMap ----
const mapText = '# demo\n# player 12 34\n# enemy jump_bird 100 50\n001\n010\n111\n';
const parsedMap = Core.parseMap(mapText);
eq(parsedMap.player, { x: 12, y: 34 }, 'parseMap: player');
eq(parsedMap.enemies, [{ type: 'jump_bird', x: 100, y: 50 }], 'parseMap: enemy');
eq(parsedMap.grid, [[0, 0, 1], [0, 1, 0], [1, 1, 1]], 'parseMap: 网格 0/1');
eq(parsedMap.comments, ['demo'], 'parseMap: 普通 # 注释保留');
eq(Core.serializeMap(parsedMap), mapText, 'parseMap→serializeMap round-trip');
throws(() => Core.parseMap('00\n0x\n'), 'parseMap: 网格含非 0/1 字符报错');
throws(() => Core.parseMap('00\n000\n'), 'parseMap: 宽度不一致报错');
```

- [ ] **Step 2: 跑测试确认失败**

Run: `node editor/smoke.js`
Expected: 新 7 条 FAIL(`parseMap` 未定义)。

- [ ] **Step 3: 在 Core 加函数**

在 `editor/structure-editor.html` 的 `Core` 里 `floodFill` 之后、`return {` 之前加:

```js
    // 整图地图格式:0/1 网格行 + # 元数据(player/enemy 指令与普通注释)。
    // 返回 { grid, player, enemies, comments }。
    function parseMap(text) {
      var lines = String(text).split(/\r?\n/);
      var grid = [], player = null, enemies = [], comments = [], width = -1;
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line === '') continue;
        if (line.charAt(0) === '#') {
          var parts = line.slice(1).trim().split(/\s+/);
          if (parts[0] === 'player' && parts.length >= 3) {
            player = { x: parseInt(parts[1], 10), y: parseInt(parts[2], 10) };
          } else if (parts[0] === 'enemy' && parts.length >= 4) {
            enemies.push({ type: parts[1], x: parseInt(parts[2], 10), y: parseInt(parts[3], 10) });
          } else {
            comments.push(line.slice(1).trim());
          }
          continue;
        }
        var row = [];
        for (var j = 0; j < line.length; j++) {
          var ch = line.charAt(j);
          if (ch !== '0' && ch !== '1') throw new Error('第 ' + (i + 1) + ' 行含非法字符 "' + ch + '"（整图网格只允许 0/1）');
          row.push(ch === '1' ? 1 : 0);
        }
        if (width === -1) width = row.length;
        else if (row.length !== width) throw new Error('第 ' + (i + 1) + ' 行宽度 ' + row.length + ' 与首行 ' + width + ' 不一致');
        grid.push(row);
      }
      return { grid: grid, player: player, enemies: enemies, comments: comments };
    }

    function serializeMap(map) {
      var lines = [];
      (map.comments || []).forEach(function (c) { lines.push('# ' + c); });
      if (map.player) lines.push('# player ' + map.player.x + ' ' + map.player.y);
      (map.enemies || []).forEach(function (e) { lines.push('# enemy ' + e.type + ' ' + e.x + ' ' + e.y); });
      map.grid.forEach(function (row) { lines.push(row.join('')); });
      return lines.join('\n') + '\n';
    }
```

并在这两个函数名加进 `return { ... }`(在 `floodFill` 那行后):

```js
      parseMap: parseMap,
      serializeMap: serializeMap,
```

- [ ] **Step 4: 跑测试确认通过**

Run: `node editor/smoke.js`
Expected: 7 条新断言 PASS,全量 PASS。

- [ ] **Step 5: Commit**

```bash
git add editor/structure-editor.html editor/smoke.js
git commit -m "feat: 编辑器 Core 支持整图地图格式 parseMap/serializeMap"
```

---

### Task 6: 编辑器整图模式(勾选 / 导入导出 / 整图渲染)

**Files:**
- Modify: `editor/structure-editor.html`(state、renderCanvas、fit、cellAt、pointer、boot、toolbar)

**Interfaces:**
- Consumes: `Core.parseMap` / `Core.serializeMap`(Task 5)
- Produces: `state.mapMode: bool`、`state.map: {grid, player, enemies, comments}`、整图渲染与导入导出

- [ ] **Step 1: 加 state 与工具栏**

把 `var state = {...}` 改为加两个字段:

```js
    var state = { library: [], selectedId: null, tool: 'paint', palette: 1, gridOn: true, brushSize: 1,
                  mapMode: false, map: null, torusMode: false, spawnTool: null };
```

在 `canvas-toolbar` 里(网格勾选附近)加:

```html
        <label style="display:flex;align-items:center;gap:4px;font-size:13px;"><input type="checkbox" id="map-mode-toggle"> 整图模式</label>
        <button id="btn-torus" title="跨接缝重复绘制、无边界平移(整图模式)">环面预览</button>
        <button id="btn-map-import">导入整图</button>
        <button id="btn-map-export" class="primary">导出整图</button>
        <input type="file" id="file-map-import" accept=".txt,text/plain" hidden>
```

在 `<body>` 加侧栏 spawn 区(整图模式显示):

```html
      <section class="panel spawn-panel">
        <h2>出生点</h2>
        <div id="spawn-tools" class="spawn-tools"></div>
        <p class="hint">整图模式下点格放置出生点,右键移除。</p>
      </section>
```

- [ ] **Step 2: 改 renderCanvas 整图分支**

把 `renderCanvas` 开头(清屏后)改为:若 `state.mapMode` 则 `renderWholeMap()` 后 `return`:

```js
    function renderCanvas() {
      if (!ctx) return;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.save();
      ctx.scale(dpr, dpr);
      ctx.fillStyle = '#17191d';
      ctx.fillRect(0, 0, wrap.clientWidth, wrap.clientHeight);
      if (state.mapMode) {
        if (state.map) renderWholeMap();
        ctx.restore();
        return;
      }
      // ...原结构渲染代码保持不变...
```

- [ ] **Step 3: 加 renderWholeMap(整图 + 可见区域裁剪 + 可选环面)**

在 `renderCanvas` 之前加:

```js
    function enemyById(id) {
      var reg = (typeof window !== 'undefined' && window.ENEMY_REGISTRY) || [];
      for (var i = 0; i < reg.length; i++) if (reg[i].id === id) return reg[i];
      return null;
    }
    // 整图渲染:只画可见区内的墙格;环面模式下把地图沿两轴各 ±1 副本平移后裁剪。
    function renderWholeMap() {
      var map = state.map;
      var w = map.grid[0].length, h = map.grid.length, z = view.zoom;
      ctx.fillStyle = '#0d1117';
      ctx.fillRect(0, 0, wrap.clientWidth, wrap.clientHeight);
      var vx0 = -view.panX / z, vy0 = -view.panY / z;
      var vx1 = vx0 + wrap.clientWidth / z, vy1 = vy0 + wrap.clientHeight / z;
      var dxs = state.torusMode ? [-1, 0, 1] : [0];
      var dys = state.torusMode ? [-1, 0, 1] : [0];
      for (var di = 0; di < dxs.length; di++) {
        for (var dj = 0; dj < dys.length; dj++) {
          var ox = dxs[di] * w, oy = dys[dj] * h;
          var cx0 = Math.max(vx0, ox), cy0 = Math.max(vy0, oy);
          var cx1 = Math.min(vx1, ox + w), cy1 = Math.min(vy1, oy + h);
          if (cx1 <= cx0 || cy1 <= cy0) continue;
          var y0 = Math.floor(cy0), y1 = Math.ceil(cy1) - 1;  // 可见格下标范围(含两端)
          var x0 = Math.floor(cx0), x1 = Math.ceil(cx1) - 1;
          for (var y = y0; y <= y1; y++) {
            var mpy = y - oy;
            for (var x = x0; x <= x1; x++) {
              var t = map.grid[mpy][x - ox];
              if (t !== 0) {
                ctx.fillStyle = TILE_COLORS[t];
                ctx.fillRect(view.panX + x * z, view.panY + y * z, z, z);
              }
            }
          }
        }
      }
      drawSpawnMarkers();
    }
    function drawSpawnMarkers() {
      var map = state.map;
      var dxs = state.torusMode ? [-1, 0, 1] : [0];
      var dys = state.torusMode ? [-1, 0, 1] : [0];
      for (var di = 0; di < dxs.length; di++) {
        for (var dj = 0; dj < dys.length; dj++) {
          var ox = dxs[di] * map.grid[0].length, oy = dys[dj] * map.grid.length;
          if (map.player) drawSpawnMarker('#54a0ff', map.player.x + ox, map.player.y + oy, 'P');
          (map.enemies || []).forEach(function (e) {
            var en = enemyById(e.type);
            drawSpawnMarker(en ? en.color : '#888888', e.x + ox, e.y + oy, en ? en.name.charAt(0) : '?');
          });
        }
      }
    }
    function drawSpawnMarker(color, gx, gy, label) {
      var z = view.zoom, px = view.panX + (gx + 0.5) * z, py = view.panY + (gy + 0.5) * z;
      ctx.fillStyle = color;
      ctx.beginPath();
      ctx.arc(px, py, Math.max(3, z * 0.3), 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = '#0b0e12';
      ctx.lineWidth = 1;
      ctx.stroke();
      if (z >= 8) {
        ctx.fillStyle = '#0b0e12';
        ctx.font = 'bold ' + Math.max(8, z * 0.5) + 'px sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(label, px, py);
      }
    }
```

- [ ] **Step 4: fit / cellAt / pointer 支持整图模式**

`fit()` 开头改为:

```js
    function fit() {
      var w, h;
      if (state.mapMode) {
        if (!state.map) return;
        w = state.map.grid[0].length; h = state.map.grid.length;
      } else {
        var s = sel();
        if (!s) return;
        w = s.grid[0].length; h = s.grid.length;
      }
      var availW = wrap.clientWidth - 60, availH = wrap.clientHeight - 60;
      if (availW <= 0 || availH <= 0) return;
      var z = Math.min(availW / w, availH / h);
      z = Math.min(48, Math.max(0.25, z));
      view.zoom = z;
      view.panX = Math.max(0, (wrap.clientWidth - w * z) / 2);
      view.panY = Math.max(0, (wrap.clientHeight - h * z) / 2);
      renderCanvas();
    }
```

`cellAt()` 改为(整图模式返回未裁剪坐标,含环面负/超界):

```js
    function cellAt(mx, my) {
      var x = Math.floor((mx - view.panX) / view.zoom);
      var y = Math.floor((my - view.panY) / view.zoom);
      if (state.mapMode) {
        if (!state.map) return null;
        return { x: x, y: y };
      }
      var s = sel();
      if (!s) return null;
      if (x < 0 || y < 0 || y >= s.grid.length || x >= s.grid[y].length) return null;
      return { x: x, y: y };
    }
```

- [ ] **Step 5: pointer 处理整图绘制**

在 `onPointerDown` 里,`var cell = cellAt(...)` 后、原 `erase/tile` 分支前,插入整图绘制分支:

```js
      if (state.mapMode) {
        var erase = e.button === 2 || e.altKey || state.tool === 'erase';
        var tile = erase ? 0 : 1;  // 整图模式只画 0/1
        if (state.tool === 'fill') {
          if (state.map.grid[cell.y][cell.x] !== tile) {
            pushMapHistory();
            state.map.grid = Core.floodFill(state.map.grid, cell.x, cell.y, tile);
          }
          renderCanvas();
          return;
        }
        pushMapHistory();
        paintMapAt(cell.x, cell.y, tile);
        drag = { mode: 'paint', lastX: cell.x, lastY: cell.y, tile: tile };
        canvas.setPointerCapture(e.pointerId);
        renderCanvas();
        return;
      }
```

加整图绘制辅助:

```js
    function pushMapHistory() { history.push({ id: -1, grid: cloneGrid(state.map.grid) }); if (history.length > 100) history.shift(); redoStack.length = 0; }
    function paintMapAt(x, y, tile) {
      var g = state.map.grid, w = g[0].length, h = g.length;
      var r = Math.floor((state.brushSize - 1) / 2);
      for (var dy = -r; dy <= r; dy++) for (var dx = -r; dx <= r; dx++) {
        var cy = y + dy, cx = x + dx;
        if (cy >= 0 && cy < h && cx >= 0 && cx < w) g[cy][cx] = tile;
      }
    }
```

`onPointerMove` 的 `paint` 分支(linePaint)与 `onPointerUp` 的 `rect` 分支在整图模式也应走整图函数;把 `onPointerUp` 的 rect 提交改为按 `state.mapMode` 二选一:

```js
      if (drag.mode === 'rect') {
        if (state.mapMode) {
          pushMapHistory();
          state.map.grid = Core.rectFill(state.map.grid, drag.sx, drag.sy, drag.lastX, drag.lastY, drag.erase ? 0 : 1);
        } else {
          var s = sel();
          if (s) {
            pushHistory(s);
            s.grid = Core.rectFill(s.grid, drag.sx, drag.sy, drag.lastX, drag.lastY, drag.erase ? 0 : state.palette);
          }
        }
      }
```

`onPointerMove` 的 paint 分支改为:

```js
      if (drag.mode === 'paint') {
        if (state.mapMode) paintMapAt(cell.x, cell.y, drag.tile);
        else linePaint(drag.lastX, drag.lastY, cell.x, cell.y, drag.tile);
        drag.lastX = cell.x;
        drag.lastY = cell.y;
        renderCanvas();
      }
```

`undo()`/`redo()` 需按 mapMode 分支(用 `-1` id 标记整图):

```js
    function undo() {
      if (history.length === 0) return;
      var snap = history.pop();
      if (state.mapMode) {
        if (snap.id !== -1) { history.push(snap); return; }
        redoStack.push({ id: -1, grid: cloneGrid(state.map.grid) });
        state.map.grid = snap.grid;
        render();
        return;
      }
      var s = sel();
      if (!s) return;
      if (snap.id !== s.id) { history.push(snap); return; }
      redoStack.push({ id: snap.id, grid: cloneGrid(s.grid) });
      s.grid = snap.grid;
      syncSizeInputs();
      render();
    }
```

`redo()` 改为:

```js
    function redo() {
      if (redoStack.length === 0) return;
      var snap = redoStack.pop();
      if (state.mapMode) {
        if (snap.id !== -1) { redoStack.push(snap); return; }
        history.push({ id: -1, grid: cloneGrid(state.map.grid) });
        state.map.grid = snap.grid;
        render();
        return;
      }
      var s = sel();
      if (!s) return;
      if (snap.id !== s.id) { redoStack.push(snap); return; }
      history.push({ id: snap.id, grid: cloneGrid(s.grid) });
      s.grid = snap.grid;
      syncSizeInputs();
      render();
    }
```

- [ ] **Step 6: boot 绑定 + 导入导出**

在 `boot()` 的 `els` 里加:

```js
        mapModeToggle: document.getElementById('map-mode-toggle'),
        btnTorus: document.getElementById('btn-torus'),
        btnMapImport: document.getElementById('btn-map-import'),
        btnMapExport: document.getElementById('btn-map-export'),
        fileMapImport: document.getElementById('file-map-import'),
        spawnTools: document.getElementById('spawn-tools'),
```

`boot()` 里加监听:

```js
      els.mapModeToggle.addEventListener('change', function () {
        state.mapMode = els.mapModeToggle.checked;
        state.spawnTool = null;
        document.querySelector('.spawn-panel').classList.toggle('hidden', !state.mapMode);
        render();  // spawn 工具列表的刷新由 Task 8 补(renderSpawnTools)
      });
      els.btnTorus.addEventListener('click', function () {
        if (!state.mapMode) return;
        state.torusMode = !state.torusMode;
        els.btnTorus.classList.toggle('active', state.torusMode);
        renderCanvas();
      });
      els.btnMapImport.addEventListener('click', function () { els.fileMapImport.click(); });
      els.fileMapImport.addEventListener('change', importWholeMap);
      els.btnMapExport.addEventListener('click', exportWholeMap);
```

加导入导出函数:

```js
    function importWholeMap() {
      var file = els.fileMapImport.files && els.fileMapImport.files[0];
      if (!file) return;
      els.fileMapImport.value = '';
      var reader = new FileReader();
      reader.onload = function () {
        var parsed;
        try { parsed = Core.parseMap(String(reader.result)); }
        catch (err) { window.alert('导入整图失败:' + err.message); return; }
        if (parsed.grid.length === 0) { window.alert('导入整图失败:网格为空'); return; }
        state.map = parsed;
        state.mapMode = true;
        els.mapModeToggle.checked = true;
        document.querySelector('.spawn-panel').classList.remove('hidden');
        render();  // spawn 工具列表的刷新由 Task 8 补(renderSpawnTools)
      };
      reader.readAsText(file, 'utf-8');
    }
    function exportWholeMap() {
      if (!state.map) { window.alert('无整图可导出'); return; }
      var blob = new Blob([Core.serializeMap(state.map)], { type: 'text/plain;charset=utf-8' });
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a');
      a.href = url; a.download = 'demo.txt';
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    }
```

- [ ] **Step 7: renderStatus 整图分支**

`renderStatus()` 里在 `parts` 组装前加:

```js
      if (state.mapMode) {
        if (state.map) {
          parts.push('整图 ' + state.map.grid[0].length + '×' + state.map.grid.length
            + (state.torusMode ? ' · 环面' : ''));
          parts.push('出生点:玩家' + (state.map.player ? '1' : '0') + ' · 敌人 ' + (state.map.enemies || []).length);
        } else {
          parts.push('整图模式 — 导入整图或保持结构库');
        }
        els.statusbar.textContent = parts.join('   ·   ');
        return;
      }
```

- [ ] **Step 8: 验证(用户手动)**

浏览器打开 `editor/structure-editor.html`:
1. 勾"整图模式"→ 勾选前画布仍结构库;勾选后无地图时显示提示。
2. "导入整图"选 `map/demo.txt` → 整图渲染,可缩放/拖拽;"导出整图"下载 `demo.txt` 内容与导入一致(可对照文件)。
3. 画笔/橡皮在整图上画墙(画出的只有 0/1),撤销/重做正常。

- [ ] **Step 9: Commit**

```bash
git add editor/structure-editor.html
git commit -m "feat: 编辑器整图模式(勾选/导入导出/整图渲染)"
```

---

### Task 7: 编辑器环面预览

**Files:**
- Modify: `editor/structure-editor.html`(渲染已含环面逻辑,本任务收尾平移交互与状态栏)

**Interfaces:**
- Consumes: `state.torusMode`、`renderWholeMap`(Task 6)
- Produces: 环面平铺平移体验

- [ ] **Step 1: 环面平移越界无缝**

`onPointerMove` 的 `pan` 分支已存在(无边界移动 `view.panX/Y`)。环面模式下 `renderWholeMap` 会按副本补图,无需额外代码。仅确认 `zoomAt` 的边界不受影响(`view.panX/Y` 任意值合法)。

- [ ] **Step 2: 验证(用户手动)**

浏览器:整图模式导入 demo.txt → 点"环面预览"→ 往右/下拖拽越过地图边缘,地图从另一侧无缝续接;关闭按钮恢复有边界平移到空白。

- [ ] **Step 3: Commit**

```bash
git add editor/structure-editor.html
git commit -m "feat: 编辑器环面预览(整图模式跨接缝平铺平移)"
```

---

### Task 8: 编辑器 spawn 放置工具

**Files:**
- Modify: `editor/structure-editor.html`(spawn 工具渲染、放置/移除交互、renderWholeMap 已画标记)

**Interfaces:**
- Consumes: `window.ENEMY_REGISTRY`(Task 2)、`state.spawnTool`、`drawSpawnMarkers`(Task 6)
- Produces: 玩家/敌人生成点放置与编辑

- [ ] **Step 1: renderSpawnTools**

加:

```js
    function renderSpawnTools() {
      var box = els.spawnTools;
      box.innerHTML = '';
      addSpawnToolButton(box, 'player', '玩家', '#54a0ff');
      var reg = (typeof window !== 'undefined' && window.ENEMY_REGISTRY) || [];
      reg.forEach(function (e) {
        addSpawnToolButton(box, e.id, e.name, e.color);
      });
    }
    function addSpawnToolButton(box, id, label, color) {
      var b = document.createElement('button');
      b.textContent = (id === 'player' ? '玩家' : label);
      b.className = 'spawn-btn' + (state.spawnTool === id ? ' active' : '');
      b.style.borderLeftColor = color;
      b.addEventListener('click', function () {
        state.spawnTool = (state.spawnTool === id) ? null : id;
        renderSpawnTools();
        renderCanvas();
      });
      box.appendChild(b);
    }
```

- [ ] **Step 2: 放置/移除交互**

在 `onPointerDown` 的整图分支开头加 spawn 放置:

```js
        if (state.spawnTool) {
          placeSpawn(cell.x, cell.y);
          return;
        }
```

加:

```js
    function placeSpawn(gx, gy) {
      var g = state.map.grid, h = g.length, w = g[0].length;
      if (gx < 0 || gy < 0 || gx >= w || gy >= h) return;
      if (state.spawnTool === 'player') {
        state.map.player = { x: gx, y: gy };
      } else {
        // 同一格已有敌人先移除(避免重叠),再追加;允许同类型多只放在不同格
        var list = state.map.enemies || [];
        for (var i = list.length - 1; i >= 0; i--) {
          if (list[i].x === gx && list[i].y === gy) list.splice(i, 1);
        }
        list.push({ type: state.spawnTool, x: gx, y: gy });
      }
      renderCanvas();
    }
```

在 `onPointerDown` 开头(pan 分支后)加右键移除 spawn(仅选了 spawn 工具时生效,移除后 return 不再擦除该格):

```js
      if (state.mapMode && e.button === 2 && state.spawnTool) {
        var cell2 = cellAt(e.offsetX, e.offsetY);
        if (cell2 && state.map) {
          if (state.map.player && state.map.player.x === cell2.x && state.map.player.y === cell2.y) {
            state.map.player = null;
          }
          var list = state.map.enemies || [];
          for (var i = list.length - 1; i >= 0; i--) {
            if (list[i].x === cell2.x && list[i].y === cell2.y) list.splice(i, 1);
          }
          renderCanvas();
        }
        return;
      }
```

- [ ] **Step 3: 补齐 renderSpawnTools() 调用点(三处)**

- `render()` 里 `renderLibrary()` 后加:

```js
      if (state.mapMode) renderSpawnTools();
```

- Task 6 的 `mapModeToggle` change 监听里,把 `render();` 前补上 `renderSpawnTools();`。
- Task 6 的 `importWholeMap` 里,把 `render();` 前补上 `renderSpawnTools();`。

- [ ] **Step 4: 样式**

`<style>` 里加:

```css
.spawn-tools { display: flex; flex-direction: column; gap: 6px; }
.spawn-tools .spawn-btn {
  text-align: left; border-left: 3px solid #888; background: var(--panel);
  padding: 5px 8px; font-size: 12px;
}
.spawn-tools .spawn-btn.active { outline: 2px solid #fff; }
```

- [ ] **Step 5: 验证(用户手动)**

浏览器:整图模式导入 demo.txt → 出生点区点"玩家"→ 在地图点一处 → 出现青圆 P 标记;点某敌人类型 → 点地图放标记;右键标记移除;导出整图 → 文件含 `# player x y` 与 `# enemy <id> x y`,再导入 round-trip 一致。

- [ ] **Step 6: Commit**

```bash
git add editor/structure-editor.html
git commit -m "feat: 编辑器 spawn 放置工具(玩家/敌人标记,右键移除)"
```

---

## 自审记录

- Spec 覆盖:格式扩展→Task1/5;共享 JSON→Task2/3;游戏读出生→Task4;整图/环面/spawn→Task6/7/8;测试→各 Task。export include_filter→Task3。
- 类型一致性:`parse_spawn_metadata`/`load_spawns`(Task1)被 Task4 消费;`EnemySpawner.load_types`/`TYPES`(Task3)被 Task4 消费;`Core.parseMap/serializeMap`(Task5)被 Task6 消费;`ENEMY_REGISTRY`(Task2)被 Task8 消费;`state.map` 字段 `{grid, player, enemies, comments}` 全链一致。
- 已知保留:Godot 冒烟与 node smoke 的失败确认由用户跑(项目约定),实现者按"写测试→实现→提交"推进并在提交信息中说明未代跑。
