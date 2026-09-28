// cyrm v4 二进制编解码(2026-09-28 落地编辑器读入)。
// 与游戏侧 core/sim/map_format_v4.gd 共享同一套字节语义(docs/superpowers/specs/
// 2026-09-19-cyrm-v4-editor-design.md §3):
//   头 20 字节:magic "CYRM" / ver=4 / compression(0=裸,1=deflate=zlib RFC1950)/
//   body_size u32LE(解压后) / crc32 u32LE(解压后 body)/ sub_cols u16LE / sub_rows u16LE /
//   layer_flags(bit0..3=前景/场景/后景/背景) / reserved
//   body:u16 meta_len + meta_utf8(原 "# player x y" 注释行,坐标以 64px 格计)+ 逐层块
//   纹理层:kind=1 + u16 调色板数 + 调色板 u32LE(描述符)+ index_width(1/2)+ 索引流(行主序)
//   背景层:kind=2 + subCols*subRows*4 字节 RGBA
//   描述符 u32:bit0-2 hue / 3-5 bri / 6-8 sat / 9-11 alpha / 12-23 texture(0=空气)
// 编辑器导入只消费「场景」层(唯一碰撞层):flattenScene 把 4×4 子格压回
// "单纹理 + 2×2 形状掩码"的旧网格模型 —— 对 v3 迁移图逐格无损;对真 4×4 混排图
// 取出现最多的纹理(旧编辑器的单层模型本就表达不了格内混排)。
(function (root) {
  'use strict';

  const CRC_TABLE = (function () {
    const t = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
      let c = i;
      for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      t[i] = c >>> 0;
    }
    return t;
  })();

  function crc32(u8) {
    let crc = 0xFFFFFFFF;
    for (let i = 0; i < u8.length; i++) crc = CRC_TABLE[(crc ^ u8[i]) & 0xFF] ^ (crc >>> 8);
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  function parseHeader(u8) {
    if (u8.length < 20 || u8[0] !== 0x43 || u8[1] !== 0x59 || u8[2] !== 0x52 || u8[3] !== 0x4D) {
      throw new Error('不是 CYRM v4 二进制(缺 magic)');
    }
    const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
    const h = {
      version: u8[4],
      compression: u8[5],
      bodySize: dv.getUint32(6, true),
      crc32: dv.getUint32(10, true),
      subCols: dv.getUint16(14, true),
      subRows: dv.getUint16(16, true),
      layerFlags: u8[18]
    };
    if (h.version !== 4) throw new Error('cyrm 版本 ' + h.version + ' 不支持(只支持 4)');
    return h;
  }

  // 同步:解压后的 body → {metaLines, scene(Uint32Array 描述符), subCols, subRows, layerFlags}
  function parseBody(body, h) {
    if (crc32(body) !== h.crc32) throw new Error('CRC32 校验失败(文件损坏)');
    if (body.length < 2) throw new Error('body 缺 meta 长度');
    const dv = new DataView(body.buffer, body.byteOffset, body.byteLength);
    const metaLen = dv.getUint16(0, true);
    if (body.length < 2 + metaLen) throw new Error('meta 截断');
    const metaText = new TextDecoder('utf-8').decode(body.subarray(2, 2 + metaLen));
    const n = h.subCols * h.subRows;
    let p = 2 + metaLen;
    let scene = null;
    for (let bit = 0; bit < 4; bit++) {
      if (!((h.layerFlags >> bit) & 1)) continue;
      if (p >= body.length) throw new Error('层块截断(bit' + bit + ')');
      const kind = body[p]; p += 1;
      if (kind === 1) {
        const pc = dv.getUint16(p, true); p += 2;
        const palette = [];
        for (let i = 0; i < pc; i++) { palette.push(dv.getUint32(p, true)); p += 4; }
        const iw = body[p]; p += 1;
        if (p + n * iw > body.length) throw new Error('索引流截断(bit' + bit + ')');
        if (bit === 1) {
          scene = new Uint32Array(n);
          for (let i = 0; i < n; i++) {
            const idx = iw === 1 ? body[p + i] : dv.getUint16(p + i * 2, true);
            scene[i] = idx < pc ? palette[idx] : 0;
          }
        }
        p += n * iw;
      } else if (kind === 2) {
        p += n * 4;   // 背景层:整块 RGBA,旧编辑器模型暂不消费
      } else {
        throw new Error('未知层类型 ' + kind);
      }
    }
    return { metaLines: metaText.split('\n'), scene: scene, subCols: h.subCols, subRows: h.subRows, layerFlags: h.layerFlags };
  }

  function flattenScene(scene, subCols, subRows) {
    const cols = subCols / 4, rows = subRows / 4;
    const grid = [];
    for (let r = 0; r < rows; r++) {
      const row = [];
      for (let c = 0; c < cols; c++) {
        const counts = {};
        let shape = 0;
        for (let qy = 0; qy < 2; qy++) {
          for (let qx = 0; qx < 2; qx++) {
            let any = false;
            for (let sy = 0; sy < 2; sy++) {
              for (let sx = 0; sx < 2; sx++) {
                const t = (scene[(r * 4 + qy * 2 + sy) * subCols + (c * 4 + qx * 2 + sx)] >> 12) & 0xFFF;
                if (t) { any = true; counts[t] = (counts[t] || 0) + 1; }
              }
            }
            if (any) shape |= 1 << (qy * 2 + qx);
          }
        }
        let best = 0, bn = 0;
        for (const t in counts) {
          const n2 = counts[t];
          if (n2 > bn || (n2 === bn && Number(t) < best)) { best = Number(t); bn = n2; }
        }
        row.push(best ? (best * 16 + shape) : 0);
      }
      grid.push(row);
    }
    return grid;
  }

  // meta 行 → {players, enemies, comments}:语法与 parseMap 的注释分支一致
  function parseMeta(metaLines) {
    const players = [], enemies = [], comments = [];
    metaLines.forEach(function (rawLine) {
      const line = String(rawLine).trim();
      if (line === '' || line.charAt(0) !== '#') return;
      const parts = line.slice(1).trim().split(/\s+/);
      const pm = /^player(\d*)$/.exec(parts[0]);
      if (pm && parts.length >= 3) {
        players.push({ x: parseInt(parts[1], 10), y: parseInt(parts[2], 10) });
      } else if (parts[0] === 'enemy' && parts.length >= 4) {
        enemies.push({ type: parts[1], x: parseInt(parts[2], 10), y: parseInt(parts[3], 10) });
      } else if (parts[0] === 'cyrm-v3' || parts[0] === 'cyrm-v4') {
        // 版本标记行不当作注释
      } else if (parts[0] !== '') {
        comments.push(line.slice(1).trim());
      }
    });
    return { players: players, enemies: enemies, comments: comments };
  }

  // 异步入口:FileReader 的 ArrayBuffer → Promise<{grid, players, enemies, comments}>
  // (与 Core.parseMap 同形,importLibrary 据此与文本导入走同一出口)
  function parseMapV4Buffer(arrayBuffer) {
    const u8 = new Uint8Array(arrayBuffer);
    const h = parseHeader(u8);
    let bodyPromise;
    if (h.compression === 1) {
      if (typeof DecompressionStream === 'undefined') {
        return Promise.reject(new Error('此环境不支持 DecompressionStream,解不开压缩的 v4 地图'));
      }
      bodyPromise = new Response(
        new Blob([u8.subarray(20)]).stream().pipeThrough(new DecompressionStream('deflate'))
      ).arrayBuffer().then(function (ab) { return new Uint8Array(ab); });
    } else if (h.compression === 0) {
      bodyPromise = Promise.resolve(u8.subarray(20));
    } else {
      return Promise.reject(new Error('未知压缩类型 ' + h.compression));
    }
    return bodyPromise.then(function (body) {
      const parsed = parseBody(body, h);
      const meta = parseMeta(parsed.metaLines);
      return {
        grid: flattenScene(parsed.scene, parsed.subCols, parsed.subRows),
        players: meta.players,
        enemies: meta.enemies,
        comments: meta.comments
      };
    });
  }

  const api = { crc32: crc32, parseHeader: parseHeader, parseBody: parseBody,
                parseMeta: parseMeta, flattenScene: flattenScene, parseMapV4Buffer: parseMapV4Buffer };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.Cyrm4 = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
