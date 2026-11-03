'use strict';

const fs = require('fs');

const { isValidMapName, mapPathFor, MAP_NAME_RE } = require('./map_names.js');
const { writeGuardReject, assertWriteTargetInside } = require('./gates.js');
const { withTransientRetry } = require('./atomic_write.js');
const { sendText, sendJson } = require('./http_util.js');

// 地图的"真动作"(改名 / 删除)。★ 服务器仍然不做格式校验(它是哑文件服务器),这里只碰文件系统。
// ★★ 两道纪律覆盖这两个端点:
//   ① 写面只有一条包含性闸(mapPathFor 的裸文件名 + assertWriteTargetInside 的 realpath),
//      rename 的**两个**名字都要过,DELETE 的那一个也要过 —— 别为了"读"放过任何一边。
//   ② 先判完所有能判的(名字 / 越界 / 存在性),最后一个动作才是碰盘;失败路径一个字节都不动。

// 带 HTTP 状态码的失败:handler 只看 e.status,不认错误文本(同 rejectWrite / rejectTooLarge 那条纪律)。
function httpError(status, message) {
  const e = new Error(message);
  e.status = status;
  return e;
}

function msgOf(e) {
  const m = (e && e.message !== undefined) ? String(e.message) : String(e);
  return m === '' && e && e.cause && e.cause.message ? String(e.cause.message) : m;
}

function requireMapsDir(mapsDir) {
  let st = null;
  try { st = fs.statSync(mapsDir); } catch (e) { st = null; }
  if (!st || !st.isDirectory()) throw httpError(404, '地图目录不存在,库里没有可操作的地图:' + String(mapsDir));
}

function checkName(which, name) {
  if (name === null || name === undefined || name === '') {
    throw httpError(400, '缺少参数 ' + which + '(要一个裸文件名)');
  }
  if (typeof name !== 'string' || !isValidMapName(name)) {
    throw httpError(400, '地图名非法(' + which + '):' + JSON.stringify(name) +
                         ' —— 只接受裸文件名 ' + MAP_NAME_RE.source);
  }
}

// 名字 → 绝对路径,并把写面的包含性闸过一遍(越界 / 指向外部的符号链接一律 403)。
function resolveTarget(mapsDir, name, which) {
  let target;
  try { target = mapPathFor(mapsDir, name); }
  catch (e) { throw httpError(400, '地图名非法(' + which + '):' + msgOf(e)); }
  try { assertWriteTargetInside(mapsDir, target, name); }
  catch (e) {
    if (e && e.writeRejected === true) throw httpError(403, msgOf(e));
    throw httpError(500, '校验地图目标失败:' + msgOf(e));
  }
  return target;
}

function existsPath(p) {
  try { fs.lstatSync(p); return true; } catch (e) {
    if (e && e.code === 'ENOENT') return false;
    throw httpError(500, '读不到地图目标的属性:' + p + '(' + (e && e.code ? e.code : msgOf(e)) + ')');
  }
}

// 只认普通文件(跟随符号链接)。同名目录不算地图 —— 与 serveMapFile 的 404 口径一致,
// 否则 rename 一个目录会成功、DELETE 一个目录会 500,同一个东西两种说法。
function requireMapFile(p, name) {
  let st = null;
  try { st = fs.statSync(p); } catch (e) {
    if (e && e.code === 'ENOENT') throw httpError(404, '找不到地图 ' + name);
    throw httpError(500, '读不到地图 ' + name + ' 的属性(' + (e && e.code ? e.code : msgOf(e)) + ')');
  }
  if (!st.isFile()) throw httpError(404, '找不到地图 ' + name + '(那不是文件)');
}

// 改名:from → to,同盘 fs.rename(原子;跨卷才退化成复制+删除,而两个名字都在同一个 mapsDir 里)。
// ★ 目标已存在一律 409 **不覆盖**:覆盖式改名 = 一次手滑抹掉另一张图,而 DELETE 之后没有任何撤销。
async function renameMap(mapsDir, from, to, deps) {
  deps = deps || {};
  requireMapsDir(mapsDir);
  checkName('from', from);
  checkName('to', to);
  if (from === to) throw httpError(400, 'from 与 to 是同一个名字,没有可改的东西:' + from);
  const fromPath = resolveTarget(mapsDir, from, 'from');
  const toPath = resolveTarget(mapsDir, to, 'to');
  requireMapFile(fromPath, from);
  if (existsPath(toPath)) throw httpError(409, '目标已存在,拒绝覆盖:' + to);
  try {
    // 注入 renameFn/sleepFn 只为测试确定性;生产走 fs.promises.rename + 共享的瞬态重试额度。
    await withTransientRetry(function () {
      return deps.renameFn ? deps.renameFn(fromPath, toPath) : fs.promises.rename(fromPath, toPath);
    }, deps.sleepFn);
  } catch (e) {
    const code = e && e.code ? String(e.code) : '';
    if (code === 'ENOENT') throw httpError(404, '找不到地图 ' + from + '(改名途中被删掉了?)');
    if (code === 'EEXIST' || code === 'ENOTEMPTY') throw httpError(409, '目标已存在,拒绝覆盖:' + to);
    throw httpError(500, '改名失败:' + msgOf(e) + '(文件可能正被别的程序占用,稍后重试)');
  }
  return { ok: true, name: to };
}

// 删除:fs.unlink 真删。★ 误删的退路只有两条:① maps/ 里的图由 git 跟踪(git checkout -- maps/<名>),
// ② 还没提交过的新图**没有**退路 —— 这一句写在 docs/eng/editor-server.md 的端点契约里。
async function deleteMap(mapsDir, name, deps) {
  deps = deps || {};
  requireMapsDir(mapsDir);
  checkName('p', name);
  const target = resolveTarget(mapsDir, name, 'p');
  requireMapFile(target, name);
  try {
    await withTransientRetry(function () {
      return deps.unlinkFn ? deps.unlinkFn(target) : fs.promises.unlink(target);
    }, deps.sleepFn);
  } catch (e) {
    const code = e && e.code ? String(e.code) : '';
    if (code === 'ENOENT') throw httpError(404, '找不到地图 ' + name);
    throw httpError(500, '删除失败:' + msgOf(e) + '(文件可能正被别的程序占用,稍后重试)');
  }
  return { ok: true, deleted: name };
}

// ── HTTP 层:两个端点共用同一段"方法 → 名字 → 写闸 → 动作 → 回包"的形状 ──
function sendError(res, err, verb) {
  const status = (err && Number.isInteger(err.status)) ? err.status : 500;
  const msg = (err && err.message) ? msgOf(err) : String(err);
  sendText(res, status, status >= 500 ? (verb + '失败:' + msg) : msg);
}

function writeGateReject(req, res) {
  const bad = writeGuardReject(req);
  if (!bad) return false;
  sendText(res, bad.status, bad.message);
  return true;
}

function handleMapRename(req, res, parsed, ctx) {
  if (req.method !== 'POST') return sendText(res, 405, '只接受 POST');
  // 本端点不用请求体(参数全在 query 上),但页面会带一个 '{}' 占位:把它排掉再回包,
  // 否则未读的 body 会让 keep-alive 连接在响应之后被重置(下一次请求偶发 ECONNRESET)。
  if (typeof req.resume === 'function') req.resume();
  const from = parsed.searchParams.get('from');
  const to = parsed.searchParams.get('to');
  // 名字闸排在写闸之前:与 PUT 同一形状(api.js 也是先判名字),且它不碰盘。
  try { checkName('from', from); checkName('to', to); }
  catch (e) { return sendError(res, e, '改名'); }
  if (writeGateReject(req, res)) return undefined;
  return renameMap(ctx.mapsDir, from, to).then(function (out) {
    ctx.logger('改名 ' + from + ' → ' + to);
    sendJson(res, 200, out);
  }).catch(function (e) { sendError(res, e, '改名'); });
}

function handleMapDelete(req, res, parsed, ctx) {
  if (req.method !== 'DELETE') return sendText(res, 405, '只接受 DELETE');
  if (typeof req.resume === 'function') req.resume();      // 同 handleMapRename:不用 body,但要排掉
  const name = parsed.searchParams.get('p');
  try { checkName('p', name); } catch (e) { return sendError(res, e, '删除'); }
  if (writeGateReject(req, res)) return undefined;
  return deleteMap(ctx.mapsDir, name).then(function (out) {
    ctx.logger('删除 ' + name);
    sendJson(res, 200, out);
  }).catch(function (e) { sendError(res, e, '删除'); });
}

module.exports = {
  httpError: httpError, checkName: checkName, resolveTarget: resolveTarget,
  renameMap: renameMap, deleteMap: deleteMap,
  handleMapRename: handleMapRename, handleMapDelete: handleMapDelete,
};
