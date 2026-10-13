# 开发工具与关卡编辑器

本文档说明 Web 关卡编辑器、前后端数据同步脚本以及打包构建工具。

---

## 一、 关卡编辑器架构 (`level_editor/`)

关卡编辑器采用独立 Web 前端实现，支持大尺寸地图视口平移缩放、16px 子格画笔、多图层编辑与染色。

### 1. 运行与服务启动
- **启动脚本**：运行 `level_editor/serve.bat`。
- **后台服务**：通过 `level_editor/editor_server.js`（Node.js）启动轻量本地 HTTP 服务（监听 `127.0.0.1:8777`）。出于浏览器安全策略限制，不支持直接通过 `file://` 协议打开。
- **前端模块划分**：
  - `editor.html`：编辑器主页面。
  - `core.js`：核心数据结构与 `.cyrm` 格式编解码逻辑。
  - `tint.js`：子格染色与调色板计算。
  - `render.js` / `ui.js` / `io.js`：画布视口渲染、工具栏交互及文件读写。
  - `worker.js`：负责大地图渲染与数据导出的 Web Worker 线程。

### 2. `.cyrm` 地图格式规范
- **v4 二进制格式**：
  - 包含 20 字节二进制文件头、Deflate 压缩与 CRC32 完整性校验。
  - 逻辑层维持 64px 大网格，视觉与碰撞层细化为 16px 子格（每大格对应 4×4 个子格），每个子格支持独立染色。
- **v3 文本格式**：每格 4 字符标记（纹理 ID + 形状掩码），首行包含 `# cyrm-v3` 声明。
- **引擎端兼容**：游戏引擎层（`core/sim/map_format.gd` 与 `core/sim/map_format_v4.gd`）全面支持 v4 二进制与 v3 文本解析。

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

## 三、 编辑器测试套件

在 `level_editor/` 目录下提供针对前端与服务端逻辑的自动化测试：

```bash
cd level_editor
node smoke.js             # 核心格式编解码测试
node tint_smoke.js        # 辅码染色与调色板单元测试
node worker_io_smoke.js   # Web Worker 线程测试
node render_smoke.js      # 画布渲染管线测试
node server_smoke.js      # 本地 HTTP 服务端接口测试
```

- **前端界面自检**：在编辑器页面顶部点击「自检」按钮，会在浏览器控制台执行组件断言并输出 `SELFTEST OK`。

---

## 四、 构建与发布脚本

- **发布导出脚本 (`tools/build_release.py`)**：
  - 读取 `project.godot` 中的版本号，写入 `core/config/build_info.gd`。
  - 构建 Windows Job 原生扩展，调用 Godot 执行 release 导出。
  - 自动执行产物冒烟测试，测试通过后将构建占位符还原。
- **命名规范检查 (`tools/check_naming.py`)**：
  - 检查工程目录小写规范、`class_name` 与文件名对齐、文档引用的文件路径有效性以及 `.tscn` 命名规范。

- **官方隧道安装** ([fetch_easytier.py](../../tools/fetch_easytier.py))：从本地官方 Windows 2.7.0 包复制全部运行组件和许可，缺少 relay.txt 时生成默认公共节点列表，保留已有自定义列表。
- **进程扩展构建** ([build_process_group.py](../../tools/build_process_group.py))：使用 godot-cpp 的 godot-4.5-stable，固定提交 e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77，通过 SCons 4.9.1 编译 Windows x64 DLL。默认使用 MSVC，也支持 --mingw 或 MINGW_PREFIX 指定 LLVM MinGW。SDK 与中间文件位于 .test_logs/native/，运行 DLL 位于 native/process_group/bin/；CI 重新编译，许可随发布包分发。
- **发布归档** ([archive_build.py](../../tools/archive_build.py))：生成 The-Cyancular-Ruins.zip，内部目录为 The-Cyancular-Ruins-YYYYMMDDHHMM/，时间戳为 UTC+8。包含客户端、服务端、同目录 Job DLL、统一许可 THIRD_PARTY_NOTICES.txt；easytier/ 包含内核、CLI、Packet.dll、wintun.dll、WinDivert64.sys 和 relay.txt。builds/ 保存当前目录，releases/ 保存目录副本与最新 ZIP。
- **回归入口** ([run_regression.py](../../tools/run_regression.py))：分类运行逻辑、视觉和网络测试；每项使用独立用户目录，保存日志并检查退出码、成功标记和脚本错误。
- **GitHub Actions 自动打包**：推送到 siri_v* 或手动运行 Build Windows game，使用 Godot 4.7.1、MSVC 与官方 EasyTier v2.7.0。上传 builds/ 下的时间戳目录，artifact 名为 The-Cyancular-Ruins；下载为 The-Cyancular-Ruins.zip，包含该目录。入口在运行记录的 Artifacts 区域。
