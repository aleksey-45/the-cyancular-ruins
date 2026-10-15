// render/20_atlas.js —— 图集入口 setAtlas(①②③④ 四层一起作废)+ ④ 取小图 tileFor。

var atlasPixels = null, atlasW = 0, atlasH = 0;
var tiles = null;                              // ④:惰性建(见 tileCache())
var cells = null;                              // ③:由 attachCells 装上(mount 装它)

function tileCache() { if (!tiles) tiles = Tint.createTileCache(); return tiles; }
function attachCells(cache) { cells = cache; return cells; }   // ★ 显式接缝:③ 的作废必须由 setAtlas 触发,不能是"谁最后建的谁生效"
function cellCache() { return cells; }

// ★★ 换图必须让四层缓存一起作废(① 缩略图 / ② 视口离屏层 / ③ 格位图 / ④ 小图缓存):③ 靠 attachCells 交上来、④ 由 Tint.setSource 自清,
//    而 ①② 的 state 住在 mount 闭包里 ⇒ 挂载侧用 attachViewInvalidator 只登记、不回调一个作废器(setAtlas 提交完 ③④ 再调它);作废器只丢弃/记账,重绘留到下一次 render() 经 createSlicer 分帧。
var atlasInvalidators = [];
function attachViewInvalidator(fn) {
  if (typeof fn !== 'function' || atlasInvalidators.indexOf(fn) >= 0) return fn;
  atlasInvalidators.push(fn);
  return fn;
}

function setAtlas(pixels, w, h, opts) {
  var next = (opts && opts.backend) ? Tint.createTileCache({ backend: opts.backend })
                                    : (tiles || Tint.createTileCache());   // ★ 不走 tileCache():那个 getter 自己就会写 tiles,等于先换 ④ 再校验
  next.setSource(pixels, w);                   // ★ 形状非法就抛 —— 校验过了才提交,那之前 tiles/atlasPixels/③ 一个字都没动(注入 backend 时尤其要这样写,否则留下一个没有贴图源的新 ④)
  tiles = next;
  atlasPixels = pixels; atlasW = w | 0; atlasH = h | 0;
  if (cells) cells.setSource();                // ③ 作废
  for (var i = 0; i < atlasInvalidators.length; i++) atlasInvalidators[i]();   // ①② 作废(先提交、后作废)
}
function atlasInfo() { return atlasPixels ? { width: atlasW, height: atlasH } : null; }
// ★ 图纸容量 = 列 × 行(320×320 的图集 = 100 块),不是描述符位宽 4095。★ Math.max(0, …) 不是装饰:h 从来没被任何人校验过,负数 h 会算出负容量,而 clampTexture 把 < 1 的容量当"没有信息"静默放宽到 TEXTURE_MAX —— 负数于是伪装成"没信息"穿过那道闸。
function atlasCapacity() {
  return atlasW > 0 ? Math.max(0, Math.floor(atlasW / Tint.BLOCK_PX) * Math.floor(atlasH / Tint.BLOCK_PX)) : 0;
}

// ★ 取一张 16×16 小图,唯一该调 Tint.get 的地方。desc === 0(空气)必须在进 Tint 之前短路 —— Tint.get 对空气会抛,漏了这句第一帧就抛、每帧都在同一处抛。
function tileFor(desc, qx, qy) {
  if (desc === 0) return null;
  var tex = RenderCore.texOf(desc);            // ★ 纹理实参从 desc 推导(不另传):"实参与 texOf(desc) 不一致导致静默画另一块砖"从此不可能发生
  if (tex === 0) return null;                  // 畸形描述符(辅码非 0、纹理 0)= 空气
  return tileCache().get(tex, quadOf(qx), quadOf(qy), desc);
}
