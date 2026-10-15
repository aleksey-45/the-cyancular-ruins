// ui/55_interaction.js —— 画布指针交互(唯一一处把 DOM 事件接上工具的地方)。

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
  renderSaveState();                // ★ 每落一笔都要跟着翻(状态栏是"现在"的样子)
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
           rgba2: app.st.rgba2, brushSize: app.st.brushSize, selection: app.r.selection(),
           descOnly: app.st.descOnly };
}
function subRectOf(from, to) {
  var k = Core.SUB_PER_CELL;
  var x0 = from.x * k2of(from), y0 = from.y * k2of(from);
  var x1 = to.x * k2of(to), y1 = to.y * k2of(to);
  return { x: Math.min(x0, x1), y: Math.min(y0, y1),
           w: Math.abs(x1 - x0) + k, h: Math.abs(y1 - y0) + k };
}
// ★ Shift 约束后的落点(规格 §4.8):预览与落笔必须走同一个函数 —— 否则预览画的是 A、松手落下去的
//   是 B(这类不一致只在动手时才看得出来)。
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
  // ★ 空格不放进 commandFor:那张表返回"按下即执行的一条命令",而空格只是下一次拖拽的修饰。
  //   它是一个按下/抬起的状态,故 keydown 置位、keyup 与 blur 清位 —— blur 那条不是装饰:
  //   按住空格去点别的窗口(或 Alt+Tab)时 keyup 到不了这个页面,清不掉的话回来一拖就莫名平移。
  var spaceDown = false;
  // ★ 两个颜色槽:规格 §4.4 的渐变是"两端各选一色" ⇒ 必须两个颜色状态(rgba 起点 / rgba2 终点);
  //   给成同一个色的话渐变会退化成纯色填充,而且看不出来。
  app.st = { tool: 'brush', brushSize: 1, desc: Core.neutralDesc(1),
             rgba: 0xFF00FFFF, rgba2: 0x101820FF,
             descOnly: false, selStart: null, stroke: null, panning: null, selDrag: null,
             gradStart: null };

  cv.addEventListener('contextmenu', function (e) { e.preventDefault(); });

  cv.addEventListener('pointerdown', function (ev) {
    if (cv.setPointerCapture) cv.setPointerCapture(ev.pointerId);
    guard('pointerdown', function () {
      if (ev.button === 1 || ev.altKey || (spaceDown && ev.button === 0)) {   // 中键 / Alt / 空格+左键 = 平移
        app.st.panning = { x: ev.clientX, y: ev.clientY };
        return;
      }
      if (ev.button !== 0) return;
      var hit = hitOf(ev);
      var sel = app.r.selection();
      // ★ 没打开地图时退回线性口径(与 Render.inSel 的 W/H 缺省同款)—— 指针事件比 setMap 早到是可能的。
      var W = app.map ? app.map.subCols : 0, H = app.map ? app.map.subRows : 0;
      if (app.st.tool === 'select') {
        // ★ 判"按在选区里"必须先把命中换算到子格:整格命中给的是格号,而选区是子格单位 —— 直接比会差
        //   4 倍(而且永远不成立),表现为"选框工具一拖就是在重新框选,选区永远拖不动";换算只有 toSub 一处。
        // ★★ 判据与 regionCells 的 clip 同一个(inRect → Render.inSel,带环面折算):三个"选区"口径此前
        //   是三种,各自在接缝那一侧给出不同答案 —— 最刺眼的是"框里画,一半画得进去、一半什么都没发生"。
        var hs = toSub(hit);
        if (sel && inRect(sel, hs.x, hs.y, W, H)) {
          app.st.selDrag = { from: hit, dx: 0, dy: 0 };   // 选区内按下 = 拖动它
        } else {
          app.st.selStart = hit;
        }
        return;
      }
      if (app.st.tool === 'picker') {
        var rect0 = cv.getBoundingClientRect();
        var p = app.r.screenToSub(ev.clientX - rect0.left, ev.clientY - rect0.top);
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
        // ★★ runJob 交回的是一整条分帧链的 promise(slicer.run → onApply → 落笔):丢掉它 = 拒绝逃到
        //   全局围栏,而围栏会 snapshot() ⇒ 一次普通的落笔失败会把当前图写进崩溃槽位,下次开机弹假的
        //   「上次异常退出」。guard 是终点(它自己吞掉结果、只往状态栏写一行),故这里是唯一该接住的地方。
        guard('油漆桶填充', function () {
          return runJob(job, function () {
            pushAndShow(paintCells(app.map, s0.layer, job.result(), valueFor(s0, s0.layer)));
          }, '油漆桶填充');
        });
        return;
      }
      if (app.st.tool === 'gradient') {
        // ★ 规格 §4.4:渐变仅背景层。工具按钮只是压暗(视觉提示),真正的闸在这里 —— 少了它,在纹理层
        //   拖渐变会悄悄改掉背景层(屏幕上看不出,因为背景在最底下)。
        if (app.r.layer() !== Core.LAYER_BG) { status('渐变只能用在背景层(它改的是颜色,不是纹理)'); return; }
        app.st.gradStart = hit;
        return;
      }
      app.st.stroke = { from: hit, last: hit, painted: false };   // 画笔/橡皮/矩形/直线
    });
  });

  cv.addEventListener('pointermove', function (ev) {
    guard('pointermove', function () {
      if (app.st.panning) {
        var dxp = ev.clientX - app.st.panning.x, dyp = ev.clientY - app.st.panning.y;
        app.st.panning.x = ev.clientX; app.st.panning.y = ev.clientY;
        // ★ 视图入口返回分帧重建派生出来的 promise:必须交回 guard 收口(漏了就是"按了没反应"只在控制台留一行)。
        return Promise.resolve(app.r.panBy(dxp, dyp));
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
          app.st.stroke.painted = true;              // ★ 见 pointerup:单击也要落一次笔
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
      // ★★ 拖动分支:记录先取到局部变量再判 —— 没有在飞的记录就整支跳过(早退是承重的)。它挡两种
      //   "没有记录":① 本次按下起的是别的动作(框选/笔画),那两条分支在下面各管各的;② 这次拖动
      //   已经被 Esc 取消了(见 cancel-selection)—— 视觉上已取消,松手就一个格都不许搬。
      //   ★ sd 的字段必须排在判过 sd 之后才读:取消之后 sd 是 null,少了这层判会去读它的 dx(抛 TypeError)。
      var sd = app.st.selDrag;
      if (sd) {
        app.st.selDrag = null;
        app.r.setSelDrag(null, 0, 0);
        // ★ 选区可能已经没有了(Esc 走 cancel-selection,而左键还按着)⇒ 没有可搬的东西。
        var cur = app.r.selection();
        if (cur && (sd.dx !== 0 || sd.dy !== 0)) {
          pushAndShow(moveRegion(app.map, app.r.layer(), cur, sd.dx, sd.dy));
          // ★★ 存回去的选区必须折算:拖动跨过接缝时 cur.x + sd.dx 会落到 [0, subCols) 之外,而 regionCells
          //   是"先折算每一格、再 inRect(clip, wx, wy)"⇒ clip.x < 0 时一格都进不来:框内所有画笔/矩形/
          //   直线/油漆桶都产出空集合,而且一条状态栏消息都没有(用户在框里画,什么都不发生)。
          app.r.setSelection({ x: Render.wrapIdx(cur.x + sd.dx, app.map.subCols),
                               y: Render.wrapIdx(cur.y + sd.dy, app.map.subRows),
                               w: cur.w, h: cur.h });
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
          s1.rgba, s1.rgba2, { clip: s1.selection });   // ★ 两端各一色(不是同一个色)
        // ★★ 与「油漆桶填充」同一条理由(同一个 runJob 出口、丢掉 promise = 一次普通的失败换来一个假的崩溃提示)。
        guard('渐变', function () {
          return runJob(gj, function () {
            var res = gj.result(), targets = [], values = [], n = 0;
            for (var i = 0; i < res.length; i++) { targets.push(res[i].i); values.push(res[i].rgba); }
            pushAndShow(paintCells(app.map, Core.LAYER_BG, targets, function () { return values[n++]; }));
          }, '渐变');
        });
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
        } else if (!st0.painted) {
          // ★ 按下与松开之间没有 pointermove(单击)时,画笔/橡皮的落笔只在 pointermove 那条路上发生 ⇒
          //   一次单击什么都不画;而"拿画笔点一格"是最常见的编辑动作,必须同样有效。
          // ★ 判据取 painted 而不是"last 是否等于 from":pointermove 在同一格内也会落笔。
          pushAndShow(applyTool(stNow(), app.st.tool, st0.from, st0.from));
        }
      }
    });
  });

  cv.addEventListener('wheel', function (ev) {
    guard('wheel', function () {
      ev.preventDefault();
      var rect = cv.getBoundingClientRect();
      // ★ 视图入口的 promise 同样收口(见上面 pointermove 的说明)
      var zp = Promise.resolve(app.r.setZoomAt(ev.clientX - rect.left, ev.clientY - rect.top,
                                               ev.deltaY < 0 ? 1.25 : 0.8));
      statusLine();
      return zp;
    });
  }, { passive: false });

  window.addEventListener('keydown', function (ev) {
    // ★★ 焦点在输入控件里时一个键都不许拦:表里有 Backspace/Delete → clear-selection、0-9 → 切层、
    //   b/e/g/l/m/i → 换工具、方向键 → 平移。焦点在输入框里时这些键是打字:按 Backspace 会先被
    //   preventDefault(数字删不掉)再真去 erase 掉整个选区 —— 数据被改,而用户以为只是在删一个字符。
    if (isTypingTarget(ev.target)) return;
    // ★★ 空格(规格 §4.8)只有认领了这个键时才拦默认行为,而"认领"的判据就是上面那行早退
    //   (isTypingTarget):焦点在输入控件里时这里一步都不走,于是空格照旧是一个字符。
    // ★ 拦的是什么:空格是浏览器的向下翻页键,而 #right / #lib-list 都是 overflow:auto ⇒ 不拦的话,
    //   按下空格准备拖拽时右边栏先滚一屏;keyup 那一半同样要拦 —— 浏览器还会把空格当"按下当前聚焦的按钮"。
    if (ev.key === ' ') { spaceDown = true; ev.preventDefault(); return; }
    var cmd = commandFor(ev);
    if (!cmd) return;                                  // ★ 表外的键一律不拦
    guard('keydown', function () {
      ev.preventDefault();
      var pend = null;                                 // 视图入口交回的 promise(交给 guard 收口)
      if (cmd.indexOf('tool:') === 0) { app.st.tool = cmd.slice(5); selectToolButton(); }
      else if (cmd === 'brush-smaller') { setBrush(bumpBrush(app.st.brushSize, -1)); }
      else if (cmd === 'brush-bigger') { setBrush(bumpBrush(app.st.brushSize, 1)); }
      else if (cmd.indexOf('layer:') === 0) { setLayer(parseInt(cmd.slice(6), 10)); }
      else if (cmd === 'undo') pend = doUndo();
      else if (cmd === 'redo') pend = doRedo();
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
      else if (cmd.indexOf('mirror:') === 0) { pend = mirrorSelection(cmd.slice(7)); }
      else if (cmd === 'clear-selection') {
        var s3 = app.r.selection();
        if (!s3) { status('先框选一块'); return; }
        pushAndShow(applyTool({ map: app.map, layer: app.r.layer(), desc: 0, rgba: 0,
                                brushSize: 0.25, selection: s3 },
                              'rect', { kind: 'sub', x: s3.x, y: s3.y },
                              { kind: 'sub', x: s3.x + s3.w - 1, y: s3.y + s3.h - 1 }));
      }
      else if (cmd === 'cancel-selection') {
        // ★★ Esc 可能在拖动途中按下去(左键还按着、selDrag 还在飞)而照样合法:选区没了 ⇒ 没有可搬的
        //   东西,这次拖动整支作废。三件事一起做:① 清在飞的拖动记录(松手时 pointerup 的拖动分支因此
        //   根本不进 —— 它是"这一支拖动还算不算数"的唯一依据);② setSelDrag(null) 让渲染侧当场把烤过的
        //   两块按内容归位;③ 清选区。★ ① 必须排在最前,紧随其后的 pointermove/pointerup 判的正是它。
        app.st.selDrag = null;
        app.r.setSelDrag(null, 0, 0);
        app.r.setSelection(null);
      }
      else if (cmd.indexOf('pan:') === 0) { pend = arrowPan(cmd.slice(4)); }
      else if (cmd === 'save' || cmd === 'save-as') { pend = saveCurrent(cmd === 'save-as'); }
      statusLine();
      return pend;
    });
  });

  window.addEventListener('keyup', function (ev) {
    if (ev.key !== ' ') return;
    spaceDown = false;                  // ★ 清位与"认不认领"无关:键已经抬起来了
    if (isTypingTarget(ev.target)) return;
    ev.preventDefault();
  });
  window.addEventListener('blur', function () { spaceDown = false; });

  statusLine();
}
