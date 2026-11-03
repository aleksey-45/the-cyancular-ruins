'use strict';
// editor_server.js —— 编辑器本地服务器的唯一入口:node editor_server.js
// [--port 8777] [--maps <dir>] [--root <dir>] [--no-open] [--keep] [--pid-file <path>]。
// 分片职责、实测记录与安全闸的完整理由见 docs/eng/editor-server.md。
// ★ 它是哑文件服务器:不校验 .cyrm 格式 —— 那是 core/ 的事。服务器再判一遍就是第二份格式实现,
//   分歧的症状是"编辑器存得下、游戏读不出",而且不报错。
// ★ 唯一的例外是**文件名之外的两条真动作**(改名 / 删除):它们不改一个字节的内容,只搬 / 删文件。

const path = require('path');

const {
  DEFAULT_HOST, DEFAULT_PORT, DEFAULT_ROOT_DIR, DEFAULT_MAPS_DIR, DEFAULT_INDEX, MAX_MAP_BYTES,
} = require('./server/defaults.js');
const { MIME, mimeOf, sendText, sendJson, readBody } = require('./server/http_util.js');
const { staticFileFor, serveStatic } = require('./server/static.js');
const { handleApi } = require('./server/api.js');
const {
  MAP_NAME_RE, MAX_MAP_NAME_LEN, isValidMapName, mapPathFor,
} = require('./server/map_names.js');
const { listMaps, serveMapFile } = require('./server/maps.js');
const {
  WRITE_CONTENT_TYPE, writeGuardReject, rejectWrite, assertWriteTargetInside,
} = require('./server/gates.js');
const {
  RENAME_RETRY_CODES, RENAME_MAX_ATTEMPTS, RENAME_RETRY_BASE_MS, RENAME_RETRY_MAX_MS,
  withTransientRetry, renameWithRetry, writeMapAtomic, receiveMapFile,
} = require('./server/atomic_write.js');
const {
  createServer, startServer, describePortOwner, openBrowser, parseArgs,
} = require('./server/server.js');
const instance = require('./server/instance.js');
const mapOps = require('./server/map_ops.js');

if (require.main === module) {
  const opts = parseArgs(process.argv.slice(2));
  const rootDir = opts.rootDir || DEFAULT_ROOT_DIR;
  const port = opts.port === undefined ? DEFAULT_PORT : opts.port;
  const pidFile = opts.pidFile || instance.pidFilePath(rootDir);
  // 单实例:先把上一个自己结束掉(判据见 server/instance.js 顶部;--keep 可关)。
  // ★ 替换逻辑放在命令行入口,**不动 startServer() 的拒绝语义** —— 那是库合同,有测试钉着。
  const prelude = opts.replaceStale === false
    ? Promise.resolve(null)
    : instance.replaceStaleInstance({ pidFile: pidFile, port: port }).then(function (rep) {
        if (rep && rep.replaced) return rep;
        // ★ 没有 PID 文件 / 记录已陈旧(第一次升级到本特性、老 serve.bat 起的孤儿…):
        //   再按"端口占用者 + 命令行认自己人"兜一次,判据同样严格,认不出就拒绝杀。
        return instance.reclaimOrphanOnPort({ port: port });
      }).catch(function (err) {
        // 拒绝杀 / 等不到端口释放:直接报清楚并且不启动(硬来会撞 EADDRINUSE,那句话更难懂)。
        console.error('[editor] 无法结束上一个实例:' + (err && err.message ? err.message : String(err)));
        process.exit(1);
      });
  prelude.then(function (rep) {
    if (rep && rep.replaced) console.log('[editor] 已结束旧实例 PID ' + rep.replaced);
    // 只有命令行入口默认开浏览器;--no-open 关掉(parseArgs 会写进 openBrowser:false)。
    return startServer(Object.assign({ openBrowser: true }, opts));
  }).then(function (r) {
    // PID 文件写的是**实际**端口(可能是 0 由系统分配),下次重启按它比对。
    instance.writePidFile(pidFile, {
      pid: process.pid, port: r.port, host: r.host,
      startedAt: new Date().toISOString(), argv: process.argv.slice(1),
    });
    instance.installPidCleanup(pidFile);
    console.log('[editor] 服务器就绪 ' + r.url);
    console.log('[editor] 静态根 ' + path.resolve(rootDir));
    console.log('[editor] 地图目录 ' + path.resolve(opts.mapsDir || DEFAULT_MAPS_DIR));
    console.log('[editor] PID 文件 ' + pidFile + '(PID ' + process.pid + ')');
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
  withTransientRetry: withTransientRetry, renameWithRetry: renameWithRetry,
  assertWriteTargetInside: assertWriteTargetInside, writeMapAtomic: writeMapAtomic,
  receiveMapFile: receiveMapFile,
  createServer: createServer, startServer: startServer,
  describePortOwner: describePortOwner, openBrowser: openBrowser, parseArgs: parseArgs,
  // ① 地图真动作(rename / delete)与 ③ 单实例 —— 分片在 server/map_ops.js 与 server/instance.js。
  renameMap: mapOps.renameMap, deleteMap: mapOps.deleteMap,
  handleMapRename: mapOps.handleMapRename, handleMapDelete: mapOps.handleMapDelete,
  pidFilePath: instance.pidFilePath, readPidFile: instance.readPidFile,
  writePidFile: instance.writePidFile, removePidFile: instance.removePidFile,
  replaceStaleInstance: instance.replaceStaleInstance, waitPortFree: instance.waitPortFree,
  reclaimOrphanOnPort: instance.reclaimOrphanOnPort, portOwnerPid: instance.portOwnerPid,
  isPortFree: instance.isPortFree, isAlive: instance.isAlive,
  PID_FILE_NAME: instance.PID_FILE_NAME, WAIT_PORT_FREE_MS: instance.WAIT_PORT_FREE_MS,
};
