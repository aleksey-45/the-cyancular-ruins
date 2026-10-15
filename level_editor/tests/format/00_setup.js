'use strict';
// tests/format/00_setup.js —— 装载被测模块:core/ 的 12 片按 editor.html 的顺序在一个共享作用域里求值。
// 后面的分片是各自独立的模块,彼此只共享 globalThis,故这里一次装完。
const loader = require('../../loader.js');
try {
  loader.loadModules(['core']);
} catch (err) {
  console.error('core/ 执行失败(可能是语法错误):', err.message);
  process.exit(1);
}
if (!globalThis.Core) {
  console.error('FAIL: core/ 没有导出 globalThis.Core');
  process.exit(1);
}
