'use strict';
// tests/server/55_map_ops.js —— 相位 ⑦c:地图的**真动作**——改名(POST /api/map/rename)与删除(DELETE /api/map)。
// ★ 判据一律取"盘上发生了什么"(还能不能 GET 到、旧名字还在不在、字节变没变),不只看状态码:
//   一个只改内存 / 只回 200 的实现也能让状态码断言全绿。
globalThis.serverChain = globalThis.serverChain.then(async function () {
const fs = require('fs');
const path = require('path');
const srv = require('../../editor_server.js');

  const mapsDir = path.join(tmpRoot, 'maps');
  const disk = function (n) { return path.join(mapsDir, n); };
  const logs = [];
  const apiSrv = track(await srv.startServer({
    rootDir: EDITOR_DIR, mapsDir: mapsDir, port: 0,
    logger: function (m) { logs.push(m); },
  }));
  // 写端点(含这两个新动作)只收 application/json —— 与 PUT 同一条写闸,故每条合法请求都显式带上。
  const JSON_CT = { 'Content-Type': 'application/json' };
  const listNames = async function () {
    const r = await request(apiSrv.port, 'GET', '/api/maps');
    return JSON.parse(r.body.toString('utf8')).maps.map(function (m) { return m.name; });
  };
  const putMap = function (n, bytes) {
    return request(apiSrv.port, 'PUT', '/api/map?p=' + encodeURIComponent(n), Buffer.from(bytes), JSON_CT);
  };
  const noTmpLeft = function () {
    const inMaps = fs.readdirSync(mapsDir).every(function (n) { return n.indexOf('.tmp') < 0; });
    const inSub = fs.existsSync(path.join(mapsDir, 'sub.cyrm')) &&
                  fs.readdirSync(path.join(mapsDir, 'sub.cyrm')).every(function (n) { return n.indexOf('.tmp') < 0; });
    return inMaps && inSub;
  };

  // ==== ① 改名成功:盘上真的搬了家(不是"内存里改了个名")====
  {
    await putMap('m_old.cyrm', [1, 2, 3]);
    // ★ 请求形状照页面里的真实现(ui/90_open.js 的 serverRenameMapFile):POST + JSON 头 + body '{}'。
    //   本端点不读 body,但"未读 body"必须被排掉,否则响应之后 keep-alive 连接会被重置。
    const r = await request(apiSrv.port, 'POST',
                            '/api/map/rename?from=m_old.cyrm&to=m_new.cyrm',
                            Buffer.from('{}'), JSON_CT);
    ok(r.status === 200, '① 改名成功 → 200(实得 ' + r.status + ':' + r.body.toString('utf8').trim() + ')');
    eq(JSON.parse(r.body.toString('utf8')), { ok: true, name: 'm_new.cyrm' },
       '① 回包形状 = {ok:true,name:"<新名>"}');
    ok(!fs.existsSync(disk('m_old.cyrm')), '★★ ① 旧名字在盘上**真的没了**(不是留着一份)');
    ok(fs.existsSync(disk('m_new.cyrm')), '① 新名字在盘上出现了');
    sameBytes(fs.readFileSync(disk('m_new.cyrm')), Buffer.from([1, 2, 3]), '★ ① 改名不动内容:字节逐字一致');
    const gNew = await request(apiSrv.port, 'GET', '/api/map?p=m_new.cyrm');
    ok(gNew.status === 200, '① 改完之后 GET 新名 → 200');
    const gOld = await request(apiSrv.port, 'GET', '/api/map?p=m_old.cyrm');
    ok(gOld.status === 404, '★ ① 改完之后 GET 旧名 → 404(实得 ' + gOld.status + ')');
    const names = await listNames();
    ok(names.indexOf('m_new.cyrm') >= 0 && names.indexOf('m_old.cyrm') < 0,
       '★ ① /api/maps 里只剩新名(库列表与磁盘一致;实得 ' + names.join(',') + ')');
    ok(logs.some(function (m) { return m.indexOf('改名') >= 0 && m.indexOf('m_new.cyrm') >= 0; }),
       '① 改名被点名记日志(不是静默动作)');
    ok(noTmpLeft(), '① 改名之后 maps/ 里没有临时文件残留');
  }

  // ==== ② 目标已存在 → 409,**不覆盖** ====
  {
    await putMap('m_src.cyrm', [7, 7]);
    await putMap('m_taken.cyrm', [8, 8, 8]);
    const r = await request(apiSrv.port, 'POST',
                            '/api/map/rename?from=m_src.cyrm&to=m_taken.cyrm', null, JSON_CT);
    ok(r.status === 409, '★★ ② 目标已存在 → 409(不覆盖;实得 ' + r.status + ')');
    sameBytes(fs.readFileSync(disk('m_taken.cyrm')), Buffer.from([8, 8, 8]),
              '★★ ② 被拒之后目标文件逐字节没变(没有"改名顺手抹掉另一张图")');
    sameBytes(fs.readFileSync(disk('m_src.cyrm')), Buffer.from([7, 7]), '★ ② 源文件也还在、字节没变');
  }

  // ==== ③ 源不存在 → 404(且不凭空造出一个新文件)====
  {
    const r = await request(apiSrv.port, 'POST',
                            '/api/map/rename?from=nope_src.cyrm&to=m_ghost.cyrm', null, JSON_CT);
    ok(r.status === 404, '③ 源不存在 → 404(实得 ' + r.status + ')');
    ok(!fs.existsSync(disk('m_ghost.cyrm')), '★★ ③ 被拒之后没有凭空写出目标文件');
  }

  // ==== ④ 名字非法 / 缺参 → 400,且错误文本点名是哪一边 ====
  {
    const rFrom = await request(apiSrv.port, 'POST',
                                '/api/map/rename?from=' + encodeURIComponent('../evil.cyrm') +
                                '&to=m_ok.cyrm', null, JSON_CT);
    ok(rFrom.status === 400, '★ ④ from 是穿越名 → 400(实得 ' + rFrom.status + ')');
    ok(rFrom.body.toString('utf8').indexOf('from') >= 0,
       '★ ④ 那个 400 点名了**哪一边**非法(实得 ' + JSON.stringify(rFrom.body.toString('utf8').trim()) + ')');
    const rTo = await request(apiSrv.port, 'POST',
                              '/api/map/rename?from=m_new.cyrm&to=' + encodeURIComponent('a/b.cyrm'),
                              null, JSON_CT);
    ok(rTo.status === 400 && rTo.body.toString('utf8').indexOf('to') >= 0,
       '★ ④ to 非法 → 400 且点名 to(实得 ' + rTo.status + ':' +
       JSON.stringify(rTo.body.toString('utf8').trim()) + ')');
    const rMissFrom = await request(apiSrv.port, 'POST', '/api/map/rename?to=m_x.cyrm', null, JSON_CT);
    ok(rMissFrom.status === 400 && rMissFrom.body.toString('utf8').indexOf('from') >= 0,
       '★ ④ 缺 from → 400 且点名 from(实得 ' + rMissFrom.status + ': ' +
       JSON.stringify(rMissFrom.body.toString('utf8').trim()) + ')');
    const rMissTo = await request(apiSrv.port, 'POST', '/api/map/rename?from=m_new.cyrm', null, JSON_CT);
    ok(rMissTo.status === 400 && rMissTo.body.toString('utf8').indexOf('to') >= 0,
       '★ ④ 缺 to → 400 且点名 to(实得 ' + rMissTo.status + ')');
    const rSame = await request(apiSrv.port, 'POST',
                                '/api/map/rename?from=m_new.cyrm&to=m_new.cyrm', null, JSON_CT);
    ok(rSame.status === 400, '★ ④ from === to → 400(没有可改的东西;实得 ' + rSame.status + ')');
    ok(fs.existsSync(disk('m_new.cyrm')), '★ ④ 五条被拒之后源文件都还在');
  }

  // ==== ⑤ 写闸:类型 / 来源 —— 被拒的请求一个字节都不碰盘 ====
  {
    const rNoCt = await request(apiSrv.port, 'POST', '/api/map/rename?from=m_new.cyrm&to=m_hijack.cyrm');
    ok(rNoCt.status === 415, '★★ ⑤ 改名不带 Content-Type → 415(与 PUT 同一条写闸;实得 ' +
       rNoCt.status + ')');
    const rPlain = await request(apiSrv.port, 'POST', '/api/map/rename?from=m_new.cyrm&to=m_hijack.cyrm',
                                 Buffer.from([1]), { 'Content-Type': 'text/plain' });
    ok(rPlain.status === 415, '★ ⑤ 改名带 text/plain → 415(实得 ' + rPlain.status + ')');
    const rCross = await request(apiSrv.port, 'POST', '/api/map/rename?from=m_new.cyrm&to=m_hijack.cyrm',
                                 null, { 'Content-Type': 'application/json',
                                         Origin: 'http://evil.example.com' });
    ok(rCross.status === 403, '★★ ⑤ 跨源改名(Origin 是别的站)→ 403(实得 ' + rCross.status + ')');
    ok(fs.existsSync(disk('m_new.cyrm')) && !fs.existsSync(disk('m_hijack.cyrm')),
       '★★ ⑤ 四条被拒的改名之后:源文件还在、目标一个字节都没被造出来');
    const rDelNoCt = await request(apiSrv.port, 'DELETE', '/api/map?p=m_new.cyrm');
    ok(rDelNoCt.status === 415, '★★ ⑤ 删除不带 Content-Type → 415(实得 ' + rDelNoCt.status + ')');
    const rDelCross = await request(apiSrv.port, 'DELETE', '/api/map?p=m_new.cyrm',
                                    null, { 'Content-Type': 'application/json',
                                            Origin: 'http://evil.example.com' });
    ok(rDelCross.status === 403, '★★ ⑤ 跨源删除 → 403(实得 ' + rDelCross.status + ')');
    ok(fs.existsSync(disk('m_new.cyrm')), '★★ ⑤ 两条被拒的删除之后文件都还在');
  }

  // ==== ⑥ 方法闸 ====
  {
    const rGet = await request(apiSrv.port, 'GET', '/api/map/rename?from=a.cyrm&to=b.cyrm');
    ok(rGet.status === 405, '⑥ GET /api/map/rename → 405(实得 ' + rGet.status + ')');
    const rPut = await request(apiSrv.port, 'PUT', '/api/map/rename?from=a.cyrm&to=b.cyrm', null, JSON_CT);
    ok(rPut.status === 405, '⑥ PUT /api/map/rename → 405(实得 ' + rPut.status + ')');
    const rPostMap = await request(apiSrv.port, 'POST', '/api/map?p=m_new.cyrm', Buffer.from([1]), JSON_CT);
    ok(rPostMap.status === 405, '⑥ POST /api/map → 405(DELETE 只加在 /api/map 上,没有放宽别的方法;实得 ' +
       rPostMap.status + ')');
  }

  // ==== ⑦ 同名目录不是地图:404,且目录连内容都别动 ====
  {
    const rRenameDir = await request(apiSrv.port, 'POST',
                                     '/api/map/rename?from=sub.cyrm&to=m_dir_renamed.cyrm', null, JSON_CT);
    ok(rRenameDir.status === 404, '★ ⑦ 改名一个同名目录 → 404(它不是地图;实得 ' + rRenameDir.status + ')');
    const rDelDir = await request(apiSrv.port, 'DELETE', '/api/map?p=sub.cyrm', null, JSON_CT);
    ok(rDelDir.status === 404, '★ ⑦ 删除一个同名目录 → 404(实得 ' + rDelDir.status + ')');
    ok(fs.statSync(disk('sub.cyrm')).isDirectory() && fs.existsSync(path.join(mapsDir, 'sub.cyrm', 'keep.txt')),
       '★★ ⑦ 那个目录连同里面的文件都还在(没有毁掉别人的东西)');
  }

  // ==== ⑧ 删除:真删 ====
  {
    await putMap('m_del.cyrm', [4, 4, 4]);
    ok(fs.existsSync(disk('m_del.cyrm')), '⑧ 前置:要删的文件确实在盘上');
    const r = await request(apiSrv.port, 'DELETE', '/api/map?p=m_del.cyrm', null, JSON_CT);
    ok(r.status === 200, '⑧ 删除 → 200(实得 ' + r.status + ':' + r.body.toString('utf8').trim() + ')');
    eq(JSON.parse(r.body.toString('utf8')), { ok: true, deleted: 'm_del.cyrm' },
       '⑧ 回包形状 = {ok:true,deleted:"<名>"}');
    ok(!fs.existsSync(disk('m_del.cyrm')), '★★ ⑧ 文件在盘上**真的没了**(fs.unlink,不是只回 200)');
    const g = await request(apiSrv.port, 'GET', '/api/map?p=m_del.cyrm');
    ok(g.status === 404, '★ ⑧ 删完再 GET → 404(实得 ' + g.status + ')');
    const names = await listNames();
    ok(names.indexOf('m_del.cyrm') < 0, '★ ⑧ /api/maps 里也没有它了');
    ok(logs.some(function (m) { return m.indexOf('删除') >= 0 && m.indexOf('m_del.cyrm') >= 0; }),
       '⑧ 删除被点名记日志');
    const rAgain = await request(apiSrv.port, 'DELETE', '/api/map?p=m_del.cyrm', null, JSON_CT);
    ok(rAgain.status === 404, '★ ⑧ 再删一次 → 404(幂等地报"没有",不是 500;实得 ' + rAgain.status + ')');
    const rBad = await request(apiSrv.port, 'DELETE', '/api/map?p=' + encodeURIComponent('../evil.cyrm'),
                               null, JSON_CT);
    ok(rBad.status === 400, '★ ⑧ 删除穿越名 → 400,一个字节都不碰(实得 ' + rBad.status + ')');
    const rMiss = await request(apiSrv.port, 'DELETE', '/api/map', null, JSON_CT);
    ok(rMiss.status === 400, '★ ⑧ 删除缺 p 参数 → 400(实得 ' + rMiss.status + ')');
    ok(!fs.existsSync(path.join(tmpRoot, 'evil.cyrm')), '★ ⑧ maps/ 之外没有多出东西');
  }

  // ==== ⑨ 写路径的包含性闸对这两个端点同样生效(指向 maps/ 之外的联接)====
  // ★ 与 50_write_gates 的硬要求 B 同一件事,这里只补"新加的两个端点也过同一道闸"。
  {
    const outsideDir = path.join(tmpRoot, 'ops_outside');
    fs.mkdirSync(outsideDir, { recursive: true });
    const victim = path.join(outsideDir, 'victim2.cyrm');
    fs.writeFileSync(victim, Buffer.from('外部文件', 'utf8'));
    const linkName = 'link_ops.cyrm';
    const linkPath = disk(linkName);
    let linked = false;
    try { fs.symlinkSync(outsideDir, linkPath, 'junction'); linked = true; }
    catch (e) { console.log('  --    ⑨ 跳过(本环境建不了联接:' + errText(e) + ')'); }
    try {
      if (linked) {
        const rRen = await request(apiSrv.port, 'POST',
                                   '/api/map/rename?from=' + linkName + '&to=m_from_link.cyrm',
                                   null, JSON_CT);
        ok(rRen.status === 403, '★★ ⑨ 改名一个指向 maps/ 之外的联接 → 403(同一道包含性闸;实得 ' +
           rRen.status + ')');
        const rDel = await request(apiSrv.port, 'DELETE', '/api/map?p=' + linkName, null, JSON_CT);
        ok(rDel.status === 403, '★★ ⑨ 删除那个联接 → 403(fail closed;实得 ' + rDel.status + ')');
        ok(fs.existsSync(victim) && fs.existsSync(linkPath), '★ ⑨ 被拒之后外部文件与联接都还在');
      }
    } finally {
      try { if (fs.existsSync(linkPath)) fs.unlinkSync(linkPath); } catch (e) { /* 联接要用 rmdir 才删得掉 */ }
      try { if (fs.existsSync(linkPath)) fs.rmdirSync(linkPath); } catch (e) { /* 清不掉不该盖住真失败 */ }
    }
  }
});
