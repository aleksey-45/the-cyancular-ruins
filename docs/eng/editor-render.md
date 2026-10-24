# 编辑器渲染层（`level_editor/render/`）

> 本文件记 `level_editor/render/` 的缓存结构、失效规则与常量。★ 冲突以源码为准，读前先 `grep` 复核。
> 返回索引：[`CLAUDE.md`](../../CLAUDE.md)。相邻几份：[`editor-core.md`](editor-core.md) /
> [`editor-ui.md`](editor-ui.md) / [`editor-io.md`](editor-io.md) / [`editor-server.md`](editor-server.md)。
> **游戏侧**的 Level0 渲染管线在 [`render.md`](render.md)（与本文件不是一回事）。

## 1. 分片与加载顺序

- 19 片按**文件名字典序**加载，`NN_` 前缀就是顺序。真相源是 `level_editor/editor.html` 的 `<script src>`
  列表；`parts_check.js` 守「目录 ↔ 页面」一致，`loader.js` 在 node 侧按同一份清单拼进**一个** Function 体。
- 分片共享**同一个作用域**：**顶层名不许重名**，`var` 的重名会 hoist 成本作用域的局部名。
  ⇒ `00_head.js` 里 `globalThis.Core` 就地取名为 **`RenderCore`**（不是 `Core`）；`parts_check.js --ratio`
  同一次运行的「全局影子」闸守这条。
- ★ **本层顶层不碰 DOM**：DOM 只出现在 `mount()` 一族里，故 node 能加载本层做断言（`render_smoke.js`）。
- 末片恒为 `99_exports.js`：公开 API 表只在它里面。

## 2. 四层缓存

| | 是什么 | 谁持有 | 失效事件 |
|---|---|---|---|
| ① | 地图**缩略图**（每层一张，2px/子格，或降为 1px） | `mount` 闭包（`S.thumbs`） | 换图、改尺寸、整片 invalidation |
| ② | **视口离屏层**（每层一张，像素系 = 屏幕系） | `mount` 闭包（`S.layerCv`） | 换图、视图变动、尺寸变动 |
| ③ | **格位图缓存**（一格的 16 个 tile 引用） | 模块层（`30_cell_cache.js`），由 `attachCells` 交上来 | 内容版本号（`touch`）+ 代际（`setSource`） |
| ④ | **tinted-tile**（真正的像素） | `tint.js`（自带 8192 张上限） | `Tint.setSource` |

- ★★ **换图（`setAtlas`）必须让四层一起作废**。③ 经 `attachCells` 交上来、④ 由 `Tint.setSource` 自清；
  ①② 的 state 住在 `mount` 闭包里，故挂载侧用 `attachViewInvalidator` **只登记、不回调**作废器
  （`20_atlas.js` 收成一张表），`setAtlas` 提交完 ③④ 之后再调它。作废器**只做同步的丢弃/记账，不做重画**。
- ★ `setAtlas` 的顺序是「**先建新 ④、校验形状、校验过了才提交**」：形状非法时 `Tint.setSource` 抛错，
  `tiles` / `atlasPixels` / ③ 的代际一个字都没动。注入 `opts.backend` 那条路同样要这样写。
- ③ 的条目 = **16 个 tile 引用**（约 128 字节），不是 64×64 的 canvas；8192 条 ≈ 1MB。像素只存在 ④ 里。
- ③ 有**两条独立失效轴**，都要判：①内容版本号（`touch`，编辑某格 → 该格版本 +1 → 下次只重建这一格）；
  ②代际（`gen`，`setSource` 递增）。`setSource` **刻意不清表**：陈旧条目靠 `gen` 不等**恒 miss**；
  重建路径必须先 `delete` 再 `set`（`Map.set` 对已存在键保留原插入位置）。
- **图集容量 = 列 × 行**（320×320 的图集 = 100 块），**不是**描述符位宽 4095。`atlasCapacity` 里的
  `Math.max(0, …)` 是必须的：`h` 没有被任何人校验，畸形的 `h` 会让容量算出负数，钳到 0 = 一块都放不下。

## 3. 环面

- `wrapIdx(v, n)` 用 `v - Math.floor(v / n) * n`（`%` 对负数返回负数，而负数是常态）。
- `quadOf(v) = wrapIdx(v, SUB)` 恒在 `0..SUB-1`，否则 `Tint` 会抛。
- **缺席层 = 全空气**：`layers[L]` 可以是 `null`（不是错误）⇒ 渲染路径一律经 `layerArray`，
  **不可**直接摸 `layers[L].desc`。
- **3×3 副本**：只返回「与视口相交」的副本偏移（最多 9 份，通常 1 份）。离屏层的像素系 = 屏幕系，
  越出主网格的像素由 `paintLayerRect` 的**环面折算**补上，副本在当前坐标系下是冗余的；
  `setTorus` 开关的可见行为就是它。屏幕 → 子格（`hitTest`）折算回主网格，无论点在哪个副本上。
- 常数量级：视口 **12.5 格宽**、地图 **500 格** ⇒ 隔壁副本被平移 −8000px、整个落在画布外。
  ★ 可见范围内落在主网格之外的像素**必须用折算后的格去填**，不可按主网格裁剪。

## 4. 脏区与平移

- 编辑 → 标脏（`editCells` → ③ 的 `touch` + ② 的脏矩形 + ① 的缩略图块）；切层/开关 → **只合成**；
  平移 → **像素级自拷贝搬移 + 只补新露出的边条**。跨层的脏矩形合成用**一个包围盒**，用完即 `clear`。
- `panStrips` 的参数是**视图/世界**的位移方向（`view.x` 增加 `dxPx/zoom`），画面内容反向走；
  调用方那里的自拷贝偏移是它的**相反数**。
- ★★ 位移**先量化到整像素**：`view` / `panStrips` / 自拷贝三者必须同源，一次量化、三处共用。
  不足 1px 的平移被**丢弃**。
- ★★ 视图一动（平移/缩放/换图/改尺寸）⇒ 在飞的那一轮重建**整个作废**（`layerGen`）；
  视图不干净时平移一律改走整片重建。
- ★ 尺寸一变，② 的旧画布必须**丢掉**（不是「只标脏」），由 `buildLayers` 分帧重来。
  `drawLayerPath` 另有一道兜底：**尺寸对不上的离屏层一路都不许画**。

## 5. 单帧预算（`40_slicer.js`）

- `DEFAULT_BUDGET_MS = 8`；注入 `now` / `nextFrame` 是为了在 node 里确定性断言「确实切了、单帧没超预算」。
- ★ 「**每帧至少做一项**」是必须的，否则 `budgetMs = 0` 会让出成死循环。
- ★ 预算必须是**有限的数**：非法值一律「非有限数 → 回落默认；负数 → 钳到 0」。
- ★ 判在**做完之后**：预算是软的（到手一项就做完它），但一格都不许超。时间基准在**让出之后**重新取。
- ★★ 抛错必须**落到 `run()` 返回的那个 promise 上**；第二个实参 `nextFrame().then(step, reject)` 同样是
  承重的（堵「让出的那一帧抛」）。漏任一条，`run()` 都会**永远不 settle**。

## 6. 图层种类：描述符 vs RGBA（`70_layer_kind.js`）

- `DRAW_ORDER = [3, 2, 1, 0]`：前景（0）最后画（盖在最上面），背景（3）最先画。
- ★★ 纹理层是**描述符**（走 `Core.texOf` / `Tint`），背景层是 **RGBA `0xRRGGBBAA`**（走 `cssOfRGBA` /
  `fillRect`）。两者都是 32 位无符号数但含义完全不同，把 RGBA 喂给 `Core.texOf` **不抛**、结论无意义，
  且有两种静默症状：不透明红 `#FF0000FF` 的 `(0xFF0000FF >>> 12) & 0xFFF = 0` ⇒ 整层当成空气看不见；
  不透明青 `#00FFFFFF` 的 `texOf = 4095` ⇒ 任何漏掉「先判层、再判纹理」的地方当场抛 `Tint` 越界错。
- 判据取 `core` 的单一来源 `LAYER_KINDS`，**不可**在渲染层再抄一份。

## 7. 挂载与闭包分解

- `mount(canvas, opts)` = `createMountState` 建共享状态 `S`，再按序装六簇：
  `installErrors` / `installThumbs` / `installLayerPath` / `installDraw` / `installDrag` / `installEdit`。
- ★★ `S` 是安装器之间**唯一**的共享通道：会被重新赋值的标量（`thumbPx` / `atlasSync` / `errorSink` /
  `cellCache` / `layersClean`）一律挂这里，跨簇读写只能走 `S.xxx`，**不可**当安装器参数传。
  安装期各簇只登记自己的函数，不许互调。只改属性/元素的对象（`ctx` / `s` / `thumbs` / `layerCv` /
  `stat` / `stat2`）引用不换，各安装器开头就地取别名即可。
- **晚绑定**：`torusList` 由 `installDraw` 产出，`drawLayerPath` 经 `S.torusList` 取用。
- `stat2` 两个名字相近、量的不是一件事，两个都要读：`layerRebuilds` = `flushDirty` 的**脏区重画次数**
  （单位「块」）；`layerRebuildMs` = **一次整片 `buildLayers` 的耗时**（毫秒）。键名不改。
- ★ ② 的像素坐标系：离屏层像素 `(px,py)` ↔ 世界子格 `(view.x + px/zoom, view.y + py/zoom)`，与屏幕同一套。
  **不可**建全图离屏（500×300 子格按 16px 是 8000×4800 = 153MB）。

## 8. 选区拖动：偏移查询与「去烤」（`90_install_drag.js`）

- 拖动**只记偏移**（`s.selDrag = {sel, dx, dy}`），渲染时做**偏移查询**（纯读），松手才提交一次 `moveRegion`。
- ★★ 三种目标格必须与落笔结果**逐格一致**：① 源格在选区内 ⇒ 读源格；② 源格在外、目标在选区内 ⇒
  被腾空的源区 ⇒ `hit:false`；③ 两边都在选区外 ⇒ 原样读它自己。少了 ③，拖动时除选区外的整张图都判成腾空。
- ★★ 一律传 `W`/`H`（环面折算）：拖动跨过接缝时目标落在图的另一头，非折算会在那里读到目标格自己的内容。
  `W`/`H` 可选，不给 = 不折算；拖动查询**必须**给。
- ★★ **选区没了，偏移就不再生效**：判据必须含 `s.selection`（`markDragDirty` 里是同一判据）。
- ★★ **去烤**：整片重建会把 `dragSource` 的偏移结果画死在 ② 上。偏移一变（**以及清除时**）必须把
  「源区 ∪ 目标区」重画一遍，且用**规范化**后的两块（`canonRects`）；上一次那两块也要一起重画
  （清除时只有 `dragBake` 记得它烤在哪）。
- ★★ **只在活动层**：`moveRegion` 只搬 `app.r.layer()` 那一层。「记它烤在哪」必须连**层号**一起记
  （拖动途中可以切层）。
- ★★ ① 缩略图那条路同样要去烤，**判据与 ② 同源**：`paintThumbRect` 也读 `dragSource`，而撤销/重做一条
  `kind='whole'` 的差量会走 `invalidateAll` → `buildThumbs`。
- ★★ 逐块重画，**不取包围盒**（跨接缝时包围盒是整行甚至整幅图）。`dedupRects` 去重；`now` 自己也要过一遍。
- ★★ **按当前路径分派**：① 缩略图与 ② 视口离屏层同一时刻只有一份在屏幕上，两条路成本形状相反 ——
  ② 的成本 = 与画布相交的格数 × 每格 16 次 `drawImage`（低倍时最大），① 的成本 = 选区面积 × 缩略图刻度
  （与缩放无关，高倍时最大）。另一条路的像素不会被留在半旧状态：换回 ≥8 必经 `viewChanged()` ⇒ 整片重建。

## 9. 缩略图（①）

- ① 总是经分帧器建（单帧预算）。
- ★★ **复用条件必须逐轴判**（宽**与**高）：`thumbScale` 只看总字节数，「同宽更高」的两张图会拿到同一刻度，
  只判宽就会复用一张矮画布，`drawThumbPath` 用五实参 `drawImage` 把它整张缩进目标框 ⇒ 画面纵向拉伸/截断。
  默认视图 `fitZoom` 之后 `zoom < 8`，走的正是这条路。
- ★★ 复用尺寸相同的旧缩略图之前，先把**新图里缺席的层**清掉（缺席层不进 `thumbTasks`，不会被重画）。
- `THUMB_MAX_BYTES = 24MB`：超过就降到 1px/子格（400×300 格 @2px = 30MB）。
- 隐藏层**也照画**（离屏内容与可见性无关）。子格线只在 **zoom ≥ 4** 时画。

## 10. 报错通道（`82_install_errors.js`）

- ★★ 视图入口（`resize` / `fit` / `setView` / `setZoomAt` / `panBy` / `setMap` / `invalidateAll`）返回的是
  **由分帧器派生出来的 promise**；抛错落在任务回调里，变成 `run()` 的**拒绝**而不是同步抛出 ⇒
  页面侧 `guard` 的同步 `try/catch` 接不住，画布默默停在上一帧。故在**返回之前**给链子挂一个观察者。
- ★ 两条契约同时成立：① 想 `await` / 想自己 `catch` 的调用方**照样拿到那次拒绝**（只挂观察者，不改、不吞、
  不替换返回值）；② 完全不管返回值的调用方也能在状态栏里看到原因。
- ★ `defaultErrorSink` 走 `ui.js` 的 `status()`（`#status-msg`），且是**运行时查找**（依赖顺序 core → tint →
  render → io → ui，加载期 `ui.js` 还不存在）。★ 报错通道自己坏了也不许把异常扔回调用方。

## 11. 已知边界

- 去烤是**同步**路径（不走 `createSlicer`）；面积已按规范块压到 2~4 块，极端情况下仍可能掉一帧。与 `tools.md` §5 ③ 同一条。
- `92_install_edit.js` 的 `clipped` 是守卫：越界的脏矩形不该让离屏层去画。`render_smoke` 相位编号
  （⑩d / ⑬ / ⑬h / ⑬i / ②b）是本文件与源码之间的定位锚，改了相位要同改这里。
