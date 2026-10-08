# The Cyancular Ruins — 编译与发布手册

发布产物为**完整打包目录**：包含客户端、专用服务端可执行文件，以及 `easytier/` 核心组件（`easytier-core.exe`、`easytier-cli.exe`、`Packet.dll`、`wintun.dll`）与 `relay.txt`。
裁剪后的客户端体积约为 45 MB（未裁剪的官方通用模板约 109 MB）。

---

## 1. 日常发布流程

### 1.1 一键构建发布

```bash
GODOT_EDITOR="D:/Codes/Zcode/cyr/godot-build/editor/Godot_v4.7.1-stable_win64.exe" \
  python tools/build_release.py
```

- `GODOT_EDITOR`：指向 4.7.1 标准版编辑器路径（未设置时回退至脚本默认值）。
- 可选参数：`--version 1.2.0`（默认读取 `project.godot` 中的 `application/config/version`，仅支持数字与点分格式）、`--stamp YYYYMMDDHHMM`。

自动化构建脚本按顺序执行以下步骤，任何一步失败均立即中止：

1. **写入发布信息**：将版本号与时间戳写入 `core/config/build_info.gd`（供主菜单与服务端日志显示），导出完成后自动还原为开发占位符，保证 `git status` 干净。
2. **导出可执行文件**：分别导出客户端（`Windows Desktop` 预设）与专用服务端（`Dedicated Server` 预设）。
3. **转换服务端子系统**：运行 `tools/make_server_console.py` 将服务端 PE 头修改为控制台子系统，确保双击运行时显示控制台窗口。
4. **自动化冒烟验证**：
   - 验证客户端能否正常拉起并安全退出；
   - 启动服务端无头模式：`--headless --quit-after 120 -- --port 7999`，检查输出中是否包含“服务器就绪”（使用 7999 端口以避免与正在运行的 7777 端口冲突）；
   - 若根目录存在 `easytier/` 相关依赖，追加运行：`-- --port 7999 --tunnel --room 48213`，校验隧道初始化输出；
   - 检查标准错误与日志，若出现 `SCRIPT ERROR`、`Parse Error` 或 `Failed to load script` 则立即报错中止；
   - 注意：游戏自定义参数必须放在 `--` 之后，引擎仅解析 `--` 之前的参数。
5. **归档生成**：运行 `tools/archive_build.py` 清空 `builds/` 目录，生成唯一的归档包 `builds/The Cyancular Ruins <版本> <时间戳>/`，包含平铺的两个可执行文件、`easytier/` 运行依赖及 `relay.txt`。

### 1.2 手动导出（不运行一键脚本）

```bash
"<编辑器路径>" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
"<编辑器路径>" --headless --path . --export-release "Dedicated Server" "Cyancular Ruins Server.exe"
python tools/make_server_console.py "Cyancular Ruins Server.exe"   # 切换为控制台子系统
python tools/archive_build.py                                      # 打包归档至 builds/ 目录
```

`tools/archive_build.py` 支持 `--stamp` 与 `--version` 参数；每次归档默认只保留最新一份构建。

### 1.3 验证与分发

- **独立目录验证**：将 `builds/` 生成的整包复制到工程目录之外运行，避免因读取工程本地资源而掩盖打包遗漏问题。
- **全流程游玩验证**：验证移动、跳跃、射击、HUD 交互、角色倒地重置及地图生成等功能。
- **远程联机验证**：两台设备使用相同发布包，一方建房生成房间号，另一方输入房间号加入；日志分别输出至 `log/easytier-host-<pid>` 与 `log/easytier-guest-<pid>`（详见 [`docs/netplay.md`](docs/netplay.md)）。
- **完整分发**：分发时必须分发 `builds/` 目录下的完整文件夹；单独发送可执行文件会导致缺少 P2P 隧道组件。
- **异常排查**：若遇到启动异常或闪退，可通过命令行重定向日志排查：`"./The Cyancular Ruins.exe" > stdout.log 2> stderr.log`。

---

## 2. 自定义裁剪模板编译（环境迁移或升级引擎）

### 2.1 环境依赖

| 依赖项 | 说明 |
|---|---|
| Python 3.10+ | 配置独立虚拟环境：`python -m venv godot-build\venv` 后安装 SCons：`godot-build\venv\Scripts\python -m pip install scons` |
| MSVC（VS 2022） | 默认编译工具链，SCons 会自动识别，无需手动配置 vcvarsall |
| MinGW-w64 x86_64（备选） | 需加入 PATH 环境变量；需配合 `use_mingw=yes lto=none` 参数使用 |
| Git | 获取源码与版本控制 |

### 2.2 引擎源码与裁剪配置

- 引擎源码目录：`godot-build\godot-4.7.1-stable\`。
- 裁剪配置文件：位于工程根目录的 `cyancular_build_profile.gdbuild`，配置了 `disabled_build_options`（禁用 3D 模块等无用功能，保留 `module_webp`）及 `disabled_classes`（禁用未使用的类）。
- **类依赖维护规则**：若工程中新增了未引用的原生引擎类，需将其从 `disabled_classes` 中移除并重新编译模板（如历史上添加过的 `Label`、`PacketPeerUDP`、`TCPServer`）。修改配置文件需要全量重新编译；日常 GDScript 开发仅需重新导出。

### 2.3 编译命令（工作目录：`godot-build\godot-4.7.1-stable\`）

**默认 MSVC 工具链**（全量耗时约 5 分钟，生成模板体积约 40 MB）：

```bat
D:\Codes\Zcode\cyr\godot-build\venv\Scripts\python.exe -m SCons ^
    platform=windows target=template_release production=yes optimize=size arch=x86_64 ^
    accesskit=no d3d12=no ^
    build_profile="D:\Codes\Zcode\cyr\the-cyancular-ruins\cyancular_build_profile.gdbuild" -j 8
```

**备选 MinGW 工具链**（需明确指定 `use_mingw=yes lto=none`）：

```bat
D:\Codes\Zcode\cyr\godot-build\venv\Scripts\python.exe -m SCons ^
    platform=windows target=template_release production=yes optimize=size arch=x86_64 ^
    lto=none use_mingw=yes accesskit=no d3d12=no ^
    build_profile="D:\Codes\Zcode\cyr\the-cyancular-ruins\cyancular_build_profile.gdbuild" -j 8
```

编译产物位于：`bin\godot.windows.template_release.x86_64.exe` 及同名控制台版本 `.console.exe`。

### 2.4 模板安装

```bat
copy bin\godot.windows.template_release.x86_64.exe         "%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64.exe"
copy bin\godot.windows.template_release.x86_64.console.exe "%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64_console.exe"
```

目标目录中需放置 `version.txt` 文件（内容为 `4.7.1.stable`）。安装完成后执行导出流程以验证模板。

---

## 3. 常见构建与运行问题排查

| 异常现象 | 排查与修复方案 |
|---|---|
| 导出报错 `可执行文件"pck"区未找到` | 导出模板或可执行文件被 UPX 等压缩工具处理过；请重新安装原始模板，避免使用 UPX 压缩 |
| 启动闪退，日志报错 `.ctex` 或 `CompressedTexture2D` | 编译配置中误关闭了 `module_webp`；需在 profile 中重新启用并重新编译模板 |
| 运行时报错 `missing class X` 或 `Could not find type "X"` | 该原生类包含在 `disabled_classes` 中；需从裁剪配置中移除并重新编译模板 |
| SCons 配置阶段报错缺少 Direct3D 12 依赖 | 编译参数中追加 `d3d12=no`，或安装 D3D12 SDK |
| MinGW 链接报错 `collect2.exe: fatal error: CreateProcess` | 编译命令中追加 `lto=none` 禁用链接时优化 |
| 预期使用 MinGW 却调用了 MSVC | 编译命令中显式指定 `use_mingw=yes` |
| 生成的可执行文件体积变大至约 109 MB | `%APPDATA%` 中的自定义模板被官方全功能模板覆盖；重新复制自定义裁剪模板（参考 2.4 节） |
| 服务端启动监听在默认 7777 端口 | 自定义命令行参数未置于 `--` 之后，导致被引擎层忽略 |
| easytier-core 双击无输出直接退出 | `easytier/` 目录下缺少 `Packet.dll` 或 `wintun.dll` 依赖，请补全相关动态库 |
| 复制到其他目录后资源或地图文件缺失 | 导出预设的 `include_filter` 中补充文件匹配规则（如 `maps/*.cyrm`） |
| 窗口图标未生效 | 导出预设中勾选 `application/modify_resources` 选项 |
| Mono 版本导出的可执行文件无法启动 | 必须使用标准版编辑器导出，项目不依赖 C#/Mono |

---

## 4. 引擎大版本升级指南

1. 将新版本源码解压至 `godot-build\` 对应子目录；将同版本的标准编辑器解压至 `godot-build\editor\`。
2. 检查并更新 `cyancular_build_profile.gdbuild`（部分原生类名或编译选项可能在引擎新版中调整）。
3. 按照 2.3 与 2.4 节步骤重新编译并安装导出模板，随后执行构建验证。
4. 运行新版 `easytier-core.exe --help` 核对 `core/config/tunnel_meta.gd` 中的隧道参数列表。

---

## 附录：常用路径速查

| 资源类别 | 对应路径 |
|---|---|
| 项目工程根目录 | `D:\Codes\Zcode\cyr\the-cyancular-ruins` |
| 标准版编辑器 | `D:\Codes\Zcode\cyr\godot-build\editor\Godot_v4.7.1-stable_win64.exe` |
| 导出模板存储目录 | `%APPDATA%\Godot\export_templates\4.7.1.stable\` |
| Godot 引擎源码目录 | `D:\Codes\Zcode\cyr\godot-build\godot-4.7.1-stable\` |
| SCons 虚拟环境 | `D:\Codes\Zcode\cyr\godot-build\venv\` |
| 裁剪配置文件 | `cyancular_build_profile.gdbuild` |
| 模板编译生成目录 | `godot-build\godot-4.7.1-stable\bin\` |
| 导出产物文件名 | `The Cyancular Ruins.exe` / `Cyancular Ruins Server.exe` |
| 归档打包目录 | `builds/The Cyancular Ruins <版本> <时间戳>/` |
| 联机技术文档 | [`docs/netplay.md`](docs/netplay.md) |
