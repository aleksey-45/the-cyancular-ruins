'use strict';

const fs = require('fs');

const { mapPathFor } = require('./map_names.js');
const { assertWriteTargetInside } = require('./gates.js');
const { sendText, sendJson, readBody } = require('./http_util.js');

// rename 的可重试错误码。Windows 上覆盖一个还有打开句柄的文件走 MoveFileEx(REPLACE_EXISTING),被拒时给的是
// EPERM(不是 EBUSY);持有者不限于本进程 —— 本服务器自己的读流、AV 扫描器、同步盘都会给出同一码,故对策是重试。
const RENAME_RETRY_CODES = ['EPERM', 'EBUSY', 'EACCES'];
// 只重试这三码:其余(EIO/ENOENT/ENOSPC/EINVAL…)立即抛,否则只是让用户多等一整套退避才看到同一条错误。
// 额度与退避(12 次 / base 20ms / 封顶 50ms,最坏总等待约 510ms)的实测依据见 docs/eng/editor-server.md。
const RENAME_MAX_ATTEMPTS = 12;
const RENAME_RETRY_BASE_MS = 20;
const RENAME_RETRY_MAX_MS = 50;      // 退避 = min(50, 20 × 2^(n-1));封顶是为了总等待有上界

function defaultSleep(ms) {
  return new Promise(function (r) { setTimeout(r, ms); });
}

// 带重试的 rename:注入 renameFn / sleepFn 是为了让测试确定性(「前两次 EPERM 第三次成功」拿活的读写竞态去测
// 必然飘),也才能顺带断言尝试次数 —— 只断言"最终成功"的话,把重试砍成 1 次也照样绿。
// ★★ 刻意不做同步退避(Atomics.wait 能同步睡):同步睡会把事件循环冻住,而竞争者(正在流地图的读流)恰恰需要
//    事件循环转起来才能把 fd 关掉 —— 同步版对这个 bug 结构上无效,不是参数没调好。
function renameWithRetry(tmpPath, target, renameFn, sleepFn) {
  const rename = renameFn || function (a, b) { return fs.promises.rename(a, b); };
  const sleep = sleepFn || defaultSleep;
  let attempts = 0;
  function attempt() {
    attempts++;
    // 包一层 Promise.resolve().then:注入的实现可能同步抛(fs.renameSync 就是)也可能异步 reject,两种都得走同一条重试路径。
    return Promise.resolve().then(function () { return rename(tmpPath, target); })
      .then(function () { return attempts; })
      .catch(function (e) {
        const code = e && e.code !== undefined ? String(e.code) : '';
        if (RENAME_RETRY_CODES.indexOf(code) < 0) throw e;          // 不在名单里 → 立即抛
        if (attempts >= RENAME_MAX_ATTEMPTS) throw e;               // 用完额度 → 照原样抛
        const backoff = Math.min(RENAME_RETRY_MAX_MS,
                                 RENAME_RETRY_BASE_MS * Math.pow(2, attempts - 1));
        return Promise.resolve(sleep(backoff)).then(attempt);       // 兜住注入的同步 sleepFn
      });
  }
  return attempt();
}

// 原子写:先写同目录的临时文件再 rename 覆盖。临时文件必须在同一目录(同一卷)—— 跨卷 rename 会退化成"复制 + 删除"。
let tmpSeq = 0;
async function writeMapAtomic(mapsDir, name, bytes, renameFn, sleepFn) {
  const target = mapPathFor(mapsDir, name);
  fs.mkdirSync(mapsDir, { recursive: true });
  assertWriteTargetInside(mapsDir, target, name);   // 闸必须在建目录之后(realpath 要求目录在)、碰任何文件之前
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
    // ★ 空体一律拒:坏掉的前端循环最可能的表现就是"发出一个空 PUT",那会把一张好地图无声清零。
    if (buf.length === 0) {
      sendText(res, 400, '空请求体:拒绝用空内容覆盖地图');
      return;
    }
    // ★★ 必须 return 出去:否则 writeMapAtomic 的失败是一个无人认领的 rejection,症状正是"PUT 永不回响应"。
    return writeMapAtomic(ctx.mapsDir, name, buf).then(function (out) {
      ctx.logger('写入 ' + name + ' ' + out.size + ' 字节');
      sendJson(res, 200, out);
    });
  }).catch(function (err) {
    const msg = (err && err.message) ? err.message : String(err);
    if (err && err.tooLarge === true) { sendText(res, 413, msg); return; }        // 分流用显式标记,不认错误文本
    if (err && err.writeRejected === true) { sendText(res, 403, msg); return; }
    sendText(res, 500, '写入失败:' + msg);
  });
}

module.exports = {
  RENAME_RETRY_CODES: RENAME_RETRY_CODES, RENAME_MAX_ATTEMPTS: RENAME_MAX_ATTEMPTS,
  RENAME_RETRY_BASE_MS: RENAME_RETRY_BASE_MS, RENAME_RETRY_MAX_MS: RENAME_RETRY_MAX_MS,
  renameWithRetry: renameWithRetry, writeMapAtomic: writeMapAtomic,
  receiveMapFile: receiveMapFile,
};
