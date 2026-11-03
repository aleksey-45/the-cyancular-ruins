# 工具与格式(地图编辑器等)

> 本文件覆盖编辑器的两种打开方式、目录结构、格式与验收入口。返回索引：[`README.md`](README.md)。
> 各层细节：[core](editor-core.md) / [ui](editor-ui.md) / [render](editor-render.md) / [io](editor-io.md) /
> [server](editor-server.md)。★ 冲突以源码为准，读之前先 `grep` 复核。

## 1. 怎么打开编辑器

**带库工作流(推荐)**：双击 `level_editor/serve.bat`(需要 node) ⇒ `http://127.0.0.1:8777/`。服务器是
`level_editor/editor_server.js`(node，**只绑 127.0.0.1**，端口 8777 避开 7777/7800+/7999)，
实现分片在 `level_editor/server/`。
- ★ **重复双击 = 结束上一个编辑器服务器再起新的**(入口写 `level_editor/.editor_server.pid`，按
  pid/端口/命令行三重判据确认"是自己人"才 `taskkill`；查不到命令行就 **fail closed** 拒绝杀)。`--keep` 关掉该行为。
  这条挡的是"改了 `server/*.js` 重启后行为没变，因为跑的还是内存里那份旧代码" —— 契约见 [`editor-server.md`](editor-server.md) §7。
- ★ 编辑器**开机不自动打开地图**：空状态里给「新建 / 打开文件… / 打开文件夹…」三个入口
  （HTTP 版与单文件版同一套 UI；单文件版的 FSA 由垫片接管）。

**开箱即用(不需要 node)**：**`level_editor/dist/cyrm-editor.html`** —— 单文件、双击即用(全部分片 + 图集 +
worker 源码都内联进这一个 HTML;`file://` 下没有服务器也能跑)。
- 点右栏「**本地目录…**」选一个装有 `.cyrm` 的目录(如 `maps/`，需 Chrome/Edge 的 File System Access 权限)
  ⇒ 库列表与 `Ctrl+S` 都直接读写它;没有该能力的浏览器用「**打开文件…**」，保存退化为下载 `.cyrm`。
  ★ 单文件版**不再**在库为空时自动造一张空白图(②)：空状态由 `#empty-hint` 说明三个入口。
- ★ **边界**(`node browser_check.js` 在 `file://` 下 17/17):IndexedDB、localStorage、同页 Worker 编解码往返
  都可用;不保证的是 File System Access。编解码在单文件版里跑在**主线程**，大图保存会有一帧级停顿。
- 重新打包:`node level_editor/build_dist.js`;抓漂移:`node level_editor/build_dist.js --check`
  (生成物**不要手改**)。★ 发布包**不含**它:`export_presets.cfg` 的 `exclude_filter` 里有 `level_editor/dist/*`。

## 2. 目录结构(分片 + 共享作用域)

页面侧模块是**经典脚本**(无 ESM、无 require):每个模块拆成 `NN_<topic>.js` 分片放进目录，按 `editor.html`
的 `<script src>` 顺序加载，**所有分片共享同一个作用域**;每个模块的末片 `99_exports.js` 就是公开 API 表
(`globalThis.Core` / `Render` / `Editor` …)—— 改它等于改公开接口。

```
level_editor/editor.html            入口:分片清单(顺序的单一真相源)
level_editor/core/    13 片         格式层(编解码冻结;95_legacy.js = legacy 纹理 id 读时迁移)
level_editor/render/  19 片         渲染层
level_editor/ui/      20 片         界面层
level_editor/tint.js / level_editor/io.js / level_editor/worker.js   单文件模块(都 <300 行)
level_editor/tile_defs.js           生成物(sync-tiles.js:15 条 tiles + legacy_texture_map)
level_editor/server/  9 片 + level_editor/editor_server.js(入口,62 行)
level_editor/tests/   harness.js + format|tint|worker_io|render|editor|server/(各套件的分片)
level_editor/{loader,parts_check,build_dist,standalone_shim,dist_smoke}.js
                                    加载器 / 结构守卫 / 打包 / 单文件垫片 / 单文件冒烟
level_editor/*_smoke.js             6 套 node 冒烟的瘦入口(分片在 tests/ 下)
level_editor/dist/cyrm-editor.html  生成物(**开箱即用**的那个单文件)
```

- **改分片顺序** ⇒ 改 [`level_editor/editor.html`](../../level_editor/editor.html)(唯一真相源);
  [`level_editor/worker.js`](../../level_editor/worker.js) 的 `importScripts` 列表必须与其中的
  `level_editor/core/` 分片一致、**末尾再加 `tile_defs.js`**(worker 没有 window,worker.js 顶部先补
  `self.window = self` 别名;validateMap 的「纹理不在 tile_defs」闸要在真做编码的 worker 侧也成立),
  `node level_editor/parts_check.js` 会抓不一致。
- 生成物两处:[`level_editor/dist/cyrm-editor.html`](../../level_editor/dist/cyrm-editor.html)(build_dist.js)、
  [`level_editor/tile_defs.js`](../../level_editor/tile_defs.js)(sync-tiles.js)—— 都别手改。
- 注释额度:>100 非空行的 `.js` 文件整行注释 ÷ 非空行 ≤ 15%，`node parts_check.js --ratio` 可复算。

## 3. 格式与两层实现

- **格式**:`.cyrm` **v4 二进制**(明文 20 字节头 + deflate + CRC32)，四图层、每格 4×4 个 16px 子格、
  每子格带辅码。**导入**认三种输入(v4 二进制 / 带 `# cyrm-v3` 标记的 v3 文本 / 旧字母格式)，
  **导出只有二进制一种**;打开 v3 文本的图首次 `Ctrl+S` 会弹一次确认(v3 → v4 的迁移是一次性的)。
  ★ **legacy 纹理 id(2,3,4,5,16,17,18 —— 新图集那 7 个全透明槽)在读取时迁移**:三种导入与草稿/
  崩溃恢复四个入口都过 `Core.migrateDescriptor/migrateMap`,纹理 id 空间稳定 1..22、格式保持 v4 不升版本
  (规则与守卫见 [`editor-core.md`](editor-core.md) §6.1)。
- **游戏侧读的是 v4**:`core/sim/map_format.gd` 的 `is_v4()` → `MapFormatV4.parse()` 是现行唯一在跑的路径;
  `maps/*.cyrm` 实盘都是 v4。编辑器保存的唯一出口 `PUT /api/map` 写的正是 `maps/`，
  `MazeGenerator._random_cyrm` 随机取 `maps/` 下任意 `*.cyrm`。
- **两份格式实现**:[`level_editor/core/`](../../level_editor/core)(入口片
  [99_exports.js](../../level_editor/core/99_exports.js))是**冻结层**、与游戏侧 `map_format.gd` 逐字对应，
  两边改一处必须同步改另一处(契约与常量见 [`editor-core.md`](editor-core.md))。
- **砖形由画笔大小表达**(整数大小画整格、`.25/.5/.75` 画子格);**纹理 22(水面)不在调色板里**
  (游戏侧按地形自动派生)。
- **出生点** `# player` / `# player2` 与**按侧复活点** `# respawn <1|2>` 都能在编辑器里放:后者按半区画
  `R1`/`R2`、带 3×3 桶辅助线、校验会报"每侧 <5 / 越半区 / 空桶"等 warning(判据见
  [`editor-core.md`](editor-core.md) §9、UI 见 [`editor-ui.md`](editor-ui.md) §12.5)。
- **可改层**:[`level_editor/render/`](../../level_editor/render) / [`level_editor/ui/`](../../level_editor/ui) /
  [`level_editor/io.js`](../../level_editor/io.js) + [`level_editor/worker.js`](../../level_editor/worker.js);
  [`level_editor/tint.js`](../../level_editor/tint.js)(辅码像素数学)与 core 同为**冻结层**。
- **敌人表**:编辑器内嵌的敌人注册表由 `node level_editor/sync-enemies.js` 从 `data/enemies.json` 重新生成
  (`--check` 只校验);砖块属性表同理走 `sync-tiles.js` —— 生成物 `tile_defs.js` 含 **15 条 `tiles` +
  顶层 `legacy_texture_map`(7 条旧 tex → {base,hue})**,两处都以 `data/tile_defs.json` 为单一真相源。

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
node parts_check.js --baseline   # 代码等价:"分片按序拼接 == 拆片前的单文件"
node parts_check.js --ratio      # 注释额度(>100 非空行的 .js ≤15%)
```
- `--baseline` 省略 rev 时自己取「该模块最后一个还含单文件的提交」(`git log -1 --diff-filter=AM`)，
  想比特定一版就 `--baseline <rev>`。`core/` 与 `ui/` 与基线**逐字符等价**;`render/` 的判据是**行为等价**。
  各入口都是**瘦入口**:分片在 `tests/<套件>/` 下，断言助手在
  [`level_editor/tests/harness.js`](../../level_editor/tests/harness.js)。
- ★★ **一条判定类别 = 一条守卫**:家族式断言一律用 `harness.js` 的 `tableEq(msg, rows)` 收成一条表比
  (`rows` = `[标签, 实得, 期望]`，失败时点名首个不匹配行)。加/删断言要同步改入口的条数闸。
- **浏览器侧**:页面上点「**自检**」按钮 ⇒ 打印一行 `SELFTEST OK` 或 `SELFTEST FAIL: n 条`;`?selftest`
  查询参数也会在 boot 末尾自动跑一次。
- **自动化复跑(判据:文本 `SELFTEST OK` **且**条数 ≥ 17 条 + 退出码 0)**:
  ```bash
  cd level_editor
  node browser_check.js                    # 跑 dist 单文件版(file://)
  node browser_check.js http://127.0.0.1:8777/   # 跑 serve.bat 起的那个(先起服务器)
  ```
  它用 CDP 直连本机 Chrome/Edge(`CHROME=<路径>` 可指定浏览器)，等 boot 真走完再**真点一下页面上的
  「自检」按钮**，把 17 条结论逐条打印出来。
- ★ 必须点按钮而不是直接调 `Editor.selfTest()`(按钮接线是 `if (btn) btn.addEventListener(...)`，
  id 打错就是静默失效)。判据取**状态栏**;`EXPECTED_CHECKS = 17` 是条数闸，改
  `level_editor/ui/96_selftest.js` 里的 `check(` 条数时**必须同步改它**。
  ★ 不可用 `chrome --dump-dom` 代替:它在 `load` 那一刻就导出 DOM，而 boot 的链全在那之后。

## 5. 已知局限

① **跨接缝的选框会选出一整行/一整列**(它是画出来的，不是静默);② **分数画笔会把选框每轴撑大至多
3 个子格(¾ 格)** —— 选框是**格对齐**的;③ **选区拖动时的逐块去烤是同步的**，面积已 ≤3~4 块，
极端情况下仍可能掉一帧;④ **崩溃栅栏比的是「任意地图最新的一份草稿」**，给另一张图写的草稿会抑制掉
一次合法的恢复提示;⑤ 单文件版的编解码跑在**主线程**，`file://` 下 File System Access 要看浏览器给不给。

## 6. Windows 脚本的两条硬约束(改 `.ps1` / `.bat` 前必看)

- **换行**:`.ps1` 与 `.bat` **必须 CRLF** —— 裸 LF 的 `.ps1` 会被 PowerShell 解析成一条怪命令;`.bat` 会被 cmd 吃掉行尾。
- **编码**:`.ps1` = 「**纯 ASCII 或带 UTF-8 BOM**」(无 BOM 的非 ASCII 在中/英区域会按 GBK 读 ⇒ 中文全乱、字符串被截断);`.bat` 不查编码。
- 两条都由 [`check_naming.py`](../../tools/check_naming.py) 的**规则 E** 逐文件守。红了的标准修法是 `rm <file> && git checkout -- <file>` 重新落盘(**纯 EOL,不动内容**)。
- **带空格的路径**在 PowerShell 里要**手工内嵌双引号**(`& "C:\Program Files\..."`);传参给 `.bat` 同理。
