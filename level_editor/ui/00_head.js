// ui/00_head.js —— 编辑器全局:依赖守卫、状态对象、常量。
'use strict';

var Core = globalThis.Core, Render = globalThis.Render, Io = globalThis.Io;
if (!Core) throw new Error('ui.js: 必须先加载 core.js');
if (!Render) throw new Error('ui.js: 必须先加载 render.js');
if (!Io) throw new Error('ui.js: 必须先加载 io.js');

var app = {
  r: null, canvas: null, map: null, name: null,
  raw: null, sourceFormat: null, tileDefs: null,
};
