# 工具与格式(地图编辑器等)

> 从 [`CLAUDE.md`](../../CLAUDE.md) 拆出(2026-10-03,**原文逐字未改**)。返回索引:[`CLAUDE.md`](../../CLAUDE.md)。
> 本文件覆盖:编辑器工具。
> ★ 文档会过期 —— **任何冲突以源码为准**,读之前先 `grep` 复核。

### 编辑器工具

`level_editor/editor.html` + `level_editor/{core,tint,render,io,ui,worker}.js` 是独立浏览器地图编辑器(大图缩放/画笔/图层/辅码),与 Godot 引擎无关。**只通过 `level_editor/serve.bat` 以 HTTP 打开**(`file://` 刻意不支持),服务器是 `level_editor/editor_server.js`(node,只绑 `127.0.0.1:8777`)。旧的 `structure-editor.html` 已退休。

- **格式**:`.cyrm` **v4 二进制**(明文 20 字节头 + deflate + CRC32),四图层、每格 4×4 个 16px 子格、每子格带辅码。**导入**仍认三种输入(v4 二进制 / 带 `# cyrm-v3` 标记的 v3 文本 / 旧字母格式),**导出只有二进制一种**;v3 → v4 的迁移是一次性的,所以打开 v3 文本的图首次 `Ctrl+S` 会弹一次确认。
- ★★ **游戏侧今天还读不了 v4 —— 那个确认框点下去就是把一张好地图换成游戏打不开的一份。** `core/sim/map_format.gd` 只有"v3 文本 + 旧字母"两条解析分支。实测(把 `maps/demo.cyrm` 迁成 v4 再喂 `MapFormat`):`map_size` 得 `(3, 0)`、`load_map_file` 得 **0 行** —— 整张图变成空的。而**保存**的唯一出口是 `PUT /api/map`,写的正是**仓库里的 `maps/`**;编辑器**没有**浏览器下载/另存到别处的出口,而 `MazeGenerator._random_cyrm` 是**随机取 `maps/` 下任意 `*.cyrm`**,副本一样会进随机池。故迁移是**期 E** 与 `maps/*.cyrm` 一起做的事,在那之前**别在真图上点那个确认框**。
- **砖形面板已删除**(2026-09-19 裁定):在"子格独立纹理"的模型下,"形状"退化成"这一笔盖哪几个子格",由画笔大小表达(整数大小画整格、`.25/.5/.75` 画子格)。
- **纹理 22(水面)不在调色板里**:游戏侧它是按地形自动派生的,画了会与游戏不一致。
- **改编辑器**:`core.js`(格式)/ `tint.js`(辅码像素数学)是**冻结层**,`render.js` / `ui.js` / `io.js` + `worker.js` 是可改层。`core.js` 的注释里写着与游戏侧 `map_format.gd` 逐字对应的几处;两边改一处必须同步改另一处。
- **敌人表**:编辑器内嵌的敌人注册表由 `node level_editor/sync-enemies.js` 从 `data/enemies.json` 重新生成(`--check` 只校验);砖块属性表同理走 `sync-tiles.js`。
- **冒烟(全在 node 里跑,`cd level_editor`)**:`node smoke.js` / `tint_smoke.js` / `worker_io_smoke.js` / `render_smoke.js` / `editor_smoke.js` / `server_smoke.js`。★ **浏览器侧(node 到不了)靠页面上的「自检」按钮**:它打印一行 `SELFTEST OK` 或 `SELFTEST FAIL: n 条` —— 那是这一整块唯一能"在真浏览器里跑一遍"的判据。
- ★ **已知局限(未修)**:① **跨接缝的选框会选出一整行/一整列**(它是**画出来的**,不是静默);② **分数画笔会把选框每轴撑大至多 3 个子格(¾ 格)** —— 选框是**格对齐**的,而 `.25/.5/.75` 画的是子格;③ **选区拖动时的逐块去烤是同步的**,面积已 ≤3~4 块,极端情况下仍可能掉一帧;④ **崩溃栅栏比的是"任意地图最新的一份草稿"**,所以给**另一张图**写的草稿会抑制掉一次合法的恢复提示 —— 宁可少问一次,方向是安全的。

