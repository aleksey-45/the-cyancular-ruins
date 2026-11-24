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

## 数值资源

世界重力与水体参数由使用方预加载 [WorldConfig 资源](../core/config/world_config.tres)。玩家、敌人和时间参数分别保存在 `core/config/` 下的自定义资源中。

## 自动加载节点

Godot 根据 [project.godot](../project.godot) 的 `[autoload]` 配置，在加载主场景前添加以下节点。

| 节点 | 职责 |
|---|---|
| [PerfMonitor](../core/config/perf_monitor.gd) | 根据命令行选项启用性能采样、发布统计和写入报告 |
| [NetBus](../core/net/net_bus.gd) | 通过 GameNetworkingSockets 收发消息，分发输入、状态和事件 |
| [NetSession](../core/net/net_session.gd) | 管理联机连接、断线重连和游戏启动的后台进程 |
| [Settings](../core/config/settings.gd) | 读写并应用显示、音量与按键设置 |

## 关卡编辑器

勾选顶栏「光照预览」可从正午开始，以 15 分钟为单位查看全天光照。F5 试玩沿用当前预览时刻，Esc 返回后可继续比较同一处地形。关闭预览恢复原色绘制。时刻只影响显示。

从桌面主菜单进入「地图编辑器」。在「文件 → 打开地图」或按 Ctrl/Cmd+O，系统文件选择窗口会打开默认地图目录 `user://maps`。选择 `.cyrm` 文件即可编辑，也可浏览其他目录。「另存为」同样使用系统窗口。单人选图和房主选图都会列出存入默认目录的地图。发行包的 `maps/` 目录中有 `demo.cyrm` 和 `newfactory.cyrm` 两张示例。文件名旁的标志表示有未保存的修改。编辑器每 10 秒把新修改写入 `user://map-editor.draft`，下次进入时恢复这份草稿。[地图编辑器](../scenes/map_editor.tscn)

从左侧材质盘点选图块即可作画，右栏显示当前工具的参数。图层逐行切换可见和锁定。「视图」菜单提供网格、环面预览、分区标线和其他层压暗。「编辑」菜单可调整地图尺寸或打开注记。画布用滚轮以光标为中心缩放，中键或空格加左键平移。前三层使用材质和色调。背景 1 至 4 可分别绘制 RGBA 颜色，编辑时对齐网格，按 F5 试玩可看到由近到远依次为 80%、60%、40%、20% 的滚动速度。画笔与点位都以 16 像素子格定位。拖动画笔后松手提交一笔，Esc 取消正在进行的操作。选框内拖动可移动内容，按住 Shift 重画选框。渐变在选区内绘制。快捷键 Ctrl/Cmd+Z 撤销、Ctrl/Cmd+Shift+Z 重做。

使用画笔或「点位」工具时，按住点位即可拖动，松手提交，Esc 取消。选中点位后也可点「移至…」，平移或缩放画布，再单击目标子格。在右栏「点位类型」中选择出生点、复活点或敌人。未选中已有点位时，选择类型会自动进入放置模式。勾选「放置点位（连续）」后可在画布上连续放置，取消勾选后可选中或拖动已有点位。画笔按住 Alt 可在点位下方落笔。重叠点可从右侧点位表选取。选中敌人或复活点后，在下拉框改类型或队伍即生效，撤销可还原。双击列表将画布定位到该点。F5 从所选点位启动当前未保存地图上的真实单人关卡，未选点时使用普通单人出生规则。按 Esc 返回编辑现场。正式写入地图使用「保存」或「另存为」。[静态地图操作](../core/sim/cyrm_map.gd) · [CYRM 地图格式](world.md) · [自动化测试](tests.md)
