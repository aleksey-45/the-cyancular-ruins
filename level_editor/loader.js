// loader.js —— node 侧按**浏览器语义**加载分片:每片是一段独立的经典脚本,
// 共享同一个全局作用域(顺序的真相源是 editor.html 的 <script src> 列表)。
// ★★ 为什么是 vm.runInThisContext 而不是 `new Function(全部拼起来)`:
//    `new Function` 把全部分片塞进**一个函数体**,于是任何一片顶层的 `var Core = …`
//    会被 hoist 到整段、**遮蔽**别的模块写在 globalThis 上的同名全局 —— 症状是"加载期"
//    裸读那个名字得到 undefined(render 侧踩过:`var SUB = Core.SUB_PER_CELL` 读到 undefined)。
//    浏览器里每片是独立脚本,`var` 落在全局对象上、不会遮蔽;`runInThisContext` 逐片执行
//    才是同一套语义(同源 realm、`var` 成全局属性、顶层 `const` 进全局词法环境且跨片可见)。
// ★ 必须一次调用装完整个模块:分两次 run 出来的是同一个作用域没错,但**顺序**要自己保证。
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const DIR = __dirname;

// 页面加载顺序的脚本路径(相对 level_editor)。
function scripts() {
  const html = fs.readFileSync(path.join(DIR, 'editor.html'), 'utf8');
  const out = [];
  const re = /<script[^>]*\bsrc="([^"]+)"/g;
  let m;
  while ((m = re.exec(html))) out.push(m[1]);
  return out;
}

// 某个目录(模块)下的分片,顺序 = editor.html 里的顺序。
function moduleScripts(dir) {
  return scripts().filter(s => s.indexOf(dir + '/') === 0);
}

// 逐片在**当前**全局作用域里执行(等价于浏览器一个个 <script>)。
function run(paths) {
  for (const p of paths || scripts()) {
    vm.runInThisContext(fs.readFileSync(path.join(DIR, p), 'utf8'), { filename: path.join(DIR, p) });
  }
}

// 依赖序:core → tile_defs → tint → render → io → ui。只装列出的那些。
// 名字不带扩展名('core' / 'render' 这类是目录,'tint' / 'io' 这类是根下的单文件)。
const ORDER = ['core', 'tile_defs', 'tint', 'render', 'io', 'ui'];
function byName(name) {
  return scripts().filter(p => p.indexOf(name + '/') === 0 || p === name + '.js');
}
function loadModules(names) {
  const want = [];
  for (const key of ORDER) {
    if (names.indexOf(key) >= 0) want.push.apply(want, byName(key));
  }
  run(want);
}

module.exports = { scripts, moduleScripts, run, loadModules };
