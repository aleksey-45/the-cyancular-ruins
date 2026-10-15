'use strict';
// tests/server/30_map_name_guard.js —— 相位 ⑤:地图名守卫(唯一的安全边界)。
globalThis.serverChain = globalThis.serverChain.then(async function () {
const path = require('path');
const srv = require('../../editor_server.js');
  // ==== 相位 ⑤ 地图名守卫(规格 §4.9,风险登记点名"必须写测试")====
  // ★★ 本相位必须留在 runAllPhases() 里面(不是 main() 里 // ==== 断言区结束 ==== 之前):
  //   那句注释在 main() 的 try/finally{ cleanup() } 之后,放那里 = 相位跑在清理之后,
  //   每次跑都会把已删掉的 tmpRoot 重新建出来 → 每次留下一个 cyrm-srv-* 临时目录(已实测)。
  {
    const bad = ['', 'demo', 'demo.txt', 'a.cyrm.bak', '..cyrm', '.cyrm', 'demo.cyrm\n',
                 '../demo.cyrm', '..%2fdemo.cyrm', '/demo.cyrm', 'a/b.cyrm', 'a\\b.cyrm',
                 'C:\\demo.cyrm', 'demo cyrm', 'demo\n.cyrm', 'demo.cyrm/x', '..\\..\\x.cyrm',
                 'demo\u0000.cyrm', 'x'.repeat(65) + '.cyrm', null, 42, undefined];
    let allRejected = true, firstFail = '';
    for (const n of bad) {
      // ★ 用「不提前 return」的写法:一条失败不该让后面 15 条一条都不跑(否则修一处红一处)。
      if (srv.isValidMapName(n) !== false) { allRejected = false; if (!firstFail) firstFail = JSON.stringify(n); }
    }
    ok(allRejected, '★ isValidMapName 拒绝全部 ' + bad.length + ' 个非法名(首个漏网:' + firstFail + ')');
    const good = ['demo.cyrm', 'factory1v1.cyrm', 'a.cyrm', 'A_1-2.cyrm', 'x'.repeat(58) + '.cyrm'];
    let allAccepted = true, firstGoodFail = '';
    for (const n of good) {
      if (srv.isValidMapName(n) !== true) { allAccepted = false; if (!firstGoodFail) firstGoodFail = n; }
    }
    ok(allAccepted, 'isValidMapName 接受全部 ' + good.length + ' 个合法名(首个漏网:' + firstGoodFail + ')');
    ok(srv.MAX_MAP_NAME_LEN === 64, 'MAX_MAP_NAME_LEN === 64(规格的正则没有长度上界,这条是防御性补充)');
    let threw = false;
    try { srv.mapPathFor(tmpRoot, '../evil.cyrm'); } catch (e) { threw = true; }
    ok(threw, 'mapPathFor: 非法名抛错(不返回一个越界的路径)');
    eq(srv.mapPathFor(tmpRoot, 'ok.cyrm'), path.join(path.resolve(tmpRoot), 'ok.cyrm'),
       'mapPathFor: 合法名 = mapsDir + 名字');

        // ★ 为什么非放行不可:编辑器在 v3→v4 的单向转换写盘之前要落一份原文备份(唯一的退路),
        //   备份名必须是 <名>.v3.bak —— 结尾不是 .cyrm,游戏的 _random_cyrm(ends_with(".cyrm"))
        //   才抽不到它,备份不会混进随机地图池。
        // ★★ 这一组是双向断言:新后缀被接受 且 旧的拒绝面一条都不少 —— 这条守卫是"一个本地网页
        //   不许读写任意路径"的唯一边界,放宽成"任意后缀"或让基名能带 . 都等于把边界拆掉。
    ok(srv.isValidMapName('demo.v3.bak') === true,
       '★★★ 新后缀被接受:`demo.v3.bak`(= 地图名去 `.cyrm` + `.v3.bak`,编辑器的原文备份名)');
    ok(srv.isValidMapName('factory1v1.v3.bak') === true,
       '★ 真地图名 + 新后缀也接受(factory1v1.v3.bak)');
    ok(srv.isValidMapName('x'.repeat(57) + '.v3.bak') === true,
       '★ 新后缀下长度上界仍然生效:恰好 64 字符(57 + 7)接受');
    const badBak = ['a.bak', 'a.v3bak', 'a.v3.bak.cyrm', 'a.cyrm.bak', 'v3.bak', '.v3.bak',
                    '..v3.bak', '../a.v3.bak', '..%2fa.v3.bak', '/a.v3.bak', 'a/b.v3.bak',
                    'a\\b.v3.bak', 'C:\\a.v3.bak', 'a.b.v3.bak', 'a b.v3.bak', 'a.v3.bak\n',
                    '..\\..\\x.v3.bak', 'a\u0000.v3.bak', 'x'.repeat(58) + '.v3.bak'];
    let bakRejected = true, firstBakFail = '';
    for (const n of badBak) {
      if (srv.isValidMapName(n) !== false) { bakRejected = false; if (!firstBakFail) firstBakFail = JSON.stringify(n); }
    }
    ok(bakRejected, '★★★ 放宽**只**多了那一个后缀:另外 ' + badBak.length +
       ' 个"名字里有 `.` 但不是 `.v3.bak` 后缀 / 想走路径 / 过长"的名字**照样全拒**' +
       '(首个漏网:' + firstBakFail + ')');
    // ④ 新旧两档在真路径上的一致性:mapPathFor 对新后缀同样只拼 mapsDir + 名字
    // ★ 两条都写成"不抛出去"的形式:mapPathFor 对非法名是抛错,直接写在 eq(...) 里
    //   一旦正则被改坏就会把整场冒烟中断在异常上(后面几十条断言一条都跑不到、也没有
    //   计数行)—— 症状看着像"冒烟自己坏了",而不是"这条守卫坏了"。
    function tryPathFor(n) { try { return { ok: true, p: srv.mapPathFor(tmpRoot, n) }; } catch (e) { return { ok: false }; } }
    const pBak = tryPathFor('demo.v3.bak');
    ok(pBak.ok && pBak.p === path.join(path.resolve(tmpRoot), 'demo.v3.bak'),
       '★ mapPathFor: 新后缀 = mapsDir + 名字(与 `.cyrm` 同一条路径拼接;实得 ' +
       (pBak.ok ? pBak.p : '(抛错了 —— 名字没被接受)') + ')');
    ok(tryPathFor('../evil.v3.bak').ok === false,
       '★★ mapPathFor: 带新后缀的遍历名照样抛错(第二道"路径必须在 maps/ 里"的闸)');
  }
});