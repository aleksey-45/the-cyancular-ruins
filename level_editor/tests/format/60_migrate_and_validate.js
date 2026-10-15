'use strict';
// tests/format/60_migrate_and_validate.js —— 取角映射、v3→v4 迁移(含非对称象限)、
const Core = globalThis.Core;

module.exports = (async function () {
// ---- 取角映射(§2.2 的规范定义,游戏侧 shader 必须与此一致)----
(function () {
  eq(Core.subcellRender(0, 0), { dst: [0, 0, 16, 16], src: [0, 0, 8, 8] }, 'subcellRender: 格内 (0,0)');
  eq(Core.subcellRender(3, 0), { dst: [48, 0, 16, 16], src: [24, 0, 8, 8] }, 'subcellRender: 格内 (3,0)');
  eq(Core.subcellRender(0, 3), { dst: [0, 48, 16, 16], src: [0, 24, 8, 8] }, 'subcellRender: 格内 (0,3)');
  eq(Core.subcellRender(4, 4), { dst: [64, 64, 16, 16], src: [0, 0, 8, 8] }, 'subcellRender: 象限按 X%4 循环');
  eq(Core.subcellRender(7, 5), { dst: [112, 80, 16, 16], src: [24, 8, 8, 8] }, 'subcellRender: 第二格右下');

  // ★ 迁移正确性的全部依据:v3 的 32px 象限 ↔ v4 的 2×2 个 16px 子格,目标矩形与源矩形都必须精确铺满(尺寸相等 + 包围盒相等 ⇒ 不重不漏)。
  function v3QuadrantRender(cellX, cellY, qx, qy) {
    return { dst: [cellX * 64 + qx * 32, cellY * 64 + qy * 32, 32, 32],
             src: [qx * 16, qy * 16, 16, 16] };
  }
  function quadrantEquivalent(cellX, cellY, qx, qy) {
    var o = v3QuadrantRender(cellX, cellY, qx, qy);
    var dMinX = Infinity, dMinY = Infinity, dMaxX = -Infinity, dMaxY = -Infinity, dArea = 0;
    var sMinX = Infinity, sMinY = Infinity, sMaxX = -Infinity, sMaxY = -Infinity;
    for (var dy = 0; dy < 2; dy++) {
      for (var dx = 0; dx < 2; dx++) {
        var s = Core.subcellRender(cellX * 4 + qx * 2 + dx, cellY * 4 + qy * 2 + dy);
        dArea += s.dst[2] * s.dst[3];
        dMinX = Math.min(dMinX, s.dst[0]); dMinY = Math.min(dMinY, s.dst[1]);
        dMaxX = Math.max(dMaxX, s.dst[0] + s.dst[2]); dMaxY = Math.max(dMaxY, s.dst[1] + s.dst[3]);
        sMinX = Math.min(sMinX, s.src[0]); sMinY = Math.min(sMinY, s.src[1]);
        sMaxX = Math.max(sMaxX, s.src[0] + s.src[2]); sMaxY = Math.max(sMaxY, s.src[1] + s.src[3]);
      }
    }
    return dArea === o.dst[2] * o.dst[3] &&
           dMinX === o.dst[0] && dMinY === o.dst[1] &&
           dMaxX === o.dst[0] + o.dst[2] && dMaxY === o.dst[1] + o.dst[3] &&
           sMinX === o.src[0] && sMinY === o.src[1] &&
           sMaxX === o.src[0] + o.src[2] && sMaxY === o.src[1] + o.src[3];
  }
  // ★ 累积成一个布尔量时失败只知道"错了":故把首个失败组合记进消息(这条断言是关键证明,失败必须可诊断)。
  var eqAll = true, firstBad = null;
  for (var cx = 0; cx < 3; cx++) for (var cy = 0; cy < 3; cy++)
    for (var qx = 0; qx < 2; qx++) for (var qy = 0; qy < 2; qy++)
      if (eqAll && !quadrantEquivalent(cx, cy, qx, qy)) {
        eqAll = false;
        firstBad = 'cx=' + cx + ' cy=' + cy + ' qx=' + qx + ' qy=' + qy;
      }
  ok(eqAll, '★ 取角等价:v3 的每个象限都能被 v4 的 2×2 子格精确铺满(3×3 格 × 4 象限全查)'
            + (firstBad === null ? '' : ' —— 首个失败组合:' + firstBad));
})();

// ---- v3 → v4 迁移 ----
await (async function () {
  var v3 = '# cyrm-v3\n# demo\n# player 1 1\n0000001F0031\n000000000000\n';
  var p = Core.parseV3Text(v3);
  var m = Core.migrateV3(p);

  eq(m.subCols, p.cellsW * 4, 'migrateV3: subCols = 格数×4');
  eq(m.subRows, p.cellsH * 4, 'migrateV3: subRows = 格数×4');
  eq(m.comments, ['demo'], 'migrateV3: 注释带过来');
  eq(m.players, [{ x: 1, y: 1 }], 'migrateV3: 出生点带过来(坐标不缩放)');
  // ★ migrateV3 里 map.enemies = parsed.enemies.map(…) 那行此前零覆盖(type 写丢或坐标被缩放都不会红),单起一格样本钉住它。
  var em = Core.migrateV3(Core.parseV3Text('# cyrm-v3\n# enemy jump_bird 100 50\n001F\n'));
  eq(em.enemies, [{ type: 'jump_bird', x: 100, y: 50 }],
     'migrateV3: 敌人带过来(type 保留、坐标不缩放)');
  eq(m.layers[Core.LAYER_FRONT].desc.some(function (v) { return v !== 0; }), false, 'migrateV3: 前景层留空');
  eq(m.layers[Core.LAYER_BACK].desc.some(function (v) { return v !== 0; }), false, 'migrateV3: 后景层留空');
  eq(m.layers[Core.LAYER_BG].rgba.some(function (v) { return v !== 0; }), false, 'migrateV3: 背景层留空(全透明黑)');

  var scene = m.layers[Core.LAYER_SCENE].desc;
  var brick = Core.neutralDesc(1);
  // 格 (1,0) 的 packed = 31 = 纹理1 全砖 → 该格 16 个子格全是 brick
  for (var dy = 0; dy < 4; dy++) {
    for (var dx = 0; dx < 4; dx++) {
      eq(scene[(0 * 4 + dy) * m.subCols + (1 * 4 + dx)], brick,
         'migrateV3: 全砖格 (1,0) 的子格 (' + dx + ',' + dy + ') 填满纹理1 中性');
    }
  }
  // 格 (2,0) 的 packed = 49 = 纹理3 shape 1(仅左上 1/4)→ 只有子格 (0,0),(1,0),(0,1),(1,1) 被填
  var g3 = 3;
  var t3 = Core.neutralDesc(g3);
  eq(scene[(0 * 4 + 0) * m.subCols + (2 * 4 + 0)], t3, 'migrateV3: 1/4 砖格 → 子格(0,0) 有纹理3');
  eq(scene[(0 * 4 + 0) * m.subCols + (2 * 4 + 1)], t3, 'migrateV3: 1/4 砖格 → 子格(1,0) 有纹理3');
  eq(scene[(0 * 4 + 1) * m.subCols + (2 * 4 + 0)], t3, 'migrateV3: 1/4 砖格 → 子格(0,1) 有纹理3');
  eq(scene[(0 * 4 + 1) * m.subCols + (2 * 4 + 1)], t3, 'migrateV3: 1/4 砖格 → 子格(1,1) 有纹理3');
  eq(scene[(0 * 4 + 0) * m.subCols + (2 * 4 + 2)], 0, 'migrateV3: 1/4 砖格 → 子格(2,0) 是空气');
  eq(scene[(0 * 4 + 2) * m.subCols + (2 * 4 + 0)], 0, 'migrateV3: 1/4 砖格 → 子格(0,2) 是空气');
  eq(scene[(0 * 4 + 3) * m.subCols + (2 * 4 + 3)], 0, 'migrateV3: 1/4 砖格 → 子格(3,3) 是空气');

  // 全空行不留任何东西
  var occupied = 0;
  for (var i = 0; i < scene.length; i++) if (scene[i] !== 0) occupied++;
  eq(occupied, 16 + 4, 'migrateV3: 非空子格总数 = 一整格(16) + 1/4 格(4)');

  // 旧字母格式也能一路迁到底
  var oldMap = Core.migrateV3(Core.parseV3Text('# old\n11\n11\n'));
  eq(oldMap.layers[Core.LAYER_SCENE].desc.length, 16, 'migrateV3: 旧格式迁移后尺寸');
  eq(oldMap.layers[Core.LAYER_SCENE].desc[0], Core.neutralDesc(1), 'migrateV3: 旧格式全砖格');

  // 迁移出来的图必须能原样过整文件往返
  var bytes = await Core.encodeMap(m);
  var back = await Core.decodeMap(bytes);
  eq(Array.prototype.slice.call(back.layers[Core.LAYER_SCENE].desc),
     Array.prototype.slice.call(m.layers[Core.LAYER_SCENE].desc), 'migrateV3: 迁移结果可二进制往返');
  eq(back.comments, ['demo'], 'migrateV3: 往返后注释仍是 demo(标记行没被当成注释)');
})();

// ---- migrateV3:非对称象限的位序与展开方向(规格 §3.6「必须写死」)----
  // ★ 上面那批样本对位序不敏感(shape 15 填满四格,与象限顺序无关;shape 1 的象限又是唯一在转置下不变的),于是把 1 << (qy*2+qx) 写成 1 << (qx*2+qy)、或把展开处的 X/Y 对调,整份冒烟仍然全绿,而每张导入图的每个非对称象限整体转 90°(静默错位)。
  //   取角等价那条断言帮不上忙:它硬编码了 cellX*4+qx*2+dx,从不调用 migrateV3。
  //   故用非对称形状逐个钉死 bit → 子格位置:bit(qy*2+qx) 为 1 → X∈[2qx,2qx+1]、Y∈[2qy,2qy+1];# = 纹理2 中性、. = 空气、? = 非空气但纹理不对(填错纹理与填错位置一样会红)。
(function () {
  var SAMPLES = [
    ['1', '左上/bit0 (qx0,qy0)', ['##..', '##..', '....', '....']],
    ['2', '右上/bit1 (qx1,qy0)', ['..##', '..##', '....', '....']],
    ['4', '左下/bit2 (qx0,qy1)', ['....', '....', '##..', '##..']],
    ['8', '右下/bit3 (qx1,qy1)', ['....', '....', '..##', '..##']],
  ];
  SAMPLES.forEach(function (s) {
    var m = Core.migrateV3(Core.parseV3Text('# cyrm-v3\n002' + s[0] + '\n'));
    var sc = m.layers[Core.LAYER_SCENE].desc, cols = m.subCols;
    var t = Core.neutralDesc(2);
    var got = [];
    for (var Y = 0; Y < 4; Y++) {
      var row = '';
      for (var X = 0; X < 4; X++) row += (sc[Y * cols + X] === 0 ? '.'
                                       : (sc[Y * cols + X] === t ? '#' : '?'));
      got.push(row);
    }
    eq(got, s[2], 'migrateV3: shape ' + s[0] + '(' + s[1] + ')的子格图案(4×4 全查,'
                + '位序 bit(qy*2+qx) 与展开方向同时被钉住)');
  });
})();

// ---- validateMap ----
(function () {
  var good = Core.createMap('ok', 8, 8);
  good.layers[Core.LAYER_SCENE].desc[0] = Core.neutralDesc(1);
  good.players = [{ x: 1, y: 1 }];
  var v = Core.validateMap(good);
  eq(v.errors, [], 'validateMap: 正常图无 error');
  // ★★ warnings 的**反面**:此前一条"不该有"的断言都没有 ⇒ 谓词改成"永远实心"也全绿(实测);规矩图必须一条 warning 都不给。
  eq(v.warnings, [], 'validateMap: 一张规规矩矩的图不该有任何 warning(无条件报警的实现在这里红)');

  // 出生点落在实心格里
  var inWall = Core.createMap('bad', 8, 8);
  var sc = inWall.layers[Core.LAYER_SCENE].desc;
  // ★ 判据要求该格 4×4 子格全非空:按行主序填前 16 个子格只铺满 (0,0) 格的顶行 ⇒ 恒不产生 warning(空转),故按格内 4×4 逐个填。
  for (var dy = 0; dy < 4; dy++) {
    for (var dx = 0; dx < 4; dx++) sc[dy * inWall.subCols + dx] = Core.neutralDesc(1);
  }
  inWall.players = [{ x: 0, y: 0 }];
  // ★ 判据钉 实心 而不是 出生点:后者任何出生点相关的 warning 都满足,今天能过纯粹因为 (0,0) 恰好没越界。
  ok(Core.validateMap(inWall).warnings.some(function (s) { return s.indexOf('实心') >= 0; }),
     'validateMap: 出生点在实心格里给 warning');
  // ★ 判据**两侧**都要钉:整格 4×4 全填才算实心 —— 只填 3 行 / 1 行都不许报(阈值放宽成"有子格就算"的实现在这里红)。
  var solidWarned = function (rows) {
    var m = Core.createMap('half', 8, 8);
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < 4; x++) m.layers[Core.LAYER_SCENE].desc[y * m.subCols + x] = Core.neutralDesc(1);
    }
    m.players = [{ x: 0, y: 0 }];
    return Core.validateMap(m).warnings.some(function (s) { return s.indexOf('实心') >= 0; });
  };
  eq(solidWarned(3), false, 'validateMap: 只填 3 行子格不算实心(谓词两侧都钉)');
  eq(solidWarned(1), false, 'validateMap: 只填 1 行子格不算实心(阈值放宽成"填 1 行就算"的实现在这里红)');

  // 一个出生点都没有
  var noSpawn = Core.createMap('n', 8, 8);
  ok(Core.validateMap(noSpawn).warnings.some(function (s) { return s.indexOf('出生点') >= 0; }),
     'validateMap: 没有出生点给 warning');

  // 第 3 个及以后的出生点游戏读不到(审计 A3)
  var three = Core.createMap('t', 8, 8);
  three.players = [{ x: 1, y: 1 }, { x: 2, y: 2 }, { x: 3, y: 3 }];
  ok(Core.validateMap(three).warnings.some(function (s) { return s.indexOf('第 3 个') >= 0; }),
     'validateMap: >2 个出生点给 warning');

  // 敌人坐标越界(改尺寸后的残留,审计 A10)
  var oob = Core.createMap('o', 8, 8);
  oob.players = [{ x: 1, y: 1 }];
  oob.enemies = [{ type: 'fly_bird', x: 99, y: 0 }];
  ok(Core.validateMap(oob).warnings.some(function (s) { return s.indexOf('越界') >= 0; }),
     'validateMap: 敌人坐标越界给 warning');

  // 四层全空
  var blank = Core.createMap('b', 8, 8);
  blank.players = [{ x: 1, y: 1 }];
  ok(Core.validateMap(blank).warnings.some(function (s) { return s.indexOf('空') >= 0; }),
     'validateMap: 四层全空给 warning');

})();

// ---- encodeMap 必须自己校验(指令 A3)----
// ★ decodeMap 在尺寸/图层长度上很严格,而 encodeMap 此前一处校验都没有 ⇒ 一张 subCols 非 4 倍数的图能编码成功,产出的文件连本编辑器都读不回来("导出后再也导不回来")。
// ★ 同时钉住反向:只有 warnings 时不许拒导出 —— 规格 §4.7 明说校验只报告不阻止。
await (async function () {
  // ① errors 非空 ⇒ reject(两条导出路径都要)
  var bad = Core.createMap('bad', 8, 8);
  bad.players = [{ x: 1, y: 1 }];
  bad.subCols = 30;                                    // 非 4 的倍数
  ok(Core.validateMap(bad).errors.length > 0,
     'A3: 前提 —— 这张图 validateMap 确实有 error(否则下面两条验的不是这件事)');
  await rejects(function () { return Core.encodeMap(bad); },
    'A3: encodeMap: 有 error 的地图必须 reject,而不是产出读不回来的文件', '校验未通过');
  await rejects(function () { return Core.encodeMap(bad, { compress: false }); },
    'A3: encodeMap: 不压缩路径同样要拒(校验在两条路径之前,不分叉)', '校验未通过');

  // ② 图层长度不符(另一条 error 分支)
  var badLen = Core.createMap('bad', 8, 8);
  badLen.players = [{ x: 1, y: 1 }];
  badLen.layers[Core.LAYER_SCENE].desc = new Uint32Array(16);   // 8×8 格应是 32×32 = 1024 子格
  ok(Core.validateMap(badLen).errors.length > 0, 'A3: 前提 —— 图层长度不符也是 error');
  await rejects(function () { return Core.encodeMap(badLen); },
    'A3: encodeMap: 图层长度不符也必须 reject', '校验未通过');

  // ③ 只有 warnings 时必须照常导出(「只拒 errors」的那一半)
  var warnOnly = Core.createMap('warn', 8, 8);          // 无出生点 + 四层全空 = 2 条 warning
  var wv = Core.validateMap(warnOnly);
  eq(wv.errors.length, 0, 'A3: 前提 —— 这张图没有 error');
  ok(wv.warnings.length >= 2, 'A3: 前提 —— 这张图确有 warning(' + wv.warnings.length + ' 条)');
  var wEnc = await Core.encodeMap(warnOnly, { compress: false });
  var wBack = await Core.decodeMap(wEnc);
  eq(wBack.subCols, warnOnly.subCols, 'A3: 只有 warnings 的地图照常导出(warnings 不阻止导出)');
  eq(wBack.subRows, warnOnly.subRows, 'A3: 只有 warnings 的地图照常导出(subRows)');

  // ★ 上面那两张图 encodeBody 自己也会抛(尺寸与图层长度对不上),证明不了这道校验是必须的;这里手工构造一张自洽的图:subCols 非 4 的倍数而每层数组长度恰好 = subCols×subRows ⇒ encodeBody 一路成功,产出的文件头 sub_cols = 6 却被 decodeMap 当场拒收。
  //   这正是要堵的洞:不加校验就会安静地写出一份自己读不回来的 .cyrm。
  var odd = Core.createMap('odd', 8, 8);
  odd.subCols = 6;                                       // 6 不是 SUB_PER_CELL(4)的倍数
  var oddN = odd.subCols * odd.subRows;                  // 6×32 = 192
  odd.layers[0].desc = new Uint32Array(oddN);
  odd.layers[1].desc = new Uint32Array(oddN);
  odd.layers[2].desc = new Uint32Array(oddN);
  odd.layers[3].rgba = new Uint32Array(oddN);
  odd.players = [{ x: 1, y: 1 }];
  var ov = Core.validateMap(odd);
  eq(ov.errors.length > 0, true, 'A3: 前提 —— 自洽的非 4 倍数尺寸图确有 error');
  eq(ov.errors.some(function (s) { return s.indexOf('倍数') >= 0; }), true,
     'A3: 前提 —— 那条 error 正是尺寸非 4 的倍数(图层长度对得上,所以只有这一条)');
  await rejects(function () { return Core.encodeMap(odd, { compress: false }); },
    'A3: 自洽的非 4 倍数尺寸图必须 reject 而不是安静地写出读不回来的文件(变异:去掉校验即红)',
    '校验未通过');
})();

})();
