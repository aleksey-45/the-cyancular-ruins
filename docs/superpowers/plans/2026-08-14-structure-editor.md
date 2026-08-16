# Structure Editor of CyR — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single-file HTML structure editor for *The Cyancular Ruins* where a designer paints tile patterns (0–9) on a grid and exports them as one plain-text library file the future map generator can consume.

**Architecture:** One self-contained HTML file with two `<script>` blocks — a DOM-free pure-function core exposed as `globalThis.Core` (serialization, parsing, validation, grid ops) and a UI layer (Canvas 2D editor) that only boots when running in a browser. A Node smoke script extracts and tests the core without a browser. No build step, no server, no frameworks.

**Tech Stack:** HTML5 + CSS3 + vanilla JS (single file, works over `file://`), Canvas 2D rendering, Node.js ≥ 18 (v24 present on machine) for the dev-time smoke test only.

## Global Constraints

- Single self-contained file `the-cyancular-ruins/editor/structure-editor.html`; CSS/JS inlined; zero network requests.
- Tile values are integers `0`–`9`. Functionally `0` = air, `1`–`9` = wall (distinct placeholder colors; real textures come later).
- Export = one plain-text library file: `# name` starts a structure only at block start (file start or after a blank line); following lines are its rows of digit chars. Blank lines ignored and separate consecutive structures. Any other `#` line is a comment that never breaks the current structure.
- Structure names: letters/digits/CJK/`_`/`-`, no leading `-`, max 32 chars, unique in library; sanitized, empty → `structure`.
- Validation: digits only, ≥1 row, ≥1 col, all rows equal width; malformed input → thrown `Error` with a Chinese message; nothing is written on failure.
- **No game-side code changes.** Map-generation rewrite is explicitly out of scope.
- Tests run as `node smoke.js` from `the-cyancular-ruins/editor/`; browser checks run by opening the HTML.

---

### Task 1: Scaffold — smoke harness + HTML skeleton + `sanitizeName`/`validateGrid`

**Files:**
- Create: `the-cyancular-ruins/editor/structure-editor.html`
- Create: `the-cyancular-ruins/editor/smoke.js`

**Interfaces:**
- Produces: `Core.sanitizeName(name: string) -> string`, `Core.validateGrid(grid: number[][]) -> {ok: boolean, error: string}`. Later tasks rely on these exact names.

- [ ] **Step 1: Write `editor/smoke.js`** (test harness + Task-1 tests). Full content:

```js
'use strict';

// Node smoke test for Structure Editor of CyR.
// Extracts the <script> blocks from structure-editor.html, evaluates them in a
// DOM-free context, and exercises the pure functions exposed as globalThis.Core.
//
// Run: node smoke.js

const fs = require('fs');
const path = require('path');

const htmlPath = path.join(__dirname, 'structure-editor.html');
const html = fs.readFileSync(htmlPath, 'utf8');

const scripts = [];
const scriptRe = /<script\b[^>]*>([\s\S]*?)<\/script>/g;
let m;
while ((m = scriptRe.exec(html)) !== null) {
  if (!/src\s*=/.test(m[0])) scripts.push(m[1]);
}

// DOM-free shim: the UI script guards boot() on document existence, so it stays inert.
const fakeWindow = { document: null };
for (const src of scripts) {
  try {
    new Function('window', 'document', src)(fakeWindow, null);
  } catch (err) {
    console.error('脚本执行失败（可能是语法错误）:', err.message);
    process.exit(1);
  }
}

const Core = globalThis.Core;
if (!Core) {
  console.error('FAIL: 未从 HTML 中加载到 Core。请确认 structure-editor.html 内含 globalThis.Core = ...');
  process.exit(1);
}

let pass = 0;
let fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
function throws(fn, msg) {
  let threw = false;
  try { fn(); } catch (e) { threw = true; }
  if (threw) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); }
}

// ---- Task 1: sanitizeName / validateGrid ----
eq(Core.sanitizeName('My Tower #1'), 'My_Tower_1', 'sanitizeName: 非法字符被清理');
eq(Core.sanitizeName('   spaced   name  '), 'spaced_name', 'sanitizeName: 空格合并为下划线');
eq(Core.sanitizeName('---'), 'structure', 'sanitizeName: 全非法回落默认名');
eq(Core.sanitizeName(''), 'structure', 'sanitizeName: 空名回落');
eq(Core.sanitizeName('-lead'), 'lead', 'sanitizeName: 去掉开头连字符');
eq(Core.sanitizeName('塔楼 #1'), '塔楼_1', 'sanitizeName: 保留中文');

eq(Core.validateGrid([[0, 1], [1, 9]]), { ok: true, error: '' }, 'validateGrid: 合法 0–9');
eq(Core.validateGrid([[0]]), { ok: true, error: '' }, 'validateGrid: 1×1 合法');
eq(Core.validateGrid([[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]]), { ok: true, error: '' }, 'validateGrid: 全部 0–9 值合法');
eq(Core.validateGrid([[0], [1, 2]]).ok, false, 'validateGrid: 宽度不一致');
eq(Core.validateGrid([[0, -1]]).ok, false, 'validateGrid: 负值非法');
eq(Core.validateGrid([['x']]).ok, false, 'validateGrid: 非数字非法');
eq(Core.validateGrid([]).ok, false, 'validateGrid: 空网格非法');

console.log('');
console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
process.exit(fail === 0 ? 0 : 1);
```

- [ ] **Step 2: Write `editor/structure-editor.html`** — full layout skeleton + empty `Core` block + inert UI block. Full content:

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Structure Editor of CyR</title>
<style>
:root {
  --bg: #17191d;
  --panel: #1f2329;
  --panel-2: #262b32;
  --border: #343b45;
  --text: #d7dde5;
  --text-dim: #8b94a1;
  --accent: #54a0ff;
  --danger: #e05a5a;
}
* { box-sizing: border-box; }
html, body { height: 100%; }
body {
  margin: 0;
  font-family: "Segoe UI", "Microsoft YaHei", system-ui, sans-serif;
  background: var(--bg);
  color: var(--text);
  display: flex;
  flex-direction: column;
}
button { cursor: pointer; }
.hidden { display: none !important; }

.topbar {
  display: flex; align-items: center; justify-content: space-between;
  padding: 8px 14px; background: var(--panel); border-bottom: 1px solid var(--border);
}
.topbar h1 { font-size: 16px; margin: 0; font-weight: 600; }
.topbar-actions { display: flex; gap: 8px; }
button {
  background: var(--panel-2); color: var(--text); border: 1px solid var(--border);
  border-radius: 6px; padding: 6px 12px; font-size: 13px;
}
button:hover { background: #2f363f; }
button.primary { background: var(--accent); border-color: var(--accent); color: #0b0e12; font-weight: 600; }
button.danger:hover { background: var(--danger); border-color: var(--danger); color: #fff; }

.main { display: flex; flex: 1; min-height: 0; }
.sidebar {
  width: 264px; flex: none; display: flex; flex-direction: column; gap: 10px;
  padding: 10px; background: var(--panel); border-right: 1px solid var(--border); overflow-y: auto;
}
.panel { background: var(--panel-2); border: 1px solid var(--border); border-radius: 8px; padding: 10px; }
.panel h2 { font-size: 12px; text-transform: uppercase; letter-spacing: .06em; color: var(--text-dim); margin: 0 0 8px; }

#library-list {
  list-style: none; margin: 0 0 8px; padding: 0; max-height: 220px; overflow-y: auto;
  border: 1px solid var(--border); border-radius: 6px;
}
#library-list li {
  display: flex; justify-content: space-between; align-items: center;
  padding: 6px 8px; font-size: 13px; cursor: pointer;
}
#library-list li:hover { background: #2f363f; }
#library-list li.selected { background: var(--accent); color: #0b0e12; }
#library-list li .sz { font-size: 11px; color: var(--text-dim); }
#library-list li.selected .sz { color: #0b0e12; }
.lib-actions { display: flex; gap: 6px; flex-wrap: wrap; }
.lib-actions button { flex: 1 1 auto; padding: 5px 8px; font-size: 12px; }

.props-panel .row { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
.props-panel label { font-size: 13px; display: flex; align-items: center; gap: 6px; }
.props-panel input[type=number] {
  width: 58px; background: var(--panel); color: var(--text);
  border: 1px solid var(--border); border-radius: 5px; padding: 4px 6px;
}

#palette { display: grid; grid-template-columns: repeat(5, 1fr); gap: 6px; }
.swatch {
  aspect-ratio: 1; border-radius: 6px; border: 1px solid var(--border);
  display: flex; align-items: center; justify-content: center;
  font-size: 12px; font-weight: 600; cursor: pointer; color: #0b0e12; user-select: none;
}
.swatch.sw-air {
  background: repeating-conic-gradient(#2a2f37 0 25%, #20242b 0 50%) 0 0/16px 16px;
  border: 1px dashed #4a5462; color: var(--text-dim);
}
.swatch.selected { outline: 2px solid #fff; outline-offset: 1px; }
.swatch.s1 { background: #54778d; }
.swatch.s2 { background: #9d7a5c; }
.swatch.s3 { background: #6fae8f; }
.swatch.s4 { background: #c98a5e; }
.swatch.s5 { background: #8a6fc9; }
.swatch.s6 { background: #c96fb0; }
.swatch.s7 { background: #5ec9c0; }
.swatch.s8 { background: #c9c95e; }
.swatch.s9 { background: #e0e0e0; }
.hint { font-size: 12px; color: var(--text-dim); margin: 8px 0 0; }

.canvas-area { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.canvas-toolbar {
  display: flex; align-items: center; gap: 6px; padding: 8px 12px;
  background: var(--panel); border-bottom: 1px solid var(--border);
}
.canvas-toolbar .tool-btn.active { background: var(--accent); border-color: var(--accent); color: #0b0e12; }
.canvas-toolbar .spacer { flex: 1; }
#canvas-wrap { flex: 1; min-height: 0; position: relative; overflow: hidden; }
#canvas { position: absolute; inset: 0; width: 100%; height: 100%; display: block; }
#statusbar {
  padding: 5px 12px; font-size: 12px; color: var(--text-dim);
  background: var(--panel); border-top: 1px solid var(--border);
}

#modal-overlay {
  position: fixed; inset: 0; background: rgba(0, 0, 0, .55);
  display: flex; align-items: center; justify-content: center; z-index: 10;
}
.modal { background: var(--panel-2); border: 1px solid var(--border); border-radius: 10px; padding: 16px; width: 300px; }
.modal h3 { margin: 0 0 12px; font-size: 14px; }
.modal input {
  width: 100%; background: var(--panel); color: var(--text); border: 1px solid var(--border);
  border-radius: 6px; padding: 8px 10px; font-size: 14px; margin-bottom: 8px;
}
.modal .err { color: var(--danger); font-size: 12px; margin: 0 0 8px; min-height: 16px; }
.modal-actions { display: flex; justify-content: flex-end; gap: 8px; }
</style>
</head>
<body>
  <header class="topbar">
    <h1>Structure Editor of CyR</h1>
    <div class="topbar-actions">
      <button id="btn-import">导入</button>
      <button id="btn-export" class="primary">导出库</button>
      <input type="file" id="file-import" accept=".txt,.cyr,text/plain" hidden>
    </div>
  </header>

  <div class="main">
    <aside class="sidebar">
      <section class="panel">
        <h2>结构库</h2>
        <ul id="library-list"></ul>
        <div class="lib-actions">
          <button id="btn-add">新建</button>
          <button id="btn-dup">复制</button>
          <button id="btn-rename">重命名</button>
          <button id="btn-del" class="danger">删除</button>
        </div>
      </section>
      <section class="panel props-panel">
        <h2>画布尺寸</h2>
        <div class="row">
          <label>宽 <input type="number" id="size-w" min="1" max="64" value="12"></label>
          <label>高 <input type="number" id="size-h" min="1" max="64" value="12"></label>
        </div>
        <button id="btn-resize" class="primary" style="width:100%">应用尺寸</button>
      </section>
      <section class="panel">
        <h2>Tile 调色板</h2>
        <div id="palette"></div>
        <p class="hint">0 = 空气 · 1–9 = 墙（纹理待接入）</p>
      </section>
    </aside>

    <main class="canvas-area">
      <div class="canvas-toolbar">
        <button data-tool="paint" class="tool-btn active">画笔</button>
        <button data-tool="rect" class="tool-btn">矩形</button>
        <button data-tool="fill" class="tool-btn">油漆桶</button>
        <button data-tool="erase" class="tool-btn">橡皮</button>
        <span class="spacer"></span>
        <button id="btn-undo" title="Ctrl+Z">撤销</button>
        <button id="btn-redo" title="Ctrl+Y">重做</button>
        <span class="spacer"></span>
        <label style="display:flex;align-items:center;gap:4px;font-size:13px;"><input type="checkbox" id="grid-toggle" checked> 网格</label>
        <button id="btn-fit">适配</button>
      </div>
      <div id="canvas-wrap">
        <canvas id="canvas"></canvas>
      </div>
      <div id="statusbar"></div>
    </main>
  </div>

  <div id="modal-overlay" class="hidden">
    <div class="modal">
      <h3 id="modal-title"></h3>
      <input id="modal-input" type="text">
      <p id="modal-err" class="err"></p>
      <div class="modal-actions">
        <button id="modal-cancel">取消</button>
        <button id="modal-ok" class="primary">确定</button>
      </div>
    </div>
  </div>

  <script>
  globalThis.Core = (function () {
    'use strict';
    // Core functions are added in Tasks 1–3.
    return {};
  })();
  </script>

  <script>
  (function () {
    'use strict';
    // UI code is added in Tasks 4–7.
    function boot() {} // stub so the page opens cleanly before Task 4
    var canBoot = typeof document !== 'undefined' && document && typeof document.getElementById === 'function';
    if (canBoot) boot();
  })();
  </script>
</body>
</html>
```

Note: `boot()` is not yet defined — that is fine for this task; the guard only runs `boot()` in a real browser, and browser checks for UI start in Task 4.

- [ ] **Step 3: Run the smoke test — verify it fails**

Run: `cd /e/Workspace/godot/the-cyancular-ruins/editor && node smoke.js`
Expected: FAIL — `Core.sanitizeName is not a function` (all Task-1 assertions fail).

- [ ] **Step 4: Implement `sanitizeName` and `validateGrid` in the Core block**

Replace the Core `<script>` block body (keep the `globalThis.Core = (function () { 'use strict';` opening and `})();` closing) with:

```js
  function sanitizeName(name) {
    var n = String(name == null ? '' : name).trim();
    n = n.replace(/\s+/g, '_');
    n = n.replace(/[^A-Za-z0-9_\u4e00-\u9fa5-]/g, '');
    n = n.replace(/^-+/, '');
    if (n.length > 32) n = n.slice(0, 32);
    if (n === '') return 'structure';
    return n;
  }

  function validateGrid(grid) {
    if (!Array.isArray(grid) || grid.length === 0) return { ok: false, error: '网格不能为空' };
    var w = grid[0].length;
    if (w === 0) return { ok: false, error: '网格宽度不能为 0' };
    for (var y = 0; y < grid.length; y++) {
      var row = grid[y];
      if (!Array.isArray(row) || row.length !== w) return { ok: false, error: '第 ' + y + ' 行宽度不一致' };
      for (var x = 0; x < w; x++) {
        var v = row[x];
        if (!Number.isInteger(v) || v < 0 || v > 9) {
          return { ok: false, error: '(' + x + ',' + y + ') 处 tile 值非法: ' + v };
        }
      }
    }
    return { ok: true, error: '' };
  }

  return {
    sanitizeName: sanitizeName,
    validateGrid: validateGrid
  };
```

- [ ] **Step 5: Run the smoke test — verify it passes**

Run: `cd /e/Workspace/godot/the-cyancular-ruins/editor && node smoke.js`
Expected: 13 tests pass, `结果: 13 通过, 0 失败`, exit code 0.

- [ ] **Step 6: Commit**

```bash
cd /e/Workspace/godot
git add the-cyancular-ruins/editor/smoke.js the-cyancular-ruins/editor/structure-editor.html the-cyancular-ruins/docs/superpowers/specs/2026-08-14-structure-editor-design.md
git commit -m "feat(editor): scaffold structure editor + name/grid validation core"
```

---

### Task 2: Export contract — `serializeLibrary`, `parseLibrary`, `resizeGrid`

**Files:**
- Modify: `the-cyancular-ruins/editor/smoke.js` (append tests before the summary lines)
- Modify: `the-cyancular-ruins/editor/structure-editor.html` (extend Core block)

**Interfaces:**
- Consumes: `Core.sanitizeName`, `Core.validateGrid` (Task 1).
- Produces: `Core.serializeLibrary(structs: Array<{name, grid}>) -> string`, `Core.parseLibrary(text: string) -> Array<{name, grid}>` (throws `Error` on malformed input), `Core.resizeGrid(grid, newW, newH) -> number[][]`.

- [ ] **Step 1: Append Task-2 tests to `smoke.js`**

Insert immediately before the `console.log('');` summary lines:

```js
// ---- Task 2: serializeLibrary / parseLibrary / resizeGrid ----
const sample = [
  { name: 'tower_01', grid: [[0, 0, 1], [0, 1, 0], [1, 1, 1]] }
];
const text = Core.serializeLibrary(sample);
eq(text, '# tower_01\n001\n010\n111\n', 'serializeLibrary: 基本输出');
eq(Core.parseLibrary(text), sample, 'parseLibrary: round-trip');

eq(Core.parseLibrary('# a\n00\n11\n\n# b\n0\n1\n'), [
  { name: 'a', grid: [[0, 0], [1, 1]] },
  { name: 'b', grid: [[0], [1]] }
], 'parseLibrary: 多结构 + 空行');

eq(Core.parseLibrary('# x\n# 内联注释\n00\n'), [
  { name: 'x', grid: [[0, 0]] }
], 'parseLibrary: 裸注释行不打断结构');

eq(Core.parseLibrary('# 塔楼\n00\n')[0].name, '塔楼', 'parseLibrary: 中文名保留');
eq(Core.parseLibrary('# a\n'), [], 'parseLibrary: 只有名字没有数据则忽略');

throws(() => Core.parseLibrary('# a\n0a\n'), 'parseLibrary: 非法字符报错');
throws(() => Core.parseLibrary('00\n'), 'parseLibrary: 结构名之前的数据报错');
throws(() => Core.parseLibrary('# a\n00\n111\n'), 'parseLibrary: 宽度不一致报错');
throws(() => Core.serializeLibrary([{ name: 'bad', grid: [[0], [1, 2]] }]), 'serializeLibrary: 非法网格报错');

eq(Core.resizeGrid([[1, 2], [3, 4]], 3, 2), [[1, 2, 0], [3, 4, 0]], 'resizeGrid: 加宽补 0');
eq(Core.resizeGrid([[1, 2, 3], [4, 5, 6]], 2, 1), [[1, 2]], 'resizeGrid: 裁剪');
eq(Core.resizeGrid([[1], [2]], 1, 3), [[1], [2], [0]], 'resizeGrid: 加高补 0');
eq(Core.resizeGrid([], 2, 2), [[0, 0], [0, 0]], 'resizeGrid: 从空网格扩展');
```

- [ ] **Step 2: Run the smoke test — verify the new tests fail**

Run: `cd /e/Workspace/godot/the-cyancular-ruins/editor && node smoke.js`
Expected: Task-1 block still green; new tests FAIL (`Core.serializeLibrary is not a function`).

- [ ] **Step 3: Implement the three functions in the Core block**

Inside the Core IIFE, above the `return { ... };` statement, add:

```js
  function parseLibrary(text) {
    var structs = [];
    var cur = null;
    var lines = String(text).split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (line === '') continue;
      if (line.charAt(0) === '#') {
        var name = line.slice(1).trim();
        if (name !== '') {
          cur = { name: sanitizeName(name), grid: [] };
          structs.push(cur);
        }
        continue;
      }
      var row = [];
      for (var j = 0; j < line.length; j++) {
        var d = line.charCodeAt(j) - 48;
        if (d < 0 || d > 9) {
          throw new Error('第 ' + (i + 1) + ' 行含非法字符 "' + line.charAt(j) + '"（只允许 0–9）');
        }
        row.push(d);
      }
      if (cur === null) {
        throw new Error('第 ' + (i + 1) + ' 行的数据出现在任何结构名之前');
      }
      cur.grid.push(row);
    }
    var result = structs.filter(function (s) { return s.grid.length > 0; });
    for (var k = 0; k < result.length; k++) {
      var v = validateGrid(result[k].grid);
      if (!v.ok) throw new Error('结构 "' + result[k].name + '" 校验失败: ' + v.error);
    }
    return result;
  }

  function serializeLibrary(structs) {
    var blocks = [];
    for (var i = 0; i < structs.length; i++) {
      var s = structs[i];
      var v = validateGrid(s.grid);
      if (!v.ok) throw new Error('结构 "' + s.name + '" 校验失败: ' + v.error);
      blocks.push('# ' + s.name + '\n' + s.grid.map(function (row) { return row.join(''); }).join('\n'));
    }
    return blocks.join('\n\n') + '\n';
  }

  function resizeGrid(grid, newW, newH) {
    var out = [];
    for (var y = 0; y < newH; y++) {
      var row = [];
      for (var x = 0; x < newW; x++) {
        row.push(y < grid.length && x < grid[y].length ? grid[y][x] : 0);
      }
      out.push(row);
    }
    return out;
  }
```

Then extend the `return` statement to include the new functions:

```js
  return {
    sanitizeName: sanitizeName,
    validateGrid: validateGrid,
    serializeLibrary: serializeLibrary,
    parseLibrary: parseLibrary,
    resizeGrid: resizeGrid
  };
```

- [ ] **Step 4: Run the smoke test — verify it passes**

Run: `cd /e/Workspace/godot/the-cyancular-ruins/editor && node smoke.js`
Expected: all tests pass, `结果: N 通过, 0 失败`, exit code 0.

- [ ] **Step 5: Commit**

```bash
cd /e/Workspace/godot
git add the-cyancular-ruins/editor/smoke.js the-cyancular-ruins/editor/structure-editor.html
git commit -m "feat(editor): plain-text library serialize/parse + grid resize core"
```

---

### Task 3: Editing ops — `rectFill`, `floodFill`

**Files:**
- Modify: `the-cyancular-ruins/editor/smoke.js`
- Modify: `the-cyancular-ruins/editor/structure-editor.html`

**Interfaces:**
- Consumes: `Core.validateGrid` (Task 1).
- Produces: `Core.rectFill(grid, x0, y0, x1, y1, tile) -> number[][]` (returns a new grid, bounds-clamped), `Core.floodFill(grid, x, y, tile) -> number[][]` (returns a new grid; no-op if target already equals tile).

- [ ] **Step 1: Append Task-3 tests to `smoke.js`** before the summary lines:

```js
// ---- Task 3: rectFill / floodFill ----
eq(Core.rectFill([[0, 0, 0], [0, 0, 0], [0, 0, 0]], 1, 0, 1, 2, 5), [[0, 5, 0], [0, 5, 0], [0, 5, 0]], 'rectFill: 竖线');
eq(Core.rectFill([[0, 0, 0], [0, 0, 0], [0, 0, 0]], 2, 2, 0, 0, 9), [[9, 9, 9], [9, 9, 9], [9, 9, 9]], 'rectFill: 反向角矩形');
eq(Core.rectFill([[1, 1], [1, 1]], 0, 0, 1, 1, 0), [[0, 0], [0, 0]], 'rectFill: 擦除整块');

eq(Core.floodFill([[0, 0, 1], [0, 1, 1], [1, 1, 1]], 0, 0, 2), [[2, 2, 1], [2, 1, 1], [1, 1, 1]], 'floodFill: 填充连通区');
eq(Core.floodFill([[0, 0, 1], [0, 1, 1], [1, 1, 1]], 0, 0, 0), [[0, 0, 1], [0, 1, 1], [1, 1, 1]], 'floodFill: 同值不修改');
eq(Core.floodFill([[1, 1], [1, 0]], 0, 0, 9), [[9, 9], [9, 0]], 'floodFill: 从角落扩展');
```

- [ ] **Step 2: Run the smoke test — verify the new tests fail**

Run: `cd /e/Workspace/godot/the-cyancular-ruins/editor && node smoke.js`
Expected: Tasks 1–2 green; new tests FAIL (`Core.rectFill is not a function`).

- [ ] **Step 3: Implement the two functions in the Core block** above the `return` statement:

```js
  function rectFill(grid, x0, y0, x1, y1, tile) {
    var out = grid.map(function (r) { return r.slice(); });
    var minX = Math.min(x0, x1), maxX = Math.max(x0, x1);
    var minY = Math.min(y0, y1), maxY = Math.max(y0, y1);
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        if (y >= 0 && y < out.length && x >= 0 && x < out[y].length) out[y][x] = tile;
      }
    }
    return out;
  }

  function floodFill(grid, x, y, tile) {
    var out = grid.map(function (r) { return r.slice(); });
    var h = out.length;
    if (h === 0) return out;
    var w = out[0].length;
    if (x < 0 || x >= w || y < 0 || y >= h) return out;
    var target = out[y][x];
    if (target === tile) return out;
    var stack = [[x, y]];
    while (stack.length > 0) {
      var p = stack.pop();
      var cx = p[0], cy = p[1];
      if (cx < 0 || cx >= w || cy < 0 || cy >= h) continue;
      if (out[cy][cx] !== target) continue;
      out[cy][cx] = tile;
      stack.push([cx + 1, cy], [cx - 1, cy], [cx, cy + 1], [cx, cy - 1]);
    }
    return out;
  }
```

Extend the `return` statement to add `rectFill` and `floodFill`.

- [ ] **Step 4: Run the smoke test — verify it passes**

Run: `cd /e/Workspace/godot/the-cyancular-ruins/editor && node smoke.js`
Expected: all pass, exit code 0.

- [ ] **Step 5: Commit**

```bash
cd /e/Workspace/godot
git add the-cyancular-ruins/editor/smoke.js the-cyancular-ruins/editor/structure-editor.html
git commit -m "feat(editor): rectFill + floodFill core ops"
```

---

### Task 4: UI — canvas rendering, view (zoom/pan/fit/grid), palette, library list, status bar

**Files:**
- Modify: `the-cyancular-ruins/editor/structure-editor.html` (UI script block + nothing else)

**Interfaces:**
- Consumes: `Core.*` (Tasks 1–3) from the first script block.
- Produces: `boot()`, `render()`, `renderCanvas()`, `renderLibrary()`, `renderStatus()`, `fit()`, `zoomAt(mx, my, factor)`, `cellAt(mx, my)`, `selectStructure(id)`, `syncSizeInputs()`, `buildPalette()`, `resizeCanvas()`, helpers `sel/uid/cloneGrid/clampInt/uniqueName/hexToRgba`. Later UI tasks extend these.

- [ ] **Step 1: Replace the UI `<script>` block** (the second one) with the code below. It renders a seeded demo structure, supports wheel zoom, middle-drag / space-drag pan, grid toggle, fit, palette selection, and the library list.

```html
  <script>
  (function () {
    'use strict';

    var TILE_COLORS = {
      0: null,
      1: '#54778d', 2: '#9d7a5c', 3: '#6fae8f', 4: '#c98a5e',
      5: '#8a6fc9', 6: '#c96fb0', 7: '#5ec9c0', 8: '#c9c95e', 9: '#e0e0e0'
    };

    var state = { library: [], selectedId: null, tool: 'paint', palette: 1, gridOn: true };
    var view = { zoom: 28, panX: 40, panY: 40 };
    var nextId = 1;
    var history = [];
    var redoStack = [];
    var spaceDown = false;
    var drag = null;
    var dpr = 1;
    var els = {};
    var canvas, ctx, wrap;

    // ── helpers ──
    function sel() {
      for (var i = 0; i < state.library.length; i++) {
        if (state.library[i].id === state.selectedId) return state.library[i];
      }
      return null;
    }
    function uid() { return nextId++; }
    function cloneGrid(g) { return g.map(function (r) { return r.slice(); }); }
    function clampInt(v, min, max, def) {
      var n = parseInt(v, 10);
      if (isNaN(n)) n = def;
      return Math.max(min, Math.min(max, n));
    }
    function uniqueName(base, lib) {
      var name = Core.sanitizeName(base);
      var used = {};
      for (var i = 0; i < lib.length; i++) used[lib[i].name] = true;
      if (!used[name]) return name;
      var k = 2;
      while (used[name + '_' + k]) k++;
      return name + '_' + k;
    }
    function hexToRgba(hex, a) {
      var n = parseInt(hex.slice(1), 16);
      return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + a + ')';
    }

    // ── canvas sizing / rendering ──
    function resizeCanvas() {
      dpr = window.devicePixelRatio || 1;
      var w = wrap.clientWidth, h = wrap.clientHeight;
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      canvas.style.width = w + 'px';
      canvas.style.height = h + 'px';
    }
    function renderCanvas() {
      if (!ctx) return;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.save();
      ctx.scale(dpr, dpr);
      ctx.fillStyle = '#17191d';
      ctx.fillRect(0, 0, wrap.clientWidth, wrap.clientHeight);

      var s = sel();
      if (s) {
        var w = s.grid[0].length, h = s.grid.length, z = view.zoom;
        ctx.fillStyle = '#0d1117';
        ctx.fillRect(view.panX, view.panY, w * z, h * z);
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            var t = s.grid[y][x];
            if (t !== 0) {
              ctx.fillStyle = TILE_COLORS[t];
              ctx.fillRect(view.panX + x * z, view.panY + y * z, z, z);
            }
          }
        }
        if (state.gridOn) {
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
        ctx.strokeStyle = '#54a0ff';
        ctx.lineWidth = 2;
        ctx.strokeRect(view.panX, view.panY, w * z, h * z);
      }
      ctx.restore();
    }
    function zoomAt(mx, my, factor) {
      var nz = Math.min(128, Math.max(4, view.zoom * factor));
      if (nz === view.zoom) return;
      view.panX = mx - (mx - view.panX) * (nz / view.zoom);
      view.panY = my - (my - view.panY) * (nz / view.zoom);
      view.zoom = nz;
      renderCanvas();
    }
    function fit() {
      var s = sel();
      if (!s) return;
      var w = s.grid[0].length, h = s.grid.length;
      var availW = wrap.clientWidth - 60, availH = wrap.clientHeight - 60;
      if (availW <= 0 || availH <= 0) return;
      var z = Math.min(availW / w, availH / h);
      z = Math.max(4, Math.floor(Math.min(48, z)));
      view.zoom = z;
      view.panX = Math.max(0, (wrap.clientWidth - w * z) / 2);
      view.panY = Math.max(0, (wrap.clientHeight - h * z) / 2);
      renderCanvas();
    }
    function cellAt(mx, my) {
      var s = sel();
      if (!s) return null;
      var x = Math.floor((mx - view.panX) / view.zoom);
      var y = Math.floor((my - view.panY) / view.zoom);
      if (x < 0 || y < 0 || y >= s.grid.length || x >= s.grid[y].length) return null;
      return { x: x, y: y };
    }

    // ── library list ──
    function renderLibrary() {
      var list = els.libraryList;
      list.innerHTML = '';
      state.library.forEach(function (s) {
        var li = document.createElement('li');
        li.dataset.id = s.id;
        if (s.id === state.selectedId) li.classList.add('selected');
        var nameSpan = document.createElement('span');
        nameSpan.textContent = s.name;
        var sz = document.createElement('span');
        sz.className = 'sz';
        sz.textContent = s.grid[0].length + '×' + s.grid.length;
        li.appendChild(nameSpan);
        li.appendChild(sz);
        li.addEventListener('click', function () { selectStructure(s.id); });
        list.appendChild(li);
      });
    }
    function selectStructure(id) {
      if (state.selectedId === id) return;
      state.selectedId = id;
      syncSizeInputs();
      fit();
      render();
    }
    function syncSizeInputs() {
      var s = sel();
      if (s) {
        els.sizeW.value = s.grid[0].length;
        els.sizeH.value = s.grid.length;
      }
    }

    // ── status bar ──
    function renderStatus() {
      var s = sel();
      var parts = [];
      if (s) {
        parts.push(s.name + ' · ' + s.grid[0].length + '×' + s.grid.length);
        parts.push('工具: ' + ({ paint: '画笔', rect: '矩形', fill: '油漆桶', erase: '橡皮' })[state.tool] || state.tool);
        parts.push('tile: ' + state.palette + (state.palette === 0 ? ' (空气)' : ' (墙)'));
        parts.push('撤销 ' + history.length + ' · 重做 ' + redoStack.length);
      } else {
        parts.push('无结构 — 点击左侧"新建"');
      }
      els.statusbar.textContent = parts.join('   ·   ');
    }

    // ── palette ──
    function buildPalette() {
      els.palette.innerHTML = '';
      for (var t = 0; t <= 9; t++) {
        var sw = document.createElement('div');
        sw.className = 'swatch' + (t === 0 ? ' sw-air' : ' s' + t);
        sw.textContent = String(t);
        sw.title = t === 0 ? '0 · 空气' : t + ' · 墙';
        if (t === state.palette) sw.classList.add('selected');
        (function (tile) {
          sw.addEventListener('click', function () {
            state.palette = tile;
            var all = els.palette.querySelectorAll('.swatch');
            all.forEach(function (x) { x.classList.remove('selected'); });
            sw.classList.add('selected');
            renderStatus();
          });
        })(t);
        els.palette.appendChild(sw);
      }
    }

    function render() {
      renderLibrary();
      renderCanvas();
      renderStatus();
    }

    function boot() {
      els = {
        libraryList: document.getElementById('library-list'),
        sizeW: document.getElementById('size-w'),
        sizeH: document.getElementById('size-h'),
        palette: document.getElementById('palette'),
        canvas: document.getElementById('canvas'),
        canvasWrap: document.getElementById('canvas-wrap'),
        statusbar: document.getElementById('statusbar'),
        gridToggle: document.getElementById('grid-toggle'),
        btnFit: document.getElementById('btn-fit')
      };
      canvas = els.canvas;
      ctx = canvas.getContext('2d');
      wrap = els.canvasWrap;

      state.library.push({
        id: uid(),
        name: 'demo',
        grid: [
          [0,0,0,0,0,0,0,0,0,0,0,0],
          [0,1,1,1,1,1,1,1,1,1,1,0],
          [0,1,0,0,0,0,0,0,0,0,1,0],
          [0,1,0,1,1,0,0,1,1,0,1,0],
          [0,1,0,1,1,0,0,1,1,0,1,0],
          [0,1,0,0,0,0,0,0,0,0,1,0],
          [0,1,1,1,1,1,1,1,1,1,1,0],
          [0,0,0,0,0,0,0,0,0,0,0,0]
        ]
      });
      state.selectedId = state.library[0].id;

      buildPalette();

      els.gridToggle.addEventListener('change', function () {
        state.gridOn = els.gridToggle.checked;
        renderCanvas();
      });
      els.btnFit.addEventListener('click', fit);
      els.palette.addEventListener('click', function (e) {
        var sw = e.target.closest('.swatch');
        if (!sw) return;
        state.palette = parseInt(sw.textContent, 10);
        var all = els.palette.querySelectorAll('.swatch');
        all.forEach(function (x) { x.classList.remove('selected'); });
        sw.classList.add('selected');
        renderStatus();
      });
      els.libraryList.addEventListener('click', function (e) {
        var li = e.target.closest('li');
        if (li && li.dataset.id) selectStructure(parseInt(li.dataset.id, 10));
      });
      canvas.addEventListener('wheel', function (e) {
        e.preventDefault();
        zoomAt(e.offsetX, e.offsetY, e.deltaY < 0 ? 1.15 : 1 / 1.15);
      }, { passive: false });
      canvas.addEventListener('pointerdown', function (e) {
        if (e.button !== 1 && !spaceDown) return;
        e.preventDefault();
        drag = { mode: 'pan', sx: e.offsetX, sy: e.offsetY, ox: view.panX, oy: view.panY };
        canvas.setPointerCapture(e.pointerId);
      });
      canvas.addEventListener('pointermove', function (e) {
        if (!drag || drag.mode !== 'pan') return;
        view.panX = drag.ox + (e.offsetX - drag.sx);
        view.panY = drag.oy + (e.offsetY - drag.sy);
        renderCanvas();
      });
      function endPan() { drag = null; }
      canvas.addEventListener('pointerup', endPan);
      canvas.addEventListener('pointercancel', endPan);
      canvas.addEventListener('contextmenu', function (e) { e.preventDefault(); });
      document.addEventListener('keydown', function (e) {
        if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA')) return;
        if (e.code === 'Space') spaceDown = true;
      });
      document.addEventListener('keyup', function (e) {
        if (e.code === 'Space') spaceDown = false;
      });

      function onResize() { resizeCanvas(); renderCanvas(); }
      window.addEventListener('resize', onResize);
      if (window.ResizeObserver) new ResizeObserver(onResize).observe(wrap);

      resizeCanvas();
      fit();
      render();
    }

    var canBoot = typeof document !== 'undefined' && document && typeof document.getElementById === 'function';
    if (canBoot) boot();
  })();
  </script>
```

- [ ] **Step 2: Verify the file still loads cleanly in Node** (catches syntax errors in the UI block)

Run: `cd /e/Workspace/godot/the-cyancular-ruins/editor && node smoke.js`
Expected: Task-1–3 tests still pass (all 33 tests), exit 0. The UI block must eval without throwing.

- [ ] **Step 3: Manual browser check**

Run: `cmd //c start "" "E:/Workspace/godot/the-cyancular-ruins/editor/structure-editor.html"`
Verify:
- Page opens, `demo` structure visible on canvas with placeholder wall colors and grid lines.
- Wheel zoom around cursor; middle-drag and space+left-drag pan; "适配" refits; grid checkbox toggles grid lines.
- Clicking palette swatches 0–9 highlights the swatch and updates the status bar; clicking `demo` in the library list keeps it selected.
- Status bar shows `demo · 12×8 · 工具: 画笔 · tile: 1 (墙)`.

- [ ] **Step 4: Commit**

```bash
cd /e/Workspace/godot
git add the-cyancular-ruins/editor/structure-editor.html
git commit -m "feat(editor): canvas render + zoom/pan/fit/grid + palette + library list"
```

---

### Task 5: UI — painting tools (paint / erase / rect / fill) + undo / redo

**Files:**
- Modify: `the-cyancular-ruins/editor/structure-editor.html` (UI block)

**Interfaces:**
- Consumes: `Core.rectFill`, `Core.floodFill` (Task 3); Task 4 UI (view, `renderCanvas`, `cellAt`).
- Produces: paint interaction on the canvas; `undo()`, `redo()`; keyboard Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z.

- [ ] **Step 1: Add painting + undo/redo inside the UI IIFE**

Insert these functions immediately before `function render() {`:

```js
    // ── undo / redo ──
    function pushHistory(s) {
      history.push({ id: s.id, grid: cloneGrid(s.grid) });
      if (history.length > 100) history.shift();
      redoStack.length = 0;
    }
    function findById(id) {
      for (var i = 0; i < state.library.length; i++) {
        if (state.library[i].id === id) return state.library[i];
      }
      return null;
    }
    function undo() {
      if (history.length === 0) return;
      var s = sel();
      if (!s) return;
      var snap = history.pop();
      redoStack.push({ id: snap.id, grid: cloneGrid(s.grid) });
      var t = findById(snap.id);
      if (t) t.grid = snap.grid;
      syncSizeInputs();
      render();
    }
    function redo() {
      if (redoStack.length === 0) return;
      var s = sel();
      if (!s) return;
      var snap = redoStack.pop();
      history.push({ id: snap.id, grid: cloneGrid(s.grid) });
      var t = findById(snap.id);
      if (t) t.grid = snap.grid;
      syncSizeInputs();
      render();
    }

    // ── painting ──
    function paintAt(x, y, tile) {
      var s = sel();
      if (!s) return;
      if (y >= 0 && y < s.grid.length && x >= 0 && x < s.grid[y].length) s.grid[y][x] = tile;
    }
    function linePaint(x0, y0, x1, y1, tile) {
      var s = sel();
      if (!s) return;
      var dx = Math.abs(x1 - x0), dy = Math.abs(y1 - y0);
      var sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
      var err = dx - dy;
      var x = x0, y = y0;
      for (;;) {
        if (y >= 0 && y < s.grid.length && x >= 0 && x < s.grid[y].length) s.grid[y][x] = tile;
        if (x === x1 && y === y1) break;
        var e2 = 2 * err;
        if (e2 > -dy) { err -= dy; x += sx; }
        if (e2 < dx) { err += dx; y += sy; }
      }
    }
    function drawRectPreview(x0, y0, x1, y1, erase) {
      var s = sel();
      if (!s) return;
      var minX = Math.min(x0, x1), maxX = Math.max(x0, x1);
      var minY = Math.min(y0, y1), maxY = Math.max(y0, y1);
      var z = view.zoom;
      ctx.save();
      ctx.scale(dpr, dpr);
      ctx.fillStyle = erase ? 'rgba(255,255,255,0.25)' : hexToRgba(TILE_COLORS[state.palette], 0.5);
      ctx.fillRect(view.panX + minX * z, view.panY + minY * z, (maxX - minX + 1) * z, (maxY - minY + 1) * z);
      ctx.strokeStyle = '#ffffff';
      ctx.lineWidth = 1;
      ctx.strokeRect(view.panX + minX * z, view.panY + minY * z, (maxX - minX + 1) * z, (maxY - minY + 1) * z);
      ctx.restore();
    }

    // ── pointer handlers ──
    function onPointerDown(e) {
      if (e.button === 1 || spaceDown) {
        e.preventDefault();
        drag = { mode: 'pan', sx: e.offsetX, sy: e.offsetY, ox: view.panX, oy: view.panY };
        canvas.setPointerCapture(e.pointerId);
        return;
      }
      var s = sel();
      if (!s) return;
      var cell = cellAt(e.offsetX, e.offsetY);
      if (!cell) return;
      var erase = e.button === 2 || e.altKey;
      var tile = erase ? 0 : state.palette;
      if (state.tool === 'fill') {
        pushHistory(s);
        s.grid = Core.floodFill(s.grid, cell.x, cell.y, tile);
        render();
        return;
      }
      if (state.tool === 'rect') {
        drag = { mode: 'rect', sx: cell.x, sy: cell.y, lastX: cell.x, lastY: cell.y, erase: erase };
        canvas.setPointerCapture(e.pointerId);
        renderCanvas();
        return;
      }
      pushHistory(s);
      paintAt(cell.x, cell.y, tile);
      drag = { mode: 'paint', lastX: cell.x, lastY: cell.y, tile: tile };
      canvas.setPointerCapture(e.pointerId);
      renderCanvas();
    }
    function onPointerMove(e) {
      if (!drag) return;
      if (drag.mode === 'pan') {
        view.panX = drag.ox + (e.offsetX - drag.sx);
        view.panY = drag.oy + (e.offsetY - drag.sy);
        renderCanvas();
        return;
      }
      var cell = cellAt(e.offsetX, e.offsetY);
      if (!cell) return;
      if (drag.mode === 'rect') {
        drag.lastX = cell.x;
        drag.lastY = cell.y;
        renderCanvas();
        drawRectPreview(drag.sx, drag.sy, cell.x, cell.y, drag.erase);
        return;
      }
      if (drag.mode === 'paint') {
        linePaint(drag.lastX, drag.lastY, cell.x, cell.y, drag.tile);
        drag.lastX = cell.x;
        drag.lastY = cell.y;
        renderCanvas();
      }
    }
    function onPointerUp() {
      if (!drag) return;
      if (drag.mode === 'rect') {
        var s = sel();
        if (s) {
          pushHistory(s);
          s.grid = Core.rectFill(s.grid, drag.sx, drag.sy, drag.lastX, drag.lastY, drag.erase ? 0 : state.palette);
        }
      }
      drag = null;
      render();
    }
    function onPointerCancel() {
      drag = null;
      renderCanvas();
    }
    function onWheel(e) {
      e.preventDefault();
      zoomAt(e.offsetX, e.offsetY, e.deltaY < 0 ? 1.15 : 1 / 1.15);
    }
```

- [ ] **Step 2: Replace the wheel / pan wiring and key handler in `boot()`**

Replace this block inside `boot()`:

```js
      canvas.addEventListener('wheel', function (e) {
        e.preventDefault();
        zoomAt(e.offsetX, e.offsetY, e.deltaY < 0 ? 1.15 : 1 / 1.15);
      }, { passive: false });
      canvas.addEventListener('pointerdown', function (e) {
        if (e.button !== 1 && !spaceDown) return;
        e.preventDefault();
        drag = { mode: 'pan', sx: e.offsetX, sy: e.offsetY, ox: view.panX, oy: view.panY };
        canvas.setPointerCapture(e.pointerId);
      });
      canvas.addEventListener('pointermove', function (e) {
        if (!drag || drag.mode !== 'pan') return;
        view.panX = drag.ox + (e.offsetX - drag.sx);
        view.panY = drag.oy + (e.offsetY - drag.sy);
        renderCanvas();
      });
      function endPan() { drag = null; }
      canvas.addEventListener('pointerup', endPan);
      canvas.addEventListener('pointercancel', endPan);
      canvas.addEventListener('contextmenu', function (e) { e.preventDefault(); });
      document.addEventListener('keydown', function (e) {
        if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA')) return;
        if (e.code === 'Space') spaceDown = true;
      });
      document.addEventListener('keyup', function (e) {
        if (e.code === 'Space') spaceDown = false;
      });
```

with:

```js
      canvas.addEventListener('wheel', onWheel, { passive: false });
      canvas.addEventListener('pointerdown', onPointerDown);
      canvas.addEventListener('pointermove', onPointerMove);
      canvas.addEventListener('pointerup', onPointerUp);
      canvas.addEventListener('pointercancel', onPointerCancel);
      canvas.addEventListener('contextmenu', function (e) { e.preventDefault(); });

      document.addEventListener('keydown', function (e) {
        var tag = e.target && e.target.tagName;
        if (tag === 'INPUT' || tag === 'TEXTAREA') return;
        if (e.code === 'Space') spaceDown = true;
        if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'z') {
          e.preventDefault();
          if (e.shiftKey) redo(); else undo();
        } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'y') {
          e.preventDefault();
          redo();
        }
      });
      document.addEventListener('keyup', function (e) {
        if (e.code === 'Space') spaceDown = false;
      });
```

- [ ] **Step 3: Wire the toolbar (tools + undo/redo buttons) in `boot()`**

Add the following at the end of `boot()` (after `buildPalette();` is fine — order within boot does not matter):

```js
      var toolBtns = document.querySelectorAll('.tool-btn');
      toolBtns.forEach(function (b) {
        b.addEventListener('click', function () {
          state.tool = b.dataset.tool;
          toolBtns.forEach(function (x) { x.classList.remove('active'); });
          b.classList.add('active');
          renderStatus();
        });
      });
      document.getElementById('btn-undo').addEventListener('click', undo);
      document.getElementById('btn-redo').addEventListener('click', redo);
```

- [ ] **Step 4: Verify the file still evals cleanly in Node**

Run: `cd /e/Workspace/godot/the-cyancular-ruins/editor && node smoke.js`
Expected: all tests pass, exit 0.

- [ ] **Step 5: Manual browser check**

Run: `cmd //c start "" "E:/Workspace/godot/the-cyancular-ruins/editor/structure-editor.html"`
Verify:
- **画笔**: left-drag paints the current tile; fast drags leave no gaps (line interpolation).
- **橡皮 / erase**: right-drag or Alt+left-drag paints 0; toolbar 橡皮 also paints 0.
- **矩形**: drag shows a translucent preview; release fills the rectangle (also with erase).
- **油漆桶**: click floods the connected same-value region; clicking on same-value region is a no-op.
- **撤销/重做**: Ctrl+Z undoes a stroke/rect/fill; Ctrl+Y and Ctrl+Shift+Z redo; toolbar buttons work; status bar counts update.
- Pan still works (middle-drag / space+drag).

- [ ] **Step 6: Commit**

```bash
cd /e/Workspace/godot
git add the-cyancular-ruins/editor/structure-editor.html
git commit -m "feat(editor): paint/erase/rect/fill tools + undo/redo"
```

---

### Task 6: UI — library management (add / duplicate / rename / delete) + canvas resize

**Files:**
- Modify: `the-cyancular-ruins/editor/structure-editor.html` (UI block)

**Interfaces:**
- Consumes: `Core.sanitizeName`, `Core.resizeGrid` (Tasks 1–2); Task 4–5 UI (`render`, `fit`, `syncSizeInputs`, `selectStructure`).
- Produces: `addStructure()`, `duplicateStructure()`, `renameStructure()`, `deleteStructure()`, `applySize()`, `promptName(title, initial) -> Promise<string|null>`.

- [ ] **Step 1: Add library-management functions inside the UI IIFE**, before `function render() {`:

```js
    // ── modal name prompt ──
    function promptName(title, initial) {
      return new Promise(function (resolve) {
        els.modalTitle.textContent = title;
        els.modalInput.value = initial || '';
        els.modalErr.textContent = '';
        els.modalOverlay.classList.remove('hidden');
        els.modalInput.focus();
        els.modalInput.select();
        function finish(val) {
          els.modalOverlay.classList.add('hidden');
          els.modalOk.removeEventListener('click', onOk);
          els.modalCancel.removeEventListener('click', onCancel);
          els.modalInput.removeEventListener('keydown', onKey);
          resolve(val);
        }
        function onOk() {
          var raw = els.modalInput.value;
          var name = Core.sanitizeName(raw);
          if (name === 'structure' && raw.trim() === '') {
            els.modalErr.textContent = '名称不能为空';
            return;
          }
          if (state.library.some(function (s) { return s.name === name; })) {
            els.modalErr.textContent = '名称已存在：' + name;
            return;
          }
          finish(name);
        }
        function onCancel() { finish(null); }
        function onKey(e) {
          if (e.key === 'Enter') onOk();
          if (e.key === 'Escape') onCancel();
        }
        els.modalOk.addEventListener('click', onOk);
        els.modalCancel.addEventListener('click', onCancel);
        els.modalInput.addEventListener('keydown', onKey);
      });
    }

    // ── library actions ──
    function addStructure() {
      var w = clampInt(els.sizeW.value, 1, 64, 12);
      var h = clampInt(els.sizeH.value, 1, 64, 12);
      promptName('新建结构', uniqueName('structure', state.library)).then(function (name) {
        if (!name) return;
        var grid = [];
        for (var y = 0; y < h; y++) {
          var r = new Array(w);
          for (var x = 0; x < w; x++) r[x] = 0;
          grid.push(r);
        }
        var s = { id: uid(), name: name, grid: grid };
        state.library.push(s);
        state.selectedId = s.id;
        syncSizeInputs();
        fit();
        render();
      });
    }
    function duplicateStructure() {
      var s = sel();
      if (!s) return;
      var copy = { id: uid(), name: uniqueName(s.name, state.library), grid: cloneGrid(s.grid) };
      state.library.push(copy);
      state.selectedId = copy.id;
      syncSizeInputs();
      fit();
      render();
    }
    function renameStructure() {
      var s = sel();
      if (!s) return;
      promptName('重命名结构', s.name).then(function (name) {
        if (!name) return;
        s.name = name;
        render();
      });
    }
    function deleteStructure() {
      var s = sel();
      if (!s) return;
      if (!window.confirm('删除结构 "' + s.name + '"？')) return;
      var idx = state.library.indexOf(s);
      state.library.splice(idx, 1);
      if (state.library.length === 0) {
        state.selectedId = null;
      } else {
        state.selectedId = state.library[Math.min(idx, state.library.length - 1)].id;
      }
      syncSizeInputs();
      fit();
      render();
    }
    function applySize() {
      var s = sel();
      if (!s) return;
      var w = clampInt(els.sizeW.value, 1, 64, 12);
      var h = clampInt(els.sizeH.value, 1, 64, 12);
      pushHistory(s);
      s.grid = Core.resizeGrid(s.grid, w, h);
      syncSizeInputs();
      render();
    }
```

- [ ] **Step 2: Add the modal + action buttons to `boot()`**

Add `modalOverlay`, `modalTitle`, `modalInput`, `modalErr`, `modalOk`, `modalCancel`, `btnAdd`, `btnDup`, `btnRename`, `btnDel`, `btnResize` to the `els` object in `boot()`, then append after the existing wiring:

```js
      document.getElementById('btn-add').addEventListener('click', addStructure);
      document.getElementById('btn-dup').addEventListener('click', duplicateStructure);
      document.getElementById('btn-rename').addEventListener('click', renameStructure);
      document.getElementById('btn-del').addEventListener('click', deleteStructure);
      document.getElementById('btn-resize').addEventListener('click', applySize);
```

The updated `els` object becomes (replace the Task-4 `els` assignment entirely):

```js
      els = {
        libraryList: document.getElementById('library-list'),
        sizeW: document.getElementById('size-w'),
        sizeH: document.getElementById('size-h'),
        palette: document.getElementById('palette'),
        canvas: document.getElementById('canvas'),
        canvasWrap: document.getElementById('canvas-wrap'),
        statusbar: document.getElementById('statusbar'),
        gridToggle: document.getElementById('grid-toggle'),
        btnFit: document.getElementById('btn-fit'),
        modalOverlay: document.getElementById('modal-overlay'),
        modalTitle: document.getElementById('modal-title'),
        modalInput: document.getElementById('modal-input'),
        modalErr: document.getElementById('modal-err'),
        modalOk: document.getElementById('modal-ok'),
        modalCancel: document.getElementById('modal-cancel')
      };
```

- [ ] **Step 3: Verify the file still evals cleanly in Node**

Run: `cd /e/Workspace/godot/the-cyancular-ruins/editor && node smoke.js`
Expected: all tests pass, exit 0.

- [ ] **Step 4: Manual browser check**

Run: `cmd //c start "" "E:/Workspace/godot/the-cyancular-ruins/editor/structure-editor.html"`
Verify:
- **新建**: opens name modal; empty name rejected; duplicate name rejected with inline error; Enter confirms, Esc cancels; new all-air structure created at the size in the size inputs and selected.
- **复制**: creates a copy with a `_2` suffix, selected.
- **重命名**: modal pre-filled; rename works; empty / duplicate rejected.
- **删除**: confirm dialog; selection moves to neighbor.
- **应用尺寸**: enlarging pads with air (0), shrinking trims; undo (Ctrl+Z) reverts a resize.
- Library list shows correct `W×H` per structure; clicking switches selection and refits.

- [ ] **Step 5: Commit**

```bash
cd /e/Workspace/godot
git add the-cyancular-ruins/editor/structure-editor.html
git commit -m "feat(editor): structure library CRUD + canvas resize + name modal"
```

---

### Task 7: UI — import / export + final polish + full verification

**Files:**
- Modify: `the-cyancular-ruins/editor/structure-editor.html` (UI block)
- Verify: `the-cyancular-ruins/editor/smoke.js` (no change expected)

**Interfaces:**
- Consumes: `Core.serializeLibrary`, `Core.parseLibrary` (Task 2); Task 4–6 UI.
- Produces: `exportLibrary()`, `importLibrary()`.

- [ ] **Step 1: Add import/export functions inside the UI IIFE**, before `function render() {`:

```js
    // ── import / export ──
    function exportLibrary() {
      if (state.library.length === 0) {
        window.alert('库为空，无可导出');
        return;
      }
      var emptyOnes = state.library.filter(function (s) {
        return s.grid.every(function (row) { return row.every(function (v) { return v === 0; }); });
      });
      if (emptyOnes.length > 0) {
        var names = emptyOnes.map(function (s) { return s.name; }).join('、');
        if (!window.confirm('以下结构全是空气（0）：' + names + '\n仍要导出吗？')) return;
      }
      var text;
      try {
        text = Core.serializeLibrary(state.library);
      } catch (err) {
        window.alert('导出失败：' + err.message);
        return;
      }
      var blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a');
      a.href = url;
      a.download = 'cyr_structures.txt';
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    }
    function importLibrary() {
      var file = els.fileImport.files && els.fileImport.files[0];
      if (!file) return;
      var reader = new FileReader();
      reader.onload = function () {
        var imported;
        try {
          imported = Core.parseLibrary(String(reader.result));
        } catch (err) {
          window.alert('导入失败：' + err.message);
          return;
        }
        if (imported.length === 0) {
          window.alert('文件里没有可用的结构');
          return;
        }
        var firstId = null;
        imported.forEach(function (st) {
          var s = { id: uid(), name: uniqueName(st.name, state.library), grid: st.grid };
          state.library.push(s);
          if (firstId === null) firstId = s.id;
        });
        state.selectedId = firstId;
        els.fileImport.value = '';
        syncSizeInputs();
        fit();
        render();
      };
      reader.readAsText(file, 'utf-8');
    }
```

- [ ] **Step 2: Wire import/export buttons in `boot()`**

Append after the Task-6 wiring:

```js
      els.fileImport = document.getElementById('file-import');
      document.getElementById('btn-import').addEventListener('click', function () {
        els.fileImport.click();
      });
      document.getElementById('btn-export').addEventListener('click', exportLibrary);
      els.fileImport.addEventListener('change', importLibrary);
```

- [ ] **Step 3: Full automated verification**

Run: `cd /e/Workspace/godot/the-cyancular-ruins/editor && node smoke.js`
Expected: all tests pass (`结果: 33 通过, 0 失败`), exit 0.

- [ ] **Step 4: Full manual browser check**

Run: `cmd //c start "" "E:/Workspace/godot/the-cyancular-ruins/editor/structure-editor.html"`
Walk the complete checklist:
1. Canvas shows the seeded demo; wheel-zoom, middle/space-drag pan, 适配, grid toggle all work.
2. Paint (tile 1–9), erase (right-drag / Alt-drag / 橡皮), rectangle with preview, flood fill, undo/redo (buttons + Ctrl+Z/Ctrl+Y/Ctrl+Shift+Z).
3. Library CRUD: 新建 (size from inputs, name validation), 复制, 重命名, 删除, 应用尺寸 (pad/trim), selection switching.
4. **Export → import round-trip**: click 导出库 → `cyr_structures.txt` downloads; delete a structure; click 导入, pick the downloaded file → structures return (name collisions get `_2` suffixes); a file edited by hand with a bad char or ragged row is rejected with a Chinese error and nothing is imported.
5. Reload the page (F5) → editor boots fresh with the demo (library not persisted across reloads — expected, that is not part of this task).

- [ ] **Step 5: Commit**

```bash
cd /e/Workspace/godot
git add the-cyancular-ruins/editor/structure-editor.html
git commit -m "feat(editor): import/export library + all-air export warning"
```

---

## Self-Review

**Spec coverage:**
- Data model (structure = 2D array, tiles 0–9): Tasks 1–3 core. ✅
- Export format (`# name` blocks, digit rows, blank lines ignored, bare comments): Task 2 + Task 7 round-trip. ✅
- Editor UI (sidebar library/palette/size, canvas, tools, top bar import/export): Tasks 4–7. ✅
- Validation (names unique/sanitized incl. CJK, grids digits-only/equal-width, malformed import rejected): Tasks 1–2 + Task 6 modal + Task 7 import. ✅
- Advisory all-air warning on export: Task 7. ✅
- Single self-contained HTML, no game-side changes: Global Constraints + all tasks touch only `editor/`. ✅
- Pure functions tested via node smoke: Tasks 1–3. ✅
- resize trim/pad: Task 2 + Task 6 UI wiring. ✅
- undo/redo: Task 5. ✅

**Placeholder scan:** No TBD/TODO; every step carries exact code or an exact command with expected output. ✅

**Type consistency:** `Core.sanitizeName`/`validateGrid`/`serializeLibrary`/`parseLibrary`/`resizeGrid`/`rectFill`/`floodFill` names are identical across smoke tests (Tasks 1–3) and UI call sites (Tasks 4–7). UI helpers `render/renderCanvas/renderLibrary/renderStatus/fit/zoomAt/cellAt/selectStructure/syncSizeInputs/buildPalette/resizeCanvas/undo/redo/promptName/addStructure/duplicateStructure/renameStructure/deleteStructure/applySize/exportLibrary/importLibrary` are defined exactly once each and called with the same names everywhere. `els` fields referenced in tasks 5–7 (`modalOverlay`…`fileImport`) are all assigned in the Task-6/7 `els` updates. ✅
