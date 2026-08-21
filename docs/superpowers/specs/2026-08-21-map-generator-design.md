# 地图生成器设计

日期:2026-08-21
状态:已确认

## 背景与目标

把现有的浏览器结构编辑器(`editor/structure-editor.html`)扩展成**地图生成器**,让关卡数据(墙、玩家出生、敌人出生)在编辑器里可视地编辑并存进地图文件,游戏启动时从地图读取,取代目前的随机出生逻辑。

四项目标:

1. 编辑器支持**整图模式**(可选项),勾选后启用**环面预览**。
2. 敌人出生点 + 玩家出生点记录进地图文件。
3. HTML 编辑器里的敌人种类随游戏更新(共享单一来源)。
4. 游戏出生/生成逻辑改为从地图读取。

## 1. 地图文件格式扩展

`map/demo.txt` 网格保持纯 `0/1` 不变,顶部追加 `#` 元数据指令(现有 `load_map_file` / `map_size` 都跳过 `#` 行,兼容):

```
# demo_2
# player 12 34
# enemy jump_bird 100 50
# enemy fly_bird 200 60
001110000000...
```

- `# player <col> <row>`:玩家出生格(单元格坐标,非像素)。多个时**最后一行生效**。
- `# enemy <type_id> <col> <row>`:一只敌人,一行一条;`type_id` 与共享 JSON 的 `id` 一致。
- 单元格坐标用空格分隔的十进制整数;格子中心像素 = `(col*TILE+8, row*TILE+8)`。
- 非法/无法识别的 `#` 指令 → `push_warning` 并跳过(不中断加载)。

### API

`MazeGenerator` 新增(纯解析函数,便于冒烟测试):

```gdscript
# 把地图文件的行数组解析成 spawn 元数据。
# 返回 { "player": Vector2i, "enemies": Array[{type:String, cell:Vector2i}] };
# 无任何 spawn 指令返回空 Dictionary(调用方回退随机)。player 缺失时字典无 "player" 键。
static func parse_spawn_metadata(lines: Array) -> Dictionary

# 读文件 → parse_spawn_metadata(与 load_map_file 各自读一遍,小文件可接受)。
static func load_spawns() -> Dictionary
```

`load_map_file()` 与 `map_size()` 不改。

## 2. 敌人清单共享 JSON(单一来源)

新增 `editor/enemies.json`(游戏与编辑器共用的敌人注册表):

```json
{
  "enemies": [
    { "id": "jump_bird", "name": "JumpBird",
      "scene": "res://Scenes/Enemies/EnemyJumpBird.tscn", "color": "#6fae8f" },
    { "id": "fly_bird", "name": "FlyBird",
      "scene": "res://Scenes/Enemies/EnemyFlyBird.tscn", "color": "#c96fb0" }
  ]
}
```

字段:`id`(地图元数据引用、调色板 key)、`name`(显示名)、`scene`(游戏 spawn 场景路径)、`color`(编辑器标记色)。

- **游戏**:`EnemySpawner.TYPES` 从 const 改为 static 变量,启动时从 `res://editor/enemies.json` 加载(`id → scene`)。缺文件/字段异常 → `push_error` 并保持空表(spawn 时自然失败或回退)。
- **HTML**:敌人调色板与标记色从**内嵌注册表**派生(见 §4)。内嵌副本由生成脚本从 `enemies.json` 重新生成。
- **同步脚本**:新增 `editor/sync-enemies.js`(node):
  1. 读 `editor/enemies.json`;
  2. 读 `editor/structure-editor.html`,把 `/*__ENEMY_REGISTRY_BEGIN__*/ ... /*__ENEMY_REGISTRY_END__*/` 之间替换为新的 `window.ENEMY_REGISTRY = [...]`;
  3. 写回 HTML;失败 exit 非零。
- **加新敌人流程**:改 `enemies.json` → 跑 `node editor/sync-enemies.js` → 游戏与编辑器同步就绪。

`export_presets.cfg` 的 `include_filter` 追加 `editor/enemies.json`(游戏运行时需要它生成 TYPES)。

## 3. 游戏逻辑改动

### 玩家出生(`Scenes/level_0.gd`)

`_ready` 里:

```gdscript
var spawns := MazeGenerator.load_spawns()
_place_player(grid, spawns.get("player", Vector2i(-1, -1)))
```

`_place_player(grid, spawn_cell)` 改为:先试 `spawn_cell`;`(-1,-1)` 哨兵 → 回退现有随机空格。

### 敌人生成(`Scenes/Enemies/enemy_spawner.gd`)

`spawn_all(grid, player_pos)` 改为:

1. `MazeGenerator.load_spawns()`;若有 `enemies` 列表 → 逐条按 `type` 取场景、按 `cell` 放像素中心,跳过未知 type(警告)。
2. 否则回退现有 `sample_spawn_cells` 随机采样。

`GameParameters.enemy_count` / `enemy_spawn_min_dist` 仍用于回退路径,不动。

## 4. 编辑器改动(`editor/structure-editor.html`)

### 整图模式(可选项)

- 画布工具栏加勾选**"整图模式"**(默认关)。开启后:
  - 画布切换为整张地图数据 `map = { grid: number[][], player: {x,y}|null, enemies: [{type,x,y}] }`。
  - 结构库模式(默认)保留不变。
- 新增**导入整图** / **导出整图**(侧栏或工具栏):
  - 导入:file input,`Core.parseMap(text)` 解析(0/1 网格 + `#` 元数据)。
  - 导出:`Core.serializeMap(map)` 输出网格 + `# player/# enemy` 行,文件名 `demo.txt`。
  - 工作流:浏览器编辑器无法直接写仓库,导出文件后由用户保存覆盖 `map/demo.txt`。

### 环面预览按钮

- 工具栏加**"环面预览"**按钮(仅整图模式生效):切换 `torusMode`。
  - 关闭:平移到画布边界为止(现状)。
  - 开启:**跨接缝重复绘制、无边界平移**。渲染时对可见区域裁剪 + 坐标 `posmod(cols/rows)` 回绕,只画可见格(避免 540×324 全量重绘卡顿)。
- 开启环面时,状态栏提示当前接缝相对位移。

### spawn 放置工具

- 整图模式下,侧栏加 **spawn 工具**:玩家出生 + 每种敌人(来自内嵌 `ENEMY_REGISTRY`)。
- 选中工具后点格放置(写入 `map.player` 或追加 `map.enemies`),右键点已有标记移除。
- 画布渲染玩家/敌人标记:
  - 玩家:青色方块 + `P` 文字;
  - 敌人:注册表 `color` 圆点(缩放足够时画类型标签首字)。

### 性能

- 整图渲染只画 `grid[x][y] != 0` 且落在可见区域内的格;环面模式把坐标取模后再判可见。

## 5. 测试

- `editor/smoke.js`(node)新增:
  - `Core.parseMap` / `Core.serializeMap` round-trip;
  - spawn 元数据解析(`# player`/`# enemy`、多行、非法行忽略)。
- Godot `Tests/enemy_logic_smoke.gd` 新增:
  - `MazeGenerator.parse_spawn_metadata` 纯函数断言(合成行数组,不依赖真实地图)。
- 测试由用户自己跑(项目约定)。

## 关键决策记录

| 决策点 | 选择 |
|---|---|
| 整图模式 | 可选项(勾选才启用),结构库保留默认 |
| 环面预览 | 环面平铺平移(跨接缝重复 + 无边界拖拽) |
| spawn 记录格式 | `#` 注释元数据行(网格保持纯 0/1) |
| 敌人同步 | 共享 `editor/enemies.json` 单一来源 + node 生成脚本 |
| 无元数据时 | 游戏回退现有随机出生逻辑(向后兼容) |
