# 编辑器统一为「结构」实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `editor/structure-editor.html` 从「结构库 + 整图模式」两套并存,重构为「只有结构」:所有结构可环面预览、可放玩家/敌人 spawn、恒画边框网格(修掉「新建整图看不到东西」);整库 JSON + 单结构地图格式导出。

**Architecture:** 单一数据模型 `{id, name, grid(0-9), player, enemies}`;`state.map`/`mapMode` 删除,`sel()` 为唯一来源;渲染统一为可见区裁剪 + 恒画边框/网格/主角参考;torus 对所有结构生效。纯函数放 `Core`(可 node 冒烟测试),DOM/渲染改动靠 smoke.js 保持绿 + 浏览器目测。

**Tech Stack:** 原生 JS(单文件 HTML 编辑器)、node 冒烟 `editor/smoke.js`。

## Global Constraints

- **测试由用户跑**;本会话已授权自行测试(2026-08-22),可代跑 `node editor/smoke.js`。
- 纯函数改动走 TDD(先红后绿);DOM/渲染改动无单测,以 smoke.js 保持绿 + 浏览器目测为准。
- `editor/enemies.json` 共享注册表 + `sync-enemies.js` 不动;Godot 侧零改动。
- 本计划只动 `editor/structure-editor.html`、`editor/smoke.js`。
- 有并行会话在提交,改动及时提交、提交前 `git log` 留意外来提交(见记忆 cyr-concurrent-session)。

---

### Task 1: 新增 Core 纯函数(JSON 库 / 结构导出)+ 测试

**Files:**
- Modify: `editor/structure-editor.html`(Core 区,`brushOffsets` 之后加新函数 + return 表加项)
- Test: `editor/smoke.js`(末尾加断言)

**Interfaces:**
- Consumes: 现有 `sanitizeName`/`validateGrid`/`serializeMap`/`parseMap`。
- Produces: `Core.serializeLibraryJSON(structs)`、`Core.parseLibraryJSON(text)`、`Core.serializeMapStructure(s)`、`Core.createEmptyStructure(w,h)`。
  **本 Task 只新增、不删旧函数**(旧 `serializeLibrary`/`parseLibrary`/`createEmptyMap` 在 Task 3 删)。

- [ ] **Step 1: 写红测试**

`editor/smoke.js` 末尾(`结果:` 打印前)追加:

```js
// ---- Task: 统一结构的 JSON 库 / 单结构地图导出 ----
(function () {
  var lib = [
    { id: 1, name: 'demo_2', grid: [[0, 0, 1], [0, 1, 9]], player: { x: 0, y: 1 },
      enemies: [{ type: 'jump_bird', x: 2, y: 0 }] },
    { id: 2, name: 'tower', grid: [[1, 1], [1, 1]], player: null, enemies: [] }
  ];
  var json = Core.serializeLibraryJSON(lib);
  eq(JSON.parse(json).version, 1, 'serializeLibraryJSON: 带 version');
  var back = Core.parseLibraryJSON(json);
  eq(back.length, 2, 'parseLibraryJSON: 数量');
  eq(back[0].name, 'demo_2', 'parseLibraryJSON: 名字');
  eq(back[0].grid, [[0, 0, 1], [0, 1, 9]], 'parseLibraryJSON: 0-9 网格原样');
  eq(back[0].player, { x: 0, y: 1 }, 'parseLibraryJSON: player');
  eq(back[0].enemies, [{ type: 'jump_bird', x: 2, y: 0 }], 'parseLibraryJSON: enemies');
  eq(back[1].player, null, 'parseLibraryJSON: 无 player 为 null');
  throws(function () { Core.parseLibraryJSON('{bad json'); }, 'parseLibraryJSON: 坏 JSON 报错');
  throws(function () { Core.parseLibraryJSON('{}'); }, 'parseLibraryJSON: 缺 structures 报错');

  var ms = { id: 9, name: 'levels', grid: [[0, 1, 9, 0], [0, 0, 1, 1]],
    player: { x: 0, y: 0 }, enemies: [{ type: 'fly_bird', x: 3, y: 1 }] };
  var text = Core.serializeMapStructure(ms);
  eq(text.split('\n')[0], '# levels', 'serializeMapStructure: 名字行');
  eq(text.indexOf('# player 0 0') >= 0, true, 'serializeMapStructure: player 行');
  eq(text.indexOf('# enemy fly_bird 3 1') >= 0, true, 'serializeMapStructure: enemy 行');
  eq(text.indexOf('0110\n0011') >= 0, true, 'serializeMapStructure: 1-9→1 归一化');

  var es = Core.createEmptyStructure(3, 2);
  eq(es.grid, [[0, 0, 0], [0, 0, 0]], 'createEmptyStructure: 全 0');
  eq(es.player, null, 'createEmptyStructure: 无 player');
  eq(es.enemies.length, 0, 'createEmptyStructure: 无 enemies');
  eq(Core.serializeMapStructure({ id: 1, name: 'blank', grid: es.grid, player: es.player, enemies: es.enemies }),
    '# blank\n000\n000\n', 'createEmptyStructure→serializeMapStructure: 空图可导出');
})();
```

- [ ] **Step 2: 跑 smoke.js,确认新断言全失败(红)**

Run: `node editor/smoke.js`
Expected: 新断言全部 `FAIL`(`serializeLibraryJSON is not a function` 或 `got: undefined`),旧断言仍绿。

- [ ] **Step 3: 在 Core 新增函数**

`editor/structure-editor.html`,在 `brushOffsets` 函数之后、`return {` 之前插入:

```js
    // 结构库整库 JSON(含 spawn)。grid 保留 0-9(编辑器装饰色,导出关卡时归一化)。
    function serializeLibraryJSON(structs) {
      return JSON.stringify({
        version: 1,
        structures: structs.map(function (s) {
          return { name: sanitizeName(s.name), grid: s.grid,
                   player: s.player || null, enemies: s.enemies || [] };
        })
      }, null, 2) + '\n';
    }
    function parseLibraryJSON(text) {
      var parsed;
      try { parsed = JSON.parse(text); }
      catch (e) { throw new Error('JSON 解析失败: ' + e.message); }
      if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.structures)) {
        throw new Error('结构库 JSON 缺少 structures 数组');
      }
      var out = [];
      parsed.structures.forEach(function (st, i) {
        if (!st || !Array.isArray(st.grid)) throw new Error('第 ' + (i + 1) + ' 个结构缺少 grid');
        var v = validateGrid(st.grid);
        if (!v.ok) throw new Error('结构 "' + (st.name || i) + '" 校验失败: ' + v.error);
        var player = (st.player && typeof st.player === 'object'
            && Number.isInteger(st.player.x) && Number.isInteger(st.player.y))
          ? { x: st.player.x, y: st.player.y } : null;
        var enemies = (Array.isArray(st.enemies) ? st.enemies : []).filter(function (e) {
          return e && typeof e.type === 'string' && Number.isInteger(e.x) && Number.isInteger(e.y);
        }).map(function (e) { return { type: e.type, x: e.x, y: e.y }; });
        out.push({ name: sanitizeName(st.name || ('structure_' + (i + 1))), grid: st.grid,
                   player: player, enemies: enemies });
      });
      return out;
    }
    // 单结构地图格式导出:名字行 + spawn 行 + 0/1 网格(非 0 当墙)。
    function serializeMapStructure(s) {
      var norm = s.grid.map(function (row) { return row.map(function (v) { return v === 0 ? 0 : 1; }); });
      return serializeMap({ comments: [sanitizeName(s.name)], player: s.player,
                           enemies: s.enemies || [], grid: norm });
    }
    // 新建空结构(数据部分,id/name 由 UI 补)。
    function createEmptyStructure(w, h) {
      var grid = [];
      for (var y = 0; y < h; y++) {
        var row = [];
        for (var x = 0; x < w; x++) row.push(0);
        grid.push(row);
      }
      return { grid: grid, player: null, enemies: [] };
    }
```

并把 `return {` 块末尾加 `serializeLibraryJSON: serializeLibraryJSON, parseLibraryJSON: parseLibraryJSON, serializeMapStructure: serializeMapStructure, createEmptyStructure: createEmptyStructure`。

- [ ] **Step 4: 跑 smoke.js,确认全绿**

Run: `node editor/smoke.js`
Expected: 新断言全 `ok`,旧断言仍 `ok`,`结果: N 通过, 0 失败`,EXIT 0。

- [ ] **Step 5: 提交**

```bash
git add editor/structure-editor.html editor/smoke.js
git commit -m "feat: 编辑器 Core 新增 JSON 结构库 + 单结构地图导出(Task 1,旧函数待删)"
```

---

### Task 2: 去 mapMode,状态/渲染统一 + blank 修复

**Files:**
- Modify: `editor/structure-editor.html`(UI 脚本区)

**Interfaces:**
- Consumes: Task 1 新增的 Core 函数(本 Task 暂不接线,只动 state/渲染)。
- Produces: 编辑器变为「只有结构」——`sel()` 唯一来源;统一渲染;torus/spawn 对所有结构可用;空结构可见。
  旧 `exportLibrary`(仍用旧 `serializeLibrary`)继续工作;新导出接线在 Task 3。

- [ ] **Step 1: state 去 mapMode/map**

`var state = { library: [], selectedId: null, tool: 'paint', palette: 1, gridOn: true, brushSize: 1, mapMode: false, map: null, torusMode: false, spawnTool: null };`
→
`var state = { library: [], selectedId: null, tool: 'paint', palette: 1, gridOn: true, brushSize: 1, torusMode: false, spawnTool: null };`

- [ ] **Step 2: fit()/cellAt() 去掉 mapMode 分支**

`fit()`(约 631 行)的 `if (state.mapMode) { if (!state.map) return; w = state.map.grid...; } else { ... }` → 直接 `var s = sel(); if (!s) return; w = s.grid[0].length; h = s.grid.length;`。

`cellAt()`(约 650 行)删除 `if (state.mapMode) {...} ` 分支,只留结构分支(越界返回 null)。

- [ ] **Step 3: renderCanvas 统一 + 恒画边框/网格/主角参考**

把 `renderCanvas`(约 580 行)整体替换为:

```js
    function renderCanvas() {
      if (!ctx) return;
      var s = sel();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.save();
      ctx.scale(dpr, dpr);
      ctx.fillStyle = '#17191d';
      ctx.fillRect(0, 0, wrap.clientWidth, wrap.clientHeight);
      if (s) {
        renderStructure(s);
        drawSpawnMarkers(s);
        drawGridLines(s);
        drawBorder(s);
      }
      drawBrushPreview();
      drawPlayerReference();
      ctx.restore();
    }
```

- [ ] **Step 4: 抽出渲染子函数(替换 renderWholeMap/drawSpawnMarkers/结构分支)**

`renderWholeMap` → 改为 `renderStructure(s)`(参数化,逻辑不变):

```js
    function renderStructure(s) {
      var w = s.grid[0].length, h = s.grid.length, z = view.zoom;
      ctx.fillStyle = '#0d1117';
      ctx.fillRect(0, 0, wrap.clientWidth, wrap.clientHeight);
      var vx0 = -view.panX / z, vy0 = -view.panY / z;
      var vx1 = vx0 + wrap.clientWidth / z, vy1 = vy0 + wrap.clientHeight / z;
      var dxs = state.torusMode ? [0, 1] : [0];
      var dys = state.torusMode ? [0, 1] : [0];
      for (var di = 0; di < dxs.length; di++) {
        for (var dj = 0; dj < dys.length; dj++) {
          var ox = dxs[di] * w, oy = dys[dj] * h;
          var cx0 = Math.max(vx0, ox), cy0 = Math.max(vy0, oy);
          var cx1 = Math.min(vx1, ox + w), cy1 = Math.min(vy1, oy + h);
          if (cx1 <= cx0 || cy1 <= cy0) continue;
          var y0 = Math.floor(cy0), y1 = Math.ceil(cy1) - 1;
          var x0 = Math.floor(cx0), x1 = Math.ceil(cx1) - 1;
          for (var y = y0; y <= y1; y++) {
            var mpy = y - oy;
            for (var x = x0; x <= x1; x++) {
              var t = s.grid[mpy][x - ox];
              if (t !== 0) {
                ctx.fillStyle = TILE_COLORS[t];
                ctx.fillRect(view.panX + x * z, view.panY + y * z, z, z);
              }
            }
          }
        }
      }
    }
```

`drawSpawnMarkers` → 参数化 `drawSpawnMarkers(s)`,把 `var map = state.map;` 换成 `var w = s.grid[0].length, h = s.grid.length;`,`map.player`→`s.player`、`map.enemies`→`s.enemies`、`map.grid[0].length`→`w`、`map.grid.length`→`h`。

新增(放 `drawSpawnMarkers` 之后):

```js
    function drawGridLines(s) {
      if (!state.gridOn) return;
      var w = s.grid[0].length, h = s.grid.length, z = view.zoom;
      ctx.strokeStyle = 'rgba(255,255,255,0.08)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      for (var gx = 0; gx <= w; gx++) {
        ctx.moveTo(view.panX + gx * z, view.panY);
        ctx.lineTo(view.panX + gx * z, view.panY + h * z);
      }
      for (var gy = 0; gy <= h; gy++) {
        ctx.moveTo(view.panX, view.panY + gy * z);
        ctx.lineTo(view.panX + w * z, view.panY + gy * z);
      }
      ctx.stroke();
    }
    function drawBorder(s) {
      var w = s.grid[0].length, h = s.grid.length, z = view.zoom;
      ctx.strokeStyle = '#54a0ff';
      ctx.lineWidth = 2;
      ctx.strokeRect(view.panX, view.panY, w * z, h * z);
    }
    function drawPlayerReference() {
      var pz = Math.min(PLAYER_TILES * view.zoom, wrap.clientHeight * 0.6);
      var ppad = 8;
      var pdx = ppad, pdy = wrap.clientHeight - ppad - pz;
      ctx.save();
      ctx.globalAlpha = 0.85;
      if (playerImg && playerImg.complete && playerImg.naturalWidth > 0) {
        ctx.drawImage(playerImg, pdx, pdy, pz, pz);
      } else {
        ctx.fillStyle = '#54a0ff';
        ctx.fillRect(pdx, pdy, pz, pz);
      }
      ctx.restore();
    }
```

删除旧 `renderCanvas` 里结构分支末尾的内联「主角尺寸参考」块(由 `drawPlayerReference()` 取代)。

- [ ] **Step 5: drawBrushPreview 去 mapMode**

`var col = state.mapMode ? TILE_COLORS[1] : TILE_COLORS[state.palette];` → `var col = TILE_COLORS[state.palette];`

- [ ] **Step 6: render()/renderStatus() 去 mapMode**

`render()`:`if (state.mapMode) renderSpawnTools();` → `renderSpawnTools();`
`renderStatus()`:删掉 `if (state.mapMode) {...}` 分支,只留结构分支;状态栏追加 `spawn` 计数与环面标记:
在 `parts.push('画笔 ' + state.brushSize);` 后加:
```js
          parts.push('出生点:玩家' + (s.player ? '1' : '0') + ' · 敌人 ' + (s.enemies || []).length);
          if (state.torusMode) parts.push('环面');
```

- [ ] **Step 7: onPointerDown/Move/Up 去 mapMode,spawn 工具对所有结构**

`onPointerDown`:删掉 `if (state.mapMode && e.button === 2 && state.spawnTool) {...}` 与 `if (state.mapMode) {...}` 整块,统一为:
- 右键 + spawnTool → 移除该格 spawn(用 `sel()`,逻辑同现状);
- spawnTool → `placeSpawn(cell.x, cell.y)`;
- 其余走结构路径(erase/fill/rect/paint 于 `sel()`)。

具体:把 `var s = sel();` 提前,`if (!cell || !s) return;`;`placeSpawn` 用 `sel()`(见 Step 8)。`linePaint`/`paintAt`/`pushHistory(s)` 结构路径保留;`linePaintMap`/`paintMapAt`/`pushMapHistory`/`Core.rectFill(map版)` 调用删除。

`onPointerMove`:`if (state.mapMode) linePaintMap(...) else linePaint(...)` → 只 `linePaint(...)`。
`onPointerUp`:`if (state.mapMode) {...} else {...}` → 只结构分支(`Core.rectFill(s.grid, ...)`)。

- [ ] **Step 8: placeSpawn 用 sel()**

```js
    function placeSpawn(gx, gy) {
      var s = sel();
      if (!s) return;
      var g = s.grid, h = g.length, w = g[0].length;
      if (gx < 0 || gy < 0 || gx >= w || gy >= h) return;
      if (state.spawnTool === 'player') {
        s.player = { x: gx, y: gy };
      } else {
        var list = s.enemies || [];
        for (var i = list.length - 1; i >= 0; i--) {
          if (list[i].x === gx && list[i].y === gy) list.splice(i, 1);
        }
        list.push({ type: state.spawnTool, x: gx, y: gy });
      }
      renderCanvas();
    }
```

- [ ] **Step 9: undo/redo 去 mapMode 分支**

`undo`/`redo` 里 `if (state.mapMode) { if (snap.id !== -1) {...} ... }` 分支删除,只留结构分支。

- [ ] **Step 10: 删工具栏地图按钮与接线**

HTML(约 186-193 行)删除:整图模式 checkbox、`btn-torus` 的「(整图模式)」提示、`btn-map-new`、`btn-map-import`、`btn-map-export`、`file-map-import`。保留 `btn-fit`。

boot 的 `els` 删 `mapModeToggle`/`btnMapNew`/`btnMapImport`/`btnMapExport`/`fileMapImport`;事件区删除 mapModeToggle/btnTorus/btnMapNew/btnMapImport/fileMapImport/btnMapExport 监听。`btn-torus` 保留但去掉 `if (!state.mapMode) return;` 门控(改为直接 toggle `state.torusMode`)。

`newWholeMap`/`importWholeMap`/`exportWholeMap` 函数删除(导出结构接线在 Task 3 加)。

spawn-panel 的 `hidden` 默认去掉:HTML `<section class="panel spawn-panel hidden">` → `<section class="panel spawn-panel">`,提示文字改为「点格放置出生点,右键移除。」。

- [ ] **Step 11: 跑 smoke.js 保持绿 + 提交**

Run: `node editor/smoke.js` → 全绿(本 Task 只动 UI,Core 未变,旧 `serializeLibrary` 测试仍在)。
浏览器目测:新建结构可见边框网格;任意结构可开环面、可放 spawn;空结构不再一片虚空。

```bash
git add editor/structure-editor.html
git commit -m "refactor: 编辑器去 mapMode,渲染统一为结构(修空结构不可见),torus/spawn 全结构可用"
```

---

### Task 3: 新结构对话框 + 单结构导出 + JSON 库接线

**Files:**
- Modify: `editor/structure-editor.html`(UI)、`editor/smoke.js`(删旧函数测试)

**Interfaces:**
- Consumes: Task 1 新增的 `serializeLibraryJSON`/`parseLibraryJSON`/`serializeMapStructure`/`createEmptyStructure`。
- Produces: 编辑器完整新形态——新建带尺寸对话框、单结构地图导出、整库 JSON 导出/导入、map 格式导入。

- [ ] **Step 1: modal 加宽/高字段**

modal HTML(约 203-211 行)在 `modal-input` 后加:

```html
      <div id="modal-size-row" class="hidden" style="display:flex;gap:8px;">
        <label style="flex:1;font-size:12px;color:var(--text-dim);">宽
          <input id="modal-size-w" type="number" min="1" value="540" style="width:100%;"></label>
        <label style="flex:1;font-size:12px;color:var(--text-dim);">高
          <input id="modal-size-h" type="number" min="1" value="324" style="width:100%;"></label>
      </div>
```

`promptName(title, initial, opts)`:`opts` 支持 `{ withSize, defaultW, defaultH }`;withSize 时显示 `modal-size-row` 并聚焦;取消/确定时隐藏。

- [ ] **Step 2: addStructure 用新对话框(name + 宽×高)**

```js
    function addStructure() {
      promptName('新建结构', uniqueName('structure', state.library), { withSize: true }).then(function (name) {
        if (!name) return;
        var w = clampMin(els.modalSizeW.value, 1, 540);
        var h = clampMin(els.modalSizeH.value, 1, 324);
        var data = Core.createEmptyStructure(w, h);
        var s = { id: uid(), name: name, grid: data.grid, player: data.player, enemies: data.enemies };
        state.library.push(s);
        state.selectedId = s.id;
        syncSizeInputs();
        fit();
        render();
      });
    }
```
boot 的 `els` 加 `modalSizeW`/`modalSizeH`/`modalSizeRow`。

- [ ] **Step 3: 单结构导出按钮**

toolbar 在 `btn-fit` 前加 `<button id="btn-structure-export" class="primary">导出结构</button>`;boot `els` 加 `btnStructureExport`,监听:

```js
      els.btnStructureExport.addEventListener('click', exportStructure);
```
```js
    function exportStructure() {
      var s = sel();
      if (!s) { window.alert('无结构可导出'); return; }
      var blob = new Blob([Core.serializeMapStructure(s)], { type: 'text/plain;charset=utf-8' });
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a');
      a.href = url; a.download = sanitizeName(s.name) + '.txt';  // 关卡用:保存为 map/demo.txt
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    }
```
(sanitizeName 是 Core 的,UI 里没有;用 `s.name` 直接做文件名即可:`a.download = s.name + '.txt';`)

- [ ] **Step 4: exportLibrary 改 JSON**

`exportLibrary` 里 `text = Core.serializeLibrary(state.library)` → `text = Core.serializeLibraryJSON(state.library)`;下载名 `cyr_structures.txt` → `cyr_structures.json`。

- [ ] **Step 5: importLibrary 自动识别(JSON 或地图格式)**

`importLibrary` 的 `imported = Core.parseLibrary(String(reader.result))` 改为:

```js
        var raw = String(reader.result).trim();
        var imported;
        if (raw.charAt(0) === '{') imported = Core.parseLibraryJSON(raw);
        else imported = Core.parseMap(raw).grid.length ? structureFromMap(Core.parseMap(raw)) : [];
```
并在 UI 区加:

```js
    function structureFromMap(p) {
      var name = (p.comments && p.comments[0]) ? p.comments[0] : 'structure';
      return [{ name: name, grid: p.grid, player: p.player, enemies: p.enemies }];
    }
```
导入循环给每个结构补 `player`/`enemies`(parseLibraryJSON 已带;structureFromMap 已带)。

- [ ] **Step 6: 删旧 Core 函数与对应测试**

Core 删除 `parseLibrary`/`serializeLibrary`/`createEmptyMap`(return 表同步删)。

`smoke.js`:删除引用 `serializeLibrary`/`parseLibrary` 的断言(约 74-97、139-141 行);`createEmptyMap` 断言(约 161-166 行)改为 `createEmptyStructure` 版(见 Task 1 Step 1 已加的新断言,删旧的 createEmptyMap 块)。

- [ ] **Step 7: 跑 smoke.js 全绿 + 提交**

Run: `node editor/smoke.js` → 全绿(`parseLibrary`/`serializeLibrary` 相关旧断言已删,新 JSON/map 断言在)。
浏览器目测:新建弹窗有宽高;选中结构可导出 map 格式;整库导出是 JSON;导入 JSON 或 map 文件都行。

```bash
git add editor/structure-editor.html editor/smoke.js
git commit -m "feat: 编辑器单结构导出 + JSON 库 + 带尺寸新建,删除旧结构库文本格式"
```

---

### Task 4: 收尾验证 + 提交

- [ ] **Step 1: 全量验证**

Run: `node editor/smoke.js` → `结果: N 通过, 0 失败`。
Run: Godot 冒烟(应不受影响)→ `SMOKE OK`。
Run: headless 游戏启动 → 无脚本错误。
`git log --oneline -3` 确认无外来并行提交混入。

- [ ] **Step 2: 总结改动给用户,确认浏览器目测**

把 `editor/structure-editor.html` 打开让用户目测:新建结构可见、环面、spawn、导出 map 格式、JSON 库往返。
