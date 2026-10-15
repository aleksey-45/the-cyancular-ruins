'use strict';
// ⑮b⑥⑦⑨⑩:启动时 offerDraft → loadDraft → 恢复 / applyUiState 把 UI 小状态按回界面 /
// **真跑一遍 `bootLoad()`** / 闸 4 的**写**侧(页面异常 ⇒ 当场把当前图写进崩溃槽位)。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
const Render = globalThis.Render;
require('./lib/stubs_draft.js').getStubs15();

module.exports = (async function () {

  const recD15 = function () { return tab15.draft.get('draft_probe') || null; };

  // ── ⑥ 接线之二:启动时 offerDraft → loadDraft → 恢复(问一次,不静默覆盖)──
  Editor.spawnAt('enemy', 0);                     // 再画一笔(草稿那份现在共 3 个敌人)
  const dirtyMap15 = Editor.app.map;
  eq(dirtyMap15.enemies.length, 3, '⑮b 前提:草稿那份现在是 3 个敌人');
  await Editor.flushDraft();
  eq(recD15() && recD15().dirty, true, '⑮b 前提:又变成"没写盘的活"');

  // 模拟"关掉页面、重新打开这张图":屏幕上先是从**真文件**打开的那份(内容不同)
  let asked15 = 0, answer15 = true;
  globalThis.confirm = function () { asked15++; return answer15; };
  Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);   // 文件里那份:空的
  Editor.app.name = 'draft_probe.cyrm';
  const restored15 = await Editor.offerDraft();
  eq(asked15, 1, '★★ 有一份没写盘的草稿 ⇒ 启动时**问一次**(不静默)');
  eq(restored15, true, '★★★ offerDraft 真的用 loadDraft 读回了草稿并恢复(handoff 3 的接线)');
  eq(Editor.app.map.enemies.length, 3, '★★ 恢复的是**草稿那份**内容(而不是文件里那份空的)');
  ok(calls15.indexOf('setMap') >= 0, '★ 恢复走 app.r.setMap(画面真的换了,不是只改了内存)');
  ok(el15('status-msg').textContent.indexOf('已从草稿恢复') >= 0,
     '★★ 恢复要**说一句**(用户得知道屏幕上是草稿、不是文件;实得 "' +
     el15('status-msg').textContent + '")');

  // 点"取消":屏幕上的图一个字都不动(问过但不覆盖)
  Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);
  answer15 = false;
  eq(await Editor.offerDraft(), false, '★ 用户点取消 ⇒ 不恢复');
  eq(Editor.app.map.enemies.length, 0, '★★ 点取消时**屏幕上那份没被碰过**(不是"恢复了又撤销")');
  eq(asked15, 2, '★ (对照)取消那次也是真问了');

  // 干净的草稿(存过盘):连问都不问
  if (recD15()) recD15().dirty = false;
  Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);
  eq(await Editor.offerDraft(), false, '★ 存过盘的草稿不再问(否则每次都弹一次)');
  eq(asked15, 2, '★★ 那一次**没有**弹确认框(asked 没涨)');

  // 没有地图可打开时:不问、不抛
  Editor.app.map = null;
  globalThis.confirm = function () { asked15++; return true; };
  eq(await Editor.offerDraft(), false, '★ 一张图都没打开时 offerDraft 直接交回 false');

  // ★★ "假提示"那一类:草稿那份与**真文件里**那份逐字节相同 ⇒ 不该问。现实里的成因是
  //    "Ctrl+S 成功、但标干净那一步没落地就刷新了页面"(或走了另存为)。
  Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);
  if (recD15()) recD15().dirty = true;
  Editor.app.raw = recD15() ? recD15().bytes : null;       // 文件里那份 = 草稿那份(逐字节)
  asked15 = 0;
  eq(await Editor.offerDraft(), false, '★★★ 草稿与刚打开的文件**逐字节相同** ⇒ 不恢复');
  eq(asked15, 0, '★★ 那一次连确认框都没弹(假提示那一类的正面守卫)');
  Editor.app.raw = new Uint8Array([1, 2, 3]);              // 文件里那份**不同** ⇒ 照问
  globalThis.confirm = function () { asked15++; return false; };
  eq(await Editor.offerDraft(), false, '★ (对照)字节不同时仍然问(用户这次点了取消)');
  eq(asked15, 1, '★ (对照)这一次真弹了确认框');

  // ── ⑦ 第 3 层:applyUiState 把 UI 小状态真的按回界面(含"缩放只在 setMap 之后")──
  Editor.app.map = Editor.createEmptyMap('draft_probe', 4, 4);
  calls15.length = 0;
  // ★ 图集此刻的容量:**这一条前提不写死** —— 见下面纹理那条断言的说明。
  const cap15 = Render.atlasCapacity();
  const pre15 = Editor.app.st.desc;            // 恢复**之前**的那份描述符(四个辅码档位)
  Editor.app.uist = { layer: Core.LAYER_BG, zoom: 0, tool: 'line', brushSize: 3,
                      grid: false, subGrid: true, torus: false, dimOthers: false,
                      panelOpen: { lib: true, right: true },
                      playerRef: { cx: 7, cy: 9, visible: true }, selectedTexture: 5 };
  Editor.applyUiState();
  eq(Editor.app.st.tool, 'line', '★★ applyUiState 把图层/工具按回界面(tool=line)');
  eq(Editor.app.st.brushSize, 3, '★ 画笔大小也按回去了');
  ok(calls15.indexOf('setLayer:3') >= 0, '★ setLayer 收到的是存下来的那一层(3=背景)');
  ok(calls15.indexOf('setGrid:false') >= 0 && calls15.indexOf('setTorus:false') >= 0,
     '★ 两个开关也按回去了(setGrid/setTorus 收到 false)');
  eq(el15('tg-grid').classList.contains('on'), false,
     '★★ DOM 与状态**一致**(开关显示关着 —— 否则"页面显示的"与"实际用的"是两回事)');
  // ★★★ 上面那条只证明"渲染层收到了 3"。**面板与图层行是另一回事**(它们由 ui 那一层的
  //     `setLayer` 管):只调 `app.r.setLayer` 的话,屏幕右侧仍摆着纹理调色板、`.cur` 仍钉在
  //     「场景」行上,而刷子已经画到背景层了 —— 用户看到的与正在发生的不是一回事,且不报错。
  eq(el15('palette').style.display, 'none',
     '★★★ 存下来的是背景层 ⇒ 纹理调色板必须**藏起来**(背景层用颜色选择器,规格 §4.5);' +
     '实得 ' + JSON.stringify(el15('palette').style.display));
  eq(curRow15(), Core.LAYER_BG,
     '★★★ 图层行的 `.cur` 在**存下来的那一层**上(不是永远钉在 editor.html 写死的「场景」行上);' +
     '实得 ' + curRow15());
  eq(calls15.indexOf('setZoomAt'), -1,
     '★ 存下来的 zoom=0 是"没存过缩放"的哨兵 ⇒ **不碰** setMap 自己 fit 出来的缩放');
  Editor.app.uist.zoom = 2.5;
  calls15.length = 0;
  Editor.applyUiState();
  ok(calls15.indexOf('setZoomAt') >= 0, '★ 真存过缩放时要恢复它(setZoomAt 被调了)');
  // ★★ 纹理那条**不能写死 5**:`clampTexture` 对"容量 < 1(没有信息)"给的是 **1**,而图集
  //    状态是**上一个分片留下的**(⑭ 的替身留的是 512×640 ⇒ cap 320)。写死 5 的话,哪天
  //    那个替身改成空图集,这条会**因为环境**而红。故判据取 `clampTexture(5, cap)`。
  // ★★ 但容量 < 5 时 5 会被钳成 cap,而 cap 可能**恰好等于**恢复前那份的纹理位 ⇒ 那条就
  //    **不再证明**"纹理位真的被按回去了"。故把前提**明文断言出来**。
  ok(cap15 >= 5,
     '★★ 前提:图集容量 ≥ 5(实得 ' + cap15 + ')—— 本分片假设 ⑭ 留下的图集还在' +
     '(512×640 ⇒ 320)。★ 容量 < 5 时下面那条只剩"不越界"这一半,不是功能红');
  eq(Editor.app.st.desc === Core.packDesc(Editor.clampTexture(5, cap15),
                                          Core.hueOf(pre15), Core.brightOf(pre15),
                                          Core.satOf(pre15), Core.alphaOf(pre15)), true,
     '★ 选中的纹理也按回去了(只换纹理位,四个辅码档位**不动** —— 与恢复**之前**那份逐位比;' +
     '纹理位按 clampTexture(5, ' + cap15 + ') 判,故与图集状态无关;' +
     '恢复前那份的纹理位 = ' + Core.texOf(pre15) + ')');

  // ── ⑨ 真跑一遍 `bootLoad()`:启动那条链**行为上**确实去问了一次草稿 ──
  // ★★ 为什么源码级那条不够:它只证明"函数名出现在函数体附近",一个把它删掉、却在紧邻的
  //    注释里写回这个名字的实现**照样全绿**(本相位就是这么被咬过一次的)。故这一步真的把
  //    `bootLoad()` 跑完:真文件里是**空**的那张图,草稿盘里是**3 个敌人**的那一份,
  //    `confirm` 答"要" —— 跑完之后 `app.map` 必须是**草稿那份**,而且状态栏说了话。
  const savedImage15 = globalThis.Image, savedLoc15 = globalThis.location;
  globalThis.Image = function () {
    const img = this;
    img.width = 512; img.height = 640; img.onload = null; img.onerror = null;
    Object.defineProperty(img, 'src', {
      get: function () { return 'structure.png'; },
      set: function () { if (img.onload) img.onload(); },
    });
  };
  globalThis.location = { search: '?p=boot_probe.cyrm' };

  const draftMap15 = Editor.createEmptyMap('boot_probe', 4, 4);
  draftMap15.enemies.push({ x: 1, y: 1, type: 'fly_bird' },
                          { x: 2, y: 2, type: 'fly_bird' },
                          { x: 3, y: 3, type: 'fly_bird' });
  const fileMap15 = Editor.createEmptyMap('boot_probe', 4, 4);      // 真文件里那份:空的
  tab15.draft.set('boot_probe', {
    key: 'boot_probe', name: 'boot_probe.cyrm', name2: 'boot_probe',
    bytes: await globalThis.Io.encodeMap(draftMap15, { compress: true }),
    sourceFormat: 'v4', savedAt: Date.now(), dirty: true,
  });
  const fileBytes15 = await globalThis.Io.encodeMap(fileMap15, { compress: true });
  globalThis.fetch = function (url) {
    const u = String(url);
    if (u.indexOf('/api/maps') === 0) {
      return Promise.resolve({ ok: true, status: 200,
                               json: function () { return Promise.resolve({ maps: [] }); } });
    }
    return Promise.resolve({ ok: true, status: 200,
                             arrayBuffer: function () { return Promise.resolve(
                               fileBytes15.buffer.slice(fileBytes15.byteOffset,
                                                        fileBytes15.byteOffset + fileBytes15.byteLength)); } });
  };
  asked15 = 0; answer15 = true;
  globalThis.confirm = function () { asked15++; return answer15; };
  Editor.app.tileDefs = globalThis.TILE_DEFS;
  Editor.app.map = null; Editor.app.name = null; Editor.app.raw = null;
  await Editor.bootLoad();
  eq(asked15, 1,
     '★★★ `bootLoad()` 真的问了一次"要不要恢复草稿"(实得问 ' + asked15 + ' 次)—— ' +
     'D2 那个缺陷的**行为**守卫:零调用点的实现这里必然问 0 次');
  ok(el15('status-msg').textContent.indexOf('启动失败') < 0,
     '⑮b 前提:启动链没有半路失败(实得 "' + el15('status-msg').textContent + '")');
  eq(Editor.app.map && Editor.app.map.enemies.length, 3,
     '★★★ 启动完之后画布上是**草稿那份**(3 个敌人),不是真文件里那份(空的)' +
     ' —— 恢复必须排在 openFromUrl() **之后**才压得住');
  ok(el15('status-msg').textContent.indexOf('已从草稿恢复') >= 0,
     '★★ 状态栏说了这件事(实得 "' + el15('status-msg').textContent + '")');
  globalThis.Image = savedImage15; globalThis.location = savedLoc15;

  // ── ⑩ 闸 4 的**写**侧:页面异常 ⇒ 当场把当前图写进崩溃槽位 ──
  // ★ 这条是这一层存在的全部理由("最坏只丢最后一笔"),而它只在**页面真的抛**的时候跑 ——
  //   node 里没有真 window.onerror,故给 `addEventListener` 一个记账替身,把生产挂上去的
  //   处理函数**拿出来直接调**(而不是"源码里出现过就过")。
  const hooked15 = {};
  const savedAdd15 = globalThis.addEventListener;
  globalThis.addEventListener = function (evt, fn) { hooked15[evt] = fn; };
  try {
    Editor.app.map = Editor.createEmptyMap('crash_probe', 4, 4);
    Editor.app.name = 'crash_probe.cyrm';
    Editor.installCrashFence();
    ok(typeof hooked15.error === 'function' && typeof hooked15.unhandledrejection === 'function',
       '★★ 闸 4 挂了**页面异常**与**未处理的拒绝**两条(两条缺一,那半边就静默没有快照)');
    tab15.crash.clear();
    el15('status-msg').textContent = '';
    hooked15.error({ message: '手工制造一次崩溃' });
    await until15(function () { return tab15.crash.has('crash'); });
    const crash15 = tab15.crash.get('crash');
    ok(!!crash15,
       '★★★ 页面异常当场把**当前这张图**写进了崩溃槽位(键 crash;等不到 = 崩溃围栏是空的)');
    eq(crash15 && crash15.key, 'crash', '★ 崩溃槽位的键固定是 crash');
    eq(crash15 && crash15.name, 'crash_probe.cyrm', '★ 记着真文件名(恢复时要写回同一张图)');
    ok(!!(crash15 && crash15.bytes && crash15.bytes.length), '★ 存的是编码后的字节');
    ok(!!crash15 && String(crash15.why).indexOf('手工制造一次崩溃') >= 0,
       '★ 记下了异常文本(事后能知道崩在哪;实得 ' + JSON.stringify(crash15 && crash15.why) + ')');
    ok(el15('status-msg').textContent.indexOf('页面异常') >= 0,
       '★★ 异常在状态栏**说出来**了(不是静默;实得 "' + el15('status-msg').textContent + '")');
    tab15.crash.clear();
    hooked15.unhandledrejection({ reason: new Error('拒绝也要兜住') });
    await until15(function () { return tab15.crash.has('crash'); });
    eq(tab15.crash.get('crash') && tab15.crash.get('crash').why, 'unhandledrejection',
       '★ 未处理的拒绝同样落一份(两条路都兜)');
  } finally {
    globalThis.addEventListener = savedAdd15;
  }

})();
