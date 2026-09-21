# `.cyrm` v4 编辑器(计划 2b):渲染架构 + 工具集 + UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把计划 2a 的骨架页换成真正的编辑器 —— `render.js`(四层缓存 + 脏区 + 闸 2 分帧)、`ui.js`(工具集 + 撤销 + 面板 + 持久化 + 热键)、`io.js` / `worker.js`(闸 3:编解码进 Web Worker)、`editor.html`(真页面 + 敌人注册表迁入),并退休 `structure-editor.html`。

**Architecture:** 四个新模块**全部是经典脚本**(`globalThis.X`,不用 ES module),而且**顶层一行都不碰 DOM** —— DOM 只出现在 `mount()` / `boot()` 一族里。于是 node 能把"错了也不报错、只在屏幕上看出来"的那几层(`③ 格位图缓存的失效`、空层、空气短路、环面命中、画笔几何、单帧预算、撤销差量)逐条断言;真正只能人眼看的只剩"画布上画对了没有"。渲染按规格 §4.2 分两条路:`<8 px/子格`走缩略图(①),`≥8` 走视口离屏层(②,绝不建全图离屏)+ 格位图缓存(③)+ tinted-tile(④),编辑只重画脏格、切层只重新合成、平移靠 canvas 自拷贝 + 补边条。

**Tech Stack:** 纯 JavaScript(经典脚本给浏览器、CommonJS 给 node 冒烟)、node v24(内置 `http`/`fs`/`zlib`,无 npm 依赖)、Canvas 2D + `Worker` + `CompressionStream` + IndexedDB + localStorage、node 侧用**打桩的 `self` / `importScripts`** 把真的 `worker.js` 加载进来跑真消息协议。

## Global Constraints

- **规格是唯一事实来源**:`docs/superpowers/specs/2026-09-19-cyrm-v4-editor-design.md`。任何与本计划冲突之处,以规格为准,并在提交信息里说明。
- **编辑器只通过 HTTP 打开**(规格 §1.2、§4.9):`file://` 支持被刻意放弃。**页面上不许出现 `file://`**,也不许出现任何外部 URL 的 `<script src>`。
- **服务器、`core.js`、`tint.js`、`smoke.js` 是冻结的**:本计划**不修改**这四个文件一个字节。`editor_server.js` 的 API(`/api/maps`、`GET /api/map?p=`、`PUT /api/map?p=`,**PUT 只收 `Content-Type: application/json`**)按现状消费,不改。
- **`node smoke.js` 必须保持 343 通过 / 0 失败 / `SMOKE OK`;`tint_smoke.js` 必须保持 96 通过。**`server_smoke.js` **只许增不许减**,唯一例外是**相位 ①b 与 ⑧**:它们描述的是"2a 不碰旧页"与"骨架页长什么样",而 2b 正是在改这两件事 —— 两条相位被**改写**成新真值(不是删掉),逐条理由与做法写在 Task 3 里;其中纪律类断言(不许第二份 HSV / `lineCells` 必须 floor / PUT 必须带 Content-Type)搬进 `editor_smoke.js` 并**加严**(扫源码而不是扫页面文本)。
- **无 npm 依赖、无构建步骤、不用 ES module**:一切新代码是经典脚本(`globalThis.*`),`<script src>` 顺序即依赖顺序。
- **一切有硬上限**(规格 §4.3 闸 1):地图 400×300 格、库条目 60、撤销 200 步(差量)、tint 缓存 8192 张、缩略图 2px/子格(超大图降到 1)、离屏画布 ≤ 视口。用户输入一律**钳制**,**不报错回滚**。
- **闸 2**:任何跨"一屏"的长循环都有单帧预算(~8ms),超了就 `await` 一帧继续 —— 全屏重建 / 缩略图更新 / 油漆桶 / IndexedDB 序列化。
- **闸 3**:二进制编解码走 Web Worker,**没有主线程降级路径**(静默降级 = 悄悄取消"一帧都不阻塞")。
- **闸 4**:`window.onerror` / `window.onunhandledrejection` → 立刻把当前图写进 IndexedDB 的独立 crash 槽位;下次打开时 crash 槽位比主槽位新就提示恢复。
- **注释一律中文、UI 文案一律中文**,与仓库其余部分一致。
- **本计划的任何测试都不许写进真实 `maps/` 目录**:需要写盘时一律 `fs.mkdtempSync`。
- **不许在页面/`ui.js` 里写第二份数学**:像素走 `Tint.*`,编解码/迁移/校验走 `Core.*`,几何走 `Render.*`。
- **`Core.lineCells` 的每个调用点都必须先 `Math.floor`**(计划 1 账本 Task 2 Minor 3:非整数或 NaN 坐标会让它的 `for(;;)` 死循环,**挂住标签页**)。

---

## 预检裁决(评审遇到引这两条,不要重复上报)

计划 1 / 2a 已与用户确认的裁决,2b 继续沿用:

- **裁决 ①(YAGNI)**:`core.js` 里带着 `sanitizeName` / `brushOffsets` / `lineCells` / `normRegion` 四个格式层不调用的纯函数 —— 它们就是给本计划用的。**同理**:`Render.createCellCache`(③)在 Task 2 落地时**还没有生产调用方**(接线在 Task 4),这是刻意的:规格 §4.2 明列 ③ 是一层,而"它的作废"正是账本点名必须带进 2b 的那条不变量 —— 断言必须落在它能被断言的地方。**不要把这两处报成 YAGNI**。
- **裁决 ②(覆盖)**:`structure-editor.html` 的行为在被本计划删掉之前**没有任何自动覆盖** —— 这是用户知悉并接受的代价(计划 1 的账本预检里已当面更正并重新确认)。本计划**不为旧编辑器补测试**,只在退休那一步钉住"三件事同一 commit"。

---

## 本计划的决定(规格留给实现者拍板的部分)

**① 新模块的顶层不碰 DOM,是"能被 node 断言"的唯一手段。**

`render.js` / `ui.js` / `io.js` 全部写成 `globalThis.X = (function () { … })()`,DOM 只在 `mount()` / `boot()` 一族里取。这不是风格洁癖:账本点名必须带进 2b 的那条不变量(**换图必须同时作废 ③ 与 ④ 两层缓存,且 ③ 的作废要有断言**)如果 ③ 只住在"挂到 canvas 上的那一半",就**无法被任何断言触及** —— 而它复发的症状是"整张图是色块,而且有时好有时坏,不报错"(审计 A2)。

**② 图层 ③(格位图缓存)里缓存的是"16 个 tile 引用",不是"一张 64×64 的 canvas"。**

规格 §4.2 ③ 的原话是「每个 64px 格的 16 个子格**合成结果**」。做法有两种:

- (a) 每格合成成一张 64×64 canvas:一屏(1200×800 @8px/子格 ≈ 37×25 格)≈ 925 格 × 16KB ≈ **15MB**,而"缓存比工作集还小"等于没缓存;
- (b) 每格缓存 **16 个 tile 对象引用**(像素仍然只存在 ④ 里,由它自己的 8192 张上限管):一屏 925 格 × 16 × 8 字节 ≈ **118KB**。

取 (b):内存安全、条目上限能开得比一屏大(8192 格),而且**把 A2 的复发路径变得可断言** —— ③ 交出的东西**就是** ④ 的 tile,所以 ③ 一旦不随 `setSource` 作废,它交出的就是**上一张图集算出来的 tile**,"地图是色块"一模一样地复发。

**③ 选区的内部单位 = **子格**(`{x, y, w, h}` 子格坐标)。** 状态栏按格显示(÷4),吸附到 16px 子格边界。理由:C15 要求"子格级命中",而选区若按格存,0.25 画笔与子格级镜像都无处安放。

**④ 跨图层粘贴只允许"纹理层 ↔ 纹理层"。** 描述符(纹理 + 辅码)与背景的 RGBA 是两种数据类型,`tex → bg` 需要一次"颜色 → 描述符"的猜测(反过来也一样),猜出来的东西没有正确解。故:`Ctrl+V` 粘到不兼容的层时**在状态栏明说**("剪贴板是纹理层内容,不能粘到背景层"),不静默、也不乱猜。

**⑤ 打开"源文件是 v3 文本"的地图时,首次保存要一次显式确认。**

§4.6 说 `Ctrl+S` 写回原文件;§3.6 说迁移是**一次性且不可逆**的,而仓库里 `maps/*.cyrm` **今天全是 v3 文本**。于是"打开 demo.cyrm → Ctrl+S"会当场把 v3 原文转成 v4 二进制。**处置**:导入时记下 `sourceFormat`;若源是 v3/旧字母格式,首次 Ctrl+S 弹一次确认(「原文件是 v3 文本,保存会把它转成 v4 二进制(不可逆);期 E 会专门做迁移并先提交一份 v3 原文留档。确认转换?」),确认后本会话不再问。**不做**"自动另存为"——那会让 `Ctrl+S` 这个肌肉记忆变得不可预测。

**⑥ 调色板从 `window.TILE_DEFS` 派生,纹理 22(水面)标注"由游戏自动派生"且不可选。** 审计 A7:22 在编辑器是"水面"、在游戏是自动派生的。第二份调色板(写死 1..22)就是本仓反复吃亏的"两份实现迟早漂",故页面加载 `tile_defs.js`(由 `sync-tiles.js` 从 `data/tile_defs.json` 生成),`Editor.texturePalette(defs)` 从它派生。

**⑦ 缩略图(①)一层一张,不是合成一张。** 四层各自一张缩略图(2px/子格),合成按图层可见性/压暗在 `render()` 里做 —— 否则"切图层可见性"要重建缩略图,而它本该是一次 4 次 `drawImage` 的合成。

**⑧ 库(服务器上的 `maps/*.cyrm`)** 只列**文件名与元信息**,内存里**永远只装一张图**;`闸 1` 的"库条目 60"约束的是**草稿盘(IndexedDB)里的条目数**(见 Task 9)。

---

## 文件结构

| 文件 | 职责 | 本计划中的动作 |
|---|---|---|
| `level_editor/worker.js` | Web Worker 入口:消息壳 + 调 `core.js` 的编解码(闸 3) | **新建**(Task 1) |
| `level_editor/io.js` | 编解码 async 门面(Worker 调用方,可注入 factory) | **新建**(Task 1) |
| `level_editor/worker_io_smoke.js` | `worker.js` + `io.js` 的 node 冒烟(打桩 `self`/`importScripts` 跑真协议) | **新建**(Task 1) |
| `level_editor/render.js` | 四层缓存 ①②③④ + 脏区 + 环面 + 分帧(闸 2)+ 画布挂载 | **新建**(Task 2 纯半边 → Task 3 画布首帧 → Task 4 逐格路径) |
| `level_editor/render_smoke.js` | `render.js` 纯半边的 node 冒烟(含 ③ 的作废断言) | **新建**(Task 2) |
| `level_editor/ui.js` | 工具内核 + 历史 + 剪贴板 + 面板 + 持久化 + 热键 + `boot()` | **新建**(Task 3 启动最小版 → Task 5/6 内核 → Task 7 交互 → Task 8 面板 → Task 9 持久化) |
| `level_editor/editor_smoke.js` | `ui.js` 内核的 node 冒烟 + 源码级纪律扫描 | **新建**(Task 5)→ 追加(Task 6、8、9) |
| `level_editor/editor.html` | 真页面:DOM 结构 + `<script src>` + 敌人注册表标记块 | **整体重写**(Task 3) |
| `level_editor/structure-editor.html` | 旧编辑器 | **删除**(Task 3,与上一条同一 commit) |
| `level_editor/sync-enemies.js` | 注册表同步脚本 | **改 `htmlPath`**(Task 3,同一 commit) |
| `level_editor/server_smoke.js` | 服务器冒烟 | **改写相位 ①b 与 ⑧**(Task 3,被改写而非删除,理由写在该 Task 里) |
| `level_editor/core.js` / `tint.js` / `smoke.js` / `tint_smoke.js` / `editor_server.js` / `serve.bat` / `tile_defs.js` / `sync-tiles.js` / `maps/*` | —— | **一个字节都不动** |
| `CLAUDE.md` 的编辑器小节 | 形状面板已删、格式已换、编辑器入口改名 | **更新**(Task 10) |

分工次序:`worker_io_smoke.js` / `render_smoke.js` / `editor_smoke.js` **各自独立、都自带断言助手**(不抽公共测试库)—— 与仓库 `tests/*.gd` 每个文件自成一体的惯例一致,评审不要报成重复代码。

**依赖顺序(硬)**:`core.js → tile_defs.js → tint.js → render.js → io.js → ui.js`。`tint.js` 对 `Core` 是硬依赖(计划 2a 的裁决 ③,没有 Core 当场抛错),`render.js` 对 `Core`+`Tint` 同理,`ui.js` 对四者都用。

---

## Task 1: `worker.js` + `io.js`(闸 3:编解码进 Web Worker)

**Files:**
- Create: `level_editor/worker.js`
- Create: `level_editor/io.js`
- Create: `level_editor/worker_io_smoke.js`

**Interfaces:**
- Consumes:`globalThis.Core`(在 worker 里由 `importScripts('core.js')` 带进来;在 node 冒烟里由 `require('./core.js')` 带进来)
- Produces:
  - `worker.js`(经典 Worker 入口,不导出任何东西;只定义 `self.onmessage`):
    - 请求 `{id:Number, op:'ping'}` → 应答 `{id, ok:true, pong:true}`
    - 请求 `{id, op:'encode', map:Object, compress:Boolean}` → 应答 `{id, ok:true, bytes:Uint8Array}`
    - 请求 `{id, op:'decode', bytes:Uint8Array}` → 应答 `{id, ok:true, map:Object}`
    - 失败一律 `{id, ok:false, error:String}`(字符串是 `errText(e)`,含 `e.cause.message` 回退)
    - 未知 `op` → `{id, ok:false, error:'worker: 未知操作 …'}`
  - `globalThis.Io`:
    - `createCodec(opts) -> {encodeMap(map, {compress?}) -> Promise<Uint8Array>, decodeMap(bytes) -> Promise<Object>, ping() -> Promise<Object>, pendingCount() -> Number, isDead() -> Boolean, terminate() -> void}`
      - `opts = {workerFactory?: () => WorkerLike}`(默认 `() => new Worker('worker.js')`)
    - `workerAvailable() -> Boolean`(`typeof Worker !== 'undefined'`)
    - `encodeMap(map, opts) -> Promise<Uint8Array>` / `decodeMap(bytes) -> Promise<Object>` / `ping() -> Promise<Object>` —— 共用同一个惰性创建的单例 codec
  - `WorkerLike` 的形状(注入契约):`{postMessage(msg):void, onmessage:(ev)=>void, onerror?:(ev)=>void, terminate?():void}`

- [ ] **Step 1: 写测试 `level_editor/worker_io_smoke.js`(此时必然红)**

新建 `level_editor/worker_io_smoke.js`:

```js
'use strict';
// Node 冒烟 —— worker.js(闸 3 的 Worker 壳)与 io.js(async 门面)。
// Run: cd level_editor && node worker_io_smoke.js
// 判据:文本 `WORKER IO SMOKE OK` + 退出码 0。
//
// ★★ 怎么在 node 里测"一个浏览器 Worker":worker.js 是**经典脚本**,只用两个全局
//    (`importScripts` 与 `self`)。本文件给这两个名字打桩,于是能把**真的** worker.js
//    加载进来、用真的消息协议跑真的 core.js —— 不是另写一个假实现冒充它。
//    (node 的 worker_threads 是另一套 API,拿它测等于测一份只在测试里存在的代码。)

globalThis.importScripts = function () { require('./core.js'); };
const inProc = { onmessage: null, postMessage: null };
globalThis.self = inProc;
require('./worker.js');                       // ← 定义 inProc.onmessage
require('./io.js');
const Core = globalThis.Core;
const Io = globalThis.Io;

let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
function sameBytes(actual, expected, msg) {
  const a = Array.prototype.slice.call(actual), e = Array.prototype.slice.call(expected);
  if (a.length !== e.length) {
    fail++; console.error('  FAIL - ' + msg + ' (长度 ' + a.length + ' ≠ 期望 ' + e.length + ')'); return;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== e[i]) {
      fail++; console.error('  FAIL - ' + msg + ' (第 ' + i + ' 字节: 实得 ' + a[i] + ', 期望 ' + e[i] + ')'); return;
    }
  }
  pass++; console.log('  ok  - ' + msg);
}
function errText(e) {
  let m = (e && e.message !== undefined) ? String(e.message) : String(e);
  if (m === '' && e && e.cause && e.cause.message) m = String(e.cause.message);
  return m;
}
// ★ 反向断言必须同时断言「错在哪」:只判「有没有抛」是假绿(拼错标识符抛的 TypeError 一样算过)。
async function rejects(fn, msg, expectSub) {
  let e = null;
  try { await fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && errText(e).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + errText(e)); return;
  }
  pass++; console.log('  ok  - ' + msg);
}

// ── 假 Worker:把消息异步交给**真的** worker.js,再把应答异步交回 ──
let live = null;
function makeWorker() {
  const w = {
    onmessage: null, onerror: null, terminated: false, sent: 0,
    postMessage: function (msg) {
      w.sent++;
      // ★ 异步投递:真 Worker 是异步的;同步回包会掩盖"发完就 terminate"那一类错。
      setImmediate(function () {
        if (w.terminated) return;
        inProc.postMessage = function (out) {
          if (typeof w.onmessage === 'function') w.onmessage({ data: out });
        };
        inProc.onmessage({ data: msg });
      });
    },
    terminate: function () { w.terminated = true; },
  };
  live = w;
  return w;
}

function fillMap(map, L, seed) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  for (let i = 0; i < a.length; i++) a[i] = ((i * 2654435761 + seed) >>> 0) % (L === Core.LAYER_BG ? 0xFFFFFFFF : 0xFFFF);
  return map;
}

(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 有请求永不 settle(应答没被投递?)');
    process.exit(1);
  }, 120000);

  // ==== 相位 ① 环境与常量 ====
  ok(Io.workerAvailable() === false, '★ node 里 workerAvailable() === false(node 没有浏览器 Worker)');
  await rejects(function () { return Io.encodeMap(Core.createMap('x', 1, 1)); },
                '★ 没有 Worker 且没注入 factory → 抛错(不静默退回主线程)',
                'Worker');
  ok(live === null, '那次失败**没有**建出任何 worker');

  // ==== 相位 ② 真协议往返(经真的 worker.js 与真的 core.js)====
  const codec = Io.createCodec({ workerFactory: makeWorker });
  const m = fillMap(fillMap(fillMap(Core.createMap('w', 3, 2), Core.LAYER_SCENE, 7), Core.LAYER_FRONT, 11),
                    Core.LAYER_BG, 13);
  m.players = [{ x: 1, y: 1 }];
  m.enemies = [{ type: 'fly_bird', x: 2, y: 1 }];
  m.comments = ['经 Worker 往返'];

  const bytes = await codec.encodeMap(m);
  ok(bytes instanceof Uint8Array, 'encodeMap 经 Worker 拿回 Uint8Array');
  ok(bytes.length > Core.HEADER_SIZE, '字节数 > 20(实得 ' + bytes.length + ')');
  sameBytes(bytes.subarray(0, 4), new Uint8Array([0x43, 0x59, 0x52, 0x4D]),
            '★ 头部 magic 仍是 "CYRM"(worker 没动内容)');
  eq(bytes[4], Core.FORMAT_VERSION, '版本字节 = ' + Core.FORMAT_VERSION);
  eq(bytes[5], 1, '默认走压缩路径(compression = 1)');

  const back = await codec.decodeMap(bytes);
  sameBytes(back.layers[Core.LAYER_SCENE].desc, m.layers[Core.LAYER_SCENE].desc, '往返:场景层一致');
  sameBytes(back.layers[Core.LAYER_FRONT].desc, m.layers[Core.LAYER_FRONT].desc, '往返:前景层一致');
  sameBytes(back.layers[Core.LAYER_BG].rgba, m.layers[Core.LAYER_BG].rgba, '往返:背景层一致');
  eq(back.players, m.players, '往返:出生点一致');
  eq(back.enemies, m.enemies, '往返:敌人一致');
  eq(back.comments, m.comments, '往返:注释一致');

  // ==== 相位 ③ 裸路径(compression = 0)也要经 Worker ====
  const raw = await codec.encodeMap(m, { compress: false });
  eq(raw[5], 0, 'compress:false → compression 字节是 0');
  const backRaw = await codec.decodeMap(raw);
  sameBytes(backRaw.layers[Core.LAYER_SCENE].desc, m.layers[Core.LAYER_SCENE].desc, '裸路径往返一致');

  // ==== 相位 ④ 错误要带错因回到调用方 ====
  await rejects(function () { return codec.decodeMap(new Uint8Array(20)); },
                '损坏文件 → promise 被拒', 'magic');
  await rejects(function () { return codec.decodeMap(new Uint8Array([1, 2, 3])); },
                '太短的文件 → promise 被拒', '小于头部');
  const bad = new Uint8Array(bytes);
  bad[5] = 9;                                   // 未知 compression
  await rejects(function () { return codec.decodeMap(bad); }, '未知 compression → 被拒', 'compression');

  // ==== 相位 ⑤ 并发:按 id 配对,不许串台 ====
  (function () {
    const jobs = [];
    for (let n = 1; n <= 6; n++) {
      const mm = fillMap(Core.createMap('c' + n, n, 2), Core.LAYER_SCENE, n * 31);
      jobs.push(codec.encodeMap(mm).then(function (b) { return { n: n, b: b }; }));
    }
    return Promise.all(jobs).then(function (outs) {
      let allOk = true, firstBad = '';
      return Promise.all(outs.map(function (o) {
        return codec.decodeMap(o.b).then(function (mm) {
          const src = Core.createMap('c' + o.n, o.n, 2);
          fillMap(src, Core.LAYER_SCENE, o.n * 31);
          const a = mm.layers[Core.LAYER_SCENE].desc;
          if (a.length !== src.layers[Core.LAYER_SCENE].desc.length) { allOk = false; firstBad = 'n=' + o.n + ' 长度'; return; }
          for (let i = 0; i < a.length; i++) {
            if (a[i] !== src.layers[Core.LAYER_SCENE].desc[i]) { allOk = false; firstBad = 'n=' + o.n + ' 第 ' + i + ' 项'; return; }
          }
        });
      })).then(function () {
        ok(allOk, '★ 6 个并发的 encode/decode 各自拿到**自己那份**结果(按 id 配对,首个不匹配:' + firstBad + ')');
        eq(codec.pendingCount(), 0, '全部 settle 之后 pending 表清空(不会泄漏)');
      });
    });
  })().then(function () {

  // ==== 相位 ⑥ ping 与 terminate ====
  return codec.ping().then(function (p) {
    ok(p.pong === true, 'ping → pong(唤醒与就绪检测用)');
    ok(typeof codec.isDead() === 'boolean' && codec.isDead() === false, 'isDead(): 正常态返回 false');
    codec.terminate();
    ok(live.terminated === true, 'terminate() 真的终止了底层 worker');

    // ==== 相位 ⑦ 源码级纪律 ====
    (function () {
      const fs = require('fs'), path = require('path');
      const src = fs.readFileSync(path.join(__dirname, 'worker.js'), 'utf8');
      ok(/importScripts\(['"]core\.js['"]\)/.test(src),
         "★ worker.js 用 importScripts('core.js') 拿格式实现(只有一份实现,不抄第二份)");
      ok(src.indexOf('encodeTexLayer') < 0 && src.indexOf('decodeTexLayer') < 0 &&
         src.indexOf('crc32') < 0 && src.indexOf('inflate') < 0,
         '★★ worker.js 里没有任何格式/压缩逻辑(全在 core.js 里 —— 第二份实现迟早漂,而漂了不报错)');
      ok(/self\.onmessage\s*=/.test(src), 'worker.js 定义 self.onmessage');
      const io = fs.readFileSync(path.join(__dirname, 'io.js'), 'utf8');
      ok(io.indexOf('new Worker(') >= 0, "io.js 用 new Worker('worker.js')(只走 HTTP,故原生可用)");
      ok(!/xmlhttprequest|activexobject|importScripts\(/i.test(io),
         '★ io.js 里没有 Blob URL / 主线程兜底那类绕法(闸 3 明说不做降级路径)');
    })();

    console.log('');
    console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
    if (fail === 0) console.log('WORKER IO SMOKE OK');
    process.exit(fail === 0 ? 0 : 1);
  });
  // ★ 计划原文**漏印了这一行**(相位 ⑤ 那个 `.then(function () {` 回调的收尾)。
  //   缺了它整个文件是 SyntaxError: Unexpected end of input,一行断言都跑不到
  //   (Task 1 实现时实测)。按括号平衡补上,无任何断言被改动。
  });
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node worker_io_smoke.js`

Expected: 进程在 `require('./io.js')` 处死掉 —— `Error: Cannot find module './io.js'`,退出码 1(模块还不存在,这是"测试先红"的正常形态)。

- [ ] **Step 3: 实现 `worker.js` 与 `io.js`**

新建 `level_editor/worker.js`:

```js
// worker.js —— 闸 3:二进制编解码 + CRC32 进 Web Worker(规格 §4.3)。
// ★ 编辑器只走 HTTP(规格 §4.9),故 `new Worker('worker.js')` **原生可用** ——
//   不需要 Blob URL 那种绕法,也**不需要降级路径**:主线程一帧都不阻塞。
// ★ 经典 Worker(不是 module worker):importScripts 同步加载 core.js,于是 worker 里
//   **只有一份格式实现**。CRC32 与 deflate 都住在 core.js 的 encodeMap/decodeMap 里,
//   本文件**一个字节的格式逻辑都不重复** —— 第二份实现的症状是"编辑器存得下、游戏读不出",
//   而且不报错。
// ★ 本文件刻意写成薄壳:只做消息收发。
'use strict';

importScripts('core.js');

function errText(e) {
  if (!e) return '未知错误';
  var m = (e.message !== undefined) ? String(e.message) : String(e);
  // core.js 在"Zlib 尾损坏"那一档抛的是**无 message 的 TypeError**,细节在 e.cause
  // (计划 1 账本 Task 7 Minor 2 实测)。不回退读它就等于把错误信息丢掉。
  if (m === '' && e.cause && e.cause.message) m = String(e.cause.message);
  return m === '' ? String(e) : m;
}

// ★ 刻意**不**用 transfer 列表搬 Uint8Array:一次保存/载入才走一趟,复制那点字节
//   远比"transfer 之后 buffer 被 detach"这一类跨环境差异便宜。少一个变量。
function reply(id, payload) {
  var msg = { id: id };
  for (var k in payload) msg[k] = payload[k];
  self.postMessage(msg);
}

self.onmessage = function (ev) {
  var msg = ev.data || {};
  var id = msg.id;
  var op = msg.op;
  if (op === 'ping') { reply(id, { ok: true, pong: true }); return; }
  if (op === 'encode') {
    Core.encodeMap(msg.map, { compress: msg.compress !== false }).then(function (bytes) {
      reply(id, { ok: true, bytes: bytes });
    }).catch(function (e) {
      reply(id, { ok: false, error: errText(e) });
    });
    return;
  }
  if (op === 'decode') {
    Core.decodeMap(msg.bytes).then(function (map) {
      reply(id, { ok: true, map: map });
    }).catch(function (e) {
      reply(id, { ok: false, error: errText(e) });
    });
    return;
  }
  reply(id, { ok: false, error: 'worker: 未知操作 ' + op });
};
```

新建 `level_editor/io.js`:

```js
// io.js —— 编解码 async 门面(规格 §4.3 闸 3)。
// ★ 写成 async **不是**为了降级:编辑器只走 HTTP,Worker 原生可用。理由只有一条 ——
//   Worker 通信本来就是异步的,写成 async 让 ui.js 里的导入/导出/自动存更直。
// ★★ Worker 起不来 = **当场抛错**,没有主线程兜底:静默退回主线程会把"一帧都不阻塞"
//    这条保证悄悄取消,而症状是"大图保存时页面卡一下" —— 没人会把它当成 bug 报。
'use strict';

globalThis.Io = (function () {
  'use strict';

  var seq = 0;

  function errText(e) {
    if (!e) return '未知错误';
    var m = (e.message !== undefined) ? String(e.message) : String(e);
    if (m === '' && e.cause && e.cause.message) m = String(e.cause.message);
    return m === '' ? String(e) : m;
  }

  function defaultFactory() {
    if (typeof Worker === 'undefined') {
      throw new Error('Io: 本环境没有 Worker —— 编辑器只通过 HTTP 打开(规格 §4.9),' +
                      'file:// 下没有 Worker。请用 serve.bat 起服务器再打开页面。');
    }
    return new Worker('worker.js');
  }

  // 一个 codec = 一个 worker + 一张"等应答"的表。
  function createCodec(opts) {
    opts = opts || {};
    var factory = opts.workerFactory || defaultFactory;
    var worker = null;
    var pending = new Map();
    var dead = null;
    var started = 0;

    function failAll(err) {
      dead = err;
      pending.forEach(function (p) { p.reject(err); });
      pending.clear();
    }

    function ensure() {
      if (dead) throw dead;
      if (worker) return worker;
      worker = factory();
      started++;
      worker.onmessage = function (ev) {
        var m = (ev && ev.data) ? ev.data : {};
        var p = pending.get(m.id);
        // ★ 表里没有的应答**直接丢**:它只可能来自 terminate 前发出去的那一批。
        //   不丢的话就是"上一次的迟到结果写进这一次的 promise"。
        if (!p) return;
        pending.delete(m.id);
        if (m.ok) p.resolve(m);
        else p.reject(new Error(m.error || 'worker 报告失败但没给原因'));
      };
      if (typeof worker.onerror !== 'function') {
        worker.onerror = function (ev) {
          var msg = (ev && ev.message) ? ev.message : 'worker 内部错误';
          failAll(new Error('Io: 编解码 worker 出错 —— ' + msg));
        };
      }
      return worker;
    }

    function call(op, payload) {
      return new Promise(function (resolve, reject) {
        var w = ensure();
        var id = ++seq;
        pending.set(id, { resolve: resolve, reject: reject });
        var msg = { id: id, op: op };
        for (var k in payload) msg[k] = payload[k];
        w.postMessage(msg);
      });
    }

    return {
      encodeMap: function (map, o) {
        return call('encode', { map: map, compress: !(o && o.compress === false) })
          .then(function (m) { return m.bytes; });
      },
      decodeMap: function (bytes) {
        return call('decode', { bytes: bytes }).then(function (m) { return m.map; });
      },
      ping: function () { return call('ping', {}); },
      pendingCount: function () { return pending.size; },
      workerStarts: function () { return started; },
      isDead: function () { return dead !== null; },
      terminate: function () {
        if (worker && typeof worker.terminate === 'function') worker.terminate();
        worker = null;
      },
    };
  }

  var shared = null;
  function sharedCodec() { if (!shared) shared = createCodec(); return shared; }

  return {
    createCodec: createCodec,
    workerAvailable: function () { return typeof Worker !== 'undefined'; },
    encodeMap: function (map, o) { return sharedCodec().encodeMap(map, o); },
    decodeMap: function (bytes) { return sharedCodec().decodeMap(bytes); },
    ping: function () { return sharedCodec().ping(); },
  };
})();
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node worker_io_smoke.js`

Expected: 全部 `ok -`,末行 `WORKER IO SMOKE OK`,退出码 0。

- [ ] **Step 5: 确认三个既有冒烟一个都没动**

Run: `cd level_editor && node smoke.js && node tint_smoke.js && node server_smoke.js`

Expected: `SMOKE OK`(343 通过 / 0 失败)、`TINT SMOKE OK`(96 通过 / 0 失败)、`SERVER SMOKE OK`(197 通过 / 0 失败),退出码 0。

- [ ] **Step 6: 提交**

```bash
git add level_editor/worker.js level_editor/io.js level_editor/worker_io_smoke.js
git commit -F - <<'EOF'
feat(editor): 闸 3 —— 编解码进 Web Worker(worker.js + io.js)

worker.js 是薄壳:importScripts('core.js') 后只做消息收发,CRC32 与 deflate
全部留在 core.js 里(第二份格式实现的症状是"编辑器存得下、游戏读不出",且不报错)。
io.js 是 async 门面 —— 异步不是为了降级(编辑器只走 HTTP,Worker 原生可用),
而是 Worker 通信本来就是异步的;没有 Worker 时**当场抛错**,不静默退回主线程。

冒烟用打桩的 self/importScripts 把**真的** worker.js 加载进 node,跑真消息协议,
含 6 路并发按 id 配对、错误带错因回传、以及"没有 Worker 时不建 worker 也不兜底"。
EOF
```

---

## Task 2: `render.js` 纯半边(缓存 ①②③ + 脏区 + 环面 + 分帧)

**Files:**
- Create: `level_editor/render.js`(只写**纯半边**:`mount()` 一族留给 Task 3/4)
- Create: `level_editor/render_smoke.js`

**Interfaces:**
- Consumes:`globalThis.Core`(`SUB_PER_CELL` / `LAYER_*` / `texOf`)、`globalThis.Tint`(`createTileCache` / `TILE_PX` / `BLOCK_PX`)
- Produces(`globalThis.Render`):
  - 常量:`MIN_ZOOM=1`、`MAX_ZOOM=64`、`ZOOM_THRESHOLD=8`、`THUMB_PX=2`、`THUMB_MAX_BYTES`、`DEFAULT_BUDGET_MS=8`、`DEFAULT_CELL_MAX=8192`、`DIRTY_RECT_MAX`
  - `wrapIdx(v, n) -> Number`(对负数也正确)
  - `quadOf(v) -> Number`(恒在 `0..SUB-1`)
  - `layerArray(map, L) -> TypedArray|null`(缺席层 → `null`)
  - `descAt(map, L, X, Y) -> Number`(坐标先环面折算;缺席层 → `0`)
  - `rgbaAt(map, X, Y) -> Number`
  - `setAtlas(pixels, w, h, opts?) -> void`(★ 唯一的换图入口:**同时作废 ③ 与 ④**;`opts.backend` 是 node 冒烟的注入缝,与 tint.js 的注入式画布同款)、`atlasInfo() -> {width,height}|null`、`atlasCapacity() -> Number`、`tileCache() -> Tint 缓存对象`
  - `tileFor(desc, qx, qy) -> Object|null`(★ `null` = 空气;空气**绝不进** `Tint.get`;纹理实参从 `desc` 推导)
  - `createCellCache(opts) -> {version(L,cx,cy), touch(L,cx,cy), setSource(), get(L,cx,cy), clear(), stats()}`(**工厂,不改模块状态**;`opts={maxCells?, build:(L,cx,cy)=>Object}`)
  - `attachCells(cache) -> cache`、`cellCache() -> cache|null`(装上/读取 ③;`setAtlas` 只作废**装上的**那一个)
  - `createSlicer(opts) -> {run(items, fn) -> Promise<{frames, processed, maxStepMs}>, budgetMs}`,`opts={budgetMs?, now?, nextFrame?}`
  - `zoomPath(pxPerSub) -> 'thumb'|'layers'`、`clampZoom(z)`、`fitZoom(subCols, subRows, viewW, viewH, pad)`、`thumbScale(subCols, subRows)`
  - `visibleSubRange(view, viewW, viewH, subCols, subRows) -> {x0,y0,x1,y1}`(半开区间)
  - `torusOffsets(view, viewW, viewH, mapW, mapH) -> Array<[dx,dy]>`
  - `hitTest(view, px, py, subCols, subRows) -> {X, Y}`(折算过的整数子格坐标)
  - `snapHit(hit) -> {kind, x, y}`、`brushSpan(size) -> {unit:'cell'|'sub', n}`、`brushRegion(hit, size) -> {unit, x0, y0, x1, y1}`
  - `selectionSource(sel, dx, dy, X, Y) -> {hit:Boolean, X, Y}`
  - `rectUnion(a, b)`、`rectIsEmpty(r)`

- [ ] **Step 1: 写测试 `level_editor/render_smoke.js`(此时必然红)**

新建 `level_editor/render_smoke.js`:

```js
'use strict';
// Node 冒烟 —— render.js 的**纯半边**(缓存 ①②③、脏区、环面、画笔几何、闸 2 分帧)。
// Run: cd level_editor && node render_smoke.js
// 判据:文本 `RENDER SMOKE OK` + 退出码 0。
// ★ 加载顺序是硬依赖:core → tint → render(tint 要 Core,render 要两者)。

require('./core.js');
require('./tint.js');
require('./render.js');
const Core = globalThis.Core;
const Tint = globalThis.Tint;
const Render = globalThis.Render;

let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
function throws(fn, msg, expectSub) {
  let e = null;
  try { fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && String(e.message).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + e.message); return;
  }
  pass++; console.log('  ok  - ' + msg);
}

// 合成图集:3 行 × 10 列、每块 32×32(R = 块内 x×8,G = 块内 y×8,B = 块号)。
const COLS = 10, ATLAS_W = COLS * 32, ATLAS_H = 96;
function makeAtlas() {
  const a = new Uint8ClampedArray(ATLAS_W * ATLAS_H * 4);
  for (let y = 0; y < ATLAS_H; y++) {
    for (let x = 0; x < ATLAS_W; x++) {
      const i = (y * ATLAS_W + x) * 4;
      a[i] = (x % 32) * 8; a[i + 1] = (y % 32) * 8;
      a[i + 2] = Math.floor(y / 32) * COLS + Math.floor(x / 32); a[i + 3] = 255;
    }
  }
  return a;
}
// 记录型 backend:每次建图都记账,于是能断言"空气**没有**进 Tint"(只判颜色是抓不住它的)。
function spyBackend() {
  const calls = [];
  return {
    calls: calls,
    createTile: function (pixels, size) { calls.push({ size: size }); return { fake: true, n: calls.length }; },
  };
}
function makeMap(cellsW, cellsH) {
  const m = Core.createMap('t', cellsW, cellsH);
  return m;
}
function setCells(map, L, list, descOf) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  for (const c of list) a[c[1] * map.subCols + c[0]] = descOf(c[0], c[1]);
  return map;
}

(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 某个断言挂住了(分帧器的 nextFrame 没被注入?)');
    process.exit(1);
  }, 120000);

  // ==== 相位 ① 环面折算与空层 ====
  eq(Render.wrapIdx(-1, 4), 3, 'wrapIdx: -1 → 3(负数也折回正区间)');
  eq(Render.wrapIdx(-5, 4), 3, 'wrapIdx: -5 → 3');
  eq(Render.wrapIdx(4, 4), 0, 'wrapIdx: 4 → 0');
  eq(Render.wrapIdx(0, 4), 0, 'wrapIdx: 0 → 0');
  eq(Render.quadOf(-1), 3, 'quadOf: -1 → 3(与 Tint.quadIndex 的合法范围一致)');
  let quadOk = true;
  for (let v = -20; v <= 20; v++) { const q = Render.quadOf(v); if (q < 0 || q >= Core.SUB_PER_CELL || Math.floor(q) !== q) quadOk = false; }
  ok(quadOk, '★ quadOf 对 [-20,20] 每个整数都落在 0..' + (Core.SUB_PER_CELL - 1) + '(Tint 对越界象限**会抛**)');

  const m2 = makeMap(2, 1);                     // 8 × 4 子格
  setCells(m2, Core.LAYER_SCENE, [[0, 0], [7, 3]], function () { return Core.neutralDesc(3); });
  eq(Render.descAt(m2, Core.LAYER_SCENE, 0, 0), Core.neutralDesc(3), 'descAt: 命中');
  eq(Render.descAt(m2, Core.LAYER_SCENE, 8, 4), Core.neutralDesc(3), '★ descAt: 坐标环面折算(8,4) → (0,0)');
  eq(Render.descAt(m2, Core.LAYER_SCENE, -8, -4), Core.neutralDesc(3), '★ descAt: 负数环面折算');
  eq(Render.descAt(m2, Core.LAYER_FRONT, 0, 0), 0, 'descAt: 空的前景层 → 0(空气)');

  // ★★ 缺席层(null)= 全空气。规格 §2.4 的 createMap 恒建四层,而 layer_flags 允许缺层
  //    ⇒ 解码出来的一层可以是 null。渲染必须把 null 当"全空气",而不是当场抛。
  const mNull = makeMap(2, 1);
  mNull.layers[Core.LAYER_BACK] = null;
  eq(Render.layerArray(mNull, Core.LAYER_BACK), null, 'layerArray: 缺席层返回 null');
  ok(Render.descAt(mNull, Core.LAYER_BACK, 0, 0) === 0 && Render.descAt(mNull, Core.LAYER_BACK, 5, 2) === 0,
     '★★ 缺席层每一格都读成 0(空气)—— 不抛、也不当成别的东西');
  eq(Render.layerArray(mNull, Core.LAYER_BG).length, 8 * 4, 'layerArray: 背景层返回 rgba 数组');

  // ==== 相位 ② 空气短路(账本 I4:air 是地图里最常见的一格)====
  (function () {
    const be = spyBackend();
    Render.setAtlas(makeAtlas(), ATLAS_W, ATLAS_H, { backend: be });
    ok(Render.atlasInfo() !== null && Render.atlasInfo().width === ATLAS_W, 'setAtlas 之后 atlasInfo 有值');
    eq(Render.atlasCapacity(), 30, 'atlasCapacity 从图集尺寸派生(320×96 → 10 列 × 3 行 = 30 块)');
    ok(Render.tileFor(0, 0, 0) === null, '★ tileFor(空气) → null');
    eq(be.calls.length, 0, '★★ 空气**没有**进 Tint(漏了这一步 = 第一帧就抛、每帧都在同一处抛)');
    ok(Render.tileFor(0x000007FF, 0, 0) === null,
       '★ 畸形描述符(辅码非 0 而纹理为 0,如 0x7FF)→ 也当空气(null),不走 Tint');
    eq(be.calls.length, 0, '畸形描述符同样没进 Tint');
    // ★ 正向对照:少了它,上面两条"0 次调用"在"tileFor 从不调 Tint"的坏实现下也全绿。
    ok(Render.tileFor(Core.neutralDesc(3), 0, 0) !== null, '正向对照:真砖能取到小图');
    eq(be.calls.length, 1, '正向对照:真砖**确实**进了 backend(证明上面那两条不是空转)');
    eq(be.calls[0].size, Tint.TILE_PX, 'backend 收到的小图边长 = ' + Tint.TILE_PX);
    ok(Render.tileFor(Core.neutralDesc(3), 0, 0) !== null && be.calls.length === 1,
       '同一块第二次命中缓存(不再进 backend)');
    throws(function () { Render.setAtlas(new Uint8ClampedArray(7), 8, 1, { backend: be }); },
           '★ setAtlas 传形状不合法的图集(7 字节不是整行 8×4) → 抛错,不静默画一片透明', '不是整行');
  })();

  // ==== 相位 ③ ③ 格位图缓存:两条独立的失效轴 ====
  (function () {
    let built = 0;
    const c3 = Render.createCellCache({
      maxCells: 4,
      build: function (L, cx, cy) { built++; return { L: L, cx: cx, cy: cy, n: built }; },
    });
    eq(Render.cellCache(), null, 'createCellCache 本身**不**改模块状态(装上要走 attachCells)');
    Render.attachCells(c3);
    ok(Render.cellCache() === c3, 'attachCells 之后 cellCache() 就是它');
    const a1 = c3.get(Core.LAYER_SCENE, 0, 0);
    eq(built, 1, '未命中 → 建一次');
    const a2 = c3.get(Core.LAYER_SCENE, 0, 0);
    ok(a1 === a2, '同键第二次命中同一个对象');
    eq(built, 1, '命中不再重建');
    eq(c3.stats().hits, 1, 'stats: hits = 1');

    // 轴 1:内容版本号。编辑某格必须 touch 它,否则 ③ 继续交出旧内容合成的格位图。
    c3.touch(Core.LAYER_SCENE, 0, 0);
    eq(c3.version(Core.LAYER_SCENE, 0, 0), 1, 'touch → 版本 +1');
    c3.get(Core.LAYER_SCENE, 0, 0);
    eq(built, 2, '★ 内容版本变了 → 该格重建(其余格不受影响)');
    c3.get(Core.LAYER_SCENE, 0, 1);
    eq(built, 3, '没被 touch 的隔壁格是**另一个键**,本来就该建一次');

    // LRU:maxCells 4,塞第 5 格 → 最久未用的键被淘汰
    c3.clear();
    built = 0;
    [[0, 0], [1, 0], [2, 0], [3, 0]].forEach(function (k) { c3.get(Core.LAYER_SCENE, k[0], k[1]); });
    eq(built, 4, 'LRU: 4 个键都建了');
    c3.get(Core.LAYER_SCENE, 4, 0);
    eq(c3.stats().evictions, 1, 'LRU: 超出上限淘汰 1 个');
    eq(c3.stats().size, 4, 'LRU: 容量守住 maxCells');

    const st = c3.stats();
    ok(typeof st.hits === 'number' && typeof st.misses === 'number' &&
       typeof st.evictions === 'number' && typeof st.size === 'number' &&
       typeof st.maxCells === 'number' && typeof st.generation === 'number',
       'stats 的键是 {hits, misses, evictions, size, maxCells, generation}');
  })();

  // ==== 相位 ③b ★★ 换图必须**同时**作废 ③ 与 ④(走生产路径 setAtlas)====
  // ★ 账本点名带进计划 2b 的那条不变量。判据走 setAtlas 这条**真实**路径,不各自
  //   调一遍 setSource —— 只测"每个缓存自己的 setSource 有效"证明不了"换图事件
  //   真的碰到了两层",而漏掉 ③ 的症状是审计 A2 在上一层原样复发。
  (function () {
    const be = spyBackend();
    const a1 = makeAtlas(), a2 = makeAtlas();
    a2[0] = 111; a2[1] = 222;                    // 两张**不同**的图集:换图之后像素必须变
    Render.setAtlas(a1, ATLAS_W, ATLAS_H, { backend: be });   // ← 装了一个可记账的 ④
    const c3 = Render.attachCells(Render.createCellCache({
      maxCells: 8, build: function (L, cx, cy) { return { L: L, cx: cx, cy: cy, v: 1 }; },
    }));
    const t4 = Render.tileCache();
    const d3 = Core.neutralDesc(3);
    const before3 = c3.get(Core.LAYER_SCENE, 0, 0);
    const before4 = t4.get(3, 0, 0, d3);
    ok(c3.stats().size === 1 && t4.stats().size === 1, '两层各有一条条目(前置条件)');

    Render.setAtlas(a2, ATLAS_W, ATLAS_H);       // ★ 换图(**不换 backend**,要的就是同一个 ④)
    eq(c3.stats().size, 0, '★★ 换图之后 ③ 被清空(漏了这一句 = A2 在上一层复发)');
    eq(t4.stats().size, 0, '★★ 换图之后 ④ 被清空(Tint.setSource 自己做的)');
    ok(c3.stats().generation === 1, '★ ③ 的代际 +1(setSource 追的是它)');
    const after3 = c3.get(Core.LAYER_SCENE, 0, 0);
    ok(after3 !== before3, '★★ 换图之后同一个格键**是新对象**(调用方不得跨换图持有格位图)');
    const after4 = t4.get(3, 0, 0, d3);
    ok(after4 !== before4, '★★ 换图之后同一块小图也是新对象(调用方不得跨换图持有 tile)');
    ok(be.calls.length >= 2, '换图之后 ④ 真的重算过(实得 backend 调用 ' + be.calls.length + ' 次)');
  })();

  // ==== 相位 ④ 闸 2:单帧预算分帧器 ====
  (function () {
    // 注入时钟与"下一帧":每项花 1ms,让出一帧再走 20ms(模拟真实的帧间隔)。
    const clock = { t: 0 };
    const slicer = Render.createSlicer({
      budgetMs: 8,
      now: function () { return clock.t; },
      nextFrame: function () { clock.t += 20; return Promise.resolve(); },
    });
    const items = [];
    for (let i = 0; i < 100; i++) items.push(i);
    const seen = [];
    return slicer.run(items, function (it) { seen.push(it); clock.t += 1; }).then(function (rep) {
      eq(seen.length, 100, '★ 分帧器把 100 项**全部**做完(慢,但不丢)');
      eq(rep.processed, 100, 'report.processed = 100');
      // 预算 8ms、每项 1ms、每帧至少一项 ⇒ 每帧 8 项;100 项 ⇒ 让出 12 次,
      // 第 13 帧把剩下的 4 项做完并 resolve。
      eq(rep.frames, 12, '★ 每帧 8 项 × 12 帧 = 96 项,余 4 项在第 13 帧(去掉预算判断 = 这里变 0)');
      eq(rep.maxStepMs, 8, '★★ 单帧**真的**没超预算(实得 ' + rep.maxStepMs + 'ms;把预算判断删掉 = 100ms)');

      const one = Render.createSlicer({ budgetMs: 0, now: function () { return clock.t; },
                                        nextFrame: function () { clock.t += 1; return Promise.resolve(); } });
      return one.run([1, 2, 3], function () {}).then(function (r2) {
        eq(r2.processed, 3, '★ budgetMs = 0:每帧至少做一项,3 项照样全部做完(不是死循环)');
        eq(r2.frames, 2, 'budgetMs = 0 → 每帧一项,3 项让出 2 次');
      });
    });
  })().then(function () {

  // ==== 相位 ⑤ 缩放阈值 / 缩略图刻度 / 适配 ====
  eq(Render.ZOOM_THRESHOLD, 8, '阈值 8 px/子格(规格 §4.2 的分工表)');
  eq(Render.zoomPath(7.9), 'thumb', 'zoomPath: 7.9 → 缩略图');
  eq(Render.zoomPath(8), 'layers', 'zoomPath: 8 → 视口离屏层(阈值是"≥ 8 走后者")');
  eq(Render.clampZoom(0.01), Render.MIN_ZOOM, 'clampZoom: 下限');
  eq(Render.clampZoom(1e9), Render.MAX_ZOOM, 'clampZoom: 上限(用户输入钳制,不报错)');
  eq(Render.thumbScale(500, 300), 2, 'thumbScale: 默认 125×75 图 → 2px/子格');
  eq(Render.thumbScale(1600, 1200), 1, '★ thumbScale: 400×300 格(1600×1200 子格)降到 1px/子格(规格 §4.3 闸 1)');
  eq(Render.fitZoom(500, 300, 1000, 600, 0), 2, 'fitZoom: 1000×600 视口 / 500×300 子格 → 2');
  eq(Render.fitZoom(500, 300, 1000, 600, 50), Render.clampZoom(Math.min(900 / 500, 500 / 300)),
     'fitZoom: 留白从两边扣,取两轴较小者');
  eq(Render.fitZoom(1600, 1200, 100, 100, 0), Render.clampZoom(100 / 1600), '★ fitZoom 不返回 0(否则除法爆)');
  ok(Render.fitZoom(1600, 1200, 100, 100, 0) >= Render.MIN_ZOOM, '★ fitZoom 结果被钳在下限之上');

  // ==== 相位 ⑥ 可见区裁剪与环面 3×3 ====
  (function () {
    const view = { x: 0, y: 0, zoom: 8 };
    eq(Render.visibleSubRange(view, 800, 400, 500, 300), { x0: 0, y0: 0, x1: 100, y1: 50 },
       'visibleSubRange: 800×400 @zoom8 → 100×50 子格(半开)');
    const v2 = { x: -50, y: -10, zoom: 4 };
    eq(Render.visibleSubRange(v2, 800, 400, 500, 300), { x0: -50, y0: -10, x1: 150, y1: 90 },
       '★ visibleSubRange 返回**未折算**的坐标(折算由调用方按格做,3×3 副本要的就是它)');

    eq(Render.torusOffsets({ x: 0, y: 0, zoom: 8 }, 800, 400, 500, 300), [[0, 0]],
       'torusOffsets: 视图在正中 → 只需 1 份(不为接缝做无用功)');
    eq(Render.torusOffsets({ x: -50, y: 0, zoom: 4 }, 800, 400, 500, 300), [[-500, 0], [0, 0]],
       '★ torusOffsets: 视图越过左接缝 → 铺 [-500,0] 与 [0,0] 两份(A4:旧实现只铺 [0,1]、少一侧)');
    eq(Render.torusOffsets({ x: -50, y: -60, zoom: 4 }, 800, 400, 500, 300).length, 4,
       '★ 跨两个方向 = 4 份(3×3 里只保留与视口相交的那些)');
  })();

  // ==== 相位 ⑦ 命中测试(副本上也能落笔 = A4 的另一半)====
  (function () {
    const view = { x: 0, y: 0, zoom: 8 };
    eq(Render.hitTest(view, 800, 400, 500, 300), { X: 100, Y: 50 }, 'hitTest: 屏幕 → 子格坐标');
    eq(Render.hitTest({ x: -1, y: -1, zoom: 8 }, 0, 0, 500, 300), { X: 499, Y: 299 },
       '★ hitTest: 画在接缝另一侧的副本上 → 折回主网格坐标(旧实现副本不可落笔)');
    eq(Render.hitTest(view, 5000 * 8, 0, 500, 300).X, 0, '★ hitTest: 远处也折回 [0, subCols)');
    const back = Render.hitTest(view, -8, 0, 500, 300);
    ok(back.X >= 0 && back.X < 500, 'hitTest: 负的屏幕坐标也落在 [0, subCols) 内');
  })();

  // ==== 相位 ⑧ 画笔几何(规格 §4.4 的吸附规则)====
  (function () {
    eq(Render.brushSpan(1), { unit: 'cell', n: 1 }, 'brushSpan(1) = 1 格');
    eq(Render.brushSpan(3), { unit: 'cell', n: 3 }, 'brushSpan(3) = 3 格');
    eq(Render.brushSpan(15), { unit: 'cell', n: 15 }, 'brushSpan(15) = 15 格(规格的上限)');
    eq(Render.brushSpan(999), { unit: 'cell', n: 15 }, '★ brushSpan(999) 钳到 15(用户输入钳制,不报错)');
    eq(Render.brushSpan(NaN), { unit: 'cell', n: 1 }, '★ brushSpan(NaN) → 1 格(不抛、不产生 NaN 几何)');
    eq(Render.brushSpan(0), { unit: 'cell', n: 1 }, 'brushSpan(0) → 1 格');
    eq(Render.brushSpan(-3), { unit: 'cell', n: 1 }, 'brushSpan(-3) → 1 格');
    eq(Render.brushSpan(0.25), { unit: 'sub', n: 1 }, '★ brushSpan(0.25) = 1 子格');
    eq(Render.brushSpan(0.5), { unit: 'sub', n: 2 }, '★ brushSpan(0.5) = 2 子格');
    eq(Render.brushSpan(0.75), { unit: 'sub', n: 3 }, '★ brushSpan(0.75) = 3 子格');

    eq(Render.brushRegion({ kind: 'cell', x: 3, y: 4 }, 1), { unit: 'cell', x0: 3, y0: 4, x1: 3, y1: 4 },
       'brushRegion: 1 格画笔画一格(整数大小只画整格,不落在子格上)');
    eq(Render.brushRegion({ kind: 'cell', x: 3, y: 4 }, 3), { unit: 'cell', x0: 2, y0: 3, x1: 4, y1: 5 },
       'brushRegion: 3×3 以光标为中心(lo = floor((n-1)/2)、hi = ceil((n-1)/2))');
    eq(Render.brushRegion({ kind: 'sub', x: 5, y: 6 }, 1), { unit: 'sub', x0: 5, y0: 6, x1: 5, y1: 6 },
       'brushRegion: 0.25 画笔盖一个子格');
    eq(Render.brushRegion({ kind: 'sub', x: 5, y: 6 }, 3), { unit: 'sub', x0: 4, y0: 5, x1: 6, y1: 7 },
       'brushRegion: 0.75 画笔盖 3×3 子格');
    // ★ 两种单位的坐标含义不同(格 vs 子格),混用会让画笔大小整体错 4 倍 ——
    //   调用方必须看 unit 再决定是"每格填 16 子格"还是"直接就是子格"。
    eq(Render.snapHit({ X: 9, Y: 10, zoom: 8, px: 0, py: 0, kind: 'cell' }).kind, 'cell',
       'snapHit: 整数画笔吸附到格');
    eq(Render.snapHit({ X: 9, Y: 10, zoom: 8, px: 0, py: 0, kind: 'sub' }), { kind: 'sub', x: 9, y: 10 },
       'snapHit: 小数画笔吸附到子格(当前子格就是命中子格)');
  })();

  // ==== 相位 ⑨ 选区拖动:纯读的偏移查询(B3 / 规格 §4.2)====
  (function () {
    const sel = { x: 4, y: 4, w: 4, h: 4 };
    eq(Render.selectionSource(sel, 2, 0, 6, 5), { hit: true, X: 4, Y: 5 },
       'selectionSource: 目标格 (6,5) 的内容来自源格 (4,5)(drag 只记 dx/dy,渲染时纯读)');
    eq(Render.selectionSource(sel, 2, 0, 4, 4), { hit: false, X: 4, Y: 4 },
       '★ selectionSource: 目标格**不在**偏移后的选区里 → hit:false(源区自己已被腾空)');
    eq(Render.selectionSource(sel, -100, 0, 6, 5).hit, false, '★ 偏移可以很大,查询照样不越界');
    eq(Render.selectionSource(sel, 0, 0, 5, 5), { hit: true, X: 5, Y: 5 }, 'dx=dy=0 时是恒等查询');
    eq(Render.rectUnion({ x: 1, y: 1, w: 2, h: 2 }, { x: 4, y: 0, w: 1, h: 1 }), { x: 1, y: 0, w: 4, h: 3 },
       'rectUnion: 脏区合并(缩略图/离屏层按它重画)');
  })();

  console.log('');
  console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
  if (fail === 0) console.log('RENDER SMOKE OK');
  process.exit(fail === 0 ? 0 : 1);
  });
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node render_smoke.js`

Expected: 进程在 `require('./render.js')` 处死掉 —— `Error: Cannot find module './render.js'`,退出码 1。

- [ ] **Step 3: 实现 `render.js`(纯半边)**

新建 `level_editor/render.js`:

```js
// render.js —— 画布渲染 + 四层缓存 + 脏区(规格 §4.2;闸 2 见 §4.3)。
//
// ★★ 本文件的**顶层一行都不碰 DOM**:DOM 只出现在 Task 3/4 加进来的 mount() 一族里。
//    于是 node 能 require 它,把"错了也不报错、只在屏幕上看出来"的那几层逐条断言 ——
//    缓存 ③ 的失效、空层、空气短路、环面命中、画笔几何、单帧预算。
// ★ 依赖顺序:core.js → tint.js → render.js(tint 要 Core,render 要两者)。
// ★ 规格 §4.2 的四层缓存:① 地图缩略图(每层一张)② 视口离屏层 ③ 格位图缓存 ④ tinted-tile。
//    ④ 住在 tint.js 里(它自己的 8192 张上限),本文件只负责**在换图时同时作废 ③ 与 ④**。
globalThis.Render = (function () {
  'use strict';

  var Core = globalThis.Core, Tint = globalThis.Tint;
  if (!Core) throw new Error('render.js: 必须先加载 core.js');
  if (!Tint) throw new Error('render.js: 必须先加载 tint.js');

  var SUB = Core.SUB_PER_CELL;

  var MIN_ZOOM = 1, MAX_ZOOM = 64;              // px / 子格
  var ZOOM_THRESHOLD = 8;                       // 规格 §4.2 的分工阈:< 8 走缩略图,≥ 8 走离屏层
  var THUMB_PX = 2;                             // 缩略图 2px/子格(规格 §4.2 ①)
  var THUMB_MAX_BYTES = 24 * 1024 * 1024;       // 超过就降到 1px/子格(400×300 格 @2px = 30MB,偏大)
  var DEFAULT_BUDGET_MS = 8;                    // 闸 2 的单帧 CPU 预算
  // ③ 的条目上限。条目 = **16 个 tile 引用**(不是 64×64 的 canvas),约 128 字节,
  // 8192 条 ≈ 1MB —— 而像素本身只存在 ④ 里,由它自己的上限管。
  // (若把"合成好的 64×64 canvas"存进来,一屏 925 格就是 15MB,缓存比工作集还小 = 没缓存。)
  var DEFAULT_CELL_MAX = 8192;

  // ── 环面折算 ──
  // ★ 两处都要它:格/子格坐标的读取,与象限坐标(quadOf)。负数在环面世界里是常态
  //   (视图越过接缝、选区拖动),而 `%` 对负数返回负数。
  function wrapIdx(v, n) { return v - Math.floor(v / n) * n; }
  function quadOf(v) { return wrapIdx(v, SUB); }        // 恒在 0..SUB-1(否则 Tint 会抛)

  // ── 图层读取(缺席层 = 全空气)──
  // ★ 规格 §2.4 的 createMap 恒建四层,而 layer_flags 允许某个层**不存在** ⇒ 解码出来的
  //   map.layers[L] 可以是 null(null = 全空气,不是"错误")。渲染路径上任何地方
  //   直接摸 map.layers[L].desc 都会在"打开一个缺层的文件"时当场炸。
  function layerArray(map, L) {
    var lay = map.layers[L];
    if (!lay) return null;
    return lay.kind === 'tex' ? lay.desc : lay.rgba;
  }
  function descAt(map, L, X, Y) {
    var a = layerArray(map, L);
    if (!a) return 0;
    return a[wrapIdx(Y, map.subRows) * map.subCols + wrapIdx(X, map.subCols)];
  }
  function rgbaAt(map, X, Y) {
    var a = layerArray(map, Core.LAYER_BG);
    if (!a) return 0;
    return a[wrapIdx(Y, map.subRows) * map.subCols + wrapIdx(X, map.subCols)];
  }

  // ── 贴图源与 ④(换图 = 两层一起作废)──
  var atlasPixels = null, atlasW = 0, atlasH = 0;
  var tiles = null;                              // ④:惰性建(见 tileCache())
  var cells = null;                              // ③:由 attachCells 装上(Task 4 的 mount 装它)

  function tileCache() { if (!tiles) tiles = Tint.createTileCache(); return tiles; }
  // 装上 ③。★ 做成显式的 attach 而不是"createCellCache 顺手写进模块变量":
  //   后者会让"谁最后建的谁生效",而 ③ 的作废是**必须由 setAtlas 触发**的一条不变量。
  function attachCells(cache) { cells = cache; return cells; }
  function cellCache() { return cells; }

  // ★ 唯一的换图入口。它必须**同时**作废 ③ 与 ④ —— 这一条是账本点名带进计划 2b 的
  //   不变量(规格 §4.2 的 ③ 与 ④ 是两层,换图是它们共同的失效事件)。
  //   ④ 那一侧由 Tint.setSource 自己做;③ 这一侧漏了的话,它会继续交出"用旧图集算出来、
  //   内容版本却没变"的格位图 ⇒ 审计 A2 在上一层原样复发(整张图是色块,"有时好有时坏",
  //   不报错)。★ 顺序是"先让 Tint 校验形状、再作废" —— 形状非法时 Tint.setSource 抛错,
  //   此时两层都还是旧的(而不是"作废了一半")。
  // ★ opts.backend 是给 node 冒烟用的注入缝(与 tint.js 的注入式画布同一个先例):
  //   传它就换一个新的 ④,于是"空气到底有没有进 Tint"能被**记账**而不是靠肉眼。
  function setAtlas(pixels, w, h, opts) {
    if (opts && opts.backend) tiles = Tint.createTileCache({ backend: opts.backend });
    tileCache().setSource(pixels, w);
    atlasPixels = pixels; atlasW = w | 0; atlasH = h | 0;
    if (cells) cells.setSource();
  }
  function atlasInfo() { return atlasPixels ? { width: atlasW, height: atlasH } : null; }
  // ★ 图纸容量 = 列 × 行(320×320 的图集 = 100 块)。**不是**描述符位宽 4095 ——
  //   tint 的越界判据就是"图集里有没有这一块",拿 4095 当上界 ⇒ 101~4095 全部抛。
  function atlasCapacity() { return atlasW > 0 ? Math.floor(atlasW / Tint.BLOCK_PX) * Math.floor(atlasH / Tint.BLOCK_PX) : 0; }

  // 取一张 16×16 小图。**唯一**该调 Tint.get 的地方。
  // ★★ desc === 0(空气)必须在**进 Tint 之前**短路:空气是地图数据里最常见的一格,
  //    而 Tint.get → buildTilePixels 对空气**会抛**(I4 契约)—— 渲染循环漏了这句,
  //    第一帧就抛、而且每帧都在同一处抛。
  // ★ 纹理实参**从 desc 推导**(不另传):账本 Task 5 的遗留是"实参与 texOf(desc) 不一致时
  //   buildTilePixels 会静默画另一块砖";从 desc 推导让不一致**不可能发生**。
  function tileFor(desc, qx, qy) {
    if (desc === 0) return null;
    var tex = Core.texOf(desc);
    if (tex === 0) return null;                  // 畸形描述符(辅码非 0、纹理 0)= 空气
    return tileCache().get(tex, quadOf(qx), quadOf(qy), desc);
  }

  // ── ③ 格位图缓存(规格 §4.2 ③)──
  // 缓存的是"这一格的 16 个子格**各用哪张 tile**",不是像素 —— 像素只存在 ④ 里。
  // ★★ 两条**独立**的失效轴,必须都判:
  //    ① 内容版本号(touch):编辑某格 → 该格版本 +1 → 下次只重建这一格;
  //    ② 代际(gen,由 setSource 递增):换贴图源之后,即便内容一个字没改,
  //       旧的 tile 也已作废 —— 只判 ① 的话这里会交出**上一张图集**算出来的 tile,
  //       症状与审计 A2 一模一样(整张图是色块,"有时好有时坏",不报错)。
  function createCellCache(opts) {
    opts = opts || {};
    var maxCells = opts.maxCells === undefined ? DEFAULT_CELL_MAX : opts.maxCells;
    var build = opts.build;
    if (typeof build !== 'function') throw new Error('createCellCache: 缺 build 回调');
    var ver = new Map();                         // 内容版本号
    var entries = new Map();                     // 键 -> {v, gen, tile}
    var gen = 0, hits = 0, misses = 0, evictions = 0;

    function key(L, cx, cy) { return L + '/' + cx + '/' + cy; }
    function version(L, cx, cy) { var v = ver.get(key(L, cx, cy)); return v === undefined ? 0 : v; }
    function touch(L, cx, cy) { ver.set(key(L, cx, cy), version(L, cx, cy) + 1); }
    // ★★ ③ 的作废。规格 §4.2 ③ 的"内容版本号"说的是轴 ①;换图是轴 ②。
    function setSource() { gen++; entries.clear(); }
    function get(L, cx, cy) {
      var k = key(L, cx, cy);
      var v = version(L, cx, cy);
      var e = entries.get(k);
      if (e !== undefined && e.v === v && e.gen === gen) {
        hits++;
        entries.delete(k); entries.set(k, e);    // 命中提到最近端(Map 的插入序 = LRU 序)
        return e.tile;
      }
      misses++;
      var tile = build(L, cx, cy);
      entries.set(k, { v: v, gen: gen, tile: tile });
      while (entries.size > maxCells) { entries.delete(entries.keys().next().value); evictions++; }
      return tile;
    }
    function clear() { entries.clear(); }
    function stats() {
      return { hits: hits, misses: misses, evictions: evictions,
               size: entries.size, maxCells: maxCells, generation: gen };
    }
    return { version: version, touch: touch, setSource: setSource,
             get: get, clear: clear, stats: stats };
  }

  // ── 闸 2:单帧预算的时间切片器(规格 §4.3)──
  // ★ 分帧是"慢慢画出来",不是"页面死掉"。注入 now/nextFrame 是为了在 node 里
  //   确定性地断言"确实切了、且单帧真的没超预算"(真 rAF 在 node 里不存在)。
  // ★ 「每帧至少做一项」是必须的:否则 budgetMs = 0 时循环会一项不做就让出、
  //   让出之后又一项不做 —— 死循环(而 0 是合法的注入值,测试就在用它)。
  function createSlicer(opts) {
    opts = opts || {};
    var budget = opts.budgetMs === undefined ? DEFAULT_BUDGET_MS : opts.budgetMs;
    var now = opts.now || function () {
      return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
    };
    var nextFrame = opts.nextFrame || function () {
      return new Promise(function (r) { requestAnimationFrame(function () { r(); }); });
    };
    function run(items, fn) {
      var i = 0, frames = 0, maxStep = 0;
      return new Promise(function (resolve) {
        function step() {
          var s0 = now();
          while (i < items.length) {
            fn(items[i], i); i++;
            // ★ 判在**做完之后**:预算是软的(到手一项就做完它),但一格都不许超。
            if (now() - s0 >= budget) break;
          }
          var d = now() - s0;
          if (d > maxStep) maxStep = d;
          if (i >= items.length) { resolve({ frames: frames, processed: i, maxStepMs: maxStep }); return; }
          frames++;
          // ★ 时间基准在**让出之后**重新取:让出一帧自己也花时间,把那段算进下一帧的
          //   预算里会让"下一帧刚做一项就又超预算"—— 分帧退化成逐项让出。
          nextFrame().then(step);
        }
        step();
      });
    }
    return { run: run, budgetMs: budget };
  }

  // ── 缩放与适配 ──
  function zoomPath(pxPerSub) { return pxPerSub < ZOOM_THRESHOLD ? 'thumb' : 'layers'; }
  function clampZoom(z) {
    if (!isFinite(z) || z <= 0) return MIN_ZOOM;   // 用户输入钳制,不报错回滚
    return Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, z));
  }
  function fitZoom(subCols, subRows, viewW, viewH, pad) {
    var p = pad === undefined ? 8 : pad;
    var zx = (viewW - 2 * p) / subCols, zy = (viewH - 2 * p) / subRows;
    return clampZoom(Math.min(zx, zy));
  }
  function thumbScale(subCols, subRows) {
    var bytes = subCols * THUMB_PX * subRows * THUMB_PX * 4;
    return bytes > THUMB_MAX_BYTES ? 1 : THUMB_PX;
  }

  // ── 可见区裁剪(B8:网格线/spawn 标记/边框不做裁剪 = 每次重画整张图)──
  // ★ 返回的是**未折算**的坐标(3×3 副本要的正是它):调用方按格自己 wrapIdx。
  function visibleSubRange(view, viewW, viewH, subCols, subRows) {
    var x0 = Math.floor(view.x), y0 = Math.floor(view.y);
    var x1 = Math.ceil(view.x + viewW / view.zoom), y1 = Math.ceil(view.y + viewH / view.zoom);
    return { x0: x0, y0: y0, x1: x1, y1: y1 };
  }

  // ── 环面 3×3:A4 说旧实现只铺 [0,1]、少一侧,且副本上不能落笔 ──
  // ★ 返回"与视口相交"的那些副本偏移(最多 3×3 = 9 份,通常 1 份)——
  //   无脑铺 9 份是 9 倍开销,而屏幕上绝大多数时候只看得到一份。
  function intersects(a0, a1, b0, b1) { return a1 > b0 && a0 < b1; }
  function torusOffsets(view, viewW, viewH, mapW, mapH) {
    var r = visibleSubRange(view, viewW, viewH, mapW, mapH);
    var out = [];
    for (var ky = -1; ky <= 1; ky++) {
      var lo = ky * mapH, hi = lo + mapH;
      if (!intersects(r.y0, r.y1, lo, hi)) continue;
      for (var kx = -1; kx <= 1; kx++) {
        var lox = kx * mapW, hix = lox + mapW;
        if (!intersects(r.x0, r.x1, lox, hix)) continue;
        out.push([lox, lo]);
      }
    }
    return out;
  }

  // 屏幕 → 子格(折算回主网格)。★ 副本上落笔靠的就是这一步:无论点在哪个副本上,
  // 结果都落在 [0, subCols) 里。
  function hitTest(view, px, py, subCols, subRows) {
    var X = Math.floor(view.x + px / view.zoom);
    var Y = Math.floor(view.y + py / view.zoom);
    return { X: wrapIdx(X, subCols), Y: wrapIdx(Y, subRows) };
  }

  // ── 画笔几何(规格 §4.4 的吸附规则)──
  // 单位仍是 64px 格,输入步进 0.25:
  //   整数大小 → 只画**整格**,吸附到 64px 格边界;
  //   小数(0.25/0.5/0.75)→ 画**子格**,吸附到 16px 子格边界(0.25=1 子格、0.5=2、0.75=3)。
  var MAX_BRUSH_CELLS = 15;
  function brushSpan(size) {
    var s = (typeof size === 'number' && isFinite(size)) ? size : 1;
    if (s <= 0) s = 1;
    if (Math.floor(s) === s) return { unit: 'cell', n: Math.max(1, Math.min(MAX_BRUSH_CELLS, s)) };
    var n = Math.round(s * SUB);                 // 0.25→1、0.5→2、0.75→3、2.5→10
    return { unit: 'sub', n: Math.max(1, Math.min(MAX_BRUSH_CELLS * SUB, n)) };
  }
  function brushRegion(hit, size) {
    var sp = brushSpan(size);
    var c = (typeof hit === 'object' && hit) ? hit : {};
    var x = Math.floor(isFinite(c.x) ? c.x : 0);
    var y = Math.floor(isFinite(c.y) ? c.y : 0);
    var lo = Math.floor((sp.n - 1) / 2), hi = Math.ceil((sp.n - 1) / 2);
    return { unit: sp.unit, x0: x - lo, y0: y - lo, x1: x + hi, y1: y + hi };
  }
  function snapHit(h) {
    if (h.kind === 'sub') return { kind: 'sub', x: Math.floor(h.X), y: Math.floor(h.Y) };
    return { kind: 'cell', x: Math.floor(h.X), y: Math.floor(h.Y) };
  }

  // ── 选区拖动:纯读的偏移查询(B3;规格 §4.2「拖动只记 dx/dy,松手才提交」)──
  function selectionSource(sel, dx, dy, X, Y) {
    var sx = X - dx, sy = Y - dy;
    if (sx >= sel.x && sx < sel.x + sel.w && sy >= sel.y && sy < sel.y + sel.h) {
      return { hit: true, X: sx, Y: sy };
    }
    return { hit: false, X: X, Y: Y };
  }

  // ── 脏区 ──
  function rectUnion(a, b) {
    if (!a) return { x: b.x, y: b.y, w: b.w, h: b.h };
    if (!b) return { x: a.x, y: a.y, w: a.w, h: a.h };
    var x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
    var x2 = Math.max(a.x + a.w, b.x + b.w), y2 = Math.max(a.y + a.h, b.y + b.h);
    return { x: x, y: y, w: x2 - x, h: y2 - y };
  }
  function rectIsEmpty(r) { return !r || r.w <= 0 || r.h <= 0; }

  return {
    MIN_ZOOM: MIN_ZOOM, MAX_ZOOM: MAX_ZOOM, ZOOM_THRESHOLD: ZOOM_THRESHOLD,
    THUMB_PX: THUMB_PX, THUMB_MAX_BYTES: THUMB_MAX_BYTES,
    DEFAULT_BUDGET_MS: DEFAULT_BUDGET_MS, DEFAULT_CELL_MAX: DEFAULT_CELL_MAX,
    wrapIdx: wrapIdx, quadOf: quadOf,
    layerArray: layerArray, descAt: descAt, rgbaAt: rgbaAt,
    setAtlas: setAtlas, atlasInfo: atlasInfo, atlasCapacity: atlasCapacity, tileCache: tileCache,
    attachCells: attachCells, cellCache: cellCache,
    tileFor: tileFor,
    createCellCache: createCellCache,
    createSlicer: createSlicer,
    zoomPath: zoomPath, clampZoom: clampZoom, fitZoom: fitZoom, thumbScale: thumbScale,
    visibleSubRange: visibleSubRange, torusOffsets: torusOffsets, hitTest: hitTest,
    MAX_BRUSH_CELLS: MAX_BRUSH_CELLS, brushSpan: brushSpan, brushRegion: brushRegion, snapHit: snapHit,
    selectionSource: selectionSource, rectUnion: rectUnion, rectIsEmpty: rectIsEmpty,
  };
})();
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node render_smoke.js`

Expected: 全部 `ok -`,末行 `RENDER SMOKE OK`,退出码 0。

- [ ] **Step 5: 变异验证(证明 ③ 的作废断言不是空转)**

把 `createCellCache` 的 `get` 里这一句删掉(只删 `e.gen === gen`,保留 `e.v === v`):

```js
      if (e !== undefined && e.v === v && e.gen === gen) {
```

改成:

```js
      if (e !== undefined && e.v === v) {
```

Run: `cd level_editor && node render_smoke.js`

Expected: 相位 ③b 至少三条报红 ——

```
  FAIL - ★★ 换图之后 ③ 被清空(漏了这一句 = A2 在上一层复发)
  FAIL - ★★ 换图之后同一个格键**是新对象**(调用方不得跨换图持有格位图)
  FAIL - ★★ 换图之后同一块小图也是新对象(调用方不得跨换图持有 tile)
```

退出码 1。**确认之后把那一行改回来**,再跑一次确认恢复全绿。这条变异的含义:它模拟的正是审计 A2 在老编辑器里的形态("贴图换了,缓存却还新鲜")—— 把它原样搬到第三层缓存上,只有专门为"代际"写的那几条断言抓得住。

- [ ] **Step 6: 确认三个既有冒烟一个都没动**

Run: `cd level_editor && node smoke.js && node tint_smoke.js && node server_smoke.js`

Expected: `SMOKE OK` / `TINT SMOKE OK` / `SERVER SMOKE OK`,退出码 0。

- [ ] **Step 7: 提交**

```bash
git add level_editor/render.js level_editor/render_smoke.js
git commit -F - <<'EOF'
feat(editor): render.js 纯半边 —— 四层缓存内核 + 环面 + 画笔几何 + 闸 2 分帧

顶层一行不碰 DOM(DOM 在 Task 3/4 的 mount 里),于是 node 能把"错了也不报错、
只在屏幕上看出来"的那几层逐条断言:空层=全空气、空气绝不进 Tint、
环面折算(含负数)、3×3 只铺与视口相交的副本、命中折回主网格、画笔吸附、
选区拖动的纯读偏移查询、单帧预算分帧器。

★★ ③ 格位图缓存有**两条独立的失效轴**:内容版本号(touch)与代际(setSource)。
只判前者的话,换贴图后 ③ 会继续交出"用旧图集算出来、内容却没变"的格位图 ——
审计 A2 在上一层原样复发(整张图是色块,"有时好有时坏",不报错)。
smoke 里有一条专门钉它(变异:去掉 gen 比较 → 两条红)。

③ 缓存的是 16 个 tile 引用而不是 64×64 canvas:像素只存在 ④ 里(由它的 8192 张
上限管),条目约 128 字节 ⇒ 8192 条 ≈ 1MB;存合成 canvas 则一屏 925 格就 15MB,
缓存比工作集还小等于没缓存。
EOF
```

---

## Task 3: `editor.html` 真页面 + 首帧渲染 + 敌人注册表迁移(三件事同一 commit)

**Files:**
- Modify: `level_editor/render.js`(加 `mount()` 一族:**① 缩略图 + 两条路径的朴素实现**)
- Create: `level_editor/ui.js`(`Editor.boot()` 最小版:图集加载 / 库列表 / 打开地图 / 挂载渲染 / 状态栏 / `guard` / `selfTest`)
- Modify: `level_editor/editor.html`(**整体重写**:§4.5 的 DOM + `<script src>` + 敌人注册表标记块)
- Modify: `level_editor/sync-enemies.js`(`htmlPath` → `editor.html`)
- Delete: `level_editor/structure-editor.html`(**与上面三件同一 commit**)
- Modify: `level_editor/server_smoke.js`(改写相位 ①b 与 ⑧)

**Interfaces:**
- Consumes:Task 1 的 `Io.*`、Task 2 的 `Render.*`
- Produces:
  - `Render.mount(canvas, opts) -> renderer`:
    - `setMap(map) -> void`、`map() -> Object|null`
    - `setLayer(L) -> void`、`layer() -> Number`
    - `setView({x, y, zoom}) -> void`、`view() -> {x,y,zoom}`
    - `setGrid(Boolean)` / `setSubGrid(Boolean)` / `setTorus(Boolean)` / `setDimOthers(Boolean)`
    - `setLayerVisible(L, Boolean)` / `setLayerLocked(L, Boolean)` / `setSelection(sel|null)`
    - `render() -> void`(**唯一渲染入口**)、`resize() -> void`、`fit() -> void`
    - `invalidateCells(L, list) -> void`(`list` 为 `[{cx,cy}]`,重画受影响的缩略图矩形)
    - `invalidateAll() -> void`
    - `thumbCanvas(L) -> HTMLCanvasElement|null`
    - `screenToSub(px, py) -> {X,Y}`(折算过的子格坐标)、`subToScreen(X, Y) -> {x,y}`
    - `stats() -> {thumbMs, renders, lastRenderMs, thumbsBuilt}`
  - `globalThis.Editor`:
    - `boot() -> void`(页面唯一的入口,`DOMContentLoaded` 之后由页面调用)
    - `guard(label, fn) -> any`(执行并捕获,异常写进状态栏 `#status-msg`)
    - `status(msg) -> void`
    - `nameFromFile(fileName) -> String`
    - `detectFormat(bytes) -> 'v4'|'v3'|'legacy'`
    - `mapFromBytes(fileName, bytes) -> Promise<{map, sourceFormat}>`
    - `selfTest() -> Promise<String>`(返回一行机器可判的结论:`SELFTEST OK` 或 `SELFTEST FAIL: …`)
    - `openFromUrl() -> Promise<void>`
    - `rawBytes() -> Uint8Array|null` / `rawName() -> String|null` / `sourceFormat() -> String|null`

- [ ] **Step 1: 在 `render.js` 末尾(`return { … }` 之前)加 `mount()` 一族**

在 `render.js` 的 `selectionSource` 之后插入:

```js
  // ── 图层绘制顺序 ──
  // 前景(0)是"从外到内"的第一层 ⇒ **最后**画(盖在最上面);背景(3)最先画。
  var DRAW_ORDER = [3, 2, 1, 0];

  // ── 画布挂载(规格 §4.2)──
  // ★ T3 这一版是**朴素**的:缩略图路径走 ①(每层一张、按脏矩形更新),
  //   而 ≥ 8 px/子格 的路径逐子格 drawImage(旧编辑器的 B2 做法,能看但慢)。
  //   Task 4 把后者换成 ② 视口离屏层 + ③ 格位图缓存 + 脏区 + 3×3。
  function mount(canvas, opts) {
    opts = opts || {};
    var ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = false;      // ★ 审计 A5:主 ctx 不关插值 ⇒ 放大后砖块是糊的
    var s = {
      map: null, layer: Core.LAYER_SCENE,
      view: { x: 0, y: 0, zoom: 8 },
      grid: true, subGrid: false, torus: true, dimOthers: true,
      layerVisible: [true, true, true, true],
      layerLocked: [false, false, false, false],
      selection: null,
    };
    var thumbs = [null, null, null, null];
    var thumbPx = THUMB_PX;
    var slicer = createSlicer({});
    var stat = { thumbMs: 0, renders: 0, lastRenderMs: 0, thumbsBuilt: 0 };

    function ensureThumbs(map) {
      var px = thumbScale(map.subCols, map.subRows);
      if (thumbs[0] && thumbPx === px && thumbs[0].width === map.subCols * px) return false;
      thumbPx = px;
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        thumbs[L] = document.createElement('canvas');
        thumbs[L].width = map.subCols * px;
        thumbs[L].height = map.subRows * px;
        var c = thumbs[L].getContext('2d');
        c.imageSmoothingEnabled = false;
      }
      return true;
    }

    // 画缩略图的一块矩形(单位 = 子格;rect 由调用方保证在图内)
    // ★ 逐子格 drawImage / fillRect 是这里唯一的成本(默认图 15 万次),所以缩略图**总是**
    //   经分帧器建(闸 2):大图上是"慢慢画出来",不是"页面死掉"。
    function paintThumbRect(L, rect) {
      var tc = thumbs[L] && thumbs[L].getContext('2d');
      if (!tc) return;
      var px = thumbPx;
      for (var Y = rect.y; Y < rect.y + rect.h; Y++) {
        for (var X = rect.x; X < rect.x + rect.w; X++) {
          var raw = descAt(s.map, L, X, Y);
          if (raw === 0 || Core.texOf(raw) === 0) { tc.clearRect(X * px, Y * px, px, px); continue; }
          if (L === Core.LAYER_BG) {
            tc.fillStyle = cssOfRGBA(raw);
            tc.fillRect(X * px, Y * px, px, px);
          } else {
            var t = tileFor(raw, X, Y);
            if (t) tc.drawImage(t, X * px, Y * px, px, px);
          }
        }
      }
    }

    // 把一整层的缩略图切成"每 8 行一组"的任务交给分帧器
    function thumbTasks(map) {
      var tasks = [], rows = 8;
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        if (!layerArray(map, L)) continue;             // 缺席层不画(全空气)
        for (var y = 0; y < map.subRows; y += rows) {
          tasks.push({ L: L, rect: { x: 0, y: y, w: map.subCols, h: Math.min(rows, map.subRows - y) } });
        }
      }
      return tasks;
    }

    function buildThumbs() {
      if (!s.map) return Promise.resolve();
      var t0 = (typeof performance !== 'undefined' ? performance.now() : Date.now());
      var tasks = thumbTasks(s.map);
      stat.thumbsBuilt++;
      return slicer.run(tasks, function (t) { paintThumbRect(t.L, t.rect); }).then(function () {
        stat.thumbMs = (typeof performance !== 'undefined' ? performance.now() : Date.now()) - t0;
      });
    }

    function cssOfRGBA(v) {
      var u = v >>> 0;
      return 'rgba(' + ((u >>> 24) & 255) + ',' + ((u >>> 16) & 255) + ',' +
             ((u >>> 8) & 255) + ',' + ((u & 255) / 255) + ')';
    }

    // ★ 用鼠标坐标算世界坐标的两个方向:命中(C15 子格级)与反算(画 spawn 标记)
    function screenToSub(px, py) {
      return hitTest(s.view, px, py, s.map.subCols, s.map.subRows);
    }
    function subToScreen(X, Y) {
      return { x: (X - s.view.x) * s.view.zoom, y: (Y - s.view.y) * s.view.zoom };
    }

    function torusList(W, H) {
      if (!s.torus) return [[0, 0]];
      return torusOffsets(s.view, W, H, s.map.subCols, s.map.subRows);
    }

    // 路径一:< 8 px/子格 → 一次 drawImage 顶掉几十万次(规格 §4.2 ①)
    function drawThumbPath(W, H) {
      var px = thumbPx;
      var scale = s.view.zoom / px;                  // 缩略图像素 → 屏幕像素
      var offs = torusList(W, H), i, L;
      for (i = 0; i < offs.length; i++) {
        for (var oi = 0; oi < DRAW_ORDER.length; oi++) {
          L = DRAW_ORDER[oi];
          if (!s.layerVisible[L] || !thumbs[L]) continue;
          ctx.globalAlpha = (s.dimOthers && L !== s.layer && L !== Core.LAYER_BG) ? 0.4 : 1;
          ctx.drawImage(thumbs[L],
                        (offs[i][0] - s.view.x) * s.view.zoom,
                        (offs[i][1] - s.view.y) * s.view.zoom,
                        s.map.subCols * px * scale, s.map.subRows * px * scale);
        }
      }
      ctx.globalAlpha = 1;
    }

    // 路径二:≥ 8 px/子格 → 逐子格(Task 4 换成 ② + ③ + 脏区)
    function drawLayerPath(W, H) {
      var r = visibleSubRange(s.view, W, H, s.map.subCols, s.map.subRows);
      var offs = torusList(W, H);
      for (var oi = 0; oi < DRAW_ORDER.length; oi++) {
        var L = DRAW_ORDER[oi];
        if (!s.layerVisible[L]) continue;
        ctx.globalAlpha = (s.dimOthers && L !== s.layer && L !== Core.LAYER_BG) ? 0.4 : 1;
        for (var i = 0; i < offs.length; i++) {
          var dx = offs[i][0], dy = offs[i][1];
          var x0 = Math.max(r.x0, dx), x1 = Math.min(r.x1, dx + s.map.subCols);
          var y0 = Math.max(r.y0, dy), y1 = Math.min(r.y1, dy + s.map.subRows);
          for (var Y = y0; Y < y1; Y++) {
            for (var X = x0; X < x1; X++) {
              // ★ 副本坐标折回主网格后再读(所以副本上也能落笔、也画得对)
              var raw = descAt(s.map, L, X - dx, Y - dy);
              if (raw === 0 || Core.texOf(raw) === 0) continue;
              var p = subToScreen(X, Y);
              if (L === Core.LAYER_BG) {
                ctx.fillStyle = cssOfRGBA(raw);
                ctx.fillRect(p.x, p.y, s.view.zoom, s.view.zoom);
              } else {
                var t = tileFor(raw, X - dx, Y - dy);
                if (t) ctx.drawImage(t, p.x, p.y, s.view.zoom, s.view.zoom);
              }
            }
          }
        }
      }
      ctx.globalAlpha = 1;
    }

    // 网格线:格线恒画,子格线只在 zoom ≥ 8 时画(C15)
    // ★ 只画可见区(B8:不裁剪 = 每次重画整张图的线)
    function drawGrid(W, H) {
      var r = visibleSubRange(s.view, W, H, s.map.subCols, s.map.subRows);
      var z = s.view.zoom;
      ctx.lineWidth = 1;
      ctx.strokeStyle = 'rgba(255,255,255,0.16)';
      ctx.beginPath();
      if (s.subGrid && z >= 4) {
        for (var X = Math.floor(r.x0 / 1); X <= r.x1; X++) {
          var sx = Math.round((X - s.view.x) * z) + 0.5;
          if (sx < -1 || sx > W + 1) continue;
          ctx.moveTo(sx, 0); ctx.lineTo(sx, H);
        }
        for (var Y = r.y0; Y <= r.y1; Y++) {
          var sy = Math.round((Y - s.view.y) * z) + 0.5;
          if (sy < -1 || sy > H + 1) continue;
          ctx.moveTo(0, sy); ctx.lineTo(W, sy);
        }
      }
      ctx.stroke();
      // 格线(64px = 4 个子格)
      ctx.strokeStyle = 'rgba(255,255,255,0.30)';
      ctx.beginPath();
      for (var X2 = Math.floor(r.x0 / SUB) * SUB; X2 <= r.x1; X2 += SUB) {
        var sx2 = Math.round((X2 - s.view.x) * z) + 0.5;
        if (sx2 < -1 || sx2 > W + 1) continue;
        ctx.moveTo(sx2, 0); ctx.lineTo(sx2, H);
      }
      for (var Y2 = Math.floor(r.y0 / SUB) * SUB; Y2 <= r.y1; Y2 += SUB) {
        var sy2 = Math.round((Y2 - s.view.y) * z) + 0.5;
        if (sy2 < -1 || sy2 > H + 1) continue;
        ctx.moveTo(0, sy2); ctx.lineTo(W, sy2);
      }
      ctx.stroke();
    }

    // spawn 标记 + 选区框。★ 字体/对齐**设一次**(B8:每标记重设 font 是排版最贵的一项)。
    function drawOverlay(W, H) {
      if (!s.map) return;
      ctx.save();
      ctx.font = '12px Consolas, monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      var offs = torusList(W, H);
      var mark = function (cellX, cellY, color, label) {
        for (var i = 0; i < offs.length; i++) {
          var X = cellX * SUB - offs[i][0], Y = cellY * SUB - offs[i][1];
          var p = subToScreen(X, Y);
          if (p.x < -64 || p.y < -64 || p.x > W + 64 || p.y > H + 64) continue;
          ctx.fillStyle = color;
          ctx.globalAlpha = 0.75;
          ctx.fillRect(p.x, p.y, 4 * s.view.zoom, 4 * s.view.zoom);
          ctx.globalAlpha = 1;
          ctx.fillStyle = '#000';
          ctx.fillText(label, p.x + 2 * s.view.zoom, p.y + 2 * s.view.zoom);
        }
      };
      for (var i = 0; i < s.map.players.length; i++) {
        mark(s.map.players[i].x, s.map.players[i].y, '#54a0ff', 'P' + (i + 1));
      }
      for (var j = 0; j < s.map.enemies.length; j++) {
        mark(s.map.enemies[j].x, s.map.enemies[j].y, '#c96fb0', 'E');
      }
      if (s.selection) {
        var a = subToScreen(s.selection.x, s.selection.y);
        ctx.strokeStyle = '#e0b34a';
        ctx.lineWidth = 2;
        ctx.strokeRect(a.x, a.y, s.selection.w * s.view.zoom, s.selection.h * s.view.zoom);
      }
      ctx.restore();
    }

    // ★ 唯一渲染入口(B6:旧实现同一帧连画两次画布)
    function render() {
      if (!s.map) return;
      var W = canvas.width, H = canvas.height;
      var t0 = (typeof performance !== 'undefined' ? performance.now() : Date.now());
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.globalAlpha = 1;
      ctx.fillStyle = '#0e1013';
      ctx.fillRect(0, 0, W, H);
      if (zoomPath(s.view.zoom) === 'thumb') drawThumbPath(W, H); else drawLayerPath(W, H);
      if (s.grid) drawGrid(W, H);
      drawOverlay(W, H);
      stat.renders++;
      stat.lastRenderMs = (typeof performance !== 'undefined' ? performance.now() : Date.now()) - t0;
    }

    // 尺寸变化:**只有一个机制**(B7:ResizeObserver 与 window.resize 同时挂 = 每次 resize 建两遍)
    function resize() {
      var wrap = canvas.parentElement;
      var w = Math.max(1, wrap ? wrap.clientWidth : canvas.width);
      var h = Math.max(1, wrap ? wrap.clientHeight : canvas.height);
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w; canvas.height = h;
        ctx.imageSmoothingEnabled = false;            // ★ 改尺寸会重置 ctx 状态,必须重设
        render();
      }
    }

    function fit() {
      if (!s.map) return;
      s.view.zoom = fitZoom(s.map.subCols, s.map.subRows, canvas.width, canvas.height, 24);
      s.view.x = -(canvas.width / s.view.zoom - s.map.subCols) / 2;
      s.view.y = -(canvas.height / s.view.zoom - s.map.subRows) / 2;
      render();
    }

    // 编辑某几个格之后:重画它们的缩略图块(Uint32Array 的下标 → 格坐标)
    function invalidateCells(L, list) {
      if (!s.map) return null;
      var rect = null;
      for (var i = 0; i < list.length; i++) {
        var r = { x: list[i].cx * SUB, y: list[i].cy * SUB, w: SUB, h: SUB };
        rect = rectUnion(rect, r);
      }
      if (!rect) return null;
      if (thumbs[L]) paintThumbRect(L, rect);
      return rect;
    }
    function invalidateAll() {
      if (!s.map) return Promise.resolve();
      return buildThumbs().then(render);
    }

    function setMap(map) {
      s.map = map;
      s.selection = null;
      ensureThumbs(map);
      return buildThumbs().then(function () {
        s.view.zoom = fitZoom(map.subCols, map.subRows, canvas.width, canvas.height, 24);
        s.view.x = -(canvas.width / s.view.zoom - map.subCols) / 2;
        s.view.y = -(canvas.height / s.view.zoom - map.subRows) / 2;
        render();
      });
    }

    return {
      setMap: setMap, map: function () { return s.map; },
      setLayer: function (L) { s.layer = L; render(); }, layer: function () { return s.layer; },
      setView: function (v) {
        s.view.x = v.x; s.view.y = v.y;
        s.view.zoom = clampZoom(v.zoom === undefined ? s.view.zoom : v.zoom);
        render();
      },
      view: function () { return { x: s.view.x, y: s.view.y, zoom: s.view.zoom }; },
      setGrid: function (b) { s.grid = !!b; render(); },
      setSubGrid: function (b) { s.subGrid = !!b; render(); },
      setTorus: function (b) { s.torus = !!b; render(); },
      setDimOthers: function (b) { s.dimOthers = !!b; render(); },
      setLayerVisible: function (L, b) { s.layerVisible[L] = !!b; render(); },
      layerVisible: function (L) { return s.layerVisible[L]; },
      setLayerLocked: function (L, b) { s.layerLocked[L] = !!b; },
      layerLocked: function (L) { return s.layerLocked[L]; },
      setSelection: function (sel) { s.selection = sel; render(); },
      selection: function () { return s.selection; },
      render: render, resize: resize, fit: fit,
      invalidateCells: invalidateCells, invalidateAll: invalidateAll,
      thumbCanvas: function (L) { return thumbs[L]; },
      thumbPx: function () { return thumbPx; },
      screenToSub: screenToSub, subToScreen: subToScreen,
      stats: function () { return { thumbMs: stat.thumbMs, renders: stat.renders,
                                    lastRenderMs: stat.lastRenderMs, thumbsBuilt: stat.thumbsBuilt }; },
    };
  }
```

导出表追加:

```js
    DRAW_ORDER: DRAW_ORDER, mount: mount,
```

- [ ] **Step 2: 新建 `level_editor/ui.js`(`boot()` 最小版)**

```js
// ui.js —— 编辑器界面(规格 §4.4–§4.8)。
//
// ★★ 顶层一行都不碰 DOM:DOM 只在 boot() 与它装上的回调里取。于是 node 能把
//    "错了也不报错、只在屏幕上看出来"的那几层(工具内核 / 撤销差量 / 名字 / 尺寸钳制)
//    逐条断言 —— 见 editor_smoke.js。
// ★ 页面里不许有第二份数学:像素走 Tint.*,编解码与迁移走 Core.*,几何走 Render.*。
// ★ 依赖顺序:core.js → tile_defs.js → tint.js → render.js → io.js → ui.js。
globalThis.Editor = (function () {
  'use strict';

  var Core = globalThis.Core, Render = globalThis.Render, Io = globalThis.Io;
  if (!Core) throw new Error('ui.js: 必须先加载 core.js');
  if (!Render) throw new Error('ui.js: 必须先加载 render.js');
  if (!Io) throw new Error('ui.js: 必须先加载 io.js');

  var UI_STATE_KEY = 'cyrm.ui.v1';
  var DEFAULT_CELLS_W = 125, DEFAULT_CELLS_H = 75;

  // 运行时状态(页面用;node 冒烟不碰它)
  var app = {
    r: null, canvas: null, map: null, name: null,
    raw: null, sourceFormat: null, tileDefs: null,
  };

  function $(id) { return document.getElementById(id); }
  function nowMs() {
    return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
  }
  function msgOf(e) {
    if (!e) return '未知错误';
    var m = (e.message !== undefined) ? String(e.message) : String(e);
    if (m === '' && e.cause && e.cause.message) m = String(e.cause.message);
    return String(m);
  }

  function status(msg) { var el = $('status-msg'); if (el) el.textContent = String(msg); }

  // ★ 面板与渲染里抛出的异常必须**可见**:症状"按了没反应"最难查,而静默捕获更糟。
  function guard(label, fn) {
    try { return fn(); }
    catch (e) { status('出错了(' + label + '):' + msgOf(e)); if (typeof console !== 'undefined') console.error(label, e); return null; }
  }

  // ── 纯函数(editor_smoke.js 直接断言)──
  // ★★ 库的身份就是**文件名**(计划 2a 的裁决 ②),而 v4 的 body 里**没有** name 字段
  //    (decodeMap 返回 name:'')⇒ 导入方必须自己用文件名补 map.name,否则
  //    sanitizeName 会把它回落成 'structure'(地图名字全体变成 structure)。
  function nameFromFile(fileName) {
    return String(fileName == null ? '' : fileName).replace(/\.cyrm$/i, '');
  }
  // 三种输入(规格 §3.6):v4 二进制 / 带 `# cyrm-v3` 标记的 v3 文本 / 旧字母格式。
  // ★ 判据只此一处:先嗅 v4 的 magic(4 字节),否则当文本看 —— 有没有 v3 标记由
  //   Core.isV3Text 判,没有标记就是旧字母格式(parseV3Text 自己会走 2×2 折叠那条路)。
  function detectFormat(bytes) {
    var b = (bytes && bytes.length !== undefined) ? bytes : null;
    if (b && b.length >= 4 && b[0] === 0x43 && b[1] === 0x59 && b[2] === 0x52 && b[3] === 0x4D) return 'v4';
    var text = new TextDecoder('utf-8', { fatal: false }).decode(b ? b.subarray(0, 4096) : new Uint8Array(0));
    return Core.isV3Text(text) ? 'v3' : 'legacy';
  }
  function mapFromBytes(fileName, bytes) {
    var fmt = detectFormat(bytes);
    if (fmt === 'v4') {
      return Io.decodeMap(bytes).then(function (map) {
        map.name = nameFromFile(fileName);          // ★★ 见 nameFromFile 的说明
        return { map: map, sourceFormat: 'v4' };
      });
    }
    var text = new TextDecoder('utf-8', { fatal: false }).decode(bytes);
    var map = Core.migrateV3(Core.parseV3Text(text));
    map.name = nameFromFile(fileName);
    return Promise.resolve({ map: map, sourceFormat: fmt });
  }

  // ── 图集(Task 3:结构图 一次装进来;换图由 Task 8 的"重载贴图"按钮触发)──
  function loadAtlas() {
    return new Promise(function (resolve, reject) {
      var img = new Image();
      img.onload = function () {
        var c = document.createElement('canvas');
        c.width = img.width; c.height = img.height;
        var g = c.getContext('2d', { willReadFrequently: true });
        g.drawImage(img, 0, 0);
        var d = g.getImageData(0, 0, img.width, img.height);
        Render.setAtlas(d.data, img.width, img.height);   // ★ 同时作废 ③ 与 ④
        resolve({ width: img.width, height: img.height });
      };
      img.onerror = function () { reject(new Error('structure.png 加载失败')); };
      img.src = 'structure.png';
    });
  }

  // ── 打开地图(拉字节 → 迁移/解码 → 挂到渲染器)──
  function openMap(name) {
    status('打开 ' + name + ' …');
    return fetch('/api/map?p=' + encodeURIComponent(name))
      .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); })
      .then(function (buf) {
        app.raw = new Uint8Array(buf);
        return mapFromBytes(name, app.raw);
      })
      .then(function (out) {
        app.map = out.map; app.name = name; app.sourceFormat = out.sourceFormat;
        app.r.setMap(app.map);
        refreshStatus();
        status('已打开 ' + name + '(' + out.sourceFormat + ')');
      });
  }

  function refreshStatus() {
    var m = app.map;
    if (!m) return;
    var set = function (id, txt) { var el = $(id); if (el) el.textContent = txt; };
    set('st-name', (m.name || '(无名)') + (app.name ? ' · ' + app.name : ''));
    set('st-size', Core.cellsWOf(m) + '×' + Core.cellsHOf(m) + ' 格');
    var rep = Core.validateMap(m);
    set('st-valid', rep.errors.length ? ('error ' + rep.errors.length)
                                      : (rep.warnings.length ? ('⚠ ' + rep.warnings.length) : '校验 OK'));
  }

  // ── 库列表 ──
  function refreshLibrary() {
    return fetch('/api/maps').then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (data) {
      var ul = $('lib-list');
      if (!ul) return;
      ul.innerHTML = '';
      if (!data.maps.length) { ul.textContent = 'maps/ 下没有 .cyrm'; return; }
      data.maps.forEach(function (mm) {
        var li = document.createElement('li');
        li.className = 'lib-row';
        li.dataset.name = mm.name;
        li.textContent = mm.name + '  ' + Math.round(mm.size / 1024) + 'KB';
        li.title = new Date(mm.mtime).toLocaleString();
        ul.appendChild(li);
      });
    });
  }

  // ── 启动 ──
  function openFromUrl() {
    var p = new URLSearchParams(location.search).get('p');
    if (p) return openMap(p);
    return refreshLibrary().then(function () {
      var first = document.querySelector('#lib-list .lib-row');
      return first ? openMap(first.dataset.name) : null;
    });
  }

  function boot() {
    app.canvas = $('map-canvas');
    if (!app.canvas) return;
    app.tileDefs = globalThis.TILE_DEFS || null;
    // ★ 闸 3 没有降级路径 ⇒ 缺 Worker 时的**唯一**正确行为是把话说清楚(而不是静默退回主线程)
    if (!Io.workerAvailable()) {
      var b = $('boot-error');
      if (b) { b.hidden = false; b.textContent = '本环境没有 Web Worker —— 请用 serve.bat 起服务器后打开 http://127.0.0.1:8777/(file:// 下没有 Worker)。'; }
      return;
    }
    app.r = Render.mount(app.canvas, {});
    var ro = new ResizeObserver(function () { guard('resize', function () { app.r.resize(); }); });
    ro.observe(app.canvas.parentElement);
    window.addEventListener('error', function (ev) {
      status('页面异常:' + (ev && ev.message ? ev.message : '未知'));
    });
    window.addEventListener('unhandledrejection', function (ev) {
      status('未处理的 promise 拒绝:' + msgOf(ev && ev.reason));
    });
    var selftestBtn = $('btn-selftest');
    if (selftestBtn) {
      selftestBtn.addEventListener('click', function () {
        selfTest().then(function (line) { status(line); });
      });
    }
    var fitBtn = $('btn-fit');
    if (fitBtn) fitBtn.addEventListener('click', function () { guard('fit', function () { app.r.fit(); }); });

    // ★ 图集必须先就位(渲染第一帧就要它);失败要说出来,而不是画一片黑。
    loadAtlas().then(function () {
      return openFromUrl();
    }).then(function () {
      if (new URLSearchParams(location.search).has('selftest')) {
        return selfTest().then(function (line) { status(line); });
      }
      return null;
    }).catch(function (e) {
      status('启动失败:' + msgOf(e));
    });
  }

  // ── 浏览器自检(★ node 到不了的那半边 —— 人眼验收就靠它打印的那一行)──
  // 判据:文本 `SELFTEST OK`;失败逐条列出。人在浏览器里点「自检」按钮,把那行贴回报告。
  function selfTest() {
    var lines = [];
    var fails = 0;
    var check = function (name, cond, extra) {
      if (cond) { lines.push('  ok  - ' + name); }
      else { fails++; lines.push('  FAIL - ' + name + (extra ? '(' + extra + ')' : '')); }
    };
    return Promise.resolve().then(function () {
      check('Worker 可用', Io.workerAvailable());
      check('图集已加载', Render.atlasInfo() !== null,
            Render.atlasInfo() ? '' : 'structure.png 没加载成功');
      check('图集容量 > 0', Render.atlasCapacity() > 0, '实得 ' + Render.atlasCapacity());
      check('地图已打开', app.map !== null);
      check('画布有尺寸', app.canvas.width > 1 && app.canvas.height > 1,
            app.canvas.width + '×' + app.canvas.height);
      if (app.map) {
        // ★ 真正的性质是"map.name 等于文件名去掉后缀"(v4 body 里没有 name 字段)
        check('map.name 来自文件名', app.map.name === Editor.nameFromFile(app.name),
              'name=' + app.map.name + ' / 文件 ' + app.name);
        check('缩略图已建', app.r.stats().thumbsBuilt > 0);
      }
      return Io.ping().then(function (p) {
        check('Worker ping 有应答', p && p.pong === true);
        // 端到端:真浏览器里的 Worker + CompressionStream 往返一次
        var m = Core.createMap('selftest', 4, 3);
        for (var i = 0; i < m.layers[Core.LAYER_SCENE].desc.length; i++) {
          m.layers[Core.LAYER_SCENE].desc[i] = Core.neutralDesc(1);
        }
        return Io.encodeMap(m).then(function (bytes) {
          check('浏览器里 encodeMap 产出 "CYRM"', bytes[0] === 0x43 && bytes[1] === 0x59);
          check('压缩路径(compression=1)', bytes[5] === 1);
          return Io.decodeMap(bytes).then(function (back) {
            var a = back.layers[Core.LAYER_SCENE].desc;
            var same = a.length === m.layers[Core.LAYER_SCENE].desc.length;
            for (var k = 0; same && k < a.length; k++) if (a[k] !== m.layers[Core.LAYER_SCENE].desc[k]) same = false;
            check('经 Worker 往返逐格一致', same);
          });
        });
      });
    }).then(function () {
      var head = fails === 0 ? 'SELFTEST OK' : ('SELFTEST FAIL: ' + fails + ' 条');
      if (typeof console !== 'undefined') console.log(head + '\n' + lines.join('\n'));
      return head + ' · 共 ' + lines.length + ' 条检查';
    });
  }

  return {
    boot: boot, guard: guard, status: status, msgOf: msgOf,
    nameFromFile: nameFromFile, detectFormat: detectFormat, mapFromBytes: mapFromBytes,
    openMap: openMap, openFromUrl: openFromUrl, refreshLibrary: refreshLibrary,
    selfTest: selfTest, refreshStatus: refreshStatus,
    app: app,
  };
})();
```

- [ ] **Step 3: 整体重写 `level_editor/editor.html`**

把 `level_editor/editor.html` **整体替换**为(★ `<script src>` 的顺序是硬依赖,**不许重排**):

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>The Cyancular Ruins — 关卡编辑器</title>
<style>
:root { --bg:#17191d; --panel:#1f2329; --panel2:#262b32; --border:#343b45;
        --text:#d7dde5; --dim:#8b94a1; --accent:#54a0ff; --warn:#e0b34a; --danger:#e06a5a; }
* { box-sizing:border-box; }
html, body { height:100%; margin:0; }
body { background:var(--bg); color:var(--text); font-size:13px;
       font-family:"Segoe UI","Microsoft YaHei",system-ui,sans-serif;
       display:flex; flex-direction:column; overflow:hidden; }
button { background:var(--panel2); color:var(--text); border:1px solid var(--border);
         border-radius:4px; padding:5px 9px; font-size:13px; cursor:pointer; }
button:hover { border-color:var(--accent); }
button.on { border-color:var(--accent); background:#243040; }
input[type=number] { width:64px; background:var(--panel2); color:var(--text);
                     border:1px solid var(--border); border-radius:4px; padding:3px 6px; }
select { background:var(--panel2); color:var(--text); border:1px solid var(--border); border-radius:4px; padding:3px; }
#toolbar { display:flex; align-items:center; gap:6px; padding:6px 10px;
           background:var(--panel); border-bottom:1px solid var(--border); flex-wrap:wrap; }
#toolbar .sep { width:1px; height:20px; background:var(--border); margin:0 4px; }
#toolbar label { color:var(--dim); }
#mid { flex:1; display:flex; min-height:0; }
#lib { width:200px; background:var(--panel); border-right:1px solid var(--border);
       display:flex; flex-direction:column; }
#lib h2 { font-size:13px; margin:8px 10px 4px; color:var(--accent); }
#lib-list { list-style:none; margin:0; padding:0 6px; overflow:auto; flex:1; }
#lib-list .lib-row { padding:4px 6px; border-radius:3px; cursor:pointer; color:var(--dim); }
#lib-list .lib-row:hover { background:var(--panel2); color:var(--text); }
#lib-btns { display:flex; flex-wrap:wrap; gap:4px; padding:6px; border-top:1px solid var(--border); }
#canvas-wrap { flex:1; min-width:0; position:relative; background:#0e1013; }
#map-canvas { display:block; width:100%; height:100%; image-rendering:pixelated; }
#right { width:240px; background:var(--panel); border-left:1px solid var(--border);
         overflow:auto; }
#right h2 { font-size:13px; margin:8px 10px 4px; color:var(--accent); }
.layer-row { display:flex; align-items:center; gap:6px; padding:3px 10px; cursor:pointer; }
.layer-row .name { flex:1; }
.layer-row.cur { background:var(--panel2); color:var(--accent); }
.layer-row button { padding:2px 6px; font-size:12px; }
#palette { display:flex; flex-wrap:wrap; gap:4px; padding:4px 10px; }
#palette .sw { width:26px; height:26px; border:1px solid var(--border); cursor:pointer;
               image-rendering:pixelated; }
#palette .sw.on { border-color:var(--accent); border-width:2px; }
.desc-row { display:flex; align-items:center; gap:6px; padding:2px 10px; color:var(--dim); }
.desc-row select { flex:1; }
#statusbar { display:flex; gap:14px; align-items:center; padding:4px 10px;
             background:var(--panel); border-top:1px solid var(--border); color:var(--dim); }
#status-msg { color:var(--warn); }
#boot-error { background:#3a2320; color:#ffd9d0; padding:8px 12px; border-bottom:1px solid var(--danger); }
</style>
</head>
<body>
<div id="boot-error" hidden></div>

<div id="toolbar">
  <button class="tool" data-tool="brush" title="画笔 (B)">画笔</button>
  <button class="tool" data-tool="rect" title="矩形">矩形</button>
  <button class="tool" data-tool="bucket" title="油漆桶 (G)">油漆桶</button>
  <button class="tool" data-tool="eraser" title="橡皮 (E)">橡皮</button>
  <button class="tool" data-tool="line" title="直线 (L)">直线</button>
  <button class="tool" data-tool="select" title="选框 (M)">选框</button>
  <button class="tool" data-tool="picker" title="吸管 (I)">吸管</button>
  <button class="tool" data-tool="gradient" title="渐变(仅背景层)">渐变</button>
  <span class="sep"></span>
  <label>画笔</label><input id="brush-size" type="number" min="0.25" max="15" step="0.25" value="1">
  <span class="sep"></span>
  <button id="tg-grid" class="on">网格</button>
  <button id="tg-subgrid">子格</button>
  <button id="tg-torus" class="on">环面</button>
  <span class="sep"></span>
  <button id="btn-fit">适配</button>
  <button id="btn-selftest">自检</button>
</div>

<div id="mid">
  <div id="lib">
    <h2>库(maps/*.cyrm)</h2>
    <ul id="lib-list"><li class="lib-row">加载中 …</li></ul>
    <div id="lib-btns">
      <button id="btn-new">新建</button>
      <button id="btn-dup">复制</button>
      <button id="btn-rename">重命名</button>
      <button id="btn-del">删除</button>
    </div>
  </div>
  <div id="canvas-wrap"><canvas id="map-canvas"></canvas></div>
  <div id="right">
    <h2>图层</h2>
    <div id="layers">
      <div class="layer-row" data-layer="0"><span class="name">前景</span><button class="vis" title="显示/隐藏">👁</button><button class="lock" title="锁定">🔒</button></div>
      <div class="layer-row cur" data-layer="1"><span class="name">场景</span><button class="vis" title="显示/隐藏">👁</button><button class="lock" title="锁定">🔒</button></div>
      <div class="layer-row" data-layer="2"><span class="name">后景</span><button class="vis" title="显示/隐藏">👁</button><button class="lock" title="锁定">🔒</button></div>
      <div class="layer-row" data-layer="3"><span class="name">背景</span><button class="vis" title="显示/隐藏">👁</button><button class="lock" title="锁定">🔒</button></div>
    </div>
    <div class="desc-row"><label><input id="dim-others" type="checkbox" checked> 非当前层压暗 60%</label></div>
    <h2>纹理调色板</h2>
    <div id="palette"></div>
    <h2>辅码</h2>
    <div class="desc-row"><span>色相</span><select id="desc-hue"></select></div>
    <div class="desc-row"><span>亮度</span><select id="desc-bri"></select></div>
    <div class="desc-row"><span>饱和</span><select id="desc-sat"></select></div>
    <div class="desc-row"><span>透明</span><select id="desc-alp"></select></div>
    <div class="desc-row"><label><input id="desc-only" type="checkbox"> 只改辅码(不碰纹理)</label></div>
    <h2 id="bg-color-title">颜色(背景层)</h2>
    <div class="desc-row" id="bg-color-row">
      <input id="bg-color" type="color" value="#00ffff">
      <span id="bg-color-val">#00ffff</span>
    </div>
    <h2>出生点工具</h2>
    <div class="desc-row">
      <button id="spawn-p1">放 P1</button>
      <button id="spawn-p2">放 P2</button>
      <button id="spawn-enemy">放敌人</button>
    </div>
    <div class="desc-row"><button id="spawn-clear">清空出生点</button></div>
  </div>
</div>

<div id="statusbar">
  <span id="st-name">(未打开)</span>
  <span id="st-size"></span>
  <span id="st-tool"></span>
  <span id="st-tex"></span>
  <span id="st-desc"></span>
  <span id="st-sel"></span>
  <span id="st-undo"></span>
  <span id="st-valid"></span>
  <span id="st-save">未保存</span>
  <span id="status-msg">就绪</span>
</div>

<script>
  /*__ENEMY_REGISTRY_BEGIN__*/
window.ENEMY_REGISTRY = [];
/*__ENEMY_REGISTRY_END__*/
</script>

<script src="core.js"></script>
<script src="tile_defs.js"></script>
<script src="tint.js"></script>
<script src="render.js"></script>
<script src="io.js"></script>
<script src="ui.js"></script>
<script>
'use strict';
// 页面只做一件事:把 DOM 交给 ui.js。★ 页面里不写任何编辑器逻辑(第二份实现迟早漂)。
document.addEventListener('DOMContentLoaded', function () { Editor.boot(); });
</script>
</body>
</html>
```

- [ ] **Step 4: 迁移敌人注册表(★ 三件事,同一个 commit)**

**按这个顺序做,顺序本身就是判据**:

1. 上一步的 `editor.html` 里已经放了两个标记(块内容是空的 `[]`);
2. 改 `sync-enemies.js` 的第 12 行:

```js
const htmlPath = path.join(dir, 'structure-editor.html');
```

改成:

```js
const htmlPath = path.join(dir, 'editor.html');
```

3. 删掉旧页面:

```bash
git rm level_editor/structure-editor.html
```

4. 让脚本把注册表**写进**新页面(不要手抄 —— 手抄就是第二次实现):

```bash
node level_editor/sync-enemies.js
```

Expected: `ok: 敌人注册表已同步 jump_bird, fly_bird, …`(以 `data/enemies.json` 里的 id 为准)。

5. 校验:

```bash
node level_editor/sync-enemies.js --check && node level_editor/sync-tiles.js --check
```

Expected: 两条都打印 `ok: …`,退出码 0。

- [ ] **Step 5: 改写 `server_smoke.js` 的相位 ①b 与 ⑧(★ 教探针,不是删断言)**

**相位 ①b 整体替换**(原文断言"旧页面还在、注册表标记在它里面、sync 指向它")。这三条**方向全部反转**,因为退休就发生在这一步:

```js
  // ==== 相位 ①b 集成约束:入口页换人了(计划 2b 的退休动作)====
  // ★ 相位原文是"structure-editor.html 仍在、注册表标记在它里面、sync 指向它" ——
  //   那三条是为"2a 不碰旧页"写的。2b 把入口页换成 editor.html 并删掉旧页,
  //   于是三条**方向全部反转**(断言不是被删掉,是被**教会**了新的真值)。
  (function () {
    const oldHtml = path.join(__dirname, 'structure-editor.html');
    ok(!fs.existsSync(oldHtml), '★ 旧页面 structure-editor.html 已退休(2b 的入口页是 editor.html)');
    const newHtml = fs.readFileSync(path.join(__dirname, 'editor.html'), 'utf8');
    ok(newHtml.indexOf('/*__ENEMY_REGISTRY_BEGIN__*/') >= 0 &&
       newHtml.indexOf('/*__ENEMY_REGISTRY_END__*/') >= 0,
       '★★ 敌人注册表两个标记已经搬进 editor.html(少了它 --check 直接红)');
    const sync = fs.readFileSync(path.join(__dirname, 'sync-enemies.js'), 'utf8');
    ok(/htmlPath = path\.join\(dir, 'editor\.html'\)/.test(sync),
       '★★ sync-enemies.js 的 htmlPath 指向 editor.html(漏了它 = 注册表静默漂移)');
    let out = '', code = 0;
    try {
      out = execFileSync(process.execPath, [path.join(__dirname, 'sync-enemies.js'), '--check'],
                         { encoding: 'utf8' });
    } catch (e) {
      code = (e.status === undefined || e.status === null) ? -1 : e.status;
      out = String(e.stdout || '') + String(e.stderr || '');
    }
    ok(code === 0 && /^ok:/m.test(out),
       '集成约束: node sync-enemies.js --check 退出 0(' + String(out).trim().split('\n')[0] + ')');
  })();
```

**相位 ⑧ 整体替换**(原文断言的 id(`maps`/`tintlab`/`roundtrip`/`btn-maps`/`btn-rt`)、"不调 `lineCells`"、"纹理上界从图集派生"、"PUT 的 Content-Type"、"注册表标记不在本页"**全部**是在描述 2a 的骨架页)。新的相位 ⑧ 只留"页面结构"这一类判据,纪律类断言搬去 Task 5 的 `editor_smoke.js`(它能扫到 `ui.js`/`render.js` 的**源码**,而本相位只能看到页面文本):

```js
  // ==== 相位 ⑧ 入口页结构(真的从服务器取,不是读盘)====
  // ★ 号仍是 ⑧(计划原文的号),本文件里另有一个 ⑧(rename 重试)—— 与两个 ⑤ 并存同款,
  //   **有意为之,别去"修正"**。
  // ★ 2b 之后本相位只判"**页面结构**":入口页由 2a 的骨架页换成真页面,原来那些
  //   "骨架页必须有 id=roundtrip"之类的断言描述的是**已经不存在的页面**。
  //   纪律类断言(不许第二份 HSV / lineCells 必须 floor / PUT 必须带 Content-Type)
  //   搬到 editor_smoke.js —— 它们要扫的是 ui.js / render.js 的源码,不是页面文本。
  {
    const page = (await request(staticSrv.port, 'GET', '/')).body.toString('utf8');
    // ── 脚本清单与**顺序**:core → tile_defs → tint → render → io → ui ──
    const want = ['core.js', 'tile_defs.js', 'tint.js', 'render.js', 'io.js', 'ui.js'];
    let prev = -1, orderOk = true, firstBad = '';
    want.forEach(function (s) {
      const tag = '<script src="' + s + '"></script>';
      const at = page.indexOf(tag);
      if (at < 0) { orderOk = false; if (!firstBad) firstBad = s + '(缺失)'; return; }
      if (at < prev) { orderOk = false; if (!firstBad) firstBad = s + '(顺序)'; }
      prev = at;
    });
    ok(orderOk, '★★ 六个外部脚本按依赖顺序排:core → tile_defs → tint → render → io → ui' +
       '(首个不对:' + firstBad + ';tint 对 Core 是硬依赖,render 对两者是硬依赖)');
    ok(!/<script src="\//.test(page) && page.indexOf('://') < 0,
       '★ 页面里没有绝对路径/外部 URL 的脚本(编辑器只走本机 HTTP)');
    ok(page.indexOf('file://') < 0, '★ 页面里没有 file://(规格 §1.2:只走 HTTP)');
    ok(/id="map-canvas"/.test(page), '页面有 id="map-canvas"');
    ok(/id="toolbar"/.test(page) && /id="lib"/.test(page) && /id="right"/.test(page) &&
       /id="statusbar"/.test(page), '§4.5 的四块版式都在(工具条 / 库 / 右栏 / 状态栏)');
    ok((page.match(/class="tool" data-tool=/g) || []).length === 8,
       '工具条有 8 个工具按钮(画笔/矩形/油漆桶/橡皮/直线/选框/吸管/渐变)');
    ok((page.match(/class="layer-row"/g) || []).length === 4, '图层列表有 4 行');
    ok(/id="boot-error"/.test(page), '★ 有启动错误条(缺 Worker 时把话说清楚,而不是静默)');
    ok(page.indexOf('Editor.boot()') >= 0, '★ 页面只负责把 DOM 交给 ui.js(页面里没有编辑器逻辑)');
    ok(/__ENEMY_REGISTRY_BEGIN__/.test(page) && /window\.ENEMY_REGISTRY\s*=/.test(page),
       '★ 敌人注册表标记与 registry 都在入口页里(由 sync-enemies.js 生成)');
    ok(page.indexOf('rgbToHsv') < 0 && page.indexOf('hsvToRgb') < 0,
       '★ 页面里没有第二份 HSV 数学(像素一律走 Tint.*)');
  }
```

- [ ] **Step 6: 运行,确认通过**

Run: `cd level_editor && node server_smoke.js`

Expected: 全部 `ok -`,末行 `SERVER SMOKE OK`,退出码 0。再跑:

```bash
cd level_editor && node smoke.js && node tint_smoke.js && node worker_io_smoke.js && node render_smoke.js && node server_smoke.js
```

Expected: `SMOKE OK` / `TINT SMOKE OK` / `WORKER IO SMOKE OK` / `RENDER SMOKE OK` / `SERVER SMOKE OK`,退出码 0。

- [ ] **Step 7: 静态自检(node 能替人看的那一半)**

Run: `node --check level_editor/ui.js && node --check level_editor/render.js && node --check level_editor/editor.html 2>/dev/null; node -e "const s=require('fs').readFileSync('level_editor/editor.html','utf8'); const ids=[...s.matchAll(/getElementById\(['\"]([^'\"]+)/g)].map(m=>m[1]); console.log('页面里的 id 数量', (s.match(/id=\"/g)||[]).length)"`

Expected: 前两条**无输出**(语法通过)。★ 顺带说明:`node --check` 对 `.html` 一律报错,故第三条只用来打印 id 数量 —— **它证明不了页面在浏览器里跑得起来**,那是下一步的事。

- [ ] **Step 8: 人眼验收(★ 浏览器半边 node 验不了 —— 这半边至今无人跑过,本 Task 就是来关掉这个缺口的)**

**测试由用户自己跑**(仓库惯例)。实现者要把下面的清单**逐条**抄进报告,并在这里如实标注"浏览器半边:已由人验证 / 未验证"。

1. 双击 `level_editor/serve.bat`;
2. 浏览器打开 `http://127.0.0.1:8777/`,**F12 打开控制台**,确认:
   - 控制台**一条红字都没有**(尤其不能有 `render.js: 必须先加载…` 这类加载顺序错误);
   - 画布上能看到**地图的缩略图**(`demo.cyrm` 或 `factory1v1.cyrm` 的轮廓,不是一片黑、也不是一片纯色块);
   - 左侧库列出了 `maps/` 下的 `.cyrm`(带 KB 数与时间);
   - 右侧图层 4 行、纹理调色板、辅码四个下拉都在;
   - 状态栏显示 `名字 · 尺寸 · 校验 …`,且 `status-msg` 停在 `已打开 …`;
   - 点「适配」,地图重新居中;
3. 点**「自检」**,把控制台/状态栏那一行 `SELFTEST OK …`(或 `SELFTEST FAIL: n 条`)贴回报告;
4. 把画布截图(整个窗口即可)附到报告里。

Expected:`SELFTEST OK`、零控制台错误、画布上认得出地图轮廓。★ 若画布是一片纯色块:先看控制台有没有 `structure.png 加载失败` —— 那正是审计 A2 的症状,而这一版**应当**是好的。

- [ ] **Step 9: 提交**

```bash
git add level_editor/render.js level_editor/ui.js level_editor/editor.html level_editor/sync-enemies.js level_editor/server_smoke.js
git rm level_editor/structure-editor.html
git commit -F - <<'EOF'
feat(editor): 真入口页 editor.html + 首帧渲染 + 敌人注册表迁移(三件事同一 commit)

render.js 加 mount():缩略图路径(① 每层一张、按脏矩形更新)与逐子格路径的
朴素实现;主 ctx 关插值(A5),网格/spawn 标记/选区都按可见区裁剪(B8)。
ui.js 只放启动最小版:图集加载(走 Render.setAtlas ⇒ 同时作废 ③ 与 ④)、
库列表、打开地图(文件名补 map.name)、状态栏、guard、以及浏览器自检 selfTest()
—— node 到不了的那半边靠它打印一行 SELFTEST OK 给人贴回来。

★ 退休 structure-editor.html 的三件事在同一个 commit:标记块搬进 editor.html、
sync-enemies.js 的 htmlPath 改指新页、删旧文件。少一件的后果各不相同(注册表静默
漂移 / --check 直接红 / 两份注册表迟早烂掉一份)。server_smoke 的相位 ①b 与 ⑧
随之**被教会**新真值(方向反转 + 只判页面结构),不是删掉。
EOF
```

---

## Task 4: 视口离屏层 + 三条路径 + 环面 3×3 + 闸 2 分帧

**Files:**
- Modify: `level_editor/render.js`(把 `drawLayerPath` 换成 ② + ③ + 脏区;加 `invalidateCells` 的 ③ 侧)
- Modify: `level_editor/render_smoke.js`(追加相位 ⑩:脏区与三条路径的**纯逻辑**部分)

**Interfaces:**
- Consumes:Task 2 的 `createCellCache` / `createSlicer` / `visibleSubRange` / `torusOffsets`、Task 3 的 `mount`
- Produces(`Render.mount` 的 renderer 追加):
  - `editCells(L, list) -> void`(★ 编辑之后的**唯一**入口:`list` 为 `[{cx, cy}]` → ③ `touch` 每个格 + ② 标脏 + ① 重画该矩形 + `render()`)
  - `panBy(dxPx, dyPx) -> void`(canvas 自拷贝搬移 + 只补新露出的边条)
  - `setZoomAt(px, py, factor) -> void`(以光标为锚缩放)
  - `stats()` 追加 `{cellsHits, cellsMisses, cellsSize, layerRebuilds, layerRebuildMs, panCopies}`
  - `buildLayers() -> Promise<void>`(分帧重建 ② 的四个离屏层)

- [ ] **Step 1: 在 `render_smoke.js` 的 `console.log('');`(结果行)之前追加相位 ⑩**

```js
  // ==== 相位 ⑩ 脏区与"编辑一格只重画一格"(规格 §4.2 ②③)====
  (function () {
    // ② 的脏区簿记是纯逻辑:编辑 → 脏矩形;切层 → 只合成;平移 → 搬移 + 补边条。
    const d = Render.createDirtySet();
    eq(d.rect(), null, '新脏区集是空的');
    d.addCell(0, 3, 4);
    eq(d.rect(), { x: 12, y: 16, w: 4, h: 4 }, 'addCell(0,3,4) → 子格矩形 (12,16,4,4)');
    d.addCell(0, 5, 4);
    eq(d.rect(), { x: 12, y: 16, w: 12, h: 4 }, '★ 两个格合并成一个包围盒(不是两次重画)');
    d.addCell(2, 0, 0);
    eq(d.rect(), { x: 0, y: 0, w: 20, h: 20 }, '★ 跨层也并进同一个盒子(合成时才按层拆)');
    d.clear();
    eq(d.rect(), null, 'clear 之后又空了');
    d.addRect({ x: 1, y: 2, w: 3, h: 4 });
    eq(d.rect(), { x: 1, y: 2, w: 3, h: 4 }, 'addRect: 直接给子格矩形');

    // 平移后的"补边条"几何:画布自拷贝之后只重画新露出来的那一条
    eq(Render.panStrips(800, 600, 10, 0), [{ x: 790, y: 0, w: 10, h: 600 }],
       '★ panStrips: 向右移 10px → 只有右边 10px 需要重画(整块搬移 + 补边条)');
    eq(Render.panStrips(800, 600, 0, -10), [{ x: 0, y: 0, w: 800, h: 10 }],
       '★ panStrips: 向上移 10px → 只有上边 10px');
    eq(Render.panStrips(800, 600, 900, 0), [{ x: 0, y: 0, w: 800, h: 600 }],
       '★ panStrips: 位移超过画布尺寸 → 整块重画(自拷贝已经没有意义)');
    eq(Render.panStrips(800, 600, 0, 0), [], '位移为 0 → 没有要补的边条');

    // 以光标为锚的缩放:光标下的那一子格在缩放前后必须停在原地
    const v0 = { x: 100, y: 50, zoom: 8 };
    const v1 = Render.zoomAround(v0, 400, 300, 2);
    eq(v1.zoom, 16, 'zoomAround: 倍率 2 → zoom 8 → 16');
    const before = { X: v0.x + 400 / v0.zoom, Y: v0.y + 300 / v0.zoom };
    const after = { X: v1.x + 400 / v1.zoom, Y: v1.y + 300 / v1.zoom };
    ok(Math.abs(before.X - after.X) < 1e-9 && Math.abs(before.Y - after.Y) < 1e-9,
       '★★ zoomAround: 光标下的子格缩放前后**不动**(锚点保持,这是"缩放到鼠标位置"的全部含义)');
    const v2 = Render.zoomAround(v0, 400, 300, 1e9);
    ok(v2.zoom <= Render.MAX_ZOOM, '★ zoomAround 也钳在上限(用户输入钳制)');
  })();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node render_smoke.js`

Expected: 相位 ⑩ 头一条报 `FAIL - 新脏区集是空的`,随后整块报 `TypeError: Render.createDirtySet is not a function`,退出码 1。

- [ ] **Step 3: 在 `render.js` 里加脏区/平移/缩放的纯逻辑**

在 `rectUnion` 之后插入:

```js
  // ── ② 的脏区簿记(纯逻辑:编辑 → 标脏;切层 → 只合成;平移 → 搬移 + 补边条)──
  // ★ 跨层的脏矩形合成用**一个**盒子就够:合成时按层拆是在 ② 的离屏层上做的,
  //   而"这一帧要不要重画"只需要一个上界(包围盒偏大只会多画一点,不会画错)。
  function createDirtySet() {
    var box = null;
    function addRect(r) { box = rectUnion(box, r); }
    // 格坐标(64px 格)→ 子格矩形
    function addCell(L, cx, cy) { addRect({ x: cx * SUB, y: cy * SUB, w: SUB, h: SUB }); }
    return { addRect: addRect, addCell: addCell,
             rect: function () { return box ? { x: box.x, y: box.y, w: box.w, h: box.h } : null; },
             clear: function () { box = null; } };
  }

  // 画布自拷贝之后"新露出来"的那一条(单位 = 画布像素)。位移超过画布尺寸 = 整块重画。
  function panStrips(w, h, dx, dy) {
    var out = [];
    if (dx === 0 && dy === 0) return out;
    if (Math.abs(dx) >= w || Math.abs(dy) >= h) return [{ x: 0, y: 0, w: w, h: h }];
    if (dx > 0) out.push({ x: w - dx, y: 0, w: dx, h: h });
    if (dx < 0) out.push({ x: 0, y: 0, w: -dx, h: h });
    if (dy > 0) out.push({ x: 0, y: h - dy, w: w, h: dy });
    if (dy < 0) out.push({ x: 0, y: 0, w: w, h: -dy });
    return out;
  }

  // 以光标为锚缩放:光标下的那一子格在缩放前后停在原地。
  function zoomAround(view, px, py, factor) {
    var z = clampZoom(view.zoom * (isFinite(factor) && factor > 0 ? factor : 1));
    var wx = view.x + px / view.zoom, wy = view.y + py / view.zoom;
    return { x: wx - px / z, y: wy - py / z, zoom: z };
  }
```

导出表追加:

```js
    createDirtySet: createDirtySet, panStrips: panStrips, zoomAround: zoomAround,
```

- [ ] **Step 4: 把 `mount()` 里的朴素逐子格路径换成 ② + ③ + 脏区**

在 `mount()` 内部,**替换** `drawLayerPath` 整个函数,并改写 `render()` / `invalidateCells` / `setMap`,追加 `panBy` / `setZoomAt` / `editCells` / `buildLayers`。

先替换 `drawLayerPath`:

```js
    // ── ② 视口离屏层(★ 绝不建全图离屏:500×300 子格按 16px 是 8000×4800 = 153MB,
    //    浏览器会直接拒绝)──
    var layerCv = [null, null, null, null];
    var layerDirty = [null, null, null, null];      // 每层一个子格矩形(null = 干净)
    var cellCache = null;                            // ③
    var stat2 = { cellsHits: 0, cellsMisses: 0, cellsSize: 0,
                  layerRebuilds: 0, layerRebuildMs: 0, panCopies: 0 };

    function ensureLayerCanvas(L) {
      if (layerCv[L] && layerCv[L].width === canvas.width && layerCv[L].height === canvas.height) return layerCv[L];
      var c = document.createElement('canvas');
      c.width = canvas.width; c.height = canvas.height;
      c.getContext('2d').imageSmoothingEnabled = false;   // ★ 离屏也必须关插值(A5)
      layerCv[L] = c;
      layerDirty[L] = null;
      return c;
    }

    // ③ 的 build 回调:把一格的 16 个子格**解析成 16 个 tile 引用**(空气 → null)。
    // ★ 像素只存在 ④ 里;这里不复制像素,所以 ③ 的条目极小(见 DEFAULT_CELL_MAX 的说明)。
    function buildCell(L, cx, cy) {
      var out = new Array(SUB * SUB);
      var bx = cx * SUB, by = cy * SUB;
      for (var qy = 0; qy < SUB; qy++) {
        for (var qx = 0; qx < SUB; qx++) {
          var raw = descAt(s.map, L, bx + qx, by + qy);
          out[qy * SUB + qx] = (raw === 0 || Core.texOf(raw) === 0) ? null : tileFor(raw, qx, qy);
        }
      }
      return out;
    }

    // 重画某一层的离屏上的一块矩形(单位 = 子格,允许越出画布,内部裁剪)
    function paintLayerRect(L, rect) {
      var cv = ensureLayerCanvas(L);
      var c = cv.getContext('2d');
      // 世界子格 → 画布局部像素
      var px0 = Math.max(0, Math.floor((rect.x - s.view.x) * s.view.zoom));
      var py0 = Math.max(0, Math.floor((rect.y - s.view.y) * s.view.zoom));
      var px1 = Math.min(cv.width, Math.ceil((rect.x + rect.w - s.view.x) * s.view.zoom));
      var py1 = Math.min(cv.height, Math.ceil((rect.y + rect.h - s.view.y) * s.view.zoom));
      if (px1 <= px0 || py1 <= py0) return;
      c.clearRect(px0, py0, px1 - px0, py1 - py0);
      if (!s.layerVisible[L]) return;
      var arr = layerArray(s.map, L);
      if (!arr) return;
      var z = s.view.zoom;
      var cell0x = Math.floor((s.view.x + px0 / z) / SUB), cell1x = Math.ceil((s.view.x + px1 / z) / SUB);
      var cell0y = Math.floor((s.view.y + py0 / z) / SUB), cell1y = Math.ceil((s.view.y + py1 / z) / SUB);
      for (var cy = cell0y; cy < cell1y; cy++) {
        for (var cx = cell0x; cx < cell1x; cx++) {
          var tilesOfCell = cellCache.get(L, cx, cy);      // ★ ③:这一格的 16 个 tile
          var bx = cx * SUB, by = cy * SUB;
          for (var k = 0; k < tilesOfCell.length; k++) {
            var t = tilesOfCell[k];
            if (!t) continue;
            var X = bx + (k % SUB), Y = by + Math.floor(k / SUB);
            var sx = (X - s.view.x) * z, sy = (Y - s.view.y) * z;
            c.drawImage(t, sx, sy, z, z);
          }
        }
      }
    }

    // 重建所有"脏"的离屏层。★ 编辑之后只重画脏矩形 ⇒ 成本 O(脏区),不是 O(全屏)。
    // ★ 分帧(闸 2):换图/改缩放/改窗口是**全屏重建**,那一条走 buildLayers()。
    function flushDirty() {
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        if (!layerDirty[L]) continue;
        if (!layerArray(s.map, L)) { var cv = ensureLayerCanvas(L); cv.getContext('2d').clearRect(0, 0, cv.width, cv.height); layerDirty[L] = null; continue; }
        paintLayerRect(L, layerDirty[L]);
        layerDirty[L] = null;
        stat2.layerRebuilds++;
      }
    }

    // 全屏重建:四层各切成若干条,交给分帧器(闸 2「全屏重建 → 分帧」)
    function buildLayers() {
      if (!s.map) return Promise.resolve();
      var r = visibleSubRange(s.view, canvas.width, canvas.height, s.map.subCols, s.map.subRows);
      var tasks = [];
      var bands = 16;
      var h = Math.max(1, Math.ceil((r.y1 - r.y0) / bands));
      for (var L = 0; L < Core.LAYER_COUNT; L++) {
        layerDirty[L] = null;
        ensureLayerCanvas(L);
        for (var y = r.y0; y < r.y1; y += h) {
          tasks.push({ L: L, rect: { x: r.x0, y: y, w: r.x1 - r.x0, h: Math.min(h, r.y1 - y) } });
        }
      }
      var t0 = nowMs();
      return slicer.run(tasks, function (t) { paintLayerRect(t.L, t.rect); }).then(function () {
        stat2.layerRebuildMs = nowMs() - t0;
      });
    }

    // ★★ 3×3 的换算:离屏层装的是**主网格那一份**(偏移 [0,0]),其余副本是把它
    //    整体平移「副本世界偏移 × zoom」再画一次 —— 平移量是世界子格,要乘 zoom 变像素。
    //    ★ 也因此离屏层**只需要画主网格范围**(见 visibleClamped):副本露出来的那部分
    //      本来就是主网格的内容,平移一下就到位了。
    function drawLayerPath(W, H) {
      flushDirty();
      var offs = torusList(W, H);
      var z = s.view.zoom;
      for (var oi = 0; oi < DRAW_ORDER.length; oi++) {
        var L = DRAW_ORDER[oi];
        if (!s.layerVisible[L] || !layerCv[L]) continue;
        // ★ 非当前层压暗:合成时一次性设 alpha —— **不改任何一层的离屏内容**,
        //   所以切层只要重新合成(4 次 drawImage),不重画任何一层。
        ctx.globalAlpha = (s.dimOthers && L !== s.layer && L !== Core.LAYER_BG) ? 0.4 : 1;
        for (var i = 0; i < offs.length; i++) {
          ctx.drawImage(layerCv[L], offs[i][0] * z, offs[i][1] * z);
        }
      }
      ctx.globalAlpha = 1;
    }
```

★ 与之配套,离屏层的重建范围必须**裁剪到主网格**(视图越过接缝时 `visibleSubRange` 会给出负数或超出 `subCols` 的边界,照它读格会读到"别处的格"——环面折算后是合法值,但那些像素属于另一份副本):

```js
    function visibleClamped(W, H) {
      var r = visibleSubRange(s.view, W, H, s.map.subCols, s.map.subRows);
      return { x0: Math.max(0, r.x0), y0: Math.max(0, r.y0),
               x1: Math.min(s.map.subCols, r.x1), y1: Math.min(s.map.subRows, r.y1) };
    }
```

`buildLayers()` 用 `visibleClamped(canvas.width, canvas.height)` 取边界(而不是 `visibleSubRange`);`paintLayerRect` 自身不做裁剪(它的矩形来自调用方,允许越出画布的部分由 canvas 丢掉)。

然后把 `render()` 换成:

```js
    function render() {
      if (!s.map) return;
      var W = canvas.width, H = canvas.height;
      var t0 = nowMs();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.globalAlpha = 1;
      ctx.fillStyle = '#0e1013';
      ctx.fillRect(0, 0, W, H);
      if (zoomPath(s.view.zoom) === 'thumb') drawThumbPath(W, H); else drawLayerPath(W, H);
      if (s.grid) drawGrid(W, H);
      drawOverlay(W, H);
      stat.renders++;
      stat.lastRenderMs = nowMs() - t0;
      stat2.cellsHits = cellCache ? cellCache.stats().hits : 0;
      stat2.cellsMisses = cellCache ? cellCache.stats().misses : 0;
      stat2.cellsSize = cellCache ? cellCache.stats().size : 0;
    }
```

`setMap` 改成(注意 ③ 的重建与 ② 的全量重建都在这里,**且 ③ 必须随图一起换**):

```js
    function setMap(map) {
      s.map = map;
      s.selection = null;
      ensureThumbs(map);
      // ★ 换图 = 内容全变:③ 必须**整片**重建(旧的格位图属于上一张图,连键都可能相同)
      cellCache = createCellCache({ maxCells: DEFAULT_CELL_MAX, build: buildCell });
      attachCells(cellCache);
      for (var L = 0; L < Core.LAYER_COUNT; L++) layerDirty[L] = null;   // 全屏重建走 buildLayers()
      return buildThumbs().then(function () {
        s.view.zoom = fitZoom(map.subCols, map.subRows, canvas.width, canvas.height, 24);
        s.view.x = -(canvas.width / s.view.zoom - map.subCols) / 2;
        s.view.y = -(canvas.height / s.view.zoom - map.subRows) / 2;
        return buildLayers();
      }).then(render);
    }
```

★ **`setAtlas` 与 ③ 的耦合**:`Render.setAtlas` 会 `cells.setSource()`,而 `cells` 是模块级变量(由 `attachCells` 装上)—— `setMap` 里刚 `attachCells` 的那个就是它,所以"换图"与"换贴图"两条路都会作废 ③。**这条依赖是有意的**:换贴图时 `renderer` 里的 `cellCache` 变量与模块级的 `cells` 指向**同一个对象**,不存在"作废了另一个"的可能。若将来有人让 `mount` 不 `attachCells`,这条就断了 —— 所以 Task 3 的 `setMap` 里那一行 `attachCells(cellCache)` 不许删(render_smoke 相位 ③b 从模块侧钉住了"attach 之后 setAtlas 会清 ③")。

追加编辑入口与视图操作:

```js
    // ★ 编辑之后的**唯一**入口:三件事一次做完(否则总有一层忘了作废)
    //   ① ③ 的 touch(内容版本号)② ② 的脏矩形 ③ ① 的缩略图块
    var dirtySet = createDirtySet();
    function editCells(L, list) {
      if (!s.map) return;
      for (var i = 0; i < list.length; i++) {
        cellCache.touch(L, list[i].cx, list[i].cy);
        dirtySet.addCell(L, list[i].cx, list[i].cy);
      }
      var box = dirtySet.rect();
      if (!box) return;
      var inner = clipped(box);
      if (inner) layerDirty[L] = rectUnion(layerDirty[L], inner);
      invalidateCells(L, list);                 // ①(缩略图那块矩形)
      dirtySet.clear();
      render();
    }

    function panBy(dxPx, dyPx) {
      if (!s.map) return;
      s.view.x += dxPx / s.view.zoom;
      s.view.y += dyPx / s.view.zoom;
      if (zoomPath(s.view.zoom) === 'layers') {
        // ★ 平移近乎零成本:先自拷贝搬移,再只补新露出的边条(规格 §4.2 ②)
        for (var L = 0; L < Core.LAYER_COUNT; L++) {
          var cv = layerCv[L];
          if (!cv) continue;
          var c = cv.getContext('2d');
          c.globalCompositeOperation = 'copy';
          c.drawImage(cv, dxPx, dyPx);
          c.globalCompositeOperation = 'source-over';
          var strips = panStrips(cv.width, cv.height, dxPx, dyPx);
          for (var i = 0; i < strips.length; i++) {
            var st2 = strips[i];
            // 边条对应的世界矩形:像素 → 子格(补画时按新视图)
            var wx = s.view.x + st2.x / s.view.zoom, wy = s.view.y + st2.y / s.view.zoom;
            paintLayerRect(L, { x: wx, y: wy, w: st2.w / s.view.zoom, h: st2.h / s.view.zoom });
          }
        }
        stat2.panCopies++;
      }
      render();
    }

    function setZoomAt(px, py, factor) {
      var v = zoomAround(s.view, px, py, factor);
      s.view.x = v.x; s.view.y = v.y; s.view.zoom = v.zoom;
      // 缩放改变的是"每个子格多少像素" ⇒ 离屏层的**所有**内容都失效(全屏重建,闸 2 分帧)
      return buildLayers().then(render);
    }
    function clipped(r) {
      if (!r) return null;
      var x0 = Math.max(0, r.x), y0 = Math.max(0, r.y);
      var x1 = Math.min(s.map.subCols, r.x + r.w), y1 = Math.min(s.map.subRows, r.y + r.h);
      if (x1 <= x0 || y1 <= y0) return null;
      return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    }
```

返回对象追加/替换:

```js
      editCells: editCells, panBy: panBy, setZoomAt: setZoomAt, buildLayers: buildLayers,
      cells: function () { return cellCache; },
```

并把 `stats()` 换成合并两份记账:

```js
      stats: function () {
        return { thumbMs: stat.thumbMs, renders: stat.renders, lastRenderMs: stat.lastRenderMs,
                 thumbsBuilt: stat.thumbsBuilt, cellsHits: stat2.cellsHits, cellsMisses: stat2.cellsMisses,
                 cellsSize: stat2.cellsSize, layerRebuilds: stat2.layerRebuilds,
                 layerRebuildMs: stat2.layerRebuildMs, panCopies: stat2.panCopies };
      },
```

★ **`nowMs()` 是 `mount` 内的局部助手**,加在 `cssOfRGBA` 旁边:

```js
    function nowMs() {
      return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now();
    }
```

- [ ] **Step 5: 运行,确认通过**

Run: `cd level_editor && node render_smoke.js`

Expected: 全部 `ok -`,末行 `RENDER SMOKE OK`,退出码 0。

- [ ] **Step 6: 人眼验收:三条路径各自"看起来对",且放大后**帧时间**有数**

**测试由用户自己跑**。实现者把清单抄进报告,请人照做并把数字贴回:

1. `serve.bat` → 打开页面 → 打开一张地图;
2. **路径 A(缩略图)**:点「适配」后应看到整张图(此时 zoom < 8)。在画布上按住右键拖动 → 画面应当**跟手**,松手后不闪;
3. **路径 B(≥8 px/子格)**:滚轮放大到能看见 16px 子格(状态栏/控制台里 `zoom ≥ 8`),确认:
   - 砖块是**硬边**的(不是糊的 —— 糊就是 `imageSmoothingEnabled` 没关,A5);
   - 拖动时画面连续、**没有整屏闪烁或重画迟滞**;
4. **环面**:把视图拖到地图最左边再往左拖 → 应当在右侧看到**接缝另一侧**的内容(它不是黑边);
5. 把 `demo.cyrm` 适配后再放大到子格级,在**控制台**执行下面这一行,把数字贴回报告:

```js
copy(JSON.stringify(Editor.app.r.stats()))
```

Expected(人贴回的数字要能看出:三档行为各发生了几次):

```
{"thumbMs":…,"renders":…,"lastRenderMs":…,"thumbsBuilt":1,"cellsHits":…,"cellsMisses":…,
 "cellsSize":…,"layerRebuilds":…,"layerRebuildMs":…,"panCopies":…}
```

判据:`thumbsBuilt === 1`(缩略图只建一次)、拖动之后 `panCopies > 0`(走的是自拷贝那条路)、`cellsHits > 0`(③ 真的命中过)、`lastRenderMs` 在 10ms 量级(拖动不卡)。

- [ ] **Step 7: 提交**

```bash
git add level_editor/render.js level_editor/render_smoke.js
git commit -F - <<'EOF'
perf(editor): ≥8 px/子格 走视口离屏层 + 格位图缓存 + 脏区,平移到零成本

规格 §4.2 ② 的三条路径落地:编辑 → 只重画脏格的离屏矩形;切层 → 只重新合成
(4 次 drawImage,不重画任何一层);平移 → canvas 自拷贝搬移 + 只补新露出的边条。
缩略图路径(①)与逐格路径按 zoom 阈值切换,全屏重建(换图/改缩放/改窗口)走
分帧器(闸 2),大图上是"慢慢画出来"而不是"页面死掉"。

③ 的 build 回调只解析出 16 个 tile 引用(像素仍在 ④ 里),所以条目极小、
上限能开到 8192;setMap 重建 ③ 并 attachCells(换图的作废链条由此闭合)。
EOF
```

---

## Task 5: `ui.js` 工具内核(纯逻辑)+ `editor_smoke.js`

**Files:**
- Modify: `level_editor/ui.js`(加工具内核、尺寸/纹理钳制、`commandFor`、spawn 增删;`boot` 不动)
- Create: `level_editor/editor_smoke.js`

**Interfaces:**
- Consumes:Task 1 的 `Io`、Task 2 的 `Render`(`brushRegion` / `wrapIdx` / `SUB_PER_CELL` 等)、Task 3 的 `Editor.nameFromFile` / `detectFormat` / `mapFromBytes`
- Produces(`globalThis.Editor` 追加,**全部是纯函数**,顶层不碰 DOM):
  - `TOOLS = ['brush','rect','bucket','eraser','line','select','picker','gradient']`、`TOOL_LABELS`
  - `DERIVED_TEXTURES = [22]`
  - `createEmptyMap(name, w, h) -> map`(★ **唯一的尺寸闸**:内部走 `Core.clampMapSize`)
  - `resizeMap(map, w, h) -> {map, dropped, size}`(越界 spawn **报告**而不是静默丢)
  - `resizeReportLines(dropped) -> Array<String>`
  - `texturePalette(defs) -> Array<{tex, name, type}>`(纹理 22 不在其中)
  - `clampTexture(tex, atlasCap) -> Number`
  - `valueFor(st, L) -> (oldValue) => newValue`、`paintCells(map, L, idx, valueOf) -> diff|null`
  - `regionCells(map, region, clip) -> Array<Number>`、`inRect(r, x, y) -> Boolean`
  - `strokePoints(from, to) -> Array<{kind,x,y}>`(★ 内部 `Math.floor` 之后才调 `Core.lineCells`)
  - `lineTargets(map, a, b, clip) -> Array<Number>`
  - `applyTool(st, tool, from, to) -> diff|null`,`st = {map, layer, desc:u32, rgba:u32, brushSize:Number, selection:rect|null, descOnly:Boolean}`
  - `pickAt(map, L, X, Y) -> Number`
  - `createBucketJob(map, L, X, Y, opts) -> {runChunk(maxSteps) -> {done, scanned, total}, result() -> Array<Number>}`(`opts = {clip?:rect}`)
  - `createGradientJob(map, a, b, rgba0, rgba1, opts) -> {runChunk(maxSteps) -> {done, scanned, total}, result() -> Array<{i, rgba}>}`
  - `lerpRGBA(v0, v1, t) -> u32`
  - `spawnIndexAt(map, cellX, cellY) -> {kind:'player'|'enemy', index:Number} | null`
  - `addSpawn(map, kind, cellX, cellY, enemyType) -> diff|null`、`removeSpawn(map, kind, index) -> diff|null`、`clearSpawns(map) -> diff|null`
  - `spawnDiff(map, before) -> diff`(spawn 差量的公共构造:整表前后快照)
  - `commandFor(ev) -> String|null`(规格 §4.8 的热键表)
  - `validateLines(report) -> Array<String>`(§4.7 的点名清单)
  - `hasSelection(st) -> Boolean`

- [ ] **Step 1: 写测试 `level_editor/editor_smoke.js`(此时必然红)**

新建 `level_editor/editor_smoke.js`:

```js
'use strict';
// Node 冒烟 —— ui.js 的**纯半边**:工具内核 / 尺寸与纹理钳制 / 名字 / 热键 / 源码纪律。
// Run: cd level_editor && node editor_smoke.js
// 判据:文本 `EDITOR SMOKE OK` + 退出码 0。
// ★ 加载顺序:core → (tile_defs) → tint → render → io → ui。
// ★ `-s` 阶段与 autoload 无关(这是浏览器侧代码,不存在 Godot autoload)。

globalThis.window = globalThis;              // tile_defs.js 是 `window.TILE_DEFS = {…}`
require('./core.js');
require('./tile_defs.js');
require('./tint.js');
require('./render.js');
require('./io.js');
require('./ui.js');
const fs = require('fs');
const path = require('path');
const Core = globalThis.Core;
const Render = globalThis.Render;
const Editor = globalThis.Editor;
const TILE_DEFS = globalThis.TILE_DEFS;

let pass = 0, fail = 0;
function ok(cond, msg) {
  if (cond) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg); }
}
function eq(actual, expected, msg) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) { pass++; console.log('  ok  - ' + msg); }
  else { fail++; console.error('  FAIL - ' + msg + '\n        got: ' + a + '\n        exp: ' + e); }
}
function throws(fn, msg, expectSub) {
  let e = null;
  try { fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && String(e.message).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + e.message); return;
  }
  pass++; console.log('  ok  - ' + msg);
}
const SUB = Core.SUB_PER_CELL;
function stOf(map, L) {
  return { map: map, layer: L, desc: Core.neutralDesc(5), rgba: 0xFF00FFFF,
           brushSize: 1, selection: null, descOnly: false };
}
function filled(map, L, desc) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  for (let i = 0; i < a.length; i++) a[i] = desc;
  return map;
}
function countNonZero(map, L) {
  const a = map.layers[L].kind === 'tex' ? map.layers[L].desc : map.layers[L].rgba;
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== 0) n++;
  return n;
}

(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 某个断言挂住了(多半是 lineCells 拿到非整数坐标)');
    process.exit(1);
  }, 120000);

  try {
    // ==== 相位 ① 名字与格式分派(账本必须带进 2b 的那条)====
    eq(Editor.nameFromFile('demo.cyrm'), 'demo', 'nameFromFile: 去掉 .cyrm 后缀');
    eq(Editor.nameFromFile('factory1v1.CYRM'), 'factory1v1', 'nameFromFile: 大小写不敏感');
    eq(Editor.nameFromFile('a.b.cyrm'), 'a.b', 'nameFromFile: 只去掉**结尾**那个后缀');
    eq(Editor.nameFromFile(''), '', 'nameFromFile: 空串仍是空串');

    const src = Core.createMap('x', 3, 2);
    src.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(7);
    const bytes = await Core.encodeMap(src);
    const out = await Editor.mapFromBytes('demo.cyrm', bytes);
    eq(out.sourceFormat, 'v4', 'mapFromBytes: v4 二进制');
    eq(out.map.name, 'demo', '★★ 导入必须用文件名补 map.name(decodeMap 返回的是空串)');
    eq(Core.sanitizeName(out.map.name), 'demo',
       '★★ 补完之后 sanitizeName **不**回落成 structure(v4 body 里没有 name 字段)');
    eq(Core.sanitizeName(''), 'structure', '(对照)空名字才会回落成 structure');
    eq(out.map.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(7), 'v4 内容读回来了');

    eq(Editor.detectFormat(bytes), 'v4', 'detectFormat: 嗅 magic');
    const enc = new TextEncoder();
    eq(Editor.detectFormat(enc.encode('# cyrm-v3\n001f001f\n')), 'v3', 'detectFormat: 带标记 = v3 文本');
    eq(Editor.detectFormat(enc.encode('11\n11\n')), 'legacy', 'detectFormat: 无标记 = 旧字母格式');
    const o3 = await Editor.mapFromBytes('old.cyrm', enc.encode('# cyrm-v3\n001f001f\n'));
    eq(o3.sourceFormat, 'v3', 'mapFromBytes: v3 文本走迁移路径');
    eq(o3.map.name, 'old', 'v3 路径同样用文件名补 map.name');
    eq(o3.map.subCols, 8, 'v3: 2 格宽 → 8 子格');
    const o4 = await Editor.mapFromBytes('legacy.cyrm', enc.encode('11\n11\n'));
    eq(o4.sourceFormat, 'legacy', 'mapFromBytes: 旧字母格式(规格 §3.6 的第三种输入)');
    eq(o4.map.subCols, 4, 'legacy: 2×2 字符 → 1 格 = 4 子格');

    // ==== 相位 ② 尺寸/纹理钳制(闸 1:用户输入钳制,不报错回滚)====
    eq(Editor.createEmptyMap('x', 99999, 99999).subCols, 400 * SUB, '★★ createEmptyMap 走 clampMapSize:99999 → 400 格');
    eq(Editor.createEmptyMap('x', 99999, 99999).subRows, 300 * SUB, '★ 同上,高 → 300 格');
    eq(Editor.createEmptyMap('x', 0, -5).subCols, 4, 'createEmptyMap: 0/负数 → 至少 1 格');
    eq(Editor.createEmptyMap('x', NaN, NaN).subCols, 125 * SUB, 'createEmptyMap: NaN → 默认 125×75');
    eq(Editor.clampTexture(0, 100), 1, 'clampTexture: 0 → 1');
    eq(Editor.clampTexture(999, 100), 100, '★ clampTexture: 超过图集容量 → 钳到容量(Tint 对越界会抛)');
    eq(Editor.clampTexture(3, 100), 3, 'clampTexture: 正常值不动');
    eq(Editor.clampTexture(NaN, 100), 1, 'clampTexture: NaN → 1');
    eq(Editor.clampTexture(5, 0), 1, '★ clampTexture: 图集还没加载(cap 0)→ 1,绝不给 0(Tint 对 0 会抛)');

    // ==== 相位 ③ 调色板从 tile_defs 派生(审计 A7:纹理 22 不可选)====
    const pal = Editor.texturePalette(TILE_DEFS);
    eq(pal.length, 21, '★ 调色板 21 项(1..22 去掉自动派生的 22)');
    ok(pal.every(function (e) { return e.tex !== 22; }),
       '★★ 纹理 22(水面)不在可点选调色板里 —— 游戏侧它是自动派生的,画了会不一致(A7)');
    eq(Editor.DERIVED_TEXTURES, [22], 'DERIVED_TEXTURES = [22](A7 那一条,写成常量便于 UI 提示)');
    ok(pal.every(function (e) { return e.tex > 0 && e.name.length > 0 && typeof e.type === 'string'; }),
       '调色板每项都有 tex/name/type');
    eq(pal.map(function (e) { return e.tex; }).join(','),
       pal.map(function (e) { return e.tex; }).sort(function (a, b) { return a - b; }).join(','),
       '调色板按纹理号升序(版面稳定)');
    eq(Editor.texturePalette(null), [], 'texturePalette(null) → 空数组(不抛)');

    // ==== 相位 ④ 画笔/直线/矩形:目标集合与**两种单位** ====
    let m = Core.createMap('t', 2, 1);                 // 2 格宽 × 1 格高 = 8 × 4 子格
    let st = stOf(m, Core.LAYER_SCENE);
    st.brushSize = 0.25;
    let d = Editor.applyTool(st, 'brush', { kind: 'sub', x: 0, y: 0 }, null);
    eq(d.idx.length, 1, '★ 0.25 画笔 = 1 个子格');
    eq(m.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(5), '那一格被写上了当前描述符');

    m = Core.createMap('t', 2, 1);
    st = stOf(m, Core.LAYER_SCENE);
    st.brushSize = 1;
    d = Editor.applyTool(st, 'brush', { kind: 'cell', x: 0, y: 0 }, null);
    eq(d.idx.length, 16, '★ 整数画笔 1 = 一整格(16 个子格;整数大小只画整格,不落在子格上)');
    eq(countNonZero(m, Core.LAYER_SCENE), 16, '地图上确实只有 16 个子格被写');

    m = Core.createMap('t', 2, 1);
    st = stOf(m, Core.LAYER_SCENE);
    st.brushSize = 3;
    d = Editor.applyTool(st, 'brush', { kind: 'cell', x: 0, y: 0 }, null);
    eq(d.idx.length, 32, '★ 3×3 格画笔在 2×1 的环面图上绕回:只剩 2 个不同的格 = 32 个子格');

    // C12:选区激活时绘制被约束在选区内
    m = Core.createMap('t', 2, 1);
    st = stOf(m, Core.LAYER_SCENE);
    st.brushSize = 1;
    st.selection = { x: 0, y: 0, w: 4, h: 4 };
    d = Editor.applyTool(st, 'brush', { kind: 'cell', x: 0, y: 0 }, null);
    eq(d.idx.length, 16, '★ C12:选区 {0,0,4,4} 内只有第 1 格那 16 个子格被画(选区约束绘制)');
    eq(Editor.applyTool(st, 'brush', { kind: 'cell', x: 1, y: 0 }, null), null,
       '★ 选区外的落笔 = 什么都没改(返回 null,不是"改了但不报错")');

    // 直线:坐标必须整数(否则 Core.lineCells 会**死循环挂住**)
    m = Core.createMap('t', 2, 1);
    st = stOf(m, Core.LAYER_SCENE);
    st.brushSize = 0.25;
    d = Editor.applyTool(st, 'line', { kind: 'sub', x: 0.7, y: 0.2 }, { kind: 'sub', x: 7.9, y: 0.6 });
    eq(d.idx.length, 8, '★★ 直线 (0.7,0.2)→(7.9,0.6) 先 floor 成 (0,0)→(7,0):8 个子格,而且**没有挂住**');
    eq(d.idx[0], 0, '直线从起点开始');
    eq(d.idx[7], 7, '直线到终点结束');

    // 矩形:跟随画笔的单位
    m = Core.createMap('t', 2, 1);
    st = stOf(m, Core.LAYER_SCENE);
    st.brushSize = 1;
    d = Editor.applyTool(st, 'rect', { kind: 'cell', x: 0, y: 0 }, { kind: 'cell', x: 1, y: 0 });
    eq(d.idx.length, 32, '矩形(整数画笔)按格:2 格 = 32 个子格');

    // 橡皮:置空气
    m = filled(Core.createMap('t', 2, 1), Core.LAYER_SCENE, Core.neutralDesc(3));
    st = stOf(m, Core.LAYER_SCENE);
    d = Editor.applyTool(st, 'eraser', { kind: 'cell', x: 0, y: 0 }, null);
    eq(d.idx.length, 16, '橡皮:改 16 个子格');
    eq(d.after[0], 0, '★ 橡皮写的是空气(0)');
    eq(countNonZero(m, Core.LAYER_SCENE), 16, '擦掉一格之后还剩 16 个非空');

    // 只改辅码(§4.4):空气仍是空气,有纹理的保留原纹理
    m = Core.createMap('t', 2, 1);
    m.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(5);       // 一格里的第 1 个子格
    st = stOf(m, Core.LAYER_SCENE);
    st.desc = Core.packDesc(9, 0, 0, 0, 0);                          // 换个明显不同的辅码
    st.descOnly = true;
    st.brushSize = 1;
    d = Editor.applyTool(st, 'brush', { kind: 'cell', x: 0, y: 0 }, null);
    eq(d.idx.length, 1, '★★ 只改辅码:只有**本来就有纹理**的那 1 个子格进了差量(空气不长纹理)');
    const v = m.layers[Core.LAYER_SCENE].desc[0];
    eq(Core.texOf(v), 5, '★ 只改辅码:纹理仍是 5(没被画笔描述符里的 9 顶掉)');
    eq(Core.hueOf(v), 0, '★ 只改辅码:辅码换成了画笔的(色相档 0)');
    ok(m.layers[Core.LAYER_SCENE].desc[1] === 0, '★ 只改辅码:空气格**没有**被写成 0x9xxx(仍然没纹理)');

    // 背景层写的是颜色不是描述符
    m = Core.createMap('t', 2, 1);
    st = stOf(m, Core.LAYER_BG);
    st.rgba = 0x11223344;
    st.brushSize = 0.25;
    d = Editor.applyTool(st, 'brush', { kind: 'sub', x: 3, y: 2 }, null);
    eq(m.layers[Core.LAYER_BG].rgba[2 * 8 + 3], 0x11223344, '背景层:写的是 RGBA(不是描述符)');
    eq(Editor.pickAt(m, Core.LAYER_BG, 3, 2), 0x11223344, '吸管:背景层取回颜色');

    // ==== 相位 ⑤ 油漆桶:跨环面 + 分帧(闸 2)====
    const mb = filled(Core.createMap('t', 2, 1), Core.LAYER_SCENE, Core.neutralDesc(3));
    const job = Editor.createBucketJob(mb, Core.LAYER_SCENE, 7, 3, {});
    const chunks = [];
    let r = job.runChunk(4);
    chunks.push(r.scanned);
    let guard = 0;
    while (!r.done && guard++ < 100) { r = job.runChunk(4); chunks.push(r.scanned); }
    ok(r.done, '油漆桶:跑完了');
    eq(job.result().length, 32, '★★ 油漆桶跨环面:(7,3) 起填能把**全部 32 个子格**填到(接缝另一侧的也算)');
    ok(chunks.every(function (n) { return n <= 4; }) && chunks.length === 8,
       '★ 分帧:每个 runChunk(4) 至多推进 4 格、32 格共 8 次(实得 ' + JSON.stringify(chunks) + ')');
    eq(job.runChunk(4), { done: true, scanned: 0, total: 32 }, '跑完之后再调 runChunk 是 no-op(幂等)');

    // 边界:另一种纹理挡住填充
    const m2 = filled(Core.createMap('t', 2, 1), Core.LAYER_SCENE, Core.neutralDesc(3));
    m2.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(9);
    const job2 = Editor.createBucketJob(m2, Core.LAYER_SCENE, 7, 3, {});
    let r2 = job2.runChunk(64);
    guard = 0;
    while (!r2.done && guard++ < 100) { r2 = job2.runChunk(64); }
    eq(job2.result().length, 31, '油漆桶:遇到不同纹理就停(32 − 1 = 31)');

    // 种子本身是空气也要能填(给空图上色最常用)
    const m3 = Core.createMap('t', 2, 1);
    const job3 = Editor.createBucketJob(m3, Core.LAYER_SCENE, 0, 0, {});
    let r3 = job3.runChunk(64);
    guard = 0;
    while (!r3.done && guard++ < 100) { r3 = job3.runChunk(64); }
    eq(job3.result().length, 32, '★ 种子是空气也能填(空图 32 个子格)');

    // ==== 相位 ⑥ 渐变(仅背景层)====
    const mg = Core.createMap('t', 2, 1);
    const gj = Editor.createGradientJob(mg, { x: 0, y: 0 }, { x: 7, y: 0 }, 0x000000FF, 0xFFFFFFFF, {});
    let gr = gj.runChunk(64);
    guard = 0;
    while (!gr.done && guard++ < 100) { gr = gj.runChunk(64); }
    const res = gj.result();
    eq(res.length, 32, '渐变覆盖全图(32 个子格)');
    const byIdx = {};
    res.forEach(function (o) { byIdx[o.i] = o.rgba; });
    eq(byIdx[0], 0x000000FF, '★ 渐变起点 = 起点色(黑,alpha 满)');
    eq(byIdx[7], 0xFFFFFFFF, '★ 渐变终点 = 终点色(白)');
    const mid = byIdx[3];
    ok(((mid >>> 8) & 255) > 100 && ((mid >>> 8) & 255) < 160,
       '★ 中点是插值出来的灰(实得 ' + ((mid >>> 8) & 255) + ',应在 100~160)');
    eq(Editor.lerpRGBA(0x00000000, 0xFFFFFFFF, 0.5), 0x80808080, 'lerpRGBA: 半程插值(每通道独立四舍五入)');
    eq(Editor.lerpRGBA(0x11223344, 0x11223344, 1), 0x11223344, 'lerpRGBA: t=1 → 终点色');
    throws(function () {
      Editor.createGradientJob(mg, { x: 0, y: 0 }, { x: 3, y: 0 }, 0, 0, { layer: Core.LAYER_SCENE });
    }, '★ 渐变用在纹理层 → 抛错(规格 §4.4:渐变**仅背景层**)', '背景层');

    // ==== 相位 ⑦ 改尺寸(A8/A10)====
    const mr = Core.createMap('t', 2, 1);
    mr.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(4);
    mr.players = [{ x: 1, y: 0 }, { x: 9, y: 9 }];
    mr.enemies = [{ type: 'fly_bird', x: 0, y: 0 }, { type: 'jump_bird', x: 40, y: 40 }];
    const rz = Editor.resizeMap(mr, 4, 3);
    eq(rz.size, { w: 4, h: 3 }, 'resizeMap: 4×3');
    eq(rz.map.subCols, 16, 'resizeMap: 子格数跟着变');
    eq(rz.map.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4), '★ 重叠区的内容被保留');
    eq(rz.map.players.length, 1, '★ 越界的出生点被丢掉(留在图外 = 游戏读到网格外坐标,A10)');
    eq(rz.dropped.length, 2, '★★ 丢掉的项**报告**出来(1 个出生点 + 1 个敌人),不静默');
    eq(rz.dropped[0], { kind: 'player', x: 9, y: 9 }, 'dropped 里点名了是哪个出生点');
    eq(rz.dropped[1], { kind: 'enemy', type: 'jump_bird', x: 40, y: 40 }, 'dropped 里点名了是哪个敌人');
    eq(rz.map.enemies.length, 1, '图内的敌人留着');
    eq(Editor.resizeReportLines(rz.dropped).length, 2, '★ resizeReportLines 给出 2 行(给状态栏/弹窗用)');
    ok(Editor.resizeReportLines(rz.dropped)[0].indexOf('出生点') >= 0,
       '报告的措辞点名了"出生点"(用户要知道丢了什么)');

    const rz2 = Editor.resizeMap(mr, 99999, 99999);
    eq(rz2.size, { w: 400, h: 300 }, '★★ resizeMap 也走 clampMapSize(输 99999 变成 400×300,不卡死)');
    eq(rz2.dropped.length, 0, '放大不会丢任何东西');

    // ==== 相位 ⑧ spawn 增删(A9:出生点/敌人也要进历史)====
    const ms = Core.createMap('t', 4, 3);
    const d1 = Editor.addSpawn(ms, 'player', 1, 1);
    eq(ms.players.length, 1, 'addSpawn: 放了一个出生点');
    eq(d1.kind, 'spawn', '★★ 差量是 spawn 类(审计 A9:出生点/敌人的增删必须在历史里)');
    eq(d1.before.players.length, 0, '差量里记着 before(0 个)');
    eq(d1.after.players.length, 1, '差量里记着 after(1 个)');
    eq(Editor.spawnIndexAt(ms, 1, 1), { kind: 'player', index: 0 }, 'spawnIndexAt: 命中');
    Editor.addSpawn(ms, 'enemy', 3, 2, 'fly_bird');
    eq(ms.enemies.length, 1, 'addSpawn(敌人)');
    eq(ms.enemies[0].type, 'fly_bird', '★ 敌人的 type 来自注册表(不是写死的)');
    const d3 = Editor.removeSpawn(ms, 'player', 0);
    eq(ms.players.length, 0, 'removeSpawn');
    ok(d3.before.players.length === 1 && d3.after.players.length === 0, 'removeSpawn 的差量也是整表前后');
    eq(Editor.spawnIndexAt(ms, 4, 2), null, '★ spawnIndexAt 用环面坐标判:(4,2) 与 (3,2) 不是同一个格');
    ok(Editor.spawnIndexAt(ms, 3 - 4, 2) !== null, '★ spawnIndexAt 折算环面:(−1,2) 与 (3,2) 是同一个格');

    // ==== 相位 ⑨ 热键表(规格 §4.8)====
    const k = function (key, mod) { return { key: key, ctrl: !!mod, meta: false, shift: false }; };
    eq(Editor.commandFor(k('b')), 'tool:brush', 'B → 画笔');
    eq(Editor.commandFor(k('e')), 'tool:eraser', 'E → 橡皮');
    eq(Editor.commandFor(k('g')), 'tool:bucket', 'G → 油漆桶');
    eq(Editor.commandFor(k('m')), 'tool:select', 'M → 选框');
    eq(Editor.commandFor(k('l')), 'tool:line', 'L → 直线');
    eq(Editor.commandFor(k('i')), 'tool:picker', 'I → 吸管');
    eq(Editor.commandFor(k('[')), 'brush-smaller', '[ → 画笔变小');
    eq(Editor.commandFor(k(']')), 'brush-bigger', '] → 画笔变大');
    eq(Editor.commandFor(k('2')), 'layer:2', '2 → 切到图层 2');
    eq(Editor.commandFor(k('z', true)), 'undo', 'Ctrl+Z → 撤销');
    eq(Editor.commandFor({ key: 'Z', ctrl: true, shift: true }), 'redo', 'Ctrl+Shift+Z → 重做');
    eq(Editor.commandFor(k('y', true)), 'redo', 'Ctrl+Y → 重做');
    eq(Editor.commandFor(k('c', true)), 'copy', 'Ctrl+C → 复制');
    eq(Editor.commandFor(k('x', true)), 'cut', 'Ctrl+X → 剪切');
    eq(Editor.commandFor(k('v', true)), 'paste', 'Ctrl+V → 粘贴');
    eq(Editor.commandFor(k('s', true)), 'save', 'Ctrl+S → 保存');
    eq(Editor.commandFor({ key: 'S', ctrl: true, shift: true }), 'save-as', 'Ctrl+Shift+S → 另存为');
    eq(Editor.commandFor(k('Delete')), 'clear-selection', 'Delete → 清空选区');
    eq(Editor.commandFor(k('Backspace')), 'clear-selection', 'Backspace → 清空选区');
    eq(Editor.commandFor(k('Escape')), 'cancel-selection', 'Esc → 取消选区');
    eq(Editor.commandFor(k('ArrowLeft')), 'pan:left', '← → 向左平移');
    eq(Editor.commandFor(k('ArrowDown')), 'pan:down', '↓ → 向下平移');
    eq(Editor.commandFor(k('F5')), null, '★ 表外的键一律返回 null(不拦浏览器自己的快捷键)');
    eq(Editor.commandFor({ key: 'p', ctrl: true }), null, '★ 表外的 Ctrl 组合也返回 null(打印留给浏览器)');

    // Shift 约束(规格 §4.8:直线约束 / 选区等比)
    eq(Editor.constrainLine({ x: 0, y: 0 }, { x: 10, y: 2 }, true), { x: 10, y: 0 },
       '★ Shift 直线:近水平 → 锁成水平');
    eq(Editor.constrainLine({ x: 0, y: 0 }, { x: 2, y: 10 }, true), { x: 0, y: 10 },
       '★ Shift 直线:近垂直 → 锁成垂直');
    eq(Editor.constrainLine({ x: 0, y: 0 }, { x: 10, y: 8 }, true), { x: 10, y: 8 },
       '★ Shift 直线:其余 → 锁成 45°(取两轴较大者)');
    eq(Editor.constrainLine({ x: 0, y: 0 }, { x: -10, y: 8 }, true), { x: -10, y: 8 },
       '★ 45° 也要带对方向(负方向不翻正)');
    eq(Editor.constrainLine({ x: 0, y: 0 }, { x: 7.9, y: 0.6 }, false), { x: 7, y: 0 },
       '★★ 不按 Shift:只 floor(NaN/小数会让 Core.lineCells 死循环挂住)');
    eq(Editor.constrainSquare({ x: 0, y: 0 }, { x: 10, y: 3 }, true), { x: 10, y: 10 },
       '★ Shift 选区:等比(取两轴较大者,变成正方形)');
    eq(Editor.constrainSquare({ x: 4, y: 4 }, { x: 0, y: 1 }, true), { x: -6, y: 1 },
       '★ Shift 选区:方向朝左上时同样等比');

    // ==== 相位 ⑩ 校验清单(§4.7)====
    const mv = Core.createMap('t', 2, 1);
    const lines = Editor.validateLines(Core.validateMap(mv));
    ok(lines.length >= 2, '★ 空图的校验清单至少两条(没有出生点 / 四层全空),实得 ' + lines.length);
    ok(lines.some(function (l) { return l.indexOf('出生点') >= 0; }), '清单里点名了"出生点"');
    ok(lines.some(function (l) { return l.indexOf('空') >= 0; }), '清单里点名了"四层全空"');
    eq(Editor.validateLines({ errors: [], warnings: [] }), [], '没有问题时清单是空的');
    ok(Editor.validateLines({ errors: ['坏文件'], warnings: [] })[0].indexOf('坏') >= 0,
       'errors 也进清单(errors 是"导出去就是坏文件")');

    // ==== 相位 ⑪ 源码纪律(★ 这些断言从 server_smoke 的相位 ⑧ 搬来)====
    // ★ 为什么搬家:相位 ⑧ 扫的是**页面文本**,而 2b 之后这些纪律住在 ui.js / render.js
    //   的**源码**里;留在页面文本上会变成对着不存在代码的假绿(探针要教,不要删)。
    const ui = fs.readFileSync(path.join(__dirname, 'ui.js'), 'utf8');
    const rd = fs.readFileSync(path.join(__dirname, 'render.js'), 'utf8');
    ok(ui.indexOf('rgbToHsv') < 0 && ui.indexOf('hsvToRgb') < 0 &&
       rd.indexOf('rgbToHsv') < 0 && rd.indexOf('hsvToRgb') < 0,
       '★ ui.js / render.js 里没有第二份 HSV 数学(一律走 Tint.*)');

    // ★★ lineCells 的每个调用点都要先 Math.floor —— 非整数坐标会让它**死循环挂住标签页**
    let bad = 0, calls = 0;
    ui.split('\n').forEach(function (l) {
      if (l.indexOf('Core.lineCells(') < 0) return;
      calls++;
      if (l.indexOf('Math.floor') < 0) bad++;
    });
    ok(calls > 0 && bad === 0,
       '★★ Core.lineCells 的每个调用点都在同一行先 Math.floor(实得 ' + calls + ' 处,未 floor 的 ' + bad + ' 处)');

    // ★ createMap 只许经过一个闸(clampMapSize),否则就是 A8 原样复发
    eq((ui.match(/Core\.createMap\(/g) || []).length, 1,
       '★★ ui.js 里 Core.createMap 只出现 **1** 次(在 createEmptyMap 里,带 clampMapSize)');
    ok(/function createEmptyMap[\s\S]{0,200}Core\.clampMapSize/.test(ui),
       '★★ createEmptyMap 走 clampMapSize(createMap 自己不判上限:输 99999 会分配巨图卡死)');

    // ★ 象限几何不许在 UI 层重算(subcellRender 对越界象限会抛,调用方必须先 posmod)
    ok(ui.indexOf('subcellRender') < 0 && rd.indexOf('subcellRender') < 0,
       '★ ui.js / render.js 不直接调 Core.subcellRender(象限几何在 tint.js 内部走 quadIndex;' +
       '直接调必须先 posmod,漏了就是越界抛错)');

    // ★ PUT 必须显式带 Content-Type(写端点只收 application/json;不带 = 415)
    ok(/method:\s*['"`]PUT['"`]/.test(ui), '★ ui.js 有 PUT 调用(写端点;GET 都是只读的)');
    ok(/['"`]Content-Type['"`]\s*:\s*['"`]application\/json['"`]/.test(ui),
       '★★ PUT 显式设 Content-Type: application/json(不设 = 浏览器给 Blob 的默认类型 ⇒ 415 ⇒ 用户看到"存不进去")');
  } catch (err) {
    console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
    console.error(err && err.stack ? err.stack : String(err));
    process.exit(1);
  }

  console.log('');
  console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
  if (fail === 0) console.log('EDITOR SMOKE OK');
  process.exit(fail === 0 ? 0 : 1);
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
```

★ 结构说明:所有相位都在**同一个 `try` 里线性 `await`**,异常集中在一个 `catch` 处理(打"后面的断言一行都没跑"并退出 1);最外层再兜一个 `catch`(防止 `main()` 自身的 promise 被拒时静默)。**不要**把相位写成嵌套的 `.then` 金字塔 —— 那会让"哪一条失败"从输出里消失。

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node editor_smoke.js`

Expected: 进程在 `require('./ui.js')` 之后立刻抛 `TypeError: Editor.nameFromFile is not a function`(被最外层的 catch 抓住),末行 `FAIL: 未捕获异常(后面的断言一行都没跑):`,退出码 1。

- [ ] **Step 3: 在 `ui.js` 里加工具内核**

在 `ui.js` 的 `mapFromBytes` **之后**插入:

```js
  // ── 工具集(规格 §4.4)──
  var TOOLS = ['brush', 'rect', 'bucket', 'eraser', 'line', 'select', 'picker', 'gradient'];
  var TOOL_LABELS = { brush: '画笔', rect: '矩形', bucket: '油漆桶', eraser: '橡皮',
                      line: '直线', select: '选框', picker: '吸管', gradient: '渐变' };
  // ★ 纹理 22(水面)在编辑器里可选、在**游戏里是自动派生**(审计 A7):做成可点选调色板
  //   只会产出"编辑器里画的、游戏里看到的"不一样的图(而且不报错),故排除,只在提示里点名。
  var DERIVED_TEXTURES = [22];

  // ── 尺寸与纹理的硬上限(闸 1:一律**钳制**,不报错回滚)──
  // ★★ 唯一的造图入口。Core.createMap **不判** 400×300 上限(它只要求正整数),
  //    所以输入 99999 的那条路必须在这里被 Core.clampMapSize 截住(A8 的原样复发形态:
  //    旧编辑器的 clampMin 第三参是"非数字时的默认值",根本没有上限)。
  function createEmptyMap(name, w, h) {
    var c = Core.clampMapSize(w, h);
    return Core.createMap(Core.sanitizeName(name), c.w, c.h);
  }
  // 纹理号必须**同时**避开两个坑:0(空气,没有贴图)与超出图集容量(越界会抛)。
  function clampTexture(tex, atlasCap) {
    var t = parseInt(tex, 10);
    if (!isFinite(t) || t < 1) t = 1;
    var cap = (atlasCap === undefined || !isFinite(atlasCap) || atlasCap < 1) ? Core.TEXTURE_MAX : atlasCap;
    return Math.max(1, Math.min(cap, t));
  }
  function texturePalette(defs) {
    if (!defs || !defs.tiles) return [];
    var out = [];
    Object.keys(defs.tiles).forEach(function (k) {
      var tex = parseInt(k, 10);
      if (!isFinite(tex) || tex <= 0) return;
      if (DERIVED_TEXTURES.indexOf(tex) >= 0) return;
      var t = defs.tiles[k] || {};
      out.push({ tex: tex, name: t.name ? String(t.name) : ('纹理 ' + tex),
                 type: t.type ? String(t.type) : '' });
    });
    out.sort(function (a, b) { return a.tex - b.tex; });
    return out;
  }
  // 校验清单(规格 §4.7):只**报告**,不阻止导出。
  function validateLines(report) {
    var out = [];
    var r = report || { errors: [], warnings: [] };
    (r.errors || []).forEach(function (e) { out.push('✖ ' + e); });
    (r.warnings || []).forEach(function (w) { out.push('⚠ ' + w); });
    return out;
  }

  // ── 目标集合(单位换算 + 环面 + 选区约束)──
  function inRect(r, x, y) { return !r || (x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h); }
  function idxOf(map, X, Y) {
    return Render.wrapIdx(Y, map.subRows) * map.subCols + Render.wrapIdx(X, map.subCols);
  }
  // ★ 两种单位(格 / 子格)的换算只此一处:region.unit === 'cell' ⇒ 每格 16 个子格。
  function regionCells(map, region, clip) {
    var out = [], seen = new Set();
    function add(X, Y) {
      var wx = Render.wrapIdx(X, map.subCols), wy = Render.wrapIdx(Y, map.subRows);
      if (!inRect(clip, wx, wy)) return;                 // ★ C12:选区约束绘制
      var i = wy * map.subCols + wx;
      if (seen.has(i)) return;                           // 环面下 3×3 会重复命中,去重
      seen.add(i); out.push(i);
    }
    var k = Core.SUB_PER_CELL;
    if (region.unit === 'cell') {
      for (var cy = region.y0; cy <= region.y1; cy++) {
        for (var cx = region.x0; cx <= region.x1; cx++) {
          for (var qy = 0; qy < k; qy++) {
            for (var qx = 0; qx < k; qx++) add(cx * k + qx, cy * k + qy);
          }
        }
      }
    } else {
      for (var y = region.y0; y <= region.y1; y++) {
        for (var x = region.x0; x <= region.x1; x++) add(x, y);
      }
    }
    return out;
  }
  // ★★ Core.lineCells 的坐标必须是整数:非整数或 NaN 会让它的 `for(;;)` **死循环、
  //    挂住整个标签页**(计划 1 账本 Task 2 Minor 3)。**所有**调用点都在这里 floor,
  //    editor_smoke 相位 ⑪ 会扫源码钉住"没有第二个没 floor 的调用点"。
  function strokePoints(from, to) {
    var pts = [];
    if (!to || (from.x === to.x && from.y === to.y)) { pts.push(from); return pts; }
    var cells = Core.lineCells(Math.floor(from.x), Math.floor(from.y),
                               Math.floor(to.x), Math.floor(to.y));
    for (var i = 0; i < cells.length; i++) pts.push({ kind: from.kind, x: cells[i][0], y: cells[i][1] });
    return pts;
  }
  function lineTargets(map, a, b, clip) {
    var pts = strokePoints({ kind: 'sub', x: a.x, y: a.y }, { kind: 'sub', x: b.x, y: b.y });
    var out = [], seen = new Set();
    for (var i = 0; i < pts.length; i++) {
      var wx = Render.wrapIdx(pts[i].x, map.subCols), wy = Render.wrapIdx(pts[i].y, map.subRows);
      if (!inRect(clip, wx, wy)) continue;
      var idx = wy * map.subCols + wx;
      if (seen.has(idx)) continue;
      seen.add(idx); out.push(idx);
    }
    return out;
  }
  function toSub(hit) {
    var k = Core.SUB_PER_CELL;
    return hit.kind === 'cell' ? { x: hit.x * k, y: hit.y * k } : { x: hit.x, y: hit.y };
  }

  // ── Shift 约束(规格 §4.8:直线约束 / 选区等比)──
  // ★ 纯函数,而且是**唯一**一处做这个判断的地方:两个调用点(预览与落笔)必须用同一个
  //   结果,否则预览画的是 A、松手落下去的是 B。
  // ★ 返回值一律 floor:它的产物会直接喂给 Core.lineCells(非整数 = 死循环挂住)。
  function constrainLine(a, b, shift) {
    var bx = Math.floor(b.x), by = Math.floor(b.y);
    if (!shift) return { x: bx, y: by };
    var dx = b.x - a.x, dy = b.y - a.y;
    var adx = Math.abs(dx), ady = Math.abs(dy);
    if (adx >= 2 * ady) return { x: bx, y: Math.floor(a.y) };          // 近水平 → 锁水平
    if (ady >= 2 * adx) return { x: Math.floor(a.x), y: by };          // 近垂直 → 锁垂直
    var m = Math.max(adx, ady);                                        // 其余 → 45°
    return { x: Math.floor(a.x + (dx < 0 ? -m : m)), y: Math.floor(a.y + (dy < 0 ? -m : m)) };
  }
  function constrainSquare(a, b, shift) {
    var bx = Math.floor(b.x), by = Math.floor(b.y);
    if (!shift) return { x: bx, y: by };
    var dx = b.x - a.x, dy = b.y - a.y;
    var m = Math.max(Math.abs(dx), Math.abs(dy));
    return { x: Math.floor(a.x + (dx < 0 ? -m : m)), y: Math.floor(a.y + (dy < 0 ? -m : m)) };
  }

  // ── 落笔:先读旧值、再写、产出一条差量 ──
  function paintCells(map, L, idx, valueOf) {
    var arr = Render.layerArray(map, L);
    if (!arr || !arr.length) return null;
    var changed = [], before = [], after = [], seen = new Set();
    for (var i = 0; i < idx.length; i++) {
      var k = idx[i];
      if (seen.has(k)) continue;
      seen.add(k);
      var oldV = arr[k], newV = valueOf(oldV) >>> 0;
      if (newV === oldV) continue;                        // 值没变就不进差量(撤销栈里不留空操作)
      changed.push(k); before.push(oldV); after.push(newV);
      arr[k] = newV;
    }
    if (!changed.length) return null;
    return { kind: 'cells', layer: L, idx: Int32Array.from(changed),
             before: Uint32Array.from(before), after: Uint32Array.from(after) };
  }
  function valueFor(st, L) {
    if (L === Core.LAYER_BG) return function () { return st.rgba >>> 0; };
    if (st.descOnly) {
      // ★ "只改辅码":空气仍是空气(不能凭空长出纹理),有纹理的保留**原纹理**、只换辅码。
      //   少了这一支,整片墙"变暗"的操作会把墙**换成画笔当前选的那个纹理**。
      return function (oldV) {
        if (oldV === 0 || Core.texOf(oldV) === 0) return oldV;
        return Core.packDesc(Core.texOf(oldV), Core.hueOf(st.desc), Core.brightOf(st.desc),
                             Core.satOf(st.desc), Core.alphaOf(st.desc));
      };
    }
    return function () { return st.desc >>> 0; };
  }
  function pickAt(map, L, X, Y) { return Render.descAt(map, L, X, Y); }

  // 一次工具操作 → 一条差量(没有改动就返回 null)。bucket / gradient / select 不走这里。
  function applyTool(st, tool, from, to) {
    var map = st.map, L = st.layer, clip = st.selection || null;
    var idx = null;
    var sub = Core.SUB_PER_CELL;
    if (tool === 'picker' || tool === 'select' || tool === 'bucket' || tool === 'gradient') return null;
    if (tool === 'brush' || tool === 'eraser') {
      var pts = strokePoints(from, to), seen = new Set();
      idx = [];
      for (var i = 0; i < pts.length; i++) {
        var reg = Render.brushRegion(pts[i], st.brushSize);
        var list = regionCells(map, reg, clip);
        for (var k2 = 0; k2 < list.length; k2++) {
          if (seen.has(list[k2])) continue;
          seen.add(list[k2]); idx.push(list[k2]);
        }
      }
      if (tool === 'eraser') {
        return paintCells(map, L, idx, function () { return L === Core.LAYER_BG ? 0 : 0; });
      }
    } else if (tool === 'rect') {
      idx = regionCells(map, {
        unit: from.kind,
        x0: Math.min(from.x, to.x), y0: Math.min(from.y, to.y),
        x1: Math.max(from.x, to.x), y1: Math.max(from.y, to.y),
      }, clip);
    } else if (tool === 'line') {
      idx = lineTargets(map, toSub(from), toSub(to), clip);
    }
    if (!idx) return null;
    return paintCells(map, L, idx, valueFor(st, L));
  }

  // ── 油漆桶:跨环面连通填充(A14)+ 可分帧驱动(闸 2)──
  // 返回一个**作业对象**而不是一次性跑完:500×300 的地图跨环面时是 19.2 万格,
  // 同步跑完就是一次长阻塞。runChunk(maxSteps) 每次至多推进 maxSteps 个格子。
  function createBucketJob(map, L, X, Y, opts) {
    opts = opts || {};
    var arr = Render.layerArray(map, L);
    var cols = map.subCols, rows = map.subRows;
    var sx = Render.wrapIdx(Math.floor(X), cols), sy = Render.wrapIdx(Math.floor(Y), rows);
    var seedVal = arr ? arr[sy * cols + sx] : 0;
    var queue = [sy * cols + sx];
    var seen = new Set(queue);
    var out = [];
    var head = 0, done = false;
    function runChunk(maxSteps) {
      var n = 0;
      var lim = (maxSteps === undefined || maxSteps < 1) ? 1 : maxSteps;
      while (head < queue.length && n < lim) {
        var i = queue[head++];
        n++;
        out.push(i);
        var x = i % cols, y = Math.floor(i / cols);
        for (var k = 0; k < 4; k++) {
          var nx = Render.wrapIdx(x + (k === 0 ? 1 : k === 1 ? -1 : 0), cols);
          var ny = Render.wrapIdx(y + (k === 2 ? 1 : k === 3 ? -1 : 0), rows);
          var ni = ny * cols + nx;
          if (seen.has(ni)) continue;
          if (!inRect(opts.clip, nx, ny)) continue;        // 选区内外是两块互不连通的地
          if (arr && arr[ni] !== seedVal) continue;
          seen.add(ni); queue.push(ni);
        }
      }
      if (head >= queue.length) done = true;
      return { done: done, scanned: n, total: out.length };
    }
    return { runChunk: runChunk, result: function () { return out.slice(); } };
  }

  // ── 渐变(规格 §4.4:**仅背景层**)──
  function lerpRGBA(v0, v1, t) {
    var a = v0 >>> 0, b = v1 >>> 0;
    var ch = function (shift) {
      var x = (a >>> shift) & 255, y = (b >>> shift) & 255;
      return Math.round(x + (y - x) * t) & 255;
    };
    return (((ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0)) >>> 0);
  }
  function createGradientJob(map, a, b, rgba0, rgba1, opts) {
    opts = opts || {};
    var L = (opts.layer === undefined) ? Core.LAYER_BG : opts.layer;
    if (L !== Core.LAYER_BG) {
      throw new Error('渐变只能用在背景层(规格 §4.4):实得图层 ' + L);
    }
    if (!Render.layerArray(map, L)) {
      throw new Error('这张图的背景层不存在(layer_flags 缺位),渐变无处可写');
    }
    var dx = Math.floor(b.x) - Math.floor(a.x), dy = Math.floor(b.y) - Math.floor(a.y);
    var ax = Math.floor(a.x), ay = Math.floor(a.y);
    var len2 = dx * dx + dy * dy;
    var all = regionCells(map, { unit: 'sub', x0: 0, y0: 0, x1: map.subCols - 1, y1: map.subRows - 1 },
                          opts.clip || null);
    var out = [];
    var head = 0, done = false;
    function runChunk(maxSteps) {
      var n = 0;
      var lim = (maxSteps === undefined || maxSteps < 1) ? 1 : maxSteps;
      while (head < all.length && n < lim) {
        var i = all[head++];
        n++;
        var X = i % map.subCols, Y = Math.floor(i / map.subCols);
        var t = len2 === 0 ? 0 : ((X - ax) * dx + (Y - ay) * dy) / len2;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        out.push({ i: i, rgba: lerpRGBA(rgba0, rgba1, t) });
      }
      if (head >= all.length) done = true;
      return { done: done, scanned: n, total: out.length };
    }
    return { runChunk: runChunk, result: function () { return out.slice(); } };
  }

  // ── 出生点与敌人(★ A9:它们的增删**也要进历史**)──
  function snapshotSpawns(map) {
    return {
      players: map.players.map(function (p) { return { x: p.x, y: p.y }; }),
      enemies: map.enemies.map(function (e) { return { type: e.type, x: e.x, y: e.y }; }),
    };
  }
  function spawnDiff(before, after) {
    return { kind: 'spawn', before: before, after: after };
  }
  function spawnIndexAt(map, cellX, cellY, kind) {
    var x = Render.wrapIdx(Math.floor(cellX), Core.cellsWOf(map));
    var y = Render.wrapIdx(Math.floor(cellY), Core.cellsHOf(map));
    var i;
    if (kind !== 'enemy') {
      for (i = 0; i < map.players.length; i++) {
        if (map.players[i].x === x && map.players[i].y === y) return { kind: 'player', index: i };
      }
    }
    if (kind !== 'player') {
      for (i = 0; i < map.enemies.length; i++) {
        if (map.enemies[i].x === x && map.enemies[i].y === y) return { kind: 'enemy', index: i };
      }
    }
    return null;
  }
  function addSpawn(map, kind, cellX, cellY, enemyType) {
    var before = snapshotSpawns(map);
    var x = Render.wrapIdx(Math.floor(cellX), Core.cellsWOf(map));
    var y = Render.wrapIdx(Math.floor(cellY), Core.cellsHOf(map));
    if (kind === 'enemy') map.enemies.push({ type: String(enemyType || 'fly_bird'), x: x, y: y });
    else map.players.push({ x: x, y: y });
    return spawnDiff(before, snapshotSpawns(map));
  }
  function removeSpawn(map, kind, index) {
    var before = snapshotSpawns(map);
    if (kind === 'enemy') { if (index < 0 || index >= map.enemies.length) return null; map.enemies.splice(index, 1); }
    else { if (index < 0 || index >= map.players.length) return null; map.players.splice(index, 1); }
    return spawnDiff(before, snapshotSpawns(map));
  }
  function clearSpawns(map) {
    var before = snapshotSpawns(map);
    map.players = []; map.enemies = [];
    return spawnDiff(before, snapshotSpawns(map));
  }

  // ── 改尺寸(★ 与 A8/A10 同源)──
  function resizeMap(map, w, h) {
    var out = createEmptyMap(map.name, w, h);          // ← 尺寸闸只在这一条路上
    var copyW = Math.min(map.subCols, out.subCols), copyH = Math.min(map.subRows, out.subRows);
    for (var L = 0; L < Core.LAYER_COUNT; L++) {
      var src = Render.layerArray(map, L), dst = Render.layerArray(out, L);
      if (!src) { out.layers[L] = null; continue; }    // 缺席层保持缺席(不是"补一层空的")
      for (var y = 0; y < copyH; y++) {
        for (var x = 0; x < copyW; x++) dst[y * out.subCols + x] = src[y * map.subCols + x];
      }
    }
    out.comments = map.comments.slice();
    var dropped = [];
    var cellsW = Core.cellsWOf(out), cellsH = Core.cellsHOf(out);
    var inRange = function (p) { return p.x >= 0 && p.y >= 0 && p.x < cellsW && p.y < cellsH; };
    var i;
    for (i = 0; i < map.players.length; i++) {
      if (inRange(map.players[i])) out.players.push({ x: map.players[i].x, y: map.players[i].y });
      else dropped.push({ kind: 'player', x: map.players[i].x, y: map.players[i].y });
    }
    for (i = 0; i < map.enemies.length; i++) {
      var e = map.enemies[i];
      if (inRange(e)) out.enemies.push({ type: e.type, x: e.x, y: e.y });
      else dropped.push({ kind: 'enemy', type: e.type, x: e.x, y: e.y });
    }
    return { map: out, dropped: dropped, size: { w: cellsW, h: cellsH } };
  }
  // ★ A10 要求的是"提示并清理"而不是"静默清理" —— 这一行就是那个提示的文案。
  function resizeReportLines(dropped) {
    return (dropped || []).map(function (d) {
      return d.kind === 'enemy'
        ? ('敌人 ' + d.type + ' 落在图外 (' + d.x + ',' + d.y + '),已移除')
        : ('出生点落在图外 (' + d.x + ',' + d.y + '),已移除');
    });
  }

  // ── 热键表(规格 §4.8)──
  // ★ 纯函数:输入事件对象的一个子集,输出命令字符串。★ Ctrl 与 Cmd 一视同仁
  //   (meta):本工具只在本机跑,而 Mac 上那个键是 Cmd。表外的键一律返回 null ——
  //   返回 null 才是"不拦浏览器自己的快捷键"。
  var KEY_TOOLS = { b: 'brush', e: 'eraser', g: 'bucket', l: 'line', m: 'select', i: 'picker' };
  function commandFor(ev) {
    var e = ev || {};
    var k = String(e.key == null ? '' : e.key).toLowerCase();
    var mod = !!(e.ctrl || e.meta);
    if (mod) {
      if (k === 'z') return e.shift ? 'redo' : 'undo';
      if (k === 'y') return 'redo';
      if (k === 'c') return 'copy';
      if (k === 'x') return 'cut';
      if (k === 'v') return 'paste';
      if (k === 's') return e.shift ? 'save-as' : 'save';
      return null;
    }
    if (KEY_TOOLS[k]) return 'tool:' + KEY_TOOLS[k];
    if (k === '[') return 'brush-smaller';
    if (k === ']') return 'brush-bigger';
    if (k >= '0' && k <= '9') return 'layer:' + k;
    if (k === 'delete' || k === 'backspace') return 'clear-selection';
    if (k === 'escape') return 'cancel-selection';
    if (k === 'arrowleft' || k === 'arrowright' || k === 'arrowup' || k === 'arrowdown') {
      return 'pan:' + k.slice(5);
    }
    return null;
  }
  function hasSelection(st) { return !!(st && st.selection); }
```

导出表追加:

```js
    TOOLS: TOOLS, TOOL_LABELS: TOOL_LABELS, DERIVED_TEXTURES: DERIVED_TEXTURES,
    createEmptyMap: createEmptyMap, resizeMap: resizeMap, resizeReportLines: resizeReportLines,
    texturePalette: texturePalette, clampTexture: clampTexture, validateLines: validateLines,
    paintCells: paintCells, valueFor: valueFor, regionCells: regionCells, inRect: inRect,
    idxOf: idxOf, strokePoints: strokePoints, lineTargets: lineTargets, toSub: toSub,
    constrainLine: constrainLine, constrainSquare: constrainSquare,
    applyTool: applyTool, pickAt: pickAt,
    createBucketJob: createBucketJob, createGradientJob: createGradientJob, lerpRGBA: lerpRGBA,
    snapshotSpawns: snapshotSpawns, spawnDiff: spawnDiff, spawnIndexAt: spawnIndexAt,
    addSpawn: addSpawn, removeSpawn: removeSpawn, clearSpawns: clearSpawns,
    commandFor: commandFor, hasSelection: hasSelection,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node editor_smoke.js`

Expected: 全部 `ok -`,末行 `EDITOR SMOKE OK`,退出码 0。

- [ ] **Step 5: 变异验证(证明"只改辅码"那条断言不是空转)**

把 `valueFor` 里 `descOnly` 那一支的返回语句临时改成直接返回画笔的描述符:

```js
        return Core.packDesc(Core.texOf(oldV), Core.hueOf(st.desc), Core.brightOf(st.desc),
                             Core.satOf(st.desc), Core.alphaOf(st.desc));
```

改成:

```js
        return st.desc >>> 0;
```

Run: `cd level_editor && node editor_smoke.js`

Expected: 至少两条报红 —— `FAIL - ★ 只改辅码:纹理仍是 5(没被画笔的描述符里的 9 顶掉)`。**确认之后改回来**,再跑一次确认恢复全绿。这条变异的含义:"只改辅码"若退化成"改成画笔的纹理",屏幕上是"整片墙变成另一种砖",而**没有任何报错**。

- [ ] **Step 6: 跑齐所有冒烟,确认全绿**

Run:

```bash
cd level_editor && node smoke.js && node tint_smoke.js && node worker_io_smoke.js && node render_smoke.js && node editor_smoke.js && node server_smoke.js
```

Expected: `SMOKE OK` / `TINT SMOKE OK` / `WORKER IO SMOKE OK` / `RENDER SMOKE OK` / `EDITOR SMOKE OK` / `SERVER SMOKE OK`,退出码 0。

- [ ] **Step 7: 提交**

```bash
git add level_editor/ui.js level_editor/editor_smoke.js
git commit -F - <<'EOF'
feat(editor): 工具内核(纯逻辑)—— 8 个工具 / 环面油漆桶 / 渐变 / 钳制 / 热键

全部是纯函数:入参是数据,出参是**差量**(撤销条),不碰 DOM。于是 node 能把
"错了也不报错、只在屏幕上看出来"的那几层逐条断言:两种画笔单位(整格 vs 子格)、
3×3 画笔在环面上的去重、C12 选区约束、只改辅码(空气不长纹理、原纹理不被顶掉)、
油漆桶跨环面 + 分帧、渐变仅背景层、改尺寸越界 spawn 的**报告**而不是静默清理。

★ 尺寸只经一个闸(createEmptyMap → Core.clampMapSize):createMap 自己不判上限,
输 99999 会去分配一张巨图然后卡死(A8)。★ Core.lineCells 的坐标在同一行 Math.floor
(非整数会让它死循环挂住标签页);★ 纹理 22 不进调色板(A7:游戏侧是自动派生的)。

editor_smoke 相位 ⑪ 把原先挂在 server_smoke 相位 ⑧ 的纪律断言搬过来(扫 ui.js/render.js
源码):不许第二份 HSV / lineCells 必须 floor / createMap 只出现一次 / 不直接调
subcellRender / PUT 必须带 Content-Type。
EOF
```

---

## Task 6: 历史(差量撤销)+ 剪贴板 / 选区移动 / 镜像

**Files:**
- Modify: `level_editor/ui.js`(加 `createHistory` / `applyEntry` / 剪贴板 / `moveRegion` / `mirrorRegion`)
- Modify: `level_editor/editor_smoke.js`(追加相位 ⑫)

**Interfaces:**
- Consumes:Task 5 的 `paintCells` / `regionCells` / `idxOf` / `snapshotSpawns` / `spawnDiff`
- Produces(`globalThis.Editor` 追加):
  - `MAX_UNDO = 200`、`MAX_UNDO_BYTES = 64*1024*1024`
  - `bytesOfEntry(e) -> Number`
  - `createHistory(opts) -> {push(e) -> Boolean, undo() -> entry|null, redo() -> entry|null, depth() -> Number, redoDepth() -> Number, bytes() -> Number, clear() -> void}`(`opts={maxSteps?, maxBytes?}`)
  - `applyEntry(map, e, dir) -> void`(`dir`:`-1` 撤销 / `+1` 重做)
  - `snapshotMap(map) -> Object`、`bytesOfSnapshot(s) -> Number`
  - `wholeDiff(map, tag) -> {entry, seal()}`(改尺寸这类整图级操作的前后快照)
  - `diffCells(map, e) -> Array<{cx, cy}>`(差量 → 格坐标列表,交给 `renderer.editCells` 作废 ③)
  - `copyRegion(map, L, sel) -> clip`、`pasteRegion(map, L, clip, X, Y) -> {ok:Boolean, why?:String, diff?:Object}`
  - `clipSize(clip) -> {w, h}`
  - `moveRegion(map, L, sel, dx, dy) -> diff|null`
  - `mirrorRegion(map, L, sel, axis) -> diff|null`(`axis`:`'h'`|`'v'`)
  - `cellCountOf(map, L) -> Number`

- [ ] **Step 1: 在 `editor_smoke.js` 的 `// ==== 相位 ⑪` 之后追加相位 ⑫**

```js
    // ==== 相位 ⑫ 历史 / 剪贴板 / 选区移动(A1 的重写)====
    // 差量历史:200 步 + 字节预算(闸 1)
    const hist = Editor.createHistory({});
    eq(Editor.MAX_UNDO, 200, 'MAX_UNDO = 200(规格 §4.3 闸 1)');
    eq(hist.depth(), 0, '新历史是空的');
    const hm = Core.createMap('h', 2, 1);
    hist.push({ kind: 'cells', layer: Core.LAYER_SCENE, idx: Int32Array.from([0]),
                before: Uint32Array.from([0]), after: Uint32Array.from([Core.neutralDesc(1)]) });
    eq(hist.depth(), 1, 'push 之后深度 1');
    ok(hist.undo() !== null, 'undo 返回被撤销的那一条');
    eq(hist.depth(), 0, 'undo 之后深度 0');
    eq(hist.redoDepth(), 1, 'redo 栈里有 1 条');
    ok(hist.redo() !== null, 'redo 返回被重做的那一条');
    hist.push(null);
    eq(hist.depth(), 1, '★ push(null) 不记(空操作不进历史)');

    // 200 步上限:第 201 步起把最老的挤掉
    const h2 = Editor.createHistory({ maxSteps: 3 });
    [[0, 1], [0, 2], [0, 3], [0, 4]].forEach(function (pair) {
      h2.push({ kind: 'cells', layer: Core.LAYER_SCENE, idx: Int32Array.from([pair[0]]),
                before: Uint32Array.from([pair[1] - 1]), after: Uint32Array.from([pair[1]]) });
    });
    eq(h2.depth(), 3, '★ maxSteps 3:第 4 条挤掉最老的,深度守住 3');
    const hm2 = Core.createMap('h', 2, 1);
    hm2.layers[Core.LAYER_SCENE].desc[0] = 4;
    Editor.applyEntry(hm2, h2.undo(), -1);
    eq(hm2.layers[Core.LAYER_SCENE].desc[0], 3, '撤销写回 before');
    Editor.applyEntry(hm2, h2.undo(), -1);
    Editor.applyEntry(hm2, h2.undo(), -1);
    eq(h2.depth(), 0, '撤到底');
    eq(hm2.layers[Core.LAYER_SCENE].desc[0], 1, '★★ 只能撤到"最老的那条"为止(被挤掉的那步回不去)');
    eq(h2.undo(), null, '空历史 undo → null(不抛)');

    // 字节预算:超了就从最老的开始丢
    const h3 = Editor.createHistory({ maxSteps: 200, maxBytes: 800 });
    const mkDiff = function (n) {
      return { kind: 'cells', layer: Core.LAYER_SCENE, idx: new Int32Array(n),
               before: new Uint32Array(n), after: new Uint32Array(n) };
    };
    h3.push(mkDiff(20));                       // 12 + 20*4*3 = 252 字节
    h3.push(mkDiff(20));
    h3.push(mkDiff(20));
    eq(h3.depth(), 3, '★ 字节预算内:3 条都留着(756 ≤ 800)');
    h3.push(mkDiff(20));
    ok(h3.depth() === 3 && h3.bytes() <= 800, '★★ 超字节预算 → 丢最老的,且字节数回落到预算内(实得 ' +
       h3.depth() + ' 条 / ' + h3.bytes() + ' 字节)');
    ok(Editor.bytesOfEntry(mkDiff(20)) > 0, 'bytesOfEntry 给出正数(字节预算是按它算的)');

    // 整图级(改尺寸)也能撤
    const hw = Core.createMap('w', 2, 1);
    hw.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(4);
    const wd = Editor.wholeDiff(hw, 'resize');
    const resized = Editor.resizeMap(hw, 4, 3).map;
    hw.subCols = resized.subCols; hw.subRows = resized.subRows; hw.layers = resized.layers;
    wd.seal();
    ok(wd.entry.bytes > 0, '★ 整图级差量记了字节数(字节预算才管得住它)');
    Editor.applyEntry(hw, wd.entry, -1);
    eq(hw.subCols, 8, '★★ 撤销改尺寸:子格数回退');
    eq(hw.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4), '内容也回退');

    // spawn 差量能撤(审计 A9)
    const hsp = Core.createMap('s', 4, 3);
    const sd = Editor.addSpawn(hsp, 'player', 1, 1);
    eq(hsp.players.length, 1, '放了出生点');
    Editor.applyEntry(hsp, sd, -1);
    eq(hsp.players.length, 0, '★★ 撤销:出生点没了(A9 —— 出生点/敌人的增删必须在历史里)');
    Editor.applyEntry(hsp, sd, +1);
    eq(hsp.players.length, 1, '重做:出生点回来了');

    // 差量 → 格坐标列表(交给 renderer.editCells 作废 ③)
    const mdk = Core.createMap('k', 2, 1);          // 8×4 子格:下标 0/5/6 落在 (0,0) 与 (1,0)
    const dk = Editor.paintCells(mdk, Core.LAYER_SCENE, [0, 5, 6], function () { return Core.neutralDesc(2); });
    eq(Editor.diffCells(mdk, dk).length, 2, '★ diffCells:下标 0/5/6 → 2 个不同的格(0,0) 与 (1,0)');
    eq(Editor.diffCells(mdk, dk)[0], { cx: 0, cy: 0 }, 'diffCells 的第一个是 (0,0)');
    eq(Editor.diffCells(mdk, dk)[1], { cx: 1, cy: 0 }, 'diffCells 的第二个是 (1,0)');

    // ==== 剪贴板 ====
    await (async function () {
      const cm = Core.createMap('c', 2, 1);           // 8×4 子格
      cm.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(3);
      cm.layers[Core.LAYER_SCENE].desc[1] = Core.neutralDesc(4);
      const clip = Editor.copyRegion(cm, Core.LAYER_SCENE, { x: 6, y: 0, w: 4, h: 4 });
      eq(clip.w, 4, 'clip 的宽');
      eq(clip.kind, 'tex', '纹理层的剪贴板是描述符');
      // ★ 选区跨接缝:{6,7} + {0,1}:后两列必须是绕回来的那一侧
      eq(clip.desc[2], Core.neutralDesc(3), '★★ 复制跨环面:选区的第 3 列绕回 x=0');
      eq(clip.desc[3], Core.neutralDesc(4), '★★ 第 4 列绕回 x=1');
      eq(clip.desc[0], 0, '第 1 列(x=6)本来就是空的');

      const pm = Core.createMap('p', 3, 1);           // 12×4
      const out = Editor.pasteRegion(pm, Core.LAYER_SCENE, clip, 2, 2);
      ok(out.ok === true, '粘贴到纹理层成功');
      eq(pm.layers[Core.LAYER_SCENE].desc[2 * 12 + 4], Core.neutralDesc(3), '★ 粘贴落在目标位置');
      Editor.applyEntry(pm, out.diff, -1);
      eq(Editor.cellCountOf(pm, Core.LAYER_SCENE), 0, '撤销之后粘贴的内容没了');

      const bad = Editor.pasteRegion(pm, Core.LAYER_BG, clip, 0, 0);
      eq(bad.ok, false, '★★ 纹理层的剪贴板**不能**粘到背景层(决定 ④:两种数据类型不互转)');
      ok(bad.why && bad.why.length > 0, '拒绝时给出原因(给状态栏用,不静默)');

      const bm = Core.createMap('b', 2, 1);
      bm.layers[Core.LAYER_BG].rgba[0] = 0x11223344;
      const bclip = Editor.copyRegion(bm, Core.LAYER_BG, { x: 0, y: 0, w: 2, h: 2 });
      eq(bclip.kind, 'color', '背景层的剪贴板是 RGBA');
      const bout = Editor.pasteRegion(bm, Core.LAYER_BG, bclip, 4, 0);
      eq(bm.layers[Core.LAYER_BG].rgba[0], 0x11223344, '★ 背景层粘回背景层可以');
      ok(bout.diff !== null, '背景粘贴产出差量');
      const texToBg = Editor.pasteRegion(bm, Core.LAYER_BG, clip, 0, 0);
      eq(texToBg.ok, false, '反过来也一样:纹理剪贴板粘不进背景层');
    })();

    // ==== 选区移动(A1 的重写)====
    (function () {
      const mm = Core.createMap('m', 2, 2);            // 8×8 子格
      for (let y = 0; y < 8; y++) for (let x = 0; x < 4; x++) {
        mm.layers[Core.LAYER_SCENE].desc[y * 8 + x] = Core.neutralDesc(6);
      }
      const before = Editor.cellCountOf(mm, Core.LAYER_SCENE);
      eq(before, 32, '前置:左半边 32 个子格被填');
      const sel = { x: 0, y: 0, w: 4, h: 8 };
      const d = Editor.moveRegion(mm, Core.LAYER_SCENE, sel, 2, 0);
      eq(Editor.cellCountOf(mm, Core.LAYER_SCENE), 32,
         '★★ A1:移动之后**一个格子都没丢**(旧实现把被裁掉的列静默删掉)');
      eq(mm.layers[Core.LAYER_SCENE].desc[0], 0, '源区里没被目标覆盖的列被腾空');
      eq(mm.layers[Core.LAYER_SCENE].desc[2], Core.neutralDesc(6), '★ 目标列拿到了源列的内容');
      eq(mm.layers[Core.LAYER_SCENE].desc[5], Core.neutralDesc(6), '★ 目标列的最右一格也在');
      eq(mm.layers[Core.LAYER_SCENE].desc[6], 0, '★ A1 的原始病灶:map 宽 8,目标列到 5 为止,x=6/7 不该被动');

      const mm2 = Core.createMap('m', 2, 2);
      for (let y = 0; y < 8; y++) for (let x = 0; x < 4; x++) {
        mm2.layers[Core.LAYER_SCENE].desc[y * 8 + x] = Core.neutralDesc(6);
      }
      const snap = Array.from(mm2.layers[Core.LAYER_SCENE].desc);
      eq(Editor.moveRegion(mm2, Core.LAYER_SCENE, { x: 0, y: 0, w: 4, h: 8 }, 1000, 0), null,
         '★★ 拖动超出整幅地图:环面折算后是恒等位移 ⇒ 返回 null(旧实现会在这里把内容裁没)');
      eq(Array.from(mm2.layers[Core.LAYER_SCENE].desc).join(','), snap.join(','),
         '★★ 而且地图逐格没变(不是"返回 null 但偷偷改了")');

      // 镜像
      const mi = Core.createMap('i', 2, 2);
      mi.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(3);
      mi.layers[Core.LAYER_SCENE].desc[3] = Core.neutralDesc(4);
      const md = Editor.mirrorRegion(mi, Core.LAYER_SCENE, { x: 0, y: 0, w: 4, h: 4 }, 'h');
      eq(mi.layers[Core.LAYER_SCENE].desc[3], Core.neutralDesc(3), '★ 水平镜像:x=0 的内容到了 x=3');
      eq(mi.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4), '★ 水平镜像:x=3 的内容到了 x=0');
      ok(md !== null, '镜像产出差量');
    })();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node editor_smoke.js`

Expected: `FAIL - MAX_UNDO = 200(规格 §4.3 闸 1)`,随后 `TypeError: Editor.createHistory is not a function` 被 catch 抓住,末行 `FAIL: 未捕获异常(后面的断言一行都没跑):`,退出码 1。

- [ ] **Step 3: 在 `ui.js` 里加历史、整图快照、剪贴板、选区移动与镜像**

在 `ui.js` 的 `hasSelection` **之后**插入:

```js
  // ── 历史(差量撤销;闸 1:200 步 + 字节预算)──
  // ★ 差量而不是整图快照:一张 125×75 的图是 2.4MB,200 份就是 480MB。
  // ★ 但"改尺寸/换图"这类操作没法差量(table 级),故留一条整图快照的通道
  //   (kind:'whole'),并按**字节**记账 —— 字节预算才是真闸,步数只是廉价上界。
  var MAX_UNDO = 200;
  var MAX_UNDO_BYTES = 64 * 1024 * 1024;

  function bytesOfEntry(e) {
    if (!e) return 0;
    if (e.kind === 'cells') return 12 + e.idx.length * 4 + e.before.length * 4 + e.after.length * 4;
    if (e.kind === 'spawn') {
      var n = (e.before ? e.before.players.length + e.before.enemies.length : 0) +
              (e.after ? e.after.players.length + e.after.enemies.length : 0);
      return 64 + 32 * n;
    }
    if (e.kind === 'whole') return 64 + (e.bytes || 0);
    return 64;
  }

  function createHistory(opts) {
    opts = opts || {};
    var maxSteps = opts.maxSteps === undefined ? MAX_UNDO : opts.maxSteps;
    var maxBytes = opts.maxBytes === undefined ? MAX_UNDO_BYTES : opts.maxBytes;
    var undos = [], redos = [], total = 0;
    function trim() {
      while (undos.length > maxSteps) { total -= bytesOfEntry(undos.shift()); }
      // ★ 至少留一条:一条都留不住时"撤销"这个功能就整体失效了(比多占几 MB 更糟)
      while (total > maxBytes && undos.length > 1) { total -= bytesOfEntry(undos.shift()); }
    }
    return {
      push: function (e) {
        if (!e) return false;                       // 空操作不进历史
        undos.push(e); total += bytesOfEntry(e);
        redos.length = 0;                           // ★ 新编辑之后重做链断掉(标准语义)
        trim();
        return true;
      },
      undo: function () {
        if (!undos.length) return null;
        var e = undos.pop(); total -= bytesOfEntry(e);
        redos.push(e);
        return e;
      },
      redo: function () {
        if (!redos.length) return null;
        var e = redos.pop(); total += bytesOfEntry(e);
        undos.push(e);
        return e;
      },
      depth: function () { return undos.length; },
      redoDepth: function () { return redos.length; },
      bytes: function () { return total; },
      clear: function () { undos.length = 0; redos.length = 0; total = 0; },
    };
  }

  // 整图快照(只给"改尺寸/换图"这类整图级操作用)
  function snapshotMap(map) {
    var layers = [];
    for (var L = 0; L < Core.LAYER_COUNT; L++) {
      var lay = map.layers[L];
      if (!lay) { layers.push(null); continue; }
      layers.push(lay.kind === 'tex' ? { kind: 'tex', desc: new Uint32Array(lay.desc) }
                                     : { kind: 'color', rgba: new Uint32Array(lay.rgba) });
    }
    var sp = snapshotSpawns(map);
    return { subCols: map.subCols, subRows: map.subRows, layers: layers,
             players: sp.players, enemies: sp.enemies, comments: map.comments.slice() };
  }
  function bytesOfSnapshot(s) {
    var n = 0;
    for (var L = 0; L < s.layers.length; L++) {
      var lay = s.layers[L];
      if (!lay) continue;
      n += (lay.kind === 'tex' ? lay.desc.length : lay.rgba.length) * 4;
    }
    return n;
  }
  // 用法:var wd = wholeDiff(map, 'resize'); …做完改动…; wd.seal(); history.push(wd.entry);
  function wholeDiff(map, tag) {
    var entry = { kind: 'whole', tag: tag || '', before: snapshotMap(map), bytes: 0 };
    entry.bytes = bytesOfSnapshot(entry.before);
    return {
      entry: entry,
      seal: function () {
        entry.after = snapshotMap(map);
        entry.bytes += bytesOfSnapshot(entry.after);
        return entry;
      },
    };
  }
  function applyEntry(map, e, dir) {
    if (!e) return;
    var i;
    if (e.kind === 'cells') {
      var arr = Render.layerArray(map, e.layer);
      if (!arr) return;
      var src = dir < 0 ? e.before : e.after;
      for (i = 0; i < e.idx.length; i++) arr[e.idx[i]] = src[i];
      return;
    }
    if (e.kind === 'spawn') {
      var v = dir < 0 ? e.before : e.after;
      map.players = v.players.map(function (p) { return { x: p.x, y: p.y }; });
      map.enemies = v.enemies.map(function (q) { return { type: q.type, x: q.x, y: q.y }; });
      return;
    }
    if (e.kind === 'whole') {
      var s = dir < 0 ? e.before : e.after;
      if (!s) return;
      map.subCols = s.subCols; map.subRows = s.subRows;
      map.layers = s.layers.map(function (lay) {
        if (!lay) return null;
        return lay.kind === 'tex' ? { kind: 'tex', desc: lay.desc } : { kind: 'color', rgba: lay.rgba };
      });
      map.players = s.players.map(function (p) { return { x: p.x, y: p.y }; });
      map.enemies = s.enemies.map(function (q) { return { type: q.type, x: q.x, y: q.y }; });
      map.comments = s.comments.slice();
    }
  }
  // 差量 → 去重后的格坐标列表(交给 renderer.editCells 作废 ③ 与重画缩略图)
  function diffCells(map, e) {
    if (!e || e.kind !== 'cells') return [];
    var seen = new Set(), out = [];
    for (var i = 0; i < e.idx.length; i++) {
      var X = e.idx[i] % map.subCols, Y = Math.floor(e.idx[i] / map.subCols);
      var cx = Math.floor(X / Core.SUB_PER_CELL), cy = Math.floor(Y / Core.SUB_PER_CELL);
      var k = cx + '/' + cy;
      if (seen.has(k)) continue;
      seen.add(k); out.push({ cx: cx, cy: cy });
    }
    return out;
  }
  function cellCountOf(map, L) {
    var a = Render.layerArray(map, L);
    if (!a) return 0;
    var n = 0;
    for (var i = 0; i < a.length; i++) if (a[i] !== 0) n++;
    return n;
  }

  // ── 剪贴板(跨图层粘贴只允许"纹理 ↔ 纹理")──
  function copyRegion(map, L, sel) {
    if (!sel) return null;
    var arr = Render.layerArray(map, L);
    var n = sel.w * sel.h, x, y;
    if (L === Core.LAYER_BG) {
      var rgba = new Uint32Array(n);
      for (y = 0; y < sel.h; y++) {
        for (x = 0; x < sel.w; x++) rgba[y * sel.w + x] = arr ? arr[idxOf(map, sel.x + x, sel.y + y)] : 0;
      }
      return { kind: 'color', w: sel.w, h: sel.h, rgba: rgba };
    }
    var desc = new Uint32Array(n);
    for (y = 0; y < sel.h; y++) {
      for (x = 0; x < sel.w; x++) desc[y * sel.w + x] = arr ? arr[idxOf(map, sel.x + x, sel.y + y)] : 0;
    }
    return { kind: 'tex', w: sel.w, h: sel.h, desc: desc };
  }
  function clipSize(clip) { return clip ? { w: clip.w, h: clip.h } : { w: 0, h: 0 }; }
  // ★ 决定 ④:两种数据类型不互相猜。拒绝时**给出原因**(状态栏要显示),不静默。
  function pasteRegion(map, L, clip, X, Y) {
    if (!clip) return { ok: false, why: '剪贴板是空的' };
    var isColorLayer = (L === Core.LAYER_BG);
    if (isColorLayer && clip.kind !== 'color') {
      return { ok: false, why: '剪贴板是纹理层内容,不能粘到背景层(两种数据类型不互转)' };
    }
    if (!isColorLayer && clip.kind !== 'tex') {
      return { ok: false, why: '剪贴板是背景层的颜色,不能粘到纹理层' };
    }
    var targets = [], values = [], x, y;
    for (y = 0; y < clip.h; y++) {
      for (x = 0; x < clip.w; x++) {
        targets.push(idxOf(map, Math.floor(X) + x, Math.floor(Y) + y));
        values.push(clip.kind === 'tex' ? clip.desc[y * clip.w + x] : clip.rgba[y * clip.w + x]);
      }
    }
    var order = 0;
    var diff = paintCells(map, L, targets, function () { return values[order++]; });
    return { ok: true, diff: diff };
  }

  // ── 选区移动(A1 的重写)──
  // ★ 旧实现的病灶:maxDX = 宽 − 选区宽 **漏了 − 选区.x**,拖动越界后
  //   moveRegion(先清源区再贴目标区)把被裁掉的列静默删掉。
  // ★ 新实现没有"裁剪"这一步:目标格 = 源格 + 偏移(两边都环面折算),
  //   源区里**没被目标覆盖**的格被清空。于是"拖到图外"在环面上就是恒等位移,
  //   结果是"什么都没变"而不是"内容被裁掉"。
  function moveRegion(map, L, sel, dx, dy) {
    if (!sel) return null;
    var arr = Render.layerArray(map, L);
    if (!arr) return null;
    var from = new Map(), to = new Map();
    var x, y;
    for (y = 0; y < sel.h; y++) {
      for (x = 0; x < sel.w; x++) {
        var si = idxOf(map, sel.x + x, sel.y + y);
        var di = idxOf(map, sel.x + x + dx, sel.y + y + dy);
        from.set(si, true);
        to.set(di, arr[si]);                       // ★ 一次性算出目标值(基于**旧**数组读)
      }
    }
    var keys = new Set();
    to.forEach(function (_, k) { keys.add(k); });
    from.forEach(function (_, k) { keys.add(k); });   // 源区里没被覆盖的格 → 写空气
    var idx = [], before = [], after = [];
    keys.forEach(function (k) {
      var nv = to.has(k) ? to.get(k) : 0;
      if (arr[k] === nv) return;
      idx.push(k); before.push(arr[k]); after.push(nv);
    });
    for (var i = 0; i < idx.length; i++) arr[idx[i]] = after[i];
    if (!idx.length) return null;
    return { kind: 'cells', layer: L, idx: Int32Array.from(idx),
             before: Uint32Array.from(before), after: Uint32Array.from(after), tag: 'move' };
  }

  // ── 镜像(规格 §4.4 的选框:可移动 / 删除 / 复制粘贴 / 镜像)──
  function mirrorRegion(map, L, sel, axis) {
    if (!sel) return null;
    var arr = Render.layerArray(map, L);
    if (!arr) return null;
    var idx = [], before = [], after = [], x, y;
    for (y = 0; y < sel.h; y++) {
      for (x = 0; x < sel.w; x++) {
        var sx = (axis === 'h') ? (sel.w - 1 - x) : x;
        var sy = (axis === 'v') ? (sel.h - 1 - y) : y;
        var di = idxOf(map, sel.x + x, sel.y + y);
        var si = idxOf(map, sel.x + sx, sel.y + sy);
        if (arr[di] === arr[si]) continue;
        idx.push(di); before.push(arr[di]); after.push(arr[si]);
      }
    }
    for (var i = 0; i < idx.length; i++) arr[idx[i]] = after[i];
    if (!idx.length) return null;
    return { kind: 'cells', layer: L, idx: Int32Array.from(idx),
             before: Uint32Array.from(before), after: Uint32Array.from(after), tag: 'mirror' };
  }
```

导出表追加:

```js
    MAX_UNDO: MAX_UNDO, MAX_UNDO_BYTES: MAX_UNDO_BYTES, bytesOfEntry: bytesOfEntry,
    createHistory: createHistory, snapshotMap: snapshotMap, bytesOfSnapshot: bytesOfSnapshot,
    wholeDiff: wholeDiff, applyEntry: applyEntry, diffCells: diffCells, cellCountOf: cellCountOf,
    copyRegion: copyRegion, clipSize: clipSize, pasteRegion: pasteRegion,
    moveRegion: moveRegion, mirrorRegion: mirrorRegion,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node editor_smoke.js`

Expected: 全部 `ok -`,末行 `EDITOR SMOKE OK`,退出码 0。

- [ ] **Step 5: 提交**

```bash
git add level_editor/ui.js level_editor/editor_smoke.js
git commit -F - <<'EOF'
feat(editor): 差量撤销(200 步 + 字节预算)+ 剪贴板 / 选区移动 / 镜像

历史是差量而不是整图快照(2.4MB × 200 = 480MB);"改尺寸/换图"这类 table 级
操作走一条整图快照通道(kind:'whole'),按**字节**记账 —— 字节预算才是真闸。
spawn 的增删也进历史(审计 A9:原先出生点/敌人的改动完全不在历史里)。

★ 选区移动重写(A1):旧实现 maxDX = 宽 − 选区宽 漏了 − 选区.x,拖动越界后
moveRegion(先清源区再贴目标区)把被裁掉的列**静默删掉**。新实现没有裁剪这一步 ——
目标格 = 源格 + 偏移(两边都环面折算),源区里没被目标覆盖的格写空气;于是
"拖到图外"在环面上就是恒等位移,结果是"什么都没变"而不是"内容被裁掉"。

跨图层粘贴只允许纹理↔纹理(决定 ④):描述符与 RGBA 不互相猜,拒绝时给出原因。
EOF
```

---

## Task 7: 画布交互接线(指针 / 热键 / 选区拖动 / 状态栏)

**Files:**
- Modify: `level_editor/render.js`(`drawOverlay` 加预览框与拖动中的选区框;加 `setSelDrag` / `setPreview`)
- Modify: `level_editor/ui.js`(指针、滚轮、热键、长作业驱动、状态栏刷新、撤销/重做接线)

**Interfaces:**
- Consumes:Task 4 的 renderer(`editCells` / `panBy` / `setZoomAt` / `fit` / `screenToSub` / `setSelection` / `layer` / `selection`)、Task 5 的 `applyTool` / `commandFor` / `createBucketJob` / `createGradientJob` / `paintCells` / `valueFor`、Task 6 的 `createHistory` / `applyEntry` / `diffCells` / `moveRegion` / `pasteRegion` / `copyRegion`
- Produces:
  - renderer 追加:`setSelDrag(sel|null, dx, dy) -> void`、`setPreview(rect|null) -> void`、`isDraggingSelection() -> Boolean`
  - `Editor.installInteraction() -> void`(由 `boot()` 调用)
  - `Editor.runJob(job, onApply, label) -> Promise<void>`(长作业分帧驱动)
  - `Editor.statusLine() -> void`
  - `Editor.doUndo() / Editor.doRedo() -> void`
  - `Editor.pushAndShow(diff) -> Boolean`(★ 唯一的"改数据之后作废缓存"入口)

- [ ] **Step 1: `render.js`:预览框、拖动中的选区框、拖动时的偏移绘制**

在 `mount` 的状态对象里补两个字段(与 `selection` 并列):

```js
      preview: null,       // 拖矩形/直线时的预览框(子格单位)
      selDrag: null,       // {sel, dx, dy}:选区拖动中(拖动只记偏移,松手才提交)
```

在 `mount` 内加三个函数(放在 `invalidateCells` 之前):

```js
    // ★ 选区拖动:**只记偏移**。渲染时对选区内的格做**偏移查询**(纯读),
    //   松手才提交一次 moveRegion —— 老实现每次 pointermove 都深拷贝三份全图(B3)。
    function setSelDrag(sel, dx, dy) {
      s.selDrag = sel ? { sel: sel, dx: dx, dy: dy } : null;
      render();
    }
    function setPreview(rect) { s.preview = rect; render(); }
    // 拖动中的选区:目标格 (X,Y) 的内容来自源格 (X-dx, Y-dy)(纯读,不改进数据)
    function dragSource(X, Y) {
      if (!s.selDrag) return { hit: true, X: X, Y: Y };
      return selectionSource(s.selDrag.sel, s.selDrag.dx, s.selDrag.dy, X, Y);
    }
```

把 `paintLayerRect` 里读格那一行:

```js
              var raw = descAt(s.map, L, X - dx, Y - dy);
```

换成(★ 两处都要:这里的 `X/Y` 已经是主网格坐标):

```js
              var q = dragSource(X, Y);
              // 拖动中:目标格若不在"偏移后的选区"里,就说明它是被腾空的源区 ⇒ 不画
              var raw = q.hit ? descAt(s.map, L, q.X, q.Y) : 0;
```

`drawOverlay` 里在选区框之前插入预览框,并把选区框改成"拖动时按偏移画":

```js
      if (s.preview) {
        var pv = subToScreen(s.preview.x, s.preview.y);
        ctx.setLineDash([6, 4]);
        ctx.strokeStyle = '#54a0ff';
        ctx.lineWidth = 1;
        ctx.strokeRect(pv.x, pv.y, s.preview.w * s.view.zoom, s.preview.h * s.view.zoom);
        ctx.setLineDash([]);
      }
      if (s.selection) {
        var sel = s.selDrag
          ? { x: s.selection.x + s.selDrag.dx, y: s.selection.y + s.selDrag.dy,
              w: s.selection.w, h: s.selection.h }
          : s.selection;
        var a = subToScreen(sel.x, sel.y);
        ctx.strokeStyle = '#e0b34a';
        ctx.lineWidth = 2;
        ctx.strokeRect(a.x, a.y, sel.w * s.view.zoom, sel.h * s.view.zoom);
      }
```

(★ 把 `drawOverlay` 里**原来**那一段 `if (s.selection) { … }` 整段删掉,换成上面这两段。)

导出:

```js
      setSelDrag: setSelDrag, setPreview: setPreview,
      isDraggingSelection: function () { return !!s.selDrag; },
```

- [ ] **Step 2: `ui.js`:装交互**

在 `ui.js` 的 `mirrorRegion` **之后**插入:

```js
  // ── 交互(指针 / 滚轮 / 热键)──
  // ★ 一切落笔都走同一条路:applyTool(只碰地图)→ 差量进历史 → renderer.editCells
  //   (只碰缓存与像素)。把"改数据"与"作废缓存"分成两步是刻意的:漏了哪一半
  //   都能在断言里指名道姓。
  var undoHistory = null;
  var clipboard = null;

  function pushAndShow(diff) {
    if (!diff) return false;
    undoHistory.push(diff);
    var cells = diffCells(app.map, diff);
    if (cells.length) app.r.editCells(diff.layer, cells);
    else app.r.render();
    statusLine();
    return true;
  }
  function doUndo() {
    var e = undoHistory.undo();
    if (!e) { status('没有可撤销的操作'); return; }
    applyEntry(app.map, e, -1);
    afterStateChange(e);
  }
  function doRedo() {
    var e = undoHistory.redo();
    if (!e) { status('没有可重做的操作'); return; }
    applyEntry(app.map, e, +1);
    afterStateChange(e);
  }
  function afterStateChange(e) {
    if (e.kind === 'whole') { app.r.setMap(app.map); }       // ★ 尺寸可能变了:必须重挂
    else if (e.kind === 'cells') {
      var cells = diffCells(app.map, e);
      if (cells.length) app.r.editCells(e.layer, cells); else app.r.render();
    } else app.r.render();
    statusLine();
  }
  // 长作业(油漆桶 / 渐变):分帧驱动(闸 2),每帧一批,做完落成一条差量。
  function runJob(job, onApply, label) {
    var CHUNK = 20000;                       // 一批 2 万格:远小于一帧的预算
    return new Promise(function (resolve) {
      function step() {
        var r = job.runChunk(CHUNK);
        if (!r.done) {
          status((label || '处理中') + ' … ' + r.total);
          requestAnimationFrame(step);
          return;
        }
        onApply(r.total);
        resolve();
      }
      step();
    });
  }
  function statusLine() {
    if (!app.map) return;
    var set = function (id, txt) { var el = $(id); if (el) el.textContent = txt; };
    set('st-tool', '工具 ' + (TOOL_LABELS[app.st.tool] || app.st.tool) + ' × ' + app.st.brushSize);
    set('st-tex', '纹理 ' + Core.texOf(app.st.desc));
    set('st-desc', '辅码 ' + Core.hueOf(app.st.desc) + '/' + Core.brightOf(app.st.desc) + '/' +
                   Core.satOf(app.st.desc) + '/' + Core.alphaOf(app.st.desc));
    var sel = app.r.selection();
    set('st-sel', sel ? ('选区 ' + (sel.w / Core.SUB_PER_CELL) + '×' + (sel.h / Core.SUB_PER_CELL) + ' 格') : '无选区');
    set('st-undo', '撤销 ' + undoHistory.depth() + ' / 重做 ' + undoHistory.redoDepth());
  }

  function hitOf(ev) {
    var cv = app.canvas;
    var rect = cv.getBoundingClientRect();
    var p = app.r.screenToSub(ev.clientX - rect.left, ev.clientY - rect.top);
    // ★ 两种单位的吸附只在 hitOf 里决定一次:整数画笔吸附到格、小数画笔吸附到子格
    var unit = Render.brushSpan(app.st.brushSize).unit;
    var k = Core.SUB_PER_CELL;
    return unit === 'sub' ? { kind: 'sub', x: p.X, y: p.Y }
                          : { kind: 'cell', x: Math.floor(p.X / k), y: Math.floor(p.Y / k) };
  }
  function k2of(hit) { return hit.kind === 'cell' ? Core.SUB_PER_CELL : 1; }
  function stNow() {
    return { map: app.map, layer: app.r.layer(), desc: app.st.desc, rgba: app.st.rgba,
             brushSize: app.st.brushSize, selection: app.r.selection(), descOnly: app.st.descOnly };
  }
  function subRectOf(from, to) {
    var k = Core.SUB_PER_CELL;
    var x0 = from.x * k2of(from), y0 = from.y * k2of(from);
    var x1 = to.x * k2of(to), y1 = to.y * k2of(to);
    return { x: Math.min(x0, x1), y: Math.min(y0, y1),
             w: Math.abs(x1 - x0) + k, h: Math.abs(y1 - y0) + k };
  }
  // Shift 约束后的落点(★ 规格 §4.8)。★ 预览与落笔**必须**走同一个函数 ——
  //   否则预览画的是 A、松手落下去的是 B(这类不一致只在动手时才看得出来)。
  function shiftHit(from, to, shift) {
    var c = constrainLine(toSub(from), toSub(to), shift);
    return { kind: 'sub', x: c.x, y: c.y };
  }
  function squareHit(from, to, shift) {
    var c = constrainSquare(toSub(from), toSub(to), shift);
    return { kind: 'sub', x: c.x, y: c.y };
  }

  function installInteraction() {
    var cv = app.canvas;
    undoHistory = createHistory({});
    app.st = { tool: 'brush', brushSize: 1, desc: Core.neutralDesc(1), rgba: 0xFF00FFFF,
               descOnly: false, selStart: null, stroke: null, panning: null, selDrag: null,
               gradStart: null };

    cv.addEventListener('contextmenu', function (e) { e.preventDefault(); });

    cv.addEventListener('pointerdown', function (ev) {
      if (cv.setPointerCapture) cv.setPointerCapture(ev.pointerId);
      guard('pointerdown', function () {
        if (ev.button === 1 || ev.altKey) {          // 中键 / Alt = 平移
          app.st.panning = { x: ev.clientX, y: ev.clientY };
          return;
        }
        if (ev.button !== 0) return;
        var hit = hitOf(ev);
        var sel = app.r.selection();
        if (app.st.tool === 'select') {
          if (sel && hit.kind === 'sub' && inRect(sel, hit.x, hit.y)) {
            app.st.selDrag = { from: hit, dx: 0, dy: 0 };   // 选区内按下 = 拖动它
          } else {
            app.st.selStart = hit;
          }
          return;
        }
        if (app.st.tool === 'picker') {
          var p = app.r.screenToSub(ev.clientX - cv.getBoundingClientRect().left,
                                    ev.clientY - cv.getBoundingClientRect().top);
          var v = pickAt(app.map, app.r.layer(), p.X, p.Y);
          if (app.r.layer() === Core.LAYER_BG) app.st.rgba = v >>> 0;
          else if (Core.texOf(v) !== 0) app.st.desc = v >>> 0;   // ★ 空气不吸(会吸出一个空纹理)
          status('吸管:0x' + (v >>> 0).toString(16) + (Core.texOf(v) === 0 ? '(空气,未采用)' : ''));
          statusLine();
          return;
        }
        if (app.st.tool === 'bucket') {
          var s0 = stNow();
          var job = createBucketJob(app.map, s0.layer, hit.x * k2of(hit), hit.y * k2of(hit),
                                    { clip: s0.selection });
          runJob(job, function () {
            pushAndShow(paintCells(app.map, s0.layer, job.result(), valueFor(s0, s0.layer)));
          }, '油漆桶填充');
          return;
        }
        if (app.st.tool === 'gradient') {
          // ★ 规格 §4.4:渐变**仅背景层**。工具按钮只是压暗(视觉提示),真正的闸在这里 ——
          //   少了它,在纹理层拖渐变会**悄悄改掉背景层**(屏幕上看不出,因为背景在最底下)。
          if (app.r.layer() !== Core.LAYER_BG) { status('渐变只能用在背景层(它改的是颜色,不是纹理)'); return; }
          app.st.gradStart = hit;
          return;
        }
        app.st.stroke = { from: hit, last: hit };     // 画笔/橡皮/矩形/直线
      });
    });

    cv.addEventListener('pointermove', function (ev) {
      guard('pointermove', function () {
        if (app.st.panning) {
          var dxp = ev.clientX - app.st.panning.x, dyp = ev.clientY - app.st.panning.y;
          app.st.panning.x = ev.clientX; app.st.panning.y = ev.clientY;
          app.r.panBy(dxp, dyp);
          return;
        }
        var hit = hitOf(ev);
        if (app.st.selDrag) {                          // ★ 拖动只记偏移(不碰数据)
          var f = app.st.selDrag.from;
          var ddx = hit.x * k2of(hit) - f.x * k2of(f);
          var ddy = hit.y * k2of(hit) - f.y * k2of(f);
          app.st.selDrag.dx = ddx; app.st.selDrag.dy = ddy;
          app.r.setSelDrag(app.r.selection(), ddx, ddy);
          return;
        }
        if (app.st.selStart) { app.r.setPreview(subRectOf(app.st.selStart, squareHit(app.st.selStart, hit, ev.shiftKey))); return; }
        if (app.st.gradStart) { app.r.setPreview(subRectOf(app.st.gradStart, hit)); return; }
        if (app.st.stroke) {
          if (app.st.tool === 'brush' || app.st.tool === 'eraser') {
            pushAndShow(applyTool(stNow(), app.st.tool, app.st.stroke.last, hit));
            app.st.stroke.last = hit;
          } else if (app.st.tool === 'line') {
            app.r.setPreview(subRectOf(app.st.stroke.from, shiftHit(app.st.stroke.from, hit, ev.shiftKey)));
          } else {
            app.r.setPreview(subRectOf(app.st.stroke.from, hit));
          }
        }
      });
    });

    cv.addEventListener('pointerup', function (ev) {
      guard('pointerup', function () {
        if (app.st.panning) { app.st.panning = null; return; }
        var hit = hitOf(ev);
        if (app.st.selDrag) {
          var sd = app.st.selDrag;
          app.st.selDrag = null;
          app.r.setSelDrag(null, 0, 0);
          if (sd.dx !== 0 || sd.dy !== 0) {
            var cur = app.r.selection();
            pushAndShow(moveRegion(app.map, app.r.layer(), cur, sd.dx, sd.dy));
            app.r.setSelection({ x: cur.x + sd.dx, y: cur.y + sd.dy, w: cur.w, h: cur.h });
          }
          statusLine();
          return;
        }
        if (app.st.selStart) {
          var rect = subRectOf(app.st.selStart, squareHit(app.st.selStart, hit, ev.shiftKey));
          app.st.selStart = null;
          app.r.setPreview(null);
          app.r.setSelection(rect);
          statusLine();
          return;
        }
        if (app.st.gradStart) {
          var a = app.st.gradStart;
          app.st.gradStart = null;
          app.r.setPreview(null);
          var s1 = stNow();
          var gj = createGradientJob(app.map,
            { x: a.x * k2of(a), y: a.y * k2of(a) },
            { x: hit.x * k2of(hit), y: hit.y * k2of(hit) },
            s1.rgba, s1.rgba, { clip: s1.selection });
          runJob(gj, function () {
            var res = gj.result(), targets = [], values = [], n = 0;
            for (var i = 0; i < res.length; i++) { targets.push(res[i].i); values.push(res[i].rgba); }
            pushAndShow(paintCells(app.map, Core.LAYER_BG, targets, function () { return values[n++]; }));
          }, '渐变');
          return;
        }
        if (app.st.stroke) {
          var st0 = app.st.stroke;
          app.st.stroke = null;
          app.r.setPreview(null);
          if (app.st.tool === 'rect') {
            pushAndShow(applyTool(stNow(), 'rect', st0.from, hit));
          } else if (app.st.tool === 'line') {
            // ★ Shift 约束(规格 §4.8):直线锁水平/垂直/45° —— 与预览同一个函数
            pushAndShow(applyTool(stNow(), 'line', st0.from, shiftHit(st0.from, hit, ev.shiftKey)));
          }
        }
      });
    });

    cv.addEventListener('wheel', function (ev) {
      guard('wheel', function () {
        ev.preventDefault();
        var rect = cv.getBoundingClientRect();
        app.r.setZoomAt(ev.clientX - rect.left, ev.clientY - rect.top, ev.deltaY < 0 ? 1.25 : 0.8);
        statusLine();
      });
    }, { passive: false });

    window.addEventListener('keydown', function (ev) {
      var cmd = commandFor(ev);
      if (!cmd) return;                                  // ★ 表外的键一律不拦
      guard('keydown', function () {
        ev.preventDefault();
        if (cmd.indexOf('tool:') === 0) { app.st.tool = cmd.slice(5); selectToolButton(); }
        else if (cmd === 'brush-smaller') { setBrush(bumpBrush(app.st.brushSize, -1)); }
        else if (cmd === 'brush-bigger') { setBrush(bumpBrush(app.st.brushSize, 1)); }
        else if (cmd.indexOf('layer:') === 0) { setLayer(parseInt(cmd.slice(6), 10)); }
        else if (cmd === 'undo') doUndo();
        else if (cmd === 'redo') doRedo();
        else if (cmd === 'copy') {
          clipboard = copyRegion(app.map, app.r.layer(), app.r.selection());
          status(clipboard ? '已复制 ' + clipSize(clipboard).w + '×' + clipSize(clipboard).h : '先框选一块');
        }
        else if (cmd === 'cut') {
          var s2 = app.r.selection();
          if (!s2) { status('先框选一块'); return; }
          clipboard = copyRegion(app.map, app.r.layer(), s2);
          pushAndShow(applyTool({ map: app.map, layer: app.r.layer(), desc: 0, rgba: 0,
                                  brushSize: 0.25, selection: s2 },
                                'rect', { kind: 'sub', x: s2.x, y: s2.y },
                                { kind: 'sub', x: s2.x + s2.w - 1, y: s2.y + s2.h - 1 }));
        }
        else if (cmd === 'paste') {
          var sel = app.r.selection();
          var at = sel ? { x: sel.x, y: sel.y } : { x: 0, y: 0 };
          var out = pasteRegion(app.map, app.r.layer(), clipboard, at.x, at.y);
          if (!out.ok) { status('粘贴失败:' + out.why); return; }
          pushAndShow(out.diff);
          if (sel) app.r.setSelection({ x: at.x, y: at.y, w: clipSize(clipboard).w, h: clipSize(clipboard).h });
        }
        else if (cmd === 'clear-selection') {
          var s3 = app.r.selection();
          if (!s3) { status('先框选一块'); return; }
          pushAndShow(applyTool({ map: app.map, layer: app.r.layer(), desc: 0, rgba: 0,
                                  brushSize: 0.25, selection: s3 },
                                'rect', { kind: 'sub', x: s3.x, y: s3.y },
                                { kind: 'sub', x: s3.x + s3.w - 1, y: s3.y + s3.h - 1 }));
        }
        else if (cmd === 'cancel-selection') { app.r.setSelection(null); }
        else if (cmd.indexOf('pan:') === 0) { arrowPan(cmd.slice(4)); }
        else if (cmd === 'save' || cmd === 'save-as') { saveCurrent(cmd === 'save-as'); }
        statusLine();
      });
    });

    statusLine();
  }

  var BRUSH_STEPS = [0.25, 0.5, 0.75, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
  function bumpBrush(cur, dir) {
    var i = BRUSH_STEPS.indexOf(cur);
    if (i < 0) i = 3;
    return BRUSH_STEPS[Math.max(0, Math.min(BRUSH_STEPS.length - 1, i + dir))];
  }
  function setBrush(v) {
    app.st.brushSize = Math.max(0.25, Math.min(Render.MAX_BRUSH_CELLS, v));
    var el = $('brush-size');
    if (el) el.value = String(app.st.brushSize);
    statusLine();
  }
  function arrowPan(dir) {
    var step = 64;
    var d = { left: [-step, 0], right: [step, 0], up: [0, -step], down: [0, step] }[dir];
    if (d) app.r.panBy(d[0], d[1]);
  }
  function selectToolButton() {
    document.querySelectorAll('#toolbar .tool').forEach(function (b) {
      b.classList.toggle('on', b.dataset.tool === app.st.tool);
    });
    statusLine();
  }
  function setLayer(L) {
    if (!(L >= 0 && L < Core.LAYER_COUNT)) return;
    app.r.setLayer(L);
    document.querySelectorAll('#layers .layer-row').forEach(function (row) {
      row.classList.toggle('cur', parseInt(row.dataset.layer, 10) === L);
    });
    // ★ 规格 §4.5:选中的是**背景层**时,右侧的纹理调色板换成颜色选择器,工具条里只有
    //   「渐变」额外可用。这个 hook 由 Task 8 提供(typeof 守卫:Task 7 单独跑时也能过)。
    if (typeof syncPanelForLayer === 'function') syncPanelForLayer();
    statusLine();
  }
```

★ `saveCurrent` 由 **Task 8** 提供。本 Task 派发时,`keydown` 里那一支写成:

```js
        else if (cmd === 'save' || cmd === 'save-as') { status('保存:计划里的 Task 8 才接上'); }
```

Task 8 再把这一行换成 `else if (cmd === 'save' || cmd === 'save-as') { saveCurrent(cmd === 'save-as'); }`。

在 `boot()` 的 `app.r = Render.mount(...)` **之后**加一行:

```js
    installInteraction();
```

导出表追加:

```js
    installInteraction: installInteraction, runJob: runJob, statusLine: statusLine,
    pushAndShow: pushAndShow, doUndo: doUndo, doRedo: doRedo, hitOf: hitOf,
    brushSteps: function () { return BRUSH_STEPS.slice(); }, setBrush: setBrush, setLayer: setLayer,
```

- [ ] **Step 3: 运行,确认所有冒烟仍绿**

Run:

```bash
cd level_editor && node editor_smoke.js && node render_smoke.js && node server_smoke.js
```

Expected: `EDITOR SMOKE OK` / `RENDER SMOKE OK` / `SERVER SMOKE OK`,退出码 0。(本 Task 没有新增 node 断言 —— 它的产物是**浏览器行为**,由下一步的人眼验收覆盖。)

- [ ] **Step 4: 人眼验收(逐条点,把结果贴回报告)**

**测试由用户自己跑**。清单:

1. `serve.bat` → 打开页面 → 打开一张地图(用副本,别直接用仓库里的真图);
2. **画笔**:选「画笔」,在画布上**拖动** → 应留下连续的一笔(不是断点);按 `[` / `]` 画笔大小在状态栏里变化;
3. 顺时针挨个试:矩形(拖出框、**松手才落地**)、油漆桶(点一下填一整片,**页面不卡死**)、橡皮、直线(**松手才落地**)、吸管(点一下,状态栏纹理号变成吸到的那块);
4. **选框**:拖出一个框 → 框内按住再拖 → **框跟着鼠标走**(带虚线预览),**松手后内容才真的移动一次**;`Delete` 清空选区;`Esc` 取消;`Ctrl+C` / `Ctrl+V` 复制粘贴;
5. **撤销/重做**:连按 `Ctrl+Z` → 每一步都回退一格;**连续撤销 5 步再重做 5 步,画面回到原样**;
6. **滚轮缩放**:应**朝着鼠标所在的位置**缩放(鼠标下的那一格不动);
7. **平移**:按住中键拖动(或 Alt+拖)→ 画面跟手、不闪;方向键也能平移;
8. **热键**:`B`/`E`/`G`/`M`/`L`/`I` 切换工具时,工具条上那个按钮高亮跟着变;
9. **背景层**:切到「背景层」,用画笔拖一笔 → 应画出**颜色**(不是纹理);再切回「场景层」画一笔 → 纹理;
10. 控制台**零红字**;把 `copy(JSON.stringify(Editor.app.r.stats()))` 的结果贴回报告。

Expected:以上 10 条全部符合。★ 特别地:第 4 条的"松手才移动"与第 9 条的"背景层是颜色"是这一版新写的两条语义 —— 若行为不符,先怀疑 `setSelDrag` / `valueFor` 这两处。

- [ ] **Step 5: 提交**

```bash
git add level_editor/render.js level_editor/ui.js
git commit -F - <<'EOF'
feat(editor): 画布交互 —— 指针工具 / 选区拖动 / 热键 / 状态栏

一切落笔走同一条路:applyTool(只碰地图)→ 差量进历史 → renderer.editCells
(只碰缓存与像素)。把"改数据"与"作废缓存"分成两步是刻意的:漏了哪一半都能在
断言里指名道姓。

★ 选区拖动只记 (dx,dy),渲染时对选区内做**偏移查询**(纯读),松手才提交一次
moveRegion —— 老实现每次 pointermove 深拷贝三份全图(B3),这是新架构里最贵的
单点,现在归零。★ 油漆桶与渐变分帧驱动(闸 2):一批 2 万格,大图上是"慢慢填出来"
而不是"页面卡死"。
EOF
```

---

## Task 8: 面板与库工作流(工具条 / 图层 / 调色板 / 辅码 / spawn / 打开保存 / 导出校验)

**Files:**
- Modify: `level_editor/ui.js`(面板构建、库按钮、保存、导出校验、v3 源保存确认)
- Modify: `level_editor/editor_smoke.js`(追加相位 ⑬:保存路径的纯逻辑)

**Interfaces:**
- Consumes:Task 5 的 `texturePalette` / `clampTexture` / `validateLines` / `addSpawn` / `clearSpawns` / `spawnDiff` / `snapshotSpawns` / `createEmptyMap` / `resizeMap`、Task 6 的 `createHistory`、Task 7 的 `setLayer` / `selectToolButton` / `pushAndShow` / `statusLine` / `setBrush`
- Produces:
  - `Editor.buildPanels() -> void`
  - `Editor.saveCurrent(asNew) -> Promise<void>`(★ PUT 显式带 `Content-Type: application/json`)
  - `Editor.saveTargetName(asNew) -> String|null`(纯)
  - `Editor.needsV3Confirm(srcFmt, confirmed) -> Boolean`(纯:决定 ⑤)
  - `Editor.freshName(base) -> String`(纯:`Core.sanitizeName` + `.cyrm`)
  - `Editor.importEnemyTypes() -> Array<String>`(从 `window.ENEMY_REGISTRY` 取)
  - `Editor.exportReport() -> {lines:Array<String>, ok:Boolean}`
  - `Editor.showExportReport() -> void`

- [ ] **Step 1: 在 `editor_smoke.js` 的 `// ==== 相位 ⑫`(镜像那一段)之后追加相位 ⑬**

```js
    // ==== 相位 ⑬ 保存路径的纯逻辑(决定 ⑤:v3 源首次保存要确认)====
    eq(Editor.saveTargetName(false), null, 'saveTargetName(false): 未打开任何地图 → null(调用方提示先打开)');
    eq(Editor.needsV3Confirm('v4', false), false, '★★ v4 源:直接保存,不问(v4 → v4 是无损的)');
    eq(Editor.needsV3Confirm('v3', false), true,
       '★★ v3 文本源:首次保存要确认(保存会把它转成 v4 二进制,不可逆 —— 规格 §3.6)');
    eq(Editor.needsV3Confirm('legacy', false), true, '★ 旧字母格式源:同样要确认');
    eq(Editor.needsV3Confirm('v3', true), false, '★ 已经确认过一次的会话不再问第二次');
    eq(Editor.needsV3Confirm(null, false), false, '没打开地图时不问');
    eq(Editor.freshName('my map!'), 'my_map.cyrm', '★ freshName 走 sanitizeName(服务器只收裸文件名)');
    ok(Editor.importEnemyTypes().length > 0, '★ 敌人类型来自页面里的 ENEMY_REGISTRY(不是写死的清单)');
    ok(Editor.importEnemyTypes().indexOf('fly_bird') >= 0, '注册表里有 fly_bird');
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node editor_smoke.js`

Expected: `FAIL - saveTargetName(false): 未打开任何地图 → null(调用方提示先打开)`,随后 `TypeError: Editor.needsV3Confirm is not a function`,退出码 1。

- [ ] **Step 3: 在 `ui.js` 里加保存、面板与库工作流**

在 `ui.js` 的 `setLayer` **之后**插入:

```js
  // ── 保存(★ 决定 ⑤:v3 源首次保存要一次显式确认)──
  // ★ 为什么必须确认:仓库里 maps/*.cyrm **今天全是 v3 文本**,而 Ctrl+S 写回原文件
  //   (规格 §4.6)⇒ 一次 Ctrl+S 就把 v3 原文转成 v4 二进制,而迁移是**单向**的
  //   (规格 §3.6「迁移是一次性的」)。期 E 会专门做迁移并先提交一份 v3 原文留档。
  var v3Confirmed = false;
  function needsV3Confirm(srcFmt, confirmed) {
    if (!srcFmt) return false;
    return (srcFmt === 'v3' || srcFmt === 'legacy') && !confirmed;
  }
  function freshName(base) { return Core.sanitizeName(base) + '.cyrm'; }
  function saveTargetName(asNew) {
    if (!app.map) return null;
    return asNew ? freshName((app.map.name || 'map') + '_copy') : app.name;
  }
  function saveCurrent(asNew) {
    if (!app.map) { status('先打开一张地图'); return Promise.resolve(); }
    if (needsV3Confirm(app.sourceFormat, v3Confirmed)) {
      var okGo = window.confirm('原文件是 v3 文本,保存会把它转成 v4 二进制(不可逆)。\n' +
                                '期 E 会专门做迁移并先提交一份 v3 原文留档。(本次会话不再询问)');
      if (!okGo) { status('已取消保存(磁盘上那份没有被碰过)'); return Promise.resolve(); }
      v3Confirmed = true;
    }
    var name = saveTargetName(asNew);
    if (!name) return Promise.resolve();
    status('保存 ' + name + ' …');
    return Io.encodeMap(app.map, { compress: true }).then(function (bytes) {
      // ★★ PUT **必须**显式设 Content-Type: application/json(写端点只收这一个;
      //    不设的话浏览器给的是 Blob 的默认类型 ⇒ 服务器 415 ⇒ 用户看到"存不进去")。
      return fetch('/api/map?p=' + encodeURIComponent(name), {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: new Blob([bytes]),
      }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status + (r.status === 415 ? '(内容类型不对)' : ''));
        return r.json();
      }).then(function (out) {
        app.name = name;
        app.raw = bytes;
        app.sourceFormat = 'v4';
        status('已保存 ' + out.name + '(' + out.size + ' 字节)');
        refreshLibrary();               // 库列表里的字节数/时间跟着更新
        refreshStatus();
        statusLine();
      });
    }).catch(function (e) {
      // ★ 保存失败要**说出来**;磁盘上那份没被动过(服务器是原子写)
      status('保存失败:' + msgOf(e));
    });
  }

  // ── 敌人类型(来自页面里的注册表 —— 不写死清单)──
  function importEnemyTypes() {
    var reg = globalThis.ENEMY_REGISTRY;
    if (!reg || !reg.length) return [];
    return reg.map(function (e) { return String(e.id); });
  }

  // ── 导出校验(规格 §4.7:只警告,不阻止导出)──
  function exportReport() {
    if (!app.map) return { lines: ['还没打开地图'], ok: false };
    var rep = Core.validateMap(app.map);
    var lines = validateLines(rep);
    if (!lines.length) lines = ['校验通过:没有发现问题'];
    lines.push('尺寸 ' + Core.cellsWOf(app.map) + '×' + Core.cellsHOf(app.map) + ' 格 · 出生点 ' +
               app.map.players.length + ' · 敌人 ' + app.map.enemies.length);
    if ((app.map.players.length > 2)) {
      lines.push('⚠ 第 3 个及以后的出生点游戏侧读不到(map_format.gd 只认 player/player2)');
    }
    return { lines: lines, ok: rep.errors.length === 0 };
  }
  function showExportReport() {
    var rep = exportReport();
    window.alert(rep.lines.join('\n'));
    status(rep.ok ? '导出校验:没有 error' : '导出校验:有 error(encodeMap 会拒绝导出)');
  }

  // ── 面板构建(★ 每个控件只挂一次监听 —— 审计 A16:旧实现同时挂了 22 个独立监听
  //    与一个容器委托,点一次跑两遍)──
  function buildPanels() {
    document.querySelectorAll('#layers .layer-row').forEach(function (row) {
      var L = parseInt(row.dataset.layer, 10);
      row.addEventListener('click', function () { setLayer(L); });
      row.querySelector('.vis').addEventListener('click', function (ev) {
        ev.stopPropagation();
        var on = !app.r.layerVisible(L);
        app.r.setLayerVisible(L, on);
        this.style.opacity = on ? '1' : '0.35';
      });
      row.querySelector('.lock').addEventListener('click', function (ev) {
        ev.stopPropagation();
        var on = !app.r.layerLocked(L);
        app.r.setLayerLocked(L, on);
        this.style.opacity = on ? '0.35' : '1';
      });
    });
    // 纹理调色板(★ 从 tile_defs 派生;纹理 22 不在其中 —— 审计 A7)
    var pal = texturePalette(app.tileDefs);
    var box = $('palette');
    pal.forEach(function (e) {
      var b = document.createElement('button');
      b.className = 'sw';
      b.title = e.tex + ' ' + e.name + (e.type ? '(' + e.type + ')' : '');
      b.textContent = String(e.tex);
      b.addEventListener('click', function () {
        app.st.desc = Core.packDesc(e.tex, Core.hueOf(app.st.desc), Core.brightOf(app.st.desc),
                                    Core.satOf(app.st.desc), Core.alphaOf(app.st.desc));
        document.querySelectorAll('#palette .sw').forEach(function (x) { x.classList.remove('on'); });
        b.classList.add('on');
        statusLine();
      });
      box.appendChild(b);
    });
    if (DERIVED_TEXTURES.length) {
      var hint = document.createElement('div');
      hint.className = 'desc-row';
      hint.textContent = '纹理 ' + DERIVED_TEXTURES.join('/') + ' 不进调色板:游戏侧由地形自动派生';
      box.parentNode.insertBefore(hint, box.nextSibling);
    }
    // 辅码四组档位
    [['desc-hue', 'hueOf'], ['desc-bri', 'brightOf'],
     ['desc-sat', 'satOf'], ['desc-alp', 'alphaOf']].forEach(function (spec) {
      var sel = $(spec[0]);
      if (!sel) return;
      for (var k = 0; k < Core.SUB_PER_CELL * 2; k++) {
        var o = document.createElement('option');
        o.value = String(k); o.textContent = String(k);
        sel.appendChild(o);
      }
      sel.value = String(Core[spec[1]](app.st.desc));
      sel.addEventListener('change', function () {
        app.st.desc = Core.packDesc(Core.texOf(app.st.desc), +$('desc-hue').value, +$('desc-bri').value,
                                    +$('desc-sat').value, +$('desc-alp').value);
        statusLine();
      });
    });
    var only = $('desc-only');
    if (only) only.addEventListener('change', function () { app.st.descOnly = only.checked; });
    var bs = $('brush-size');
    if (bs) {
      bs.addEventListener('change', function () { setBrush(parseFloat(bs.value) || 1); });
    }
    document.querySelectorAll('#toolbar .tool').forEach(function (b) {
      b.addEventListener('click', function () { app.st.tool = b.dataset.tool; selectToolButton(); });
    });
    $('tg-grid').addEventListener('click', function () {
      this.classList.toggle('on'); app.r.setGrid(this.classList.contains('on'));
    });
    $('tg-subgrid').addEventListener('click', function () {
      this.classList.toggle('on'); app.r.setSubGrid(this.classList.contains('on'));
    });
    $('tg-torus').addEventListener('click', function () {
      this.classList.toggle('on'); app.r.setTorus(this.classList.contains('on'));
    });
    var dim = $('dim-others');
    if (dim) dim.addEventListener('change', function () { app.r.setDimOthers(dim.checked); });
    var p1 = $('spawn-p1'), p2 = $('spawn-p2'), en = $('spawn-enemy'), cl = $('spawn-clear');
    if (p1) p1.addEventListener('click', function () { spawnAt('player', 0); });
    if (p2) p2.addEventListener('click', function () { spawnAt('player', 1); });
    if (en) en.addEventListener('click', function () { spawnAt('enemy', 0); });
    if (cl) cl.addEventListener('click', function () { pushAndShow(clearSpawns(app.map)); });
    var libList = $('lib-list');
    if (libList) {
      libList.addEventListener('click', function (ev) {          // ★ 委托一次,不给每行挂监听
        var row = ev.target.closest ? ev.target.closest('.lib-row') : null;
        if (row && row.dataset.name) openMap(row.dataset.name);
      });
    }
    var bn = $('btn-new'), bd = $('btn-dup'), br = $('btn-rename'), bx = $('btn-del');
    if (bn) bn.addEventListener('click', function () {
      var name = window.prompt('新地图名字(不含 .cyrm)', 'new_map');
      if (!name) return;
      var m = createEmptyMap(name, 125, 75);       // ★ 尺寸只经这一个闸
      app.map = m; app.name = freshName(name);
      app.sourceFormat = 'v4';
      undoHistory = createHistory({});
      app.r.setMap(m);
      status('新建 ' + app.name + '(还没写盘 —— Ctrl+S 才落盘)');
      refreshStatus(); statusLine();
    });
    if (bd) bd.addEventListener('click', function () {
      if (!app.map) { status('先打开一张地图'); return; }
      var copy = resizeMap(app.map, Core.cellsWOf(app.map), Core.cellsHOf(app.map)).map;
      copy.name = (app.map.name || 'map') + '_copy';
      app.map = copy;
      app.name = freshName(copy.name);
      app.sourceFormat = 'v4';
      undoHistory = createHistory({});
      app.r.setMap(copy);
      status('已复制为 ' + app.name + '(还没写盘)');
      refreshStatus();
    });
    if (br) br.addEventListener('click', function () {
      if (!app.map) { status('先打开一张地图'); return; }
      var n = window.prompt('新的名字(不含 .cyrm)', app.map.name);
      if (!n) return;
      app.map.name = Core.sanitizeName(n);
      app.name = app.map.name + '.cyrm';
      status('改名为 ' + app.name + '(还要 Ctrl+S 才写盘)');
      refreshStatus();
    });
    if (bx) bx.addEventListener('click', function () {
      status('删除地图请直接在磁盘上删 maps/ 下的文件(编辑器不做删除动作 —— 这是故意的)');
    });
    var exp = $('btn-export');
    if (exp) exp.addEventListener('click', showExportReport);
    // ★ 背景层的颜色选择器(规格 §4.5):选中的是背景层时,纹理调色板与辅码四组换成它。
    var bgc = $('bg-color');
    if (bgc) {
      bgc.addEventListener('input', function () {
        // #RRGGBB → 0xRRGGBBFF(背景层是不透明的真彩;alpha 由辅码那一路管不了它)
        var m = /^#([0-9a-f]{6})$/i.exec(bgc.value);
        if (!m) return;
        app.st.rgba = (parseInt(m[1], 16) * 256 + 255) >>> 0;
        var lab = $('bg-color-val');
        if (lab) lab.textContent = bgc.value;
        statusLine();
      });
      var m0 = /^#([0-9a-f]{6})$/i.exec(bgc.value);
      if (m0) app.st.rgba = (parseInt(m0[1], 16) * 256 + 255) >>> 0;
    }
    selectToolButton();
    syncPanelForLayer();
    statusLine();
  }

  // 背景层时把"纹理调色板 + 辅码"换成"颜色选择器"(规格 §4.5)。
  // ★ 只切显示,不动任何数据:切回纹理层时用户刚才选的纹理/辅码还在。
  function syncPanelForLayer() {
    var isBg = (app.r.layer() === Core.LAYER_BG);
    var show = function (id, on) { var el = $(id); if (el) el.style.display = on ? '' : 'none'; };
    show('palette', !isBg);
    show('bg-color-row', isBg);
    show('bg-color-title', isBg);
    ['desc-hue', 'desc-bri', 'desc-sat', 'desc-alp'].forEach(function (id) {
      var el = $(id);
      if (el && el.parentNode) el.parentNode.style.display = isBg ? 'none' : '';
    });
    var titles = document.querySelectorAll('#right h2');
    for (var i = 0; i < titles.length; i++) {
      if (titles[i].textContent === '辅码') titles[i].style.display = isBg ? 'none' : '';
    }
    // ★ 工具条上"渐变只在背景层可用":其余工具照旧(纹理层没有颜色可插值,故渐变**只在**背景层)
    var g = document.querySelector('#toolbar .tool[data-tool="gradient"]');
    if (g) g.style.opacity = isBg ? '1' : '0.45';
  }

  function spawnAt(kind, playerIndex) {
    if (!app.map) { status('先打开一张地图'); return; }
    var v = app.r.view();
    // 视图中心那一格(不猜鼠标位置:按下按钮时鼠标在按钮上)
    var cx = Math.round((v.x + app.canvas.width / v.zoom / 2) / Core.SUB_PER_CELL);
    var cy = Math.round((v.y + app.canvas.height / v.zoom / 2) / Core.SUB_PER_CELL);
    var types = importEnemyTypes();
    if (kind === 'player' && playerIndex > 0) {
      var before = snapshotSpawns(app.map);
      if (app.map.players.length <= playerIndex) app.map.players.push({ x: cx, y: cy });
      else app.map.players[playerIndex] = { x: cx, y: cy };
      pushAndShow(spawnDiff(before, snapshotSpawns(app.map)));
      status('P' + (playerIndex + 1) + ' 放到 (' + cx + ',' + cy + ')');
      return;
    }
    pushAndShow(addSpawn(app.map, kind === 'enemy' ? 'enemy' : 'player', cx, cy,
                         types[0] || 'fly_bird'));
    status(kind === 'enemy' ? ('敌人放到 (' + cx + ',' + cy + ')') : ('P1 放到 (' + cx + ',' + cy + ')'));
  }
```

把 Task 7 里那一行占位替换掉:

```js
        else if (cmd === 'save' || cmd === 'save-as') { status('保存:计划里的 Task 8 才接上'); }
```

换成:

```js
        else if (cmd === 'save' || cmd === 'save-as') { saveCurrent(cmd === 'save-as'); }
```

`boot()` 里在 `openFromUrl()` 之后加 `buildPanels();`(顺序:面板要在图打开之后建,因为调色板与 spawn 工具都读 `app.map` 的尺寸)。

导出表追加:

```js
    buildPanels: buildPanels, syncPanelForLayer: syncPanelForLayer,
    saveCurrent: saveCurrent, saveTargetName: saveTargetName,
    needsV3Confirm: needsV3Confirm, freshName: freshName,
    importEnemyTypes: importEnemyTypes, exportReport: exportReport, showExportReport: showExportReport,
    spawnAt: spawnAt,
```

- [ ] **Step 4: 在 `editor.html` 的库按钮那一行加一个「导出校验」按钮**

把:

```html
    <div id="lib-btns">
      <button id="btn-new">新建</button>
      <button id="btn-dup">复制</button>
      <button id="btn-rename">重命名</button>
      <button id="btn-del">删除</button>
    </div>
```

改成:

```html
    <div id="lib-btns">
      <button id="btn-new">新建</button>
      <button id="btn-dup">复制</button>
      <button id="btn-rename">重命名</button>
      <button id="btn-del">删除</button>
      <button id="btn-export">导出校验</button>
    </div>
```

- [ ] **Step 5: 运行,确认通过**

Run:

```bash
cd level_editor && node editor_smoke.js && node server_smoke.js
```

Expected: `EDITOR SMOKE OK` / `SERVER SMOKE OK`,退出码 0。

- [ ] **Step 6: 人眼验收(★ 这一步会**真的写盘**,先用一份副本试)**

**测试由用户自己跑**。实现者把清单抄进报告。清单:

1. `serve.bat` → 打开页面;在文件管理器里把 `maps/demo.cyrm` **复制**成 `maps/demo_copy.cyrm`,编辑器里打开 `demo_copy.cyrm`;
2. **纹理调色板**:点几个纹理 → 状态栏「纹理 N」跟着变;调色板里**没有 22**,下方有一行说明;
3. **辅码**:四个下拉各调一档再画一笔 → 颜色随之变化(色相/亮度/饱和/透明四个方向各自可辨);勾上「只改辅码」再画 → **纹理不变、只有颜色变**;
3b. **Shift 约束**:选「直线」,按住 `Shift` 斜着拖 → 线被锁成水平或垂直(拖得接近 45° 时锁成 45°),**松手落下去的那条线与预览完全一致**;选「选框」按住 `Shift` 拖 → 框是正方形;
4. **图层**:点「背景层」行 → 该行高亮,且**右侧的纹理调色板与辅码换成颜色选择器**;用颜色选择器挑个色,在画布上拖一笔 → 画出来的是**那个颜色**;👁 关掉「场景层」→ 画布上场景层的砖消失;切回「场景层」→ 调色板与辅码回来,画一笔 → 是纹理不是颜色;
5. **spawn**:点「放 P1」/「放 P2」/「放敌人」→ 画布中央出现标记;`Ctrl+Z` 能撤销;点「导出校验」看得到出生点/敌人条数;
6. **保存(★ 会写盘)**:在 `demo_copy.cyrm` 上画几笔 → 按 `Ctrl+S` → **应弹出 v3 转换确认框**(因为原文件是 v3 文本)→ 点确定 → 状态栏显示「已保存 …(N 字节)」;文件管理器里看该文件**大小与修改时间都变了**;再按一次 `Ctrl+S` → **不再弹框**;
7. **关掉页面重开** → 打开那张 `demo_copy.cyrm` → 刚才画的东西**还在**(v4 往返无损);
8. 控制台**零红字** —— 尤其不能出现 `415`(那就是 PUT 少了 `Content-Type`)。

Expected:8 条全部符合。★ 用副本试,别拿 `demo.cyrm` / `factory1v1.cyrm` 试(它们是仓库里的真图,而且仍是 v3 文本)。

- [ ] **Step 7: 提交**

```bash
git add level_editor/ui.js level_editor/editor.html level_editor/editor_smoke.js
git commit -F - <<'EOF'
feat(editor): 面板与库工作流 —— 工具条/图层/调色板/辅码/spawn/保存/导出校验

调色板从 tile_defs 派生(不写第二份),纹理 22 不进调色板并给出说明(A7:游戏侧
自动派生)。辅码四组档位常驻,外加「只改辅码」模式(整片墙变暗/半透明)。事件监听
一律只挂一次(审计 A16:旧实现同时挂 22 个独立监听 + 一个容器委托,点一次跑两遍)。

★★ 保存路上一道显式确认:仓库里 maps/*.cyrm 今天全是 v3 文本,而 Ctrl+S 写回原文件
⇒ 一次 Ctrl+S 就把 v3 转成 v4 二进制,而迁移不可逆。源是 v3/旧字母格式时首次保存
弹一次确认,本会话不再问。PUT 显式带 Content-Type: application/json(不设 = 415)。
EOF
```

---

## Task 9: 持久化三层 + 闸 4(IndexedDB 草稿盘 / localStorage 小状态 / 崩溃围栏)

**Files:**
- Modify: `level_editor/ui.js`(草稿盘、UI 小状态、崩溃围栏、配额告知)
- Modify: `level_editor/editor_smoke.js`(追加相位 ⑭:持久化的**纯逻辑**)

**Interfaces:**
- Consumes:`Io.encodeMap` / `Io.decodeMap`、Task 5 的 `clampTexture`、Task 6 的 `snapshotMap`、Task 7 的 `statusLine` / `installInteraction`
- Produces:
  - 常量:`DRAFT_DB = 'cyrm-editor'`、`DRAFT_STORE = 'draft'`、`CRASH_STORE = 'crash'`、`UI_STATE_KEY = 'cyrm.ui.v1'`、`MAX_LIB = 60`、`DRAFT_DEBOUNCE_MS = 1500`
  - `Editor.draftKey(name) -> String`(由 `Core.sanitizeName` 派生,**不另铸 id**)
  - `Editor.crashIsNewer(crashRec, mainRec) -> Boolean`(纯)
  - `Editor.evictPlan(records, maxEntries) -> {keep:Array<String>, drop:Array<String>}`(纯)
  - `Editor.uiStateDefaults() -> Object`、`Editor.readUiState(store) -> Object`、`Editor.writeUiState(store, st) -> void`
  - `Editor.openDraftStore() -> Promise<IDBDatabase|null>`、`Editor.saveDraft(force) -> Promise<void>`、`Editor.loadDraft(key) -> Promise<Object|null>`
  - `Editor.installCrashFence() -> void`、`Editor.checkCrashSlot() -> Promise<Boolean>`
  - `renderer` 追加:`setSelDrag` / `setPreview` / `isDraggingSelection()`(**Task 7 已加**)

- [ ] **Step 1: 在 `editor_smoke.js` 的 `// ==== 相位 ⑬` 之后追加相位 ⑭**

```js
    // ==== 相位 ⑭ 持久化的纯逻辑(★ 需要 DOM 的那半边由人眼验收)====
    eq(Editor.draftKey('demo.cyrm'), 'demo', '★ draftKey 由 sanitizeName 派生(不另铸一套 id)');
    eq(Editor.draftKey('my-map.cyrm'), 'my-map', 'draftKey: 连字符保留');
    eq(Editor.draftKey(''), 'structure', 'draftKey: 空名回落(与 Core.sanitizeName 同源)');
    eq(Editor.MAX_LIB, 60, 'MAX_LIB = 60(规格 §4.3 闸 1)');
    ok(Editor.DRAFT_DEBOUNCE_MS >= 500, '草稿落盘有防抖(不是每笔都写盘)');
    eq(Editor.DRAFT_DB, 'cyrm-editor', 'DRAFT_DB 名字固定(换名 = 老草稿全丢)');
    eq(Editor.UI_STATE_KEY, 'cyrm.ui.v1', 'UI_STATE_KEY 带版本号');

    // 崩溃槽位比主槽位新 → 提示恢复
    eq(Editor.crashIsNewer({ savedAt: 200 }, { savedAt: 100 }), true, '★ 崩溃快照比主草稿新 → 提示恢复');
    eq(Editor.crashIsNewer({ savedAt: 100 }, { savedAt: 200 }), false, '主草稿更新 → 不提示');
    eq(Editor.crashIsNewer({ savedAt: 100 }, null), true, '没有主草稿 → 有崩溃快照就提示');
    eq(Editor.crashIsNewer(null, { savedAt: 1 }), false, '没有崩溃快照 → 不提示');
    eq(Editor.crashIsNewer(null, null), false, '两个都没有 → 不提示');

    // 库条目 60 上限:先丢"已保存且最老"的
    (function () {
      const recs = [];
      for (let i = 0; i < 65; i++) recs.push({ key: 'k' + i, savedAt: 1000 + i, dirty: i % 2 === 0 });
      const plan = Editor.evictPlan(recs, 60);
      eq(plan.keep.length + plan.drop.length, 65, '★ 不丢条目:keep + drop = 全部');
      eq(plan.keep.length, 60, '★ 上限 60:留下 60 条');
      eq(plan.drop.length, 5, '★ 丢 5 条');
      const dropped = recs.filter(function (r) { return plan.drop.indexOf(r.key) >= 0; });
      ok(dropped.every(function (r) { return !r.dirty; }),
         '★★ 先丢**已保存**的(脏的那份是用户还没写盘的劳动,不许丢)');
      ok(plan.drop.length === 5, '★ 同条件时丢最老的(实得 ' + plan.drop.join(',') + ')');
      const allDirty = recs.map(function (r) { return { key: r.key, savedAt: r.savedAt, dirty: true }; });
      const plan2 = Editor.evictPlan(allDirty, 60);
      eq(plan2.drop.length, 5, '全是脏的时也得丢够(否则上限失效)');
      ok(plan2.drop.indexOf('k0') >= 0 && plan2.drop.indexOf('k1') >= 0, '全靠 savedAt 时丢最老的');
      eq(Editor.evictPlan([], 60), { keep: [], drop: [] }, '空库 → 空计划(不抛)');
    })();

    // localStorage 的 UI 小状态:读到损坏值一律回落默认(★ 尤其"玩家参考图按格坐标存")
    (function () {
      const def = Editor.uiStateDefaults();
      ok(def.playerRef && typeof def.playerRef.cx === 'number' && typeof def.playerRef.cy === 'number',
         '★★ 玩家参考图位置按**格坐标**存(cx/cy),不是屏幕像素(A13)');
      ok(def.layer >= 0 && def.layer < 4, '默认图层合法');
      const store = {};
      eq(Editor.readUiState(store), def, '空的 storage → 全集默认值');
      store[Editor.UI_STATE_KEY] = '{ 这不是 JSON';
      eq(Editor.readUiState(store), def, '★ 坏 JSON → 回落默认(不抛,编辑器还能开)');
      store[Editor.UI_STATE_KEY] = JSON.stringify({ layer: 99, zoom: -1, tool: 'nope', brushSize: 1e9 });
      const fixed = Editor.readUiState(store);
      eq(fixed.layer, def.layer, '★ 越界图层 → 回落默认(而不是让渲染器拿到 99)');
      ok(fixed.zoom > 0, '★ 负 zoom → 钳到合法值(clampZoom 不返回 0)');
      ok(Editor.TOOLS.indexOf(fixed.tool) >= 0, '★ 表外的工具名 → 回落默认(否则状态栏显示 undefined)');
      ok(fixed.brushSize <= 15, '★ 天大的画笔 → 钳到 15');
      store[Editor.UI_STATE_KEY] = JSON.stringify({ panelOpen: { lib: false } });
      const keep = Editor.readUiState(store);
      eq(keep.panelOpen.lib, false, '★ 合法字段原样保留(只回落坏字段)');
      eq(keep.playerRef, def.playerRef, '★ 缺的字段补默认(不是整份丢掉)');
    })();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node editor_smoke.js`

Expected: `FAIL - draftKey 由 sanitizeName 派生(不另铸一套 id)`,随后 `TypeError: Editor.draftKey is not a function`,退出码 1。

- [ ] **Step 3: 在 `ui.js` 里加三层持久化与崩溃围栏**

在 `ui.js` 的 `showExportReport` **之后**插入:

```js
  // ── 持久化三层(规格 §4.6)+ 闸 4(崩溃前快照)──
  // ① 真文件 maps/*.cyrm(Ctrl+S 写回)② IndexedDB 草稿盘 ③ localStorage 只存 UI 小状态。
  var DRAFT_DB = 'cyrm-editor';
  var DRAFT_STORE = 'draft';
  var CRASH_STORE = 'crash';
  var MAX_LIB = 60;
  var DRAFT_DEBOUNCE_MS = 1500;

  // ★ 草稿盘的主键 = sanitizeName(文件名):库的身份就是**文件名**(计划 2a 的裁决 ②),
  //   另铸一套 id 必然与文件那一套漂。
  function draftKey(name) { return Core.sanitizeName(nameFromFile(name)); }

  // 闸 4 的判据(纯函数,便于断言):崩溃槽位比主槽位新 ⇒ 上次是异常退出。
  function crashIsNewer(crashRec, mainRec) {
    if (!crashRec) return false;
    if (!mainRec) return true;
    return (crashRec.savedAt || 0) > (mainRec.savedAt || 0);
  }

  // 库条目上限(闸 1:60)。★ 先丢"已保存且最老"的 —— 脏的那份是用户还没写盘的劳动。
  function evictPlan(records, maxEntries) {
    var list = (records || []).slice();
    var cap = (maxEntries === undefined) ? MAX_LIB : maxEntries;
    if (list.length <= cap) return { keep: list.map(function (r) { return r.key; }), drop: [] };
    var sorted = list.slice().sort(function (a, b) {
      var ad = a.dirty ? 1 : 0, bd = b.dirty ? 1 : 0;
      if (ad !== bd) return ad - bd;                 // 干净的排前面(先被丢)
      return (a.savedAt || 0) - (b.savedAt || 0);     // 同样干净时,最老的先丢
    });
    var drop = sorted.slice(0, list.length - cap).map(function (r) { return r.key; });
    var keep = [];
    list.forEach(function (r) { if (drop.indexOf(r.key) < 0) keep.push(r.key); });
    return { keep: keep, drop: drop };
  }

  // ── localStorage 小状态(★ 读损坏值一律回落默认:编辑器要能开)──
  var UI_STATE_KEY = 'cyrm.ui.v1';
  function uiStateDefaults() {
    // ★ 玩家参考图的位置**按格坐标**存(cx/cy):按屏幕像素存的话,换窗口大小/换缩放
    //   之后语义就漂了(审计 A13)。
    return { layer: Core.LAYER_SCENE, zoom: 0, tool: 'brush', brushSize: 1,
             grid: true, subGrid: false, torus: true, dimOthers: true,
             panelOpen: { lib: true, right: true },
             playerRef: { cx: 0, cy: 0, visible: false }, selectedTexture: 1 };
  }
  function readUiState(store) {
    var def = uiStateDefaults();
    var raw = null;
    try { raw = store ? store[UI_STATE_KEY] : null; } catch (e) { raw = null; }
    if (!raw) return def;
    var obj = null;
    try { obj = JSON.parse(raw); } catch (e) { return def; }
    if (!obj || typeof obj !== 'object') return def;
    var out = uiStateDefaults();
    // ★ 逐字段校验:一个坏字段不该把整份状态丢掉,也不该把坏值原样喂给渲染器。
    if (obj.layer >= 0 && obj.layer < Core.LAYER_COUNT) out.layer = obj.layer | 0;
    if (isFinite(obj.zoom) && obj.zoom > 0) out.zoom = Render.clampZoom(obj.zoom);
    if (TOOLS.indexOf(obj.tool) >= 0) out.tool = obj.tool;
    if (isFinite(obj.brushSize) && obj.brushSize > 0) {
      out.brushSize = Math.max(0.25, Math.min(Render.MAX_BRUSH_CELLS, obj.brushSize));
    }
    ['grid', 'subGrid', 'torus', 'dimOthers'].forEach(function (k) {
      if (typeof obj[k] === 'boolean') out[k] = obj[k];
    });
    if (obj.panelOpen && typeof obj.panelOpen === 'object') {
      if (typeof obj.panelOpen.lib === 'boolean') out.panelOpen.lib = obj.panelOpen.lib;
      if (typeof obj.panelOpen.right === 'boolean') out.panelOpen.right = obj.panelOpen.right;
    }
    if (obj.playerRef && typeof obj.playerRef === 'object') {
      var pr = obj.playerRef;
      out.playerRef = {
        cx: isFinite(pr.cx) ? Math.floor(pr.cx) : def.playerRef.cx,
        cy: isFinite(pr.cy) ? Math.floor(pr.cy) : def.playerRef.cy,
        visible: pr.visible === true,
      };
    }
    if (isFinite(obj.selectedTexture) && obj.selectedTexture > 0) {
      out.selectedTexture = clampTexture(obj.selectedTexture, Render.atlasCapacity());
    }
    return out;
  }
  function writeUiState(store, uist) {
    try { store.setItem(UI_STATE_KEY, JSON.stringify(uist)); }
    catch (e) { /* 私密模式/配额满:UI 小状态丢了不影响作品,静默 */ }
  }

  // ── IndexedDB 草稿盘 ──
  function openDraftStore() {
    return new Promise(function (resolve) {
      if (typeof indexedDB === 'undefined') { resolve(null); return; }
      var req;
      try { req = indexedDB.open(DRAFT_DB, 1); } catch (e) { resolve(null); return; }
      req.onupgradeneeded = function () {
        var db = req.result;
        if (!db.objectStoreNames.contains(DRAFT_STORE)) db.createObjectStore(DRAFT_STORE, { keyPath: 'key' });
        if (!db.objectStoreNames.contains(CRASH_STORE)) db.createObjectStore(CRASH_STORE, { keyPath: 'key' });
      };
      req.onsuccess = function () { resolve(req.result); };
      req.onerror = function () { resolve(null); };      // 配额/私密模式:草稿盘不可用也要能用编辑器
    });
  }
  function idbPut(db, store, rec) {
    return new Promise(function (resolve, reject) {
      var tx = db.transaction(store, 'readwrite');
      tx.objectStore(store).put(rec);
      tx.oncomplete = function () { resolve(true); };
      tx.onerror = function () { reject(tx.error || new Error('IndexedDB 写失败')); };
      tx.onabort = function () { reject(tx.error || new Error('IndexedDB 写被中止')); };
    });
  }
  function idbGetAll(db, store) {
    return new Promise(function (resolve) {
      var tx = db.transaction(store, 'readonly');
      var rq = tx.objectStore(store).getAll();
      rq.onsuccess = function () { resolve(rq.result || []); };
      rq.onerror = function () { resolve([]); };
    });
  }
  // 落盘一份草稿(含字节:草图以**编码后的字节**存,恢复时走同一条解码路)
  function saveDraft(force) {
    if (!app.map || !app.db) return Promise.resolve();
    return Io.encodeMap(app.map, { compress: true }).then(function (bytes) {
      var rec = { key: draftKey(app.name || app.map.name),
                  name: app.name, name2: app.map.name, bytes: bytes,
                  sourceFormat: app.sourceFormat, savedAt: Date.now(), dirty: true };
      return idbPut(app.db, DRAFT_STORE, rec);
    }).then(function () {
      // ★ 规格 §4.5:状态栏要显示自动保存时间(用户得知道"我的东西有没有被兜住")
      var el = $('st-save');
      if (el) el.textContent = '已自动保存 ' + new Date().toLocaleTimeString();
      return pruneDrafts();
    }).catch(function (e) {
      // ★ 配额失败要**明确告知**,不静默吞掉(规格 §4.6)
      status('草稿盘写入失败:' + msgOf(e) + '(作品仍在,请尽快 Ctrl+S 写盘)');
    });
  }
  function pruneDrafts() {
    return idbGetAll(app.db, DRAFT_STORE).then(function (recs) {
      var plan = evictPlan(recs.map(function (r) {
        return { key: r.key, savedAt: r.savedAt, dirty: !!(r.dirty && r.name !== app.name) };
      }), MAX_LIB);
      if (!plan.drop.length) return null;
      var tx = app.db.transaction(DRAFT_STORE, 'readwrite');
      plan.drop.forEach(function (k) { tx.objectStore(DRAFT_STORE).delete(k); });
      return new Promise(function (resolve) {
        tx.oncomplete = function () { status('草稿盘超过 ' + MAX_LIB + ' 条,已清掉 ' + plan.drop.length + ' 条最老的'); resolve(true); };
        tx.onerror = function () { resolve(false); };
      });
    }).catch(function () { return null; });
  }
  function loadDraft(key) {
    if (!app.db) return Promise.resolve(null);
    return new Promise(function (resolve) {
      var tx = app.db.transaction(DRAFT_STORE, 'readonly');
      var rq = tx.objectStore(DRAFT_STORE).get(key);
      rq.onsuccess = function () { resolve(rq.result || null); };
      rq.onerror = function () { resolve(null); };
    });
  }
  // ── 闸 4:全局错误围栏 + 崩溃前快照 ──
  // ★ 这条是兜底:就算前面三道闸哪里漏了,作品也不会丢,最坏只丢最后一笔。
  // ── UI 小状态(规格 §4.6 第 3 层):恢复与落盘 ──
  function applyUiState() {
    var u = app.uist;
    if (!u) return;
    // ★ 缩放必须在**地图打开之后**恢复:setMap 自己会 fit(),先设会被它覆盖掉
    var cur = app.r.view().zoom;
    if (u.zoom > 0 && Math.abs(u.zoom - cur) > 1e-6) {
      app.r.setZoomAt(app.canvas.width / 2, app.canvas.height / 2, u.zoom / cur);
    }
    app.r.setLayer(u.layer);
    app.r.setGrid(u.grid); app.r.setSubGrid(u.subGrid);
    app.r.setTorus(u.torus); app.r.setDimOthers(u.dimOthers);
    app.st.tool = u.tool;
    app.st.brushSize = u.brushSize;
    if (u.selectedTexture > 0) {
      app.st.desc = Core.packDesc(clampTexture(u.selectedTexture, Render.atlasCapacity()),
                                  Core.hueOf(app.st.desc), Core.brightOf(app.st.desc),
                                  Core.satOf(app.st.desc), Core.alphaOf(app.st.desc));
    }
    // ★ DOM 必须与上面保持一致:否则"页面显示的"与"实际用的"是两回事(开关显示关着、其实开着)
    [['tg-grid', u.grid], ['tg-subgrid', u.subGrid], ['tg-torus', u.torus]].forEach(function (pair) {
      var el = $(pair[0]);
      if (el) el.classList.toggle('on', !!pair[1]);
    });
    var dim = $('dim-others');
    if (dim) dim.checked = !!u.dimOthers;
    var bsEl = $('brush-size');
    if (bsEl) bsEl.value = String(app.st.brushSize);
  }
  var uiSaveTimer = null;
  function persistUi() {
    if (uiSaveTimer || !app.map || !app.st) return;
    uiSaveTimer = setTimeout(function () {
      uiSaveTimer = null;
      app.uist = {
        layer: app.r.layer(), zoom: app.r.view().zoom, tool: app.st.tool,
        brushSize: app.st.brushSize,
        grid: $('tg-grid') ? $('tg-grid').classList.contains('on') : true,
        subGrid: $('tg-subgrid') ? $('tg-subgrid').classList.contains('on') : false,
        torus: $('tg-torus') ? $('tg-torus').classList.contains('on') : true,
        dimOthers: $('dim-others') ? !!$('dim-others').checked : true,
        panelOpen: app.uist.panelOpen, playerRef: app.uist.playerRef,
        selectedTexture: Core.texOf(app.st.desc),
      };
      writeUiState(window.localStorage, app.uist);
    }, 500);
  }
  // ★ 节流 500ms 而不是逐帧:localStorage 是**同步**写(每帧写会掉帧)。
  //   挂在几个明确的变更点上,不侵入 Task 7 的交互代码。
  function installUiStateSave() {
    ['click', 'change', 'wheel', 'keyup', 'pointerup'].forEach(function (evt) {
      window.addEventListener(evt, persistUi, { passive: true });
    });
  }

  function installCrashFence() {
    function snapshot(why) {
      if (!app.map || !app.db) return;
      Io.encodeMap(app.map, { compress: true }).then(function (bytes) {
        return idbPut(app.db, CRASH_STORE, {
          key: 'crash', name: app.name, name2: app.map.name, bytes: bytes,
          savedAt: Date.now(), why: String(why || '').slice(0, 200),
        });
      }).catch(function () { /* 崩溃路径上什么都不该再抛 */ });
    }
    window.addEventListener('error', function (ev) {
      status('页面异常:' + (ev && ev.message ? ev.message : '未知'));
      snapshot(ev && ev.message);
    });
    window.addEventListener('unhandledrejection', function (ev) {
      status('未处理的 promise 拒绝:' + msgOf(ev && ev.reason));
      snapshot('unhandledrejection');
    });
  }
  function checkCrashSlot() {
    if (!app.db) return Promise.resolve(false);
    return Promise.all([idbGetAll(app.db, CRASH_STORE), idbGetAll(app.db, DRAFT_STORE)]).then(function (both) {
      var crash = (both[0] || []).filter(function (r) { return r.key === 'crash'; })[0] || null;
      var main = (both[1] || []).sort(function (a, b) { return (b.savedAt || 0) - (a.savedAt || 0); })[0] || null;
      if (!crashIsNewer(crash, main)) return false;
      var yes = window.confirm('上次异常退出,已恢复到崩溃前(草稿:' + (crash.name2 || crash.name || '?') +
                               ')。要打开它吗?');
      if (!yes) return false;
      return Io.decodeMap(crash.bytes).then(function (map) {
        map.name = crash.name2 || '';
        app.map = map; app.name = crash.name; app.sourceFormat = 'v4';
        app.r.setMap(map);
        status('已从崩溃前快照恢复:' + (crash.name || ''));
        return true;
      }).catch(function (e) { status('崩溃快照解码失败:' + msgOf(e)); return false; });
    });
  }
```

`boot()` 里补上启动顺序(★ 顺序是契约:草稿盘要在打开地图**之前**就绪,崩溃检查要在之后):

```js
    installCrashFence();
    app.uist = readUiState(window.localStorage);
    app.db = null;
    openDraftStore().then(function (db) {
      app.db = db;
      if (!db) status('草稿盘不可用(私密模式?)—— 编辑器仍可用,但请及时 Ctrl+S 存盘');
      return checkCrashSlot();
    }).then(function () {
      return loadAtlas();
    }).then(function () {
      return openFromUrl();
    }).then(function () {
      applyUiState();                 // ★ 必须在 openFromUrl() 之后(setMap 会 fit)
      buildPanels();
      installUiStateSave();
      return null;
    }).then(function () {
      if (new URLSearchParams(location.search).has('selftest')) {
        return selfTest().then(function (line) { status(line); });
      }
      return null;
    }).catch(function (e) { status('启动失败:' + msgOf(e)); });
```

把 `boot()` 原来的 `loadAtlas().then(openFromUrl)...` 那一段**整体换成上面这一串**(图片集与地图的加载次序不变,只是前面插入了草稿盘与崩溃检查)。

`selfTest()` 里补三条(人眼验收要能一行看到它们):

```js
      check('localStorage 可用', (function () {
        try { window.localStorage.setItem('cyrm.probe', '1'); window.localStorage.removeItem('cyrm.probe'); return true; }
        catch (e) { return false; }
      })());
      check('IndexedDB 已打开', app.db !== null && app.db !== undefined);
```

★ 草稿盘的**读写往返**不在这里做:它需要真的写一条记录再读回来,而"草稿盘里有没有那条记录"
由人眼清单第 1 步(DevTools → IndexedDB)直接看 —— 自检只报"开没打开",不替人判断草稿的内容。

导出表追加:

```js
    DRAFT_DB: DRAFT_DB, DRAFT_STORE: DRAFT_STORE, CRASH_STORE: CRASH_STORE,
    UI_STATE_KEY: UI_STATE_KEY, MAX_LIB: MAX_LIB, DRAFT_DEBOUNCE_MS: DRAFT_DEBOUNCE_MS,
    draftKey: draftKey, crashIsNewer: crashIsNewer, evictPlan: evictPlan,
    uiStateDefaults: uiStateDefaults, readUiState: readUiState, writeUiState: writeUiState,
    openDraftStore: openDraftStore, saveDraft: saveDraft, loadDraft: loadDraft,
    installCrashFence: installCrashFence, checkCrashSlot: checkCrashSlot,
    applyUiState: applyUiState, persistUi: persistUi, installUiStateSave: installUiStateSave,
```

- [ ] **Step 4: 运行,确认通过**

Run:

```bash
cd level_editor && node editor_smoke.js && node server_smoke.js
```

Expected: `EDITOR SMOKE OK` / `SERVER SMOKE OK`,退出码 0。

- [ ] **Step 5: 人眼验收(草稿盘与崩溃恢复 —— ★ 必须用 DevTools)**

**测试由用户自己跑**。清单(全部在浏览器里做):

1. `serve.bat` → 打开页面 → 打开一张地图 → 画几笔 → **等 2 秒**(草稿防抖)→
   F12 → Application → IndexedDB → `cyrm-editor` → `draft` → 应有一条记录(键 = 文件名去后缀),值是 `bytes/savedAt/dirty`;
2. **刷新页面**(F5)→ 地图仍在(从真文件重开),草稿盘那条记录的 `savedAt` 不变;
3. **崩溃恢复**:在控制台里执行 `setTimeout(function(){ throw new Error('手工制造一次崩溃') }, 0)` → 状态栏出现「页面异常…」,`crash` 槽位里**多出一条**记录;
   再刷新页面 → 应弹出「上次异常退出,已恢复到崩溃前」→ 点确定 → 画布上是崩溃前那张图;
4. **配额失败要说话**:DevTools → Application → Storage 里把 IndexedDB 设为被阻止(或用一个隐私窗口试)→ 状态栏应出现「草稿盘不可用…」或「草稿盘写入失败…」,**不是静默**;
5. **UI 小状态**:切到「背景层」、关掉「子格」、把缩放滚到某一个值 → **等 1 秒**(落盘是 500ms 节流)→ 刷新页面 → 图层/开关/缩放**都还在**(从 localStorage 恢复;`applyUiState()` 在 `setMap` 之后才恢复缩放,所以不会被 fit 覆盖);
6. 把 `Editor.uiStateDefaults()` 与 `Editor.readUiState(window.localStorage)` 的结果贴回报告(后者应体现第 5 步的选择)。

Expected:6 条全部符合。★ 第 3 条是闸 4 的**唯一**端到端验证 —— 它在 node 里验不了(没有 IndexedDB),所以要人贴回结果。

- [ ] **Step 6: 提交**

```bash
git add level_editor/ui.js level_editor/editor_smoke.js
git commit -F - <<'EOF'
feat(editor): 三层持久化 + 闸 4(崩溃前快照)

① 真文件 maps/*.cyrm(任务 8 的 Ctrl+S)② IndexedDB 草稿盘(防抖落盘、按文件名
做键 —— 库的身份就是文件名,不另铸 id)③ localStorage 只存 UI 小状态,且玩家参考图
位置**按格坐标**存(按屏幕像素存的话换窗口/换缩放语义就漂,A13)。

★ 闸 4:window.onerror / unhandledrejection 立刻把当前图写进独立的 crash 槽位,
下次打开若 crash 槽位比主槽位新就提示恢复 —— 就算前三道闸漏了,作品也最坏只丢最后一笔。
★ 配额失败**明确告知**(不静默吞掉);库条目上限 60 的淘汰先丢"已保存且最老"的
(脏的那份是用户还没写盘的劳动)。
EOF
```

---

## Task 10: 收尾(CLAUDE.md / 全冒烟 / 不做清单核查)

**Files:**
- Modify: `CLAUDE.md`(编辑器小节)
- Modify: `docs/superpowers/plans/2026-09-21-cyrm-v4-editor-render-and-ui.md`(只在需要订正时)

**Interfaces:**
- Consumes:Task 1–9 的全部产物
- Produces:无新代码 —— 本 Task 的交付物是"文档与实际一致"与"六套冒烟全绿"的证据

- [ ] **Step 1: 更新 `CLAUDE.md` 的编辑器小节**

先看现状:

```bash
grep -n "编辑器工具" -A 6 CLAUDE.md
```

把「编辑器工具」那一节**整体替换**为下面这段(改的是三件**已经变了**的事实:入口页改名、格式换成 v4 二进制、砖形面板已删):

```markdown
### 编辑器工具
`level_editor/editor.html` + `level_editor/{core,tint,render,io,ui,worker}.js` 是独立浏览器编辑器(大图缩放/画笔/图层/辅码),与 Godot 引擎无关。**只通过 `level_editor/serve.bat` 以 HTTP 打开**(`file://` 刻意不支持:没有 Worker、没有同源、读不到 `maps/`),服务器是 `level_editor/editor_server.js`(node,只绑 `127.0.0.1:8777`)。旧的 `structure-editor.html` 已退休(2026-09-21)。

- **格式**:`.cyrm` **v4 二进制**(明文 20 字节头 + deflate + CRC32),四图层、每格 4×4 个 16px 子格、每子格带辅码(色相/亮度/饱和/透明各 8 档)。**导入**仍认三种输入(v4 二进制 / 带 `# cyrm-v3` 标记的 v3 文本 / 旧字母格式),**导出只有二进制一种**;v3 → v4 的迁移是一次性的,所以打开 v3 文本的图首次 `Ctrl+S` 会弹一次确认。
- **砖形面板已删除**(2026-09-19 裁定):在"子格独立纹理"的模型下,"形状"退化成"这一笔盖哪几个子格",由画笔大小表达 —— 整数大小画整格、`.25/.5/.75` 画子格(0.25 = 1 个子格)。
- **纹理 22(水面)不在调色板里**:游戏侧它是按地形自动派生的(A7),画了会与游戏不一致。
- **改编辑器**:`core.js`(格式)/`tint.js`(辅码像素数学)是冻结层,`render.js`(四层缓存 + 脏区)/`ui.js`(工具 + 面板 + 持久化)/`io.js` + `worker.js`(编解码进 Worker)。`core.js` 的注释里写着与游戏侧 `map_format.gd` 逐字对应的几处;两边改一处必须同步改另一处。
- **敌人表**:编辑器内嵌的敌人注册表由 `node level_editor/sync-enemies.js` 从 `data/enemies.json` 重新生成(`--check` 只校验);砖块属性表同理走 `sync-tiles.js`。
- **冒烟(全在 node 里跑,`cd level_editor`)**:`node smoke.js`(`SMOKE OK`,格式层)/ `node tint_smoke.js` / `node worker_io_smoke.js` / `node render_smoke.js` / `node editor_smoke.js` / `node server_smoke.js`。★ 浏览器侧(node 到不了)靠页面上的**「自检」按钮**:它打印一行 `SELFTEST OK` 或 `SELFTEST FAIL: n 条`。
```

- [ ] **Step 2: 跑齐六套冒烟**

Run:

```bash
cd level_editor && node smoke.js && node tint_smoke.js && node worker_io_smoke.js && node render_smoke.js && node editor_smoke.js && node server_smoke.js
```

Expected:

- `SMOKE OK` —— **343 通过 / 0 失败**(计划 1 的覆盖一条没少)
- `TINT SMOKE OK` —— 96 通过 / 0 失败
- `WORKER IO SMOKE OK`
- `RENDER SMOKE OK`
- `EDITOR SMOKE OK`
- `SERVER SMOKE OK`
- 退出码 0

- [ ] **Step 3: 确认冻结文件一个字节没动**

Run:

```bash
git diff --stat 9e2aef7 -- level_editor/core.js level_editor/tint.js level_editor/smoke.js level_editor/tint_smoke.js level_editor/editor_server.js level_editor/serve.bat level_editor/tile_defs.js
```

Expected:**输出为空**(相对计划 2b 的起点 `9e2aef7`,这七个文件一个都没改)。

- [ ] **Step 4: 确认集成约束仍成立(★ 三件事都真的做了)**

Run:

```bash
node level_editor/sync-enemies.js --check && node level_editor/sync-tiles.js --check && test ! -e level_editor/structure-editor.html && echo "旧页面已退休"
```

Expected:两条 `ok: …` + `旧页面已退休`,退出码 0。

- [ ] **Step 5: 确认纪律断言真的都在(★ 它们不许在搬家时被删掉)**

Run:

```bash
grep -c "Content-Type" level_editor/ui.js; grep -c "Math.floor" level_editor/ui.js; grep -rn "rgbToHsv" level_editor/ui.js level_editor/render.js level_editor/editor.html | wc -l
```

Expected:

- `Content-Type` 在 `ui.js` 里 **≥ 1**(PUT 的那一处);
- `Math.floor` 在 `ui.js` 里 **> 1**(其中至少一处在 `Core.lineCells(` 的同一行);
- 第三条输出 **0**(这三个文件里没有第二份 HSV 数学)。

★ 这三条在 Task 5 的 `editor_smoke.js` 相位 ⑪ 里有更强的版本;这里是**给收尾的人眼看的双保险** —— 尤其第一条:它在 Task 3 从 `server_smoke` 的相位 ⑧ 被**搬走**(因为 PUT 的落点从页面挪到了 `ui.js`),搬家过程中漏掉就会变成"页面里没有断言、ui.js 里也没有"的空洞。

- [ ] **Step 6: 提交**

```bash
git add CLAUDE.md
git commit -F - <<'EOF'
docs(claude): 编辑器小节同步 —— 入口页改名、v4 二进制、砖形面板已删

三处已经变了的事实:入口是 editor.html(旧 structure-editor.html 已退休)、
格式是 v4 二进制(导入仍认三种、导出只有二进制)、砖形面板整体删除(画笔大小
表达"这一笔盖哪几个子格")。另补:纹理 22 不进调色板的原因、冻结层与可改层的分工、
六套 node 冒烟 + 页面「自检」按钮这条浏览器侧的唯一判据。
EOF
```

---

## ★ 每个 Task 的浏览器半边:人怎么验、要交什么证据

node 到不了浏览器,**这不是可以省略的步骤**:计划 2a 的终审点名过"这条缺陷住在一个 node 只能 grep、没有人真机跑过的页面里,它之所以活过七轮评审正是因为这个"。所以本计划把浏览器侧拆成**每个 Task 一条清单**,证据统一是这四样:

| 证据 | 怎么给 | 用在哪 |
|---|---|---|
| 页面的 `SELFTEST OK` / `SELFTEST FAIL: n 条` 一行 | 点页面上的「自检」按钮,把状态栏那一行贴回报告 | Task 3 起,每个浏览器 Task |
| 控制台零红字 | F12 → Console,截图或文字贴回 | 每个浏览器 Task |
| 画布截图 | 整窗截图 | Task 3 / 4 / 7 / 8 |
| 数字 | `copy(JSON.stringify(Editor.app.r.stats()))` 的结果 | Task 4(帧时间与三档路径) |

★ **实现者必须在报告里如实写"浏览器半边:已由人验证 / 未验证"** —— 没验就说没验,不要用"node 全绿"暗示浏览器也绿。

---

## ★ 本计划刻意不做的事

| 不做 | 归属 | 为什么不在 2b |
|---|---|---|
| `maps/*.cyrm` 迁移为 v4 二进制 | **期 E** | 迁移单向且不可逆,必须先把 v3 文本原样提交一次留档;而且迁移完游戏侧要同步改(交接文档 §3 那个决策还没拍板)。2b 只保证**导入**能读 v3、**导出**写 v4,并在首次保存时把不可逆这件事说出来 |
| 游戏侧交接文档的**更新** | **期 E** | 它**已经存在**(`docs/2026-09-20-cyrm-v4-handover.md`,377 行,写于计划 1 之后),内容是"游戏侧怎么改";2b 一行游戏代码都没碰,也没有能让它更准的新事实。★ 唯一值得回填的是 Task 1 的 **Worker 真实往返证据**(deflate 两端兼容性那一栏)—— 那是期 E 顺手做的一件事,不是 2b 的交付物 |
| 「游戏真值」叠加层(32px 碰撞子格 / 墙-通道-液体分类 / 自动派生水面 / 3×3 环面铺贴的可视化) | 审计 C13,**后续** | 它是**只读的调试视图**,与"能编辑"正交;而 2b 已经把 3×3 环面铺贴做进渲染与命中(Task 4),真值叠加是在这之上再加一层 |
| 小地图 / 鸟瞰导航器 | 审计 C10,后续 | 缩略图路径(①)在大缩放下已经是鸟瞰效果;真要做导航器得再开一套交互,不值得与工具集抢这一版 |
| 旋转(Rotate)选区 | 后续 | §4.4 只承诺"移动 / 删除 / 复制粘贴 / 镜像";旋转会引出"非正方形选区旋转后尺寸怎么变"这类没定过的问题 |
| 多文件批量导出 / 批量迁移工具 | 后续 | 期 E 的事,且它更需要"先有一份能跑的编辑器" |
| 服务器的认证 / TLS / 目录浏览 / 多用户 / range 请求 | 永久不做 | 规格 §4.9:本机自用工具 |
| 服务器校验 `.cyrm` 格式 | 永久不做 | 计划 2a 的决定 ④:格式只有一个实现(`core.js`) |
| 编辑器的"删除地图"按钮 | 刻意不做 | 删除是不可逆的文件操作,而编辑器**没有回收站**。状态栏直接告诉用户"请去磁盘上删"(Task 8) |
| 编辑器预测/撤销"跨文件"操作(比如撤销一次保存) | 刻意不做 | 保存不是编辑历史的一部分 —— 撤销改的是内存里的地图,磁盘上那份由用户自己决定什么时候覆盖 |

---

## 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| **浏览器半边从未运行**(计划 2a 的唯一验收缺口) | 整页打不开、渲染全错、Worker 起不来 —— 而 node 一条断言都拦不住 | Task 3 就把真页面跑起来(计划里第 3 个 Task),并且每个浏览器 Task 都带**人眼清单 + `SELFTEST` 一行**;`SELFTEST` 里覆盖 Worker ping/往返、图集加载、画布尺寸、IndexedDB、localStorage —— 「能在浏览器里跑」由它给出**可粘贴**的判据 |
| **③ 与 ④ 的作废耦合断掉**(审计 A2 的上一层复发) | 换贴图后整张图是色块,"有时好有时坏",不报错 | `setAtlas` 是**唯一**换图入口,同时作废两层;`attachCells` 让 `setMap` 与 ③ 绑定;`render_smoke` 相位 ③b 走**生产路径**断言两条轴(变异:去掉 `gen` 比较 → 三条红) |
| ③ 的 `build` 回调只存 tile 引用 ⇒ 有人"优化"成存像素 | 一屏 15MB、缓存比工作集还小、换图后仍交出旧像素 | 计划「决定 ②」写明了理由;相位 ③b 的"换图后是新对象"断言在两种实现下都成立,**但**`DEFAULT_CELL_MAX = 8192` 与注释点明了口径 |
| 长作业(油漆桶 / 渐变 / 全屏重建)漏了分帧 | 大图上一操作就卡几秒,"页面像死了" | 闸 2 由 `Render.createSlicer` 统一提供,并有**确定性**断言(预算 8ms、每项 1ms → 每帧 8 项、单帧 ≤ 8ms);油漆桶/渐变/建层/缩略图四条长路径都走它 |
| `Core.lineCells` 拿到非整数坐标 | **死循环挂住整个标签页**(不是返回错值) | 所有调用点收在 `strokePoints` 与 `lineTargets` 两处,都在同一行 `Math.floor`;`editor_smoke` 相位 ⑪ 扫源码钉住"没有第二个没 floor 的调用点" |
| 尺寸/纹理输入没有上限 | 输 99999 分配巨图卡死(A8 原样复发) | `createEmptyMap` 是唯一的造图入口(内部 `Core.clampMapSize`);`clampTexture` 同时躲开 0 与越界;相位 ⑪ 断言 `Core.createMap(` 在 `ui.js` 里**只出现一次** |
| v3 文本被一次 Ctrl+S 静默转成 v4(不可逆) | 仓库里两张真图被改格式,而 v3 原文只在 git 里 | 决定 ⑤:源是 v3/旧字母格式时首次保存弹一次确认,并说明期 E 会做正式迁移;人眼清单里明确"用副本试" |
| PUT 少了 `Content-Type` | 保存回 415,用户看到"存不进去",服务器日志只有一行 415 | `ui.js` 里显式设头(唯一一处 PUT);`editor_smoke` 相位 ⑪ 用正则钉死;人眼清单里点名"控制台不能有 415" |
| 撤销栈吃掉内存 | 大图上连续操作后浏览器内存爆掉 | 差量条目(不是整图快照)+ **字节预算** 64MB(不只是 200 步):整图级操作也按字节记账,超了从最老的丢 |
| IndexedDB 配额失败 | 草稿丢失,用户以为"编辑器帮我存着呢" | 落盘失败的 catch 里**明确报状态栏**(不静默);启动时草稿盘不可用也报一次;人眼清单第 4 条专门验它 |
| 探针在搬家(2b 的重构)中失明 | 断言对着不存在的代码恒绿 | 相位 ①b / ⑧ 是**被教会**新真值(方向反转 + 只判页面结构)而不是删掉;纪律断言搬进 `editor_smoke` 相位 ⑪ 并**加严**(扫源码而不是扫页面文本);Task 10 Step 5 再给人眼一遍 grep 双保险 |
| 缩略图构建在大图上慢 | 打开大图时"页面像卡了一下" | 缩略图**总是**经分帧器建(每 8 行一个任务);400×300 格时自动降到 1px/子格(30MB → 7.7MB);`thumbScale` 有断言 |
| 双模块同心:`Render.mount` 里 `attachCells` 被后人删掉 | `setAtlas` 不再作废 `mount` 的 ③ ⇒ A2 复发 | 相位 ③b 从**模块侧**钉住"attach 之后 setAtlas 会清 ③";`setMap` 里那一行有注释点名不许删 |
