// core/70_v3_text.js —— v3 文本 / 旧字母格式的解析与一次性迁移。


// ★ 这里的 packed = texture*16 + shape 是 v3 的编码,与 v4 的 descriptor 毫无关系(规格 §3.6)。
const SHAPE_HEX = '0123456789ABCDEF';
// 旧字母格式只认 0-9 与 A(大小写均可),与游戏侧 MapFormat._tile_char_to_value 一致。
const LEGACY_CHAR = { '0':0,'1':1,'2':2,'3':3,'4':4,'5':5,'6':6,'7':7,'8':8,'9':9,'A':10 };
// ★ 版本标记行的唯一谓词:isV3Text 与 parseV3Text 两处都必须走它 —— 此前两处各写一份且不等价,
//   于是 #cyrm-v3 掉进旧字母格式、# cyrm-v3 (demo) 落进 comments(宽严不是重点,两处同宽才是)。
function isV3MarkerLine(line) {
  return /^#\s*cyrm-v\d+(\s|$)/.test(String(line).trim());
}

function _v3Pack(texture, shape) {
  if (shape === 0 || texture === 0) return 0;
  return (texture * 16 + shape) & 0xFFFF;
}
function _v3TexOf(v)   { return (v / 16) | 0; }
function _v3ShapeOf(v) { return v % 16; }

function isV3Text(text) {
  var lines = String(text == null ? '' : text).split(/\r?\n/);
  for (var i = 0; i < lines.length; i++) {
    if (isV3MarkerLine(lines[i])) return true;
  }
  return false;
}

// 旧 2×2 字母网格 → 1 格 packed(纹理取组内首个非零,形状 = 2×2 掩码);逻辑与游戏侧 MapFormat.convert_old_grid 逐字对应。
function _convertLegacy2x2(rows) {
  var h = rows.length, w = rows[0].length;
  var out = [];
  for (var ny = 0; ny < Math.floor(h / 2); ny++) {
    var row = [];
    for (var nx = 0; nx < Math.floor(w / 2); nx++) {
      var shape = 0, tex = 0;
      for (var sy = 0; sy < 2; sy++) {
        for (var sx = 0; sx < 2; sx++) {
          var ov = rows[ny * 2 + sy][nx * 2 + sx];
          if (ov !== 0) {
            shape |= 1 << (sy * 2 + sx);
            if (tex === 0) tex = ov;
          }
        }
      }
      row.push(_v3Pack(tex, shape));
    }
    out.push(row);
  }
  return out;
}

function parseV3Text(text) {
  var lines = String(text == null ? '' : text).split(/\r?\n/);
  var v3 = false;
  for (var i = 0; i < lines.length; i++) {
    if (isV3MarkerLine(lines[i])) { v3 = true; break; }
  }
  var rows = [], width = -1;
  var metaText = '';
  for (i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (line === '') continue;
    if (line.charAt(0) === '#') {
      // ★ 版本标记行不算注释(判据同上):漏了这句,# cyrm-v3 会被塞进 comments,导入→导出就往用户 meta 里塞垃圾。
      if (isV3MarkerLine(line)) continue;
      metaText += line + '\n';
      continue;
    }
    var row = [];
    if (v3) {
      if (line.length % 4 !== 0) {
        throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行长度 ' + line.length + ' 不是 4 的倍数');
      }
      for (var j = 0; j < line.length; j += 4) {
        var tstr = line.substr(j, 3);
        if (!/^[0-9]{3}$/.test(tstr)) {
          throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行纹理位 "' + tstr + '" 不是 3 位数字');
        }
        var ch = line.charAt(j + 3).toUpperCase();
        var sv = SHAPE_HEX.indexOf(ch);
        if (sv < 0) throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行非法形状字符 "' + line.charAt(j + 3) + '"');
        row.push(_v3Pack(parseInt(tstr, 10), sv));
      }
    } else {
      for (j = 0; j < line.length; j++) {
        var lch = line.charAt(j).toUpperCase();
        var lv = LEGACY_CHAR[lch];
        if (lv === undefined) {
          throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行非法字符 "' + line.charAt(j) + '"(旧格式只允许 0-9/A)');
        }
        row.push(lv);
      }
    }
    if (width < 0) width = row.length;
    else if (row.length !== width) {
      throw new Error('parseV3Text: 第 ' + (i + 1) + ' 行宽度 ' + row.length + ' 与首行 ' + width + ' 不一致');
    }
    rows.push(row);
  }
  if (rows.length === 0) throw new Error('parseV3Text: 地图里没有有效网格行');

  var meta = parseMeta(metaText);
  var players = meta.players, enemies = meta.enemies;
  if (!v3) {
    // ★ 旧字母格式靠 2×2 折叠成 1 格,所以宽高必须都是 ≥2 的偶数 —— 否则单行输入抛裸 TypeError、
    //   宽 3 × 高 4 会一句话不说地永久丢掉两整列;而按规格 §3.6 迁移是单向的,吃掉的就找不回来(推导见 docs/eng/editor-core.md)。
    if (width < 2 || width % 2 !== 0 || rows.length < 2 || rows.length % 2 !== 0) {
      throw new Error('parseV3Text: 旧字母格式的宽高必须都是 ≥2 的偶数(收到 ' +
                      width + '×' + rows.length + '),否则 2×2 折叠会静默丢掉边缘行/列');
    }
    rows = _convertLegacy2x2(rows);
    // 旧格式 2×2 → 1,spawn 坐标同步 ÷2
    players = players.map(function (p) { return { x: Math.floor(p.x / 2), y: Math.floor(p.y / 2) }; });
    enemies = enemies.map(function (e) { return { type: e.type, x: Math.floor(e.x / 2), y: Math.floor(e.y / 2) }; });
  }
  var cellsW = rows[0].length, cellsH = rows.length;
  var packed = new Uint16Array(cellsW * cellsH);
  for (var y = 0; y < cellsH; y++) {
    for (var x = 0; x < cellsW; x++) packed[y * cellsW + x] = rows[y][x];
  }
  return { cellsW: cellsW, cellsH: cellsH, packed: packed,
           players: players, enemies: enemies, comments: meta.comments };
}

// ── 取角映射(规格 §2.2,规范定义)──
// 子格全局坐标 (X,Y) → dst 目标矩形(世界像素,恒 16×16)+ src 源矩形(贴图块内偏移,恒 8×8);调用方按 (texture-1) 定位贴图块再加 src 偏移。
// ★ 象限由子格在 64px 格内的位置决定(X % 4 / Y % 4),不是存在数据里的字段 —— 每个子格要能独立推出自己该画哪一块。
// ★★ 调用方约束:X / Y 必须非负,调用方自己 posmod。JS 的 % 保留被除数符号,X = -1 会得到 qx = -1 ⇒ src[0] = -8 落在贴图块外;
//   本函数不做归一化(环面语义属于调用方的世界模型),不抛错、只安静地给出错误的源矩形。
function subcellRender(X, Y) {
  var qx = X % SUB_PER_CELL, qy = Y % SUB_PER_CELL;
  return { dst: [X * SUB_PX, Y * SUB_PX, SUB_PX, SUB_PX],
           src: [qx * (32 / SUB_PER_CELL), qy * (32 / SUB_PER_CELL),
                 32 / SUB_PER_CELL, 32 / SUB_PER_CELL] };
}

// ── v3 → v4 迁移(规格 §3.6)──
// 旧掩码 bit (qy*2+qx) 为 1 → 新网格的 4 个子格 X∈[2qx,2qx+1], Y∈[2qy,2qy+1] 填同一纹理;spawn 坐标同步 ÷2。
// 配合 subcellRender 的取角映射,这保证迁移后视觉逐像素不变;前/后/背景三层留空 —— v3 里没有它们。
function migrateV3(parsed) {
  var map = createMap('', parsed.cellsW, parsed.cellsH);
  var scene = map.layers[LAYER_SCENE].desc;
  var subCols = map.subCols;
  for (var cy = 0; cy < parsed.cellsH; cy++) {
    for (var cx = 0; cx < parsed.cellsW; cx++) {
      var v = parsed.packed[cy * parsed.cellsW + cx];
      if (v === 0) continue;
      var tex = _v3TexOf(v), shape = _v3ShapeOf(v);
      if (tex === 0 || shape === 0) continue;
      var d = neutralDesc(tex);
      for (var qy = 0; qy < 2; qy++) {
        for (var qx = 0; qx < 2; qx++) {
          if (!(shape & (1 << (qy * 2 + qx)))) continue;
          for (var dy = 0; dy < 2; dy++) {
            for (var dx = 0; dx < 2; dx++) {
              var X = cx * SUB_PER_CELL + qx * 2 + dx;
              var Y = cy * SUB_PER_CELL + qy * 2 + dy;
              scene[Y * subCols + X] = d;
            }
          }
        }
      }
    }
  }
  map.players = parsed.players.map(function (p) { return { x: p.x, y: p.y }; });
  map.enemies = parsed.enemies.map(function (e) { return { type: e.type, x: e.x, y: e.y }; });
  map.comments = parsed.comments.slice();
  return map;
}
