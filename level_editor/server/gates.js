'use strict';

const fs = require('fs');
const path = require('path');

// Host 白名单闸(所有路由之前):只绑 127.0.0.1 挡不住 DNS rebinding —— 恶意页面把自己的域名解析到
// 回环,就以同源身份打进来。判据 = Host 必须点名回环主机 + 本服务器实际监听的端口(不写死 8777)。
const ALLOWED_HOSTS = ['127.0.0.1', 'localhost'];

function hostAllowed(req) {
  const localPort = req.socket ? req.socket.localPort : 0;
  if (!localPort) return false;                       // 拿不到监听端口 → 一律拒(宁严勿松)
  const host = String(req.headers.host || '').toLowerCase();
  return ALLOWED_HOSTS.some(function (h) { return host === h + ':' + localPort; });   // 不含裸主机名
}

// 写端点的 CSRF 闸:恶意页面可以直接 fetch 本服务器(那时 Host 合法,上面那道闸照过)⇒ 写端点自己要求
// 一个非简单形态逼浏览器先发预检,而预检我们一个 CORS 头都不答。★ 绝不加 Access-Control-Allow-Origin:
// 那等于把预检答成通过,会把本来安全的读端点一起拖下水。
const WRITE_CONTENT_TYPE = 'application/json';

function writeGuardReject(req) {
  const raw = String(req.headers['content-type'] || '');
  const mediaType = raw.split(';')[0].trim().toLowerCase();   // 只比分号之前:按整串比会误伤带 charset 的自家前端
  if (mediaType !== WRITE_CONTENT_TYPE) {
    return { status: 415, message: '写端点只接受 Content-Type: ' + WRITE_CONTENT_TYPE +
      '(非简单内容类型 ⇒ 跨源的浏览器请求会先发预检,而预检不被放行);实得 ' +
      JSON.stringify(raw === '' ? '(缺失)' : raw) };
  }
  // ② Origin:主闸。跨源的非简单请求一定会带它,而页面伪造不了自己的来源。
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
    // ★ Origin 有效就此放行,不再看 Sec-Fetch-Site:localhost 与 127.0.0.1 按 Fetch 的"同站"定义是两个
    //   站,从前者打开的编辑器去写后者时浏览器会诚实标 cross-site —— 拿它拒等于自家前端存不进任何地图。
    return null;
  }
  // ③ Sec-Fetch-Site:浏览器专有头,只在 ② 无从判断时兜底(非浏览器客户端两个头都不带,由类型闸兜着)。
  const site = req.headers['sec-fetch-site'];
  if (site === 'cross-site') {
    return { status: 403, message: '跨源写被拒:没有 Origin 可判,而 Sec-Fetch-Site 是 ' +
      String(site) };
  }
  return null;
}

// 安全闸拒掉写时用标记而不是认错误文本:改字面量不会让 403 静默退化成 500(同 readBody 的 rejectTooLarge)。
function rejectWrite(message) {
  const e = new Error(message);
  e.writeRejected = true;
  return e;
}

// 写路径的符号链接二次包含性检查:mapPathFor 判的只是路径字符串,而 fs.stat/writeFile/realpath 会跟随链接。
// 两边都在 realpath 空间里比 —— Windows 上 realpath 会把 8.3 短名规整成长名,拿字面量比会假红。
// 目标不存在 = 新建地图(没有链接可跟随)⇒ 放行;存在却 realpath 不了(悬空链接)一律 fail closed。
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
    if (path.resolve(path.dirname(target)) !== path.resolve(mapsDir)) {   // 越过 mapPathFor 的越界路径在这里被挡
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

module.exports = {
  ALLOWED_HOSTS: ALLOWED_HOSTS, hostAllowed: hostAllowed,
  WRITE_CONTENT_TYPE: WRITE_CONTENT_TYPE, writeGuardReject: writeGuardReject,
  rejectWrite: rejectWrite, assertWriteTargetInside: assertWriteTargetInside,
};
