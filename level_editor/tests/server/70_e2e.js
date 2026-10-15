'use strict';
// tests/server/70_e2e.js —— 相位 ⑨:端到端(encodeMap 的字节 → 服务器 → decodeMap 解回来)。
globalThis.serverChain = globalThis.serverChain.then(async function () {
const fs = require('fs');
const path = require('path');
const srv = require('../../editor_server.js');
  // ==== 相位 ⑨ 端到端:core.js 编出来的字节 → 服务器 → core.js 解回来 ====
// ★ 相位必须留在 serverChain 上(入口在 try 里 await 它):cleanup() 在 finally,
  //   挂在链外 = 相位跑在清理之后,会把已删掉的 tmpRoot 重新建出来。
  // ★ 号从 ⑨ 起(本文件里已经有两个 ⑤、两个 ⑧,都是有意为之,别去"修正")。
  // ★ 本相位是纯增量覆盖:它消费的接口(core.js 的 encodeMap/decodeMap/sanitizeName、
  //   服务器的 PUT/GET/列库)已由前面的相位覆盖,本相位只补"两半对得上"。
  {
    const loader = require('../../loader.js');
    loader.run(loader.moduleScripts('core'));
    const Core = globalThis.Core;
    // ★ 写端点只收 application/json(非简单内容类型 ⇒ 逼浏览器先发预检),不带头一律 415;故这里
    //   照相位 ⑦ 的先例显式带上(载荷是二进制的,这个类型只是个协议令牌,不代表 body 是 JSON)。
    const PUT_JSON = { 'Content-Type': 'application/json' };
    const mapsDir = path.join(tmpRoot, 'maps');
    const apiSrv = track(await srv.startServer({ rootDir: EDITOR_DIR, mapsDir: mapsDir, port: 0 }));

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
    const putE2E = await request(apiSrv.port, 'PUT', '/api/map?p=e2e.cyrm', Buffer.from(bytes), PUT_JSON);
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

// ★ v4 的 body 里没有 name 字段 —— 导入方必须自己用文件名补。
    eq(back.name, '', '★ decodeMap 返回的 name 是空串(v4 body 无 name 字段)');
    back.name = 'e2e';
    eq(Core.sanitizeName(back.name), 'e2e', '★ 用文件名补 map.name 之后 sanitizeName 不回落成 structure');
    eq(Core.sanitizeName(''), 'structure', '(对照)空名字才会回落成 structure');

    // 裸 body(compression=0)是一条完整可用的退路,也要能过服务器
    const raw = await Core.encodeMap(m, { compress: false });
    const putRaw = await request(apiSrv.port, 'PUT', '/api/map?p=e2e_raw.cyrm', Buffer.from(raw), PUT_JSON);
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
});