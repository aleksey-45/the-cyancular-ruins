# 运行与工具

## 从源码运行

项目使用 Godot 4.7.1 标准版。原生扩展用 Python 3.12、Git、CMake 和 Ninja 构建，Windows 使用 x64 MSVC 开发者终端，macOS 使用 Xcode 命令行工具。消息传输与进程管理共用一个 [CMake 工程](../native/CMakeLists.txt)。

```sh
python -m pip install cmake==3.31.6 ninja==1.11.1.4
python tools/build_native.py
godot --headless --editor --path . --import
godot --path .
```

这些命令分别安装构建工具、编译原生扩展、导入 Godot 资源并启动主菜单。`godot` 可用可执行文件的完整路径替代。从 Godot 编辑器打开 [项目](../project.godot) 后，F5 运行同一个主场景。

专用服务器默认监听 UDP 7777。启动完成时输出 `SERVER READY`，`--port` 指定监听端口。

```sh
godot --headless --path . res://server/server_main.tscn -- --port 7777
```

发布包中的服务器入口见 [构建与发布](../RELEASE.md#发布包中的专用服务器)。

## 自动加载节点

Godot 根据 [project.godot](../project.godot) 的 `[autoload]` 配置，在加载主场景前添加以下节点。

| 节点 | 职责 |
|---|---|
| [GameParameters](../core/config/game_parameters.gd) | 提供瓦片尺寸等地图格式结构常量；重力与水体参数见 [WorldConfig](../core/config/world_config.gd) / [world_config.tres](../core/config/world_config.tres) |
| [PerfMonitor](../core/config/perf_monitor.gd) | 根据命令行选项启用性能采样、发布统计和写入报告 |
| [NetBus](../core/net/net_bus.gd) | 通过 GameNetworkingSockets 收发消息，分发输入、状态和事件 |
| [NetSession](../core/net/net_session.gd) | 管理联机连接、断线重连和游戏启动的后台进程 |
| [Settings](../core/config/settings.gd) | 读写并应用显示、音量与按键设置 |

## 关卡编辑器

源码版通过 Node.js 在 `http://127.0.0.1:8777/` 提供编辑页面和 `maps/` 地图库。[Windows 启动脚本](../level_editor/serve.bat) 启动同一服务并打开浏览器。`--no-open` 关闭自动打开浏览器，`--port` 和 `--maps` 可指定端口和地图库目录。

```sh
node level_editor/editor_server.js --no-open
node level_editor/build_dist.js
```

本地服务和离线版都使用游戏的瓦片图集。离线构建把图集、脚本和 Worker 内嵌到 `level_editor/dist/cyrm-editor.html`，浏览器可直接打开此文件。两种版本都支持导入和下载地图。浏览器支持目录访问时，编辑器也能在选中的本地目录保存、重命名和删除地图。[瓦片图集](../assets/textures/structure.png)

编辑器可导入 CYRM v4、v3 文本和字符地图，保存统一写出 v4。覆盖地图库中的非 v4 文件时保留原文件的备份。游戏读取的地图数据见 [世界与地图](world.md#cyrm-地图)。

## 编辑与保存

画布包含前景、场景、后景和背景四层。前三层使用纹理和色相、亮度、饱和度、透明度参数，背景层直接保存 RGBA 颜色。绘制以 16 像素子格为单位，支持选区、填充、撤销和重做。单人玩家、敌人和联机出生点均以 64 像素瓦片为单位。缩小地图时会移除越界点并报告变更。

地图编解码由 Worker 执行，画布重建分帧绘制。自检对当前地图执行一次编码和解码。草稿按文档键保存在 IndexedDB，异常退出时可从关联的草稿恢复。界面布局、画笔和图层偏好存放在 `localStorage`。

```sh
node level_editor/sync-tiles.js
node level_editor/sync-enemies.js
```

这两个脚本分别从 [材质表](../data/tile_defs.json) 和 [敌人类型表](../data/enemies.json) 生成编辑器数据。两者的 `--check` 只比较生成结果。`node level_editor/build_dist.js --check` 比较默认离线文件与当前源码。[自动化测试](tests.md)
