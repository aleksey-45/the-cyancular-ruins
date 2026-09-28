// editor_server.js —— 编辑器本地服务器(规格 §4.9)。
// ★ 编辑器**只通过它打开**:`file://` 支持被刻意放弃(规格 §1.2),换来原生 Worker、
//   无同源限制、能直接读写磁盘上的 `maps/*.cyrm`。代价是每次要先起服务器。
// ★ 用 node 写 —— 仓库的编辑器工具链(sync-tiles.js / sync-enemies.js)本来就是 node,
//   不引入新的运行时依赖。
// ★ 只绑 127.0.0.1;端口 8777 刻意避开游戏侧已占用的一切端口
//   (7777 大厅 / 7800+ worker / 7999 测试)。
// ★ 它是**哑文件服务器**:不校验 .cyrm 格式 —— 那是 core.js 的事。
//   服务器若也判一遍格式,就是第二份格式实现,分歧的症状是"编辑器存得下、游戏读不出",且不报错。
// ★ **不做**:认证、TLS、目录浏览、多用户、range 请求。它是本机自用工具,不是服务。
// 用法:node editor_server.js [--port 8777] [--maps <dir>] [--root <dir>] [--no-open]
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, execFileSync } = require('child_process');

const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 8777;
const DEFAULT_ROOT_DIR = __dirname;
const DEFAULT_MAPS_DIR = path.join(__dirname, '..', 'maps');
const DEFAULT_INDEX = 'editor.html';
// ★ 闸 1「一切有硬上限」(规格 §4.3):PUT 的请求体也要有上限,否则一个坏掉的前端
//   循环就能把磁盘写满。取 core.js 的 MAX_BODY_SIZE 同值(64MB)—— 合法文件最坏约
//   19.1MiB(core.js 里那段推导),对合法文件不会误拒,对跑飞的客户端是一道硬闸。
const MAX_MAP_BYTES = 64 * 1024 * 1024;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.cyrm': 'application/octet-stream',
};
function mimeOf(filePath) {
  return MIME[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
}

function sendText(res, status, message) {
  const body = Buffer.from(message + '\n', 'utf8');
  res.writeHead(status, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}
function sendJson(res, status, obj) {
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

// 静态路径 → 绝对文件路径,并保证它**落在 rootDir 里面**。
// ★ 这是本文件后果最重的一处:没有这道检查,一个本地网页就能读整块磁盘
//   (GET /../../../../Windows/win.ini)。
// ★ 判据刻意用「解析后的绝对路径必须落在 rootAbs 里面」,而不是「字符串里有没有 ..」:
//   后者漏掉 URL 编码(%2e%2e 会被 URL 解析器归一化掉、但 %2f 不会)与一切别的变体,
//   而前者是**结构性**的 —— 无论输入长什么样,解析完都得落在根里面。
// ★ URL 解析器本身也会归一化掉 `..`(实测 /../x → /x),所以这里是**第二道**闸;
//   真正危险的是 /..%2f..(编码过的分隔符),那一个必须靠这一道挡。
function staticFileFor(rootDir, urlPath, indexName) {
  let rel;
  try { rel = decodeURIComponent(String(urlPath)); }
  catch (e) { return { status: 400, message: 'URL 编码非法' }; }
  if (rel.indexOf('\0') >= 0) return { status: 400, message: '路径里含空字节' };
  rel = rel.split('\\').join('/');                 // Windows 上反斜杠也是分隔符
  if (rel === '/' || rel === '') rel = '/' + indexName;
  const rootAbs = path.resolve(rootDir);
  const target = path.resolve(rootAbs, '.' + (rel.charAt(0) === '/' ? rel : '/' + rel));
  if (target !== rootAbs && target.indexOf(rootAbs + path.sep) !== 0) {
    return { status: 403, message: '路径越出静态根目录' };
  }
  return { status: 200, file: target };
}

function serveStatic(res, resolved, headOnly) {
  if (resolved.status !== 200) return sendText(res, resolved.status, resolved.message);
  fs.stat(resolved.file, function (err, st) {
    // ★ 目录也走这里 → 404:规格 §4.9 明写「不做目录浏览」。
    if (err || !st.isFile()) return sendText(res, 404, '找不到 ' + path.basename(resolved.file));
    res.writeHead(200, {
      'Content-Type': mimeOf(resolved.file),
      'Content-Length': st.size,
      // ★ 一定要关缓存:编辑器是"改完立刻刷新看效果"的工作流,
      //   浏览器缓存住旧 .js 会让用户对着旧代码调半天。
      'Cache-Control': 'no-store',
    });
    if (headOnly) return res.end();
    // ★★ 响应头**已经发出去了**,这一支只能把本次响应中止掉,不能回头改状态码。
    //   ReadStream 的 'error' 必须在这里接管:没人接管就是一次**无人认领的 'error' 事件**
    //   = 未捕获异常 = **整个编辑器服务器进程死掉**(客户端什么响应都收不到,用户只能重启 serve.bat)。
    //   「stat 成功但 open 失败」是真实存在的状态,不是理论:Windows 上文件被 AV/扫描器
    //   独占锁定、ACL 拒绝、负载下的 EMFILE、以及文件在 stat 与 createReadStream 之间被删掉
    //   (编辑器自己重写文件时正会如此)。上面那道 404 只覆盖「stat 失败」,根本走不到这里。
    // ★ 同步抛(createReadStream 的参数非法)与异步 'error' 是同一类「这一次读不出去」,
    //   一并兜住:它们的正确处理都是「中止这一条响应」,而不是把服务器带走。
    let stream;
    try { stream = fs.createReadStream(resolved.file); }
    catch (e) { return res.destroy(); }
    stream.on('error', function () { res.destroy(); });
    // ★ 防泄漏的另一半:客户端提前断开时把**源流**关掉,否则 fd 与流对象一直留到进程结束。
    res.on('close', function () { stream.destroy(); });
    stream.pipe(res);
  });
}

// ── 地图名守卫(规格 §4.9)──
// ★ 没有这一条,一个本地网页就能读写整块磁盘 —— 它是本文件唯一的安全边界,
//   也是规格 §7 风险登记里点名"这条必须写测试"的那一条。
// 只接受**裸文件名**:不接受路径分隔符(/ 与 \)、不接受 ..、不接受空字节、不接受绝对路径。
// ★★ 2026-09-22(用户裁定,本文件**唯一**一次放宽):除了 `.cyrm`,再接受**一个**后缀
//    `.v3.bak`。为什么非放行不可:v3→v4 的转换是**单向**的(规格 §3.6),保存前要落一份
//    原文备份当退路,而备份名必须是 `<名>.v3.bak` —— 结尾**不是** `.cyrm`,游戏的
//    `_random_cyrm`(`f.to_lower().ends_with(".cyrm")`)才抽不到它,备份不会混进随机地图池。
//    放宽得极小:基名照旧**只许** `[A-Za-z0-9_-]`(里面**连 `.` 都不许有**,`..`、`/`、
//    `\`、空字节、其它后缀一律照旧拒),故它仍然写不出 maps/ 之外、也写不出任意后缀的文件。
//    守卫在 server_smoke.js 相位 ⑤:新后缀被接受 + 旧的每一条拒绝路径都还在。
const MAP_NAME_RE = /^[A-Za-z0-9_\-]+(?:\.cyrm|\.v3\.bak)$/;
// 规格的正则没有长度上界;这条是防御性补充(真名由 core.js 的 sanitizeName 生成,
// ≤32 字符 + ".cyrm" = 37,64 留了一倍余量)。
const MAX_MAP_NAME_LEN = 64;

function isValidMapName(name) {
  if (typeof name !== 'string') return false;
  if (name.length === 0 || name.length > MAX_MAP_NAME_LEN) return false;
  // 空字节:正则本来就不放行,这里再挡一次 —— 防的是"将来有人把正则改宽"。
  if (name.indexOf('\0') >= 0) return false;
  return MAP_NAME_RE.test(name);
}

function mapPathFor(mapsDir, name) {
  if (!isValidMapName(name)) throw new Error('地图名非法:' + JSON.stringify(name));
  const dir = path.resolve(mapsDir);
  const target = path.resolve(dir, name);
  // 双保险:即便正则哪天被改宽,这里也保证出去的路径一定在 maps/ 里面。
  if (target.indexOf(dir + path.sep) !== 0) throw new Error('地图名越出 maps 目录:' + name);
  return target;
}

// 列地图。★ 只列**打得开**的(名字不过守卫的文件列出来也点不开),但绝不静默 ——
// 跳过的每一个都记一条日志点名。
// ★ 待修 2:这句话原先**只在"名字不过守卫"那一条上是真的** —— stat 抛错与"同名目录"
//   两条路径都是静默 continue。承诺与实际不符就是过度承诺(而且静默的那两条恰好是
//   "磁盘上有个东西你以为它在库里、其实不在"这类最难自查的),故三条路径一律点名。
function listMaps(mapsDir, logger) {
  const out = [];
  let names = [];
  try { names = fs.readdirSync(mapsDir); }
  catch (e) { return out; }                     // 目录不存在 = 空库,不是错误
  names.sort();
  for (const n of names) {
    if (!isValidMapName(n)) { if (logger) logger('跳过不可打开的文件:' + n); continue; }
    let st;
    try { st = fs.statSync(path.join(mapsDir, n)); }
    catch (e) {
      if (logger) logger('跳过读不到属性的文件:' + n + '(' + (e && e.message ? e.message : String(e)) + ')');
      continue;
    }
    if (!st.isFile()) { if (logger) logger('跳过非文件(同名目录?):' + n); continue; }
    out.push({ name: n, size: st.size, mtime: st.mtimeMs });
  }
  return out;
}

function serveMapFile(res, target, name, headOnly) {
  fs.stat(target, function (err, st) {
    if (err || !st.isFile()) return sendText(res, 404, '找不到地图 ' + name);
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': st.size,
      'Cache-Control': 'no-store',
    });
    if (headOnly) return res.end();
    // ★★ 与 serveStatic 同一条教训(Task 1 的待修 1):响应头**已经发出去了**,
    //   这一支只能把本次响应中止掉,不能回头改状态码。ReadStream 的 'error' 必须在这里接管:
    //   没人接管就是一次**无人认领的 'error' 事件** = 未捕获异常 = **整个编辑器服务器进程死掉**
    //   (而 serve.bat 是整场开着的 ⇒ 一个坏文件把编辑器打下来,用户只能重启)。
    //   「stat 成功但 open 失败」是真实状态,不是理论:Windows 上 AV/扫描器独占锁、ACL 拒绝、
    //   负载下的 EMFILE、以及文件在 stat 与 createReadStream 之间被删掉(编辑器自己正在重写它)。
    //   上面那道 404 只覆盖「stat 失败」,根本走不到这里。
    let stream;
    try { stream = fs.createReadStream(target); }
    catch (e) { return res.destroy(); }
    stream.on('error', function () { res.destroy(); });
    // ★ 防泄漏的另一半:客户端提前断开时把**源流**关掉,否则 fd 与流对象一直留到进程结束。
    res.on('close', function () { stream.destroy(); });
    stream.pipe(res);
  });
}

// 请求体超限时抛的错误:带一个显式标记,让 receiveMapFile 能把它与别的写失败分开
// (超限 = 413,安全闸拒绝 = 403,其余 = 500)。
// ★ 与 rejectWrite 是**同一条纪律:用标记,不认错误文本** —— 文本会被将来改字面量的人
//   改掉(改完 413 就静默退化成 500),而标记改了会当场红。
function rejectTooLarge(message) {
  const e = new Error(message);
  e.tooLarge = true;
  return e;
}

// 读请求体,带硬上限。
// ★ 超限守的是**内存**、不是带宽:超限之后不再收集(超限那一块根本不留下),
//   但仍把请求读完再回 413 —— 中途 destroy 会让客户端拿到 ECONNRESET 而不是那条错误信息。
function readBody(req, maxBytes) {
  return new Promise(function (resolve, reject) {
    const chunks = [];
    let total = 0;
    let overflow = false;
    req.on('data', function (c) {
      total += c.length;
      if (total > maxBytes) {
        // ★ 判在 push **之前**(与 core.js 的 inflateBytes 同款纪律):
        //   "先收后判"等于已经把超限数据存住了。
        overflow = true;
        chunks.length = 0;
        return;
      }
      if (!overflow) chunks.push(c);
    });
    req.on('end', function () {
      if (overflow) return reject(rejectTooLarge('请求体超过 ' + maxBytes + ' 字节上限'));
      resolve(Buffer.concat(chunks, total));
    });
    req.on('error', reject);
  });
}

// 写端点被**安全闸**拒掉时抛的错误:带一个显式标记,让 receiveMapFile 能把它与
// 「真的写失败了」分开 —— 前者是**拒绝**(403,再来一次也一样),后者是**故障**(500)。
// ★ 用标记而不是认错误文本:文本会被将来改字面量的人改掉,而标记改了会当场红。
function rejectWrite(message) {
  const e = new Error(message);
  e.writeRejected = true;
  return e;
}

// ── 写路径的**符号链接**二次包含性检查(硬要求 B)──
// ★ mapPathFor 判的是**路径字符串**(裸文件名正则 + "拼出来的字符串必须落在 maps/ 里面"),
//   而 `fs.stat` / `fs.writeFile` / `fs.realpath` 这一族**会跟随符号链接**。对读端点这只是
//   低危(要求攻击者已经能往 maps/ 里放一个链接 —— 而那个链接多半是"解压一个压缩包""克隆
//   一个仓库"这类**看起来无害**的动作带进来的);写端点走同一条路径时会升级成
//   「把编辑器当任意文件写入器」⇒ 这里按**真实路径**再判一次。
// ★ 整个比较都在 realpath 空间里做(两边都从 realDir 出发):Windows 上 realpath 可能把
//   8.3 短名(ALEKSE~1)规整成长名,拿它去和 path.resolve 出来的**字面量**比会假红。
// ★ 「目标尚不存在」是**最正常**的情形(新建一张地图),不是错误:没有那个文件 ⇒
//   没有任何符号链接可以跟随 ⇒ 直接放行。只有 ENOENT 走这一支;目标**存在**却 realpath
//   不了(最典型的是**悬空**符号链接)一律 fail closed —— 判不了就不写。
function assertWriteTargetInside(mapsDir, target, name) {
  const realDir = fs.realpathSync(mapsDir);            // 调用方保证 mapsDir 已存在
  let st = null;
  try { st = fs.lstatSync(target); }
  catch (e) {
    if (!e || e.code !== 'ENOENT') throw rejectWrite('读不到地图目标的属性,拒绝写入:' + name +
      '(' + (e && e.code ? e.code : String(e)) + ')');
  }
  let realTarget;
  if (st === null) {
    // ★ 目标不存在 = 新建地图。先确认调用方给的路径**就是** mapsDir 正下方的直接子项
    //   (越过 mapPathFor 传进来的越界路径必须在这里被挡),再用 realDir 拼出它的真实路径
    //   —— 用 basename 拼会把 `..`/分隔符洗掉,反而成了绕过。
    if (path.resolve(path.dirname(target)) !== path.resolve(mapsDir)) {
      throw rejectWrite('地图目标不在 maps 目录正下方,拒绝写入:' + name);
    }
    realTarget = path.join(realDir, path.basename(target));
  } else {
    try { realTarget = fs.realpathSync(target); }
    catch (e) {
      throw rejectWrite('地图目标读不出真实路径(悬空符号链接?),拒绝写入:' + name +
        '(' + (e && e.code ? e.code : String(e)) + ')');
    }
  }
  if (realTarget.indexOf(realDir + path.sep) !== 0) {
    throw rejectWrite('地图目标经符号链接指到 maps 目录之外,拒绝写入:' + name +
      '(真实路径 ' + realTarget + ' 不在 ' + realDir + ' 里面)');
  }
}

// ── rename 的**可重试**错误码(待修 1)──
// ★ 为什么需要重试:Windows 上覆盖一个**还有打开句柄**的文件走的是
//   `MoveFileEx(REPLACE_EXISTING)`,它会被拒绝并报 `EPERM`(不是 EBUSY)—— 实测复现:
//   对一张已有地图连做 4 次 PUT,同时有读者在 GET 同一张图 → 4/4 全部 500;读者一停,
//   紧接着 2 次 PUT 立刻 200。而**本服务器自己的读路径就是那个持有者之一**
//   (`serveMapFile` 的 createReadStream 在流完之前一直攥着 fd),所以"载入后马上保存"
//   这种最普通的前端动作就能撞上。
// ★ 不限于本进程:杀毒扫描器、Windows Search、OneDrive/Dropbox 同步 `maps/` 目录,
//   任何持有者都给出同一个错误码 —— 这正是"重试"而不是"只在自家读路径上想办法"
//   的理由(改自家读路径只能消掉本进程那一半持有者)。
// ★ 只重试这三码,其余(`EIO`/`ENOENT`/`ENOSPC`/`EINVAL`…)一律**立即抛**:
//   重试一个"重试也没用"的错误码只是让用户多等一整套退避(现在最坏 ~510ms)才看到同一条错误信息。
const RENAME_RETRY_CODES = ['EPERM', 'EBUSY', 'EACCES'];
// ── 额度与退避(待修 1 的复审实测,见下面那张表;别凭感觉改这两个数)──
// ★★ 为什么是 12 而不是 5:出厂那一版(5 次 / 退避 20-160ms)是**照着论证写反了**的 ——
//    选型论证里"异步退避第 9 次成功"那个第 9 次,本身就**落在出厂额度 5 之外**。
//    复审用真 HTTP 服务器 + 真 61KB 地图(`factory1v1.cyrm`)+ 持续 GET 该图的读者 +
//    20 次连续 PUT 复跑,得到(失败数 / 20):
//
//      | 配置                        | 20 次 PUT 的失败数        |
//      |-----------------------------|---------------------------|
//      | 出厂(5 次 / 20-160ms)      | 6                     ★   |
//      | 去掉重试(MAX=1)的对照      | 14                        |
//      | 20 次 / 固定 50ms           | 0                     ★   |
//
//    本机复跑(同一手段,见 task-3-report.md 的复跑表;失败**全部**是 EPERM):
//      · 读者紧循环(周期 ≈1.5ms,比复审那台更狠)5 轮 × 20 次:
//        出厂 **34/100**、本档 **6/100**、12 次×固定 50ms 6/100、20 次×固定 50ms 1/100。
//      · 读者 ≈50ms 一轮:出厂 0/60、本档 0/60(普通场景本来就已修好)。
//    ★ 诚实边界两条,别把结论读过头:
//      ① 复审的 HTTP 组**可能被相位锁定**(退避是 2 的幂、读者 GET 周期约 10.5ms,近似整数倍
//         会让每次尝试落在同一相位 ⇒ 可能**高估**真实失败率);进程内那组(2MiB 图 + 逐块
//         read()、块间让出事件循环)不受此影响,结论一致 —— 故"预算不够宽"这个判断是稳的。
//      ② 本档**不是 0 失败**:在最狠的那个读者节奏下仍有 ~6% 残留(20 次 PUT 里约 1 次),
//         而 20 次×50ms 是 1/100。残留的根因是"读者几乎全程攥着 fd"这种极端形态,
//         真机上是"载入后马上保存"那一类**瞬时**持有 —— 出厂参数在那档就已 0/60。
//         想再压只能继续加额度(超出 dispatch 给的 10~12 上限),没做。
// ★ 退避**封顶在 50ms**(不是继续翻倍):12 次若继续翻倍,末次退避就到 20s、最坏总等待
//   两分钟量级 —— 那是用户会以为"卡死了"的档。封顶之后最坏总等待
//   = 20+40+9×50 ≈ **510ms**,仍是人的等待阈值以内。
//   ★ 别以为"封顶会拖累命中率":实测 12 次×固定 50ms(6/100)与本档 6/100 **打平** ——
//     封顶拿回的是"总等待有上界",没拿命中率去换。
// ★ **固有代价(照实说)**:目标**永久**不可写时(只读属性文件、被别人用独占句柄长期打开),
//   用户现在要多等这 ~510ms 才看到同一条 500。那正是"重试 EPERM"的必然成本,不是缺陷;
//   不加额度的代价则是"最普通的前端动作(载入后马上保存)常态性 500",两害相权取此。
const RENAME_MAX_ATTEMPTS = 12;
const RENAME_RETRY_BASE_MS = 20;
// 退避上限。理由见上(封顶而不是继续翻倍)。
const RENAME_RETRY_MAX_MS = 50;

function defaultSleep(ms) {
  return new Promise(function (r) { setTimeout(r, ms); });
}

// 带重试的 rename。★ `renameFn` 与 `sleepFn` **可注入**就是为了让测试**确定性** ——
// 「前两次抛 EPERM、第三次成功」这种事用"活的读写竞态"去测必然飘(要掐到读者正好在场的
// 那一瞬),注入之后它是纯逻辑,而且能顺带断言**尝试次数**(只断言"最终成功"的话,
// 把重试次数改成 1 也照样绿 —— 那等于没测)。
// ★★ 刻意**不做**同步退避(虽然 `Atomics.wait` 能同步睡):同步睡会把事件循环冻住,
//    而竞争者(正在流地图的那个读流)**恰恰需要事件循环转起来才能把 fd 关掉**。
//    实测(2MiB 地图 + 慢客户端):同步退避 21 次尝试 / 1270ms,期内读者前进 **0 字节**、
//    全部失败;异步退避同期读者前进 1.9MiB、第 9 次成功。同步版对这个 bug
//    **结构上无效**,不是参数没调好。
// ★ 返回 Promise 而不是同步值:这是 `writeMapAtomic` 由同步改成异步的直接原因,
//   契约变化与调用链的影响见该函数与 receiveMapFile 的注释。
function renameWithRetry(tmpPath, target, renameFn, sleepFn) {
  const rename = renameFn || function (a, b) { return fs.promises.rename(a, b); };
  const sleep = sleepFn || defaultSleep;
  let attempts = 0;
  function attempt() {
    attempts++;
    // ★ 包一层 Promise.resolve().then(...):注入的实现可能是**同步抛**(fs.renameSync
    //   就是),也可能是**异步 reject**(fs.promises.rename)。两种都得走同一条重试路径,
    //   否则同步抛那一支会直接穿出去、一次都不重试(而它正是默认实现的等价写法)。
    return Promise.resolve().then(function () { return rename(tmpPath, target); })
      .then(function () { return attempts; })
      .catch(function (e) {
        const code = e && e.code !== undefined ? String(e.code) : '';
        if (RENAME_RETRY_CODES.indexOf(code) < 0) throw e;          // 不在名单里 → 立即抛
        if (attempts >= RENAME_MAX_ATTEMPTS) throw e;               // 用完额度 → 照原样抛
        // ★ Promise.resolve(...) 兜住"注入一个同步的 sleepFn"(测试里就是一个空函数):
        //   注入契约因此是"返回什么都可以",同步/异步实现都走得通。
        // ★ 退避 = min(上限, base × 2^(n-1)) = 20/40/50/50/…(上限的理由见常量那一段)。
        const backoff = Math.min(RENAME_RETRY_MAX_MS,
                                 RENAME_RETRY_BASE_MS * Math.pow(2, attempts - 1));
        return Promise.resolve(sleep(backoff)).then(attempt);
      });
  }
  return attempt();
}

let tmpSeq = 0;
// 原子写:先写同目录的临时文件,再 rename 覆盖目标。
// ★ 临时文件必须落在**同一个目录**(同一卷)里:跨卷 rename 会退化成"复制 + 删除",
//   那就不是原子的了 —— 而这个函数的全部意义就是"断电也不会留下半截地图"。
// ★★ 本函数**是异步的**(返回 Promise),这是待修 1 带出来的契约变化:
//    rename 那一步走 renameWithRetry(理由见它的注释 —— 同步退避会把事件循环冻住、
//    反而让持有句柄的读者永远放不掉 fd)。调用方只有 receiveMapFile 一处,而它本来
//    就在 readBody 的 promise 链上,故**调用链零改动**(把返回值 return 出去即可)。
// ★ `renameFn` / `sleepFn` 是给测试的注入点(可选)。生产调用一律不传。
//   失败清理留在**同一个 catch** 里(注入与否都覆盖得到):临时文件必须删掉,
//   否则每次失败都在 maps/ 里留垃圾。
async function writeMapAtomic(mapsDir, name, bytes, renameFn, sleepFn) {
  const target = mapPathFor(mapsDir, name);
  fs.mkdirSync(mapsDir, { recursive: true });
  // ★★ 闸在**建目录之后、碰任何文件之前**:realpath 要求目录已存在,而"被拒的写一个字节都
  //    不许落盘"这条不变量就靠这个顺序(它也是"原文件逐字节没变"那条断言的实现基础)。
  assertWriteTargetInside(mapsDir, target, name);
  const tmp = target + '.' + process.pid + '.' + (++tmpSeq) + '.tmp';
  try {
    fs.writeFileSync(tmp, bytes);
    await renameWithRetry(tmp, target, renameFn, sleepFn);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (e2) { /* 清理失败不改写主错误 */ }
    throw e;
  }
  return { name: name, size: bytes.length };
}

function receiveMapFile(req, res, name, ctx) {
  readBody(req, ctx.maxMapBytes).then(function (buf) {
    // ★ 空体一律拒:一个坏掉的前端循环最可能的表现就是"发出一个空 PUT",
    //   那会把一张好地图**无声地清零**。宁可回 400 让用户自己删文件。
    if (buf.length === 0) {
      sendText(res, 400, '空请求体:拒绝用空内容覆盖地图');
      return;
    }
    // ★★ 必须**return** 出去(待修 1):writeMapAtomic 现在返回 Promise,不 return 的话
    //    它的失败会成为一个**无人认领的 rejection**(既不会被下面的 .catch 接住,
    //    也不会回给客户端 —— 症状正是"PUT 永不回响应"这类最难查的形态)。
    return writeMapAtomic(ctx.mapsDir, name, buf).then(function (out) {
      ctx.logger('写入 ' + name + ' ' + out.size + ' 字节');
      sendJson(res, 200, out);
    });
  }).catch(function (err) {
    const msg = (err && err.message) ? err.message : String(err);
    // ★ M3:413 与下面的 403 用**同一款判据**——显式标记,而不是 `msg.indexOf('上限')`。
    //   认得是错误文本的话,哪天有人把 readBody 里那句消息改个词,413 就静默退化成 500
    //   (而 500 在用户眼里是"服务器坏了",不是"这份文件太大了")。
    if (err && err.tooLarge === true) { sendText(res, 413, msg); return; }
    // ★ 安全闸的拒绝(符号链接指到 maps/ 之外等)与"真的写失败了"分开,理由见 rejectWrite。
    if (err && err.writeRejected === true) { sendText(res, 403, msg); return; }
    sendText(res, 500, '写入失败:' + msg);
  });
}

// ★ Host 白名单闸(所有路由之前)。
//   只绑 127.0.0.1 **挡不住 DNS rebinding**:用户访问一个恶意页面时,那个页面可以把
//   自己的域名解析到 127.0.0.1,于是它就以**同源**身份打到这个服务器上 —— 绑回环完全帮不上忙。
//   今天它只读一个源码目录,危害有限;但只要长出可写接口(计划里的 `PUT /api/map`),
//   它就是「从任意网页触发的任意文件写入」。
//   ★ 判据是 Host 头必须点名**回环主机 + 本服务器实际监听的端口**:
//     正常浏览器访问 http://127.0.0.1:8777/ 发的就是 `127.0.0.1:8777`,而 rebinding 打过来时
//     Host 是那个恶意域名 ⇒ 正好被挡。端口取 `req.socket.localPort`(**不要写死 8777**:
//     startServer 支持 port:0 由系统分配,冒烟测试正是这么跑的)。
const ALLOWED_HOSTS = ['127.0.0.1', 'localhost'];
function hostAllowed(req) {
  const localPort = req.socket ? req.socket.localPort : 0;
  if (!localPort) return false;                       // 拿不到监听端口 → 一律拒(宁严勿松)
  const host = String(req.headers.host || '').toLowerCase();
  // ★ 判据取「host:port 全等」,**不含裸主机名**:浏览器/curl 访问非默认端口时一定带端口,
  //   放行裸名只会多开一扇门(而且裸名只在 80 端口才有意义,那不是本服务器)。
  return ALLOWED_HOSTS.some(function (h) { return host === h + ':' + localPort; });
}

// ── 写端点的 CSRF 闸(硬要求 A)──
// ★ Host 白名单闸(见 hostAllowed)挡的是 **DNS rebinding**,它挡不住这一类:一个恶意页面
//   可以直接 `fetch('http://127.0.0.1:8777/api/map', { method: 'PUT', body })` —— 此时浏览器
//   发的 `Host` **就是** `127.0.0.1:8777`,完全合法,闸照过。
//   读端点安全(不发 CORS 头 ⇒ 跨源读不到响应体),但**写端点**上,一个「简单请求」
//   (不触发预检的那些组合:GET/HEAD/POST + 三种 CORS 安全内容类型 text/plain、
//    multipart/form-data、application/x-www-form-urlencoded)会被浏览器**直接发出去、不经预检**
//   ⇒ 会被本服务器处理。
// ★ 所以写端点必须自己要求一个**非简单**的形态,逼浏览器先发预检;而预检我们一个 CORS 头都不答
//   ⇒ 浏览器根本不会把那条写请求发出来。两道一起上(纵深防御):
//     ① 内容类型必须是 application/json(CORS 安全名单之外 ⇒ 必然触发预检)—— 逼预检的那一条
//     ② Origin(带了就必须是本服务器自己的两个回环名字)—— 精确判据,主闸
//     ③ Sec-Fetch-Site: cross-site —— 只在**没有 Origin 可判**时兜底(理由见 writeGuardReject ②)
// ★★ 反过来:**绝不要加 `Access-Control-Allow-Origin`** —— 那等于把预检答成"通过",
//    会把本来安全的**读**端点一起拖下水(跨源就能读到响应体了)。冒烟相位 ⑦ 钉住这一点。
const WRITE_CONTENT_TYPE = 'application/json';

// 返回 null = 放行;返回 {status, message} = 拒。
function writeGuardReject(req) {
  // ① 内容类型。★ 只比**分号之前**的 media type:浏览器 fetch 带 charset 时会发
  //    `application/json; charset=utf-8`,按整串比会**误伤自家前端**。
  const raw = String(req.headers['content-type'] || '');
  const mediaType = raw.split(';')[0].trim().toLowerCase();
  if (mediaType !== WRITE_CONTENT_TYPE) {
    return { status: 415, message: '写端点只接受 Content-Type: ' + WRITE_CONTENT_TYPE +
      '(非简单内容类型 ⇒ 跨源的浏览器请求会先发预检,而预检不被放行);实得 ' +
      JSON.stringify(raw === '' ? '(缺失)' : raw) };
  }
  // ② Origin:跨源的非简单请求一定会带它,而且**伪造不了**(页面改不了自己的来源)。
  //    合法来源只有"本服务器自己"的两个回环名字。端口取 `req.socket.localPort`
  //    (理由同 hostAllowed:冒烟跑在 port:0 上,写死 8777 会把测试全判红)。
  const localPort = req.socket ? req.socket.localPort : 0;
  const origin = req.headers['origin'];
  if (origin !== undefined) {
    const sameOrigin = localPort && ALLOWED_HOSTS.some(function (h) {
      return origin === 'http://' + h + ':' + localPort;
    });
    if (!sameOrigin) {
      return { status: 403, message: '跨源写被拒:Origin: ' + String(origin) +
        '(只接受 http://127.0.0.1:' + localPort + ' / http://localhost:' + localPort + ')' };
    }
    // ★★ Origin 有效时**就此放行,不再看 Sec-Fetch-Site** —— 这条不是疏忽:
    //    `localhost` 与 `127.0.0.1` 按 Fetch 的"同站"定义是**两个站**,所以一个从
    //    http://localhost:8777 打开的编辑器页去写 http://127.0.0.1:8777 时,浏览器会诚实地
    //    标成 `Sec-Fetch-Site: cross-site` —— 那**是我们自己**(见上面那个白名单),
    //    拿它去拒就等于"用 localhost 打开编辑器就存不进任何地图"。精确的判据是 Origin,
    //    它是本函数的**主闸**;Sec-Fetch-Site 只在**没有 Origin 可判**时兜底(见 ③)。
    return null;
  }
  // ③ Sec-Fetch-Site:浏览器**专有**头(在 forbidden header 名单上,页面 JS 改不了它)。
  //    只在 ② 无从判断时用它兜底。★ 非浏览器客户端(冒烟/curl)两个头都不带 ⇒ 走到这儿
  //    仍放行,由上面那道类型闸兜着(它才是逼预检的那一条)。
  const site = req.headers['sec-fetch-site'];
  if (site === 'cross-site') {
    return { status: 403, message: '跨源写被拒:没有 Origin 可判,而 Sec-Fetch-Site 是 ' +
      String(site) };
  }
  return null;
}

// /api/* 的分派。
function handleApi(req, res, parsed, ctx) {
  if (parsed.pathname === '/api/maps') {
    if (req.method !== 'GET' && req.method !== 'HEAD') return sendText(res, 405, '只接受 GET');
    const maps = listMaps(ctx.mapsDir, ctx.logger);
    ctx.logger('列出 ' + maps.length + ' 张地图');
    return sendJson(res, 200, { maps: maps });
  }
  if (parsed.pathname === '/api/map') {
    const name = parsed.searchParams.get('p');
    // ★ 名字不过关一律在**碰文件系统之前**回 400。
    if (!isValidMapName(name)) {
      return sendText(res, 400,
        '地图名非法(只接受裸文件名 ' + MAP_NAME_RE.source + '):' + JSON.stringify(name));
    }
    const target = mapPathFor(ctx.mapsDir, name);
    if (req.method === 'GET' || req.method === 'HEAD') {
      return serveMapFile(res, target, name, req.method === 'HEAD');
    }
    if (req.method === 'PUT') {
      // ★ 写闸排在 receiveMapFile **之前**:被它拒掉的请求一个字节都不碰盘(名字合法
      //   **不等于**可以写)。见 writeGuardReject 的文件头。
      const bad = writeGuardReject(req);
      if (bad) return sendText(res, bad.status, bad.message);
      return receiveMapFile(req, res, name, ctx);
    }
    return sendText(res, 405, '只接受 GET / PUT');
  }
  return sendText(res, 404, '未知接口 ' + parsed.pathname);
}

function createServer(opts) {
  opts = opts || {};
  const ctx = {
    rootDir: opts.rootDir || DEFAULT_ROOT_DIR,
    mapsDir: opts.mapsDir || DEFAULT_MAPS_DIR,
    indexName: opts.index || DEFAULT_INDEX,
    maxMapBytes: opts.maxMapBytes === undefined ? MAX_MAP_BYTES : opts.maxMapBytes,
    logger: opts.logger || function () {},
  };
  return http.createServer(function (req, res) {
    // ★ 所有路由之前(静态与 /api/* 都过):见 ALLOWED_HOSTS 的说明。
    if (!hostAllowed(req)) {
      return sendText(res, 403, 'Host 头不被接受:' + String(req.headers.host || '(缺失)') +
                                '(只接受本机回环地址)');
    }
    let parsed;
    try { parsed = new URL(req.url, 'http://' + DEFAULT_HOST); }
    catch (e) { return sendText(res, 400, '请求 URL 非法'); }
    if (parsed.pathname.indexOf('/api/') === 0) return handleApi(req, res, parsed, ctx);
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return sendText(res, 405, '静态路径只接受 GET/HEAD,收到 ' + req.method);
    }
    serveStatic(res, staticFileFor(ctx.rootDir, parsed.pathname, ctx.indexName), req.method === 'HEAD');
  });
}

// 端口占用时"点名是谁占的"(规格 §7 风险登记)。
// ★ 尽力而为:拿不到就退回一句让用户自己查的命令,**绝不抛错** ——
//   它的唯一职责是把错误信息写清楚,它自己失败会把"起不来"变成"起不来且不知道为什么"。
function describePortOwner(port) {
  const hint = '  查占用者:netstat -ano | findstr :' + port + '(最后一列是 PID),再 taskkill /PID <PID> /F';
  if (process.platform !== 'win32') return hint;
  try {
    const out = execFileSync('netstat', ['-ano'], { encoding: 'utf8' });
    const lines = out.split(/\r?\n/).filter(function (l) {
      return l.indexOf(':' + port) >= 0 && /LISTENING/i.test(l);
    });
    if (lines.length) {
      return '  占用者:\n' + lines.map(function (l) { return '    ' + l.trim(); }).join('\n') + '\n' + hint;
    }
  } catch (e) { /* 拿不到就只给 hint */ }
  return hint;
}

function openBrowser(url) {
  try {
    if (process.platform === 'win32') {
      spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore' }).unref();
    } else if (process.platform === 'darwin') {
      spawn('open', [url], { detached: true, stdio: 'ignore' }).unref();
    } else {
      spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref();
    }
  } catch (e) {
    console.error('[editor] 打开浏览器失败(请手动访问 ' + url + '):' + e.message);
  }
}

// 绑定并起服务。port:0 = 由系统分配一个空闲端口(冒烟测试用,互不打架)。
function startServer(opts) {
  opts = opts || {};
  const host = opts.host || DEFAULT_HOST;
  const port = opts.port === undefined ? DEFAULT_PORT : opts.port;
  const server = createServer(opts);
  return new Promise(function (resolve, reject) {
    server.once('error', function (err) {
      if (err && err.code === 'EADDRINUSE') {
        return reject(new Error('端口 ' + port + ' 已被占用 —— 编辑器服务器起不来。\n' +
                                describePortOwner(port)));
      }
      reject(err);
    });
    server.listen(port, host, function () {
      const addr = server.address();
      const url = 'http://' + host + ':' + addr.port + '/';
      // ★ 默认**不**弹浏览器:弹浏览器是命令行入口的事(startServer 是给测试与嵌入方用的)。
      //   反过来(库默认弹)会让每一个冒烟用例都在开发机上弹出一个浏览器窗口。
      if (opts.openBrowser === true) openBrowser(url);
      resolve({ server: server, port: addr.port, host: host, url: url });
    });
  });
}

function parseArgs(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--no-open') o.openBrowser = false;
    else if (a === '--port') { const n = parseInt(argv[++i], 10); if (isFinite(n)) o.port = n; }
    else if (a === '--maps') o.mapsDir = argv[++i];
    else if (a === '--root') o.rootDir = argv[++i];
    else console.error('[editor] 未知参数 ' + a);
  }
  return o;
}

if (require.main === module) {
  const opts = parseArgs(process.argv.slice(2));
  // ★ 只有命令行入口默认开浏览器;--no-open 关掉(parseArgs 会写进 openBrowser:false)。
  startServer(Object.assign({ openBrowser: true }, opts)).then(function (r) {
    console.log('[editor] 服务器就绪 ' + r.url);
    console.log('[editor] 静态根 ' + path.resolve(opts.rootDir || DEFAULT_ROOT_DIR));
    console.log('[editor] 地图目录 ' + path.resolve(opts.mapsDir || DEFAULT_MAPS_DIR));
  }).catch(function (err) {
    console.error('[editor] 启动失败:' + (err && err.message ? err.message : String(err)));
    process.exit(1);
  });
}

module.exports = {
  DEFAULT_HOST: DEFAULT_HOST, DEFAULT_PORT: DEFAULT_PORT,
  DEFAULT_ROOT_DIR: DEFAULT_ROOT_DIR, DEFAULT_MAPS_DIR: DEFAULT_MAPS_DIR,
  DEFAULT_INDEX: DEFAULT_INDEX, MAX_MAP_BYTES: MAX_MAP_BYTES,
  MIME: MIME, mimeOf: mimeOf, sendText: sendText, sendJson: sendJson,
  staticFileFor: staticFileFor, serveStatic: serveStatic, handleApi: handleApi,
  MAP_NAME_RE: MAP_NAME_RE, MAX_MAP_NAME_LEN: MAX_MAP_NAME_LEN,
  isValidMapName: isValidMapName, mapPathFor: mapPathFor, listMaps: listMaps,
  serveMapFile: serveMapFile,
  WRITE_CONTENT_TYPE: WRITE_CONTENT_TYPE, writeGuardReject: writeGuardReject,
  readBody: readBody, rejectWrite: rejectWrite,
  RENAME_RETRY_CODES: RENAME_RETRY_CODES, RENAME_MAX_ATTEMPTS: RENAME_MAX_ATTEMPTS,
  RENAME_RETRY_BASE_MS: RENAME_RETRY_BASE_MS, RENAME_RETRY_MAX_MS: RENAME_RETRY_MAX_MS,
  renameWithRetry: renameWithRetry,
  assertWriteTargetInside: assertWriteTargetInside, writeMapAtomic: writeMapAtomic,
  receiveMapFile: receiveMapFile,
  createServer: createServer, startServer: startServer,
  describePortOwner: describePortOwner, openBrowser: openBrowser, parseArgs: parseArgs,
};
