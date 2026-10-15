'use strict';
// tests/server/60_rename_retry.js —— 相位 ⑧:rename 重试(注入式,不启服务器)与退避曲线的逐档判据。
globalThis.serverChain = globalThis.serverChain.then(async function () {
const fs = require('fs');
const path = require('path');
const srv = require('../../editor_server.js');
  // ★ 为什么不用活的读写竞态测这条:它必然飘 —— 要掐到"读者正攥着句柄"的那一瞬
  //   "机器负载/调度"写进了判据。这里改成把 rename 注入进去,于是
  //   「前两次 EPERM 第三次成功」是纯逻辑、秒级、且能顺带断言尝试次数
  {
    // 注入用的"同步抛"rename(与 fs.renameSync 同形态)与一个不真的等的 sleep。
    const noSleep = function () { /* 立即返回:注入契约是"返回什么都行" */ };
    const eperm = function () { const e = new Error('EPERM: operation not permitted, rename'); e.code = 'EPERM'; return e; };
    const retryDir = path.join(tmpRoot, 'retry_maps');
    fs.mkdirSync(retryDir, { recursive: true });
    const keepName = 'keep.cyrm';
    const keepPath = path.join(retryDir, keepName);
    const originalBytes = Buffer.from('★ 原来那张地图 —— 失败的写一个字节都不许动它', 'utf8');
    fs.writeFileSync(keepPath, originalBytes);
    const noTmpInRetryDir = function () {
      return fs.readdirSync(retryDir).every(function (n) { return n.indexOf('.tmp') < 0; });
    };

    // ★ 常量本身也钉住:重试名单少了 EPERM,下面那条"两次 EPERM 第三次成功"会红;
    //   漏一个就等于在那些机器上静默退回"保存失败对用户可见"。
    ok(srv.RENAME_RETRY_CODES.indexOf('EPERM') >= 0 &&
       srv.RENAME_RETRY_CODES.indexOf('EBUSY') >= 0 &&
       srv.RENAME_RETRY_CODES.indexOf('EACCES') >= 0,
       '★ 待修 1:重试名单含 EPERM / EBUSY / EACCES(实得 ' + JSON.stringify(srv.RENAME_RETRY_CODES) + ')');
        // ★ 范围 10~12 是实测定的(复审:真 HTTP + 真 61KB 地图 + 持续 GET 读者 + 20 次 PUT ⇒
        //   出厂参数 6/20 失败、20 次 × 固定 50ms 则 0/20)。具体值由下面"用满 N 次"那条断言参数化跟上。
    ok(srv.RENAME_MAX_ATTEMPTS >= 10 && srv.RENAME_MAX_ATTEMPTS <= 12,
       '★ 待修 1:总尝试次数在 10~12 之间(实得 ' + srv.RENAME_MAX_ATTEMPTS + ')');
    // ★ 退避上限:少了它,额度一放宽就会退回"翻倍到 160ms"那套稀疏尝试。
    ok(srv.RENAME_RETRY_MAX_MS > 0 && srv.RENAME_RETRY_MAX_MS <= 100,
       '★ 待修 1:退避封顶在 100ms 以内(实得 ' + srv.RENAME_RETRY_MAX_MS + 'ms)');

    // ① 前两次 EPERM、第三次成功 → 成功,且恰好调用了 3 次。
    {
      let calls = 0;
      const flaky = function () {
        calls++;
        if (calls <= 2) throw eperm();
        return undefined;                 // 第三次成功(renameFn 允许同步返回)
      };
      let err = null;
      try { await srv.renameWithRetry('t', 'g', flaky, noSleep); } catch (e) { err = e; }
      ok(err === null, '★ 待修 1:EPERM 两次后第三次成功 → 不抛(实得 ' +
         (err === null ? '成功' : errText(err)) + ')');
      ok(calls === 3, '★★ 待修 1:重试确实发生了 —— 调用次数 3(实得 ' + calls +
         ';为 1 = 根本没重试,> 3 = 退避多算了)');
    }

    // ①b 同一条,但注入的是异步 reject 形态 —— 那才是生产里的默认实现
    //     (fs.promises.rename)。★ 这一条与 ① 不重复:同步抛与异步 reject 走的是
    {
      let calls = 0;
      const flakyAsync = function () {
        calls++;
        if (calls <= 2) return Promise.reject(eperm());
        return Promise.resolve();
      };
      let err = null;
      try { await srv.renameWithRetry('t', 'g', flakyAsync, noSleep); } catch (e) { err = e; }
      ok(err === null && calls === 3,
         '★ 待修 1:异步 reject 形态(生产默认那条)同样重试到第 3 次成功(实得 calls=' + calls +
         ', err=' + (err === null ? '无' : errText(err)) + ')');
    }

        // ★ 为什么必须补这条:本相位此前每一条注入调用都传了 noSleep,而相位 ⑦ 的真实 PUT 永远
    {
      let loopTicks = 0;
      let ticking = true;
      (function arm() {
        setImmediate(function () { if (!ticking) return; loopTicks++; arm(); });
      })();
      let calls = 0;
      const oneEperm = function () {
        calls++;
        if (calls <= 1) throw eperm();
        return undefined;
      };
      let err = null;
      const ticksBefore = loopTicks;
      try {
        // ★ 只有一个实参:走默认 sleep(生产那条路径)。
        await srv.renameWithRetry('t', 'g', oneEperm);
      } catch (e) { err = e; }
      const ticksDuring = loopTicks - ticksBefore;
      ticking = false;
      ok(err === null && calls === 2,
         '★ 待修 2:默认退避(不注入 sleepFn)下 EPERM 一次后第二次成功(实得 calls=' + calls +
         ', err=' + (err === null ? '无' : errText(err)) + ')');
      ok(ticksDuring > 0,
         '★★ 待修 2:重试期间**事件循环确实前进过** —— 默认退避是异步让出,不是同步等待' +
         '(实得 ' + ticksDuring + ' 个循环回合;为 0 = 换成了 Atomics.wait 那类同步 sleep,' +
         '整个修复结构上失效)');
    }

        // ★ 缺口:上面三条钉的是常量的值,而常量的用法没被观测过 —— 把退避公式里的 Math.min 删掉、常量照留,
        //   冒烟照样全绿,而"无界增长"原样回来(11 档 ≈ 41 秒最坏等待,用户只会以为卡死)。
    {
      const recorded = [];
      const recSleep = function (ms) { recorded.push(ms); /* 刻意不真睡:本块只要序列 */ };
      const neverRenames = function () { throw eperm(); };
      let err = null;
      try { await srv.renameWithRetry('t', 'g', neverRenames, recSleep); } catch (e) { err = e; }
      const expected = [];
      for (let i = 0; i < srv.RENAME_MAX_ATTEMPTS - 1; i++) {
        expected.push(Math.min(srv.RENAME_RETRY_MAX_MS,
                               srv.RENAME_RETRY_BASE_MS * Math.pow(2, i)));
      }
      const maxRecorded = Math.max.apply(null, recorded.concat([0]));
      ok(err !== null, '★ 待修 1:恒定 EPERM 用满额度后照原样抛出(实得:' +
         (err === null ? '(未抛错 —— 重试变成无限循环了)' : errText(err)) + ')');
      // ★ 断言的是整条曲线,不是"最大值没超":后者漏得掉"前几档就没按 base 翻倍"
      //   这类错(曲线整体平移一格也照样不超上限)。
      eq(recorded, expected,
         '★★ 待修 1:退避序列**逐档** = min(' + srv.RENAME_RETRY_MAX_MS + 'ms, ' +
         srv.RENAME_RETRY_BASE_MS + '×2^(n-1)) —— 前两档按 base 翻倍、之后被上限钳住,' +
         '共 ' + expected.length + ' 档(实得 ' + JSON.stringify(recorded) + ')');
      ok(maxRecorded <= srv.RENAME_RETRY_MAX_MS,
         '★★ 待修 1:退避最大值 ≤ 上限 ' + srv.RENAME_RETRY_MAX_MS + 'ms' +
         '(把 Math.min 从退避公式里拿掉 = 在这里红;实得最大 ' + maxRecorded + 'ms)');
      ok(recorded.length > 0 &&
         recorded[recorded.length - 1] === srv.RENAME_RETRY_MAX_MS,
         '★★ 待修 1:末档**恰好**被钳到上限(上限必须真的生效,而不只是"恰好没被超")' +
         '(实得末档 ' + recorded[recorded.length - 1] + 'ms)');
    }

        // ★ ①c 只证明重试期内事件循环前进过;而一个 setImmediate 形态的 sleep(一个循环回合、
        //   ~0 实际时间)能让它照样绿 —— 判据:这次不注入 sleepFn(走生产那条默认路径),改在注入的
    {
      const stamps = [];
      let calls = 0;
      const stamping = function () {
        stamps.push(Date.now());
        calls++;
        if (calls <= 3) throw eperm();
        return undefined;                          // 第 4 次成功
      };
      let err = null;
      try { await srv.renameWithRetry('t', 'g', stamping); } catch (e) { err = e; }
      const gaps = [];
      for (let i = 1; i < stamps.length; i++) gaps.push(stamps[i] - stamps[i - 1]);
      const wantGaps = [];
      for (let i = 0; i < 3; i++) {
        wantGaps.push(Math.min(srv.RENAME_RETRY_MAX_MS,
                               srv.RENAME_RETRY_BASE_MS * Math.pow(2, i)));
      }
      ok(err === null && calls === 4,
         '★ 待修 2:默认退避(不注入 sleepFn)下第 4 次尝试成功(实得 calls=' + calls +
         ', err=' + (err === null ? '无' : errText(err)) + ')');
      let waited = gaps.length === 3;
      for (let i = 0; i < 3 && waited; i++) waited = gaps[i] >= wantGaps[i] / 2;
      ok(waited,
         '★★ 待修 2:每次退避**真的把那一档睡掉了**(相邻尝试间隔 ≥ 该档期望的一半)' +
         ' —— 不是 setImmediate 那种"让出循环但不等"的假 sleep(实得间隔 ' +
         JSON.stringify(gaps) + 'ms / 期望档位 ' + JSON.stringify(wantGaps) + 'ms)');
    }

        // ★ 走 writeMapAtomic(不是 renameWithRetry):"临时文件被清掉"这条清理逻辑住在
    {
      let calls = 0;
      const alwaysEperm = function () { calls++; throw eperm(); };
      let err = null;
      try { await srv.writeMapAtomic(retryDir, keepName, Buffer.from([0xEE, 0xEE]), alwaysEperm, noSleep); }
      catch (e) { err = e; }
      ok(err !== null && errText(err).indexOf('EPERM') >= 0,
         '★ 待修 1:一直 EPERM → 抛出并保留错误码(实得:' +
         (err === null ? '(未抛错)' : errText(err)) + ')');
      ok(calls === srv.RENAME_MAX_ATTEMPTS,
         '★ 待修 1:用满 ' + srv.RENAME_MAX_ATTEMPTS + ' 次尝试才放弃(实得 ' + calls + ')');
      sameBytes(fs.readFileSync(keepPath), originalBytes,
                '★★ 待修 1:写失败之后原文件逐字节未变(失败是 fail-safe 的)');
      ok(noTmpInRetryDir(), '★★ 待修 1:写失败之后临时文件被清掉(否则每次失败都在 maps/ 里留垃圾)');
    }

    // ③ 不在重试名单里的码(EIO / ENOENT)→ 立即抛,一次都不重试。
    //    ★ 这条防的是"图省事写成无条件重试":那会让真正的磁盘错误也多等一整套退避才报,
    //      而且掩盖掉"错在哪"。
    {
      const cases = ['EIO', 'ENOENT'];
      for (const code of cases) {
        let calls = 0;
        // ★ 必须真的抛(返回一个 Error 对象不算失败 —— 那会被 Promise 当成成功值),
        //   否则这条断言测的是"什么都没发生"。
        const other = function () { calls++; const e = new Error(code + ': 注入的别的错'); e.code = code; throw e; };
        let err = null;
        try { await srv.writeMapAtomic(retryDir, keepName, Buffer.from([0x01]), other, noSleep); }
        catch (e) { err = e; }
        ok(err !== null && errText(err).indexOf(code) >= 0 && calls === 1,
           '★ 待修 1:' + code + ' 不在重试名单 → 立即抛且只调用 1 次(实得 calls=' + calls +
           ', err=' + (err === null ? '(未抛错)' : errText(err)) + ')');
      }
      sameBytes(fs.readFileSync(keepPath), originalBytes,
                '★ 待修 1:两条"立即抛"之后原文件仍逐字节未变');
      ok(noTmpInRetryDir(), '★ 待修 1:两条"立即抛"也没留临时文件');
    }

    // ④ 重试的成功路径:同一张图连做两次 PUT(注入 rename)后,盘上就是新字节、mapPathFor 照旧返回 {name,size}。
    {
      const okRename = function (t, g) { fs.renameSync(t, g); };
      const out = await srv.writeMapAtomic(retryDir, keepName, Buffer.from([7, 7, 7, 7]), okRename, noSleep);
      eq(out, { name: keepName, size: 4 }, '★ 待修 1:异步化之后成功路径照旧返回 {name,size}');
      sameBytes(fs.readFileSync(keepPath), Buffer.from([7, 7, 7, 7]), '★ 待修 1:成功路径确实落盘');
      ok(noTmpInRetryDir(), '★ 待修 1:成功路径不留临时文件');
      // 收尾:还原成原始内容,免得将来有人把这个目录也列进某个"精确列表"断言。
      fs.writeFileSync(keepPath, originalBytes);
    }
  }
});