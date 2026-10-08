# `.cyrm` v4 格式核心层实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 `level_editor/core.js` —— `.cyrm` v4 二进制格式的数据模型、编解码、v3 迁移与校验,全部可用 `node smoke.js` 自动验证,不依赖浏览器。

**Architecture:** 一个 DOM-free 的纯逻辑模块,导出到 `globalThis.Core`。内部按"位域 → 字节读写 → 分层块编解码 → 整文件容器 → 旧格式迁移 → 校验"六层递进,每层只依赖它下面那层。压缩用浏览器/Node 都原生提供的 `CompressionStream('deflate')`,不自造压缩器。

**Tech Stack:** 纯 JavaScript(经典脚本,非 ES module)、`Uint8Array`/`Uint32Array`、`TextEncoder`/`TextDecoder`、`CompressionStream`/`DecompressionStream`、`Blob`+`Response`、Node(v24)跑冒烟。

## Global Constraints

- **规格是唯一事实来源**:`docs/superpowers/specs/2026-09-19-cyrm-v4-editor-design.md`。任何与本计划冲突之处,以规格为准,并在提交信息里说明。
- **子格 = 16px,格 = 64px,`SUB_PER_CELL = 4`**。`subCols`/`subRows` 必须是 4 的倍数,编解码两侧都要断言。
- **descriptor 是 32 位无符号整数**,`0` 恒为空气。位域从低位起:`hue(3) | bright(3)<<3 | sat(3)<<6 | alpha(3)<<9 | texture(12)<<12`,bit 24-31 保留为 0。
- **中性描述符 = `(hue 4, bright 4, sat 4, alpha 7)`**。三列的中性档不在一行:alpha 的中性在**档 7**,其余在**档 4**。
- **调色板索引 0 恒为 `DESC_AIR`**(即使本层没有任何空气格,也要占住第 0 位)。
- **所有多字节整数一律小端**。
- **v3 packed(`texture*16 + shape`)与 v4 descriptor 是两种完全不同的编码**,代码里必须用不同的函数名(`_v3Pack` vs `packDesc`),不得混用。
- **`core.js` 不得引用任何 DOM API**,必须能被 Node 直接 `new Function(src)()` 求值。
- **文件头 20 字节,明文不压缩**;`body_size` 是**解压后**的字节数。
- **注释一律用中文**,与仓库其余部分一致。

---

## 文件结构

| 文件 | 职责 | 本计划中的动作 |
|---|---|---|
| `level_editor/core.js` | 数据模型 + 二进制编解码 + v3 迁移 + 校验。DOM-free,导出 `globalThis.Core` | **新建** |
| `level_editor/smoke.js` | Node 冒烟:直接读 `core.js` 并断言 | **重写加载段**,替换旧断言 |

`core.js` 内部分层(自上而下),每层只依赖下层:

```
校验        validateMap
迁移        parseV3Text / migrateV3 / subcellRender
容器        encodeMap / decodeMap / buildMeta / parseMeta
分层块      encodeTexLayer / decodeTexLayer / encodeColorLayer / decodeColorLayer
字节        ByteWriter / ByteReader / crc32
位域        packDesc / texOf / hueOf / brightOf / satOf / alphaOf / neutralDesc
基础        createMap / subIndex / sanitizeName / brushOffsets / lineCells / normRegion
```

---

## Task 1: 模块骨架 + descriptor 位域 + smoke 加载方式改造

**Files:**
- Create: `level_editor/core.js`
- Modify: `level_editor/smoke.js:1-56`(加载段与断言助手)

**Interfaces:**
- Consumes: 无
- Produces: `Core.packDesc(texture, hue, bright, sat, alpha) -> u32`、`Core.texOf(d) -> int`、`Core.hueOf(d)`、`Core.brightOf(d)`、`Core.satOf(d)`、`Core.alphaOf(d)`、`Core.isAir(d) -> bool`、`Core.neutralDesc(texture) -> u32`、`Core.DESC_AIR`、`Core.SUB_PER_CELL`、`Core.TEXTURE_MAX`

- [ ] **Step 1: 改写 smoke.js 的加载段,并加入 descriptor 断言(此时必然失败)**

把 `level_editor/smoke.js` 的第 1–56 行**整体替换**为下列内容(后续 Task 都往这个文件的"断言区"追加):

```js
'use strict';

// Node smoke test —— `.cyrm` v4 格式核心层(level_editor/core.js)。
// 直接读 core.js 并求值,不依赖浏览器、不依赖 structure-editor.html。
//
// Run: node smoke.js

const fs = require('fs');
const path = require('path');

const corePath = path.join(__dirname, 'core.js');
if (!fs.existsSync(corePath)) {
  console.error('FAIL: 找不到 ' + corePath);
  process.exit(1);
}
const coreSrc = fs.readFileSync(corePath, 'utf8');
try {
  new Function(coreSrc)();
} catch (err) {
  console.error('core.js 执行失败（可能是语法错误）:', err.message);
  process.exit(1);
}
const Core = globalThis.Core;
if (!Core) {
  console.error('FAIL: core.js 没有导出 globalThis.Core');
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
// 异步版的 throws —— decodeMap 是 async,「坏文件必须抛错」那批断言要用它。
async function rejects(fn, msg) {
  try { await fn(); fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); }
  catch (e) { pass++; console.log('  ok  - ' + msg); }
}

(async function main() {

// ==== 断言区 ====

// ---- descriptor 位域 ----
ok(Core.SUB_PER_CELL === 4, 'SUB_PER_CELL === 4');
ok(Core.DESC_AIR === 0, 'DESC_AIR === 0');
eq(Core.packDesc(0, 0, 0, 0, 0), 0, 'packDesc: 纹理 0 恒为空气');
eq(Core.packDesc(0, 7, 7, 7, 7), 0, 'packDesc: 空气忽略辅码');
ok(Core.packDesc(1, 4, 4, 4, 7) !== 0, 'packDesc: 纹理 1 中性描述符非 0');

var d1 = Core.packDesc(5, 4, 3, 2, 7);
eq(Core.texOf(d1), 5, 'descriptor: 纹理回读');
eq(Core.hueOf(d1), 4, 'descriptor: 色相回读');
eq(Core.brightOf(d1), 3, 'descriptor: 亮度回读');
eq(Core.satOf(d1), 2, 'descriptor: 饱和度回读');
eq(Core.alphaOf(d1), 7, 'descriptor: 透明度回读');

var all = Core.packDesc(4095, 7, 7, 7, 7);
eq(Core.texOf(all), 4095, 'descriptor: 纹理上界 4095');
eq(Core.hueOf(all) + Core.brightOf(all) + Core.satOf(all) + Core.alphaOf(all), 28, 'descriptor: 四个辅码全 7');
eq(Core.packDesc(4096, 4, 4, 4, 7), 0, 'descriptor: 纹理 4096 溢出为空气');
eq(Core.packDesc(-1, 4, 4, 4, 7), 0, 'descriptor: 负纹理为空气');

var n9 = Core.neutralDesc(9);
ok(Core.texOf(n9) === 9 && Core.hueOf(n9) === 4 && Core.brightOf(n9) === 4 &&
   Core.satOf(n9) === 4 && Core.alphaOf(n9) === 7, 'neutralDesc: (4,4,4,7) 且保留纹理');
ok(Core.isAir(0) && !Core.isAir(n9), 'isAir: 只对 0 为真');

// ==== 断言区结束 ====

console.log('');
console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
if (fail === 0) console.log('SMOKE OK');
process.exit(fail === 0 ? 0 : 1);

})();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node smoke.js`
Expected: 打印 `FAIL: 找不到 .../core.js`,退出码 1

- [ ] **Step 3: 新建 core.js,只实现位域层**

```js
// core.js —— `.cyrm` v4 数据模型 + 二进制编解码 + v3 迁移 + 校验。
// ★ 纯逻辑,不引用任何 DOM API:必须能被 node 直接 new Function(src)() 求值(smoke.js 就是这么跑的)。
// ★ 格式规格:docs/superpowers/specs/2026-09-19-cyrm-v4-editor-design.md §2 / §3。
//   v3 packed = texture*16 + shape 与 v4 descriptor 是两种完全不同的编码 —— 本文件里
//   _v3Pack / _v3TexOf / _v3ShapeOf 专管前者,packDesc / texOf 专管后者,不得混用。
globalThis.Core = (function () {
  'use strict';

  // ── 常量 ──
  const SUB_PER_CELL = 4;          // 每 64px 格细分成 4×4 个 16px 子格(规格 §2.1)
  const SUB_PX = 16;               // 子格边长(世界像素)
  const CELL_PX = 64;              // 格边长(世界像素)

  // ── descriptor 位域(规格 §2.3)──
  //   bit  0- 2  hue         0-7
  //   bit  3- 5  brightness  0-7
  //   bit  6- 8  saturation  0-7
  //   bit  9-11  alpha       0-7
  //   bit 12-23  texture     1-4095(0 = 空气)
  //   bit 24-31  保留,固定 0
  const DESC_AIR = 0;
  const TEXTURE_MAX = 4095;
  const HUE_NEUTRAL = 4, BRI_NEUTRAL = 4, SAT_NEUTRAL = 4, ALPHA_NEUTRAL = 7;

  // 打包成 u32。纹理不在 1..TEXTURE_MAX 内一律当空气(含 0 与负数)。
  function packDesc(texture, hue, bright, sat, alpha) {
    texture = texture | 0;
    if (texture <= 0 || texture > TEXTURE_MAX) return DESC_AIR;
    return (((hue & 7)) |
            ((bright & 7) << 3) |
            ((sat & 7) << 6) |
            ((alpha & 7) << 9) |
            (texture << 12)) >>> 0;
  }
  function texOf(d)    { return (d >>> 12) & 0xFFF; }
  function hueOf(d)    { return d & 7; }
  function brightOf(d) { return (d >>> 3) & 7; }
  function satOf(d)    { return (d >>> 6) & 7; }
  function alphaOf(d)  { return (d >>> 9) & 7; }
  function isAir(d)    { return d === DESC_AIR; }

  // 中性描述符 = 完全按原图,一点色都不改。
  // ★ 三列的中性档不在同一行:alpha 的中性在档 7,其余在档 4。
  function neutralDesc(texture) {
    return packDesc(texture, HUE_NEUTRAL, BRI_NEUTRAL, SAT_NEUTRAL, ALPHA_NEUTRAL);
  }

  return {
    SUB_PER_CELL: SUB_PER_CELL,
    SUB_PX: SUB_PX,
    CELL_PX: CELL_PX,
    DESC_AIR: DESC_AIR,
    TEXTURE_MAX: TEXTURE_MAX,
    HUE_NEUTRAL: HUE_NEUTRAL, BRI_NEUTRAL: BRI_NEUTRAL,
    SAT_NEUTRAL: SAT_NEUTRAL, ALPHA_NEUTRAL: ALPHA_NEUTRAL,
    packDesc: packDesc,
    texOf: texOf, hueOf: hueOf, brightOf: brightOf, satOf: satOf, alphaOf: alphaOf,
    isAir: isAir, neutralDesc: neutralDesc,
  };
})();
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node smoke.js`
Expected: 全部 `ok`,末行 `SMOKE OK`,退出码 0

- [ ] **Step 5: 提交**

```bash
git add level_editor/core.js level_editor/smoke.js
git commit -F - <<'EOF'
feat(editor): core.js 骨架 + v4 descriptor 位域

新增 level_editor/core.js(DOM-free,导出 globalThis.Core),
实现 §2.3 的 32 位描述符编解码与中性值。

smoke.js 改为直接读 core.js(不再从 HTML 抠 <script> 块),
旧的 parseMap/serializeMap/validateGrid/moveRegion 等断言随之移除 ——
那些函数将在计划 2 用新签名(TypedArray)重建。
EOF
```

---

## Task 2: 地图对象、图层常量与基础纯函数

**Files:**
- Modify: `level_editor/core.js`(在 descriptor 层之下追加基础层)
- Modify: `level_editor/smoke.js`(断言区追加)

**Interfaces:**
- Consumes: Task 1 的 `packDesc` / `SUB_PER_CELL`
- Produces:
  - `Core.LAYER_COUNT = 4`、`Core.LAYER_FRONT = 0`、`Core.LAYER_SCENE = 1`、`Core.LAYER_BACK = 2`、`Core.LAYER_BG = 3`
  - `Core.LAYER_NAMES = ['前景','场景','后景','背景']`
  - `Core.LAYER_KINDS = ['tex','tex','tex','color']`
  - `Core.createMap(name, cellsW, cellsH) -> map`
  - `Core.subIndex(subCols, X, Y) -> int`
  - `Core.cellsWOf(map)`、`Core.cellsHOf(map)`
  - `Core.sanitizeName(name) -> String`
  - `Core.brushOffsets(size) -> {lo, hi}`
  - `Core.lineCells(x0, y0, x1, y1) -> Array<[x,y]>`
  - `Core.normRegion(x0, y0, x1, y1) -> {x,y,w,h}`

- [ ] **Step 1: 在 smoke.js 的断言区末尾追加断言**

```js
// ---- 图层常量与地图对象 ----
ok(Core.LAYER_COUNT === 4, 'LAYER_COUNT === 4');
eq(Core.LAYER_NAMES, ['前景', '场景', '后景', '背景'], 'LAYER_NAMES 顺序:前/场/后/背景');
eq(Core.LAYER_KINDS, ['tex', 'tex', 'tex', 'color'], 'LAYER_KINDS:背景层是颜色层');
ok(Core.LAYER_FRONT === 0 && Core.LAYER_SCENE === 1 && Core.LAYER_BACK === 2 && Core.LAYER_BG === 3,
   '图层索引常量');

var m = Core.createMap('demo', 125, 75);
eq(m.subCols, 500, 'createMap: subCols = 格数×4');
eq(m.subRows, 300, 'createMap: subRows = 格数×4');
eq(m.layers.length, 4, 'createMap: 四个图层');
eq(m.layers.map(function (L) { return L.kind; }), ['tex', 'tex', 'tex', 'color'], 'createMap: 图层种类');
ok(m.layers[0].desc instanceof Uint32Array, 'createMap: 前景层是 Uint32Array');
eq(m.layers[0].desc.length, 500 * 300, 'createMap: 前景层长度 = subCols×subRows');
ok(m.layers[3].rgba instanceof Uint32Array, 'createMap: 背景层是 rgba 数组');
eq(m.layers[3].rgba.length, 500 * 300, 'createMap: 背景层长度');
eq(m.players, [], 'createMap: players 初始为空数组');
eq(m.enemies, [], 'createMap: enemies 初始为空数组');
eq(m.comments, [], 'createMap: comments 初始为空数组');
eq(Core.cellsWOf(m), 125, 'cellsWOf');
eq(Core.cellsHOf(m), 75, 'cellsHOf');

eq(Core.subIndex(500, 3, 2), 2 * 500 + 3, 'subIndex: 行主序 y*subCols+x');
eq(Core.subIndex(500, 0, 0), 0, 'subIndex: 原点');

throws(function () { Core.createMap('bad', 1.5, 10); }, 'createMap: 非整数格数报错');
throws(function () { Core.createMap('bad', 0, 10); }, 'createMap: 零宽报错');

// ---- 从旧编辑器沿用、与格式无关的纯函数 ----
eq(Core.sanitizeName('My Tower #1'), 'My_Tower_1', 'sanitizeName: 非法字符被清理');
eq(Core.sanitizeName('   spaced   name  '), 'spaced_name', 'sanitizeName: 空格合并为下划线');
eq(Core.sanitizeName('---'), 'structure', 'sanitizeName: 全非法回落默认名');
eq(Core.sanitizeName(''), 'structure', 'sanitizeName: 空名回落');
eq(Core.sanitizeName('塔楼 #1'), '塔楼_1', 'sanitizeName: 保留中文');

eq(Core.brushOffsets(1), { lo: 0, hi: 0 }, 'brushOffsets: 1 → 1×1');
eq(Core.brushOffsets(2), { lo: 0, hi: 1 }, 'brushOffsets: 2 → 2×2(偏下右)');
eq(Core.brushOffsets(3), { lo: 1, hi: 1 }, 'brushOffsets: 3 → 3×3');
eq(Core.brushOffsets(4), { lo: 1, hi: 2 }, 'brushOffsets: 4 → 4×4(偏下右)');
ok((function () {
  for (var s = 1; s <= 15; s++) {
    var o = Core.brushOffsets(s);
    if (!o || o.lo + o.hi + 1 !== s || o.lo < 0 || o.hi < o.lo) return false;
  }
  return true;
})(), 'brushOffsets: 1..15 全部满足 lo+1+hi===尺寸 且 lo≤hi');

eq(Core.lineCells(0, 0, 4, 0), [[0,0],[1,0],[2,0],[3,0],[4,0]], 'lineCells: 水平线');
eq(Core.lineCells(2, 2, 2, 5), [[2,2],[2,3],[2,4],[2,5]], 'lineCells: 垂直线');
eq(Core.lineCells(0, 0, 2, 2), [[0,0],[1,1],[2,2]], 'lineCells: 对角线');
eq(Core.lineCells(4, 0, 0, 0), [[4,0],[3,0],[2,0],[1,0],[0,0]], 'lineCells: 反向水平');
eq(Core.lineCells(1, 1, 1, 1), [[1,1]], 'lineCells: 单点');
eq(Core.lineCells(0, 0, 4, 2), [[0,0],[1,0],[2,1],[3,1],[4,2]], 'lineCells: 缓坡 Bresenham 锚定');

eq(Core.normRegion(3, 2, 1, 5), { x: 1, y: 2, w: 3, h: 4 }, 'normRegion: 反向角归一化');
eq(Core.normRegion(1, 1, 1, 1), { x: 1, y: 1, w: 1, h: 1 }, 'normRegion: 单格');
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node smoke.js`
Expected: 出现 `FAIL - Core.LAYER_COUNT === 4` 等一批失败,退出码 1

- [ ] **Step 3: 在 core.js 里实现基础层**

在 `globalThis.Core = (function () {` 的第一行 `'use strict';` **之后**插入以下内容(放在 descriptor 段之前,因为它不依赖 descriptor):

```js
  // ── 图层(规格 §2.1)──
  // 顺序从外到内:前景 / 场景 / 后景 / 背景。只有「场景」参与碰撞。
  const LAYER_COUNT = 4;
  const LAYER_FRONT = 0, LAYER_SCENE = 1, LAYER_BACK = 2, LAYER_BG = 3;
  const LAYER_NAMES = ['前景', '场景', '后景', '背景'];
  const LAYER_KINDS = ['tex', 'tex', 'tex', 'color'];

  // ── 地图对象 ──
  // 全部用 TypedArray:4 层 × 150k 子格若用嵌套 JS 数组会到几十 MB 且 GC 压力巨大。
  // 下标一律 = y * subCols + x(行主序),与文件里的排布一致。
  function createMap(name, cellsW, cellsH) {
    if (!Number.isInteger(cellsW) || !Number.isInteger(cellsH) || cellsW <= 0 || cellsH <= 0) {
      throw new Error('createMap: 格数必须是正整数,收到 ' + cellsW + '×' + cellsH);
    }
    var subCols = cellsW * SUB_PER_CELL;
    var subRows = cellsH * SUB_PER_CELL;
    var n = subCols * subRows;
    return {
      name: String(name == null ? '' : name),
      subCols: subCols,
      subRows: subRows,
      layers: [
        { kind: 'tex', desc: new Uint32Array(n) },
        { kind: 'tex', desc: new Uint32Array(n) },
        { kind: 'tex', desc: new Uint32Array(n) },
        { kind: 'color', rgba: new Uint32Array(n) },
      ],
      players: [],
      enemies: [],
      comments: [],
    };
  }
  function cellsWOf(map) { return map.subCols / SUB_PER_CELL; }
  function cellsHOf(map) { return map.subRows / SUB_PER_CELL; }
  function subIndex(subCols, X, Y) { return Y * subCols + X; }

  // ── 与格式无关的纯工具(自旧编辑器沿用)──
  function sanitizeName(name) {
    var n = String(name == null ? '' : name).trim();
    n = n.replace(/\s+/g, '_');
    n = n.replace(/[^A-Za-z0-9_一-龥-]/g, '');
    n = n.replace(/^-+/, '');
    if (n.length > 32) n = n.slice(0, 32);
    return n === '' ? 'structure' : n;
  }

  // 画笔块偏移:以指针格为中心的上下/左右扩展量,保证 lo+1+hi===size。
  // 奇数尺寸对称;偶数尺寸偏下右(否则偶数会缩水一格)。
  function brushOffsets(size) {
    return { lo: Math.floor((size - 1) / 2), hi: Math.ceil((size - 1) / 2) };
  }

  // Bresenham 直线路径格坐标(含两端)。
  function lineCells(x0, y0, x1, y1) {
    var cells = [];
    var dx = Math.abs(x1 - x0), dy = Math.abs(y1 - y0);
    var sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    var err = dx - dy;
    var x = x0, y = y0;
    for (;;) {
      cells.push([x, y]);
      if (x === x1 && y === y1) break;
      var e2 = 2 * err;
      if (e2 > -dy) { err -= dy; x += sx; }
      if (e2 < dx) { err += dx; y += sy; }
    }
    return cells;
  }

  // 矩形区域归一化:任意两角点 → {x, y, w, h}(含两端)。
  function normRegion(x0, y0, x1, y1) {
    return { x: Math.min(x0, x1), y: Math.min(y0, y1),
             w: Math.abs(x1 - x0) + 1, h: Math.abs(y1 - y0) + 1 };
  }
```

并把它们加入 `return { ... }` 导出表:

```js
    LAYER_COUNT: LAYER_COUNT,
    LAYER_FRONT: LAYER_FRONT, LAYER_SCENE: LAYER_SCENE,
    LAYER_BACK: LAYER_BACK, LAYER_BG: LAYER_BG,
    LAYER_NAMES: LAYER_NAMES, LAYER_KINDS: LAYER_KINDS,
    createMap: createMap, cellsWOf: cellsWOf, cellsHOf: cellsHOf, subIndex: subIndex,
    sanitizeName: sanitizeName, brushOffsets: brushOffsets,
    lineCells: lineCells, normRegion: normRegion,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node smoke.js`
Expected: 全部 `ok`,`SMOKE OK`,退出码 0

- [ ] **Step 5: 提交**

```bash
git add level_editor/core.js level_editor/smoke.js
git commit -F - <<'EOF'
feat(editor): core.js 地图对象、图层常量与基础纯函数

createMap 用 TypedArray 分配四层(前/场/后 tex + 背景 color),
并提供 subIndex / cellsWOf / cellsHOf。
sanitizeName / brushOffsets / lineCells / normRegion 自旧编辑器原样沿用。
EOF
```

---

## Task 3: 字节读写器与 CRC32

**Files:**
- Modify: `level_editor/core.js`
- Modify: `level_editor/smoke.js`

**Interfaces:**
- Consumes: 无
- Produces: `Core.ByteWriter`(方法 `u8/u16/u32/bytes/finish`,全部返回 `this` 以便链式)、`Core.ByteReader`(方法 `u8/u16/u32/bytes/remaining`)、`Core.crc32(bytes) -> u32`

- [ ] **Step 1: 追加断言**

```js
// ---- ByteWriter / ByteReader ----
(function () {
  var w = new Core.ByteWriter(4);          // 故意给小容量,顺便验扩容
  w.u8(0x12).u16(0x3456).u32(0x789ABCDE).bytes(new Uint8Array([0xAA, 0xBB]));
  var b = w.finish();
  eq(b.length, 1 + 2 + 4 + 2, 'ByteWriter: 长度累计正确');
  eq(Array.prototype.slice.call(b), [0x12, 0x56, 0x34, 0xDE, 0xBC, 0x9A, 0x78, 0xAA, 0xBB],
     'ByteWriter: 小端序');
  var r = new Core.ByteReader(b);
  eq(r.u8(), 0x12, 'ByteReader: u8');
  eq(r.u16(), 0x3456, 'ByteReader: u16');
  eq(r.u32(), 0x789ABCDE, 'ByteReader: u32 高位不为负');
  eq(Array.prototype.slice.call(r.bytes(2)), [0xAA, 0xBB], 'ByteReader: bytes');
  eq(r.remaining(), 0, 'ByteReader: remaining 归零');
  throws(function () { r.u8(); }, 'ByteReader: 越界读抛错');
  throws(function () { new Core.ByteReader(b).bytes(b.length + 1); }, 'ByteReader: bytes 越界抛错');
})();

// ---- CRC32(IEEE,标准测试向量)----
eq(Core.crc32(new Uint8Array(0)), 0, 'crc32: 空输入为 0');
eq(Core.crc32(new TextEncoder().encode('123456789')), 0xCBF43926, 'crc32: 标准向量 123456789');
eq(Core.crc32(new Uint8Array([0x00])), 0xD202EF8D, 'crc32: 单字节 0x00');
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node smoke.js`
Expected: `FAIL - ByteWriter: 长度累计正确` 等,退出码 1

- [ ] **Step 3: 实现**

在 core.js 的 `subIndex` 之后插入:

```js
  // ── 字节读写器(一律小端)──
  function ByteWriter(capacity) {
    this.buf = new Uint8Array(capacity || 256);
    this.len = 0;
  }
  ByteWriter.prototype._need = function (n) {
    if (this.len + n <= this.buf.length) return;
    var cap = this.buf.length;
    while (cap < this.len + n) cap *= 2;
    var nb = new Uint8Array(cap);
    nb.set(this.buf.subarray(0, this.len));
    this.buf = nb;
  };
  ByteWriter.prototype.u8 = function (v) {
    this._need(1); this.buf[this.len++] = v & 0xFF; return this;
  };
  ByteWriter.prototype.u16 = function (v) {
    this._need(2);
    this.buf[this.len++] = v & 0xFF;
    this.buf[this.len++] = (v >>> 8) & 0xFF;
    return this;
  };
  ByteWriter.prototype.u32 = function (v) {
    this._need(4);
    this.buf[this.len++] = v & 0xFF;
    this.buf[this.len++] = (v >>> 8) & 0xFF;
    this.buf[this.len++] = (v >>> 16) & 0xFF;
    this.buf[this.len++] = (v >>> 24) & 0xFF;
    return this;
  };
  ByteWriter.prototype.bytes = function (arr) {
    this._need(arr.length);
    this.buf.set(arr, this.len);
    this.len += arr.length;
    return this;
  };
  ByteWriter.prototype.finish = function () {
    return this.buf.slice(0, this.len);
  };

  function ByteReader(bytes) {
    this.b = bytes;
    this.p = 0;
  }
  ByteReader.prototype._need = function (n) {
    if (this.p + n > this.b.length) {
      throw new Error('ByteReader: 越界读(' + this.p + '+' + n + ' > ' + this.b.length + ')');
    }
  };
  ByteReader.prototype.u8 = function () {
    this._need(1); return this.b[this.p++];
  };
  ByteReader.prototype.u16 = function () {
    this._need(2);
    var v = this.b[this.p] | (this.b[this.p + 1] << 8);
    this.p += 2;
    return v >>> 0;
  };
  ByteReader.prototype.u32 = function () {
    this._need(4);
    var v = (this.b[this.p] | (this.b[this.p + 1] << 8) |
             (this.b[this.p + 2] << 16) | (this.b[this.p + 3] << 24)) >>> 0;
    this.p += 4;
    return v;
  };
  ByteReader.prototype.bytes = function (n) {
    this._need(n);
    var s = this.b.subarray(this.p, this.p + n);
    this.p += n;
    return s;
  };
  ByteReader.prototype.remaining = function () { return this.b.length - this.p; };

  // ── CRC32(IEEE 802.3,多项式 0xEDB88320)──
  const CRC_TABLE = (function () {
    var t = new Uint32Array(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      t[n] = c >>> 0;
    }
    return t;
  })();
  function crc32(bytes) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) {
      c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) >>> 0;
  }
```

导出表追加:

```js
    ByteWriter: ByteWriter, ByteReader: ByteReader, crc32: crc32,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node smoke.js`
Expected: `SMOKE OK`

- [ ] **Step 5: 提交**

```bash
git add level_editor/core.js level_editor/smoke.js
git commit -F - <<'EOF'
feat(editor): core.js 小端字节读写器与 CRC32

ByteWriter 自动扩容;ByteReader 越界即抛错(不静默返 0)。
CRC32 用 IEEE 标准多项式,以 123456789 → 0xCBF43926 钉住。
EOF
```

---

## Task 4: 纹理层块编解码(调色板 + 索引宽度)

**Files:**
- Modify: `level_editor/core.js`
- Modify: `level_editor/smoke.js`

**Interfaces:**
- Consumes: `ByteWriter` / `ByteReader` / `DESC_AIR` / `neutralDesc`
- Produces:
  - `Core.KIND_TEX = 1`、`Core.KIND_COLOR = 2`
  - `Core.encodeTexLayer(desc, subCols, subRows) -> Uint8Array`
  - `Core.decodeTexLayer(reader, subCols, subRows) -> { kind:'tex', desc: Uint32Array }`

- [ ] **Step 1: 追加断言**

```js
// ---- 纹理层块编解码 ----
(function () {
  var subCols = 8, subRows = 4, n = subCols * subRows;
  var desc = new Uint32Array(n);
  var brick = Core.neutralDesc(3);
  var moss = Core.packDesc(15, 4, 3, 5, 7);
  for (var i = 0; i < n; i++) {
    desc[i] = i < 4 ? 0 : (i < 12 ? brick : moss);
  }
  var enc = Core.encodeTexLayer(desc, subCols, subRows);
  eq(enc[0], Core.KIND_TEX, 'encodeTexLayer: 首字节是 kind');
  var r = new Core.ByteReader(enc);
  var dec = Core.decodeTexLayer(r, subCols, subRows);
  eq(r.remaining(), 0, 'decodeTexLayer: 字节全部消费');
  eq(dec.kind, 'tex', 'decodeTexLayer: kind');
  eq(Array.prototype.slice.call(dec.desc), Array.prototype.slice.call(desc), '纹理层: 往返一致');

  // 空气必须占住调色板第 0 位
  eq(dec.desc[0], 0, '纹理层: 空气回读为 0');

  // 调色板恰好 3 项(空气 + 两种纹理)→ 单字节索引
  var r2 = new Core.ByteReader(enc);
  r2.u8();                       // kind
  eq(r2.u16(), 3, '纹理层: 调色板 3 项');
  eq(r2.u32(), 0, '纹理层: 调色板[0] 是空气');
  eq(r2.u32(), brick, '纹理层: 调色板[1]');
  eq(r2.u32(), moss, '纹理层: 调色板[2]');
  eq(r2.u8(), 1, '纹理层: 调色板 ≤256 项 → index_width = 1');
  eq(enc.length, 1 + 2 + 3 * 4 + 1 + n, '纹理层: 总长度 = 头 + 调色板 + 索引流');

  // 空层:调色板只有空气一项
  var empty = new Uint32Array(16);
  var encEmpty = Core.encodeTexLayer(empty, 4, 4);
  var r3 = new Core.ByteReader(encEmpty);
  r3.u8();
  eq(r3.u16(), 1, '空层: 调色板只有 1 项');
  eq(encEmpty.length, 1 + 2 + 4 + 1 + 16, '空层: 长度');

  // 即使整层没有空气格,索引 0 仍必须是空气
  var full = new Uint32Array(16).fill(brick);
  var rFull = new Core.ByteReader(Core.encodeTexLayer(full, 4, 4));
  rFull.u8();
  eq(rFull.u16(), 2, '满层: 调色板 = 空气 + 砖 = 2 项');
  eq(rFull.u32(), 0, '满层: 索引 0 仍留给空气');
  eq(rFull.u32(), brick, '满层: 索引 1 才是砖');

  // 尺寸校验
  throws(function () { Core.encodeTexLayer(new Uint32Array(5), 4, 4); }, 'encodeTexLayer: 长度不符报错');
  // 越界索引要抛错而不是静默
  var bad = new Uint8Array([Core.KIND_TEX, 1, 0, 0, 0, 0, 0, 1, 99]);   // 调色板 1 项,索引 99
  throws(function () { Core.decodeTexLayer(new Core.ByteReader(bad), 1, 1); }, 'decodeTexLayer: 索引越界报错');
  throws(function () { Core.decodeTexLayer(new Core.ByteReader(new Uint8Array([9])), 1, 1); }, 'decodeTexLayer: 错 kind 报错');
})();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node smoke.js`
Expected: `FAIL - encodeTexLayer: 首字节是 kind`,退出码 1

- [ ] **Step 3: 实现**

在 core.js 的 `crc32` 之后插入:

```js
  // ── 层块种类(规格 §3.3 / §3.4)──
  const KIND_TEX = 1;
  const KIND_COLOR = 2;

  // 纹理层块:kind(1) + 调色板 + 索引流(规格 §3.3)。
  // ★ 索引 0 恒为空气 —— 即使本层一个空气格都没有,也要占住第 0 位,
  //   这样"空图 = 调色板 [0] + 全 0 索引流"是一条无条件成立的不变量。
  function encodeTexLayer(desc, subCols, subRows) {
    var n = subCols * subRows;
    if (desc.length !== n) {
      throw new Error('encodeTexLayer: desc 长度 ' + desc.length + ' ≠ subCols×subRows ' + n);
    }
    var pal = [DESC_AIR];
    var seen = new Map();
    seen.set(DESC_AIR, 0);
    var idx = new Uint32Array(n);
    for (var i = 0; i < n; i++) {
      var d = desc[i] >>> 0;
      var p = seen.get(d);
      if (p === undefined) {
        p = pal.length;
        if (p > 65535) throw new Error('encodeTexLayer: 调色板超过 65535 项');
        pal.push(d);
        seen.set(d, p);
      }
      idx[i] = p;
    }
    var iw = pal.length <= 256 ? 1 : 2;
    var w = new ByteWriter(8 + pal.length * 4 + n * iw);
    w.u8(KIND_TEX);
    w.u16(pal.length);
    for (var k = 0; k < pal.length; k++) w.u32(pal[k]);
    w.u8(iw);
    if (iw === 1) { for (i = 0; i < n; i++) w.u8(idx[i]); }
    else { for (i = 0; i < n; i++) w.u16(idx[i]); }
    return w.finish();
  }

  function decodeTexLayer(r, subCols, subRows) {
    var kind = r.u8();
    if (kind !== KIND_TEX) throw new Error('decodeTexLayer: kind=' + kind + ',期望 ' + KIND_TEX);
    var palCount = r.u16();
    if (palCount === 0) throw new Error('decodeTexLayer: 调色板为空(索引 0 必须留给空气)');
    var pal = new Uint32Array(palCount);
    for (var k = 0; k < palCount; k++) pal[k] = r.u32();
    var iw = r.u8();
    if (iw !== 1 && iw !== 2) throw new Error('decodeTexLayer: index_width=' + iw + '(只允许 1 或 2)');
    var n = subCols * subRows;
    var desc = new Uint32Array(n);
    for (var i = 0; i < n; i++) {
      var p = iw === 1 ? r.u8() : r.u16();
      if (p >= palCount) throw new Error('decodeTexLayer: 索引 ' + p + ' 越出调色板 ' + palCount + ' 项');
      desc[i] = pal[p];
    }
    return { kind: 'tex', desc: desc };
  }
```

导出表追加:

```js
    KIND_TEX: KIND_TEX, KIND_COLOR: KIND_COLOR,
    encodeTexLayer: encodeTexLayer, decodeTexLayer: decodeTexLayer,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node smoke.js`
Expected: `SMOKE OK`

- [ ] **Step 5: 提交**

```bash
git add level_editor/core.js level_editor/smoke.js
git commit -F - <<'EOF'
feat(editor): core.js 纹理层块编解码(调色板 + 索引宽度)

索引 0 无条件留给空气,于是空层必然压成"1 项调色板 + 全 0 索引流"。
调色板 ≤256 项用单字节索引,超出自动切双字节。
解码侧对越界索引与非法 index_width 一律抛错,不静默。
EOF
```

---

## Task 5: 背景层块编解码

**Files:**
- Modify: `level_editor/core.js`
- Modify: `level_editor/smoke.js`

**Interfaces:**
- Consumes: `KIND_COLOR` / `ByteReader`
- Produces: `Core.encodeColorLayer(rgba, subCols, subRows) -> Uint8Array`、`Core.decodeColorLayer(reader, subCols, subRows) -> { kind:'color', rgba: Uint32Array }`

- [ ] **Step 1: 追加断言**

```js
// ---- 背景层块编解码 ----
(function () {
  var subCols = 4, subRows = 2, n = subCols * subRows;
  var rgba = new Uint32Array(n);
  for (var i = 0; i < n; i++) rgba[i] = (0x11223344 + i * 0x01010101) >>> 0;
  var enc = Core.encodeColorLayer(rgba, subCols, subRows);
  eq(enc[0], Core.KIND_COLOR, 'encodeColorLayer: 首字节是 kind');
  eq(enc.length, 1 + n * 4, 'encodeColorLayer: 长度 = 1 + n×4');
  var r = new Core.ByteReader(enc);
  var dec = Core.decodeColorLayer(r, subCols, subRows);
  eq(r.remaining(), 0, 'decodeColorLayer: 字节全部消费');
  eq(dec.kind, 'color', 'decodeColorLayer: kind');
  eq(Array.prototype.slice.call(dec.rgba), Array.prototype.slice.call(rgba), '背景层: 往返一致');

  // 全透明黑(0)是合法且最常见的空背景
  var blank = new Uint32Array(4);
  var r2 = new Core.ByteReader(Core.encodeColorLayer(blank, 2, 2));
  eq(Array.prototype.slice.call(Core.decodeColorLayer(r2, 2, 2).rgba), [0, 0, 0, 0], '背景层: 全 0 往返');
  eq(Core.decodeColorLayer(new Core.ByteReader(Core.encodeColorLayer(blank, 2, 2)), 2, 2).rgba instanceof Uint32Array,
     true, '背景层: 回读是 Uint32Array');

  throws(function () { Core.encodeColorLayer(new Uint32Array(3), 2, 2); }, 'encodeColorLayer: 长度不符报错');
  throws(function () {
    Core.decodeColorLayer(new Core.ByteReader(new Uint8Array([Core.KIND_TEX])), 1, 1);
  }, 'decodeColorLayer: 错 kind 报错');
})();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node smoke.js`
Expected: `FAIL - encodeColorLayer: 首字节是 kind`,退出码 1

- [ ] **Step 3: 实现**

在 core.js 的 `decodeTexLayer` 之后插入:

```js
  // 背景层块:kind(2) + 逐格 RGBA8888(规格 §3.4)。
  // 不做调色板 —— 背景是真彩,而平滑渐变恰好是 deflate 最擅长的一类数据。
  function encodeColorLayer(rgba, subCols, subRows) {
    var n = subCols * subRows;
    if (rgba.length !== n) {
      throw new Error('encodeColorLayer: rgba 长度 ' + rgba.length + ' ≠ subCols×subRows ' + n);
    }
    var w = new ByteWriter(5 + n * 4);
    w.u8(KIND_COLOR);
    for (var i = 0; i < n; i++) w.u32(rgba[i]);
    return w.finish();
  }

  function decodeColorLayer(r, subCols, subRows) {
    var kind = r.u8();
    if (kind !== KIND_COLOR) throw new Error('decodeColorLayer: kind=' + kind + ',期望 ' + KIND_COLOR);
    var n = subCols * subRows;
    var rgba = new Uint32Array(n);
    for (var i = 0; i < n; i++) rgba[i] = r.u32();
    return { kind: 'color', rgba: rgba };
  }
```

导出表追加:

```js
    encodeColorLayer: encodeColorLayer, decodeColorLayer: decodeColorLayer,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node smoke.js`
Expected: `SMOKE OK`

- [ ] **Step 5: 提交**

```bash
git add level_editor/core.js level_editor/smoke.js
git commit -F - <<'EOF'
feat(editor): core.js 背景层块编解码

背景层是真彩 RGBA8888,不做调色板 —— 平滑渐变交给 deflate 压。
EOF
```

---

## Task 6: meta 文本编解码(注释 + 出生点 + 敌人)

**Files:**
- Modify: `level_editor/core.js`
- Modify: `level_editor/smoke.js`

**Interfaces:**
- Consumes: 无
- Produces: `Core.buildMeta(map) -> String`、`Core.parseMeta(text) -> { players, enemies, comments }`

- [ ] **Step 1: 追加断言**

```js
// ---- meta 文本 ----
(function () {
  var m = Core.createMap('demo', 4, 4);
  m.comments = ['demo', '这是一张测试图'];
  m.players = [{ x: 3, y: 4 }, { x: 10, y: 4 }];
  m.enemies = [{ type: 'fly_bird', x: 20, y: 12 }];
  var text = Core.buildMeta(m);
  eq(text, '# demo\n# 这是一张测试图\n# player 3 4\n# player2 10 4\n# enemy fly_bird 20 12\n',
     'buildMeta: 注释在前,再 spawn');

  var back = Core.parseMeta(text);
  eq(back.comments, ['demo', '这是一张测试图'], 'parseMeta: 注释回读');
  eq(back.players, [{ x: 3, y: 4 }, { x: 10, y: 4 }], 'parseMeta: 多个出生点回读');
  eq(back.enemies, [{ type: 'fly_bird', x: 20, y: 12 }], 'parseMeta: 敌人回读');

  // 第 3 个及以后的出生点必须原样保留(游戏侧读不到,但编辑器不许丢)
  var m3 = Core.createMap('t', 4, 4);
  m3.players = [{ x: 1, y: 1 }, { x: 2, y: 2 }, { x: 3, y: 3 }];
  eq(Core.parseMeta(Core.buildMeta(m3)).players.length, 3, 'parseMeta: 第 3 个出生点不丢');

  // 空 meta
  eq(Core.buildMeta(Core.createMap('t', 2, 2)), '', 'buildMeta: 什么都沒有时是空串');
  eq(Core.parseMeta(''), { players: [], enemies: [], comments: [] }, 'parseMeta: 空串');

  // 非法 spawn 行降级成注释,不丢信息也不崩
  var bad = Core.parseMeta('# player abc 4\n# enemy\n');
  eq(bad.players, [], 'parseMeta: 非法 player 不当出生点');
  eq(bad.comments, ['player abc 4', 'enemy'], 'parseMeta: 非法 spawn 行降级为注释');

  // 普通注释里出现 player 字样不该被误认(缺坐标)
  eq(Core.parseMeta('# player 是主角\n').comments, ['player 是主角'], 'parseMeta: player 注释不被误认');

  // CRLF 要能吃
  eq(Core.parseMeta('# demo\r\n# player 1 2\r\n').players, [{ x: 1, y: 2 }], 'parseMeta: CRLF');

  // round-trip:buildMeta → parseMeta → buildMeta 稳定
  var t1 = Core.buildMeta(m);
  var m2 = Core.createMap('x', 4, 4);
  var pm = Core.parseMeta(t1);
  m2.comments = pm.comments; m2.players = pm.players; m2.enemies = pm.enemies;
  eq(Core.buildMeta(m2), t1, 'meta: build→parse→build 稳定');
})();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node smoke.js`
Expected: `FAIL - buildMeta: 注释在前,再 spawn`,退出码 1

- [ ] **Step 3: 实现**

在 core.js 的 `decodeColorLayer` 之后插入:

```js
  // ── meta 文本(规格 §3.2)──
  // 形状就是今天那几行 `# ...` 注释:deflate 压得掉,而且游戏侧
  // MapFormat.parse_spawn_metadata() 零改动就能继续用。
  // 本函数输出:先注释,再出生点(player / player2 / player3…),最后敌人。
  function buildMeta(map) {
    var lines = [];
    var i;
    for (i = 0; i < map.comments.length; i++) lines.push('# ' + map.comments[i]);
    for (i = 0; i < map.players.length; i++) {
      var kw = i === 0 ? 'player' : (i === 1 ? 'player2' : 'player' + (i + 1));
      lines.push('# ' + kw + ' ' + map.players[i].x + ' ' + map.players[i].y);
    }
    for (i = 0; i < map.enemies.length; i++) {
      var e = map.enemies[i];
      lines.push('# enemy ' + e.type + ' ' + e.x + ' ' + e.y);
    }
    return lines.length ? lines.join('\n') + '\n' : '';
  }

  // 解析失败(坐标不是整数、坐标个数不够)的行**降级成注释**而不是丢掉 ——
  // 编辑器不许静默吃掉用户写的东西。
  function parseMeta(text) {
    var players = [], enemies = [], comments = [];
    var lines = String(text == null ? '' : text).split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
      var s = lines[i].trim();
      if (s === '') continue;
      if (s.charAt(0) !== '#') { comments.push(s); continue; }
      var body = s.slice(1).trim();
      var parts = body.split(/\s+/);
      var head = parts[0];
      if (/^player\d*$/.test(head) && parts.length >= 3) {
        var px = parseInt(parts[1], 10), py = parseInt(parts[2], 10);
        if (isFinite(px) && isFinite(py)) { players.push({ x: px, y: py }); continue; }
      } else if (head === 'enemy' && parts.length >= 4) {
        var ex = parseInt(parts[2], 10), ey = parseInt(parts[3], 10);
        if (isFinite(ex) && isFinite(ey) && parts[1] !== '') {
          enemies.push({ type: parts[1], x: ex, y: ey });
          continue;
        }
      }
      comments.push(body);
    }
    return { players: players, enemies: enemies, comments: comments };
  }
```

导出表追加:

```js
    buildMeta: buildMeta, parseMeta: parseMeta,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node smoke.js`
Expected: `SMOKE OK`

- [ ] **Step 5: 提交**

```bash
git add level_editor/core.js level_editor/smoke.js
git commit -F - <<'EOF'
feat(editor): core.js meta 文本编解码

meta 就是今天那几行 "# player 3 4" 注释,游戏侧 parse_spawn_metadata 零改动。
解析失败的行降级成注释而不是丢掉 —— 编辑器不许静默吃掉用户写的东西。
第 3 个及以后的出生点原样保留(游戏侧读不到,但编辑器不许丢)。
EOF
```

---

## Task 7: 整文件编解码(头部 + deflate + CRC)

**Files:**
- Modify: `level_editor/core.js`
- Modify: `level_editor/smoke.js`

**Interfaces:**
- Consumes: `buildMeta` / `parseMeta` / 四个层编解码 / `ByteWriter` / `ByteReader` / `crc32`
- Produces:
  - `Core.encodeMap(map, opts) -> Promise<Uint8Array>`,`opts.compress`(默认 `true`)
  - `Core.decodeMap(bytes) -> Promise<map>`
  - `Core.FORMAT_VERSION = 4`、`Core.HEADER_SIZE = 20`
  - `Core.deflateBytes(bytes) -> Promise<Uint8Array>`、`Core.inflateBytes(bytes) -> Promise<Uint8Array>`

- [ ] **Step 1: 追加断言**

```js
// ---- 整文件编解码 ----
await (async function () {
  function mkMap() {
    var m = Core.createMap('demo', 6, 5);
    var brick = Core.neutralDesc(1);
    var moss = Core.packDesc(15, 5, 3, 6, 7);
    var half = Core.packDesc(3, 2, 4, 4, 4);
    for (var i = 0; i < m.layers[0].desc.length; i += 7) m.layers[0].desc[i] = half;      // 前景:稀疏装饰
    for (i = 0; i < m.layers[1].desc.length; i++) {
      m.layers[1].desc[i] = (i % m.subCols < 4) ? brick : 0;                              // 场景:左边一堵墙
    }
    for (i = 0; i < m.layers[2].desc.length; i += 13) m.layers[2].desc[i] = moss;         // 后景:零星
    for (i = 0; i < m.layers[3].rgba.length; i++) {
      m.layers[3].rgba[i] = ((0x102030 | (i & 0xFF)) * 0x010101) >>> 0;                   // 背景:条带
    }
    m.comments = ['demo', '带中文的注释'];
    m.players = [{ x: 3, y: 4 }, { x: 10, y: 4 }];
    m.enemies = [{ type: 'fly_bird', x: 20, y: 12 }];
    return m;
  }

  var src = mkMap();
  var bytes = await Core.encodeMap(src);
  eq(Array.prototype.slice.call(bytes.subarray(0, 4)), [0x43, 0x59, 0x52, 0x4D], 'encodeMap: magic "CYRM"');
  eq(bytes[4], Core.FORMAT_VERSION, 'encodeMap: 版本 4');
  eq(bytes[5], 1, 'encodeMap: 默认压缩');
  eq(bytes.length >= Core.HEADER_SIZE, true, 'encodeMap: 至少有头部');

  var hr = new Core.ByteReader(bytes);
  hr.bytes(6);
  var bodySize = hr.u32(); hr.u32();
  eq(hr.u16(), src.subCols, 'encodeMap: 头部 sub_cols');
  eq(hr.u16(), src.subRows, 'encodeMap: 头部 sub_rows');
  eq(hr.u8(), 0b1111, 'encodeMap: layer_flags 四位全开');
  eq(hr.u8(), 0, 'encodeMap: reserved 为 0');

  var back = await Core.decodeMap(bytes);
  eq(back.subCols, src.subCols, 'decodeMap: subCols');
  eq(back.subRows, src.subRows, 'decodeMap: subRows');
  eq(back.layers.length, 4, 'decodeMap: 四层');
  for (var L = 0; L < 4; L++) {
    var key = L === 3 ? 'rgba' : 'desc';
    eq(Array.prototype.slice.call(back.layers[L][key]), Array.prototype.slice.call(src.layers[L][key]),
       '整文件往返: 图层 ' + L);
  }
  eq(back.players, src.players, '整文件往返: players');
  eq(back.enemies, src.enemies, '整文件往返: enemies');
  eq(back.comments, src.comments, '整文件往返: comments');
  eq(back.layers[3].kind, 'color', '整文件往返: 背景层 kind');
  eq(back.layers[0].kind, 'tex', '整文件往返: 前景层 kind');

  // 不压缩路径
  var raw = await Core.encodeMap(src, { compress: false });
  eq(raw[5], 0, 'encodeMap: compress:false → compression = 0');
  eq(raw.length, Core.HEADER_SIZE + bodySize, 'encodeMap: 不压缩时文件长度 = 20 + body_size');
  var rawBack = await Core.decodeMap(raw);
  eq(Array.prototype.slice.call(rawBack.layers[1].desc), Array.prototype.slice.call(src.layers[1].desc),
     '不压缩路径: 往返一致');
  ok(raw.length > bytes.length, '不压缩确实更大(否则压缩没起作用)');

  // 缺层:置 null 的图层不进文件,解码回 null
  var partial = Core.createMap('p', 4, 4);
  partial.layers[0] = null;
  partial.layers[2] = null;
  var pEnc = await Core.encodeMap(partial, { compress: false });
  var pr = new Core.ByteReader(pEnc); pr.bytes(18);
  eq(pr.u8(), 0b1010, '缺层: layer_flags 只开场景与背景');
  var pBack = await Core.decodeMap(pEnc);
  eq(pBack.layers[0], null, '缺层: 前景回来是 null');
  eq(pBack.layers[2], null, '缺层: 后景回来是 null');
  ok(pBack.layers[1] !== null && pBack.layers[3] !== null, '缺层: 场景与背景仍在');

  // ── 反向断言:损坏的文件必须抛错,不能静默读成一张空图 ──
  var badMagic = bytes.slice(); badMagic[0] = 0x00;
  await rejects(function () { return Core.decodeMap(badMagic); }, 'decodeMap: 坏 magic 抛错');

  var badVer = bytes.slice(); badVer[4] = 99;
  await rejects(function () { return Core.decodeMap(badVer); }, 'decodeMap: 未知版本抛错');

  var badCrc = bytes.slice(); badCrc[badCrc.length - 1] ^= 0xFF;
  await rejects(function () { return Core.decodeMap(badCrc); }, 'decodeMap: CRC 不符抛错');

  var badSize = bytes.slice(); badSize[14] = 0; badSize[15] = 0;     // sub_cols = 0
  await rejects(function () { return Core.decodeMap(badSize); }, 'decodeMap: 尺寸 0 抛错');

  var badAlign = bytes.slice(); badAlign[14] = 6; badAlign[15] = 0;  // sub_cols = 6,非 4 倍数
  await rejects(function () { return Core.decodeMap(badAlign); }, 'decodeMap: 尺寸非 4 倍数抛错');

  await rejects(function () { return Core.decodeMap(new Uint8Array(10)); }, 'decodeMap: 短于头部抛错');

  // 不压缩但 body_size 与真实长度不符
  var badLen = raw.slice();
  badLen[6] = (bodySize + 1) & 0xFF;
  await rejects(function () { return Core.decodeMap(badLen); }, 'decodeMap: body_size 不符抛错');

  var badComp = bytes.slice(); badComp[5] = 7;
  await rejects(function () { return Core.decodeMap(badComp); }, 'decodeMap: 未知 compression 抛错');
})();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node smoke.js`
Expected: `FAIL - encodeMap: magic "CYRM"`,退出码 1

- [ ] **Step 3: 实现**

在 core.js 的 `parseMeta` 之后插入:

```js
  // ── 压缩(规格 §3.5)──
  // 用运行时原生的 CompressionStream('deflate') —— 产出 zlib(RFC1950)格式,
  // 与 Godot 侧 PackedByteArray.decompress(n, COMPRESSION_DEFLATE) 对应。
  // ★ 刻意不自造压缩器:自己写 RLE 就要自己写解压器,而解压器写错是那种
  //   "大部分时候对、偶尔静默出错"的 bug。
  function deflateBytes(bytes) {
    if (typeof CompressionStream === 'undefined' || typeof Blob === 'undefined') {
      return Promise.reject(new Error(
        'deflateBytes: 本环境没有 CompressionStream/Blob;请用 encodeMap(map, {compress:false}) 导出裸 body'));
    }
    var stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate'));
    return new Response(stream).arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
  }
  function inflateBytes(bytes) {
    if (typeof DecompressionStream === 'undefined' || typeof Blob === 'undefined') {
      return Promise.reject(new Error('inflateBytes: 本环境没有 DecompressionStream/Blob'));
    }
    var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'));
    return new Response(stream).arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
  }

  // ── 整文件容器(规格 §3.1 / §3.2)──
  const FORMAT_VERSION = 4;
  const HEADER_SIZE = 20;
  const MAGIC = [0x43, 0x59, 0x52, 0x4D];   // "CYRM"

  function layerFlags(map) {
    var f = 0;
    for (var L = 0; L < LAYER_COUNT; L++) if (map.layers[L]) f |= (1 << L);
    return f;
  }

  function encodeBody(map) {
    var metaBytes = new TextEncoder().encode(buildMeta(map));
    if (metaBytes.length > 65535) throw new Error('encodeBody: meta 超过 65535 字节');
    var w = new ByteWriter(64 + metaBytes.length);
    w.u16(metaBytes.length);
    w.bytes(metaBytes);
    for (var L = 0; L < LAYER_COUNT; L++) {
      var layer = map.layers[L];
      if (!layer) continue;                        // 缺层不写块,由 layer_flags 表达
      w.bytes(layer.kind === 'tex'
        ? encodeTexLayer(layer.desc, map.subCols, map.subRows)
        : encodeColorLayer(layer.rgba, map.subCols, map.subRows));
    }
    return w.finish();
  }

  function decodeBody(body, subCols, subRows, flags) {
    var r = new ByteReader(body);
    var metaLen = r.u16();
    var meta = parseMeta(new TextDecoder().decode(r.bytes(metaLen)));
    var layers = [];
    for (var L = 0; L < LAYER_COUNT; L++) {
      if (!(flags & (1 << L))) { layers.push(null); continue; }
      layers.push(LAYER_KINDS[L] === 'tex'
        ? decodeTexLayer(r, subCols, subRows)
        : decodeColorLayer(r, subCols, subRows));
    }
    if (r.remaining() !== 0) {
      throw new Error('decodeBody: 尾部还有 ' + r.remaining() + ' 字节未消费');
    }
    return {
      name: '', subCols: subCols, subRows: subRows, layers: layers,
      players: meta.players, enemies: meta.enemies, comments: meta.comments,
    };
  }

  // opts.compress 默认 true;传 false 走裸 body(compress=0),用来兜住
  // "两端 deflate 实现对不上"这类风险,是一条完整可用的路径而不是半成品。
  function encodeMap(map, opts) {
    opts = opts || {};
    var body, payload, compression;
    try {
      body = encodeBody(map);
    } catch (e) {
      return Promise.reject(e);
    }
    var compress = opts.compress !== false;
    var pre = compress ? deflateBytes(body) : Promise.resolve(body);
    return pre.then(function (p) {
      payload = p;
      compression = compress ? 1 : 0;
      var w = new ByteWriter(HEADER_SIZE + payload.length);
      w.u8(MAGIC[0]); w.u8(MAGIC[1]); w.u8(MAGIC[2]); w.u8(MAGIC[3]);
      w.u8(FORMAT_VERSION);
      w.u8(compression);
      w.u32(body.length);          // ★ 解压后的大小
      w.u32(crc32(body));
      w.u16(map.subCols);
      w.u16(map.subRows);
      w.u8(layerFlags(map));
      w.u8(0);
      w.bytes(payload);
      return w.finish();
    });
  }

  function decodeMap(bytes) {
    return new Promise(function (resolve) { resolve(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)); })
      .then(function (b) {
        if (b.length < HEADER_SIZE) throw new Error('decodeMap: 文件只有 ' + b.length + ' 字节,小于头部 20 字节');
        var r = new ByteReader(b);
        if (r.u8() !== MAGIC[0] || r.u8() !== MAGIC[1] || r.u8() !== MAGIC[2] || r.u8() !== MAGIC[3]) {
          throw new Error('decodeMap: magic 不是 "CYRM"');
        }
        var version = r.u8();
        if (version !== FORMAT_VERSION) {
          throw new Error('decodeMap: 版本 ' + version + ',本编辑器只认 ' + FORMAT_VERSION);
        }
        var compression = r.u8();
        var bodySize = r.u32();
        var expectCrc = r.u32();
        var subCols = r.u16(), subRows = r.u16();
        var flags = r.u8();
        r.u8();
        if (subCols <= 0 || subRows <= 0) {
          throw new Error('decodeMap: 尺寸非法 ' + subCols + '×' + subRows);
        }
        if (subCols % SUB_PER_CELL !== 0 || subRows % SUB_PER_CELL !== 0) {
          throw new Error('decodeMap: 尺寸 ' + subCols + '×' + subRows + ' 不是 ' + SUB_PER_CELL + ' 的倍数');
        }
        var payload = r.bytes(b.length - HEADER_SIZE);
        var next;
        if (compression === 0) next = Promise.resolve(payload);
        else if (compression === 1) next = inflateBytes(payload);
        else throw new Error('decodeMap: 未知 compression=' + compression);
        return next.then(function (body) {
          if (body.length !== bodySize) {
            throw new Error('decodeMap: 解压后 ' + body.length + ' 字节,头部声明 ' + bodySize);
          }
          var actual = crc32(body);
          if (actual !== expectCrc) {
            throw new Error('decodeMap: CRC 不符(算得 0x' + actual.toString(16) +
                            ',头部 0x' + expectCrc.toString(16) + ')');
          }
          return decodeBody(body, subCols, subRows, flags);
        });
      });
  }
```

导出表追加:

```js
    FORMAT_VERSION: FORMAT_VERSION, HEADER_SIZE: HEADER_SIZE,
    deflateBytes: deflateBytes, inflateBytes: inflateBytes,
    encodeMap: encodeMap, decodeMap: decodeMap, layerFlags: layerFlags,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node smoke.js`
Expected: `SMOKE OK`

- [ ] **Step 5: 提交**

```bash
git add level_editor/core.js level_editor/smoke.js
git commit -F - <<'EOF'
feat(editor): core.js 整文件容器(明文头 + deflate + CRC32)

头部 20 字节明文,body_size 记解压后大小,body 整段 deflate。
压缩用运行时原生 CompressionStream('deflate')(zlib/RFC1950),
对应 Godot 的 COMPRESSION_DEFLATE;compress:false 是完整可用的退路。

反向断言:坏 magic / 未知版本 / CRC 不符 / 尺寸为 0 / 尺寸非 4 倍数 /
body_size 不符 / 短于头部 —— 七种损坏都必须抛错,不能静默读成空图。
EOF
```

---

## Task 8: v3 文本解析(与旧字母格式)

**Files:**
- Modify: `level_editor/core.js`
- Modify: `level_editor/smoke.js`

**Interfaces:**
- Consumes: `parseMeta`
- Produces:
  - `Core.isV3Text(text) -> bool`
  - `Core.parseV3Text(text) -> { cellsW, cellsH, packed: Uint16Array, players, enemies, comments }`

- [ ] **Step 1: 追加断言**

```js
// ---- v3 文本解析 ----
(function () {
  ok(Core.isV3Text('# cyrm-v3\n0000001F0031\n'), 'isV3Text: 有标记为真');
  ok(!Core.isV3Text('# 普通地图\n11\n11\n'), 'isV3Text: 无标记为假');

  // v3:每格 4 字符 = 3 位纹理 + 1 位形状 hex
  var v3 = '# cyrm-v3\n# demo\n# player 12 34\n# enemy jump_bird 100 50\n0000001F0031\n';
  var p = Core.parseV3Text(v3);
  eq(p.cellsW, 3, 'parseV3Text: 宽 3 格');
  eq(p.cellsH, 1, 'parseV3Text: 高 1 格');
  eq(Array.prototype.slice.call(p.packed), [0, 31, 49], 'parseV3Text: packed 0/31(纹理1 全砖)/49(纹理3 左上 1/4)');
  eq(p.players, [{ x: 12, y: 34 }], 'parseV3Text: players');
  eq(p.enemies, [{ type: 'jump_bird', x: 100, y: 50 }], 'parseV3Text: enemies');
  eq(p.comments, ['demo'], 'parseV3Text: 注释保留,标记行不算注释');

  // 旧字母格式:单字符 0-9/A,2×2 收缩成 1 格,spawn 坐标 ÷2
  var old = Core.parseV3Text('# old\n# player 112 95\n11\n11\n');
  eq(old.cellsW, 1, '旧格式: 2×2 → 1 格宽');
  eq(old.cellsH, 1, '旧格式: 2×2 → 1 格高');
  eq(Array.prototype.slice.call(old.packed), [31], '旧格式: 2×2 全实心 → 全砖 31');
  eq(old.players, [{ x: 56, y: 47 }], '旧格式: spawn 坐标 ÷2');

  // 旧格式只认 0-9 与 A —— 游戏侧 _tile_char_to_value 就是这么定的,
  // 编辑器多认 b-k 会让"导得进、跑起来一片变空气"(审计 A11)。
  throws(function () { Core.parseV3Text('# old\n1b\n11\n'); }, '旧格式: 小写 b 报错(游戏侧不认)');
  throws(function () { Core.parseV3Text('# old\n1B\n11\n'); }, '旧格式: 大写 B 报错(游戏侧不认)');

  // 非法输入必须抛错,不能静默截断成空气(审计 A12:parseInt("0A1") === 0)
  throws(function () { Core.parseV3Text('# cyrm-v3\n0A10\n'); }, 'v3: 纹理位含字母报错');
  throws(function () { Core.parseV3Text('# cyrm-v3\n000X\n'); }, 'v3: 非法形状字符报错');
  throws(function () { Core.parseV3Text('# cyrm-v3\n00000000\n0000\n'); }, 'v3: 行宽不一致报错');
  throws(function () { Core.parseV3Text('# cyrm-v3\n000\n'); }, 'v3: 字符数非 4 倍数报错');
  throws(function () { Core.parseV3Text('# cyrm-v3\n# 只有注释\n'); }, 'v3: 没有网格行报错');
  throws(function () { Core.parseV3Text('# old\n'); }, '旧格式: 没有网格行报错');

  // CRLF 与空行
  var crlf = Core.parseV3Text('# cyrm-v3\r\n\r\n0000001F0031\r\n');
  eq(Array.prototype.slice.call(crlf.packed), [0, 31, 49], 'parseV3Text: CRLF 与空行');

  // 小写形状字符仍要能读(v3 写法上允许,游戏侧 shape_char_to_value 也认)
  eq(Array.prototype.slice.call(Core.parseV3Text('# cyrm-v3\n000f\n').packed), [15], 'v3: 小写形状字符 f 可读');
})();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node smoke.js`
Expected: `FAIL - isV3Text: 有标记为真`,退出码 1

- [ ] **Step 3: 实现**

在 core.js 的 `decodeMap` 之后插入:

```js
  // ── v3 / 旧字母格式解析(只读迁移用,规格 §3.6)──
  // ★ 这里的 packed = texture*16 + shape 是 **v3 的编码**,与 v4 的 descriptor 毫无关系。
  //   故一律走 _v3Pack / _v3TexOf / _v3ShapeOf,绝不与 packDesc / texOf 混用。
  const V3_MARKER = '# cyrm-v3';
  const SHAPE_HEX = '0123456789ABCDEF';
  // 旧字母格式只认 0-9 与 A(大小写均可),与游戏侧 MapFormat._tile_char_to_value 一致。
  const LEGACY_CHAR = { '0':0,'1':1,'2':2,'3':3,'4':4,'5':5,'6':6,'7':7,'8':8,'9':9,'A':10 };

  function _v3Pack(texture, shape) {
    if (shape === 0 || texture === 0) return 0;
    return (texture * 16 + shape) & 0xFFFF;
  }
  function _v3TexOf(v)   { return (v / 16) | 0; }
  function _v3ShapeOf(v) { return v % 16; }

  function isV3Text(text) {
    var lines = String(text == null ? '' : text).split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().indexOf(V3_MARKER) === 0) return true;
    }
    return false;
  }

  // 旧 2×2 字母网格 → 1 格 packed(纹理取组内首个非零,形状 = 2×2 掩码)。
  // 逻辑与游戏侧 MapFormat.convert_old_grid 逐字对应。
  function _convertLegacy2x2(rows) {
    var h = rows.length, w = rows[0].length;
    var out = [];
    for (var ny = 0; ny < Math.floor(h / 2); ny++) {
      var row = [];
      for (var nx = 0; nx < Math.floor(w / 2); nx++) {
        var shape = 0, tex = 0;
        for (var sy = 0; sy < 2; sy++) {
          for (var sx = 0; sx < 2; sx++) {
            var ov = rows[ny * 2 + sy][nx * 2 + sx];
            if (ov !== 0) {
              shape |= 1 << (sy * 2 + sx);
              if (tex === 0) tex = ov;
            }
          }
        }
        row.push(_v3Pack(tex, shape));
      }
      out.push(row);
    }
    return out;
  }

  function parseV3Text(text) {
    var lines = String(text == null ? '' : text).split(/\r?\n/);
    var v3 = false;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().indexOf(V3_MARKER) === 0) { v3 = true; break; }
    }
    var rows = [], width = -1;
    var metaText = '';
    for (i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (line === '') continue;
      if (line.charAt(0) === '#') {
        // ★ 版本标记行不算注释。漏了这一句 `# cyrm-v3` 会被当成一条普通注释
        //   塞进 comments,于是"导入→导出"会往用户的 meta 里塞进一行垃圾。
        if (/^#\s*cyrm-v\d+\s*$/.test(line)) continue;
        metaText += line + '\n';
        continue;
      }
      var row = [];
      if (v3) {
        if (line.length % 4 !== 0) {
          throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行长度 ' + line.length + ' 不是 4 的倍数');
        }
        for (var j = 0; j < line.length; j += 4) {
          var tstr = line.substr(j, 3);
          if (!/^[0-9]{3}$/.test(tstr)) {
            throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行纹理位 "' + tstr + '" 不是 3 位数字');
          }
          var ch = line.charAt(j + 3).toUpperCase();
          var sv = SHAPE_HEX.indexOf(ch);
          if (sv < 0) throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行非法形状字符 "' + line.charAt(j + 3) + '"');
          row.push(_v3Pack(parseInt(tstr, 10), sv));
        }
      } else {
        for (j = 0; j < line.length; j++) {
          var lch = line.charAt(j).toUpperCase();
          var lv = LEGACY_CHAR[lch];
          if (lv === undefined) {
            throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行非法字符 "' + line.charAt(j) + '"(旧格式只允许 0-9/A)');
          }
          row.push(lv);
        }
      }
      if (width < 0) width = row.length;
      else if (row.length !== width) {
        throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行宽度 ' + row.length + ' 与首行 ' + width + ' 不一致');
      }
      rows.push(row);
    }
    if (rows.length === 0) throw new Error('parseV3Text: 地图里没有有效网格行');

    var meta = parseMeta(metaText);
    var players = meta.players, enemies = meta.enemies;
    if (!v3) {
      rows = _convertLegacy2x2(rows);
      // 旧格式 2×2 → 1,spawn 坐标同步 ÷2
      players = players.map(function (p) { return { x: Math.floor(p.x / 2), y: Math.floor(p.y / 2) }; });
      enemies = enemies.map(function (e) { return { type: e.type, x: Math.floor(e.x / 2), y: Math.floor(e.y / 2) }; });
    }
    var cellsW = rows[0].length, cellsH = rows.length;
    var packed = new Uint16Array(cellsW * cellsH);
    for (var y = 0; y < cellsH; y++) {
      for (var x = 0; x < cellsW; x++) packed[y * cellsW + x] = rows[y][x];
    }
    return { cellsW: cellsW, cellsH: cellsH, packed: packed,
             players: players, enemies: enemies, comments: meta.comments };
  }
```

导出表追加:

```js
    isV3Text: isV3Text, parseV3Text: parseV3Text,
    _v3Pack: _v3Pack, _v3TexOf: _v3TexOf, _v3ShapeOf: _v3ShapeOf,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node smoke.js`
Expected: `SMOKE OK`

- [ ] **Step 5: 提交**

```bash
git add level_editor/core.js level_editor/smoke.js
git commit -F - <<'EOF'
feat(editor): core.js v3 文本与旧字母格式解析(只读迁移用)

v3 packed(texture*16+shape)与 v4 descriptor 是两种编码,函数名刻意分开
(_v3Pack/_v3TexOf/_v3ShapeOf vs packDesc/texOf),不许混用。

修掉旧编辑器两处静默:
  - parseInt("0A1") === 0 会把坏格读成空气(审计 A12)→ 改逐字符校验
  - 旧格式认 b-k 而游戏只认 0-9/A,导得进跑起来变空气(审计 A11)→ 收紧
EOF
```

---

## Task 9: 取角映射 + v3 → v4 迁移(含逐像素等价断言)

**Files:**
- Modify: `level_editor/core.js`
- Modify: `level_editor/smoke.js`

**Interfaces:**
- Consumes: `createMap` / `neutralDesc` / `parseV3Text` / `_v3TexOf` / `_v3ShapeOf` / `_v3Pack`
- Produces:
  - `Core.subcellRender(X, Y) -> { dst:[x,y,w,h], src:[x,y,w,h] }`
  - `Core.migrateV3(parsed) -> map`

- [ ] **Step 1: 追加断言**

```js
// ---- 取角映射(§2.2 的规范定义,游戏侧 shader 必须与此一致)----
(function () {
  eq(Core.subcellRender(0, 0), { dst: [0, 0, 16, 16], src: [0, 0, 8, 8] }, 'subcellRender: 格内 (0,0)');
  eq(Core.subcellRender(3, 0), { dst: [48, 0, 16, 16], src: [24, 0, 8, 8] }, 'subcellRender: 格内 (3,0)');
  eq(Core.subcellRender(0, 3), { dst: [0, 48, 16, 16], src: [0, 24, 8, 8] }, 'subcellRender: 格内 (0,3)');
  eq(Core.subcellRender(4, 4), { dst: [64, 64, 16, 16], src: [0, 0, 8, 8] }, 'subcellRender: 象限按 X%4 循环');
  eq(Core.subcellRender(7, 5), { dst: [112, 80, 16, 16], src: [24, 8, 8, 8] }, 'subcellRender: 第二格右下');

  // ★ 迁移正确性的全部依据:v3 的一个 32px 象限 ↔ v4 的 2×2 个 16px 子格,
  //   目标矩形与源矩形都必须**精确铺满**(尺寸相等 + 包围盒相等 ⇒ 不重不漏)。
  function v3QuadrantRender(cellX, cellY, qx, qy) {
    return { dst: [cellX * 64 + qx * 32, cellY * 64 + qy * 32, 32, 32],
             src: [qx * 16, qy * 16, 16, 16] };
  }
  function quadrantEquivalent(cellX, cellY, qx, qy) {
    var o = v3QuadrantRender(cellX, cellY, qx, qy);
    var dMinX = Infinity, dMinY = Infinity, dMaxX = -Infinity, dMaxY = -Infinity, dArea = 0;
    var sMinX = Infinity, sMinY = Infinity, sMaxX = -Infinity, sMaxY = -Infinity;
    for (var dy = 0; dy < 2; dy++) {
      for (var dx = 0; dx < 2; dx++) {
        var s = Core.subcellRender(cellX * 4 + qx * 2 + dx, cellY * 4 + qy * 2 + dy);
        dArea += s.dst[2] * s.dst[3];
        dMinX = Math.min(dMinX, s.dst[0]); dMinY = Math.min(dMinY, s.dst[1]);
        dMaxX = Math.max(dMaxX, s.dst[0] + s.dst[2]); dMaxY = Math.max(dMaxY, s.dst[1] + s.dst[3]);
        sMinX = Math.min(sMinX, s.src[0]); sMinY = Math.min(sMinY, s.src[1]);
        sMaxX = Math.max(sMaxX, s.src[0] + s.src[2]); sMaxY = Math.max(sMaxY, s.src[1] + s.src[3]);
      }
    }
    return dArea === o.dst[2] * o.dst[3] &&
           dMinX === o.dst[0] && dMinY === o.dst[1] &&
           dMaxX === o.dst[0] + o.dst[2] && dMaxY === o.dst[1] + o.dst[3] &&
           sMinX === o.src[0] && sMinY === o.src[1] &&
           sMaxX === o.src[0] + o.src[2] && sMaxY === o.src[1] + o.src[3];
  }
  var eqAll = true;
  for (var cx = 0; cx < 3; cx++) for (var cy = 0; cy < 3; cy++)
    for (var qx = 0; qx < 2; qx++) for (var qy = 0; qy < 2; qy++)
      if (!quadrantEquivalent(cx, cy, qx, qy)) eqAll = false;
  ok(eqAll, '★ 取角等价:v3 的每个象限都能被 v4 的 2×2 子格精确铺满(3×3 格 × 4 象限全查)');
})();

// ---- v3 → v4 迁移 ----
(function () {
  var v3 = '# cyrm-v3\n# demo\n# player 1 1\n0000001F0031\n000000000000\n';
  var p = Core.parseV3Text(v3);
  var m = Core.migrateV3(p);

  eq(m.subCols, p.cellsW * 4, 'migrateV3: subCols = 格数×4');
  eq(m.subRows, p.cellsH * 4, 'migrateV3: subRows = 格数×4');
  eq(m.comments, ['demo'], 'migrateV3: 注释带过来');
  eq(m.players, [{ x: 1, y: 1 }], 'migrateV3: 出生点带过来(坐标不缩放)');
  eq(m.layers[Core.LAYER_FRONT].desc.some(function (v) { return v !== 0; }), false, 'migrateV3: 前景层留空');
  eq(m.layers[Core.LAYER_BACK].desc.some(function (v) { return v !== 0; }), false, 'migrateV3: 后景层留空');
  eq(m.layers[Core.LAYER_BG].rgba.some(function (v) { return v !== 0; }), false, 'migrateV3: 背景层留空(全透明黑)');

  var scene = m.layers[Core.LAYER_SCENE].desc;
  var brick = Core.neutralDesc(1);
  // 格 (1,0) 的 packed = 31 = 纹理1 全砖 → 该格 16 个子格全是 brick
  for (var dy = 0; dy < 4; dy++) {
    for (var dx = 0; dx < 4; dx++) {
      eq(scene[(0 * 4 + dy) * m.subCols + (1 * 4 + dx)], brick,
         'migrateV3: 全砖格 (1,0) 的子格 (' + dx + ',' + dy + ') 填满纹理1 中性');
    }
  }
  // 格 (2,0) 的 packed = 49 = 纹理3 shape 1(仅左上 1/4)→ 只有子格 (0,0),(1,0),(0,1),(1,1) 被填
  var g3 = 3;
  var t3 = Core.neutralDesc(g3);
  eq(scene[(0 * 4 + 0) * m.subCols + (2 * 4 + 0)], t3, 'migrateV3: 1/4 砖格 → 子格(0,0) 有纹理3');
  eq(scene[(0 * 4 + 0) * m.subCols + (2 * 4 + 1)], t3, 'migrateV3: 1/4 砖格 → 子格(1,0) 有纹理3');
  eq(scene[(0 * 4 + 1) * m.subCols + (2 * 4 + 0)], t3, 'migrateV3: 1/4 砖格 → 子格(0,1) 有纹理3');
  eq(scene[(0 * 4 + 1) * m.subCols + (2 * 4 + 1)], t3, 'migrateV3: 1/4 砖格 → 子格(1,1) 有纹理3');
  eq(scene[(0 * 4 + 0) * m.subCols + (2 * 4 + 2)], 0, 'migrateV3: 1/4 砖格 → 子格(2,0) 是空气');
  eq(scene[(0 * 4 + 2) * m.subCols + (2 * 4 + 0)], 0, 'migrateV3: 1/4 砖格 → 子格(0,2) 是空气');
  eq(scene[(0 * 4 + 3) * m.subCols + (2 * 4 + 3)], 0, 'migrateV3: 1/4 砖格 → 子格(3,3) 是空气');

  // 全空行不留任何东西
  var occupied = 0;
  for (var i = 0; i < scene.length; i++) if (scene[i] !== 0) occupied++;
  eq(occupied, 16 + 4, 'migrateV3: 非空子格总数 = 一整格(16) + 1/4 格(4)');

  // 旧字母格式也能一路迁到底
  var oldMap = Core.migrateV3(Core.parseV3Text('# old\n11\n11\n'));
  eq(oldMap.layers[Core.LAYER_SCENE].desc.length, 16, 'migrateV3: 旧格式迁移后尺寸');
  eq(oldMap.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(1), 'migrateV3: 旧格式全砖格');

  // 迁移出来的图必须能原样过整文件往返
  var bytes = await Core.encodeMap(m);
  var back = await Core.decodeMap(bytes);
  eq(Array.prototype.slice.call(back.layers[Core.LAYER_SCENE].desc),
     Array.prototype.slice.call(m.layers[Core.LAYER_SCENE].desc), 'migrateV3: 迁移结果可二进制往返');
  eq(back.comments, ['demo'], 'migrateV3: 往返后注释仍是 demo(标记行没被当成注释)');
})();
```

> 断言块的写法:凡是含 `await` 的断言块一律写成 `await (async function () { ... })();`(Task 7 与 Task 9 都是),与 `main` 的 async 配套。不要写成"返回 Promise 但不 await"——那会让断言在 `process.exit` 之后才跑,表现为**静默通过**。

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node smoke.js`
Expected: `FAIL - subcellRender: 格内 (0,0)`,退出码 1

- [ ] **Step 3: 实现**

在 core.js 的 `parseV3Text` 之后插入:

```js
  // ── 取角映射(规格 §2.2,规范定义)──
  // 子格全局坐标 (X,Y) → 目标矩形(世界像素)+ 源矩形(贴图块内偏移)。
  // 调用方按 (texture-1) 定位贴图块,再加这里的 src 偏移。
  //   dst: [x, y, w, h] 世界像素,恒为 16×16
  //   src: [x, y, w, h] 贴图块内偏移,恒为 8×8
  // ★ 象限由子格在 64px 格内的位置决定(X % 4 / Y % 4),不是存在数据里的字段 ——
  //   每个子格要能独立推出自己该画哪一块。
  function subcellRender(X, Y) {
    var qx = X % SUB_PER_CELL, qy = Y % SUB_PER_CELL;
    return { dst: [X * SUB_PX, Y * SUB_PX, SUB_PX, SUB_PX],
             src: [qx * (32 / SUB_PER_CELL), qy * (32 / SUB_PER_CELL),
                   32 / SUB_PER_CELL, 32 / SUB_PER_CELL] };
  }

  // ── v3 → v4 迁移(规格 §3.6)──
  // 旧掩码 bit (qy*2+qx) 为 1 → 新网格的 4 个子格 X∈[2qx,2qx+1], Y∈[2qy,2qy+1] 填同一纹理。
  // 配合 subcellRender 的取角映射,这保证迁移后**视觉逐像素不变**:
  // 旧的那块 32px 区域由 4 个 16px 子格拼回,每个取到的正是原来那 8px 象限放大 2×。
  // 前/后/背景三层留空 —— v3 里没有它们。
  function migrateV3(parsed) {
    var map = createMap('', parsed.cellsW, parsed.cellsH);
    var scene = map.layers[LAYER_SCENE].desc;
    var subCols = map.subCols;
    for (var cy = 0; cy < parsed.cellsH; cy++) {
      for (var cx = 0; cx < parsed.cellsW; cx++) {
        var v = parsed.packed[cy * parsed.cellsW + cx];
        if (v === 0) continue;
        var tex = _v3TexOf(v), shape = _v3ShapeOf(v);
        if (tex === 0 || shape === 0) continue;
        var d = neutralDesc(tex);
        for (var qy = 0; qy < 2; qy++) {
          for (var qx = 0; qx < 2; qx++) {
            if (!(shape & (1 << (qy * 2 + qx)))) continue;
            for (var dy = 0; dy < 2; dy++) {
              for (var dx = 0; dx < 2; dx++) {
                var X = cx * SUB_PER_CELL + qx * 2 + dx;
                var Y = cy * SUB_PER_CELL + qy * 2 + dy;
                scene[Y * subCols + X] = d;
              }
            }
          }
        }
      }
    }
    map.players = parsed.players.map(function (p) { return { x: p.x, y: p.y }; });
    map.enemies = parsed.enemies.map(function (e) { return { type: e.type, x: e.x, y: e.y }; });
    map.comments = parsed.comments.slice();
    return map;
  }
```

导出表追加:

```js
    subcellRender: subcellRender, migrateV3: migrateV3,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node smoke.js`
Expected: `SMOKE OK`

- [ ] **Step 5: 提交**

```bash
git add level_editor/core.js level_editor/smoke.js
git commit -F - <<'EOF'
feat(editor): core.js 取角映射与 v3→v4 迁移

subcellRender 是 §2.2 的规范定义(游戏侧 shader 必须与此一致),
smoke 里有"精确铺满"断言把它钉住:v3 的每个 32px 象限,
v4 的 2×2 个 16px 子格必须不重不漏地覆盖,源矩形也要一致 ——
这是"旧图迁移后视觉逐像素不变"的全部依据,3×3 格 × 4 象限全查。
EOF
```

---

## Task 10: 校验与端到端冒烟(含大图性能守卫)

**Files:**
- Modify: `level_editor/core.js`
- Modify: `level_editor/smoke.js`

**Interfaces:**
- Consumes: 前面全部
- Produces:
  - `Core.validateMap(map) -> { errors: [String], warnings: [String] }`
  - `Core.MAX_CELLS_W = 400`、`Core.MAX_CELLS_H = 300`、`Core.clampMapSize(w, h) -> {w, h}`

- [ ] **Step 1: 追加断言**

```js
// ---- 尺寸钳制(审计 A8:旧 clampMin 的第三参是"默认值"而不是上限,输 99999 直接卡死)----
eq(Core.MAX_CELLS_W, 400, 'MAX_CELLS_W');
eq(Core.MAX_CELLS_H, 300, 'MAX_CELLS_H');
eq(Core.clampMapSize(125, 75), { w: 125, h: 75 }, 'clampMapSize: 正常值原样');
eq(Core.clampMapSize(99999, 99999), { w: 400, h: 300 }, 'clampMapSize: 超上限被钳');
eq(Core.clampMapSize(0, -5), { w: 1, h: 1 }, 'clampMapSize: 下限 1');
eq(Core.clampMapSize(NaN, 'x'), { w: 125, h: 75 }, 'clampMapSize: 非数字回落默认');

// ---- validateMap ----
(function () {
  var good = Core.createMap('ok', 8, 8);
  good.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(1);
  good.players = [{ x: 1, y: 1 }];
  var v = Core.validateMap(good);
  eq(v.errors, [], 'validateMap: 正常图无 error');

  // 出生点落在实心格里
  var inWall = Core.createMap('bad', 8, 8);
  var sc = inWall.layers[Core.LAYER_SCENE].desc;
  for (var i = 0; i < 16; i++) sc[i] = Core.neutralDesc(1);   // 格 (0,0) 填实
  inWall.players = [{ x: 0, y: 0 }];
  ok(Core.validateMap(inWall).warnings.some(function (s) { return s.indexOf('出生点') >= 0; }),
     'validateMap: 出生点在实心格里给 warning');

  // 一个出生点都没有
  var noSpawn = Core.createMap('n', 8, 8);
  ok(Core.validateMap(noSpawn).warnings.some(function (s) { return s.indexOf('出生点') >= 0; }),
     'validateMap: 没有出生点给 warning');

  // 第 3 个及以后的出生点游戏读不到(审计 A3)
  var three = Core.createMap('t', 8, 8);
  three.players = [{ x: 1, y: 1 }, { x: 2, y: 2 }, { x: 3, y: 3 }];
  ok(Core.validateMap(three).warnings.some(function (s) { return s.indexOf('第 3 个') >= 0; }),
     'validateMap: >2 个出生点给 warning');

  // 敌人坐标越界(改尺寸后的残留,审计 A10)
  var oob = Core.createMap('o', 8, 8);
  oob.players = [{ x: 1, y: 1 }];
  oob.enemies = [{ type: 'fly_bird', x: 99, y: 0 }];
  ok(Core.validateMap(oob).warnings.some(function (s) { return s.indexOf('越界') >= 0; }),
     'validateMap: 敌人坐标越界给 warning');

  // 四层全空
  var blank = Core.createMap('b', 8, 8);
  blank.players = [{ x: 1, y: 1 }];
  ok(Core.validateMap(blank).warnings.some(function (s) { return s.indexOf('空') >= 0; }),
     'validateMap: 四层全空给 warning');

  // error 只给真正非法的东西:尺寸非 4 倍数
  var badSize = Core.createMap('s', 8, 8);
  badSize.subCols = 30;
  ok(Core.validateMap(badSize).errors.length > 0, 'validateMap: 尺寸非 4 倍数给 error');
})();

// ---- 大图端到端 + 性能守卫 ----
await (async function () {
  var t0 = Date.now();
  var big = Core.createMap('big', 400, 300);          // 上限尺寸:1600×1200 子格 = 192 万
  var tCreate = Date.now() - t0;
  ok(tCreate < 2000, '大图: createMap(400×300) 耗时 ' + tCreate + 'ms < 2000ms');

  // 铺一层可压缩的内容(条带),再叠一点稀疏噪声防止退化成全部相同
  var sc = big.layers[Core.LAYER_SCENE].desc;
  var d1 = Core.neutralDesc(1), d2 = Core.neutralDesc(2);
  for (var i = 0; i < sc.length; i++) sc[i] = ((i / big.subCols) | 0) % 7 === 0 ? d1 : d2;
  for (i = 0; i < sc.length; i += 997) sc[i] = Core.neutralDesc(15);
  for (i = 0; i < big.layers[Core.LAYER_BG].rgba.length; i++) {
    big.layers[Core.LAYER_BG].rgba[i] = ((i % 256) * 0x010101) >>> 0;
  }

  t0 = Date.now();
  var bytes = await Core.encodeMap(big);
  var tEnc = Date.now() - t0;
  ok(tEnc < 8000, '大图: encodeMap 耗时 ' + tEnc + 'ms < 8000ms(压缩后 ' + bytes.length + ' 字节)');

  t0 = Date.now();
  var back = await Core.decodeMap(bytes);
  var tDec = Date.now() - t0;
  ok(tDec < 8000, '大图: decodeMap 耗时 ' + tDec + 'ms < 8000ms');

  eq(back.subCols, big.subCols, '大图: subCols 往返');
  eq(Array.prototype.slice.call(back.layers[Core.LAYER_SCENE].desc, 0, 64),
     Array.prototype.slice.call(sc, 0, 64), '大图: 场景层前 64 格往返一致');
  eq(back.layers[Core.LAYER_SCENE].desc.length, sc.length, '大图: 场景层长度');

  // 高度重复的内容必须被压掉一大截。
  // 单是场景层的裸索引流就有 sc.length 字节,压完若还比它大,说明压缩没起作用。
  ok(bytes.length < sc.length,
     '大图: 压缩后 ' + bytes.length + ' 字节 < 场景层裸索引流 ' + sc.length + ' 字节');
})();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node smoke.js`
Expected: `FAIL - MAX_CELLS_W`,退出码 1

- [ ] **Step 3: 实现**

在 core.js 的 `migrateV3` 之后插入:

```js
  // ── 尺寸上限(规格 §4.3 闸 1)──
  // 旧编辑器的 clampMin(v, min, def) 第三参是"非数字时的默认值"而不是上限,
  // 输 99999 就会去分配一张巨图然后卡死浏览器。这里给硬上限。
  const MAX_CELLS_W = 400;
  const MAX_CELLS_H = 300;
  const DEFAULT_CELLS_W = 125, DEFAULT_CELLS_H = 75;

  function clampMapSize(w, h) {
    var wi = parseInt(w, 10), hi = parseInt(h, 10);
    if (!isFinite(wi)) wi = DEFAULT_CELLS_W;
    if (!isFinite(hi)) hi = DEFAULT_CELLS_H;
    return {
      w: Math.max(1, Math.min(MAX_CELLS_W, wi)),
      h: Math.max(1, Math.min(MAX_CELLS_H, hi)),
    };
  }

  // ── 导出前校验(规格 §4.7)──
  // 只报告,不阻止导出 —— 编辑器不该替用户做决定。
  // errors   = 真正非法,导出会产出坏文件
  // warnings = 能导出,但游戏里大概不按你预期跑
  function validateMap(map) {
    var errors = [], warnings = [];
    if (!map || !map.layers || map.layers.length !== LAYER_COUNT) {
      errors.push('图层数不是 ' + LAYER_COUNT);
      return { errors: errors, warnings: warnings };
    }
    if (map.subCols % SUB_PER_CELL !== 0 || map.subRows % SUB_PER_CELL !== 0) {
      errors.push('尺寸 ' + map.subCols + '×' + map.subRows + ' 不是 ' + SUB_PER_CELL + ' 的倍数');
    }
    var n = map.subCols * map.subRows;
    var L, layer;
    for (L = 0; L < LAYER_COUNT; L++) {
      layer = map.layers[L];
      if (!layer) continue;
      var arr = layer.kind === 'tex' ? layer.desc : layer.rgba;
      if (!arr || arr.length !== n) {
        errors.push(LAYER_NAMES[L] + '层长度不是 ' + map.subCols + '×' + map.subRows);
      }
    }
    if (errors.length) return { errors: errors, warnings: warnings };

    var cellsW = map.subCols / SUB_PER_CELL, cellsH = map.subRows / SUB_PER_CELL;
    var scene = map.layers[LAYER_SCENE] ? map.layers[LAYER_SCENE].desc : null;

    // 出生点
    if (map.players.length === 0) {
      warnings.push('一个出生点都没有');
    }
    if (map.players.length > 2) {
      warnings.push('有 ' + map.players.length + ' 个出生点,但游戏只认前两个' +
                    '(第 3 个及以后在 map_format.gd 里读不到)');
    }
    var i;
    for (i = 0; i < map.players.length; i++) {
      warnings = warnings.concat(_checkSpawn(map.players[i], '出生点 P' + (i + 1),
                                            cellsW, cellsH, scene));
    }
    for (i = 0; i < map.enemies.length; i++) {
      warnings = warnings.concat(_checkSpawn(map.enemies[i], '敌人 ' + map.enemies[i].type,
                                            cellsW, cellsH, scene));
    }

    // 四层全空
    var allEmpty = true;
    for (L = 0; L < LAYER_COUNT && allEmpty; L++) {
      layer = map.layers[L];
      if (!layer) continue;
      var a = layer.kind === 'tex' ? layer.desc : layer.rgba;
      for (var k = 0; k < a.length; k++) if (a[k] !== 0) { allEmpty = false; break; }
    }
    if (allEmpty) warnings.push('四个图层全是空的');

    return { errors: errors, warnings: warnings };
  }

  // 越界 / 落在实心格。返回 warning 文案数组(可能为空)。
  function _checkSpawn(pt, label, cellsW, cellsH, sceneDesc) {
    var out = [];
    if (pt.x < 0 || pt.y < 0 || pt.x >= cellsW || pt.y >= cellsH) {
      out.push(label + ' 坐标 (' + pt.x + ',' + pt.y + ') 越界(地图是 ' + cellsW + '×' + cellsH + ' 格)');
      return out;
    }
    if (!sceneDesc) return out;
    // 「场景」层该格 4×4 子格全非空才算实心
    var subCols = cellsW * SUB_PER_CELL;
    var solid = true;
    for (var dy = 0; dy < SUB_PER_CELL && solid; dy++) {
      for (var dx = 0; dx < SUB_PER_CELL; dx++) {
        if (sceneDesc[(pt.y * SUB_PER_CELL + dy) * subCols + (pt.x * SUB_PER_CELL + dx)] === 0) {
          solid = false; break;
        }
      }
    }
    if (solid) out.push(label + ' 落在实心格里(场景层该格被填满)');
    return out;
  }
```

导出表追加:

```js
    MAX_CELLS_W: MAX_CELLS_W, MAX_CELLS_H: MAX_CELLS_H,
    clampMapSize: clampMapSize, validateMap: validateMap,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node smoke.js`
Expected: `SMOKE OK`,且大图三条耗时断言都打印实际毫秒数

- [ ] **Step 5: 提交**

```bash
git add level_editor/core.js level_editor/smoke.js
git commit -F - <<'EOF'
feat(editor): core.js 尺寸硬上限、导出前校验与大图端到端冒烟

clampMapSize 给硬上限 400×300 格 —— 旧 clampMin 的第三参是"默认值"
而不是上限,输 99999 会去分配巨图然后卡死浏览器(审计 A8)。

validateMap 只报告不阻止:出生点为空 / >2 个 / 落在实心格里 /
坐标越界 / 四层全空都出 warning,尺寸与数组长度问题才出 error。

大图断言用上限尺寸(1600×1200 子格 = 192 万)跑完整
encode→decode 往返,并给三条耗时上限,兼作性能回归守卫。
EOF
```

---

## 收尾

- [ ] **跑一遍完整冒烟确认全部通过**

Run: `cd level_editor && node smoke.js`
Expected: 末行 `SMOKE OK`,退出码 0

- [ ] **确认旧编辑器不受影响**

`structure-editor.html` 在本计划中**未被改动**,仍能照常打开使用(它自带一份旧的 `Core`)。计划 2 才会替换它。

- [ ] **交接给计划 2**

本计划交付后,以下符号已经定型,计划 2 直接引用:

```
Core.createMap / cellsWOf / cellsHOf / subIndex
Core.LAYER_FRONT / LAYER_SCENE / LAYER_BACK / LAYER_BG / LAYER_NAMES / LAYER_KINDS
Core.packDesc / texOf / hueOf / brightOf / satOf / alphaOf / isAir / neutralDesc
Core.subcellRender
Core.encodeMap / decodeMap  (async)
Core.parseV3Text / isV3Text / migrateV3
Core.validateMap / clampMapSize
Core.sanitizeName / brushOffsets / lineCells / normRegion
Core.ByteWriter / ByteReader / crc32
```
