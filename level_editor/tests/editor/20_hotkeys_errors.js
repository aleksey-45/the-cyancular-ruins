'use strict';
// 热键表 / 校验清单 / 唯一的写盘出口(行为面)/ 错误可见性。
const Core = globalThis.Core;
const Editor = globalThis.Editor;

module.exports = (async function () {

  // ── 热键表(规格 §4.8):一条判定类别 = 一条守卫(24 条"一个键一条断言"是 D9)
  const k = function (key, mod) { return { key: key, ctrl: !!mod, meta: false, shift: false }; };
  const KEYMAP = [
    ['b', false, 'tool:brush'], ['e', false, 'tool:eraser'], ['g', false, 'tool:bucket'],
    ['m', false, 'tool:select'], ['l', false, 'tool:line'], ['i', false, 'tool:picker'],
    ['[', false, 'brush-smaller'], [']', false, 'brush-bigger'], ['2', false, 'layer:2'],
    ['z', true, 'undo'], ['y', true, 'redo'], ['c', true, 'copy'], ['x', true, 'cut'],
    ['v', true, 'paste'], ['s', true, 'save'],
    ['Delete', false, 'clear-selection'], ['Backspace', false, 'clear-selection'],
    ['Escape', false, 'cancel-selection'],
    ['ArrowLeft', false, 'pan:left'], ['ArrowDown', false, 'pan:down'],
    ['F5', false, null], ['p', true, null],   // ★ 表外的键一律 null(不拦浏览器自己的快捷键)
  ];
  eq(KEYMAP.map(function (e) { return Editor.commandFor(k(e[0], e[1])); }),
     KEYMAP.map(function (e) { return e[2]; }),
     '热键表逐条与规格 §4.8 一致(' + KEYMAP.length + ' 条 + 表外键返回 null)');
  // ★ 两处 Shift 变体单独留:它们的输入形状(带 shift 的 Ctrl 组合)与上表不同。
  eq(Editor.commandFor({ key: 'Z', ctrl: true, shift: true }), 'redo', 'Ctrl+Shift+Z → 重做');
  eq(Editor.commandFor({ key: 'S', ctrl: true, shift: true }), 'save-as', 'Ctrl+Shift+S → 另存为');

  // Shift 约束(规格 §4.8):期望值按规格的字面取实现那一侧。
  tableEq('Shift 直线:近轴锁轴、其余锁 45°(取两轴较大者),方向不翻正', [
    ['近水平 → 锁成水平', Editor.constrainLine({ x: 0, y: 0 }, { x: 10, y: 2 }, true), { x: 10, y: 0 }],
    ['近垂直 → 锁成垂直', Editor.constrainLine({ x: 0, y: 0 }, { x: 2, y: 10 }, true), { x: 0, y: 10 }],
    ['其余 → 锁成 45°(不是"不按 Shift"的 floor 结果)', Editor.constrainLine({ x: 0, y: 0 }, { x: 10, y: 8 }, true), { x: 10, y: 10 }],
    ['45° 也带对方向(负方向不翻正)', Editor.constrainLine({ x: 0, y: 0 }, { x: -10, y: 8 }, true), { x: -10, y: 10 }],
  ]);
  // ★ 与上表不同类(判的是**整数化**,不是方向),单独留。
  eq(Editor.constrainLine({ x: 0, y: 0 }, { x: 7.9, y: 0.6 }, false), { x: 7, y: 0 },
     '★★ 不按 Shift:只 floor(NaN/小数会让 Core.lineCells 死循环挂住)');
  eq(Editor.constrainSquare({ x: 0, y: 0 }, { x: 10, y: 3 }, true), { x: 10, y: 10 },
     '★ Shift 选区:等比(取两轴较大者,变成正方形)');
  eq(Editor.constrainSquare({ x: 4, y: 4 }, { x: 0, y: 1 }, true), { x: 0, y: 0 },
     '★ Shift 选区:方向朝左上时同样等比(|dx|=4、|dy|=3 ⇒ 只能是 {0,0})');

  // ── 校验清单(§4.7)──
  const mv = Core.createMap('t', 2, 1);
  const lines = Editor.validateLines(Core.validateMap(mv));
  ok(lines.length >= 2, '★ 空图的校验清单至少两条(没有出生点 / 四层全空),实得 ' + lines.length);
  ok(lines.some(function (l) { return l.indexOf('出生点') >= 0; }), '清单里点名了"出生点"');
  ok(lines.some(function (l) { return l.indexOf('空') >= 0; }), '清单里点名了"四层全空"');
  eq(Editor.validateLines({ errors: [], warnings: [] }), [], '没有问题时清单是空的');
  ok(Editor.validateLines({ errors: ['坏文件'], warnings: [] })[0].indexOf('坏') >= 0,
     'errors 也进清单(errors 是"导出去就是坏文件")');

  // ── 唯一的写盘出口:PUT 的行为面 ──
  // ★ body 必须是裸字节:写端点把 buffer 原样落盘;头里的 application/json
  //   是跨域闸(CSRF),不是编码声明。
  const sent = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = function (url, init) {
    sent.push({ url: url, init: init });
    return Promise.resolve({ ok: true, status: 200, json: function () { return Promise.resolve({ name: 'x.cyrm', size: 12 }); } });
  };
  try {
    const wout = await Editor.putMapBytes('x.cyrm', new Uint8Array([1, 2, 3]));
    eq(sent.length, 1, '★ putMapBytes 真发了**一次**请求');
    ok(sent[0].url.indexOf('/api/map?p=x.cyrm') >= 0, '★ 写端点带上了文件名');
    eq(sent[0].init.method, 'PUT', '★★ 行为断言:请求方法就是 PUT(不只是源码里出现过这个词)');
    eq(sent[0].init.headers && sent[0].init.headers['Content-Type'], 'application/json',
       '★★ 行为断言:请求头真的带 Content-Type: application/json(少了它就是 415)');
    // ★ 先判类型再取内容:body 不是 Blob 时 `.arrayBuffer` 不存在 ⇒ 抛出去会中断整条冒烟。
    const putBlob = sent[0].init.body;
    const putBody = (putBlob && typeof putBlob.arrayBuffer === 'function')
                    ? Array.from(new Uint8Array(await putBlob.arrayBuffer())) : null;
    eq(putBody, [1, 2, 3],
       '★★ body 是**裸字节**(不是 JSON 编码;写端点把 buffer 原样落盘,JSON 化会写出一份坏文件。' +
       '实得 ' + JSON.stringify(putBody) + ')');
    eq(wout, { name: 'x.cyrm', size: 12 }, 'putMapBytes: 交回服务器那份应答(调用方要报字节数)');
  } finally {
    globalThis.fetch = realFetch;
  }

  // ── 错误可见性(症状"按了没反应"的那条通道)──
  // ★ 陷阱:面板与渲染里抛出的异常若被吞掉,用户看到的是"点了没反应";而分帧重建的失败
  //   是一次 promise 拒绝,同步 try/catch 接不住 —— guard 必须同时接住这两条,并报到
  //   屏幕上的同一条通道(可替换的 sink)。
  const seen = [];
  Editor.setErrorSink(function (text) { seen.push(String(text)); });

  eq(Editor.guard('工具', function () { throw new Error('画布炸了'); }), null,
     '★ guard:同步抛出时返回 null(调用方不必自己判异常)');
  ok(seen.length === 1 && seen[0].indexOf('画布炸了') >= 0 && seen[0].indexOf('工具') >= 0,
     '★★ 同步抛出**上报**给了 sink(不是被吞掉):' + JSON.stringify(seen));

  const mp = Core.createMap('t', 2, 1);
  seen.length = 0;
  const painted = Editor.guard('落笔', function () {
    return Editor.paintCells(mp, Core.LAYER_SCENE, [0], function () { throw new Error('描述符非法'); });
  });
  eq(painted, null, '★ 抛错的落笔路径:guard 交回 null(调用方不必自己判)');
  ok(seen.length === 1 && seen[0].indexOf('描述符非法') >= 0,
     '★★ **抛错的落笔**产出一条可见消息(而不是静默空面板):' + JSON.stringify(seen));
  eq(countNonZero(mp, Core.LAYER_SCENE), 0, '★ 抛错的那一笔一个字都没写进地图(不留半截状态)');

  seen.length = 0;
  let settled = null;
  await Editor.guard('视图', function () { return Promise.reject(new Error('分帧里炸了')); })
    .then(function () { settled = 'resolved'; }, function () { settled = 'rejected'; });
  ok(settled === 'resolved' && seen.length === 1 && seen[0].indexOf('分帧里炸了') >= 0,
     '★★ 视图入口的**拒绝**同样上报这条通道,且交回的 promise 已收口(调用方忘了 await 也不会冒' +
     '"未处理的 promise 拒绝"):' + JSON.stringify(seen));
  Editor.setErrorSink(null);          // 还原默认通道(后面的分片不再借它)

})();
