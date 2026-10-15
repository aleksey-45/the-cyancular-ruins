'use strict';
// 相位 ⑫:差量历史(步数/字节两道闸)/ 剪贴板 / 选区移动。
// ★ 判据全部是**行为**:push→undo→redo 的状态迁移、整图级条目的**解耦**、跨接缝的折算。
const Core = globalThis.Core;
const Editor = globalThis.Editor;
const Render = globalThis.Render;

module.exports = (async function () {

  // ── 差量历史(闸 1:200 步 + 字节预算)──
  const hist = Editor.createHistory({});
  eq(Editor.MAX_UNDO, 200, 'MAX_UNDO = 200(规格 §4.3 闸 1)');
  eq(Editor.MAX_UNDO_BYTES, 64 * 1024 * 1024,
     'MAX_UNDO_BYTES = 64MB(★ 出自**计划**:规格 §4.3 闸 1 只有「撤销步数 200(差量)」)');
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

  // 步数上限:第 N+1 步起把最老的挤掉
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

  // ★★ 默认**步数**上限必须真的在生效:上面那条走的是显式传 maxSteps:3 的历史,默认那一支
  //    一次都没跑到。默认值漏掉那个三元(写成 `opts.maxSteps`)时 `undos.length > undefined`
  //    恒 false ⇒ **完全没有上限**,而整个冒烟照样全绿。
  //    每条 mkDiff(1) 只 24 字节,201 条共 4824 字节 ⇒ 这里红就只能是步数闸的问题。
  const hdefSteps = Editor.createHistory({});
  for (let i = 0; i < 201; i++) hdefSteps.push(mkDiff(1));
  eq(hdefSteps.depth(), 200,
     '★★ 默认步数上限在生效:推 201 条(**不给 maxSteps**)后深度停在 200(实得 ' +
     hdefSteps.depth() + ' 条 / ' + hdefSteps.bytes() + ' 字节)');

  // ★★ 默认**预算**必须真的在生效(同上:上面那条走的是显式 maxBytes)。
  //    ★ 用**合成的** whole 条目(bytes 字段直接写字节数)而不是真分配 64MB:bytesOfEntry(whole)
  //      只读 `e.bytes`。★ 用**真的**快照(而不是 before/after: null):将来谁把 bytesOfEntry
  //      改成"从快照现算字节",null 会在 push 里炸成一次未捕获异常(后面的断言一行都跑不到),
  //      而真快照下它退化成一条**具名 FAIL** —— 测试要在重构下"红得可读"。
  const hdef = Editor.createHistory({});          // 不给 maxBytes ⇒ 应走 MAX_UNDO_BYTES
  const hdry = Core.createMap('hd', 2, 1);
  hdef.push({ kind: 'whole', tag: 'fake', bytes: Editor.MAX_UNDO_BYTES,
              before: Editor.snapshotMap(hdry), after: Editor.snapshotMap(hdry) });
  hdef.push(mkDiff(20));
  hdef.push(mkDiff(20));
  eq(hdef.depth(), 2, '★★ 默认字节预算在生效:超预算的 whole 条目被挤掉,只剩后两条(实得 ' +
     hdef.depth() + ' 条 / ' + hdef.bytes() + ' 字节)');

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

  // ★★ 整图级撤销之后地图必须与 entry 里的快照**解耦**(旧实现 `desc: lay.desc` 是 alias:
  //    撤销后再落一笔就写进了历史条目,下一次撤销恢复的是被污染的 before —— 且一个字都不报)。
  const hz = Core.createMap('z', 2, 1);
  hz.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(4);
  const zd = Editor.wholeDiff(hz, 'resize');
  const zsz = Editor.resizeMap(hz, 4, 3).map;
  hz.subCols = zsz.subCols; hz.subRows = zsz.subRows; hz.layers = zsz.layers;
  zd.seal();
  Editor.applyEntry(hz, zd.entry, -1);
  eq(hz.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4), '撤销改尺寸后内容回到 before');
  const zp = Editor.paintCells(hz, Core.LAYER_SCENE, [0], function () { return Core.neutralDesc(9); });
  ok(zp !== null, '撤销之后落笔产出差量(下面那条才有意义)');
  Editor.applyEntry(hz, zd.entry, -1);
  eq(hz.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4),
     '★★ 撤销改尺寸 → 落一笔 → 再撤销:地图回到**原始**状态,不是被污染的 before');

  // ★★ 快照拷贝的**另一半**:seal() 定格之后继续落笔,`entry.after` 不得跟着变。
  //    ★ 这里刻意**不夹 undo**:applyEntry 会把 map.layers 换成防御性拷贝,一旦换了,
  //      活数组与快照就脱钩了 —— 必须在"seal 完、还没撤销"这个窗口里落笔才测得准。
  const hq = Core.createMap('q', 2, 1);
  hq.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(4);
  const qd = Editor.wholeDiff(hq, 'resize');
  qd.seal();
  const qp = Editor.paintCells(hq, Core.LAYER_SCENE, [0], function () { return Core.neutralDesc(9); });
  ok(qp !== null, '★ seal() 之后仍能在地图上落笔(下面那条才有意义)');
  eq(qd.entry.after.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(4),
     '★★ seal() 之后落笔**没写进历史条目的 after 快照**(alias 实现下会变成 9 —— 重做会拿被污染的 after)');

  // ★★ 「字节预算管得住整图级」不能只靠"记了个正数"(bytesOfEntry 的 whole 分支退化成
  //    `return 64` 时,上面那条 `> 0` 照样绿)。两条:数值面(≥ before 快照)+ 行为面(真的挤掉)。
  ok(Editor.bytesOfEntry(wd.entry) >= Editor.bytesOfSnapshot(wd.entry.before),
     '★★ bytesOfEntry(whole) ≥ before 快照的字节量(实得 ' + Editor.bytesOfEntry(wd.entry) +
     ' ≥ ' + Editor.bytesOfSnapshot(wd.entry.before) + ')—— 记常数过不了这条');
  // wd 是 2×1 格建图、改成 4×3 格之后才 seal 的 ⇒ 两份快照不一样大:
  // before = 8×4×4×4 = 512,after = 16×12×4×4 = 3072,bytesOfEntry = 64+512+3072 = 3648。
  const hwb = Editor.createHistory({ maxBytes: 1000 });
  hwb.push(wd.entry);
  eq(hwb.depth(), 1, '★ 单条 whole 条目就超预算 ⇒ 只丢到"至少留一条"为止(实得 ' + hwb.depth() + ' 条)');
  ok(hwb.bytes() >= Editor.bytesOfSnapshot(wd.entry.before),
     '★★ 那一条在总账里按快照字节数记着(实得 ' + hwb.bytes() + ' 字节,至少要 ' +
     Editor.bytesOfSnapshot(wd.entry.before) + ')');
  const wd2 = Editor.wholeDiff(Core.createMap('w2', 2, 1), 'resize');
  wd2.seal();
  hwb.push(wd2.entry);
  eq(hwb.depth(), 1, '★★ 再来一条 whole 就把最老的挤掉(whole 的字节数真的参与闸门)');

  // ★★ 错误用法必须**看得见**:wholeDiff 没 seal() 就把 entry 推进历史 ⇒ 重做静默 no-op。
  const hbad = Core.createMap('bad', 2, 1);
  const badwd = Editor.wholeDiff(hbad, 'resize');     // ★ 故意不 seal()
  const wseen = [];
  Editor.setErrorSink(function (text) { wseen.push(String(text)); });
  Editor.applyEntry(hbad, badwd.entry, +1);           // 重做 —— after 快照不存在
  Editor.setErrorSink(null);
  ok(wseen.length === 1 && wseen[0].indexOf('重做无效') >= 0,
     '★★ seal() 之前就进历史的 whole 条目:重做时**上报**而不是静默 no-op(实得 ' + JSON.stringify(wseen) + ')');

  // spawn 差量能撤(审计 A9)
  const hsp = Core.createMap('s', 4, 3);
  const sd = Editor.addSpawn(hsp, 'player', 1, 1);
  eq(hsp.players.length, 1, '放了出生点');
  Editor.applyEntry(hsp, sd, -1);
  eq(hsp.players.length, 0, '★★ 撤销:出生点没了(A9 —— 出生点/敌人的增删必须在历史里)');
  Editor.applyEntry(hsp, sd, +1);
  eq(hsp.players.length, 1, '重做:出生点回来了');

  // 差量 → 格坐标列表(交给 renderer.editCells 作废)
  const mdk = Core.createMap('k', 2, 1);          // 8×4 子格:下标 0/5/6 落在 (0,0) 与 (1,0)
  const dk = Editor.paintCells(mdk, Core.LAYER_SCENE, [0, 5, 6], function () { return Core.neutralDesc(2); });
  eq(Editor.diffCells(mdk, dk).length, 2, '★ diffCells:下标 0/5/6 → 2 个不同的格(0,0) 与 (1,0)');
  eq(Editor.diffCells(mdk, dk)[0], { cx: 0, cy: 0 }, 'diffCells 的第一个是 (0,0)');
  eq(Editor.diffCells(mdk, dk)[1], { cx: 1, cy: 0 }, 'diffCells 的第二个是 (1,0)');

  // ── 剪贴板 ──
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

  // ── 选区移动(A1 的重写)──
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
    // ★★ 非法 axis 必须**当场拒绝并给出原因** —— 旧实现里没有任何一支命中 ⇒ 退化成恒等
    //    ⇒ 静默返回 null,与"镜像了一圈、内容恰好没变"**完全同形**。
    throws(function () {
      Editor.mirrorRegion(mi, Core.LAYER_SCENE, { x: 0, y: 0, w: 4, h: 4 }, 'x');
    }, '★★ 非法镜像轴:当场拒绝并给出原因(旧实现退化成恒等、静默回 null)', '镜像轴非法');
  })();

})();
