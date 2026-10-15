'use strict';

const path = require('path');

// 地图名守卫(唯一的安全边界):只接受裸文件名,后缀除 .cyrm 外只多一个 .v3.bak —— v3→v4 的转换
// 是单向的,保存前那份原文备份必须叫 <名>.v3.bak,且基名不许有 . 才写不出任意后缀的文件。
const MAP_NAME_RE = /^[A-Za-z0-9_\-]+(?:\.cyrm|\.v3\.bak)$/;
const MAX_MAP_NAME_LEN = 64;    // 正则没有长度上界;真名由 core.js 的 sanitizeName 生成,64 留一倍余量

function isValidMapName(name) {
  if (typeof name !== 'string') return false;
  if (name.length === 0 || name.length > MAX_MAP_NAME_LEN) return false;
  if (name.indexOf('\0') >= 0) return false;    // 正则本就不放行,再挡一次防的是"将来有人把正则改宽"
  return MAP_NAME_RE.test(name);
}

function mapPathFor(mapsDir, name) {
  if (!isValidMapName(name)) throw new Error('地图名非法:' + JSON.stringify(name));
  const dir = path.resolve(mapsDir);
  const target = path.resolve(dir, name);
  // 双保险:即便正则哪天被改宽,出去的路径也必须落在 maps/ 里面。
  if (target.indexOf(dir + path.sep) !== 0) throw new Error('地图名越出 maps 目录:' + name);
  return target;
}

module.exports = {
  MAP_NAME_RE: MAP_NAME_RE, MAX_MAP_NAME_LEN: MAX_MAP_NAME_LEN,
  isValidMapName: isValidMapName, mapPathFor: mapPathFor,
};
