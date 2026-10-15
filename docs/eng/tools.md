# 工具与格式(地图编辑器等)

> 从 [`CLAUDE.md`](../../CLAUDE.md) 拆出(2026-10-03),2026-10-15 随"编辑器拆目录 + 单文件版"重写。
> 返回索引:[`CLAUDE.md`](../../CLAUDE.md)。本文件覆盖:编辑器工具与它的目录结构。
> ★ 文档会过期 —— **任何冲突以源码为准**,读之前先 `grep` 复核。

## 1. 怎么打开编辑器

**开发 / 带库工作流(推荐)**:双击 `level_editor/serve.bat`(需要 node)⇒ `http://127.0.0.1:8777/`。
服务器是 `level_editor/editor_server.js`(node,**只绑 127.0.0.1**,端口 8777 刻意避开 7777/7800+/7999),
实现分片在 `level_editor/server/`。旧的 `structure-editor.html` 已退休。

**开箱即用(不需要 node)**:**`level_editor/dist/cyrm-editor.html`** —— 单文件、双击即用
(全部分片 + 图集 + worker 源码都内联进这一个 HTML;`file://` 下没有服务器也能跑)。
- 点右栏「**本地目录…**」选一个装有 `.cyrm` 的目录(如仓库的 `maps/`,需 Chrome/Edge 的
  File System Access 权限)⇒ 库列表与 `Ctrl+S` 都直接读写它;
- 没有目录访问能力的浏览器/环境用「**打开文件…**」,保存退化为下载 `.cyrm`;
- 库是空的时候开机**自动给一张 125×75 的空白图**(否则双击进来只有一片黑画布);
- ★ **实测边界**(`node browser_check.js` 在 `file://` 下 17/17 全绿):IndexedDB、localStorage、
  同页 Worker 编解码往返**都可用**;不保证的是 File System Access(浏览器可能拒绝目录授权,
  那时退化成"打开文件 + 下载")。编解码在单文件版里跑在**主线程**(没有独立 worker 文件可加载),
  大图保存会有一帧级停顿。
- 重新打包:`node level_editor/build_dist.js`;抓漂移:`node level_editor/build_dist.js --check`
  (生成物**不要手改**)。★ 发布包**不含**它:`export_presets.cfg` 的 `exclude_filter` 里有
  `level_editor/dist/*`(生成物进发布包只会在每次构建里留一份过期副本)。

## 2. 目录结构(分片 + 共享作用域)

页面侧模块是**经典脚本**(无 ESM、无 require):每个模块拆成 `NN_<topic>.js` 分片放进目录,
按 `editor.html` 的 `<script src>` 顺序加载,**所有分片共享同一个作用域**;每个模块的末片
`99_exports.js` 就是公开 API 表(`globalThis.Core` / `Render` / `Editor` …)—— 改它等于改公开接口。

```
level_editor/editor.html            入口:分片清单(顺序的单一真相源)
level_editor/core/    12 片         格式层(冻结)
level_editor/render/  19 片         渲染层
level_editor/ui/      19 片         界面层
level_editor/tint.js / level_editor/io.js / level_editor/worker.js   单文件模块(未拆:都 <300 行)
level_editor/tile_defs.js           生成物(sync-tiles.js)
level_editor/server/  9 片 + level_editor/editor_server.js(入口,62 行)
level_editor/tests/   harness.js + format|tint|worker_io|render|editor|server/(各套件的分片)
level_editor/loader.js              node 侧按浏览器语义加载分片(测试用)
level_editor/parts_check.js         结构守卫:顺序 / 跨模块重名 / worker 的 importScripts / 末片 / 注释额度 / 代码等价(有意的两处差异登记在它自己的 PAGE_MODULES 里)
level_editor/build_dist.js          产出 level_editor/dist/cyrm-editor.html
level_editor/standalone_shim.js     单文件版的运行时垫片(同页 Worker + 本地文件后端 + 两个入口按钮)
level_editor/*_smoke.js             6 套 node 冒烟的瘦入口(判词不变;分片在 tests/ 下)
level_editor/dist_smoke.js          单文件版冒烟
level_editor/dist/cyrm-editor.html  生成物(**开箱即用**的那个单文件)
```
- **改分片顺序** ⇒ 改 [`level_editor/editor.html`](../../level_editor/editor.html)(唯一真相源);
  [`level_editor/worker.js`](../../level_editor/worker.js) 的 `importScripts` 列表必须与它里面的
  `level_editor/core/` 分片一致,`node level_editor/parts_check.js` 会抓不一致。
- 生成物两处:[`level_editor/dist/cyrm-editor.html`](../../level_editor/dist/cyrm-editor.html)
  (build_dist.js)、[`level_editor/tile_defs.js`](../../level_editor/tile_defs.js)(sync-tiles.js)——
  都别手改。
- 注释额度(同 [`comment-style.md`](comment-style.md) §8):>100 非空行的 `.js` 文件
  整行注释 ÷ 非空行 ≤ 15%,`node parts_check.js --ratio` 可复算。

## 3. 格式与两层实现

- **格式**:`.cyrm` **v4 二进制**(明文 20 字节头 + deflate + CRC32),四图层、每格 4×4 个 16px
  子格、每子格带辅码。**导入**仍认三种输入(v4 二进制 / 带 `# cyrm-v3` 标记的 v3 文本 /
  旧字母格式),**导出只有二进制一种**;v3 → v4 的迁移是一次性的,所以打开 v3 文本的图首次
  `Ctrl+S` 会弹一次确认。
- ★★ **游戏侧今天读得了 v4**（**2026-10-13 订正**：原文写"还读不了 v4 —— 别点那个确认框"，
  **与源码相反**）。`core/sim/map_format.gd` 的 `is_v4()` → `MapFormatV4.parse()` 是**现行唯一
  在跑**的路径；`maps/*.cyrm` 实盘都是 v4。编辑器保存的唯一出口 `PUT /api/map` 写的正是仓库里的
  `maps/`，而 `MazeGenerator._random_cyrm` 随机取 `maps/` 下任意 `*.cyrm` ⇒ **迁到 v4 不再是危险操作**。
- ★ 但"**两份格式实现**"这件事没变:[`level_editor/core/`](../../level_editor/core)(入口片 [level_editor/core/99_exports.js](../../level_editor/core/99_exports.js))是**冻结层**、
  与游戏侧 `map_format.gd` 逐字对应，两边改一处必须同步改另一处。格式层为什么这么定、
  各闸门与契约的完整推导见 [`editor-core.md`](editor-core.md)。
- **砖形面板已删除**(2026-09-19 裁定):在"子格独立纹理"的模型下,"形状"退化成"这一笔盖哪几个
  子格",由画笔大小表达(整数大小画整格、`.25/.5/.75` 画子格)。
- **纹理 22(水面)不在调色板里**:游戏侧它是按地形自动派生的,画了会与游戏不一致。
- **改编辑器**:[`level_editor/core/`](../../level_editor/core)(格式)/ [`level_editor/tint.js`](../../level_editor/tint.js)(辅码像素数学)是**冻结层**;[`level_editor/render/`](../../level_editor/render) / [`level_editor/ui/`](../../level_editor/ui) / [`level_editor/io.js`](../../level_editor/io.js) + [`level_editor/worker.js`](../../level_editor/worker.js) 是可改层。
- **敌人表**:编辑器内嵌的敌人注册表由 `node level_editor/sync-enemies.js` 从 `data/enemies.json`
  重新生成(`--check` 只校验);砖块属性表同理走 `sync-tiles.js`。

## 4. 测试与验收

**node 侧(全部 headless、不碰 7777、不弹窗)**:
```bash
cd level_editor
node smoke.js          # 格式层      判词 SMOKE OK
node tint_smoke.js     # 辅码像素数学 判词 TINT SMOKE OK
node worker_io_smoke.js# worker/io    判词 WORKER IO SMOKE OK
node render_smoke.js   # 渲染层       判词 RENDER SMOKE OK
node editor_smoke.js   # 界面层       判词 EDITOR SMOKE OK
node server_smoke.js   # 本地服务器   判词 SERVER SMOKE OK(只用临时目录与临时端口)
node dist_smoke.js     # 单文件版     判词 DIST SMOKE OK
node parts_check.js    # 结构守卫     判词 PARTS CHECK OK
node parts_check.js --baseline   # 代码等价:"分片按序拼接 == 拆片前的单文件"(逐字符,减掉有意的两处)
node parts_check.js --ratio      # 注释额度(>100 非空行的 .js ≤15%)
```
★ `--baseline` **不用记版本号**:省略 rev 时它自己取"该模块最后一个还含单文件的提交"
(`git log -1 --diff-filter=AM`),所以拆批**提交前后都能跑**;想比特定一版就 `--baseline <rev>`。
`core/` 与 `ui/` 与基线**逐字符等价**(render/ 例外:它的拆分含闭包分解,判据是行为等价)。
★ 每个入口现在都是**瘦入口**:分片在 `tests/<套件>/` 下,断言助手在 [`level_editor/tests/harness.js`](../../level_editor/tests/harness.js)。
★★ **一条判定类别 = 一条守卫**(D9):家族式断言(一个热键一条 / 一个数值一条 / 一条路径一条)一律用
`harness.js` 的 **`tableEq(msg, rows)`** 收成**一条**表比 —— `rows` 是 `[标签, 实得, 期望]`,
失败时它**点名首个不匹配的那一行**(纯数组比会丢掉这条诊断,所以别用)。加/删断言要同步改入口的条数闸。

**浏览器侧(node 到不了的那半边)**:
- 页面上点「**自检**」按钮 ⇒ 打印一行 `SELFTEST OK` 或 `SELFTEST FAIL: n 条`(两种打开方式都有);
  `?selftest` 查询参数也会在 boot 末尾自动跑一次(输出进 console)。
- **自动化复跑(判据:文本 `SELFTEST OK` **且**条数 ≥ 17 条 + 退出码 0)**:
  ```bash
  cd level_editor
  node browser_check.js                    # 跑 dist 单文件版(file://)
  node browser_check.js http://127.0.0.1:8777/   # 跑 serve.bat 起的那个(先起服务器)
  ```
  它用 CDP 直连本机 Chrome/Edge(不依赖 puppeteer;`CHROME=<路径>` 可指定浏览器),等 boot
  真走完(调色板建出来 + 渲染器挂上)再**真点一下页面上的「自检」按钮**,把 17 条结论逐条打印出来。
  ★★ **为什么点按钮而不是直接调 `Editor.selfTest()`**:按钮接线是 `if (btn) btn.addEventListener(...)`
  ⇒ id 打错 / 漏接就是**静默失效**(点了没反应),直接调会绕过这条路。判据取**状态栏**(成功写
  `SELFTEST OK · 共 N 条检查`,失败由 `guard` 写错误);`EXPECTED_CHECKS = 17` 就是那条**条数闸** ——
  `SELFTEST OK` 本身只证明"没有任何失败输出",把自检削掉一半也照绿(改 `level_editor/ui/96_selftest.js` 里的
  `check(` 条数时**必须同步改它**)。
  ★ 不要用 `chrome --dump-dom` 代替:它在 `load` 那一刻就导出 DOM,而 boot 的链(草稿盘 →
  图集 → 库 → 打开图)全在那之后;`--virtual-time-budget` 又会让 IndexedDB 的回调永远不来。 

## 5. 已知局限(未修)

① **跨接缝的选框会选出一整行/一整列**(它是**画出来的**,不是静默);② **分数画笔会把选框每轴撑大至多
3 个子格(¾ 格)** —— 选框是**格对齐**的,而 `.25/.5/.75` 画的是子格;③ **选区拖动时的逐块去烤是
同步的**,面积已 ≤3~4 块,极端情况下仍可能掉一帧;④ **崩溃栅栏比的是"任意地图最新的一份草稿"**,
所以给**另一张图**写的草稿会抑制掉一次合法的恢复提示 —— 宁可少问一次,方向是安全的;
⑤ 单文件版的编解码跑在**主线程**(打包页里没有独立 worker 文件可加载),大图保存会有一帧级停顿;
`file://` 下 File System Access 要看浏览器给不给(给不了就退化成"打开文件 + 下载")。

## 6. 域文档

| 想查什么 | 去哪 |
|---|---|
| 格式层([`level_editor/core/`](../../level_editor/core)):容器/压缩/v3 迁移/校验/契约与不保证 | [`editor-core.md`](editor-core.md) |
| 界面层([`level_editor/ui/`](../../level_editor/ui)):工具内核、历史、持久化三层、面板与启动 | [`editor-ui.md`](editor-ui.md) |
| 渲染层([`level_editor/render/`](../../level_editor/render)):四层缓存、脏区、环面、分帧预算与闭包分解 | [`editor-render.md`](editor-render.md) |
| [`level_editor/io.js`](../../level_editor/io.js) / [`level_editor/worker.js`](../../level_editor/worker.js):超时、三条死法收口、消息协议 | [`editor-io.md`](editor-io.md) |
| 本地服务器([`level_editor/server/`](../../level_editor/server)):写闸/安全闸/原子写/重试实测 | [`editor-server.md`](editor-server.md) |
| 编辑器测试怎么跑、单文件版怎么打包 | 本文件 §1/§4 |
