'use strict';

const path = require('path');

// 只绑回环;8777 刻意避开游戏侧已占用的一切端口(7777 大厅 / 7800+ worker / 7999 测试)。
// MAX_MAP_BYTES 与 core.js 的 MAX_BODY_SIZE 同值(合法地图最坏约 19.1MiB),只打跑飞的客户端。
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 8777;
const DEFAULT_ROOT_DIR = path.join(__dirname, '..');
const DEFAULT_MAPS_DIR = path.join(DEFAULT_ROOT_DIR, '..', 'maps');
const DEFAULT_INDEX = 'editor.html';
const MAX_MAP_BYTES = 64 * 1024 * 1024;

module.exports = {
  DEFAULT_HOST: DEFAULT_HOST, DEFAULT_PORT: DEFAULT_PORT,
  DEFAULT_ROOT_DIR: DEFAULT_ROOT_DIR, DEFAULT_MAPS_DIR: DEFAULT_MAPS_DIR,
  DEFAULT_INDEX: DEFAULT_INDEX, MAX_MAP_BYTES: MAX_MAP_BYTES,
};
