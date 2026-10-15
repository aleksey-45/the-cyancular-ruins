'use strict';
// tests/server/40_api_read.js —— 相位 ⑥/⑦ 前半:/api/maps 列库 + /api/map 读 + PUT 原子写(413/500/目录/HEAD)。
globalThis.serverChain = globalThis.serverChain.then(async function () {
const fs = require('fs');
const path = require('path');
const srv = require('../../editor_server.js');
  // ==== 相位 ⑥ /api/maps + GET /api/map ====
  //   位置同理,必须在 runAllPhases() 里面。
  {
    const mapsDir = path.join(tmpRoot, 'maps');
    fs.mkdirSync(mapsDir, { recursive: true });
    fs.writeFileSync(path.join(mapsDir, 'b_second.cyrm'), Buffer.from([1, 2, 3, 4, 5]));
    fs.writeFileSync(path.join(mapsDir, 'a_first.cyrm'), Buffer.from([9, 9]));
    fs.writeFileSync(path.join(mapsDir, 'notes.txt'), 'not a map');
    fs.mkdirSync(path.join(mapsDir, 'sub.cyrm'), { recursive: true });
    fs.writeFileSync(path.join(mapsDir, 'sub.cyrm', 'keep.txt'), 'x');
    const logged = [];
    const apiSrv = track(await srv.startServer({
      rootDir: EDITOR_DIR, mapsDir: mapsDir, port: 0,
      logger: function (m) { logged.push(m); },
    }));

    eq(srv.listMaps(path.join(tmpRoot, 'no_such_dir'), null), [], 'listMaps: 目录不存在 = 空库,不抛错');

    const rm = await request(apiSrv.port, 'GET', '/api/maps');
    ok(rm.status === 200, 'GET /api/maps → 200');
    ok(/^application\/json/.test(String(rm.headers['content-type'])), 'GET /api/maps → application/json');
    const data = JSON.parse(rm.body.toString('utf8'));
    eq(data.maps.map(function (m) { return m.name; }), ['a_first.cyrm', 'b_second.cyrm'],
       '★ /api/maps: 只列合法且是文件的 .cyrm,按名字升序(notes.txt 与同名目录都不进来)');
    eq(data.maps[0].size, 2, '/api/maps: size = 文件字节数');
    ok(typeof data.maps[0].mtime === 'number' && data.maps[0].mtime > 0, '/api/maps: mtime 是数字');
        // ★ notes.txt 走的是「名字不过守卫」那条路径;同名目录(sub.cyrm)走的是另一条(名字合法、
        //   stat 也成功、只是不是文件)。一个原因一条断言,才钉得住"两种跳过都不静默"。
    ok(logged.some(function (m) { return m.indexOf('notes.txt') >= 0; }),
       '★ /api/maps: **名字不过守卫**而被跳过的文件点名记日志(绝不静默消失)');
    ok(logged.some(function (m) { return m.indexOf('sub.cyrm') >= 0; }),
       '★ /api/maps: **不是文件**(同名目录)而被跳过的**也**点名记日志 —— 这条路径待修 2 之前是静默 continue');

    const rg = await request(apiSrv.port, 'GET', '/api/map?p=b_second.cyrm');
    ok(rg.status === 200, 'GET /api/map → 200');
    ok(rg.headers['content-type'] === 'application/octet-stream', 'GET /api/map → octet-stream');
    sameBytes(rg.body, Buffer.from([1, 2, 3, 4, 5]), 'GET /api/map: 字节原样返回');
    ok(rg.headers['cache-control'] === 'no-store', 'GET /api/map → no-store');

    const r404 = await request(apiSrv.port, 'GET', '/api/map?p=nope.cyrm');
    ok(r404.status === 404, 'GET /api/map 不存在的名字 → 404');
    const rMiss = await request(apiSrv.port, 'GET', '/api/map');
    ok(rMiss.status === 400, 'GET /api/map 缺 p 参数 → 400');
    const rTrav = await request(apiSrv.port, 'GET', '/api/map?p=' + encodeURIComponent('../package.json'));
    ok(rTrav.status === 400, '★ GET /api/map 路径穿越名 → 400');
    ok(rTrav.body.toString('utf8').indexOf('"name"') < 0, '★ 那个 400 的正文里没有 package.json 的内容');
    const rTrav2 = await request(apiSrv.port, 'GET', '/api/map?p=' + encodeURIComponent('..%2fdemo.cyrm'));
    ok(rTrav2.status === 400, '★ GET /api/map 编码过的穿越名 → 400');
    const rPost = await request(apiSrv.port, 'POST', '/api/map?p=b_second.cyrm', Buffer.from([1]));
    ok(rPost.status === 405, 'POST /api/map → 405');
    const rMapsPost = await request(apiSrv.port, 'POST', '/api/maps', Buffer.from([1]));
    ok(rMapsPost.status === 405, 'POST /api/maps → 405');
  }
  // ==== 相位 ⑦ PUT /api/map 原子写 ====
  //   位置同理,必须在 runAllPhases() 里面。
  {
    const mapsDir = path.join(tmpRoot, 'maps');
    const readBack = function (n) { return fs.readFileSync(path.join(mapsDir, n)); };
    const noTmpLeft = function () {
      return fs.readdirSync(mapsDir).every(function (n) {
        return n.indexOf('.tmp') < 0;
      }) && fs.readdirSync(path.join(mapsDir, 'sub.cyrm')).every(function (n) {
        return n.indexOf('.tmp') < 0;
      });
    };
    // ★ 写端点只收 application/json(硬要求 A:CSRF,理由见相位末尾那一块)——
    //   所以本相位每一条合法的 PUT 都必须显式带上它。下面是它们的公共头。
    const PUT_JSON = { 'Content-Type': 'application/json' };
    const apiSrv = track(await srv.startServer({
      rootDir: EDITOR_DIR, mapsDir: mapsDir, port: 0,
    }));
    // 一个 maxMapBytes 很小的服务器,专门用来验 413 —— 不用真发 64MB。
    const smallSrv = track(await srv.startServer({
      rootDir: EDITOR_DIR, mapsDir: mapsDir, port: 0, maxMapBytes: 16,
    }));

    const put = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([7, 7, 7]), PUT_JSON);
    ok(put.status === 200, 'PUT 新文件 → 200(实得 ' + put.status + ')');
    eq(JSON.parse(put.body.toString('utf8')), { name: 'c_new.cyrm', size: 3 }, 'PUT 回 JSON {name,size}');
    sameBytes(readBack('c_new.cyrm'), Buffer.from([7, 7, 7]), 'PUT: 落盘字节与请求体一致');
    ok(noTmpLeft(), '★ PUT 之后没有残留临时文件');

    const put2 = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([1, 2, 3, 4]), PUT_JSON);
    ok(put2.status === 200, 'PUT 覆盖已有文件 → 200');
    sameBytes(readBack('c_new.cyrm'), Buffer.from([1, 2, 3, 4]), 'PUT: 覆盖后是新内容(不留尾巴)');

    // ── 反向:被拒的写绝不能动到已有文件 ──
    const before = readBack('c_new.cyrm');
    const rBadName = await request(apiSrv.port, 'PUT', '/api/map?p=' + encodeURIComponent('../evil.cyrm'),
                                   Buffer.from([0xEE]), PUT_JSON);
    ok(rBadName.status === 400, '★ PUT 路径穿越名 → 400');
    ok(!fs.existsSync(path.join(tmpRoot, 'evil.cyrm')), '★ PUT 没有在 maps/ 之外写出任何文件');
    const rEmpty = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.alloc(0), PUT_JSON);
    ok(rEmpty.status === 400, 'PUT 空请求体 → 400(不许用空内容覆盖地图)');
    const rBig = await request(smallSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.alloc(64, 1), PUT_JSON);
    ok(rBig.status === 413, '★ PUT 超过 maxMapBytes → 413(实得 ' + rBig.status + ')');
    sameBytes(readBack('c_new.cyrm'), before,
              '★★ 三种被拒的 PUT 之后,原文件逐字节没变');
    ok(noTmpLeft(), '被拒的 PUT 也没留临时文件');

    // ★ 写失败的清理路径:目标是一个非空目录 → rename 必失败 → 临时文件必须被删掉。
    const rDir = await request(apiSrv.port, 'PUT', '/api/map?p=sub.cyrm', Buffer.from([1, 2]), PUT_JSON);
    ok(rDir.status === 500, '★ PUT 目标是个目录 → 500(写失败,实得 ' + rDir.status + ')');
    ok(fs.statSync(path.join(mapsDir, 'sub.cyrm')).isDirectory() &&
       fs.existsSync(path.join(mapsDir, 'sub.cyrm', 'keep.txt')),
       '★ 写失败后那个目录连同里面的文件都还在(没有被毁掉)');
    ok(noTmpLeft(), '★★ 写失败后临时文件被清掉(否则每次失败都在 maps/ 里留垃圾)');

    // 头请求不能带 body(顺带验 HEAD 分支)
    const rHead = await request(apiSrv.port, 'HEAD', '/api/map?p=c_new.cyrm');
    ok(rHead.status === 200 && rHead.body.length === 0, 'HEAD /api/map → 200 且无正文');
}
});