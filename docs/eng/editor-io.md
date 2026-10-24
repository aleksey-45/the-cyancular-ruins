# 编辑器 io 门面与 tint 像素缓存（`level_editor/io.js` / `level_editor/tint.js`）

> 本文件记 `level_editor/io.js` 与 `level_editor/tint.js` 的契约与常量。★ 冲突以源码为准，读前先 `grep` 复核。
> 返回索引：[`CLAUDE.md`](../../CLAUDE.md)。格式核心层见 [`editor-core.md`](editor-core.md)。

## 1. io.js：每请求 30 秒超时

- `worker.onerror` 只覆盖「worker 自己报了错」这一条死法；worker 被杀或挂住时 `await Io.encodeMap(…)`
  **永远不 settle**（一个悬挂的 promise 连异常都没有）。30 秒的量级：编码一张 125×75 的地图是毫秒级。
- 超时回调**不自己拒那一条请求**，而是走收口 `failAll`，于是「标死 + 拒光在飞 + 回收 worker」
  与 `terminate()` / `onerror` 两条死法同一份代码。
- 「标死」是必须的：只拒当前这一条的话，下一次调用会**静默**再起一个 worker，无限循环。
- 守卫：`level_editor/worker_io_smoke.js` 相位 ⑫ 用注入时钟跑这条路径。

## 2. io.js：三条死法共用的收口

- 三条死法 = `terminate()` / `worker.onerror` / 请求超时，它们**只走** `failAll` 一个收口：
  标死 + 拒光在飞（连定时器一起撤）+ 清表 + 回收 worker。
- ★ 顺序是承重的：**先标死、先拒光、先清表，回收放最后**（`worker.terminate()` 万一抛，promise 已拿到失败）。
- ★ 「dead 只认第一个错因」由 `failAll` 里的 `if (dead === null)` 保证，这条守卫只写在 `failAll` 一处。
- 回收时**先置空引用再 terminate**；`terminate()` 之后在飞请求必须当场拒掉（留着就是永不 settle 的 promise）。

## 3. io.js：定时器的撤销与 postMessage 抛错

- 契约：`opts.timer` 一旦给了，`setTimeout` 与 `clearTimeout` **必须成对**给，否则每一次成功的请求
  都会在 30 秒后触发一次超时收口、把整条链打死。
- 两条撤闹钟的路缺一不可：**答复到达**与**发出失败**（`DataCloneError`）。
- `postMessage` 会抛：这一档**只清自己那条**，codec 不标死；表里那条不删则 resolver 被永久攥着。
- `onerror` **无条件覆盖**，不可写成 `if (typeof worker.onerror !== 'function')`。
- 表里查不到的应答（`pending.get(id)` 为空）**直接丢**。
- 本文件**没有** `errText()`：错误文本在 `level_editor/worker.js` 里由 `reply(errText(e))` 格式化好，
  经 `{ok:false, error}` 原样带回。

## 4. tint.js：象限与命中判据

- `quadIndex` 把越界坐标**当场抛掉**；环面回绕由调用方自己先做。
- 命中判据必须是 `tiles.has(k)`，**不可**写成 `tiles.get(k) !== undefined`（backend 返回 `undefined` 时
  后者恒假：那张图永不命中，却已占着槽位、计入 size、还能挤掉活条目）。

## 5. tint.js：与游戏 shader 逐像素一致的像素数学

| 量 | 规定 | 中性档 |
|---|---|---|
| 色彩空间 | **HSV**，不是 HSL | —— |
| 色相 | `h' = fposmod(h + (H-4)*15, 360)`，八档**不对称**（−60°…+45°） | 4 |
| 亮度 / 饱和度 | **乘法**，乘数 `(k+6)/10`（MUL 表 0.6…1.3） | 4（×1.0，恒等元） |
| alpha | `a' = a * (A/7)` | **7**（不是 4） |

- 档位的中性行、象限数、位域取值**全部取自 `globalThis.Core`**（单一真相源）。
- 8 位通道的取整规则只有一处：`round(clamp01(x) * 255)`；规范定义 `tintRGBA` 浮点进浮点出。
- 放大必须是**最近邻**（与项目其余 `texture_filter=nearest` 一致）。
- 地图集：`structure.png` 是 320×320、每块 32×32；`textureBlockRect` 从传入的图集宽度算列数，不写死。
- 缓存上限 `DEFAULT_MAX_TILES = 8192`（8192 × 16×16×4 字节 = 8MB）。

## 6. tint.js：抛错是「编程错误」的哨兵

- 会抛的入口：`buildTilePixels`（空气格 `desc === 0`、纹理号超出图集行/列、纹理实参与 `Core.texOf(desc)`
  不一致、象限坐标不是 `0..SUB_PER_CELL-1` 的整数）、`quadIndex`（越界象限）、`textureBlockRect`
  （纹理号或图集宽度非法）、`setSource`（参数形状不对）。渲染循环必须先过滤 `desc === 0`。
- ★ `setSource`：传 `ImageData` **对象**（而不是它的 `.data`）时 `atlas.length` 是 `undefined` ⇒
  `rows = NaN` ⇒ 边界比较恒为 false ⇒ 一路产出全透明小图且不报错。形状守卫只做在参数形状上。
- 缓存画布是**注入**的（`opts.backend`）；换图（`setSource`）**必须整片失效**。
