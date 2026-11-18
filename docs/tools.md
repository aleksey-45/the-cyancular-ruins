# 运行与工具

## 从源码运行

项目使用 Godot 4.7.1 标准版、Python 3.12 和 Git。Windows 使用 x64 MSVC 开发者终端，macOS 使用 Xcode 命令行工具。进程管理和 GNS 扩展共用一个 CMake 工程。

```sh
python -m pip install cmake==3.31.6 ninja==1.11.1.4
python tools/build_native.py
godot --headless --editor --path . --import
godot --path .
```

`godot` 可以替换为可执行文件的完整路径。编辑器中打开 [project.godot](../project.godot) 后，F5 同样从主菜单运行。专用服务端默认监听 UDP 7777，启动成功时输出 `SERVER READY`。

```sh
godot --headless --path . res://server/server_main.tscn -- --port 7777
```

Windows 的 `start_server.bat` 从 `PATH` 调用 `godot`，也可以用 `GODOT` 指定控制台程序。发布包使用游戏可执行文件启动同一个服务端。EasyTier 组件和导出模板见 [构建与发布](../RELEASE.md)。

## 关卡编辑器

源码版通过 Node.js 在本机提供页面与 `maps/` 地图库，默认地址是 `http://127.0.0.1:8777/`。Windows 的 `level_editor/serve.bat` 启动同一服务并打开浏览器。

```sh
node level_editor/editor_server.js --no-open
node level_editor/build_dist.js
```

`--no-open` 关闭启动时打开浏览器的行为，`--port` 和 `--maps` 分别指定监听端口和地图库目录。离线构建产出 `level_editor/dist/cyrm-editor.html`，图集和 Worker 随页面内嵌，可直接打开。

两个版本均支持导入文件与下载导出。支持目录访问 API 的浏览器也可以选择本地可写目录，编辑器在该目录保存、重命名和删除地图。旧版 v3 文本与字符地图可导入，保存使用 v4。覆盖库内旧格式文件时保留原文备份。游戏读取的格式见 [世界与地图](world.md)。

画布提供前景、场景、后景和背景四层，支持 16 像素子格绘图、辅码染色、选区编辑和撤销重做。出生点按 64 像素格编辑，团队复活点分侧放置。缩小时会报告并移除超出画布的点。地图校验显示格式、材质与点位问题，自检执行一次 Worker 编解码往返。

浏览器草稿按文档键自动保存。页面异常时记录对应草稿键，启动恢复读取该文档。视图、画笔与图层设置保存在浏览器本地。地图编解码在 Worker 内执行，画布重建按帧分批处理。

```sh
node level_editor/sync-tiles.js
node level_editor/sync-enemies.js
```

两条命令分别由 [瓦片定义](../data/tile_defs.json) 和 [敌人列表](../data/enemies.json) 生成编辑器数据。加 `--check` 时只比较数据。离线构建的 `--check` 比较默认输出文件与当前源码。运行检查见 [行为检查](tests.md)。
