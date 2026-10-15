// parts_check.js —— 编辑器分片结构守卫。
// 只读源码判形态,不跑行为断言(那是 6 个 *_smoke.js 的事)。查四条:
//   1. editor.html 的 <script src> 顺序 == 目录内文件名字典序,且两边不许多、不许少;
//   2. 跨模块顶层名不重名(重名 = 静默覆盖,var/function 那条连错误都没有);
//   3. worker.js 的 importScripts 列表 == 页面加载的 core 分片列表(只错这一处时,
//      页面照常、只有编解码在浏览器里死 —— node 侧一条断言都看不到);
//   4. 每个模块以 99_exports.js 收尾(公开 API 表只在它里面)。
// --baseline [git-rev]:额外做"代码等价"比对 —— 分片按序拼接后(忽略注释与空白)必须与那一版
//   的原单文件逐字符同,减去模块登记的 drops(拆片时有意删/有意改,见 PAGE_MODULES);
//   改注释、改排版不算漂,改一个字符就算并打印首个差异。省略 rev = 取该模块最后一个还含
//   单文件的提交(git log -1 --diff-filter=AM):写死 rev 在拆批提交之后就取不到文件了。
// 用法:node parts_check.js [--baseline [git-rev]] [--drop <字面量>] [--ratio]
'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const DIR = __dirname;
// 页面侧共享作用域模块:目录名 ↔ 原单文件名(等价比对用)。
// ★ render 的 `baseline: false`:它这一轮不只是切分,还做了 mount() 的**闭包分解**
//   (共享状态对象 + 安装器),代码本来就不再逐字符等价 —— 它的判据是行为等价
//   (render_smoke / editor_smoke / browser_check),不是这里的逐字符比对。
const PAGE_MODULES = [
  { dir: 'core', src: 'core.js', global: 'Core', baseline: true },
  { dir: 'render', src: 'render.js', global: 'Render', baseline: false },
  {
    dir: 'ui', src: 'ui.js', global: 'Editor', baseline: true,
    // 与基线有意不同的两处,等价比对时两边都裁;裁不掉就报红,不会静默放宽:
    //   ① DEFAULT_CELLS_W/H 原本在本文件里重复声明,现在只有 core/80_validate.js 一份
    //      (三模块同页同域 ⇒ 分片读到的就是那一份)。重复真相源,删掉是对的。
    //   ② 图集路径留了注入点:单文件版把它内联成 data URL(build_dist.js 注入),
    //      开发页里 undefined ⇒ 逐字回落原来的 'structure.png'。
    drops: [
      'var DEFAULT_CELLS_W = 125, DEFAULT_CELLS_H = 75;',
      'globalThis.__CYRM_ATLAS_URL__ || ',
    ],
  },
];
let bad = 0;
function fail(msg) { bad++; console.error('  FAIL - ' + msg); }
function ok(msg) { console.log('  ok   - ' + msg); }

function read(p) { return fs.readFileSync(path.join(DIR, p), 'utf8'); }
function exists(p) { return fs.existsSync(path.join(DIR, p)); }

// ── editor.html 的脚本列表(页面加载顺序的单一真相源)──
function scriptList() {
  const html = read('editor.html');
  const out = [];
  const re = /<script[^>]*\bsrc="([^"]+)"/g;
  let m;
  while ((m = re.exec(html))) out.push(m[1]);
  return out;
}
// 某个目录下的 .js,按文件名序(加载顺序 = 字典序,故 NN_ 前缀就是顺序)。
function dirParts(dir) {
  if (!exists(dir)) return null;
  return fs.readdirSync(path.join(DIR, dir)).filter(f => f.endsWith('.js')).sort();
}

// ── 去注释、压空白(字符串字面量逐字保留)──
// 这是全仓唯一一处"把 JS 当文本归一化"的地方;注释与排版的变化不该算漂。
function normalize(src) {
  const out = [];
  let i = 0;
  const n = src.length;
  const blank = () => { if (out.length && out[out.length - 1] !== ' ') out.push(' '); };
  while (i < n) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') { while (i < n && src[i] !== '\n') i++; continue; }
    if (c === '/' && src[i + 1] === '*') {
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++;
      i += 2;
      continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      out.push(c); i++;
      while (i < n) {
        const d = src[i];
        if (d === '\\') { out.push(d); out.push(src[i + 1]); i += 2; continue; }
        out.push(d); i++;
        if (d === c) break;
      }
      continue;
    }
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') { blank(); i++; continue; }
    out.push(c); i++;
  }
  return out.join('');
}

// 原单文件 → 分片世界的等价形态:去掉 IIFE 外壳,**最后一个** `return {` 变成全局赋值。
// ★ 只能换最后一个:前面的 `return {` 是各函数自己的返回值。
function normalizeBaseline(src, globalName) {
  let s = src;
  s = s.replace(/^globalThis\.[A-Za-z_$][\w$]* = \(function \(\) \{$/m, '');
  s = s.replace(/^\}\)\(\);$/m, '');
  const re = /^[ \t]*return \{[ \t]*$/gm;
  let m, last = -1, lastLen = 0;
  while ((m = re.exec(s))) { last = m.index; lastLen = m[0].length; }
  if (last >= 0) {
    s = s.slice(0, last) + 'globalThis.' + globalName + ' = {' + s.slice(last + lastLen);
  }
  return normalize(s);
}
function normalizeParts(dir, globalName) {
  const files = dirParts(dir);
  const joined = files.map(f => read(path.join(dir, f))).join('\n');
  return normalize(joined);
}

// 顶层声明名(按大括号深度算,不信缩进)。
function topLevelNames(src) {
  const names = [];
  let depth = 0, inBlock = false, i = 0;
  for (const line of src.split('\n')) {
    let code = '';
    i = 0;
    while (i < line.length) {
      const c = line[i];
      if (inBlock) { const j = line.indexOf('*/', i); if (j < 0) { i = line.length; break; } i = j + 2; inBlock = false; continue; }
      if (c === '/' && line[i + 1] === '/') break;
      if (c === '/' && line[i + 1] === '*') { inBlock = true; i += 2; continue; }
      if (c === '"' || c === "'" || c === '`') {
        const q = c; i++;
        while (i < line.length) { if (line[i] === '\\') { i += 2; continue; } if (line[i] === q) { i++; break; } i++; }
        code += 'S'; continue;
      }
      code += c; i++;
    }
    const t = code.trim();
    if (depth === 0) {
      const m = /^(?:function\s+([A-Za-z_$][\w$]*)|(?:var|let|const)\s+([A-Za-z_$][\w$]*)|class\s+([A-Za-z_$][\w$]*))/.exec(t);
      if (m) names.push(m[1] || m[2] || m[3]);
    }
    for (const ch of code) { if (ch === '{') depth++; else if (ch === '}') depth--; }
  }
  return names;
}

function commentRatio(src) {
  let comment = 0, blank = 0, inBlock = false;
  for (const line of src.split('\n')) {
    const s = line.trim();
    if (s === '') { blank++; continue; }
    if (inBlock) { comment++; if (s.indexOf('*/') >= 0) inBlock = false; continue; }
    if (s.startsWith('//')) { comment++; continue; }
    if (s.startsWith('/*')) { comment++; if (s.indexOf('*/') < 0) inBlock = true; continue; }
  }
  const nonblank = src.split('\n').filter(l => l.trim() !== '').length;
  return { comment, nonblank, pct: nonblank ? 100 * comment / nonblank : 0 };
}

// ── 主检查 ──
function checkStructure() {
  const scripts = scriptList();
  const byDir = {};
  for (const s of scripts) {
    const d = path.dirname(s);
    if (d === '.') continue;                    // 根下的经典脚本(io/tint/tile_defs/worker)不按目录管
    (byDir[d] = byDir[d] || []).push(path.basename(s));
  }
  for (const mod of PAGE_MODULES) {
    const want = dirParts(mod.dir);
    if (!want) { fail('目录不存在:' + mod.dir + '/'); continue; }
    const got = byDir[mod.dir] || [];
    if (want.join(',') !== got.join(',')) {
      fail(mod.dir + '/: editor.html 的顺序与目录不一致\n        目录 ' + want.join(' ') + '\n        html ' + got.join(' '));
    } else {
      ok(mod.dir + '/: ' + want.length + ' 片,页面顺序与文件名字典序一致');
    }
    if (want[want.length - 1] !== '99_exports.js') fail(mod.dir + '/: 末片不是 99_exports.js');
  }

  // worker 只要 core 的分片;两边不一致 = 浏览器里只有 worker 死。
  const worker = read('worker.js');
  const m = /importScripts\(([\s\S]*?)\);/.exec(worker);
  const workerList = m ? (m[1].match(/'([^']+)'/g) || []).map(s => s.slice(1, -1)) : [];
  const coreList = (byDir['core'] || []).map(f => 'core/' + f);
  if (workerList.join(',') !== coreList.join(',')) {
    fail('worker.js 的 importScripts 列表与页面加载的 core 分片不一致\n        worker ' + workerList.join(' ') + '\n        html   ' + coreList.join(' '));
  } else {
    ok('worker.js: importScripts 与页面 core 分片一致(' + coreList.length + ' 片)');
  }

  // 跨模块重名。只比页面侧三个模块:io/tint/tile_defs 仍是自己的 IIFE,不与它们同域。
  const seen = {};
  for (const mod of PAGE_MODULES) {
    if (!exists(mod.dir)) continue;
    for (const f of dirParts(mod.dir)) {
      for (const name of topLevelNames(read(path.join(mod.dir, f)))) {
        if (seen[name]) fail('顶层名重名:' + name + '(' + seen[name] + ' 与 ' + mod.dir + '/' + f + ')');
        else seen[name] = mod.dir + '/' + f;
      }
    }
  }
  ok('跨模块顶层名:' + Object.keys(seen).length + ' 个,无重名');
}

// 基线版本:显式给的优先;没给就现算"最后一个还含这个单文件的提交"。'' = 算不出来,
// 调用方必须点名这件事(不许把 undefined 拼进 git show)。
function baselineRev(mod, rev) {
  if (rev) return rev;
  try {
    return execFileSync('git', ['log', '-1', '--format=%H', '--diff-filter=AM', '--', 'level_editor/' + mod.src],
      { cwd: path.join(DIR, '..'), encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch (e) { return ''; }
}

function checkBaseline(rev, extraDrops) {
  for (const mod of PAGE_MODULES) {
    if (!dirParts(mod.dir)) { fail('无法比对:目录不存在 ' + mod.dir + '/'); continue; }
    if (!mod.baseline) {
      ok(mod.dir + '/ 跳过等价比对(它的拆分含闭包分解,判据是行为等价:render_smoke/editor_smoke/browser_check)');
      continue;
    }
    const use = baselineRev(mod, rev);
    if (!use) {
      fail('取不到基线版本:无法定位含 level_editor/' + mod.src + ' 的提交 —— 显式给一个:' +
        'node parts_check.js --baseline <git-rev>');
      continue;
    }
    let base;
    try { base = execFileSync('git', ['show', use + ':level_editor/' + mod.src], { cwd: path.join(DIR, '..'), encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }); }
    catch (e) { fail('取不到基线 ' + use.slice(0, 8) + ':level_editor/' + mod.src + '(那个提交里没有这个文件?)'); continue; }
    let a = normalizeBaseline(base, mod.global);
    let b = normalizeParts(mod.dir, mod.global);
    // 逐字裁掉"拆片时有意删掉/有意改掉"的那几处:模块自己登记的 drops + 命令行 --drop,两边都裁。
    // 裁不掉 = 两边都留着 ⇒ 下面照常报红,不会因为"多给了一个 drop"就静默放宽。
    for (const d of (mod.drops || []).map(normalize).concat(extraDrops)) {
      a = normalize(a.split(d).join('')); b = normalize(b.split(d).join(''));
    }
    const tag = use.slice(0, 8);
    if (a === b) { ok(mod.dir + '/ 与 ' + tag + ' 的 ' + mod.src + ' 代码等价(' + a.length + ' 字符)'); continue; }
    let i = 0;
    while (i < a.length && i < b.length && a[i] === b[i]) i++;
    fail(mod.dir + '/ 与 ' + tag + ' 的 ' + mod.src + ' 不等:首个差异在第 ' + i + ' 字符\n        基线 …' + a.slice(Math.max(0, i - 60), i + 60) + '\n        分片 …' + b.slice(Math.max(0, i - 60), i + 60));
  }
}

function walkJs(dir, out) {
  for (const e of fs.readdirSync(path.join(DIR, dir), { withFileTypes: true })) {
    const rel = dir ? dir + '/' + e.name : e.name;
    if (e.isDirectory()) { if (e.name !== 'dist' && e.name !== 'node_modules') walkJs(rel, out); }
    else if (e.name.endsWith('.js')) out.push(rel);
  }
  return out;
}
function reportRatio() {
  // tile_defs.js 是 sync-tiles.js 的生成物,dist/ 是整个页面的打包结果 —— 都不在额度内。
  // 额度口径同 docs/eng/comment-style.md §8:**非空行 > 100** 的文件才受 ≤15% 约束
  // (小文件里 1 行头注释就能占 20%,拿比例去管它没有意义)。
  const files = walkJs('', []).filter(f => f !== 'tile_defs.js');
  let over = 0, counted = 0;
  for (const f of files) {
    const r = commentRatio(read(f));
    const big = r.nonblank > 100;
    if (big) counted++;
    const flag = (big && r.pct > 15) ? '  <<< 超标' : (big ? '' : '  (非空行 ≤100,不在额度内)');
    if (big && r.pct > 15) over++;
    console.log('  ' + (r.pct.toFixed(1) + '%').padStart(6) + '  ' + f.padEnd(32) + r.comment + '/' + r.nonblank + flag);
  }
  if (over) fail(over + ' 个 >100 行的文件注释占比 > 15%');
  else ok('注释额度:' + counted + ' 个 >100 行的文件全部 ≤15%');
}

const argv = process.argv.slice(2);
console.log('[parts_check]');
checkStructure();
const bi = argv.indexOf('--baseline');
if (bi >= 0) {
  const drops = [];
  for (let i = 0; i < argv.length; i++) if (argv[i] === '--drop') drops.push(normalize(argv[i + 1]));
  // `--baseline` 后面跟的是另一个开关(而不是 rev)时按"没给 rev"处理,别把 `--ratio` 当版本号。
  const next = argv[bi + 1];
  checkBaseline(next && next.indexOf('--') !== 0 ? next : '', drops);
}
if (argv.indexOf('--ratio') >= 0) reportRatio();
console.log(bad ? 'PARTS CHECK FAIL(' + bad + ' 条)' : 'PARTS CHECK OK');
process.exit(bad ? 1 : 0);
