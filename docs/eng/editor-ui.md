# 编辑器界面层（`level_editor/ui/`）

> 本文件记 `level_editor/ui/` 的状态账、持久化层级与启动顺序。★ 冲突以源码为准，读前先 `grep` 复核。
> 返回索引：[`CLAUDE.md`](../../CLAUDE.md)。相邻几份：[`editor-core.md`](editor-core.md) /
> [`editor-render.md`](editor-render.md) / [`editor-io.md`](editor-io.md) / [`editor-server.md`](editor-server.md)。
> **游戏侧** UI 语汇在 [`ui.md`](ui.md)（与本文件不是一回事）。

## 1. 分片与加载顺序

- 19 片按**文件名字典序**加载，`NN_` 前缀就是顺序。顺序的真相源是 `level_editor/editor.html` 的 `<script src>` 列表；
  `loader.js` 从同一处读，`parts_check.js` 守「目录 ↔ 页面」一致。
- 分片共享**同一个作用域**：**顶层名不许重名**，重名即静默覆盖。
- 末片恒为 `99_exports.js`：公开 API 表只在它里面，`editor_smoke.js` 按它取名字。
- ★ **顶层一行都不碰 DOM**：DOM 只在 `boot()` 与它装上的回调里取，故工具内核 / 撤销差量 / 名字 / 尺寸钳制
  可由 node 逐条断言（`editor_smoke.js`）。
- ★ **页面里不许有第二份数学**：像素走 `Tint.*`，编解码与迁移走 `Core.*`，几何走 `Render.*`。

## 2. 尺寸闸只有一条路

```
applySize → resizeMap → createEmptyMap → Core.clampMapSize
```

- `Core.createMap` **不判** 400×300 上限（只要求正整数）⇒ **不可**新开第二个造图入口，
  否则输 99999 会分配巨图、标签页卡死。
- 行为守卫：`createEmptyMap` / `resizeMap` 输 99999 都落回 400×300
  （[`level_editor/tests/editor/10_core_tools.js`](../../level_editor/tests/editor/10_core_tools.js)）。
- 「这一格没有给一个数」的判据必须与 `Core.clampMapSize` **同一把尺子**（`parseInt(v,10)` + `isFinite`）：
  `<input type="number">` 删光或填垃圾读回来是空串，而 `clampMapSize('')` 回落 `DEFAULT_CELLS_W/H = 125×75`
  ⇒ 在改尺寸这条路上是一次**静默缩图**。
- 钳制**不报错回滚**：NaN / 0 / 99999 一律落到合法区间，钳完照样回显到输入框。
- ★ 默认尺寸的唯一来源是 core 的 `DEFAULT_CELLS_W/H`，不在 ui/ 里重抄一份。

## 3. 状态栏：`#st-save` 与 `#status-msg`

- `#st-save` 说「磁盘上那份是不是这一份」，`#status-msg` 说「刚刚发生了什么」。
- ★★ **一个写入者**：三种文案全在 `renderSaveState()` 里决定，别处只改 `dirty` / `lastAutoSaveAt` 两个变量。
- ★★ 它**只**在「保存真的成功」与「打开真的成功」两处清零，**不可**挂在 `guard(...)` 的决议上
  （`guard` 失败时决议是 `undefined`）。
- 有草稿盘时这一格写「已自动保存 12:34」；「未保存 / 已保存」是没有草稿盘时的回落值。
  ★ **撤销/重做也是一次改动**：回到「保存时那一刻」的图上仍显示「未保存」。

## 4. 编码出口与作业分帧

- `compression = 0`（裸 body）是一条完整可用的路径，规则是 `optCompress()` 读开关。
- ★★ `optCompress()` 是**唯一**读该开关的地方，一处对三处共用：真文件（`saveCurrent`）、草稿盘（`saveDraft`）、
  崩溃槽位（`installCrashFence` 的 snapshot）。**前两处必须同值**，否则 `offerDraft` 的 `sameBytes(rec.bytes, app.raw)`
  会弹出**假**的「发现一份还没写盘的草稿」。
- 长作业（油漆桶 / 渐变）分帧的**让出判据是时间预算**（`Render.createSlicer`，默认 8ms/帧），不是固定条数：
  `JOB_QUANTUM = 2048`（一个量子的格数）、`JOB_QUANTA = 4096`（一轮的量子额度）。

## 5. v3 → v4 迁移与原文备份

- Ctrl+S 写回原文件；打开 v3 文本的图首次保存会弹一次确认。迁移是**单向**的。
- ★★ **确认与备份是两条独立的门**：确认每会话一次（`v3Confirmed`），备份**每个文件**一次
  （`v3BackedUp`，键 = 保存目标文件名）。
- ★ `v3BackedUp` 用 `Set` 而不是普通对象（图名合法字符含 `_`，`__proto__.cyrm` 这类名字在普通对象上会被静默忽略）。
- ★ 记账**只在备份真的写成功之后**落：写失败时保存整个中止、`sourceFormat` 仍是 v3。

### 5.1 备份名：`<基名>_<8 位十六进制>.v3.bak`

- ★★ 结尾**不是** `.cyrm`，游戏的 `MazeGenerator._random_cyrm`（`f.to_lower().ends_with(".cyrm")`）抽不到它。
- 服务器 `editor_server.js` 的名字校验放行 `<基名>.cyrm` 与 `.v3.bak` 两个后缀。
- ★★ 哈希是 FNV-1a 32 位（输出补到 8 位十六进制，用 `Math.imul`），输入取**完整原文件名**（截断前那一份）。
- ★ 基名只许 `[A-Za-z0-9_-]`（服务器的 `MAP_NAME_RE`），`.` 也收掉。
- 长度：整名最长 `24 + 1 + 8 + 7 = 40` < `MAX_MAP_NAME_LEN`（64，守卫在 `editor_smoke`）。
- ★★ 备份**不是地图**：内容是这张图**原文**的最后一手退路。`isBackupName` 两处消费者：`refreshLibrary`
  的列表过滤与 `saveCurrent` 的一道闸（列表只管点击，`?p=xxx.v3.bak` 这条 URL 直接打开的路它管不到）。

## 6. PUT 只有一个出口：`putMapBytes`

- ★★ PUT **必须显式带** `Content-Type: application/json`，服务器写端点只收这一个类型，别的类型一律 **415**。
- ★ 页面上发 PUT 的地方**恰好一处**：真保存与原文备份都走它。
- ★ 备份**排在真保存之前**，走同一个出口；备份写不进去就**不写盘**。
- ★ 不写 `method` 的都是只读（GET：`openMap` / `refreshLibrary`）。失败原样抛出，由调用方变成状态栏上的一句话。

## 7. 持久化三层与崩溃栅栏

| 层 | 存什么 | 语义 |
|---|---|---|
| ① 真文件 `maps/*.cyrm` | 作品本体（Ctrl+S 写回） | **最高保真副本**永远是真文件 |
| ② IndexedDB 草稿盘（`cyrm-editor` / store `draft`） | 「还没写盘的活」 | 状态栏那一格由它接管 |
| ③ localStorage（键 `cyrm.ui.v1`） | 「下次打开时界面该长什么样」 | 读损坏值一律回落默认 |

### 7.1 库结构

- ★ 库版本 **2** = 给草稿盘加 `savedAt` 索引，支撑两条不物化记录本体的查询：最新一条的 `savedAt`
  （启动时的崩溃槽位比对，`openKeyCursor(null,'prev')` 键游标）与按时间升序挑淘汰对象（草稿盘清理）。
- ★ 主键 = `sanitizeName(文件名)`。**当前这张图**的键只有 `currentDraftKey()` 一处：写进去的与读出来的必须是同一个键。
- ★★ `onupgradeneeded` **两条路都要把索引建出来**：全新库走 `createObjectStore` 之后建索引；已在用的库升上来时
  经升级事务拿到 store 再补建索引。只建一条路的话老库升级后两条查询都读不到东西。老记录不需要迁移（稀疏索引）。
- ★★ `onblocked` 必须接：另一个标签页仍按版本 1 开着这张库时升级被阻塞，不接这条 promise 永远不 settle，
  而 `bootLoad` 正 `await` 着它。接住后交回 `null`（草稿盘这一局不可用），编辑器照常打开。

### 7.2 读失败与「没有这条记录」必须分得开

- ★★ `idbGetOne` 交回 `{ok, rec}`：`ok:false` = **读不到**，`rec:null` = 读到了、那条不存在。
- ★ `idbCount` 交回 `null` = 读不到（不是「0 条」）；`idbNewestSavedAt` 的 `savedAt: null` = 库里一条都没有。
- ★ 清理的两条失败路径都必须**说出来**（读不到条数 / 读不到记录列表 / 删除事务失败），但**不拒绝这次写入**。
- ★ **草稿盘写入的配额失败要明确告知**，不静默吞掉（`saveDraft` 的 `catch` 里那句状态栏文案）。
- ★ 淘汰口径**只有一处**（`evictPlan`：干净的排前面，同样干净时最老的先丢）；`pruneDrafts` 的 `cap`
  取 `entries.length - need`，是同一口径的两种情形。

### 7.3 草稿的内容与该记的账

- ★★ **草稿以编码后的字节存**（`rec.bytes`），恢复时走同一条解码路（`Io.decodeMap`）。
- ★★ **一条记录的两半（它是谁 / 它是什么内容）必须在同一个瞬间取**：编码是异步的（codec 是 Worker，
  400×300 的图 × 4 层 ≈ 30MB）而这段时间里用户可能换一张图 ⇒ 编码后再读键会写出
  `{key:'B', name:'B.cyrm', bytes: <A 的内容>}`。
- ★★ 编码期间可能已经有过一次 Ctrl+S ⇒ 落盘前再看一眼 `rev <= draftSavedRev`（`force` 也要过这一条）。
- ★ `force` = 即使这一版已经写过也照样写（离开页面前那一刀要的是此刻的一份）。
- ★ `markDraftSaved` 三件事一起做：① `draftSavedRev` 推到当前 rev；② `lastAutoSaveAt` 归零；
  ③ 草稿记录本身标 `dirty:false`（启动时 `offerDraft` 只问脏的）。
- ★ `openMap` 成功时另两笔账也要归位：`draftSavedRev = draftRev` 与 `lastAutoSaveAt = 0`。
- ★★ `saveCurrent` 里那条草稿盘记录挂在**存盘前**那个键上（`draftAt = currentDraftKey()`）：
  「另存为」会换名字，存完再问键就找不到。
- ★★ `app.raw` **只能**在解码**成功之后**认领：失败路径一个字段都不改（屏幕上那张图没动过），
  提前认领会让它装着失败文件的字节，而 `saveCurrent` 的原文备份与 `offerDraft` 的 `sameBytes` 都读它。

### 7.4 崩溃槽位

- ★★ `crashIsNewer` 只比「草稿盘里任意地图最新一份」的 `savedAt`（`idbNewestSavedAt` 与 `get('crash')`
  两条点读），并把 `declined` 也当判据。⚠ **已知局限**：它不知道崩溃那份草稿是哪张图的，
  所以用别的图刷新的草稿会把崩溃提示压下去。
- ★ `declined` 记在记录本身上（新的一次崩溃会重写这条记录、不带 `declined`）；记录本身**留着**。
- ★ 它排在 `openFromUrl()` **之后**（`bootLoad` 的顺序）；崩溃快照比草稿新时才轮到草稿盘
  （`if (recovered) return false;`）。
- ★ `consumeCrashSlot` 失败**不打扰用户**（下次打开还会问）。

### 7.5 UI 小状态（第 3 层）

- `UI_STATE_KEY = 'cyrm.ui.v1'` 带版本号。
- ★★ **逐字段校验**：一个坏字段不该把整份状态丢掉，也不该把坏值原样喂给渲染器。缩放那一处是**钳**不是
  「回落默认」（默认的 `0` 是「没存过缩放」的哨兵）。
- ★★ **`selectedTexture` 不许在 `readUiState` 里用图集派生的上界钳**：`bootLoad` 在图集存在之前就读这份状态，
  那时 `atlasCapacity()` 是 0 ⇒ `clampTexture` 返回 1 ⇒ 每次开机静默毁掉用户选中的纹理。
  钳制在 `applyUiState` 里做，它跑在 `loadAtlas()` **之后**。
- ★ `playerRef` 的位置**按格坐标**（`cx`/`cy`）存。
- ★ `localStore()`：读 localStorage 这件事本身在私密模式下就可能抛，故读与写的调用方都不必各自 `try`。
  `writeUiState` 的写失败是静默的。
- ★★ **压回 DOM 的两处**：① `applyUiState` 必须走**本文件**的 `setLayer`（内部再调 `app.r.setLayer`），
  直接调 `app.r.setLayer` 会让面板与图层行不跟着动；② `selectToolButton()`，否则工具条高亮钉在写死的画笔上。
- ★★ 压缩开关**只在存过这个字段时**才动它（老存档里没有 `compress`，照 `!!u.compress` 写会把框取消勾选）。
- ★ 节流而不是逐帧：localStorage 是同步写，挂在几个明确的变更点上。

## 8. 启动顺序（`bootLoad`）

1. `installCrashFence()` **第一件事就装**。
2. 草稿盘要在**打开地图之前**就绪（`offerDraft` 要用它；它打不开只影响自动存）。
3. 崩溃槽位 / 草稿盘的检查排在 `openFromUrl()` **之后**——恢复出来的那份必须**压住**刚从文件打开的那份。
4. `applyUiState()` 必须排在 `setMap` **之后**（`setMap` 自己会 `fit`）。

★ **面板必须建在打开之前**：`buildPanels` 只读 `app.tileDefs` 与 `app.r`，对 `app.map` 只有一处引用
且不读任何地图尺寸，并自带 null 守卫。挂在「打开之后」时，`openFromUrl()` 一旦拒绝就整条链短路到 `catch`，
工具条 / 图层行 / 调色板 / 出生点按钮一个监听都装不上。

★ **缺 Worker 没有降级路径** ⇒ 唯一正确行为是把话说清楚（`#boot-error`），不静默退回主线程。

## 9. 异步入口与错误通道

- ★ `guard` 是页面上**唯一的**报错收口：既接同步 `try/catch`，也接**视图入口返回的分帧 promise 的拒绝**
  （`resize` / `fit` / `setView` / `setZoomAt` / `panBy` / `setMap` / `invalidateAll`）。
  `Render.mount` 的 `onError` 指到同一个 sink。
- ★ 默认 sink = 状态栏；**有自定义 sink 时不再 `console.error`**（node 冒烟会故意触发失败）。
  ★ 报错通道自己坏了也不许把异常扔回调用方。★ 自检探完 sink 必须**还原**（不是置 `null`）。
- ★★ **`runJob` 的 promise 必须交给 `guard`**（油漆桶 / 渐变，以及 `keydown` 里那些 `pend`）：
  丢掉它 = 拒绝逃到全局围栏，围栏会 `snapshot()` ⇒ 一次普通的落笔/打开失败会把当前这张图写进崩溃槽位。
  `#lib-list` 的委托处理器同样必须包 `guard`（`openMap` 的失败是常态）。
- ★ `Promise.resolve(guard(...))`：`guard` 在同步抛时返回 `null`，直接 `.then` 会炸成 `TypeError`。
- ★ 视图入口都要**经 `guard` 收口**，`guard(...)` 写在调用旁边。
- ★ `onWin`：node 冒烟里 `window` 是 `globalThis`，而 `globalThis` 没有 `addEventListener`，
  裸 `window.addEventListener(...)` 会在 `bootLoad()` 第一行就抛。

## 10. 交互与工具内核

- ★ **空格是修饰键，不进 `commandFor`**：`keydown` 置位、`keyup` 与 `blur` 清位（`blur` 那条防「按住空格切窗口」）。
- ★★ `keyup` 的清位必须**无条件**做，只有 `preventDefault` 才走「输入控件里不拦」那道早退，否则修饰键会永久卡住。
- ★ 空格需要 `preventDefault`：它是浏览器的向下翻页键（`#right` / `#lib-list` 都是 `overflow:auto`），
  也会被当成「按下当前聚焦的按钮」；`keyup` 那一半同样要拦。
- ★★ **焦点在输入控件里时一个键都不许拦**（命令表含 `Backspace/Delete`、`0-9`、`b/e/g/l/m/i`、方向键）。
  判据取 `tagName` 与 `isContentEditable`，**不取** `ev.target === document.activeElement`。
- ★ Esc 可能在拖动途中按下：① 清在飞的拖动记录（必须排最前）；② `setSelDrag(null)`；③ 清选区。
  拖动分支还要**先取局部变量再判**（取消之后 `sd` 是 `null`）。
- ★★ **存回去的选区必须折算**（`Render.wrapIdx`）：拖动跨过接缝时 `cur.x + sd.dx` 会落到 `[0, subCols)` 之外，
  而 `regionCells` 先折算再 `inRect` ⇒ `clip.x < 0` 时一格都进不来，且没有任何状态栏消息。
- ★ **单击也要落一次笔**：判据取 `painted` 而不是「`last` 是否等于 `from`」。
- ★★ **两个颜色槽是渐变的全部**：`rgba` = 起点、`rgba2` = 终点。背景层是不透明的真彩
  （`#RRGGBB → 0xRRGGBBFF`，alpha 由辅码那一路管不了它）。
- ★★ **渐变仅背景层**：工具按钮只是压暗，真正的闸在 `pointerdown`。
- ★ 纹理 **22（水面）** 在编辑器里可选、在游戏里是自动派生的 ⇒ 排除出调色板，只在提示里点名
  （`#palette-hint`，它是 `#palette` 的派生行，背景层上跟着一起藏）。
- ★★ **选区成员的判据本体只有一处**（`Render.inSel`）：拖动预览的源格查询、`regionCells` 的 `clip`、
  `moveRegion` 的 `from` 集合、「按下算不算在选区里」都转调它，且它做**环面折算**。
- ★★ **`Core.lineCells` 的坐标必须是整数**：非整数或 NaN 会让它的 `for(;;)` 死循环、挂住整个标签页。
  **所有**调用点都在 `strokePoints` / `constrainLine` / `constrainSquare` 里 `floor`（新调用点漏 `floor` 抓不到）。
- ★★ **「只改辅码」这一支不能少**：空气仍是空气，有纹理的保留**原纹理**、只换辅码。
- ★★ **`clampTexture` 的上界派生自图集**（列 × 行）：容量 < 1 一律当「没有信息」⇒ 只给 1，
  **不可**放宽到描述符位宽那个上界（越界号会直接进 `tileFor`，它抛且每帧同一处抛一屏）。
- ★★ **油漆桶 / 渐变不预展开整张图**：逐格推进，顺序是行主序；`scanned` 数的是**扫过的格**（含被选区挡掉的）。
- ★★ **镜像的非法 `axis` 必须当场抛出**（带原因的中文错），不可退化成恒等再静默回 `null`；
  抛出的错在上层被 `guard(...)` 接住 → 落进状态栏。`mirrorSelection` 里 `if (out.threw) return;`
  不可省（否则「没改动」文案会把刚写上去的错覆盖掉）。抛出的错**绝不许**进历史（历史只收 `diff|null`）。
- ★★ **选区移动没有「裁剪」这一步**：目标格 = 源格 + 偏移（两边都环面折算），源区里没被目标覆盖的格被清空。
- ★ **跨图层粘贴只允许「纹理 ↔ 纹理」**，拒绝时**给出原因**。
- ★★ **整图级差量必须原地装字段**（`adoptMapInto`）而不是 `app.map = out.map`：`wholeDiff(map, …)` 的 `seal()`
  快照的是它建时抓的那个对象。`applyEntry` 的 `whole` 分支相反，必须**防御性拷贝** `map.layers`。
- ★★ 尺寸/换图这类操作没法差量（table 级），走 `kind:'whole'` 并**按字节**记账：
  `MAX_UNDO_BYTES = 64MB` 是真闸，`MAX_UNDO = 200` 是廉价上界。撤销栈至少留一条。
- ★★ **改尺寸那条路的选区清理**：`invalidateAll` 不清选区（只有 `setMap` 清）⇒ 留下的框会画在图外，
  且消费选区的工具走 `idxOf` 的取模折算、把图外的格折回图里落笔。清掉（看得见）优于钳到边界。
  撤销/重做**都要**判一遍。
- ★★ **改尺寸的 before 快照必须在改动之前取**，改完还要翻新状态栏的 `#st-size` 与尺寸面板的两个框。
- ★★ **越界项要报出来**（`resizeMap` **只丢不钳**）。`spawnAt` 的「视图中心那一格」也必须 `Render.wrapIdx`
  折算（`panBy` 不钳视图 ⇒ 环面模式下会算出越界坐标）。
- ★★ **P1/P2 是位置语义、不是「第几条记录」**：放 P1 = 写第 0 条、放 P2 = 写第 1 条；缺号一律**显式拒绝**
  并说明理由，不可 `push` 出一条位置不对的记录。
- ★★ **库列表里混进备份的后果**：`openFromUrl` 的兜底是「打开列表第一行」⇒ 开机可能直接打开一份退路。
- ★ **面板监听只挂一份**：`#lib-list` 那一处用**委托**一次，不给每行挂监听。
- ★ **背景层时面板要换一套控件**：纹理调色板 + 辅码 ↔ 颜色选择器；工具条上「渐变」压暗到 0.45。
  藏的是**整行**而不是控件的直接父节点（「只改辅码」那个 input 外面还包着 `<label>`）。
  输入框里的回车也当「应用尺寸」。
- ★ **没打开地图时的提示要一致**：四个出生点按钮与改尺寸面板都必须说「先打开一张地图」。
- ★ **导出的敌人类型清单来自页面注册表**（`globalThis.ENEMY_REGISTRY`），导出校验只警告不阻止导出。
  ★ 已知边界：第 3 个及以后的出生点游戏侧读不到（`map_format.gd` 只认 `player` / `player2`）。
- ★ **`editor_server.js` 不做删除动作**：删地图请直接在磁盘上删 `maps/` 下的文件。
- ★ **刷新库列表排在说结果之后**：那条 GET 失败时 `guard` 会往同一条状态栏写一行错误，先写「已保存 …」
  再被它盖掉的话用户看到的是「刷新失败了」，而保存其实成功了。刷新不影响落盘。
- ★ **`refreshStatus` 是几条换图路的公共收口**（打开 / 新建 / 复制 / 改尺寸 / 草稿恢复），
  `sizeInputsSync` 挂在它里面。

## 11. 自检（浏览器侧唯一能跑的判据）

- 判据是文本 `SELFTEST OK`；失败逐条列出。人在浏览器里点「自检」按钮，把那行贴回报告。
- ★★ 自检是页面上的**异步入口**之一，必须经 `guard` 收口（它会拒绝：`Io.ping()` / `Io.encodeMap` /
  `Io.decodeMap` 的 30s 超时是拒绝源，它自己也会探 `indexedDB`、`localStorage`）。
- ★ **探的是真行为**：`probeIndexedDb` 真开一次库，超时也必须收口（2 秒没有回调就判失败并写出原因），
  并删掉自检建的库。
- ★ 「IndexedDB 可打开」与「草稿盘已打开（`app.db`）」**不是**同一件事，两条读数各自要能看到。
- ★ 抽成具名函数（`runSelfTest`），判「有没有护栏」必须是**行为**断言。
