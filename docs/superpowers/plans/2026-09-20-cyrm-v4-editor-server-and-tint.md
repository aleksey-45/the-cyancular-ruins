# `.cyrm` v4 编辑器(计划 2a):本地服务器 + 辅码像素数学

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地编辑器重写里**能被 node 自动验证**的那一半 —— `level_editor/editor_server.js`(本地 HTTP 服务器 + 地图读写 API + serve.bat)与 `level_editor/tint.js`(辅码像素数学 + tinted-tile LRU 缓存),外加一个能让这两样"真跑起来"的最小骨架页,全部由 node 冒烟断言。

**Architecture:** 服务器是**哑文件服务器**(CommonJS,`http` 模块,只绑 `127.0.0.1:8777`)——它不认识 `.cyrm` 格式,格式的一切归 `core.js`;安全边界只有一条:地图名走裸文件名白名单 + 解析后包含性检查两道闸,写盘走同目录临时文件 + rename 的原子替换。`tint.js` 是**经典脚本**(`globalThis.Tint`,与 `core.js` 同款),但它的档位常量**全部从 `globalThis.Core` 派生**、不自己抄一份,于是"编辑器与游戏 shader 必须逐像素一致"这条不变量变成结构性的而不是靠约定。

**Tech Stack:** 纯 JavaScript(经典脚本给浏览器,CommonJS 给 node)、node v24(内置 `http`/`fs`/`child_process`、原生 `CompressionStream`,**不引入任何 npm 依赖**)、`node:http` 做真实 HTTP 往返测试、注入式 canvas backend 让像素代码在 node 里可跑。

## Global Constraints

- **规格是唯一事实来源**:`docs/superpowers/specs/2026-09-19-cyrm-v4-editor-design.md`。任何与本计划冲突之处,以规格为准,并在提交信息里说明。
- **编辑器只通过 HTTP 打开**(规格 §1.2、§4.9):`file://` 支持被刻意放弃。页面上不许出现 `file://`。
- **服务器只绑 `127.0.0.1`**,端口 **8777** —— 刻意避开游戏侧已占用的一切端口(7777 大厅 / 7800+ worker / 7999 测试)。
- **路径穿越防护是硬需求**:地图名参数只接受裸文件名 `^[A-Za-z0-9_\-]+\.cyrm$`,拒绝任何含 `/`、`\`、`..`、空字节的值。没有这条,一个本地网页就能读写整块磁盘。
- **写盘必须原子**(同目录临时文件 + `rename`),绝不允许"写一半断电把地图毁了"。
- **`tint.js` 的像素数学必须与规格 §2.3 逐字一致**:是 **HSV**(不是 HSL)、色相 `fposmod(h + (H-4)*15, 360)`、亮度/饱和度**乘法** `(B-4)*0.1`、alpha `A/7`。中性描述符 = `(hue 4, bright 4, sat 4, alpha 7)` —— **三列的中性档不在同一行**(alpha 的中性在档 **7**)。
- **`core.js` 是冻结的**:本计划**不修改** `level_editor/core.js` 与 `level_editor/smoke.js` 一行。所有新代码消费它的导出,不重实现、不动它的签名。
- **`node smoke.js` 必须保持全绿**(343 通过 / 0 失败 / `SMOKE OK`)。
- **`structure-editor.html` 原样保留**:它内嵌的敌人注册表标记 `/*__ENEMY_REGISTRY_BEGIN__*/`…`/*__ENEMY_REGISTRY_END__*/` 是 `sync-enemies.js` 的锚点,本计划一次都不碰它。
- **一切有硬上限**(规格 §4.3 闸 1):请求体 64MB(= `core.js` 的 `MAX_BODY_SIZE`)、tint 缓存 8192 张(= 8MB)。用户输入一律**钳制**,不报错回滚。
- **注释一律用中文**,与仓库其余部分一致。
- **本计划的任何测试都不许写进真实 `maps/` 目录**:所有写路径都指向 `fs.mkdtempSync` 出来的临时目录。

---

## 预检裁决(评审遇到引这两条,不要重复上报)

这两条是**计划 1 开工前已与用户确认**的裁决,计划 2a 继续沿用:

- **裁决 ①**:`core.js` 里带着 `sanitizeName` / `brushOffsets` / `lineCells` / `normRegion` 四个**格式层一行都不调用**的纯函数。严格按 YAGNI 这算"多余代码",但这是刻意的 —— 它们是给编辑器层留的,现在搬过来了才能留住它们在旧 `smoke.js` 里的既有断言。
- **裁决 ②**:计划 1 删掉了旧 `smoke.js` 里约 150 行 / 约 60 条当时正绿的断言(它们测的是 `structure-editor.html` **内嵌的旧 Core**;新 `smoke.js` 加载 `core.js`,换加载源后它们必然失效)。**`structure-editor.html` 自身的行为在计划 2b 重写它之前没有自动覆盖** —— 这是用户知悉并接受的代价。本计划**不**新增对旧编辑器行为的覆盖(不重写它、也不为它写测试),只钉住"它的注册表标记还在、`sync-enemies.js --check` 还绿"这一条集成约束。

---

## 本计划的四条决定(规格留给实现者拍板的部分)

**① 入口文件 = 新建 `level_editor/editor.html`;`structure-editor.html` 一个字节都不动。**

理由有两条,都是硬理由:

1. `sync-enemies.js` 把 `structure-editor.html` **写死**在 `htmlPath` 里,`--check` 在标记缺失时直接 FAIL。计划 2a **不实现任何 UI**(渲染/工具栏/图层全在 2b),此时重写那个文件等于把仓库里**唯一能用的编辑器**换成一个半成品 —— 收益为零,风险是"编辑器暂时不可用 + 注册表失联"。
2. `core.js`(计划 1)已经把 `globalThis.Core` 定义成"编辑器与 node 冒烟共用的一份实现"。新入口页与旧编辑器**可以并存**(旧编辑器自带一份内嵌的旧 Core,互不干扰),于是 2b 可以**先让新页跑起来、验收通过,再删旧页**。

**迁移时点(写给 2b)**:把标记块搬进 `editor.html`、把 `sync-enemies.js` 的 `htmlPath` 指过去、删掉 `structure-editor.html` —— **这三件事必须同一个 commit**。少做第二件 = 注册表静默漂移;少做第一件 = `--check` 直接红;少做第三件 = 两份注册表并存,迟早有一份烂掉。

**② 库的"身份"就是文件名,不另铸 `map.id`。**

计划 1 的账本里留了一条缺口:规格 §2.4 把地图建模成 `{ id, name, … }`,但 `createMap(name, cellsW, cellsH)` 不造 `id`,也没有任何地方赋值过。规格 §4.6 自己给了答案:**「真文件 `maps/*.cyrm` —— 作品的真身」**。真身是文件,文件的身份就是文件名 ⇒ **不需要 `map.id`**。于是:

- `core.js` 不造 `id` 是对的,**不改**。
- 服务器的 API 全部以**文件名**为键(`/api/map?p=<name>`)。
- 2b 的草稿盘(IndexedDB)若需要主键,用 `sanitizeName(文件名)`,**不许另铸一套 id**(两套身份必然漂)。
- `decodeMap` 返回的 `name` 是空串(v4 body 里没有 name 字段,计划 1 账本 Task 7 Minor 4 已经点过),所以**导入方必须自己用文件名补 `map.name`** —— 否则 `sanitizeName` 会回落成 `'structure'`。这一条在 Task 7 里有断言钉住。

**③ `tint.js` 对 `core.js` 是**硬依赖**(结构性,不是装饰)。**

`Tint.HUE_OFFSET_DEG` 是规格里的表,但 `Tint.NEUTRAL` / 档位的中性行 / 象限数 / 贴图块边长**全部读 `Core` 的常量**(`Core.HUE_NEUTRAL` / `BRI_NEUTRAL` / `SAT_NEUTRAL` / `ALPHA_NEUTRAL` / `SUB_PER_CELL` / `texOf`)。被否掉的替代方案是"tint.js 自己写一份常量,再加一条断言比对两边相等" —— 那等于**把漂移面重新引入**,只是多了一条要记得跑的断言。`tint.js` 在没有 `Core` 时**当场抛错**,这条也有断言(Task 4 相位 ③)。

**④ 服务器是**哑文件服务器**,不校验 `.cyrm` 格式。**

它只做四件事:服务静态文件、列地图、读地图字节、原子写地图字节。magic / 版本 / CRC / 尺寸合法性**全部**归 `core.js`(唯一实现)。服务器若自己也判一遍格式,就是第二份格式实现 —— 那种"两边判得不一样"的分歧症状是"编辑器存得下、游戏读不出",且不报错。

---

## 文件结构

| 文件 | 职责 | 本计划中的动作 |
|---|---|---|
| `level_editor/editor_server.js` | 本地 HTTP 服务器:静态服务(+ 穿越防护)+ `/api/maps` + `GET`/`PUT /api/map`(原子写)+ 启动失败诊断 | **新建**(Task 1)→ **扩充**(Task 2、Task 3) |
| `level_editor/serve.bat` | 起服务器并让浏览器打开 `http://127.0.0.1:8777/` | **新建**(Task 1) |
| `level_editor/editor.html` | 新入口页。Task 1 只放一个占位骨架,Task 6 重写成三条自检(库 / 辅码实验室 / 编解码往返) | **新建**(Task 1)→ **重写**(Task 6) |
| `level_editor/server_smoke.js` | `editor_server.js` 的 node 冒烟(真 HTTP 往返,只用临时目录) | **新建**(Task 1)→ 追加相位(Task 2、Task 3、Task 6、Task 7) |
| `level_editor/tint.js` | 辅码像素数学(规范定义)+ 取角 + 贴图块定位 + tinted-tile LRU 缓存 | **新建**(Task 4)→ 扩充(Task 5) |
| `level_editor/tint_smoke.js` | `tint.js` 的 node 冒烟(手工 golden + 穷举恒等 + LRU 行为) | **新建**(Task 4)→ 追加(Task 5) |
| `level_editor/core.js` / `smoke.js` / `structure-editor.html` / `sync-enemies.js` / `sync-tiles.js` / `tile_defs.js` / `maps/*` | —— | **一个字节都不动** |

分工次序:`server_smoke.js` 与 `tint_smoke.js` **各自独立、都自带断言助手**(不抽公共测试库)—— 与仓库 `tests/*.gd` 每个文件自成一体的惯例一致,评审不要报成重复代码。

---

## Task 1: 本地服务器骨架(静态服务 + 穿越防护 + 启动诊断)+ `serve.bat` + 占位骨架页

**Files:**
- Create: `level_editor/editor_server.js`
- Create: `level_editor/serve.bat`
- Create: `level_editor/editor.html`
- Create: `level_editor/server_smoke.js`

**Interfaces:**
- Consumes: 无(纯 node 内置模块)
- Produces:
  - 常量:`DEFAULT_HOST = '127.0.0.1'`、`DEFAULT_PORT = 8777`、`DEFAULT_ROOT_DIR = __dirname`、`DEFAULT_MAPS_DIR = <仓库根>/maps`、`DEFAULT_INDEX = 'editor.html'`、`MAX_MAP_BYTES = 64 * 1024 * 1024`
  - `mimeOf(filePath) -> String`
  - `sendText(res, status, message) -> void`、`sendJson(res, status, obj) -> void`
  - `staticFileFor(rootDir, urlPath, indexName) -> {status:200, file:String} | {status:400|403, message:String}`
  - `serveStatic(res, resolved, headOnly) -> void`
  - `handleApi(req, res, parsed, ctx) -> void`(本 Task 里一律 404)
  - `createServer(opts) -> http.Server`,`opts = {rootDir?, mapsDir?, index?, maxMapBytes?, logger?}`
  - `describePortOwner(port) -> String`(尽力而为,不抛错)
  - `startServer(opts) -> Promise<{server, port, host, url}>` —— ★ 只有 `opts.openBrowser === true` 才弹浏览器(**默认不弹**:弹浏览器是命令行入口的事,库默认弹会让每个冒烟用例都弹出浏览器窗口)
  - `openBrowser(url) -> void`
  - `parseArgs(argv) -> Object`
  - 命令行:`node editor_server.js [--port N] [--maps <dir>] [--root <dir>] [--no-open]`
  - `module.exports` 导出上面除 `parseArgs` 外的全部(`parseArgs` 也导出,便于测试)

- [ ] **Step 1: 写测试 `level_editor/server_smoke.js`(此时必然红)**

新建 `level_editor/server_smoke.js`:

```js
'use strict';
// Node 冒烟 —— 本地服务器 level_editor/editor_server.js(规格 §4.9)。
// Run: cd level_editor && node server_smoke.js
// 判据:文本 `SERVER SMOKE OK` + 退出码 0。
// ★ 本文件只碰 mkdtemp 出来的临时目录:真实 maps/ 目录一次都不写。

const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const { execFileSync } = require('child_process');
const srv = require('./editor_server.js');

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
// 逐字节比对,失败时报第一个不同的下标(整文件/整层比对要用它,eq(JSON) 会打出一屏数字)。
function sameBytes(actual, expected, msg) {
  const a = Array.prototype.slice.call(actual);
  const e = Array.prototype.slice.call(expected);
  if (a.length !== e.length) {
    fail++; console.error('  FAIL - ' + msg + ' (长度 ' + a.length + ' ≠ 期望 ' + e.length + ')');
    return;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== e[i]) {
      fail++; console.error('  FAIL - ' + msg + ' (第 ' + i + ' 字节: 实得 0x' + a[i].toString(16) +
                            ', 期望 0x' + e[i].toString(16) + ')');
      return;
    }
  }
  pass++; console.log('  ok  - ' + msg);
}
function errText(e) {
  let msg = (e && e.message !== undefined) ? String(e.message) : String(e);
  if (msg === '' && e && e.cause && e.cause.message) msg = String(e.cause.message);
  return msg;
}
// ★ 反向断言必须同时断言「错在哪」:只判「有没有抛」是假绿 ——
//   srv.startServer 若因拼写错误根本不存在,抛出来的 TypeError 一样算通过。
async function rejects(fn, msg, expectSub) {
  let e = null;
  try { await fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && errText(e).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + errText(e));
    return;
  }
  pass++; console.log('  ok  - ' + msg);
}

// ── 测试脚手架 ──
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'cyrm-srv-'));
const openServers = [];
function track(r) { openServers.push(r.server); return r; }
async function shutdown() {
  for (const s of openServers) {
    if (typeof s.closeAllConnections === 'function') s.closeAllConnections();
    await new Promise(function (res) { s.close(function () { res(); }); });
  }
  openServers.length = 0;
}
function request(port, method, reqPath, body) {
  return new Promise(function (resolve, reject) {
    const req = http.request({ host: '127.0.0.1', port: port, method: method, path: reqPath },
      function (res) {
        const chunks = [];
        res.on('data', function (c) { chunks.push(c); });
        res.on('end', function () {
          resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) });
        });
      });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

(async function main() {
  // ★ 看门狗:任何一处挂住(server 没关 / promise 永不 settle)都走到这里,
  //   而不是让 node 静默退出。★ 刻意**不 unref**:事件循环空转时静默退出(退出码 0、
  //   一行不打)才是最难发现的假绿 —— core.js 的 inflateBytes 实测踩过这一档。
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 有 server 没关,或某个 promise 永不 settle');
    process.exit(1);
  }, 120000);

  // ==== 相位 ① 常量与文件结构 ====
  ok(srv.DEFAULT_PORT === 8777, 'DEFAULT_PORT === 8777(避开游戏侧 7777/7800+/7999)');
  ok(srv.DEFAULT_HOST === '127.0.0.1', '★ DEFAULT_HOST === 127.0.0.1(绝不绑 0.0.0.0)');
  ok(srv.MAX_MAP_BYTES === 64 * 1024 * 1024, 'MAX_MAP_BYTES === 64MB(与 core.js 的 MAX_BODY_SIZE 同值)');
  ok(srv.DEFAULT_ROOT_DIR === __dirname, 'DEFAULT_ROOT_DIR === level_editor/');
  ok(srv.DEFAULT_MAPS_DIR === path.join(__dirname, '..', 'maps'), 'DEFAULT_MAPS_DIR === 仓库根的 maps/');
  ok(srv.DEFAULT_INDEX === 'editor.html', 'DEFAULT_INDEX === editor.html');
  ok(fs.existsSync(path.join(__dirname, 'editor.html')), '入口页 editor.html 存在');
  ok(fs.existsSync(path.join(__dirname, 'serve.bat')), 'serve.bat 存在');
  (function () {
    const bat = fs.readFileSync(path.join(__dirname, 'serve.bat'), 'utf8');
    ok(bat.charCodeAt(0) !== 0xFEFF, '★ serve.bat 不带 UTF-8 BOM(带了 cmd 会把第一行当命令报错)');
    ok(/chcp 65001/.test(bat), 'serve.bat: 切 UTF-8 代码页(否则中文错误信息在 cmd 里是乱码)');
    ok(/cd \/d "%~dp0"/.test(bat), 'serve.bat: cd 到脚本所在目录(双击时 cwd 是别的地方)');
    ok(/node\s+editor_server\.js/.test(bat), 'serve.bat: 用 node 起 editor_server.js');
    ok(/pause/.test(bat), 'serve.bat: 结尾 pause(否则启动失败时窗口一闪而过,看不到原因)');
  })();

  // ==== 相位 ①b 集成约束:旧编辑器与它的注册表标记必须原样活着 ====
  (function () {
    const oldHtml = path.join(__dirname, 'structure-editor.html');
    ok(fs.existsSync(oldHtml), '集成约束: structure-editor.html 仍在(本计划不重写它)');
    const src = fs.readFileSync(oldHtml, 'utf8');
    ok(src.indexOf('/*__ENEMY_REGISTRY_BEGIN__*/') >= 0 && src.indexOf('/*__ENEMY_REGISTRY_END__*/') >= 0,
       '集成约束: 敌人注册表两个标记都在');
    const sync = fs.readFileSync(path.join(__dirname, 'sync-enemies.js'), 'utf8');
    ok(/htmlPath = path\.join\(dir, 'structure-editor\.html'\)/.test(sync),
       '集成约束: sync-enemies.js 仍指向 structure-editor.html(搬它必须与搬标记同一 commit)');
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

  // ==== 相位 ② 静态服务 ====
  const staticSrv = track(await srv.startServer({
    rootDir: __dirname, mapsDir: path.join(tmpRoot, 'maps'), port: 0,
  }));
  {
    const r1 = await request(staticSrv.port, 'GET', '/');
    ok(r1.status === 200, 'GET / → 200(实得 ' + r1.status + ')');
    ok(/^text\/html/.test(String(r1.headers['content-type'])), 'GET / → Content-Type: text/html');
    ok(/<!DOCTYPE html>/i.test(r1.body.toString('utf8')), 'GET / 返回的是入口页本身');
    ok(r1.headers['cache-control'] === 'no-store', 'GET / → Cache-Control: no-store(改完刷新就能看到新代码)');

    const r2 = await request(staticSrv.port, 'GET', '/core.js');
    ok(r2.status === 200, 'GET /core.js → 200');
    ok(/^text\/javascript/.test(String(r2.headers['content-type'])), 'GET /core.js → text/javascript');
    sameBytes(r2.body, fs.readFileSync(path.join(__dirname, 'core.js')),
              'GET /core.js 的字节与磁盘逐字节一致');

    const r3 = await request(staticSrv.port, 'GET', '/nope.js');
    ok(r3.status === 404, 'GET 不存在的文件 → 404');
    const r4 = await request(staticSrv.port, 'POST', '/core.js');
    ok(r4.status === 405, '静态路径 POST → 405');
    const r5 = await request(staticSrv.port, 'GET', '/api/nope');
    ok(r5.status === 404, '未实现的 /api/* → 404');
    const addr = staticSrv.server.address();
    ok(addr.address === '127.0.0.1' || addr.address === '::ffff:127.0.0.1',
       '★ 实际绑定地址是回环(实得 ' + addr.address + ')');
  }

  // ==== 相位 ③ 路径穿越(规格 §7 风险登记点名"必须写测试"的那一条)====
  {
    const secret = 'TOP SECRET —— 本文件在静态根之外,永远不该被读到';
    const rootDir = path.join(tmpRoot, 'level_editor');
    fs.mkdirSync(rootDir, { recursive: true });
    fs.writeFileSync(path.join(rootDir, 'editor.html'), '<!DOCTYPE html><html><body>穿越靶子</body></html>');
    fs.mkdirSync(path.join(rootDir, 'sub'), { recursive: true });
    fs.writeFileSync(path.join(tmpRoot, 'secret.txt'), secret, 'utf8');

    eq(srv.staticFileFor(rootDir, '/', 'editor.html'), { status: 200, file: path.join(rootDir, 'editor.html') },
       'staticFileFor: / → 索引页');
    eq(srv.staticFileFor(rootDir, '/core.js', 'editor.html').status, 200, 'staticFileFor: 正常文件 → 200');
    eq(srv.staticFileFor(rootDir, '/..%2f..%2fsecret.txt', 'editor.html').status, 403,
       '★ staticFileFor: /..%2f..%2fsecret.txt → 403');
    eq(srv.staticFileFor(rootDir, '/..%5c..%5csecret.txt', 'editor.html').status, 403,
       '★ staticFileFor: 反斜杠编码 %5c 一样被挡');
    eq(srv.staticFileFor(path.join(rootDir, 'sub'), '/..%2f..%2fsecret.txt', 'editor.html').status, 403,
       '★ staticFileFor: 根目录是子目录时同样被挡(判据是"落在根里面",不是"有没有 ..")');
    eq(srv.staticFileFor(rootDir, '/a%00b', 'editor.html').status, 400, 'staticFileFor: 空字节 → 400');

    const travSrv = track(await srv.startServer({ rootDir: rootDir, mapsDir: path.join(tmpRoot, 'maps'), port: 0 }));
    const paths = ['/..%2fsecret.txt', '/..%2f..%2fsecret.txt', '/..%5csecret.txt', '/%2e%2e%2fsecret.txt',
                   '/../secret.txt'];
    for (const p of paths) {
      const r = await request(travSrv.port, 'GET', p);
      ok(r.body.toString('utf8').indexOf('TOP SECRET') < 0,
         '★ HTTP 穿越被挡: GET ' + p + ' → ' + r.status + ',正文里没有那个文件');
    }
    const rDir = await request(travSrv.port, 'GET', '/sub');
    ok(rDir.status === 404, 'GET 目录 → 404(不做目录浏览)');
  }

  // ==== 相位 ④ 启动诊断(端口占用必须说清楚是谁占的)====
  {
    const a = track(await srv.startServer({ rootDir: __dirname, mapsDir: path.join(tmpRoot, 'maps'), port: 0 }));
    await rejects(function () {
      return srv.startServer({ rootDir: __dirname, mapsDir: path.join(tmpRoot, 'maps'), port: a.port });
    }, '★ 同端口再起一个 → 抛错(不是静默退出)', '已被占用');
    ok(srv.describePortOwner(a.port).indexOf('netstat') >= 0, 'describePortOwner: 给出查占用者的命令');
    ok(typeof srv.openBrowser === 'function', 'openBrowser 已导出(可注入)');
    ok(srv.parseArgs(['--no-open']).openBrowser === false, "parseArgs: --no-open → openBrowser:false");
    ok(srv.parseArgs([]).openBrowser === undefined,
       'parseArgs: 默认不设该键 —— 默认值只在命令行入口变成 true(库默认弹浏览器 = 每个冒烟用例弹一个窗口)');
  }

  // ==== 断言区结束 ====
  await shutdown();
  fs.rmSync(tmpRoot, { recursive: true, force: true });
  console.log('');
  console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
  if (fail === 0) console.log('SERVER SMOKE OK');
  process.exit(fail === 0 ? 0 : 1);
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node server_smoke.js`

Expected: 进程在 `require('./editor_server.js')` 处直接死掉 —— `Error: Cannot find module './editor_server.js'`,退出码 1(模块还不存在,这是"测试先红"的正常形态)。

- [ ] **Step 3: 实现 `editor_server.js`、`serve.bat`、`editor.html` 占位页**

新建 `level_editor/editor_server.js`:

```js
// editor_server.js —— 编辑器本地服务器(规格 §4.9)。
// ★ 编辑器**只通过它打开**:`file://` 支持被刻意放弃(规格 §1.2),换来原生 Worker、
//   无同源限制、能直接读写磁盘上的 `maps/*.cyrm`。代价是每次要先起服务器。
// ★ 用 node 写 —— 仓库的编辑器工具链(sync-tiles.js / sync-enemies.js)本来就是 node,
//   不引入新的运行时依赖。
// ★ 只绑 127.0.0.1;端口 8777 刻意避开游戏侧已占用的一切端口
//   (7777 大厅 / 7800+ worker / 7999 测试)。
// ★ 它是**哑文件服务器**:不校验 .cyrm 格式 —— 那是 core.js 的事。
//   服务器若也判一遍格式,就是第二份格式实现,分歧的症状是"编辑器存得下、游戏读不出",且不报错。
// ★ **不做**:认证、TLS、目录浏览、多用户、range 请求。它是本机自用工具,不是服务。
// 用法:node editor_server.js [--port 8777] [--maps <dir>] [--root <dir>] [--no-open]
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 8777;
const DEFAULT_ROOT_DIR = __dirname;
const DEFAULT_MAPS_DIR = path.join(__dirname, '..', 'maps');
const DEFAULT_INDEX = 'editor.html';
// ★ 闸 1「一切有硬上限」(规格 §4.3):PUT 的请求体也要有上限,否则一个坏掉的前端
//   循环就能把磁盘写满。取 core.js 的 MAX_BODY_SIZE 同值(64MB)—— 合法文件最坏约
//   19.1MiB(core.js 里那段推导),对合法文件不会误拒,对跑飞的客户端是一道硬闸。
const MAX_MAP_BYTES = 64 * 1024 * 1024;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.cyrm': 'application/octet-stream',
};
function mimeOf(filePath) {
  return MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
}

function sendText(res, status, message) {
  const body = Buffer.from(message + '\n', 'utf8');
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}
function sendJson(res, status, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

// 静态路径 → 绝对文件路径,并保证它**落在 rootDir 里面**。
// ★ 这是本文件后果最重的一处:没有这道检查,一个本地网页就能读整块磁盘
//   (GET /../../../../Windows/win.ini)。
// ★ 判据刻意用「解析后的绝对路径必须落在 rootAbs 里面」,而不是「字符串里有没有 ..」:
//   后者漏掉 URL 编码(%2e%2e 会被 URL 解析器归一化掉、但 %2f 不会)与一切别的变体,
//   而前者是**结构性**的 —— 无论输入长什么样,解析完都得落在根里面。
// ★ URL 解析器本身也会归一化掉 `..`(实测 /../x → /x),所以这里是**第二道**闸;
//   真正危险的是 /..%2f..(编码过的分隔符),那一个必须靠这一道挡。
function staticFileFor(rootDir, urlPath, indexName) {
  let rel;
  try { rel = decodeURIComponent(String(urlPath)); }
  catch (e) { return { status: 400, message: 'URL 编码非法' }; }
  if (rel.indexOf('\0') >= 0) return { status: 400, message: '路径里含空字节' };
  rel = rel.split('\\').join('/');                 // Windows 上反斜杠也是分隔符
  if (rel === '/' || rel === '') rel = '/' + indexName;
  const rootAbs = path.resolve(rootDir);
  const target = path.resolve(rootAbs, '.' + (rel.charAt(0) === '/' ? rel : '/' + rel));
  if (target !== rootAbs && target.indexOf(rootAbs + path.sep) !== 0) {
    return { status: 403, message: '路径越出静态根目录' };
  }
  return { status: 200, file: target };
}

function serveStatic(res, resolved, headOnly) {
  if (resolved.status !== 200) return sendText(res, resolved.status, resolved.message);
  fs.stat(resolved.file, function (err, st) {
    // ★ 目录也走这里 → 404:规格 §4.9 明写「不做目录浏览」。
    if (err || !st.isFile()) return sendText(res, 404, '找不到 ' + path.basename(resolved.file));
    res.writeHead(200, {
      'Content-Type': mimeOf(resolved.file),
      'Content-Length': st.size,
      // ★ 一定要关缓存:编辑器是"改完立刻刷新看效果"的工作流,
      //   浏览器缓存住旧 .js 会让用户对着旧代码调半天。
      'Cache-Control': 'no-store',
    });
    if (headOnly) return res.end();
    fs.createReadStream(resolved.file).pipe(res);
  });
}

// /api/* 的分派。Task 2 会长出 /api/maps 与 GET /api/map,Task 3 再长出 PUT /api/map。
function handleApi(req, res, parsed, ctx) {
  return sendText(res, 404, '未知接口 ' + parsed.pathname);
}

function createServer(opts) {
  opts = opts || {};
  const ctx = {
    rootDir: opts.rootDir || DEFAULT_ROOT_DIR,
    mapsDir: opts.mapsDir || DEFAULT_MAPS_DIR,
    indexName: opts.index || DEFAULT_INDEX,
    maxMapBytes: opts.maxMapBytes === undefined ? MAX_MAP_BYTES : opts.maxMapBytes,
    logger: opts.logger || function () {},
  };
  return http.createServer(function (req, res) {
    let parsed;
    try { parsed = new URL(req.url, 'http://' + DEFAULT_HOST); }
    catch (e) { return sendText(res, 400, '请求 URL 非法'); }
    if (parsed.pathname.indexOf('/api/') === 0) return handleApi(req, res, parsed, ctx);
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return sendText(res, 405, '静态路径只接受 GET/HEAD,收到 ' + req.method);
    }
    serveStatic(res, staticFileFor(ctx.rootDir, parsed.pathname, ctx.indexName), req.method === 'HEAD');
  });
}

// 端口占用时"点名是谁占的"(规格 §7 风险登记)。
// ★ 尽力而为:拿不到就退回一句让用户自己查的命令,**绝不抛错** ——
//   它的唯一职责是把错误信息写清楚,它自己失败会把"起不来"变成"起不来且不知道为什么"。
function describePortOwner(port) {
  const hint = '  查占用者:netstat -ano | findstr :' + port + '(最后一列是 PID),再 taskkill /PID <PID> /F';
  if (process.platform !== 'win32') return hint;
  try {
    const out = execFileSync('netstat', ['-ano'], { encoding: 'utf8' });
    const lines = out.split(/\r?\n/).filter(function (l) {
      return l.indexOf(':' + port) >= 0 && /LISTENING/i.test(l);
    });
    if (lines.length) {
      return '  占用者:\n' + lines.map(function (l) { return '    ' + l.trim(); }).join('\n') + '\n' + hint;
    }
  } catch (e) { /* 拿不到就只给 hint */ }
  return hint;
}

function openBrowser(url) {
  try {
    if (process.platform === 'win32') {
      spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore' }).unref();
    } else if (process.platform === 'darwin') {
      spawn('open', [url], { detached: true, stdio: 'ignore' }).unref();
    } else {
      spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref();
    }
  } catch (e) {
    console.error('[editor] 打开浏览器失败(请手动访问 ' + url + '):' + e.message);
  }
}

// 绑定并起服务。port:0 = 由系统分配一个空闲端口(冒烟测试用,互不打架)。
function startServer(opts) {
  opts = opts || {};
  const host = opts.host || DEFAULT_HOST;
  const port = opts.port === undefined ? DEFAULT_PORT : opts.port;
  const server = createServer(opts);
  return new Promise(function (resolve, reject) {
    server.once('error', function (err) {
      if (err && err.code === 'EADDRINUSE') {
        return reject(new Error('端口 ' + port + ' 已被占用 —— 编辑器服务器起不来。\n' +
                                describePortOwner(port)));
      }
      reject(err);
    });
    server.listen(port, host, function () {
      const addr = server.address();
      const url = 'http://' + host + ':' + addr.port + '/';
      // ★ 默认**不**弹浏览器:弹浏览器是命令行入口的事(startServer 是给测试与嵌入方用的)。
      //   反过来(库默认弹)会让每一个冒烟用例都在开发机上弹出一个浏览器窗口。
      if (opts.openBrowser === true) openBrowser(url);
      resolve({ server: server, port: addr.port, host: host, url: url });
    });
  });
}

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--no-open') o.openBrowser = false;
    else if (a === '--port') { const n = parseInt(argv[++i], 10); if (isFinite(n)) o.port = n; }
    else if (a === '--maps') o.mapsDir = argv[++i];
    else if (a === '--root') o.rootDir = argv[++i];
    else console.error('[editor] 未知参数 ' + a);
  }
  return o;
}

if (require.main === module) {
  const opts = parseArgs(process.argv.slice(2));
  // ★ 只有命令行入口默认开浏览器;--no-open 关掉(parseArgs 会写进 openBrowser:false)。
  startServer(Object.assign({ openBrowser: true }, opts)).then(function (r) {
    console.log('[editor] 服务器就绪 ' + r.url);
    console.log('[editor] 静态根 ' + path.resolve(opts.rootDir || DEFAULT_ROOT_DIR));
    console.log('[editor] 地图目录 ' + path.resolve(opts.mapsDir || DEFAULT_MAPS_DIR));
  }).catch(function (err) {
    console.error('[editor] 启动失败:' + (err && err.message ? err.message : String(err)));
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_HOST: DEFAULT_HOST, DEFAULT_PORT: DEFAULT_PORT,
  DEFAULT_ROOT_DIR: DEFAULT_ROOT_DIR, DEFAULT_MAPS_DIR: DEFAULT_MAPS_DIR,
  DEFAULT_INDEX: DEFAULT_INDEX, MAX_MAP_BYTES: MAX_MAP_BYTES,
  MIME: MIME, mimeOf: mimeOf, sendText: sendText, sendJson: sendJson,
  staticFileFor: staticFileFor, serveStatic: serveStatic, handleApi: handleApi,
  createServer: createServer, startServer: startServer,
  describePortOwner: describePortOwner, openBrowser: openBrowser, parseArgs: parseArgs,
};
```

新建 `level_editor/serve.bat`(**必须以 UTF-8 无 BOM 存盘** —— 带 BOM 时 cmd 会把第一行当命令报错):

```bat
@echo off
rem serve.bat —— 起本地编辑器服务器并打开浏览器(规格 §4.9)。
rem ★ 编辑器只通过 HTTP 打开:file:// 下没有 Worker、没有同源、也读不到 maps/。
rem ★ 中文错误信息要靠 UTF-8 代码页,否则 cmd 里是乱码。
chcp 65001 >nul
cd /d "%~dp0"
echo [serve] 正在启动编辑器服务器(node editor_server.js)...
node editor_server.js
echo.
echo [serve] 服务器已退出(退出码 %ERRORLEVEL%)。
pause
```

新建 `level_editor/editor.html`(占位骨架页 —— Task 6 会重写它):

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>The Cyancular Ruins — 关卡编辑器</title>
</head>
<body>
<h1>The Cyancular Ruins — 关卡编辑器</h1>
<p>这是计划 2a 的<strong>最小骨架页</strong>:它存在的意义是让本地服务器有东西可服务、
让 <code>core.js</code> 在真实浏览器的 HTTP 环境里被加载一次。</p>
<p>真正的界面(渲染 / 工具栏 / 图层 / 持久化)在计划 2b 里替换本页的 body。</p>
<p>服务器连通性:<span id="status">…</span></p>
<script src="core.js"></script>
<script>
// 只依赖 core.js —— tint.js 要到 Task 4 才落地,这一版还不引用它。
document.getElementById('status').textContent =
  'core.js 已加载,Core.FORMAT_VERSION = ' + Core.FORMAT_VERSION +
  ',尺寸上限 ' + Core.MAX_CELLS_W + '×' + Core.MAX_CELLS_H + ' 格';
</script>
</body>
</html>
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node server_smoke.js`

Expected: 全部 `ok -`,末行 `SERVER SMOKE OK`,退出码 0。

- [ ] **Step 5: 提交**

```bash
git add level_editor/editor_server.js level_editor/serve.bat level_editor/editor.html level_editor/server_smoke.js
git commit -F - <<'EOF'
feat(editor): 本地服务器骨架 + serve.bat + 最小入口页

editor_server.js:只绑 127.0.0.1:8777(避开游戏侧 7777/7800+/7999),
服务 level_editor/ 下的静态文件;路径安全用「解析后必须落在静态根里面」
这道结构性判据(不是"字符串里有没有 .."),编码过的分隔符 /..%2f 靠它挡。
端口占用时报错要点名占用者(netstat + PID),serve.bat 结尾 pause 免得窗口一闪而过。

入口页改为新建 editor.html:2a 不实现任何 UI,重写 structure-editor.html
等于把仓库里唯一能用的编辑器换成半成品,而它的敌人注册表标记是
sync-enemies.js 的锚点。旧文件一个字节不动,相位 ①b 跑 --check 钉住。
EOF
```

---

## Task 2: 地图名守卫 + `/api/maps` + `GET /api/map`

**Files:**
- Modify: `level_editor/editor_server.js`(加名守卫与读接口,重写 `handleApi`)
- Modify: `level_editor/server_smoke.js`(追加相位 ⑤、⑥)

**Interfaces:**
- Consumes: Task 1 的 `sendText` / `sendJson` / `createServer` 的 `ctx`
- Produces:
  - `MAP_NAME_RE`(=`/^[A-Za-z0-9_\-]+\.cyrm$/`)
  - `MAX_MAP_NAME_LEN = 64`
  - `isValidMapName(name) -> Boolean`
  - `mapPathFor(mapsDir, name) -> String`(非法名抛错)
  - `listMaps(mapsDir, logger) -> Array<{name:String, size:Number, mtime:Number}>`(按名字升序)
  - `serveMapFile(res, target, name, headOnly) -> void`
  - 路由:`GET|HEAD /api/maps` → `{maps:[…]}`;`GET|HEAD /api/map?p=<name>` → 原始字节

- [ ] **Step 1: 在 `server_smoke.js` 的 `// ==== 断言区结束 ====` 之前追加两个相位**

```js
  // ==== 相位 ⑤ 地图名守卫(规格 §4.9,风险登记点名"必须写测试")====
  {
    const bad = ['', 'demo', 'demo.txt', 'a.cyrm.bak', '..cyrm', '.cyrm', 'demo.cyrm\n',
                 '../demo.cyrm', '..%2fdemo.cyrm', '/demo.cyrm', 'a/b.cyrm', 'a\\b.cyrm',
                 'C:\\demo.cyrm', 'demo cyrm', 'demo\n.cyrm', 'demo.cyrm/x', '..\\..\\x.cyrm',
                 'demo\u0000.cyrm', 'x'.repeat(65) + '.cyrm', null, 42, undefined];
    let allRejected = true, firstFail = '';
    for (const n of bad) {
      // ★ 用「不提前 return」的写法:一条失败不该让后面 15 条一条都不跑(否则修一处红一处)。
      if (srv.isValidMapName(n) !== false) { allRejected = false; if (!firstFail) firstFail = JSON.stringify(n); }
    }
    ok(allRejected, '★ isValidMapName 拒绝全部 ' + bad.length + ' 个非法名(首个漏网:' + firstFail + ')');
    const good = ['demo.cyrm', 'factory1v1.cyrm', 'a.cyrm', 'A_1-2.cyrm', 'x'.repeat(58) + '.cyrm'];
    let allAccepted = true, firstGoodFail = '';
    for (const n of good) {
      if (srv.isValidMapName(n) !== true) { allAccepted = false; if (!firstGoodFail) firstGoodFail = n; }
    }
    ok(allAccepted, 'isValidMapName 接受全部 ' + good.length + ' 个合法名(首个漏网:' + firstGoodFail + ')');
    ok(srv.MAP_NAME_RE.source === '^[A-Za-z0-9_\\-]+\\.cyrm$', 'MAP_NAME_RE 与规格 §4.9 逐字一致');
    ok(srv.MAX_MAP_NAME_LEN === 64, 'MAX_MAP_NAME_LEN === 64(规格的正则没有长度上界,这条是防御性补充)');
    let threw = false;
    try { srv.mapPathFor(tmpRoot, '../evil.cyrm'); } catch (e) { threw = true; }
    ok(threw, 'mapPathFor: 非法名抛错(不返回一个越界的路径)');
    eq(srv.mapPathFor(tmpRoot, 'ok.cyrm'), path.join(path.resolve(tmpRoot), 'ok.cyrm'),
       'mapPathFor: 合法名 = mapsDir + 名字');
  }

  // ==== 相位 ⑥ /api/maps + GET /api/map ====
  {
    const mapsDir = path.join(tmpRoot, 'maps');
    fs.mkdirSync(mapsDir, { recursive: true });
    fs.writeFileSync(path.join(mapsDir, 'b_second.cyrm'), Buffer.from([1, 2, 3, 4, 5]));
    fs.writeFileSync(path.join(mapsDir, 'a_first.cyrm'), Buffer.from([9, 9]));
    fs.writeFileSync(path.join(mapsDir, 'notes.txt'), 'not a map');
    fs.mkdirSync(path.join(mapsDir, 'sub.cyrm'), { recursive: true });
    fs.writeFileSync(path.join(mapsDir, 'sub.cyrm', 'keep.txt'), 'x');
    const logged = [];
    const apiSrv = track(await srv.startServer({
      rootDir: __dirname, mapsDir: mapsDir, port: 0,
      logger: function (m) { logged.push(m); },
    }));

    eq(srv.listMaps(path.join(tmpRoot, 'no_such_dir'), null), [], 'listMaps: 目录不存在 = 空库,不抛错');

    const rm = await request(apiSrv.port, 'GET', '/api/maps');
    ok(rm.status === 200, 'GET /api/maps → 200');
    ok(/^application\/json/.test(String(rm.headers['content-type'])), 'GET /api/maps → application/json');
    const data = JSON.parse(rm.body.toString('utf8'));
    eq(data.maps.map(function (m) { return m.name; }), ['a_first.cyrm', 'b_second.cyrm'],
       '★ /api/maps: 只列合法且是文件的 .cyrm,按名字升序(notes.txt 与同名目录都不进来)');
    eq(data.maps[0].size, 2, '/api/maps: size = 文件字节数');
    ok(typeof data.maps[0].mtime === 'number' && data.maps[0].mtime > 0, '/api/maps: mtime 是数字');
    ok(logged.some(function (m) { return m.indexOf('notes.txt') >= 0; }),
       '★ /api/maps: 被跳过的文件**点名记日志**(绝不静默消失)');

    const rg = await request(apiSrv.port, 'GET', '/api/map?p=b_second.cyrm');
    ok(rg.status === 200, 'GET /api/map → 200');
    ok(rg.headers['content-type'] === 'application/octet-stream', 'GET /api/map → octet-stream');
    sameBytes(rg.body, Buffer.from([1, 2, 3, 4, 5]), 'GET /api/map: 字节原样返回');
    ok(rg.headers['cache-control'] === 'no-store', 'GET /api/map → no-store');

    const r404 = await request(apiSrv.port, 'GET', '/api/map?p=nope.cyrm');
    ok(r404.status === 404, 'GET /api/map 不存在的名字 → 404');
    const rMiss = await request(apiSrv.port, 'GET', '/api/map');
    ok(rMiss.status === 400, 'GET /api/map 缺 p 参数 → 400');
    const rTrav = await request(apiSrv.port, 'GET', '/api/map?p=' + encodeURIComponent('../package.json'));
    ok(rTrav.status === 400, '★ GET /api/map 路径穿越名 → 400');
    ok(rTrav.body.toString('utf8').indexOf('"name"') < 0, '★ 那个 400 的正文里没有 package.json 的内容');
    const rTrav2 = await request(apiSrv.port, 'GET', '/api/map?p=' + encodeURIComponent('..%2fdemo.cyrm'));
    ok(rTrav2.status === 400, '★ GET /api/map 编码过的穿越名 → 400');
    const rPost = await request(apiSrv.port, 'POST', '/api/map?p=b_second.cyrm', Buffer.from([1]));
    ok(rPost.status === 405, 'POST /api/map → 405');
    const rMapsPost = await request(apiSrv.port, 'POST', '/api/maps', Buffer.from([1]));
    ok(rMapsPost.status === 405, 'POST /api/maps → 405');
  }
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node server_smoke.js`

Expected: 相位 ⑤ 第一行就炸 —— 末行 `FAIL: 未捕获异常(后面的断言一行都没跑):` + `TypeError: srv.isValidMapName is not a function`,退出码 1。

(★ 这是刻意的设计:导出缺失时**大声中断**而不是一路 `FAIL` 到底 —— 后面的断言依赖它,继续跑只会刷屏。)

- [ ] **Step 3: 实现名守卫与两个读接口**

在 `editor_server.js` 的 `serveStatic` **之后**插入:

```js
// ── 地图名守卫(规格 §4.9)──
// ★ 没有这一条,一个本地网页就能读写整块磁盘 —— 它是本文件唯一的安全边界,
//   也是规格 §7 风险登记里点名"这条必须写测试"的那一条。
// 只接受**裸文件名**:不接受路径分隔符(/ 与 \)、不接受 ..、不接受空字节、不接受绝对路径。
const MAP_NAME_RE = /^[A-Za-z0-9_\-]+\.cyrm$/;
// 规格的正则没有长度上界;这条是防御性补充(真名由 core.js 的 sanitizeName 生成,
// ≤32 字符 + ".cyrm" = 37,64 留了一倍余量)。
const MAX_MAP_NAME_LEN = 64;

function isValidMapName(name) {
  if (typeof name !== 'string') return false;
  if (name.length === 0 || name.length > MAX_MAP_NAME_LEN) return false;
  // 空字节:正则本来就不放行,这里再挡一次 —— 防的是"将来有人把正则改宽"。
  if (name.indexOf('\0') >= 0) return false;
  return MAP_NAME_RE.test(name);
}

function mapPathFor(mapsDir, name) {
  if (!isValidMapName(name)) throw new Error('地图名非法:' + JSON.stringify(name));
  const dir = path.resolve(mapsDir);
  const target = path.resolve(dir, name);
  // 双保险:即便正则哪天被改宽,这里也保证出去的路径一定在 maps/ 里面。
  if (target.indexOf(dir + path.sep) !== 0) throw new Error('地图名越出 maps 目录:' + name);
  return target;
}

// 列地图。★ 只列**打得开**的(名字不过守卫的文件列出来也点不开),但绝不静默 ——
// 跳过的每一个都记一条日志点名。
function listMaps(mapsDir, logger) {
  const out = [];
  let names = [];
  try { names = fs.readdirSync(mapsDir); }
  catch (e) { return out; }                     // 目录不存在 = 空库,不是错误
  names.sort();
  for (const n of names) {
    if (!isValidMapName(n)) { if (logger) logger('跳过不可打开的文件:' + n); continue; }
    let st;
    try { st = fs.statSync(path.join(mapsDir, n)); } catch (e) { continue; }
    if (!st.isFile()) continue;
    out.push({ name: n, size: st.size, mtime: st.mtimeMs });
  }
  return out;
}

function serveMapFile(res, target, name, headOnly) {
  fs.stat(target, function (err, st) {
    if (err || !st.isFile()) return sendText(res, 404, '找不到地图 ' + name);
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': st.size,
      'Cache-Control': 'no-store',
    });
    if (headOnly) return res.end();
    fs.createReadStream(target).pipe(res);
  });
}
```

把 `handleApi` **整体替换**成:

```js
function handleApi(req, res, parsed, ctx) {
  if (parsed.pathname === '/api/maps') {
    if (req.method !== 'GET' && req.method !== 'HEAD') return sendText(res, 405, '只接受 GET');
    const maps = listMaps(ctx.mapsDir, ctx.logger);
    ctx.logger('列出 ' + maps.length + ' 张地图');
    return sendJson(res, 200, { maps: maps });
  }
  if (parsed.pathname === '/api/map') {
    const name = parsed.searchParams.get('p');
    // ★ 名字不过关一律在**碰文件系统之前**回 400。
    if (!isValidMapName(name)) {
      return sendText(res, 400,
        '地图名非法(只接受裸文件名 ' + MAP_NAME_RE.source + '):' + JSON.stringify(name));
    }
    const target = mapPathFor(ctx.mapsDir, name);
    if (req.method === 'GET' || req.method === 'HEAD') {
      return serveMapFile(res, target, name, req.method === 'HEAD');
    }
    return sendText(res, 405, '只接受 GET');
  }
  return sendText(res, 404, '未知接口 ' + parsed.pathname);
}
```

导出表追加(放在 `serveStatic: serveStatic, handleApi: handleApi,` 那一行的后面):

```js
  MAP_NAME_RE: MAP_NAME_RE, MAX_MAP_NAME_LEN: MAX_MAP_NAME_LEN,
  isValidMapName: isValidMapName, mapPathFor: mapPathFor, listMaps: listMaps,
  serveMapFile: serveMapFile,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node server_smoke.js`

Expected: 全部 `ok -`,末行 `SERVER SMOKE OK`,退出码 0。

- [ ] **Step 5: 提交**

```bash
git add level_editor/editor_server.js level_editor/server_smoke.js
git commit -F - <<'EOF'
feat(editor): 地图名守卫 + /api/maps + GET /api/map

名字只接受裸文件名 ^[A-Za-z0-9_\-]+\.cyrm$(规格 §4.9):拒绝 / 与 \ 分隔符、
..、空字节、绝对路径、超长名。不过关的在碰文件系统**之前**就回 400。

/api/maps 只列合法且是文件的 .cyrm,但被跳过的文件会点名记日志 ——
绝不静默消失(库里的东西"看不见但还在"是最难查的一类问题)。
EOF
```

---

## Task 3: `PUT /api/map`(原子写 + 硬上限 + 被拒的写逐字节不动原文件)

**Files:**
- Modify: `level_editor/editor_server.js`(加 `readBody` / `writeMapAtomic` / `receiveMapFile`,改 `handleApi` 的 `/api/map` 分支)
- Modify: `level_editor/server_smoke.js`(追加相位 ⑦)

**Interfaces:**
- Consumes: Task 2 的 `isValidMapName` / `mapPathFor`
- Produces:
  - `readBody(req, maxBytes) -> Promise<Buffer>`(超限 reject,message 里含 `上限`)
  - `writeMapAtomic(mapsDir, name, bytes) -> {name:String, size:Number}`(失败抛错且清掉临时文件)
  - `receiveMapFile(req, res, name, ctx) -> void`
  - 路由:`PUT /api/map?p=<name>`,200 → `{name, size}`;400 空体/坏名;413 超限;500 写失败

- [ ] **Step 1: 在 `server_smoke.js` 的追加相位 ⑥ 之后追加相位 ⑦**

```js
  // ==== 相位 ⑦ PUT /api/map 原子写 ====
  {
    const mapsDir = path.join(tmpRoot, 'maps');
    const readBack = function (n) { return fs.readFileSync(path.join(mapsDir, n)); };
    const noTmpLeft = function () {
      return fs.readdirSync(mapsDir).every(function (n) {
        return n.indexOf('.tmp') < 0;
      }) && fs.readdirSync(path.join(mapsDir, 'sub.cyrm')).every(function (n) {
        return n.indexOf('.tmp') < 0;
      });
    };
    const apiSrv = track(await srv.startServer({
      rootDir: __dirname, mapsDir: mapsDir, port: 0,
    }));
    // 一个 maxMapBytes 很小的服务器,专门用来验 413 —— 不用真发 64MB。
    const smallSrv = track(await srv.startServer({
      rootDir: __dirname, mapsDir: mapsDir, port: 0, maxMapBytes: 16,
    }));

    const put = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([7, 7, 7]));
    ok(put.status === 200, 'PUT 新文件 → 200(实得 ' + put.status + ')');
    eq(JSON.parse(put.body.toString('utf8')), { name: 'c_new.cyrm', size: 3 }, 'PUT 回 JSON {name,size}');
    sameBytes(readBack('c_new.cyrm'), Buffer.from([7, 7, 7]), 'PUT: 落盘字节与请求体一致');
    ok(noTmpLeft(), '★ PUT 之后没有残留临时文件');

    const put2 = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([1, 2, 3, 4]));
    ok(put2.status === 200, 'PUT 覆盖已有文件 → 200');
    sameBytes(readBack('c_new.cyrm'), Buffer.from([1, 2, 3, 4]), 'PUT: 覆盖后是新内容(不留尾巴)');

    // ── 反向:被拒的写绝不能动到已有文件 ──
    const before = readBack('c_new.cyrm');
    const rBadName = await request(apiSrv.port, 'PUT', '/api/map?p=' + encodeURIComponent('../evil.cyrm'),
                                   Buffer.from([0xEE]));
    ok(rBadName.status === 400, '★ PUT 路径穿越名 → 400');
    ok(!fs.existsSync(path.join(tmpRoot, 'evil.cyrm')), '★ PUT 没有在 maps/ 之外写出任何文件');
    const rEmpty = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.alloc(0));
    ok(rEmpty.status === 400, 'PUT 空请求体 → 400(不许用空内容覆盖地图)');
    const rBig = await request(smallSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.alloc(64, 1));
    ok(rBig.status === 413, '★ PUT 超过 maxMapBytes → 413(实得 ' + rBig.status + ')');
    sameBytes(readBack('c_new.cyrm'), before,
              '★★ 三种被拒的 PUT 之后,原文件逐字节没变');
    ok(noTmpLeft(), '被拒的 PUT 也没留临时文件');

    // ★ 写失败的清理路径:目标是**一个非空目录** → rename 必失败 → 临时文件必须被删掉。
    const rDir = await request(apiSrv.port, 'PUT', '/api/map?p=sub.cyrm', Buffer.from([1, 2]));
    ok(rDir.status === 500, '★ PUT 目标是个目录 → 500(写失败,实得 ' + rDir.status + ')');
    ok(fs.statSync(path.join(mapsDir, 'sub.cyrm')).isDirectory() &&
       fs.existsSync(path.join(mapsDir, 'sub.cyrm', 'keep.txt')),
       '★ 写失败后那个目录连同里面的文件都还在(没有被毁掉)');
    ok(noTmpLeft(), '★★ 写失败后临时文件被清掉(否则每次失败都在 maps/ 里留垃圾)');

    // 头请求不能带 body(顺带验 HEAD 分支)
    const rHead = await request(apiSrv.port, 'HEAD', '/api/map?p=c_new.cyrm');
    ok(rHead.status === 200 && rHead.body.length === 0, 'HEAD /api/map → 200 且无正文');
  }
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node server_smoke.js`

Expected: 相位 ⑦ 头一条报 `FAIL - PUT 新文件 → 200(实得 405)`,随后 `FAIL - PUT: 落盘字节与请求体一致`,退出码 1。

- [ ] **Step 3: 实现原子写**

在 `editor_server.js` 的 `serveMapFile` **之后**插入:

```js
// 读请求体,带硬上限。
// ★ 超限守的是**内存**、不是带宽:超限之后不再收集(超限那一块根本不留下),
//   但仍把请求读完再回 413 —— 中途 destroy 会让客户端拿到 ECONNRESET 而不是那条错误信息。
function readBody(req, maxBytes) {
  return new Promise(function (resolve, reject) {
    const chunks = [];
    let total = 0;
    let overflow = false;
    req.on('data', function (c) {
      total += c.length;
      if (total > maxBytes) {
        // ★ 判在 push **之前**(与 core.js 的 inflateBytes 同款纪律):
        //   "先收后判"等于已经把超限数据存住了。
        overflow = true;
        chunks.length = 0;
        return;
      }
      if (!overflow) chunks.push(c);
    });
    req.on('end', function () {
      if (overflow) return reject(new Error('请求体超过 ' + maxBytes + ' 字节上限'));
      resolve(Buffer.concat(chunks, total));
    });
    req.on('error', reject);
  });
}

let tmpSeq = 0;
// 原子写:先写同目录的临时文件,再 rename 覆盖目标。
// ★ 临时文件必须落在**同一个目录**(同一卷)里:跨卷 rename 会退化成"复制 + 删除",
//   那就不是原子的了 —— 而这个函数的全部意义就是"断电也不会留下半截地图"。
function writeMapAtomic(mapsDir, name, bytes) {
  const target = mapPathFor(mapsDir, name);
  fs.mkdirSync(mapsDir, { recursive: true });
  const tmp = target + '.' + process.pid + '.' + (++tmpSeq) + '.tmp';
  try {
    fs.writeFileSync(tmp, bytes);
    fs.renameSync(tmp, target);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (e2) { /* 清理失败不改写主错误 */ }
    throw e;
  }
  return { name: name, size: bytes.length };
}

function receiveMapFile(req, res, name, ctx) {
  readBody(req, ctx.maxMapBytes).then(function (buf) {
    // ★ 空体一律拒:一个坏掉的前端循环最可能的表现就是"发出一个空 PUT",
    //   那会把一张好地图**无声地清零**。宁可回 400 让用户自己删文件。
    if (buf.length === 0) {
      sendText(res, 400, '空请求体:拒绝用空内容覆盖地图');
      return;
    }
    const out = writeMapAtomic(ctx.mapsDir, name, buf);
    ctx.logger('写入 ' + name + ' ' + out.size + ' 字节');
    sendJson(res, 200, out);
  }).catch(function (err) {
    const msg = (err && err.message) ? err.message : String(err);
    if (msg.indexOf('上限') >= 0) { sendText(res, 413, msg); return; }
    sendText(res, 500, '写入失败:' + msg);
  });
}
```

把 `handleApi` 里 `/api/map` 分支的最后两行:

```js
    const target = mapPathFor(ctx.mapsDir, name);
    if (req.method === 'GET' || req.method === 'HEAD') {
      return serveMapFile(res, target, name, req.method === 'HEAD');
    }
    return sendText(res, 405, '只接受 GET');
```

替换成:

```js
    const target = mapPathFor(ctx.mapsDir, name);
    if (req.method === 'GET' || req.method === 'HEAD') {
      return serveMapFile(res, target, name, req.method === 'HEAD');
    }
    if (req.method === 'PUT') return receiveMapFile(req, res, name, ctx);
    return sendText(res, 405, '只接受 GET / PUT');
```

导出表追加:

```js
  readBody: readBody, writeMapAtomic: writeMapAtomic, receiveMapFile: receiveMapFile,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node server_smoke.js`

Expected: 全部 `ok -`,末行 `SERVER SMOKE OK`,退出码 0。

- [ ] **Step 5: 提交**

```bash
git add level_editor/editor_server.js level_editor/server_smoke.js
git commit -F - <<'EOF'
feat(editor): PUT /api/map 原子写 + 请求体上限

先写同目录临时文件再 rename:断电/失败都不会留下半截地图(跨卷 rename
会退化成复制+删除,所以临时文件必须与目标同目录)。失败路径清临时文件。

请求体上限 64MB(= core.js 的 MAX_BODY_SIZE):超限守的是内存不是带宽 ——
不再收集但把请求读完再回 413,中途 RST 会让客户端拿到 ECONNRESET 而不是那条错误。
空体一律 400:坏掉的前端最可能的表现就是发个空 PUT,那会把好地图无声清零。
EOF
```

---

## Task 4: `tint.js` 辅码像素数学(规范定义 + 取角 + 16×16 小图)

**Files:**
- Create: `level_editor/tint.js`
- Create: `level_editor/tint_smoke.js`

**Interfaces:**
- Consumes: `globalThis.Core`(硬依赖)—— `SUB_PER_CELL` / `SUB_PX` / `HUE_NEUTRAL` / `BRI_NEUTRAL` / `SAT_NEUTRAL` / `ALPHA_NEUTRAL` / `hueOf` / `brightOf` / `satOf` / `alphaOf` / `texOf` / `neutralDesc`
- Produces(`globalThis.Tint`):
  - `LEVELS = 8`
  - `HUE_OFFSET_DEG = [-60,-45,-30,-15,0,15,30,45]`、`MUL = [0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3]`、`ALPHA_NUM = [0,1,2,3,4,5,6,7]`
  - `NEUTRAL = {hue, bri, sat, alpha}`(取自 `Core`)
  - `hueOffsetOf(level) -> Number`、`mulOf(level) -> Number`、`alphaScaleOf(level) -> Number`
  - `fposmod(a, n) -> Number`
  - `rgbToHsv(r,g,b) -> {h, s, v}`、`hsvToRgb(h,s,v) -> {r, g, b}`(均为 0–1 浮点,`h` 为度)
  - `tintRGBA(r, g, b, a, desc) -> {r, g, b, a}` —— **规范定义,浮点**
  - `tintBytes(r, g, b, a, desc) -> [r, g, b, a]` —— 8 位落地(入参 0–255),取整规则 `Math.round(x*255)`
  - `BLOCK_PX = 32`、`QUAD_PX = 8`、`TILE_PX = 16`、`DEFAULT_MAX_TILES = 8192`
  - `textureBlockRect(texture, atlasWidth) -> {x, y, w, h}`
  - `buildTilePixels(atlas, atlasWidth, texture, qx, qy, desc) -> Uint8ClampedArray(16*16*4)`

- [ ] **Step 1: 写测试 `level_editor/tint_smoke.js`(此时必然红)**

新建 `level_editor/tint_smoke.js`:

```js
'use strict';
// Node 冒烟 —— 辅码像素数学与 tinted-tile 缓存(level_editor/tint.js)。
// Run: cd level_editor && node tint_smoke.js
// 判据:文本 `TINT SMOKE OK` + 退出码 0。
// ★ tint.js 是经典脚本(globalThis.Tint),core.js 是它的硬依赖 —— 加载顺序不能反。

require('./core.js');
require('./tint.js');
const Core = globalThis.Core;
const Tint = globalThis.Tint;

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
  const a = Array.prototype.slice.call(actual);
  const e = Array.prototype.slice.call(expected);
  if (a.length !== e.length) {
    fail++; console.error('  FAIL - ' + msg + ' (长度 ' + a.length + ' ≠ 期望 ' + e.length + ')');
    return;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== e[i]) {
      fail++; console.error('  FAIL - ' + msg + ' (第 ' + i + ' 个字节: 实得 ' + a[i] + ', 期望 ' + e[i] + ')');
      return;
    }
  }
  pass++; console.log('  ok  - ' + msg);
}
// ★ 反向断言必须同时断言「错在哪」:只判「有没有抛」是假绿。
function throws(fn, msg, expectSub) {
  let e = null;
  try { fn(); } catch (err) { e = err; }
  if (e === null) { fail++; console.error('  FAIL - ' + msg + ' (未抛出异常)'); return; }
  if (expectSub !== undefined && String(e.message).indexOf(expectSub) < 0) {
    fail++; console.error('  FAIL - ' + msg + ' (异常文本里没有 "' + expectSub + '")\n        got: ' + e.message);
    return;
  }
  pass++; console.log('  ok  - ' + msg);
}

// 合成图集:3 行 × 10 列、每块 32×32。每个像素编码成
//   R = 块内 x × 8, G = 块内 y × 8, B = 块号(0-based), A = 255
// 于是"取到了哪一块的哪个像素"既好读、也能被断言验。
const COLS = 10, ATLAS_W = COLS * 32, ATLAS_H = 96;
function makeAtlas() {
  const a = new Uint8ClampedArray(ATLAS_W * ATLAS_H * 4);
  for (let y = 0; y < ATLAS_H; y++) {
    for (let x = 0; x < ATLAS_W; x++) {
      const i = (y * ATLAS_W + x) * 4;
      a[i] = (x % 32) * 8;
      a[i + 1] = (y % 32) * 8;
      a[i + 2] = Math.floor(y / 32) * COLS + Math.floor(x / 32);
      a[i + 3] = 255;
    }
  }
  return a;
}

(async function main() {
  setTimeout(function () {
    console.error('FAIL: 120 秒超时 —— 某个断言挂住了');
    process.exit(1);
  }, 120000);

  // ==== 相位 ① 常量与来源 ====
  ok(Tint.LEVELS === 8, 'LEVELS === 8(规格 §2.3 的八档)');
  eq(Tint.HUE_OFFSET_DEG, [-60, -45, -30, -15, 0, 15, 30, 45], 'hue 档位表(不对称:−60…+45)');
  eq(Tint.MUL, [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3], '亮度/饱和度乘法档位表');
  eq(Tint.NEUTRAL, { hue: Core.HUE_NEUTRAL, bri: Core.BRI_NEUTRAL, sat: Core.SAT_NEUTRAL,
                     alpha: Core.ALPHA_NEUTRAL },
     '★ 中性档直接取自 Core(不自己抄一份)');
  ok(Tint.NEUTRAL.hue === 4 && Tint.NEUTRAL.alpha === 7,
     '★ 三列的中性档不在同一行:色相/亮度/饱和在档 4,alpha 在档 7');
  eq(Tint.hueOffsetOf(4), 0, 'hue 中性档 4 → 0°');
  eq(Tint.mulOf(4), 1, '亮度/饱和度中性档 4 → ×1.0(恒等元)');
  eq(Tint.alphaScaleOf(7), 1, 'alpha 中性档 7 → ×1');
  ok(Math.abs(Tint.alphaScaleOf(4) - 4 / 7) < 1e-12, '★ alpha 档 4 是 4/7 而不是 1');
  ok(Tint.BLOCK_PX === 32 && Tint.QUAD_PX === 8 && Tint.TILE_PX === 16,
     '贴图几何:块 32 / 象限 8 / 小图 16(= Core.SUB_PX)');
  ok(Tint.TILE_PX === Core.SUB_PX && Tint.QUAD_PX * 2 === Tint.TILE_PX,
     '★ 小图边长 = 子格边长(16),象限 8px 放大 2× 正好铺满');
  ok(Tint.DEFAULT_MAX_TILES * Tint.TILE_PX * Tint.TILE_PX * 4 === 8 * 1024 * 1024,
     '★ 缓存上限 ' + Tint.DEFAULT_MAX_TILES + ' 张 × 16×16×4 字节 = 正好 8MB(规格 §4.3 闸 1)');

  // ==== 相位 ② HSV(是 HSV 不是 HSL)====
  eq(Tint.rgbToHsv(1, 0, 0), { h: 0, s: 1, v: 1 }, 'rgbToHsv: 纯红 → (0,1,1)');
  eq(Tint.rgbToHsv(0, 1, 1), { h: 180, s: 1, v: 1 }, 'rgbToHsv: 青 → (180,1,1)');
  eq(Tint.rgbToHsv(0.5, 0.5, 0.5), { h: 0, s: 0, v: 0.5 }, 'rgbToHsv: 灰 → s=0');
  eq(Tint.rgbToHsv(0, 0, 0), { h: 0, s: 0, v: 0 }, 'rgbToHsv: 黑 → 全 0(不能出 NaN)');
  const cyan = Tint.hsvToRgb(180, 1, 1);
  ok(Math.abs(cyan.r) < 1e-12 && Math.abs(cyan.g - 1) < 1e-12 && Math.abs(cyan.b - 1) < 1e-12,
     'hsvToRgb: (180,1,1) → 青');
  eq(Tint.hsvToRgb(360, 1, 1), Tint.hsvToRgb(0, 1, 1), 'hsvToRgb: 360° 与 0° 同结果');
  ok(Math.abs(Tint.fposmod(-60, 360) - 300) < 1e-12, 'fposmod: 负数绕回正区间');

  // ==== 相位 ③ tint.js 对 core.js 的依赖是结构性的 ====
  (function () {
    const saveCore = globalThis.Core, saveTint = globalThis.Tint;
    const p = require.resolve('./tint.js');
    delete require.cache[p];
    delete globalThis.Core;
    let err = null;
    try { require('./tint.js'); } catch (e) { err = e; }
    delete require.cache[p];
    globalThis.Core = saveCore;
    globalThis.Tint = saveTint;
    ok(err !== null && /core\.js/.test(String(err.message)),
       '★ 没有 Core 时 tint.js 当场抛错(常量是派生来的,不是抄来的):' + (err ? err.message : '(没抛)'));
  })();

  // ==== 相位 ④ golden:手工从规格 §2.3 推导的期望值 ====
  // (这一组是"编辑器与游戏 shader 必须逐像素一致"的唯一硬证据 ——
  //  期望值全部手推,不是拿实现跑出来的。)
  (function () {
    const N = Core.neutralDesc(1);
    // 纯红 (255,0,0) → HSV(0,1,1)。
    // H=5(+15°):h'=15 → 扇区 0 → c=1,x=1*(1-|fposmod(0.25,2)-1|)=0.25 → (1,0.25,0) → (255,64,0)
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 5, 4, 7, 7)), [255, 64, 0, 255],
       '★ golden: 纯红 +15° 色相 → (255,64,0)');
    // H=3(−15°):h'=fposmod(-15,360)=345 → 扇区 5 → c=1,x=0.25 → (1,0,0.25) → (255,0,64)
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 3, 4, 7, 7)), [255, 0, 64, 255],
       '★ golden: 纯红 −15° 色相 → (255,0,64)');
    // H=0(−60°):h'=300 → 扇区 5 → x=1 → (1,0,1) 品红 → (255,0,255)
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 0, 4, 7, 7)), [255, 0, 255, 255],
       '★ golden: 纯红 −60° → 品红(色相在 360° 上环绕)');
    // H=7(+45°):h'=45 → 扇区 0 → x=1*(1-|0.75-1|)=0.75 → (1,0.75,0) → (255,191,0)
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 7, 4, 7, 7)), [255, 191, 0, 255],
       '★ golden: 纯红 +45° 色相 → (255,191,0)');
    // 白: s=0,v=1。B=2(×0.8) → v'=0.8 → 0.8*255=204
    eq(Tint.tintBytes(255, 255, 255, 255, Core.packDesc(1, 4, 2, 4, 7)), [204, 204, 204, 255],
       '★ golden: 白 ×0.8 亮度 → 204');
    // 中灰 128/255 × 0.8 = 0.40157 → 102.4 → round 102(加法变亮会得到 77)
    eq(Tint.tintBytes(128, 128, 128, 255, Core.packDesc(1, 4, 2, 4, 7)), [102, 102, 102, 255],
       '★ golden: 中灰 ×0.8 亮度 → 102(**乘法**不是加法)');
    // S=0(×0.6): 纯红 s=1 → 0.6 → HSV(0,0.6,1) → (1,0.4,0.4) → (255,102,102)
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 0, 7)), [255, 102, 102, 255],
       '★ golden: 纯红 ×0.6 饱和度 → (255,102,102)');
    eq(Tint.tintBytes(255, 255, 255, 255, Core.packDesc(1, 4, 4, 0, 7)), [255, 255, 255, 255],
       '★ golden: 白 ×0.6 饱和度 → 仍是白(s=0 时饱和度无效)');
    // S=7(×1.3)作用在已饱和的红上会被 clamp 到 1 —— 不许出越界通道
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 7, 7)), [255, 0, 0, 255],
       '★ golden: 饱和度已满时 ×1.3 被 clamp(不越界)');
    // A=3: a' = 255 × 3/7 = 109.2857 → 109
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 4, 3)), [255, 0, 0, 109],
       '★ golden: alpha 档 3 → 109(= 255×3/7)');
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 4, 4, 4, 0)), [255, 0, 0, 0],
       '★ golden: alpha 档 0 → 0(全透明,颜色不受影响)');
    eq(Tint.tintBytes(255, 0, 0, 255, N), [255, 0, 0, 255], '中性描述符是恒等:纯红');
    // 浮点规范定义与 8 位落地是同一件事
    const f = Tint.tintRGBA(1, 0, 0, 1, Core.neutralDesc(1));
    ok(f.r === 1 && f.g === 0 && f.b === 0 && f.a === 1, 'tintRGBA: 中性描述符下浮点也是恒等');
    const g = Tint.tintRGBA(1, 0, 0, 1, Core.packDesc(1, 5, 4, 7, 7));
    ok(Math.abs(g.g - 0.25) < 1e-12, 'tintRGBA: 浮点值是 0.25(取整只发生在 tintBytes 里)');
    eq(Tint.tintBytes(255, 0, 0, 255, Core.packDesc(1, 5, 4, 7, 7))[1], Math.round(0.25 * 255),
       'tintBytes 的取整规则 = Math.round(x*255),只此一处');
  })();

  // ==== 相位 ⑤ 穷举:中性描述符对 8 位输入逐字节恒等 ====
  (function () {
    const vals = [0, 1, 2, 3, 17, 63, 64, 127, 128, 129, 191, 254, 255];
    let bad = 0, n = 0;
    for (const R of vals) for (const G of vals) for (const B of vals) for (const A of vals) {
      n++;
      const o = Tint.tintBytes(R, G, B, A, Core.neutralDesc(1));
      if (o[0] !== R || o[1] !== G || o[2] !== B || o[3] !== A) bad++;
    }
    ok(bad === 0, '★ 中性描述符对 ' + n + ' 组 8 位输入逐字节恒等(含非灰度色)');
    // 浮点往返:rgb → hsv → rgb 的最大误差必须远小于一个 8 位刻度(1/255 ≈ 0.0039)
    let worst = 0;
    for (let i = 0; i <= 255; i += 3) {
      for (let j = 0; j <= 255; j += 7) {
        for (let k = 0; k <= 255; k += 11) {
          const r = i / 255, g = j / 255, b = k / 255;
          const hsv = Tint.rgbToHsv(r, g, b);
          const o = Tint.hsvToRgb(hsv.h, hsv.s, hsv.v);
          worst = Math.max(worst, Math.abs(o.r - r), Math.abs(o.g - g), Math.abs(o.b - b));
        }
      }
    }
    ok(worst < 1e-9, '★ rgbToHsv → hsvToRgb 的浮点往返最大误差 ' + worst.toExponential(2) + ' < 1e-9');
  })();

  // ==== 相位 ⑥ 贴图块定位与 16×16 小图 ====
  (function () {
    eq(Tint.textureBlockRect(1, 320), { x: 0, y: 0, w: 32, h: 32 }, 'textureBlockRect: 第 1 块在左上');
    eq(Tint.textureBlockRect(10, 320), { x: 288, y: 0, w: 32, h: 32 }, 'textureBlockRect: 第 10 块在第一行行尾');
    eq(Tint.textureBlockRect(11, 320), { x: 0, y: 32, w: 32, h: 32 }, 'textureBlockRect: 第 11 块换行(每行 10 块)');
    eq(Tint.textureBlockRect(21, 320), { x: 0, y: 64, w: 32, h: 32 }, 'textureBlockRect: 第 21 块(第三行首块 = 水)');
    eq(Tint.textureBlockRect(22, 320), { x: 32, y: 64, w: 32, h: 32 }, 'textureBlockRect: 第 22 块(水面)');
    let inside = true;
    for (let t = 1; t <= 22; t++) {
      const r = Tint.textureBlockRect(t, 320);
      if (r.x < 0 || r.y < 0 || r.x + r.w > 320 || r.y + r.h > 320) inside = false;
    }
    ok(inside, 'textureBlockRect: 22 块纹理全部落在 320×320 的 structure.png 里');
    throws(function () { Tint.textureBlockRect(0, 320); }, 'textureBlockRect: 纹理号 0 抛错', '纹理号');

    const atlas = makeAtlas();
    const neutral = Core.neutralDesc(3);
    const px = Tint.buildTilePixels(atlas, ATLAS_W, 3, 0, 0, neutral);
    ok(px instanceof Uint8ClampedArray && px.length === 16 * 16 * 4, 'buildTilePixels: 返回 16×16 RGBA');
    let upscaled = true;
    for (let y = 0; y < 16; y++) {
      for (let x = 0; x < 16; x++) {
        const o = (y * 16 + x) * 4;
        const sx = Math.floor(x / 2), sy = Math.floor(y / 2);
        if (px[o] !== sx * 8 || px[o + 1] !== sy * 8 || px[o + 2] !== 2 || px[o + 3] !== 255) upscaled = false;
      }
    }
    ok(upscaled, '★ buildTilePixels: 取纹理 3 的 (0,0) 象限,8px 最近邻放大 2× 成 16×16');

    const q = Tint.buildTilePixels(atlas, ATLAS_W, 3, 2, 1, neutral);
    let quadOk = true;
    for (let y = 0; y < 16; y++) {
      for (let x = 0; x < 16; x++) {
        const o = (y * 16 + x) * 4;
        const sx = 16 + Math.floor(x / 2), sy = 8 + Math.floor(y / 2);
        if (q[o] !== sx * 8 || q[o + 1] !== sy * 8) quadOk = false;
      }
    }
    ok(quadOk, '★ buildTilePixels: 象限 (2,1) 取的是块内 (16..23, 8..15)(取角映射)');

    // 端到端:白图集 + 亮度档 2 → 整块 204(与相位 ④ 手推的 golden 同源)
    const white = makeAtlas();
    for (let i = 0; i < white.length; i += 4) { white[i] = 255; white[i + 1] = 255; white[i + 2] = 255; }
    const wt = Tint.buildTilePixels(white, ATLAS_W, 1, 1, 3, Core.packDesc(1, 4, 2, 4, 7));
    let all204 = true;
    for (let i = 0; i < wt.length; i += 4) {
      if (wt[i] !== 204 || wt[i + 1] !== 204 || wt[i + 2] !== 204 || wt[i + 3] !== 255) all204 = false;
    }
    ok(all204, '★ buildTilePixels 端到端:白图集 + 亮度档 2 → 整块 16×16 全是 204');

    throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, 0, 0, Core.DESC_AIR); },
           'buildTilePixels: 空气格没有贴图,抛错', '空气');
    throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 31, 0, 0, neutral); },
           'buildTilePixels: 图集里没有这块(越出下边界)抛错', '图集');
  })();

  // ==== 断言区结束 ====
  console.log('');
  console.log('结果: ' + pass + ' 通过, ' + fail + ' 失败');
  if (fail === 0) console.log('TINT SMOKE OK');
  process.exit(fail === 0 ? 0 : 1);
})().catch(function (err) {
  console.error('FAIL: 未捕获异常(后面的断言一行都没跑):');
  console.error(err && err.stack ? err.stack : String(err));
  process.exit(1);
});
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node tint_smoke.js`

Expected: 进程在 `require('./tint.js')` 处死掉 —— `Error: Cannot find module './tint.js'`,退出码 1。

- [ ] **Step 3: 实现 `tint.js`(像素数学部分)**

新建 `level_editor/tint.js`:

```js
// tint.js —— 辅码(descriptor)的像素数学 + tinted-tile 缓存(规格 §2.3 / §4.2 ④)。
//
// ★ 本模块**必须在 core.js 之后加载**:档位的中性行、象限数、位域取值全部取自
//   `globalThis.Core`,不自己抄一份 —— 抄一份就意味着两处会漂,而漂了的表现是
//   "编辑器里调好的颜色进游戏就变样"(不报错,只在玩的时候看出来)。没有 Core 就当场抛错。
// ★ 像素数学必须与游戏侧 shader **逐像素一致**(规格 §2.3;交接文档 §2.2 是同一份公式):
//     · 是 **HSV** 不是 HSL(饱和度/亮度取的是 HSV 的 S 与 V);
//     · 色相 h' = fposmod(h + (H-4)*15, 360),八档**不对称**(−60°…+45°);
//     · 亮度/饱和度是**乘法** (k-4)*0.1 —— 暗部不会被压成纯黑,中性档 4 恰好是恒等元;
//     · alpha a' = a * (A/7),中性档在 **7**(不在 4)。
// ★ 纯逻辑 + 注入式画布:node 里能直接 require 进来断言(`node tint_smoke.js`)。
globalThis.Tint = (function () {
  'use strict';

  var Core = globalThis.Core;
  if (!Core) {
    throw new Error('tint.js: 必须先加载 core.js(本模块的档位常量全部取自 Core,不自己抄一份)');
  }

  // ── 档位含义表(规格 §2.3 的那张表,直接抄成按下标取的数组)──
  var LEVELS = 8;
  var HUE_OFFSET_DEG = [-60, -45, -30, -15, 0, 15, 30, 45];      // = (k - 4) * 15
  var MUL = [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3];             // = (k + 6) / 10
  var ALPHA_NUM = [0, 1, 2, 3, 4, 5, 6, 7];                       // a' = a * k / 7
  // ★ 中性档来自 Core,不写字面量 —— 这是"两边不许漂"的那一条。
  var NEUTRAL = {
    hue: Core.HUE_NEUTRAL, bri: Core.BRI_NEUTRAL,
    sat: Core.SAT_NEUTRAL, alpha: Core.ALPHA_NEUTRAL,
  };

  function hueOffsetOf(level) { return HUE_OFFSET_DEG[level & 7]; }
  function mulOf(level) { return MUL[level & 7]; }
  function alphaScaleOf(level) { return ALPHA_NUM[level & 7] / Core.ALPHA_NEUTRAL; }

  // ── HSV(标准定义,h ∈ [0,360),s/v ∈ [0,1])──
  // ★ 为什么不用 HSL:规格 §2.3 写死是 HSV,而这两个在同一个 (r,g,b) 上会给出**不同的**
  //   饱和度与亮度 —— 用错一个,"编辑器里调好的颜色进游戏就变样"。
  function fposmod(a, n) { var r = a % n; return r < 0 ? r + n : r; }

  function rgbToHsv(r, g, b) {
    var max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
    var h = 0;
    if (d !== 0) {
      if (max === r) h = 60 * fposmod((g - b) / d, 6);
      else if (max === g) h = 60 * ((b - r) / d + 2);
      else h = 60 * ((r - g) / d + 4);
    }
    return { h: fposmod(h, 360), s: max === 0 ? 0 : d / max, v: max };
  }

  function hsvToRgb(h, s, v) {
    h = fposmod(h, 360);
    var c = v * s;
    var x = c * (1 - Math.abs(fposmod(h / 60, 2) - 1));
    var m = v - c;
    var i = Math.floor(h / 60) % 6;
    var r1, g1, b1;
    if (i === 0) { r1 = c; g1 = x; b1 = 0; }
    else if (i === 1) { r1 = x; g1 = c; b1 = 0; }
    else if (i === 2) { r1 = 0; g1 = c; b1 = x; }
    else if (i === 3) { r1 = 0; g1 = x; b1 = c; }
    else if (i === 4) { r1 = x; g1 = 0; b1 = c; }
    else { r1 = c; g1 = 0; b1 = x; }
    return { r: r1 + m, g: g1 + m, b: b1 + m };
  }

  function clamp01(x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }

  // ★★ 规范定义(规格 §2.3),浮点进浮点出 —— **与游戏 shader 对齐的就是这一个**。
  //    任何 8 位取整都只是它的落地实现(tintBytes / buildTilePixels)。
  function tintRGBA(r, g, b, a, desc) {
    var hsv = rgbToHsv(r, g, b);
    var h2 = fposmod(hsv.h + hueOffsetOf(Core.hueOf(desc)), 360);
    var s2 = clamp01(hsv.s * mulOf(Core.satOf(desc)));
    var v2 = clamp01(hsv.v * mulOf(Core.brightOf(desc)));
    var rgb = hsvToRgb(h2, s2, v2);
    return { r: rgb.r, g: rgb.g, b: rgb.b, a: a * alphaScaleOf(Core.alphaOf(desc)) };
  }

  // 8 位通道的取整规则**只有这一处**:Math.round(clamp01(x) * 255)。
  function toByte(x) {
    var v = Math.round(clamp01(x) * 255);
    return v < 0 ? 0 : (v > 255 ? 255 : v);
  }
  function tintBytes(r, g, b, a, desc) {
    var o = tintRGBA(r / 255, g / 255, b / 255, a / 255, desc);
    return [toByte(o.r), toByte(o.g), toByte(o.b), toByte(o.a)];
  }

  // ── 贴图几何 ──
  // structure.png 是 320×320、每块 32×32、每行 10 块(游戏侧一致:两行各 10 块 + 第三行两块水)。
  // 象限由 core.js 的 subcellRender 给出(块内 8px 偏移),这里只负责"第 T 块在哪"。
  var BLOCK_PX = 32;
  var QUAD_PX = 32 / Core.SUB_PER_CELL;     // 8
  var TILE_PX = Core.SUB_PX;                // 16 = 象限 8px 放大 2×,正好一个子格

  function textureBlockRect(texture, atlasWidth) {
    var cols = Math.floor(atlasWidth / BLOCK_PX);
    var i = (texture | 0) - 1;
    if (cols <= 0 || i < 0) {
      throw new Error('textureBlockRect: 纹理号 ' + texture + ' 或图集宽度 ' + atlasWidth + ' 非法');
    }
    return { x: (i % cols) * BLOCK_PX, y: Math.floor(i / cols) * BLOCK_PX, w: BLOCK_PX, h: BLOCK_PX };
  }

  // 纯像素:从**图集**(整张 structure.png 的 RGBA)里取纹理 T 的第 (qx,qy) 个 8px 象限,
  // 按描述符 tint,再**最近邻**放大 2× 成 16×16。返回 Uint8ClampedArray(16*16*4)。
  // ★ 放大必须是最近邻(不是插值)—— 与项目其余的 texture_filter=nearest 口径一致。
  function buildTilePixels(atlas, atlasWidth, texture, qx, qy, desc) {
    if (Core.texOf(desc) === 0) {
      throw new Error('buildTilePixels: 空气格没有贴图(desc=0x' + (desc >>> 0).toString(16) + ')');
    }
    var rect = textureBlockRect(texture, atlasWidth);
    var srcX = rect.x + (qx % Core.SUB_PER_CELL) * QUAD_PX;
    var srcY = rect.y + (qy % Core.SUB_PER_CELL) * QUAD_PX;
    var rows = atlas.length / (atlasWidth * 4);
    if (srcX + QUAD_PX > atlasWidth || srcY + QUAD_PX > rows) {
      throw new Error('buildTilePixels: 图集里没有纹理 ' + texture + ' 的象限 (' + qx + ',' + qy +
                      ') —— 图集是 ' + atlasWidth + '×' + rows);
    }
    var scale = TILE_PX / QUAD_PX;
    var out = new Uint8ClampedArray(TILE_PX * TILE_PX * 4);
    for (var y = 0; y < QUAD_PX; y++) {
      for (var x = 0; x < QUAD_PX; x++) {
        var si = ((srcY + y) * atlasWidth + (srcX + x)) * 4;
        var p = tintBytes(atlas[si], atlas[si + 1], atlas[si + 2], atlas[si + 3], desc);
        for (var dy = 0; dy < scale; dy++) {
          for (var dx = 0; dx < scale; dx++) {
            var oi = ((y * scale + dy) * TILE_PX + (x * scale + dx)) * 4;
            out[oi] = p[0]; out[oi + 1] = p[1]; out[oi + 2] = p[2]; out[oi + 3] = p[3];
          }
        }
      }
    }
    return out;
  }

  // 缓存上限(Task 5 用):8192 × 16×16×4 字节 = 正好 8MB(规格 §4.3 闸 1)。
  var DEFAULT_MAX_TILES = 8192;

  return {
    LEVELS: LEVELS,
    HUE_OFFSET_DEG: HUE_OFFSET_DEG, MUL: MUL, ALPHA_NUM: ALPHA_NUM, NEUTRAL: NEUTRAL,
    hueOffsetOf: hueOffsetOf, mulOf: mulOf, alphaScaleOf: alphaScaleOf,
    fposmod: fposmod, rgbToHsv: rgbToHsv, hsvToRgb: hsvToRgb,
    tintRGBA: tintRGBA, tintBytes: tintBytes,
    BLOCK_PX: BLOCK_PX, QUAD_PX: QUAD_PX, TILE_PX: TILE_PX,
    textureBlockRect: textureBlockRect, buildTilePixels: buildTilePixels,
    DEFAULT_MAX_TILES: DEFAULT_MAX_TILES,
  };
})();
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node tint_smoke.js`

Expected: 全部 `ok -`,末行 `TINT SMOKE OK`,退出码 0。其中相位 ⑤ 会打印两条穷举断言的实测值(28561 组、误差数量级)。

- [ ] **Step 5: 提交**

```bash
git add level_editor/tint.js level_editor/tint_smoke.js
git commit -F - <<'EOF'
feat(editor): tint.js 辅码像素数学(规范定义 + 取角 + 16×16 小图)

规格 §2.3 的公式逐条落地:HSV(不是 HSL)、色相 fposmod(h+(H-4)*15,360)、
亮度与饱和度**乘法** (k-4)*0.1、alpha a*(A/7)。中性档全取自 Core 的常量 ——
tint.js 没有 Core 时当场抛错,不许自己抄一份(抄一份 = 两处会漂且不报错)。

golden 期望值全部手工从规格推导(+15°/-15°/-60°/+45° 色相、×0.8 亮度、
×0.6 饱和度、alpha 3/0),再加一条"中性描述符对 28561 组 8 位输入逐字节恒等"。
EOF
```

---

## Task 5: tinted-tile LRU 缓存(注入式 backend + 换图整片失效)

**Files:**
- Modify: `level_editor/tint.js`(加 `DEFAULT_BACKEND` / `createTileCache`)
- Modify: `level_editor/tint_smoke.js`(追加相位 ⑦)

**Interfaces:**
- Consumes: Task 4 的 `buildTilePixels` / `TILE_PX` / `DEFAULT_MAX_TILES`
- Produces(`globalThis.Tint` 追加):
  - `DEFAULT_BACKEND = { createTile(pixels:Uint8ClampedArray, size:Number) -> Object }`(浏览器里造 `document.createElement('canvas')`;node 里调用会抛错)
  - `createTileCache(opts) -> {setSource(data, width), get(texture, qx, qy, desc), has(texture, qx, qy, desc), clear(), stats(), tileKey(texture, qx, qy, desc)}`
    - `opts = {maxSize?:Number(默认 8192), backend?:Object(默认 DEFAULT_BACKEND)}`
    - `get` 命中返回同一个对象;未命中时调 `backend.createTile(buildTilePixels(...), 16)`
    - `stats() -> {hits, misses, evictions, size, maxSize}` —— **键序固定**,测试逐字比对
    - `maxSize === 0` = 不缓存(每次现造,`size` 恒 0)

- [ ] **Step 1: 在 `tint_smoke.js` 的 `// ==== 断言区结束 ====` 之前追加相位 ⑦**

```js
  // ==== 相位 ⑦ tinted-tile 缓存(规格 §4.2 ④ / §4.3 闸 1)====
  (function () {
    // 注入式 backend:node 里没有 canvas,缓存把"画出来的像素"交给 backend ——
    // 我们记录它收到了什么,于是能断言"缓存给出去的像素 = 直算的像素"。
    const made = [];
    const backend = {
      createTile: function (pixels, size) {
        made.push({ pixels: pixels, size: size });
        return { fake: true, pixels: pixels, size: size };
      },
    };
    const atlas = makeAtlas();
    const N1 = Core.neutralDesc(1), N2 = Core.neutralDesc(2), N3 = Core.neutralDesc(3), N4 = Core.neutralDesc(4);

    // 没 setSource 就 get → 抛错(而不是画出一块空白)
    const bare = Tint.createTileCache({ backend: backend });
    throws(function () { bare.get(1, 0, 0, N1); }, 'createTileCache: 没 setSource 就 get → 抛错', 'setSource');

    const cache = Tint.createTileCache({ maxSize: 3, backend: backend });
    cache.setSource(atlas, ATLAS_W);
    const a = cache.get(3, 2, 1, Core.neutralDesc(3));
    eq(made.length, 1, '未命中才会让 backend 造图');
    ok(a && a.fake === true, 'get 返回的正是 backend 造出来的那个对象');
    sameBytes(made[0].pixels,
              Tint.buildTilePixels(atlas, ATLAS_W, 3, 2, 1, Core.neutralDesc(3)),
              '★ 缓存交给 backend 的像素与直接算的逐字节一致(缓存没有改坏像素)');
    eq(made[0].size, Tint.TILE_PX, 'backend 收到的尺寸是 16');
    ok(a === cache.get(3, 2, 1, Core.neutralDesc(3)), '相同键第二次命中同一个对象');
    eq(made.length, 1, '命中不再造图');
    eq(cache.stats(), { hits: 1, misses: 1, evictions: 0, size: 1, maxSize: 3 }, 'stats 记账(hits/misses/evictions/size)');
    ok(cache.has(3, 2, 1, Core.neutralDesc(3)), 'has: 命中');
    ok(!cache.has(3, 2, 1, Core.packDesc(3, 5, 4, 4, 7)),
       '★ 描述符不同 = 不同键(同一象限的不同辅码各存一份)');
    ok(!cache.has(2, 2, 1, Core.neutralDesc(3)), '★ 纹理不同 = 不同键');
    ok(!cache.has(3, 1, 1, Core.neutralDesc(3)), '★ 象限不同 = 不同键');

    // LRU:maxSize 3,塞第 4 个 → 最久未用的那个被淘汰
    cache.clear();
    cache.get(1, 0, 0, N1);            // A
    cache.get(2, 0, 0, N2);            // B
    cache.get(3, 0, 0, N3);            // C
    cache.get(1, 0, 1, N1);            // D → A 最久未用,被淘汰
    ok(!cache.has(1, 0, 0, N1), '★ LRU: 塞第 4 个时最久未用的那个被淘汰');
    ok(cache.has(2, 0, 0, N2) && cache.has(3, 0, 0, N3) && cache.has(1, 0, 1, N1), 'LRU: 其余三个还在');
    eq(cache.stats().size, 3, 'LRU: 容量守住 maxSize');
    ok(cache.stats().evictions >= 1, 'LRU: 淘汰计数被记上');
    cache.get(2, 0, 0, N2);            // 命中 → B 提到最近端
    cache.get(4, 0, 0, N4);            // E → 淘汰此时最久未用的 C
    ok(cache.has(2, 0, 0, N2), '★ LRU: 命中过的条目被提到最近端(没被淘汰)');
    ok(!cache.has(3, 0, 0, N3), '★ LRU: 被淘汰的是最久未用的那个');

    // ★★ 换图必须整片失效 —— 审计 A2 的原样翻版:
    //    旧编辑器在 structure.png 加载完成前写进纯色兜底且**永不失效**,
    //    于是地图一直是色块,还"有时好有时坏"。
    const beforeStats = cache.stats();
    cache.setSource(atlas, ATLAS_W);
    eq(cache.stats().size, 0, '★★ setSource 清空缓存(资源换了 = 缓存全废,不许留旧的色块)');
    ok(!cache.has(3, 0, 0, N3), 'setSource 之后旧条目查不到');
    ok(cache.stats().hits === beforeStats.hits && cache.stats().misses === beforeStats.misses,
       'setSource 不重置记账(hits/misses 是累计量)');
    const m0 = made.length;
    cache.get(3, 0, 0, N3);
    eq(made.length - m0, 1, 'setSource 之后同一个键会重新造(确实失效了,不是"命中旧图")');

    // maxSize 0 = 不缓存
    const nocache = Tint.createTileCache({ maxSize: 0, backend: backend });
    nocache.setSource(atlas, ATLAS_W);
    const m1 = made.length;
    nocache.get(1, 0, 0, N1);
    nocache.get(1, 0, 0, N1);
    eq(made.length - m1, 2, 'maxSize 0 → 每次都现造(不缓存)');
    eq(nocache.stats().size, 0, 'maxSize 0 → size 恒 0');
    eq(Tint.createTileCache({ backend: backend }).stats().maxSize, Tint.DEFAULT_MAX_TILES,
       '默认 maxSize = DEFAULT_MAX_TILES');

    // ★ 浏览器默认后端在 node 里必须**明确报错**,而不是悄悄画不出来
    throws(function () { Tint.DEFAULT_BACKEND.createTile(new Uint8ClampedArray(4), 1); },
           '★ DEFAULT_BACKEND 在 node(没有 document)里明确抛错', 'document');
  })();
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node tint_smoke.js`

Expected: 进程在 `const cache = Tint.createTileCache({ maxSize: 3, backend: backend });` 那一行被外层 catch 抓住,末行打印:

```
FAIL: 未捕获异常(后面的断言一行都没跑):
TypeError: Tint.createTileCache is not a function
```

退出码 1。

(★ 顺带一个值得记的现场:它上面那句 `throws(function () { bare.get(1, 0, 0, N1); }, …, 'setSource')` 此时**反而是绿的** —— `Tint.createTileCache` 不存在,`bare` 是 `undefined`,`bare.get` 抛的 `TypeError` 被 `throws` 当成了"抛错了"。这正是"只判有没有抛 = 假绿"的实物;`expectSub` 就是为它准备的,等第 3 步实现落地后那条断言才是真的。)

- [ ] **Step 3: 实现 `createTileCache`**

在 `tint.js` 的 `buildTilePixels` **之后**、`var DEFAULT_MAX_TILES = 8192;` **之前**插入:

```js
  // ── tinted-tile 缓存(规格 §4.2 ④)──
  // 键 = (纹理, 象限, 描述符) → 一张 16×16 小图。贴图源只有 32×32,一块小图 256 像素,
  // 手算极便宜 —— 但同一块会被画成千上万次,故必须缓存。
  // ★ 画布是**注入**的:node 里没有 document,缓存把"画出来的像素"交给 backend,
  //   于是缓存的键/淘汰/失效逻辑在 node 里可以完整断言。
  var DEFAULT_BACKEND = {
    createTile: function (pixels, size) {
      if (typeof document === 'undefined') {
        throw new Error('Tint: 本环境没有 document,请给 createTileCache 传 backend(node 测试用)');
      }
      var c = document.createElement('canvas');
      c.width = size;
      c.height = size;
      var ctx = c.getContext('2d');
      ctx.imageSmoothingEnabled = false;       // 最近邻,与项目其余部分一致
      ctx.putImageData(new ImageData(pixels, size, size), 0, 0);
      return c;
    },
  };

  function createTileCache(opts) {
    opts = opts || {};
    var maxSize = opts.maxSize === undefined ? DEFAULT_MAX_TILES : opts.maxSize;
    var backend = opts.backend || DEFAULT_BACKEND;
    // ★ Map 的**插入序就是 LRU 序**:命中时 delete + set 把条目提到末尾,
    //   淘汰时取 keys().next().value(最老的那个)。
    var tiles = new Map();
    var atlas = null, atlasWidth = 0;
    var hits = 0, misses = 0, evictions = 0;

    // ★★ 换图**必须**整片失效(审计 A2):旧编辑器在 structure.png 加载完成前写进
    //    纯色兜底、且永不失效 —— 于是地图一直是色块,而且"有时好有时坏"。
    //    资源换了就是换了,没有"部分还新鲜"这回事。
    function setSource(data, width) {
      atlas = data;
      atlasWidth = width | 0;
      tiles.clear();
    }
    function tileKey(texture, qx, qy, desc) {
      return texture + '/' + (qx & 3) + '/' + (qy & 3) + '/' + (desc >>> 0);
    }
    function get(texture, qx, qy, desc) {
      var k = tileKey(texture, qx, qy, desc);
      var hit = tiles.get(k);
      if (hit !== undefined) {
        hits++;
        tiles.delete(k);
        tiles.set(k, hit);                     // 提到最近使用端
        return hit;
      }
      misses++;
      if (!atlas) throw new Error('Tint: 还没 setSource,拿不到贴图(别在图片加载完成前画)');
      var tile = backend.createTile(buildTilePixels(atlas, atlasWidth, texture, qx, qy, desc), TILE_PX);
      if (maxSize > 0) {
        tiles.set(k, tile);
        while (tiles.size > maxSize) {
          tiles.delete(tiles.keys().next().value);
          evictions++;
        }
      }
      return tile;
    }
    function has(texture, qx, qy, desc) { return tiles.has(tileKey(texture, qx, qy, desc)); }
    function clear() { tiles.clear(); }
    function stats() {
      return { hits: hits, misses: misses, evictions: evictions, size: tiles.size, maxSize: maxSize };
    }
    return { setSource: setSource, get: get, has: has, clear: clear, stats: stats,
             tileKey: tileKey };
  }
```

导出表追加(在 `DEFAULT_MAX_TILES: DEFAULT_MAX_TILES,` 之后):

```js
    DEFAULT_BACKEND: DEFAULT_BACKEND, createTileCache: createTileCache,
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node tint_smoke.js`

Expected: 全部 `ok -`,末行 `TINT SMOKE OK`,退出码 0。

- [ ] **Step 5: 提交**

```bash
git add level_editor/tint.js level_editor/tint_smoke.js
git commit -F - <<'EOF'
feat(editor): tinted-tile LRU 缓存(注入式画布 + 换图整片失效)

键 =(纹理, 象限, 描述符),上限 8192 张(正好 8MB,规格 §4.3 闸 1);
LRU 用 Map 的插入序,命中时 delete+set 提最近端。画布走注入的 backend,
于是 node 里能断言"缓存交给 backend 的像素 == 直算的像素"与淘汰次序。

setSource 一律清空缓存 —— 审计 A2 的原样翻版(旧编辑器在贴图加载完成前
写进纯色兜底且永不失效,地图一直是色块还"有时好有时坏")。
EOF
```

---

## Task 6: `editor.html` 骨架页(库列表 / 辅码实验室 / 编解码往返)

**Files:**
- Modify: `level_editor/editor.html`(整体重写 —— 替换 Task 1 的占位页)
- Modify: `level_editor/server_smoke.js`(追加相位 ⑧)

**Interfaces:**
- Consumes: `editor_server.js` 的三个接口(`/api/maps`、`/api/map`)、`core.js`(`Core.*`)、`tint.js`(`Tint.createTileCache` / `Tint.TILE_PX`)、`structure.png`(经 `/structure.png` 取)
- Produces: 入口页 `editor.html` —— 三条自检:① 库列表(服务器连通)② 辅码实验室(浏览器里的 tint 像素)③ 编解码往返(浏览器里的 `CompressionStream`)。**计划 2b 会替换本页 body,但保留 `<script src>` 这两行与"用 Core/Tint、不自己写第二份数学"这条纪律。**

- [ ] **Step 1: 在 `server_smoke.js` 的 `// ==== 断言区结束 ====` 之前追加相位 ⑧**

```js
  // ==== 相位 ⑧ 骨架页结构(真的从服务器取,不是读盘)====
  {
    const page = (await request(staticSrv.port, 'GET', '/')).body.toString('utf8');
    ok(/<script src="core\.js"><\/script>/.test(page), '骨架页加载 core.js');
    ok(/<script src="tint\.js"><\/script>/.test(page), '骨架页加载 tint.js');
    (function () {
      const srcs = [];
      const re = /<script[^>]*\bsrc="([^"]+)"/g;
      let m;
      while ((m = re.exec(page)) !== null) srcs.push(m[1]);
      ok(srcs.length >= 2, '骨架页有 ' + srcs.length + ' 个外部脚本');
      const missing = [];
      srcs.forEach(function (s) {
        if (s.indexOf('://') >= 0) { missing.push(s + '(外部 URL —— 编辑器只走本机 HTTP)'); return; }
        if (!fs.existsSync(path.join(__dirname, s))) missing.push(s);
      });
      ok(missing.length === 0, '★ 骨架页引用的每个脚本文件都存在(否则运行时 404):' +
         (missing.length ? missing.join(', ') : '全部命中'));
    })();
    ok(page.indexOf('file://') < 0, '★ 骨架页里没有 file://(规格 §1.2:只走 HTTP)');
    for (const id of ['maps', 'tintlab', 'roundtrip']) {
      ok(page.indexOf('id="' + id + '"') >= 0, '骨架页有 id="' + id + '" 区块');
    }
    ok(page.indexOf('id="btn-maps"') >= 0 && page.indexOf('id="btn-rt"') >= 0,
       '骨架页有两个自检按钮(库刷新 / 往返)');
    ok(page.indexOf('Tint.') >= 0, '★ 骨架页用 Tint.*');
    ok(page.indexOf('Core.') >= 0, '骨架页用 Core.*');
    ok(page.indexOf('createTileCache') >= 0, '★ 骨架页用 Tint.createTileCache(小图走缓存,不自己造 canvas)');
    ok(page.indexOf('rgbToHsv') < 0 && page.indexOf('hsvToRgb') < 0,
       '★ 骨架页里没有第二份 HSV 数学(必须调 Tint —— 两份实现迟早漂,而漂了不报错)');
    ok(page.indexOf('Core.lineCells') < 0,
       '★ 骨架页不调 Core.lineCells:它的坐标必须是整数,非整数/NaN 会让它死循环挂住标签页' +
       '(账本 Task 2 Minor 3 —— 2b 加绘制工具时每个调用点都要先 Math.floor)');
    ok(page.indexOf('__ENEMY_REGISTRY_BEGIN__') < 0,
       '★ 敌人注册表标记仍留在 structure-editor.html(本计划不搬:搬标记、改 sync-enemies.js 的 htmlPath、' +
       '删旧文件三件事必须同一 commit,那是 2b 的收尾动作)');
  }
```

- [ ] **Step 2: 运行,确认失败**

Run: `cd level_editor && node server_smoke.js`

Expected: 相位 ⑧ 头两条即红 —— `FAIL - 骨架页加载 core.js`(占位页里那行是 `<script src="core.js"></script>`,能过)之后 `FAIL - 骨架页加载 tint.js`、`FAIL - 骨架页有 id="maps" 区块` 等一批,退出码 1。

- [ ] **Step 3: 重写 `editor.html`**

把 `level_editor/editor.html` **整体替换**为:

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>The Cyancular Ruins — 关卡编辑器(骨架)</title>
<style>
:root { --bg:#17191d; --panel:#1f2329; --panel2:#262b32; --border:#343b45;
        --text:#d7dde5; --dim:#8b94a1; --accent:#54a0ff; --warn:#e0b34a; }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text); font-size:14px;
       font-family:"Segoe UI","Microsoft YaHei",system-ui,sans-serif; }
header { padding:10px 16px; background:var(--panel); border-bottom:1px solid var(--border); }
header h1 { font-size:16px; margin:0 0 4px; }
header div { color:var(--dim); }
main { display:flex; gap:12px; padding:12px; align-items:flex-start; flex-wrap:wrap; }
section { background:var(--panel); border:1px solid var(--border); border-radius:6px;
          padding:12px; min-width:280px; max-width:420px; }
section h2 { font-size:14px; margin:0 0 8px; color:var(--accent); }
button { background:var(--panel2); color:var(--text); border:1px solid var(--border);
         border-radius:4px; padding:6px 10px; font-size:13px; cursor:pointer; }
button:hover { border-color:var(--accent); }
input[type=range] { width:130px; vertical-align:middle; }
input[type=number] { width:64px; background:var(--panel2); color:var(--text);
                     border:1px solid var(--border); border-radius:4px; padding:3px 6px; }
ul { margin:6px 0 0; padding-left:18px; color:var(--dim); }
pre { white-space:pre-wrap; margin:8px 0 0; color:var(--dim);
      font-family:Consolas,"Courier New",monospace; font-size:12px; }
.row { display:flex; gap:6px; align-items:center; margin-bottom:6px; }
.row span { color:var(--dim); width:2.5em; text-align:right; }
.swatches { display:flex; flex-wrap:wrap; gap:6px; margin-top:8px; }
.sw { text-align:center; }
.sw canvas { width:48px; height:48px; image-rendering:pixelated;
             border:1px solid var(--border); background:#000; display:block; }
.sw small { color:var(--dim); font-size:11px; }
</style>
</head>
<body>
<header>
  <h1>The Cyancular Ruins — 关卡编辑器(计划 2a 骨架)</h1>
  <div>本页是脚手架:服务器 / 编解码 / 辅码三条自检。真正的界面(渲染、工具栏、图层、持久化)在计划 2b。</div>
</header>
<main>
  <section id="maps">
    <h2>① 库(maps/*.cyrm)</h2>
    <div class="row"><button id="btn-maps">刷新列表</button></div>
    <ul id="maplist"><li>未加载</li></ul>
  </section>

  <section id="tintlab">
    <h2>② 辅码实验室</h2>
    <div class="row">纹理 <input id="tex" type="number" min="1" max="4095" value="1"></div>
    <div class="row">色相 <input id="hue" type="range" min="0" max="7" value="4"><span id="huev">4</span></div>
    <div class="row">亮度 <input id="bri" type="range" min="0" max="7" value="4"><span id="briv">4</span></div>
    <div class="row">饱和 <input id="sat" type="range" min="0" max="7" value="4"><span id="satv">4</span></div>
    <div class="row">透明 <input id="alp" type="range" min="0" max="7" value="7"><span id="alpv">7</span></div>
    <div class="swatches" id="swatches"></div>
    <pre id="tintinfo">正在读取 structure.png …</pre>
  </section>

  <section id="roundtrip">
    <h2>③ 编解码往返</h2>
    <div class="row">
      <select id="rtname"></select>
      <button id="btn-rt">拉取并往返</button>
    </div>
    <pre id="rtlog">未运行</pre>
  </section>
</main>

<script src="core.js"></script>
<script src="tint.js"></script>
<script>
'use strict';
// 计划 2a 的骨架页。★ 页面里**不写第二份数学**:所有像素都走 Tint.*,所有编解码都走 Core.*。
const $ = function (id) { return document.getElementById(id); };

// ── ① 库:从本地服务器列 maps/*.cyrm ──
function refreshMaps() {
  const ul = $('maplist');
  ul.textContent = '加载中 …';
  fetch('/api/maps').then(function (r) {
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return r.json();
  }).then(function (data) {
    ul.innerHTML = '';
    const sel = $('rtname');
    sel.innerHTML = '';
    if (!data.maps.length) { ul.textContent = 'maps/ 下没有 .cyrm'; return; }
    data.maps.forEach(function (m) {
      const li = document.createElement('li');
      li.textContent = m.name + ' — ' + m.size + ' 字节 — ' + new Date(m.mtime).toLocaleString();
      ul.appendChild(li);
      const op = document.createElement('option');
      op.value = m.name;
      op.textContent = m.name;
      sel.appendChild(op);
    });
  }).catch(function (e) { ul.textContent = '拉取失败:' + e.message; });
}
$('btn-maps').addEventListener('click', refreshMaps);

// ── ② 辅码实验室:16 个象限 × 当前描述符,全部走 tint.js 的缓存 ──
let atlas = null, atlasW = 0;
const tiles = Tint.createTileCache();
const img = new Image();
img.onload = function () {
  const c = document.createElement('canvas');
  c.width = img.width; c.height = img.height;
  const ctx = c.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(img, 0, 0);
  const d = ctx.getImageData(0, 0, img.width, img.height);
  atlas = d.data;
  atlasW = img.width;
  tiles.setSource(atlas, atlasW);        // ★ 资源换了 = 缓存整片失效(审计 A2)
  drawSwatches();
};
img.onerror = function () { $('tintinfo').textContent = 'structure.png 加载失败'; };
img.src = 'structure.png';

function drawSwatches() {
  const hue = +$('hue').value, bri = +$('bri').value, sat = +$('sat').value, alp = +$('alp').value;
  $('huev').textContent = hue; $('briv').textContent = bri;
  $('satv').textContent = sat; $('alpv').textContent = alp;
  if (!atlas) { $('tintinfo').textContent = 'structure.png 还没加载完'; return; }
  const tex = Math.max(1, Math.min(4095, parseInt($('tex').value, 10) || 1));
  const desc = Core.packDesc(tex, hue, bri, sat, alp);
  const box = $('swatches');
  box.innerHTML = '';
  for (let qy = 0; qy < Core.SUB_PER_CELL; qy++) {
    for (let qx = 0; qx < Core.SUB_PER_CELL; qx++) {
      const wrap = document.createElement('div');
      wrap.className = 'sw';
      wrap.appendChild(tiles.get(tex, qx, qy, desc));
      const lab = document.createElement('small');
      lab.textContent = qx + ',' + qy;
      wrap.appendChild(lab);
      box.appendChild(wrap);
    }
  }
  const st = tiles.stats();
  $('tintinfo').textContent = '纹理 ' + tex + ' · 描述符 0x' + desc.toString(16) +
    ' · 缓存:命中 ' + st.hits + ' / 未命中 ' + st.misses + ' / 淘汰 ' + st.evictions + ' / 在册 ' + st.size;
}
['tex', 'hue', 'bri', 'sat', 'alp'].forEach(function (id) {
  $(id).addEventListener('input', drawSwatches);
});

// ── ③ 编解码往返:拉真地图 → decode → encode(压缩/裸)→ 再 decode,逐层比对 ──
$('btn-rt').addEventListener('click', function () {
  const name = $('rtname').value;
  const log = $('rtlog');
  if (!name) { log.textContent = '先选一张地图'; return; }
  log.textContent = '拉取 ' + name + ' …';
  const t0 = performance.now();
  fetch('/api/map?p=' + encodeURIComponent(name))
    .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.arrayBuffer(); })
    .then(function (buf) { return Core.decodeMap(new Uint8Array(buf)); })
    .then(function (map) {
      // ★ v4 的 body 里没有 name 字段(decodeMap 返回 name:'')——
      //   导入方必须自己用文件名补上,否则 sanitizeName 会回落成 'structure'。
      map.name = name.replace(/\.cyrm$/, '');
      const report = Core.validateMap(map);
      return Core.encodeMap(map).then(function (packed) {
        return Core.encodeMap(map, { compress: false }).then(function (raw) {
          return Core.decodeMap(packed).then(function (back) {
            const same = back.layers.every(function (L, i) {
              const a = map.layers[i];
              if (!L || !a) return L === a;
              const x = L.kind === 'tex' ? L.desc : L.rgba;
              const y = a.kind === 'tex' ? a.desc : a.rgba;
              if (x.length !== y.length) return false;
              for (let k = 0; k < x.length; k++) if (x[k] !== y[k]) return false;
              return true;
            });
            const lines = [
              name + '  ' + map.subCols + '×' + map.subRows + ' 子格(' +
                Core.cellsWOf(map) + '×' + Core.cellsHOf(map) + ' 格)',
              '压缩后 ' + packed.length + ' 字节 / 裸 ' + raw.length + ' 字节(≈' +
                (raw.length / Math.max(1, packed.length)).toFixed(1) + ':1)',
              '往返一致:' + same + ' · 出生点 ' + map.players.length + ' · 敌人 ' +
                map.enemies.length + ' · 注释 ' + map.comments.length,
              '校验:error ' + report.errors.length + ' / warning ' + report.warnings.length,
              '耗时 ' + Math.round(performance.now() - t0) + 'ms',
            ].concat(report.warnings.map(function (w) { return '  ⚠ ' + w; }));
            log.textContent = lines.join('\n');
          });
        });
      });
    })
    .catch(function (e) { log.textContent = '失败:' + e.message; });
});

refreshMaps();
</script>
</body>
</html>
```

- [ ] **Step 4: 运行,确认通过**

Run: `cd level_editor && node server_smoke.js`

Expected: 全部 `ok -`,末行 `SERVER SMOKE OK`,退出码 0。

- [ ] **Step 5: 人眼验收(浏览器里的那两件事,node 验不了)**

**测试由用户自己跑。** 这一步 node 只能验结构,真正的渲染与 `CompressionStream` 要浏览器:

1. 双击 `level_editor/serve.bat`(或跑 `node level_editor/editor_server.js`)。
2. 浏览器自动打开 `http://127.0.0.1:8777/`,确认:
   - ① 列出了 `demo.cyrm` 与 `factory1v1.cyrm`(带字节数与时间);
   - ② 拖动四个滑块,16 张小图**立刻**跟着变色,且色相/亮度/饱和/透明四个方向各自可辨;
     底部那行"缓存:命中 N / 未命中 M"在反复拨动后**命中数持续增长**(说明缓存真的在起作用);
   - ③ 选 `demo.cyrm` 点「拉取并往返」,打印出的 `往返一致:` 必须是 **true**。
3. 若 ② 是一片全黑:多半是 `structure.png` 没加载成功(看那行提示)。

- [ ] **Step 6: 提交**

```bash
git add level_editor/editor.html level_editor/server_smoke.js
git commit -F - <<'EOF'
feat(editor): 骨架页 —— 库列表 / 辅码实验室 / 编解码往返

入口页从占位换成三条真自检:① 从 /api/maps 列地图 ② 用 tint.js 的缓存
画 16 个象限(拨档位立刻变色,并显示缓存命中数)③ 拉一张真 .cyrm,
decode → encode(压缩/裸)→ 再 decode 逐层比对 —— 这是浏览器侧唯一能验
CompressionStream 的地方。

页面里不写第二份数学(结构断言钉住:没有 rgbToHsv/hsvToRgb、不自己造 canvas),
也不调 Core.lineCells(它的坐标必须整数;2b 加绘制工具时每个调用点都要 Math.floor)。
EOF
```

---

## Task 7: 端到端(`core.js` ↔ 服务器)与收尾

**Files:**
- Modify: `level_editor/server_smoke.js`(追加相位 ⑨)

**Interfaces:**
- Consumes: `require('./core.js')` 得到的 `globalThis.Core`、Task 1–3 的服务器接口
- Produces: 无新导出 —— 本 Task 的交付物是"两半真的对得上"的证据,以及给计划 2b 的交接清单

- [ ] **Step 1: 在 `server_smoke.js` 的 `// ==== 断言区结束 ====` 之前追加相位 ⑨**

```js
  // ==== 相位 ⑨ 端到端:core.js 编出来的字节 → 服务器 → core.js 解回来 ====
  {
    require('./core.js');
    const Core = globalThis.Core;
    const mapsDir = path.join(tmpRoot, 'maps');
    const apiSrv = track(await srv.startServer({ rootDir: __dirname, mapsDir: mapsDir, port: 0 }));

    const m = Core.createMap('e2e', 12, 9);
    const brick = Core.neutralDesc(1);
    const moss = Core.packDesc(15, 5, 3, 6, 7);
    for (let i = 0; i < m.layers[Core.LAYER_SCENE].desc.length; i++) {
      m.layers[Core.LAYER_SCENE].desc[i] = (i % m.subCols < 8) ? brick : 0;
    }
    for (let i = 0; i < m.layers[Core.LAYER_FRONT].desc.length; i += 13) m.layers[Core.LAYER_FRONT].desc[i] = moss;
    for (let i = 0; i < m.layers[Core.LAYER_BG].rgba.length; i++) {
      m.layers[Core.LAYER_BG].rgba[i] = ((i % 256) * 0x010101) >>> 0;
    }
    m.comments = ['e2e 冒烟', '第二行注释'];
    m.players = [{ x: 10, y: 1 }, { x: 10, y: 7 }];
    m.enemies = [{ type: 'fly_bird', x: 3, y: 4 }];

    const bytes = await Core.encodeMap(m);
    const putE2E = await request(apiSrv.port, 'PUT', '/api/map?p=e2e.cyrm', Buffer.from(bytes));
    ok(putE2E.status === 200, '端到端: PUT encodeMap 的产物 → 200');
    eq(JSON.parse(putE2E.body.toString('utf8')).size, bytes.length, '端到端: 服务器记的 size = 字节数');

    const got = await request(apiSrv.port, 'GET', '/api/map?p=e2e.cyrm');
    sameBytes(got.body, bytes, '★ 端到端: 服务器上存着的就是 encodeMap 产出的那串字节');
    sameBytes(got.body.subarray(0, 4), Buffer.from([0x43, 0x59, 0x52, 0x4D]),
              '★ 端到端: 落盘的文件 magic 仍是 "CYRM"(服务器没动过内容)');

    const back = await Core.decodeMap(new Uint8Array(got.body));
    eq(back.subCols, m.subCols, '端到端: subCols 往返');
    eq(back.subRows, m.subRows, '端到端: subRows 往返');
    for (let L = 0; L < 4; L++) {
      const key = L === Core.LAYER_BG ? 'rgba' : 'desc';
      sameBytes(back.layers[L][key], m.layers[L][key], '端到端: 图层 ' + L + ' 往返一致');
    }
    eq(back.players, m.players, '端到端: players 往返');
    eq(back.enemies, m.enemies, '端到端: enemies 往返');
    eq(back.comments, m.comments, '端到端: comments 往返');

    // ★ 账本 Task 7 Minor 4:v4 的 body 里没有 name 字段 —— 导入方必须自己用文件名补。
    eq(back.name, '', '★ decodeMap 返回的 name 是空串(v4 body 无 name 字段)');
    back.name = 'e2e';
    eq(Core.sanitizeName(back.name), 'e2e', '★ 用文件名补 map.name 之后 sanitizeName 不回落成 structure');
    eq(Core.sanitizeName(''), 'structure', '(对照)空名字才会回落成 structure');

    // 裸 body(compression=0)是一条完整可用的退路,也要能过服务器
    const raw = await Core.encodeMap(m, { compress: false });
    const putRaw = await request(apiSrv.port, 'PUT', '/api/map?p=e2e_raw.cyrm', Buffer.from(raw));
    ok(putRaw.status === 200, '端到端: 裸 body(compression=0)PUT → 200');
    const gotRaw = await request(apiSrv.port, 'GET', '/api/map?p=e2e_raw.cyrm');
    eq(gotRaw.body[5], 0, '端到端: 裸文件的 compression 字节是 0');
    const backRaw = await Core.decodeMap(new Uint8Array(gotRaw.body));
    sameBytes(backRaw.layers[Core.LAYER_SCENE].desc, m.layers[Core.LAYER_SCENE].desc,
              '端到端: 裸 body 路径往返一致');

    // 库列表里现在应该有这三张(e2e / e2e_raw / 之前相位留下的)
    const list = JSON.parse((await request(apiSrv.port, 'GET', '/api/maps')).body.toString('utf8'));
    const names = list.maps.map(function (x) { return x.name; });
    ok(names.indexOf('e2e.cyrm') >= 0 && names.indexOf('e2e_raw.cyrm') >= 0,
       '端到端: /api/maps 列出了刚写进去的两张(' + names.join(', ') + ')');

    // ★ 全流程之后 maps/ 里不许有临时文件残留
    ok(fs.readdirSync(mapsDir).every(function (n) { return n.indexOf('.tmp') < 0; }),
       '★ 端到端跑完之后 maps/ 里没有临时文件残留');
  }
```

- [ ] **Step 2: 运行,看它是不是真的绿**

Run: `cd level_editor && node server_smoke.js`

Expected: 全部 `ok -`,末行 `SERVER SMOKE OK`,退出码 0。

相位 ⑨ 是**纯增量覆盖**:它消费的接口全在前面三个 Task 里实现完了,所以它应该**一上来就全绿**。若它报红,说明前面某个 Task 的实现有问题 —— 回到那个 Task 修,不要在这里绕过。

- [ ] **Step 3: 变异验证(证明相位 ⑨ 不是空转)**

"一写就绿"的测试有可能是空转的。花两分钟证明它真的抓得住东西:

把 `editor_server.js` 的 `writeMapAtomic` 里这一行:

```js
    fs.renameSync(tmp, target);
```

临时改成:

```js
    fs.renameSync(tmp, target + '.bak');
```

再跑 `node server_smoke.js`,Expected:

```
  FAIL - ★ 端到端: 服务器上存着的就是 encodeMap 产出的那串字节 (长度 0 ≠ 期望 …)
```

(以及随后的 GET 404 引起的连带失败),退出码 1。**确认之后把那一行改回来**,再跑一次确认恢复全绿。

★ 这条变异的含义:它模拟的正是"**写成功了、但写到了别处**"这类最难发现的 bug ——
只断言 `PUT → 200` 的话它完全抓不住(200 照常返回),要靠 `GET` 回来的**字节**比对才抓得住。

- [ ] **Step 4: 跑齐三套,确认全绿**

Run:
```bash
cd level_editor && node smoke.js && node tint_smoke.js && node server_smoke.js
```
Expected:
- `smoke.js` → `结果: 343 通过, 0 失败` + `SMOKE OK`(计划 1 的覆盖一条没少)
- `tint_smoke.js` → `TINT SMOKE OK`
- `server_smoke.js` → `SERVER SMOKE OK`
- 退出码 0

- [ ] **Step 5: 提交**

```bash
git add level_editor/server_smoke.js
git commit -F - <<'EOF'
test(editor): 端到端 —— core.js 与本地服务器对得上

encodeMap 的字节 PUT 上去、GET 回来逐字节相同,decodeMap 解回来的四层
/出生点/敌人/注释全一致;裸 body(compression=0)那条退路同样走一遍。

顺带钉住账本 Task 7 Minor 4:v4 body 里没有 name 字段(decodeMap 返回 ''),
导入方必须自己用文件名补 map.name,否则 sanitizeName 回落成 'structure'。
EOF
```

---

## 收尾

- [ ] **跑齐三套冒烟确认全绿**

Run: `cd level_editor && node smoke.js && node tint_smoke.js && node server_smoke.js`

Expected: `SMOKE OK` / `TINT SMOKE OK` / `SERVER SMOKE OK`,退出码 0。

- [ ] **确认计划 1 的覆盖一点没少,而且 `core.js` 一个字节没动**

Run: `git diff --stat <计划 1 结束时的 commit> -- level_editor/core.js level_editor/smoke.js`

Expected: 输出为空(这两个文件在本计划里**未被修改**)。

- [ ] **确认集成约束仍成立**

Run: `node level_editor/sync-enemies.js --check && node level_editor/sync-tiles.js --check`

Expected: 两条都打印 `ok: …`,退出码 0。(server_smoke 相位 ①b 也跑前者,这里是给人眼看的双保险。)

- [ ] **交接给计划 2b**

本计划交付后,以下符号已经定型,2b 直接引用:

```
node:      editor_server.js  → createServer / startServer / isValidMapName / listMaps / mapPathFor
           serve.bat(双击即起服务器并开浏览器)
浏览器:    editor.html(入口页;2b 替换 body,保留两条 <script src>)
           /api/maps → {maps:[{name,size,mtime}]}
           /api/map?p=<name>  GET → 原始字节;PUT(原子写,请求体 ≤ 64MB)
tint.js:   Tint.createTileCache({maxSize?, backend?}) → {setSource, get, has, clear, stats, tileKey}
           Tint.buildTilePixels(atlas, atlasWidth, texture, qx, qy, desc) → Uint8ClampedArray(16×16×4)
           Tint.textureBlockRect(texture, atlasWidth) → {x,y,w,h}
           Tint.tintBytes / tintRGBA / rgbToHsv / hsvToRgb / hueOffsetOf / mulOf / alphaScaleOf
           几何常量:  Tint.BLOCK_PX=32 / Tint.QUAD_PX=8 / Tint.TILE_PX=16 / Tint.DEFAULT_MAX_TILES=8192
```

**★ 2b 必须遵守的七条**(按重要性排序):

1. **入口页的 `<script src="core.js"></script>` 与 `<script src="tint.js"></script>` 两行不能动**(顺序也不能换 —— `tint.js` 对 `Core` 是硬依赖,反了当场抛错)。
2. **不许在 UI 层写第二份 tint / HSV / 编解码数学**:一切都走 `Tint.*` 与 `Core.*`(server_smoke 相位 ⑧ 有结构断言钉住 `rgbToHsv` 不出现)。
3. **`Core.lineCells` 的每个调用点都要先 `Math.floor`**(账本 Task 2 Minor 3:非整数或 NaN 坐标会让它的 `for(;;)` 死循环、直接挂住标签页 —— 不是返回错值,是挂住)。
4. **导入面板必须用文件名设 `map.name`**(`decodeMap` 返回 `name: ''`,不补就会经 `sanitizeName` 回落成 `'structure'`)。相位 ⑨ 已把这条契约钉住。
5. **库的身份就是文件名,不许另铸一套 id**(见本计划「决定 ②」);草稿盘要用主键就用 `sanitizeName(文件名)`。
6. **搬敌人注册表标记 = 三件事同一个 commit**:标记块搬进 `editor.html` + 改 `sync-enemies.js` 的 `htmlPath` + 删 `structure-editor.html`。少一件都会留下一份会静默漂移的注册表。
7. **纹理 22(水面)在编辑器里可选、在游戏里是自动派生**(审计 A7):调色板必须显式处理这个分歧(去掉 22,或标注"由游戏自动派生"),否则"编辑器里画的、游戏里看到的"不一样。

---

## ★ 本计划刻意不做的事(2b / 后续期)

| 不做 | 归属 | 为什么不在 2a |
|---|---|---|
| `render.js`(四层缓存 + 脏区)、`ui.js`(工具栏/图层/面板/热键)、`io.js`、`worker.js` | **计划 2b** | 全是浏览器运行时行为,**只能手测**;而 2a 的划分标准就是"能不能被 node 自动验证" |
| **闸 2**(一切长循环有单帧预算 ~8ms) | **计划 2b** | 它约束的是渲染/填充/IndexedDB 的长循环,2a 里没有这样的循环 |
| **闸 3**(编解码进 Web Worker) | **计划 2b** | `worker.js` + `io.js` 的 async 门面是 UI 的调用方;签名按规格 §4.3 的 `encodeMap(map,{compress})` / `decodeMap(bytes)` |
| **闸 4**(全局错误围栏 + 崩溃前快照) | **计划 2b** | 依赖 IndexedDB 草稿盘(§4.6)与 `ui.js` 的生命周期 |
| IndexedDB 持久化 / localStorage UI 小状态 / 「玩家参考图按格坐标存」(审计 A13) | **计划 2b** | 同上;`core.js` 与服务器都不参与 |
| 工具集(画笔/矩形/油漆桶/直线/选框/吸管/渐变)、撤销、复制粘贴、库间粘贴 | **计划 2b** | §4.4 整节;`core.js` 的 `lineCells` / `normRegion` / `brushOffsets` 已经备好 |
| 导出前校验的**界面**(把 `Core.validateMap` 的 warnings 弹出来) | **计划 2b** | 校验逻辑(§4.7)在计划 1 已落地;2a 的骨架页只是把它打印成文本 |
| `maps/*.cyrm` 迁移为 v4 二进制 | **期 E** | 迁移是单向的,必须先把 v3 文本原样提交一次留档;而且迁移完游戏侧必须同步改(交接文档 §3 那个决策还没拍板) |
| `CLAUDE.md` 的编辑器小节更新(形状面板已删、格式已换) | **计划 2b 收尾** | 现在改等于写"已实现"但实际没有的东西;等新编辑器成形后一次性更新 |
| 服务器:认证 / TLS / 目录浏览 / 多用户 / range 请求 | **永久不做** | 规格 §4.9 明写:它是本机自用工具,不是服务 |
| 服务器校验 `.cyrm` 格式(magic/版本/CRC) | **永久不做** | 见「决定 ④」:格式只有一个实现(`core.js`),两份判得不一样是"存得下、读不出"且不报错 |
| 请求体的**流式**拒绝(超限立刻 RST) | 不做 | 见 Task 3:上界守的是内存不是带宽;中途 RST 会让客户端拿到 ECONNRESET 而不是那条 413 |

---

## 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| 端口 8777 被别的进程占 | 编辑器打不开 | `startServer` 对 `EADDRINUSE` 有专门分支:打印端口 + `netstat -ano` 里那一行 + `taskkill` 提示;`serve.bat` 结尾 `pause` 免得窗口一闪而过;这条分支有断言(`rejects(..., '已被占用')`) |
| **服务器路径穿越**(静态路径或地图名) | 本机任意文件读写 | 两道闸:地图名走裸文件名白名单,静态路径走"解析后必须落在根里面"的结构性判据(不是"有没有 `..`");单元级(`staticFileFor`)+ HTTP 级(`/..%2f..`)两级测试,断言"正文里没有那个文件" |
| Windows 上 `rename` 覆盖失败(目标被别的进程占着) | 保存失败 | 临时文件与目标同目录;失败时清临时文件并回 500,**原文件保持原样**;用"目标是个非空目录"注入这个失败路径并断言清理与保全 |
| tint 数学与游戏 shader 不一致 | 编辑器里调好的颜色进游戏变样,且**不报错** | 常量从 `Core` 派生(结构性,不是靠约定);手工 golden;中性描述符对 28561 组 8 位输入逐字节恒等;交接文档 §2.2 是同一份公式 |
| 缓存不失效(审计 A2 复现) | 贴图一直是纯色块,而且"有时好有时坏" | `setSource` 一律清空整片缓存 + 专门断言;默认 backend 在无 `document` 时明确抛错(不静默画空白) |
| node 测试挂住(server 没关 / promise 永不 settle) | **假绿**:静默退出、退出码 0、一行不打 | 120 秒看门狗(**刻意不 unref**);`closeAllConnections()` 后再 `close()`;结尾显式 `process.exit`;`main()` 的 reject 被捕获后打印"后面的断言一行都没跑" |
| 反向断言"只要抛了就算过" | 假绿:拼错标识符抛的 `TypeError` 也算通过 | `rejects` / `throws` 一律带 `expectSub` 错因子串(相位 ⑤ 第一条绿、第二条红的现场就演示了这个坑) |
| 服务器写坏用户的地图 | 作品丢失 | 原子写(同目录 tmp + rename);空请求体一律拒收;三种被拒的 PUT 之后原文件逐字节不变(有断言) |
| 2b 搬走注册表标记后 `sync-enemies.js` 失联 | 敌人表静默漂移 | 本计划不碰 `structure-editor.html`;相位 ①b 跑 `--check` 钉住;删/搬/改三件事同一 commit 写进交接清单 |
| 大图上 `PUT` 的内存放大 | 服务器 OOM | `readBody` 有 64MB 上限且判在 push **之前**;上限值 = `MAX_BODY_SIZE`,对合法文件(最坏 ≈19.1MiB)不会误拒 |

