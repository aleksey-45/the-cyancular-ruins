'use strict';
// tests/server/50_write_gates.js —— 相位 ⑦ 后半:硬要求 A(CSRF:只收 JSON、不答 CORS)与硬要求 B(符号链接 realpath)。
globalThis.serverChain = globalThis.serverChain.then(async function () {
const fs = require('fs');
const path = require('path');
const srv = require('../../editor_server.js');
// ⑦ 的外层块在 40_api_read.js 里收尾,这里有它自己的那四个局部助手(同一份 maps/)。
const mapsDir = path.join(tmpRoot, 'maps');
const readBack = function (n) { return fs.readFileSync(path.join(mapsDir, n)); };
const noTmpLeft = function () {
  return fs.readdirSync(mapsDir).every(function (n) { return n.indexOf('.tmp') < 0; }) &&
         fs.readdirSync(path.join(mapsDir, 'sub.cyrm')).every(function (n) { return n.indexOf('.tmp') < 0; });
};
const PUT_JSON = { 'Content-Type': 'application/json' };
const apiSrv = track(await srv.startServer({ rootDir: EDITOR_DIR, mapsDir: mapsDir, port: 0 }));
    // ── ★★ 硬要求 A:CSRF —— 写端点只收 application/json,且一个 CORS 头都不答 ──
    // ★ Host 白名单闸挡的是 DNS rebinding;它挡不住这一类:恶意页面直接
    {
      const beforeA = readBack('c_new.cyrm');
      // ① 简单请求的经典内容类型。★ 它本身不是"简单方法"(PUT 不在 CORS 安全方法名单里),这条钉的是类型闸本身。
      const rPlain = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([0xDE, 0xAD]),
                                   { 'Content-Type': 'text/plain' });
      ok(rPlain.status === 415,
         '★★ 硬要求 A:Content-Type: text/plain(简单请求的组合)→ 415 拒绝(实得 ' + rPlain.status + ')');
      const rNoCt = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([0xDE, 0xAD]));
      ok(rNoCt.status === 415, '★ 硬要求 A:不带 Content-Type → 415(实得 ' + rNoCt.status + ')');
      // ③ Origin 是别的站 → 403。跨源的非简单请求一定会带 Origin。
      const rCross = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([0xDE, 0xAD]),
                                   { 'Content-Type': 'application/json', Origin: 'http://evil.example.com' });
      ok(rCross.status === 403,
         '★ 硬要求 A:Origin 是别的站(类型对、来源错)→ 403(实得 ' + rCross.status + ')');
// ★ 这条刻意不带 Origin
      const rSite = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([0xDE, 0xAD]),
                                  { 'Content-Type': 'application/json', 'Sec-Fetch-Site': 'cross-site' });
      ok(rSite.status === 403,
         '★ 硬要求 A:没有 Origin、而 Sec-Fetch-Site: cross-site → 403(兜底那道)(实得 ' +
         rSite.status + ')');
      sameBytes(readBack('c_new.cyrm'), beforeA,
                '★★ 硬要求 A:四条被拒的跨源 / 非 JSON PUT 之后,原文件逐字节没变');
      ok(noTmpLeft(), '★ 硬要求 A:被拒的跨源 PUT 也没留临时文件');

      // ⑤ 预检本身:浏览器发的 OPTIONS 必须拿不到任何 Access-Control-* 头 ——
      const rOpt = await request(apiSrv.port, 'OPTIONS', '/api/map?p=c_new.cyrm', null,
                                 { Origin: 'http://evil.example.com',
                                   'Access-Control-Request-Method': 'PUT',
                                   'Access-Control-Request-Headers': 'content-type' });
      const corsKeys = Object.keys(rOpt.headers).filter(function (h) { return h.indexOf('access-control-') === 0; });
      ok(corsKeys.length === 0,
         '★★ 硬要求 A:跨源预检(OPTIONS)一个 Access-Control-* 头都不答(实得 status=' + rOpt.status +
         ', ' + (corsKeys.length ? corsKeys.join(',') : '无 CORS 头') + ')');

      // ④b ★ 防误伤自己人:编辑器可以从 localhost 或 127.0.0.1 任一个名字打开,而按 Fetch
      const rLoop = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([4, 4]),
                                  { 'Content-Type': 'application/json',
                                    Origin: 'http://localhost:' + apiSrv.port,
                                    'Sec-Fetch-Site': 'cross-site' });
      ok(rLoop.status === 200,
         '★★ 硬要求 A:Origin 是回环的另一个名字(localhost)+ Sec-Fetch-Site: cross-site → 放行' +
         '(Origin 是主闸,别用"同站"判自家页面)(实得 ' + rLoop.status + ')');
      const rLoop2 = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([4, 4]),
                                   { 'Content-Type': 'application/json',
                                     Origin: 'http://127.0.0.1:' + apiSrv.port });
      ok(rLoop2.status === 200,
         '★ 硬要求 A:Origin: http://127.0.0.1:<实际端口>(浏览器在非简单请求上一定会带)→ 放行' +
         '(实得 ' + rLoop2.status + ')');

      // ⑥ 那条成功的 PUT 也不许带 CORS 头(带了 = 跨源读得到响应体,把读端点也拖下水)。
      const rOkA = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([5, 5]), PUT_JSON);
      ok(rOkA.status === 200 && rOkA.headers['access-control-allow-origin'] === undefined,
         '★ 硬要求 A:同源 PUT 照常 200、且响应里没有 Access-Control-Allow-Origin(实得 ' +
         rOkA.status + ')');
      const rCharset = await request(apiSrv.port, 'PUT', '/api/map?p=c_new.cyrm', Buffer.from([6, 6]),
                                     { 'Content-Type': 'application/json; charset=utf-8' });
      ok(rCharset.status === 200,
         '★ 硬要求 A:application/json; charset=utf-8 照收(否则自家 fetch 会被自己挡掉)(实得 ' +
         rCharset.status + ')');
      sameBytes(readBack('c_new.cyrm'), Buffer.from([6, 6]), '★ 硬要求 A:带参数的 JSON 类型确实写进去了');
      // ⑧ 那个"简单请求"的真实攻击形态:POST + text/plain + 跨源 Origin —— 它不预检、会被浏览器直接发出去,而本端点只收 PUT。
      const rSimple = await request(apiSrv.port, 'POST', '/api/map?p=c_new.cyrm', Buffer.from([0xDE, 0xAD]),
                                    { 'Content-Type': 'text/plain', Origin: 'http://evil.example.com' });
      ok(rSimple.status === 405,
         '★ 硬要求 A:简单请求的真实形态(POST + text/plain + 跨源 Origin)→ 405(实得 ' +
         rSimple.status + ')');
      sameBytes(readBack('c_new.cyrm'), Buffer.from([6, 6]), '★ 硬要求 A:那条简单请求也没动到文件');
    }

    // ── ★★ 硬要求 B:符号链接 —— 写端点必须按真实路径再判一次包含性 ──
    // ★ 现有两道闸(裸文件名正则 + mapPathFor 里的字符串包含性)判的都是路径字符串,而 stat/writeFile 会跟随符号链接。
    {
      const outsideDir = path.join(tmpRoot, 'outside');
      fs.mkdirSync(outsideDir, { recursive: true });
      const victimPath = path.join(outsideDir, 'victim.cyrm');
      const victimBytes = Buffer.from('★ maps/ 之外的文件 —— 写端点一个字节都不许碰它', 'utf8');
      fs.writeFileSync(victimPath, victimBytes);
      const linkName = 'link_out.cyrm';
      const linkPath = path.join(mapsDir, linkName);

      // ① 守卫本体(与"能不能建链接"无关的那一半):目标经 realpath 后落在 maps/ 之外 → 必须抛。
      //    ★ 断言必须同时判错在哪:只判"有没有抛"是假绿 —— 守卫不存在时抛出的 TypeError 一样算通过。
      let guardErr = null;
      try { srv.assertWriteTargetInside(mapsDir, victimPath, linkName); } catch (e) { guardErr = e; }
      ok(guardErr !== null && errText(guardErr).indexOf('maps 目录之外') >= 0,
         '★ 硬要求 B 守卫本体:目标真实路径落在 maps/ 之外 → 抛错并点名原因(实得:' +
         (guardErr === null ? '(未抛错)' : errText(guardErr)) + ')');
      sameBytes(fs.readFileSync(victimPath), victimBytes,
                '★ 硬要求 B:那次调用(它只是判,不写)之后外部文件仍逐字节未变');

      // ② 端到端:在 maps/ 里造一个指向外部的链接,PUT 它必须被拒。
      //    ★ 本机(Windows、非管理员)建不了文件符号链接(EPERM —— 需要 SeCreateSymbolicLinkPrivilege
      let linked = false;
      try { fs.symlinkSync(outsideDir, linkPath, 'junction'); linked = true; }
      catch (e) { console.log('  --    硬要求 B 跳过(端到端那两条):本环境建不了符号链接/联接(' + errText(e) + ')'); }
      try {
        if (linked) {
          ok(fs.lstatSync(linkPath).isSymbolicLink(),
             '硬要求 B 前置:' + linkName + ' 确实是一个链接(不是普通文件)');
          ok(fs.realpathSync(linkPath) === fs.realpathSync(outsideDir),
             '硬要求 B 前置:它的**真实路径**落在 maps/ 之外(' + fs.realpathSync(linkPath) + ')');
          const rLink = await request(apiSrv.port, 'PUT', '/api/map?p=' + linkName, Buffer.from([0xAA, 0xBB]),
                                      PUT_JSON);
          ok(rLink.status === 403,
             '★★ 硬要求 B:PUT 一个指向 maps/ 之外的链接 → 403 拒绝(实得 ' + rLink.status +
             ';若实得 500 说明它是走到 rename 才失败的,那就不是 realpath 闸挡的)');
          sameBytes(fs.readFileSync(victimPath), victimBytes,
                    '★★ 硬要求 B:那个外部文件逐字节未变(被拒的写一个字节都没落盘)');
          ok(fs.existsSync(linkPath), '★ 硬要求 B:链接本身也还在(没有被 rename 覆盖掉)');
          ok(fs.readdirSync(outsideDir).length === 1,
             '★ 硬要求 B:maps/ 之外那个目录里没有多出任何东西(实得 ' +
             fs.readdirSync(outsideDir).join(',') + ')');
          ok(noTmpLeft(), '★ 硬要求 B:被拒的链接写也没在 maps/ 里留临时文件');
        }
      } finally {
        // ★ 一定要收掉:留着它会让后面任何一个"列 maps/ 目录"的断言多出一个条目。
        try { if (fs.existsSync(linkPath)) fs.unlinkSync(linkPath); } catch (e) { /* 清不掉不该盖住真失败 */ }
      }
    }
});