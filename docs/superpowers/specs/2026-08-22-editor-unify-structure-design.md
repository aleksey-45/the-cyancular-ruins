# 编辑器统一为「结构」设计

日期: 2026-08-22
状态: 已确认
相关文件: `editor/structure-editor.html`、`editor/smoke.js`(Godot 侧零改动)

## 背景与问题

现在的结构编辑器把「结构库」和「整图模式」做成两套并存:整图模式有自己的勾选开关、新建按钮、
导入导出、环面预览,渲染逻辑也分成 `renderCanvas` 结构分支和 `renderWholeMap` 两套。问题:

1. **新建整图后什么也看不到**: `renderWholeMap` 只在非 0 格画色,整图画布只填深色底,
   不画边框/网格/主角参考 → 全 0 新地图显示为一片虚空,无任何反馈。
2. 两套概念(`mapMode` vs 结构)让「地图」和「结构」割裂,关卡 demo.txt 是"地图",小方块是"结构"。

用户决定:**编辑器里不再有「地图」分类,只有「结构」一种东西**。关卡 = 结构库里那个 540×324 的大结构,
导出存成 `map/demo.txt` 即可。

## 设计

### 1. 数据模型

- 结构 = `{ id, name, grid: number[][] (0-9), player: {x,y}|null, enemies: [{type,x,y}] }`。
- 删除 `mapMode` / `map` / `torusMode` 与 mapMode 的耦合。所有结构同构。
- grid 取值 0-9:`0`=空气,`1`=墙,`2-9`=装饰(编辑器内彩色,导出时一律当墙)。
- spawn 字段对任何结构有效(空结构 `player=null`、`enemies=[]`)。

### 2. 渲染(顺带修 blank bug)

- 所有结构统一用**可见区裁剪**渲染(现 `renderWholeMap` 的逻辑,只画可见格,540×324 不卡),
  删掉结构分支的全量 `for y/x` 重绘。
- **恒画**: 结构边框(高亮描边)、网格线(`gridOn` 开关)、左下角主角尺寸参考 —— 全 0 结构也可见。
- **环面预览**: 按钮对所有结构可用,2×2 平铺 + 接缝线(现整图 torus 逻辑复用)。

### 3. 工具

- 0-9 调色板保留(现结构模式逻辑)。
- spawn 工具条(`renderSpawnTools`,玩家 + `ENEMY_REGISTRY` 敌人)**对所有结构可用**:
  点格放置、右键移除,画布画标记(`drawSpawnMarker` 玩家方块 + 敌人色点)。
- 画笔/矩形/油漆桶/橡皮继续用;整图分支 `linePaintMap`/`paintMapAt`/`rectFill`/`floodFill` 并入统一路径。

### 4. 导出 / 导入

- **整库 JSON**: 新增 `serializeLibraryJSON`/`parseLibraryJSON`,schema:
  ```json
  { "version": 1, "structures": [
    { "name": "demo_2", "grid": [[0,0,1],...], "player": { "x": 12, "y": 34 },
      "enemies": [ { "type": "jump_bird", "x": 100, "y": 50 } ] }
  ] }
  ```
  导出全部 / 导入全部(替换当前库)。旧 `serializeLibrary`/`parseLibrary` 文本格式**删除**。
- **单结构 map 导出**: 新增 `serializeMapStructure(structure)` → 地图格式文本:
  ```
  # demo_2
  # player 12 34
  # enemy jump_bird 100 50
  00111...
  ```
  - 名字行 `# <name>`(结构名);
  - `# player col row` / `# enemy type col row`(有则写);
  - 网格行:`0` → `0`,`1-9` → `1`(非 0 当墙)。
  - 关卡 = 把大结构用这个导出,文件保存为 `map/demo.txt`。
- **导入 map 格式**: 复用 `parseMap`(0/1 网格 + spawn);结构名取首个 `#` 注释行,无则 `structure_<n>`。

### 5. 新建

- 「新建」对话框输入名字 + 宽×高(默认 540×324),创建全 0 结构(可含空 spawn)。
- 删除「新建整图」按钮及其流程。

## 移除项

- `mapMode` 开关及所有 `if (state.mapMode)` 分支。
- 「新建整图」按钮、mapMode 勾选、torus 按钮的 mapMode 限制、spawn-panel 的 mapMode 门控。
- `serializeLibrary`/`parseLibrary`(由 JSON 版取代)。
- 渲染结构分支的全量重绘(并入裁剪渲染)。

## 不动

- Godot 侧零改动:游戏仍读 `map/demo.txt` 的 0/1 + `# player`/`# enemy` 格式。
- `editor/enemies.json` 共享注册表 + `editor/sync-enemies.js` 继续用。
- `brushOffsets` 修复保持;`parseMap` 保持(导入 0/1);`serializeMap` 保持为纯 0/1 地图写出器,
  `serializeMapStructure` 先做 1-9→'1' 归一化、再调 `serializeMap` 复用行格式。

## 测试(`editor/smoke.js`)

- 删除引用 `serializeLibrary`/`parseLibrary` 的旧断言。
- 新增:
  - `serializeLibraryJSON`/`parseLibraryJSON` round-trip(含 player/enemies);
  - `serializeMapStructure`: 0/2/9 → '0'/'1'/'1' 归一化、`# player`/`# enemy` 行;
  - 导入 map 格式 → 结构名回填;
  - 全 0 结构导出后仍是合法 0/1。
- 保留 `parseMap`/`serializeMap`/`brushOffsets` 断言。
- 测试由用户自己跑(项目约定,本次已授权自行测试)。

## 关键决策

| 决策点 | 选择 |
|---|---|
| 地图分类 | 删除,只有结构 |
| 格子取值 | 保留 0-9;导出时非 0 当墙 |
| 导出格式 | 整库 JSON + 单结构 map 格式 |
| 环面预览 | 所有结构可用 |
| spawn 工具 | 所有结构可用 |
| 旧结构库格式 | 移除,由 JSON 取代 |
