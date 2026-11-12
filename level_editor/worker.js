'use strict';

importScripts('tile_defs.js', 'core.js');

self.onmessage = async ({data: {id, op, map, bytes, compress}}) => {
  try {
    let result;
    switch (op) {
      case 'ping': result = {pong: true}; break;
      case 'encode': result = {bytes: await Core.encodeMap(map, {compress})}; break;
      case 'decode': result = {map: await Core.decodeMap(bytes)}; break;
      case 'import': result = await Core.importMap(bytes); break;
      default: throw new Error('未知的编解码操作 ' + op);
    }
    self.postMessage({id, ok: true, ...result});
  } catch (error) {
    self.postMessage({id, ok: false, error: error.message});
  }
};
