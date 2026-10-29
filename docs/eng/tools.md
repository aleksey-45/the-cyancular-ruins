# 开发工具与关卡编辑器

本文档介绍 Web 关卡编辑器、前后端数据同步脚本以及打包构建工具。

---

## 一、 关卡编辑器架构 (`level_editor/`)

关卡编辑器采用独立 Web 前端实现，支持大尺寸地图视口平移缩放、16px 子格画笔、多图层编辑与辅码染色。

### 1. 运行与服务启动
- **启动脚本**：运行 `level_editor/serve.bat`。
- **源码版服务**：通过 `level_editor/editor_server.js`（Node.js）启动轻量本地 HTTP 服务（监听 `127.0.0.1:8777`）。源码入口 `editor.html` 需通过 HTTP 打开。
- **离线单文件版**：运行 `node level_editor/build_dist.js`，生成 `level_editor/dist/cyrm-editor.html`，可直接打开。图集、脚本和真实 Worker 的源码均内嵌，不依赖本地服务器；编解码仍在独立线程执行。
- **离线文件读写**：支持 File System Access 的浏览器可选择地图目录后直接保存；其他环境通过「打开文件」和浏览器下载读写。未选择目录时必须完成浏览器下载才能把导出的文件保存到磁盘。选择目录的权限由浏览器管理。
- **前端模块划分**：
  - `editor.html`：编辑器主页面。
  - `core.js`：核心数据结构与 `.cyrm` 格式编解码逻辑。
  - `tint.js`：子格染色与调色板计算。
  - `render.js` / `ui.js` / `io.js`：画布视口渲染、工具栏交互及文件读写。
  - `worker.js`：负责地图编解码与压缩的 Web Worker 线程；画布渲染仍由 `render.js` 分帧执行。
  - `standalone_files.js`：离线文件适配器；源码版继续使用既有 HTTP 文件接口，不覆盖浏览器的 fetch/Worker。

### 2. `.cyrm` 地图格式规范
- **v4 二进制格式**：
  - 包含 20 字节二进制文件头、Deflate 数据压缩与 CRC32 完整性校验。
  - 逻辑层维持 64px 大网格，视觉与碰撞层细化为 16px 子格（每大格对应 4×4 个子格），每个子格支持独立染色。
- **统一格式**：游戏和 Web 编辑器只读取 v4。

---

## 二、 数据同步工具

为了确保 Web 编辑器与 Godot 引擎的数据定义保持一致，通过 Node.js 脚本维护单向同步机制：

1. **敌人配置同步**：
   - 数据源：`data/enemies.json`。
   - 同步脚本：`node level_editor/sync-enemies.js`。
   - 校验模式：执行 `node level_editor/sync-enemies.js --check` 仅检查数据一致性而不覆盖写盘。
2. **场景瓦片配置同步**：
   - 数据源：`data/tile_defs.json`。
   - 同步脚本：`node level_editor/sync-tiles.js`，将瓦片图集与物理属性映射同步至前端。

---

## 三、 开发检查

地图契约变更运行 `node tests/editor_case.js`，界面修改验证对应实际操作。`python tools/check_naming.py` 检查目录、类名、场景名、文档链接和脚本编码。

---

## 四、 构建与发布工具

- **发布导出脚本 (`tools/build_release.py`)**：
  - 读取 `project.godot` 中的版本号，写入 `core/config/build_info.gd`。
  - 各构建一次 Windows Job、GNS 与场景模拟原生扩展，导入资源后调用 Godot 导出统一游戏程序；CI 统一调用构建入口。
  - 导出打包结束后还原构建占位符；CI 随后单独运行一次关键行为检查。
- **命名规范检查 (`tools/check_naming.py`)**：
  - 检查工程目录小写规范、`class_name` 与文件名对齐、文档引用的文件路径有效性以及 `.tscn` 命名规范。
- **网络隧道组件获取 (`tools/fetch_easytier.py`)**：
  - 默认从官方最新 nightly 的发布元数据选择 Windows 或 macOS 资产，日志记录提交与下载地址，不固定版本或比对校验和。Windows 支持显式 `--source` 从本地官方包复制组件。若缺失 `relay.txt` 则自动生成公共中继节点列表。
- **原生作业对象扩展构建 (`tools/build_process_group.py`)**：
  - 基于 godot-cpp（分支 `godot-4.5-stable`，commit `e83fd09`），通过 SCons 4.9.1 编译 Windows x64 DLL。默认使用 MSVC，亦支持 `--mingw` 参数或 `MINGW_PREFIX` 环境变量指定 LLVM MinGW 工具链。产物位于 `native/process_group/bin/`。
  - macOS 使用 `--platform macos`，以 Xcode Clang 编译 arm64 + x86_64 通用动态库，部署目标为 macOS 12。
- **macOS 发布 (`tools/build_macos.py`)**：
  - 编译通用进程、GNS 与场景模拟扩展，合并官方 EasyTier 两种架构，导出、签名并归档 `.app`。`tools/fetch_easytier.py --platform macos` 可单独安装通用 EasyTier。产物和双架构 CI 验证见[发布手册](../../RELEASE.md)。
- **GNS 扩展构建 (`tools/build_gns.py`)**：
  - 使用 CMake 3.31.6 与 Ninja 1.11.1.4，固定 GNS v1.6.1、Protobuf v21.12 与 godot-cpp 4.5 的源码提交。依赖缓存位于 `.test_logs/native/`，运行库静态链接进扩展。
  - Windows 使用 MSVC 或 `MINGW_PREFIX` 指定的 LLVM MinGW，密码库采用系统 BCrypt。macOS 使用 `--platform macos`，静态链接 OpenSSL 3.5.9，分别编译 arm64 与 x86_64 后合成通用动态库。产物位于 `native/gns/bin/`。
- **发布包归档 (`tools/archive_build.py`)**：
  - 打包生成 `The-Cyancular-Ruins.zip`，内部根目录格式为 `The-Cyancular-Ruins-YYYYMMDDHHMM/`（时间戳使用 UTC+8）。包含统一游戏 EXE、同级进程、GNS 与场景模拟扩展 DLL 及开源声明 `THIRD_PARTY_NOTICES.txt`。
- **场景模拟扩展构建 (`tools/build_simulation.py`)**：
  - 使用同一份固定 godot-cpp SDK，以 CMake/Ninja 编译 Release C++17 原生类；Windows 支持 MSVC 或 LLVM MinGW，macOS 合并 arm64 与 x86_64。产物位于 `native/simulation/bin/`。
  - 热点循环直接读取原生成员并调用 Godot 物理 API；GDScript 在边界传递配置、输入与结果。职责与调用边界见[原生模拟](native_scene_simulation.md)。
