'use strict';
// tests/server/20_static_read_failure.js —— 相位 ⑤:stat 成功但 open 失败(独占锁),服务器必须活着。
globalThis.serverChain = globalThis.serverChain.then(async function () {
const fs = require('fs');
const path = require('path');
const srv = require('../../editor_server.js');
  {
    // ★ 这里复现的是真实的文件状态,不是打桩:fs.stat 成功(它只读目录项属性),
    //   而随后的 open 失败(共享冲突)。制造手段与理由见 lockFileExclusiveWin 的注释。
    //   ★ 非 Windows 上跳过(打印一行,不计入 ok/FAIL):[IO.File]::Open 是 .NET API。
    const lockDir = path.join(tmpRoot, 'locked');
    fs.mkdirSync(lockDir, { recursive: true });
    const lockedPath = path.join(lockDir, 'editor.html');
    const lockedBytes = Buffer.from('<!DOCTYPE html><html><body>这个入口页会被独占锁住</body></html>', 'utf8');
    fs.writeFileSync(lockedPath, lockedBytes);
    const goodBytes = Buffer.from('// 锁事件之后的存活探针\n', 'utf8');
    fs.writeFileSync(path.join(lockDir, 'good.js'), goodBytes);
    const lockSrv = track(await srv.startServer({
      rootDir: lockDir, mapsDir: path.join(tmpRoot, 'maps'), port: 0,
    }));
        // ★★ /api/map 那一支(serveMapFile)的守卫必须有自己的反证,不能靠"照抄了一份已经测过的
        //   代码"(serveStatic 那条根本盖不到这条分支)。落点必须是 tmpRoot/maps 下面(地图名守卫
        //   只放行裸文件名),而相位 ⑥ 的 GET /api/maps 是精确列表比对 ⇒ 本相位结束前必须删掉它。
    const mapsDir = path.join(tmpRoot, 'maps');
    fs.mkdirSync(mapsDir, { recursive: true });
    const lockedMapName = 'locked.cyrm';
    const lockedMapPath = path.join(mapsDir, lockedMapName);
    const lockedMapBytes = Buffer.from([7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7]);
    fs.writeFileSync(lockedMapPath, lockedMapBytes);

    try {
      if (process.platform !== 'win32') {
        console.log('  --    相位 ⑤ 跳过:非 Windows(独占句柄需要 .NET 的 FileShare.None)');
      } else {
        // ★ 一次锁住两个:入口页(静态那条分支)与 locked.cyrm(/api/map 那条分支)。
        lockerChild = await lockFileExclusiveWin([lockedPath, lockedMapPath]);
        // 前置:故障点必须真的在 open 而不在 stat —— 否则下面几条什么都没验(比如文件已被删)。
        let st = null;
        try { st = fs.statSync(lockedPath); } catch (e) { /* 前置不成立 */ }
        ok(st !== null && st.isFile(),
           '待修 1 前置:被独占锁住的文件 fs.stat **照样成功**(故障点因此在 open,不在 stat)');

        const rLock = await requestSettled(lockSrv.port, 'GET', '/editor.html');
        ok(rLock.aborted === true && rLock.body.length < lockedBytes.length,
           '★★ 待修 1:open 失败 → 客户端拿到的是**已中止**的响应,而不是一个完整的 200 ' +
           '(实得 status=' + rLock.status + ', aborted=' + rLock.aborted + ', body=' +
           rLock.body.length + '/' + lockedBytes.length + 'B, err=' + (rLock.error || '无') + ')');

        // ★ 这条才是主断言:旧实现在这里已经是一具尸体 —— ReadStream 的 'error' 没人接管
        //   → 未捕获异常 → 整个进程退出 1,客户端一行响应都收不到,用户只能重启 serve.bat。
        const rGood = await request(lockSrv.port, 'GET', '/good.js');
        ok(rGood.status === 200,
           '★★ 待修 1:出过坏文件之后服务器**还活着**(紧接着 GET /good.js → ' + rGood.status + ')');
        sameBytes(rGood.body, goodBytes, '待修 1:活着,而且读出来的字节正确(不是「活着但坏了」)');

            // ★ /api/map 这一支与上面两条同款,但走的是另一份代码:两份守卫各自独立,serveStatic
            //   测到不证明这条测到。前置:与 /editor.html 同理,故障点必须在 open 而不在 stat。
        let stMap = null;
        try { stMap = fs.statSync(lockedMapPath); } catch (e) { /* 前置不成立 */ }
        ok(stMap !== null && stMap.isFile(),
           '待修 1 前置:被独占锁住的地图 fs.stat **照样成功**(故障点因此在 serveMapFile 的 open)');

        const rMapLock = await requestSettled(lockSrv.port, 'GET', '/api/map?p=' + lockedMapName);
        ok(rMapLock.aborted === true && rMapLock.body.length < lockedMapBytes.length,
           '★★ 待修 1:/api/map 的 open 失败 → 客户端拿到的是**已中止**的响应,而不是一个完整的 200 ' +
           '(实得 status=' + rMapLock.status + ', aborted=' + rMapLock.aborted + ', body=' +
           rMapLock.body.length + '/' + lockedMapBytes.length + 'B, err=' + (rMapLock.error || '无') + ')');

        // ★ 这条才是主断言:这 6 行缺席时,ReadStream 的 'error' 无人接管 → 未捕获异常
        //   → 整个进程退出,这条请求根本等不到响应(整支冒烟连一行结果都打不出来)。
        const rMapsAlive = await request(lockSrv.port, 'GET', '/api/maps');
        ok(rMapsAlive.status === 200,
           '★★ 待修 1:出过坏地图之后服务器**还活着**(紧接着 GET /api/maps → ' + rMapsAlive.status + ')');

        // ★ 反证:证明刚才那条确实是锁造成的,而不是"没锁上、一切正常"。
        await releaseLocker();
        const rAfter = await requestSettled(lockSrv.port, 'GET', '/editor.html');
        ok(rAfter.status === 200 && rAfter.body.length === lockedBytes.length,
           '待修 1 反证:句柄一放开,同一个 URL 立刻恢复正常(证明前一条确实栽在 open 上)(实得 ' +
           rAfter.status + ', ' + rAfter.body.length + 'B)');
        // ★ 反证(/api/map 那一支):同一把锁、同一时刻放开,地图这条也要恢复 —— 且字节正确。
        const rMapAfter = await requestSettled(lockSrv.port, 'GET', '/api/map?p=' + lockedMapName);
        ok(rMapAfter.status === 200 && rMapAfter.body.length === lockedMapBytes.length,
           '待修 1 反证(/api/map):句柄一放开立刻恢复(证明前一条确实栽在 serveMapFile 的 open 上)(实得 ' +
           rMapAfter.status + ', ' + rMapAfter.body.length + 'B)');
      }
    } finally {
      // ★ 子进程一定要收掉:它握着句柄时连临时目录都删不掉(rmSync 会 EBUSY)。
      //   (断言失败走不到 kill 那一步 —— 所以这里必须再兜一次。)
      await releaseLocker();
      // ★ locked.cyrm 必须在这里删掉:相位 ⑥ 的 GET /api/maps 是精确列表比对
      //   (['a_first.cyrm','b_second.cyrm']),留着它会把那条一直绿着的断言判红。
      //   非 Windows 上这个文件只是建了没用,一并删掉;删不到(例如上面提前抛错)也不该盖住真失败。
      try { fs.unlinkSync(lockedMapPath); } catch (e) { /* 不在就跳过 */ }
    }
  }
});