'use strict';
// editor_server.js —— 编辑器本地服务器的唯一入口:node editor_server.js
// [--port 8777] [--maps <dir>] [--root <dir>] [--no-open]。分片职责、实测记录与安全闸的完整理由
// 见 docs/eng/editor-server.md。
// ★ 它是哑文件服务器:不校验 .cyrm 格式 —— 那是 core/ 的事。服务器再判一遍就是第二份格式实现,
//   分歧的症状是"编辑器存得下、游戏读不出",而且不报错。

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
  renameWithRetry, writeMapAtomic, receiveMapFile,
} = require('./server/atomic_write.js');
const {
  createServer, startServer, describePortOwner, openBrowser, parseArgs,
} = require('./server/server.js');

if (require.main === module) {
  const opts = parseArgs(process.argv.slice(2));
  // 只有命令行入口默认开浏览器;--no-open 关掉(parseArgs 会写进 openBrowser:false)。
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
