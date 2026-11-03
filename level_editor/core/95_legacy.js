// core/95_legacy.js —— legacy 纹理 id 的读时迁移(新图集里 7 个全透明槽:tex 2,3,4,5,16,17,18)。


// ★ 纹理 id 空间稳定 1..22 不重编号、文件格式保持 v4:legacy 槽在新图集里已清成全透明,
//   旧文件/旧草稿里的 legacy id 在**读时**迁移,内存即干净 ⇒ 新保存的文件不再含 legacy id。
//   另一半守卫在 80_validate.js(tex 不在 tile_defs ⇒ error,encodeMap 只拒 errors 天然拦住残留)。
// ★ 迁移表 = tile_defs.js 的 legacy_texture_map(sync-tiles.js 从 data/tile_defs.json 生成,
//   单一真相源,别在这里抄一份)。TILE_DEFS 缺席时(部分 node 冒烟只装 core)按"没有表"原样返回:
//   页面与 worker 都装了 tile_defs.js,生产路径上恒有表。
function legacyTexMap() {
  var defs = globalThis.TILE_DEFS;
  var lm = defs && defs.legacy_texture_map;
  return (lm && typeof lm === 'object') ? lm : null;
}

// 合成规则(已定决策,别改):tex 命中 legacy_texture_map ⇒ new_tex = base,
// new_hue = clamp(hueOf(d) + legacy_hue − 4, 0, 7);bri/sat/alpha 原样。未命中原样返回。
// ★ hue 是档位不是角度:legacy_hue 是旧槽自己的色相档(中性 = 4),(k−4) 是它相对中性的偏移;
//   叠加当前偏移后钳回 0..7(钳制会截断色相,这是既定规则接受的代价)。
function migrateDescriptor(d) {
  var tex = texOf(d);
  if (tex === 0) return d;                        // 空气(含"tex 0 辅码非 0"的畸形)不迁移
  var lm = legacyTexMap();
  if (!lm || !Object.prototype.hasOwnProperty.call(lm, String(tex))) return d;
  var hit = lm[String(tex)];
  var base = hit ? (hit.base | 0) : 0;
  if (base < 1 || base > TEXTURE_MAX) return d;   // 表项畸形不迁移(宁留原样交给 validateMap 报 error)
  var hue = hueOf(d) + ((hit.hue | 0) - HUE_NEUTRAL);
  if (hue < 0) hue = 0;
  if (hue > 7) hue = 7;
  return packDesc(base, hue, brightOf(d), satOf(d), alphaOf(d));
}

// 整图三个纹理层**原地**迁移(颜色层是 RGBA 不是描述符,一个字节都不许碰)。交回同一个 map 对象。
// ★ 调用点 = 所有"从字节/IndexedDB 产出 map"的读入口:mapFromBytes(ui/10_util.js)、
//   offerDraft(ui/75_draft_store.js)、checkCrashSlot(ui/80_ui_state.js);v3/旧字母那条路由
//   migrateV3(core/70_v3_text.js)在产出 desc 时逐条套 migrateDescriptor,不经这里。
function migrateMap(map) {
  if (!map || !map.layers) return map;
  for (var L = 0; L < LAYER_COUNT; L++) {
    var layer = map.layers[L];
    if (!layer || layer.kind !== 'tex' || !layer.desc) continue;
    var a = layer.desc;
    for (var i = 0; i < a.length; i++) {
      if (a[i] === 0) continue;                   // 空气是绝大多数,先跳过
      var m = migrateDescriptor(a[i]);
      if (m !== a[i]) a[i] = m;
    }
  }
  return map;
}
