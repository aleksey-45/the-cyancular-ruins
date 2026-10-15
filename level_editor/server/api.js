'use strict';

const { sendText, sendJson } = require('./http_util.js');
const { isValidMapName, mapPathFor, MAP_NAME_RE } = require('./map_names.js');
const { listMaps, serveMapFile } = require('./maps.js');
const { writeGuardReject } = require('./gates.js');
const { receiveMapFile } = require('./atomic_write.js');

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
    // 名字不过关一律在碰文件系统之前回 400。
    if (!isValidMapName(name)) {
      return sendText(res, 400,
        '地图名非法(只接受裸文件名 ' + MAP_NAME_RE.source + '):' + JSON.stringify(name));
    }
    const target = mapPathFor(ctx.mapsDir, name);
    if (req.method === 'GET' || req.method === 'HEAD') {
      return serveMapFile(res, target, name, req.method === 'HEAD');
    }
    if (req.method === 'PUT') {
      // 写闸排在 receiveMapFile 之前:被它拒掉的请求一个字节都不碰盘(名字合法不等于可以写)。
      const bad = writeGuardReject(req);
      if (bad) return sendText(res, bad.status, bad.message);
      return receiveMapFile(req, res, name, ctx);
    }
    return sendText(res, 405, '只接受 GET / PUT');
  }
  return sendText(res, 404, '未知接口 ' + parsed.pathname);
}

module.exports = { handleApi: handleApi };
