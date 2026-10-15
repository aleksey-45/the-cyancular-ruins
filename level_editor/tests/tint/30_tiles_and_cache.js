'use strict';
// tests/tint/30_tiles_and_cache.js —— 贴图块定位、16×16 小图合成、tinted-tile 缓存与 LRU。
const Core = globalThis.Core;
const Tint = globalThis.Tint;

// ==== 相位 ⑥ 贴图块定位与 16×16 小图 ====
(function () {
  eq(Tint.textureBlockRect(1, 320), { x: 0, y: 0, w: 32, h: 32 }, 'textureBlockRect: 第 1 块在左上');
  eq(Tint.textureBlockRect(10, 320), { x: 288, y: 0, w: 32, h: 32 }, 'textureBlockRect: 第 10 块在第一行行尾');
  eq(Tint.textureBlockRect(11, 320), { x: 0, y: 32, w: 32, h: 32 }, 'textureBlockRect: 第 11 块换行(每行 10 块)');
  eq(Tint.textureBlockRect(21, 320), { x: 0, y: 64, w: 32, h: 32 }, 'textureBlockRect: 第 21 块(第三行首块 = 水)');
  eq(Tint.textureBlockRect(22, 320), { x: 32, y: 64, w: 32, h: 32 }, 'textureBlockRect: 第 22 块(水面)');
  let inside = true;
  for (let t = 1; t <= 22; t++) {
    const r = Tint.textureBlockRect(t, 320);
    if (r.x < 0 || r.y < 0 || r.x + r.w > 320 || r.y + r.h > 320) inside = false;
  }
  ok(inside, 'textureBlockRect: 22 块纹理全部落在 320×320 的 structure.png 里');
  throws(function () { Tint.textureBlockRect(0, 320); }, 'textureBlockRect: 纹理号 0 抛错', '纹理号');

  const atlas = makeAtlas();
  const neutral = Core.neutralDesc(3);
  const px = Tint.buildTilePixels(atlas, ATLAS_W, 3, 0, 0, neutral);
  ok(px instanceof Uint8ClampedArray && px.length === 16 * 16 * 4, 'buildTilePixels: 返回 16×16 RGBA');
  let upscaled = true;
  for (let y = 0; y < 16; y++) {
    for (let x = 0; x < 16; x++) {
      const o = (y * 16 + x) * 4;
      const sx = Math.floor(x / 2), sy = Math.floor(y / 2);
      if (px[o] !== sx * 8 || px[o + 1] !== sy * 8 || px[o + 2] !== 2 || px[o + 3] !== 255) upscaled = false;
    }
  }
  ok(upscaled, '★ buildTilePixels: 取纹理 3 的 (0,0) 象限,8px 最近邻放大 2× 成 16×16');

  const q = Tint.buildTilePixels(atlas, ATLAS_W, 3, 2, 1, neutral);
  let quadOk = true;
  for (let y = 0; y < 16; y++) {
    for (let x = 0; x < 16; x++) {
      const o = (y * 16 + x) * 4;
      const sx = 16 + Math.floor(x / 2), sy = 8 + Math.floor(y / 2);
      if (q[o] !== sx * 8 || q[o + 1] !== sy * 8) quadOk = false;
    }
  }
  ok(quadOk, '★ buildTilePixels: 象限 (2,1) 取的是块内 (16..23, 8..15)(取角映射)');

  // 端到端:白图集 + 亮度档 2 → 整块 204(与相位 ④ 手推的 golden 同源)
  const white = makeAtlas();
  for (let i = 0; i < white.length; i += 4) { white[i] = 255; white[i + 1] = 255; white[i + 2] = 255; }
  const wt = Tint.buildTilePixels(white, ATLAS_W, 1, 1, 3, Core.packDesc(1, 4, 2, 4, 7));
  let all204 = true;
  for (let i = 0; i < wt.length; i += 4) {
    if (wt[i] !== 204 || wt[i + 1] !== 204 || wt[i + 2] !== 204 || wt[i + 3] !== 255) all204 = false;
  }
  ok(all204, '★ buildTilePixels 端到端:白图集 + 亮度档 2 → 整块 16×16 全是 204');

  throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, 0, 0, Core.DESC_AIR); },
         'buildTilePixels: 空气格没有贴图,抛错', '空气');
  throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 31, 0, 0, neutral); },
         'buildTilePixels: 图集里没有这块(越出下边界)抛错', '图集');
  // 纹理实参必须就是描述符里那个 —— 不一致时上面两条都拦不住(那块在坐标系里存在),
  // 旧实现会一声不响地画出另一块砖的像素。
  throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, 0, 0, Core.neutralDesc(5)); },
         '★ buildTilePixels: 纹理实参与描述符里的纹理不一致 → 抛错(不许画另一块砖)', '不一致');
  // 象限坐标越界(含负数)一律抛 —— 旧实现靠 `%` 静默取负、靠 `& 3` 静默折到 3。
  throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, -1, 0, neutral); },
         '★ buildTilePixels: 象限坐标 -1 → 抛错(不许静默取负)', '象限坐标');
  throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, 0, 4, neutral); },
         '★ buildTilePixels: 象限坐标 4(越界)→ 抛错', '象限坐标');
  throws(function () { Tint.buildTilePixels(atlas, ATLAS_W, 3, 0.5, 0, neutral); },
         '★ buildTilePixels: 象限坐标 0.5(非整数)→ 抛错', '象限坐标');
})();

// ==== 相位 ⑦ tinted-tile 缓存(规格 §4.2 ④ / §4.3 闸 1)====
(function () {
  // 注入式 backend:node 里没有 canvas,缓存把"画出来的像素"交给 backend ——
  // 我们记录它收到了什么,于是能断言"缓存给出去的像素 = 直算的像素"。
  const made = [];
  const backend = {
    createTile: function (pixels, size) {
      made.push({ pixels: pixels, size: size });
      return { fake: true, pixels: pixels, size: size };
    },
  };
  const atlas = makeAtlas();
  const N1 = Core.neutralDesc(1), N2 = Core.neutralDesc(2), N3 = Core.neutralDesc(3), N4 = Core.neutralDesc(4);

  // 没 setSource 就 get → 抛错(而不是画出一块空白)
  const bare = Tint.createTileCache({ backend: backend });
  throws(function () { bare.get(1, 0, 0, N1); }, 'createTileCache: 没 setSource 就 get → 抛错', 'setSource');

  const cache = Tint.createTileCache({ maxSize: 3, backend: backend });
  cache.setSource(atlas, ATLAS_W);
  const a = cache.get(3, 2, 1, Core.neutralDesc(3));
  eq(made.length, 1, '未命中才会让 backend 造图');
  ok(a && a.fake === true, 'get 返回的正是 backend 造出来的那个对象');
  sameBytes(made[0].pixels,
            Tint.buildTilePixels(atlas, ATLAS_W, 3, 2, 1, Core.neutralDesc(3)),
            '★ 缓存交给 backend 的像素与直接算的逐字节一致(缓存没有改坏像素)');
  eq(made[0].size, Tint.TILE_PX, 'backend 收到的尺寸是 16');
  ok(a === cache.get(3, 2, 1, Core.neutralDesc(3)), '相同键第二次命中同一个对象');
  eq(made.length, 1, '命中不再造图');
  eq(cache.stats(), { hits: 1, misses: 1, evictions: 0, size: 1, maxSize: 3 }, 'stats 记账(hits/misses/evictions/size)');
  ok(cache.has(3, 2, 1, Core.neutralDesc(3)), 'has: 命中');
  ok(!cache.has(3, 2, 1, Core.packDesc(3, 5, 4, 4, 7)),
     '★ 描述符不同 = 不同键(同一象限的不同辅码各存一份)');
  ok(!cache.has(2, 2, 1, Core.neutralDesc(3)), '★ 纹理不同 = 不同键');
  ok(!cache.has(3, 1, 1, Core.neutralDesc(3)), '★ 象限不同 = 不同键');

  // LRU:maxSize 3,塞第 4 个 → 最久未用的那个被淘汰
  cache.clear();
  cache.get(1, 0, 0, N1);            // A
  cache.get(2, 0, 0, N2);            // B
  cache.get(3, 0, 0, N3);            // C
  cache.get(1, 0, 1, N1);            // D → A 最久未用,被淘汰
  ok(!cache.has(1, 0, 0, N1), '★ LRU: 塞第 4 个时最久未用的那个被淘汰');
  ok(cache.has(2, 0, 0, N2) && cache.has(3, 0, 0, N3) && cache.has(1, 0, 1, N1), 'LRU: 其余三个还在');
  eq(cache.stats().size, 3, 'LRU: 容量守住 maxSize');
  ok(cache.stats().evictions >= 1, 'LRU: 淘汰计数被记上');
  cache.get(2, 0, 0, N2);            // 命中 → B 提到最近端
  cache.get(4, 0, 0, N4);            // E → 淘汰此时最久未用的 C
  ok(cache.has(2, 0, 0, N2), '★ LRU: 命中过的条目被提到最近端(没被淘汰)');
  ok(!cache.has(3, 0, 0, N3), '★ LRU: 被淘汰的是最久未用的那个');

  // ★★ 换图必须整片失效:旧编辑器在 structure.png 加载完成前写进纯色兜底且永不失效,
  //    于是地图一直是色块,还"有时好有时坏"。
  const beforeStats = cache.stats();
  cache.setSource(atlas, ATLAS_W);
  eq(cache.stats().size, 0, '★★ setSource 清空缓存(资源换了 = 缓存全废,不许留旧的色块)');
  ok(!cache.has(3, 0, 0, N3), 'setSource 之后旧条目查不到');
  ok(cache.stats().hits === beforeStats.hits && cache.stats().misses === beforeStats.misses,
     'setSource 不重置记账(hits/misses 是累计量)');
  const m0 = made.length;
  cache.get(3, 0, 0, N3);
  eq(made.length - m0, 1, 'setSource 之后同一个键会重新造(确实失效了,不是"命中旧图")');

  // maxSize 0 = 不缓存
  const nocache = Tint.createTileCache({ maxSize: 0, backend: backend });
  nocache.setSource(atlas, ATLAS_W);
  const m1 = made.length;
  nocache.get(1, 0, 0, N1);
  nocache.get(1, 0, 0, N1);
  eq(made.length - m1, 2, 'maxSize 0 → 每次都现造(不缓存)');
  eq(nocache.stats().size, 0, 'maxSize 0 → size 恒 0');
  eq(Tint.createTileCache({ backend: backend }).stats().maxSize, Tint.DEFAULT_MAX_TILES,
     '默认 maxSize = DEFAULT_MAX_TILES');

  // ★ 浏览器默认后端在 node 里必须明确报错,而不是悄悄画不出来
  throws(function () { Tint.DEFAULT_BACKEND.createTile(new Uint8ClampedArray(4), 1); },
         '★ DEFAULT_BACKEND 在 node(没有 document)里明确抛错', 'document');

  // ════════ 下面三条刻意放在本块最后:上面好几条断言数的是 `made.length` 这类相对计数,
  //   插在中间会把它们整体挪位。各自用自己的 backend(与共享的 `made` 完全隔离)。

  // ── 命中判据:必须是 `has(k)`,不能是 `get(k) !== undefined` ──
  // 一个返回 undefined 的 backend 在旧判据下:那张图永不命中,却已经占着槽位、计入 size、
  // 还能把活条目挤掉 —— 实测 {hits:0,misses:2,size:1} 且 has() 为 true。
  const undefBackend = { createTile: function () { return undefined; } };
  const uc = Tint.createTileCache({ maxSize: 3, backend: undefBackend });
  uc.setSource(atlas, ATLAS_W);
  uc.get(1, 0, 0, N1);
  uc.get(1, 0, 0, N1);
  eq(uc.stats(), { hits: 1, misses: 1, evictions: 0, size: 1, maxSize: 3 },
     '★★ 缓存: backend 返回 undefined 时照样命中(命中判据是 has(k),不是 get(k) !== undefined)');
  ok(uc.has(1, 0, 0, N1), '★ 缓存: 上面那条的条目 has() 为 true(与命中判据同一条)');

  // ── 键的象限约定必须与像素数学同一条 ──
  // 旧实现:键用 `(qx & 3)`、像素用 `qx % SUB_PER_CELL` ⇒ get(3,-1,0,desc) 会先造出一张错图
  // 并存进象限 3 的键,随后 get(3,3,0,desc) 直接命中那张错图。今天所有调用方都只循环 0..3,
  // 但"从坐标算象限"的调用方(环面 / 拖拽选区)出现负坐标很正常。
  const made2 = [];
  const backend2 = {
    createTile: function (pixels, size) {
      made2.push({ pixels: pixels, size: size });
      return { fake: true, pixels: pixels, size: size };
    },
  };
  const qc = Tint.createTileCache({ backend: backend2 });
  qc.setSource(atlas, ATLAS_W);
  throws(function () { qc.get(3, -1, 0, Core.neutralDesc(3)); },
         '★★ 缓存: 象限坐标 -1 → 抛错(不许"折到象限 3"再造出一张错图)', '象限坐标');
  eq(made2.length, 0, '★ 越界坐标连一张图都没造(抛出发生在建图之前)');
  eq(qc.stats().size, 0, '★ 越界坐标一个条目都没写进缓存(不留幽灵条目)');
  const q3 = qc.get(3, 3, 0, Core.neutralDesc(3));
  sameBytes(q3.pixels, Tint.buildTilePixels(atlas, ATLAS_W, 3, 3, 0, Core.neutralDesc(3)),
            '★★ 象限 3 拿到的是正确那张(旧实现在这里会命中 -1 那趟造出来的错图)');
  ok(qc.has(3, 3, 0, Core.neutralDesc(3)), '★ 象限 3 的键确实落在 3 上');

  // ── setSource 的形状守卫:最自然的误用必须当场抛,不许静默画全透明 ──
  // 传 ImageData 对象而不是 .data:旧实现 atlas.length 是 undefined ⇒ rows = NaN ⇒
  // 边界比较(> NaN)恒假 ⇒ 一路产出全透明小图。
  const shape = Tint.createTileCache({ backend: backend2 });
  throws(function () { shape.setSource({ data: atlas, width: ATLAS_W }, ATLAS_W); },
         '★★ setSource: 传 ImageData 对象(而不是它的 .data)→ 抛错', 'RGBA 数组');
  throws(function () { shape.setSource(undefined, ATLAS_W); },
         '★ setSource: data 是 undefined → 抛错', 'RGBA 数组');
  throws(function () { shape.setSource(atlas, 6); },
         '★ setSource: 宽度不是 4 的倍数 → 抛错', '4 的倍数');
  throws(function () { shape.setSource(atlas, 0); },
         '★ setSource: 宽度 0 → 抛错', '4 的倍数');
  throws(function () { shape.setSource(atlas.subarray(0, 100), ATLAS_W); },
         '★ setSource: 字节数不是整行(宽×4)的整数倍 → 抛错(否则 rows 是分数)', '整数倍');
  // 被形状闸拒掉的调用不许动到上一份图集(守卫在赋值之前)
  shape.setSource(atlas, ATLAS_W);
  const s1 = shape.get(3, 0, 0, N3);
  throws(function () { shape.setSource(atlas.subarray(0, 100), ATLAS_W); },
         '(对照)同一条非整行的数据依旧被拒', '整数倍');
  ok(shape.has(3, 0, 0, N3) && shape.get(3, 0, 0, N3) === s1,
     '★ 被形状闸拒掉的 setSource 不清缓存、不换图集(上一份还完好)');
})();
