# 构建与发布指南

发布压缩包名称为 **The-Cyancular-Ruins.zip**，内部目录为 **The-Cyancular-Ruins-YYYYMMDDHHMM/**（时间戳使用 UTC+8）。版本号读取自 `project.godot` 中的 `application/config/version`，供游戏界面与日志展示。

## 一、 一键构建

构建环境依赖 Godot 4.7.1 标准编辑器及同版本 Windows 导出模板、Python、SCons 4.9.1 和 MSVC 编译工具链（进程扩展也支持通过 `MINGW_PREFIX` 指定 LLVM MinGW）。

```powershell
$env:GODOT_EDITOR = "D:/Codes/ChatGPT/cyr/godot-build/editor/Godot_v4.7.1-stable_win64.exe"
python -m pip install scons==4.9.1
python tools/fetch_easytier.py --source D:/Codes/ChatGPT/cyr/easytier-windows-x86_64
python tools/build_release.py
```

`build_release.py` 支持 `--version` 与 `--stamp` 参数，默认读取工程版本并自动生成当前时间戳。构建步骤如下：

1. 编译 Windows Job 原生扩展。
2. 将版本号与时间戳写入 `core/config/build_info.gd`。
3. 导出 Windows Desktop 客户端与专用服务端（Dedicated Server）。
4. 将服务端 PE 子系统标记配置为控制台程序。
5. 在独立临时目录中进行冒烟验证：验证客户端启动、武器注册表完整性以及服务端 `--port 0` 的就绪状态（SERVER READY）。
6. 还原 `core/config/build_info.gd`，将构建目录归档并生成发布 ZIP 压缩包。

构建冒烟测试要求退出码为 0、输出预期成功标记，且控制台无脚本与解析报错。自定义游戏启动参数请统一置于 `--` 之后传递。

## 二、 发布产物结构

```text
The-Cyancular-Ruins.zip
└── The-Cyancular-Ruins-YYYYMMDDHHMM/
    ├── The Cyancular Ruins.exe
    ├── Cyancular Ruins Server.exe
    ├── process_group.windows.x86_64.dll
    ├── THIRD_PARTY_NOTICES.txt
    └── easytier/
        ├── easytier-core.exe
        ├── easytier-cli.exe
        ├── Packet.dll
        ├── wintun.dll
        ├── WinDivert64.sys
        └── relay.txt
```

归档脚本会在构建产物目录保存当前版本，并在 releases 归档目录保存带时间戳的副本及最新的 `The-Cyancular-Ruins.zip`。`tools/archive_build.py` 可单独执行，支持 `--stamp` 参数。

第三方组件的开源许可证与版权声明统一整合于发布包根目录下的 `THIRD_PARTY_NOTICES.txt`。

运行环境最低要求为 Windows 10 64位操作系统。分发时需提供完整的压缩包；解压后客户端、服务端与网络隧道均在同级目录下直接启动。原生扩展的编译说明见 [开发工具](docs/eng/tools.md)，网络会话与进程管理细节见 [联机系统](docs/eng/netplay.md)。

## 三、 macOS 通用包

在 macOS 上安装 Xcode 命令行工具、Python、SCons 4.9.1、Godot 4.7.1 标准编辑器及同版本导出模板：

```bash
export GODOT_EDITOR="/Applications/Godot.app/Contents/MacOS/Godot"
python -m pip install scons==4.9.1
python tools/build_macos.py
```

`tools/build_macos.py` 编译通用进程扩展，下载官方 EasyTier v2.7.0 的 arm64 与 x86_64 包并合并内核和 CLI，导出通用 `.app`，执行 ad-hoc 签名并用 `ditto` 保存权限和符号链接。产物为 `builds/macos/The-Cyancular-Ruins.zip`，内部目录沿用 UTC+8 时间戳，包含 `The Cyancular Ruins.app` 与统一许可 `THIRD_PARTY_NOTICES.txt`。

游戏、进程扩展和 EasyTier 都包含 arm64 与 x86_64，可分别在 M 系列和 Intel Mac 原生运行；最低系统版本设为 macOS 12。EasyTier 位于 `.app/Contents/Helpers/`，进程扩展位于 `.app/Contents/Frameworks/`。应用包可整体移动到 Applications。

客户端建房时启动同一应用包的可执行文件，使用无头服务端入口：

```bash
"The Cyancular Ruins.app/Contents/MacOS/The Cyancular Ruins" --headless -- --server --port 7777
```

macOS 日志位于 `~/Library/Application Support/Godot/app_userdata/The Cyancular Ruins/log/`，发布版 `relay.txt` 位于同一用户数据目录。开发态中继列表位于工程 `easytier/relay.txt`。

当前使用 ad-hoc 签名，未进行 Apple 公证。从网络下载后，首次运行按 macOS「系统设置 → 隐私与安全性 → 仍要打开」允许应用。

## 四、 GitHub Actions 持续集成

代码推送到 `siri_v*` 分支或在 GitHub Actions 页面手动触发 [Build game](.github/workflows/build.yml) 工作流即可自动执行打包。`Build Windows` 与 `Build macOS` 分别生成两个平台的发布包。Windows 使用 Godot 4.7.1、MSVC 与官方 EasyTier v2.7.0，完成资产导入与导出冒烟测试。

Windows 产物名为 `The-Cyancular-Ruins-Windows`，可在对应运行记录的 Artifacts 区域下载 `The-Cyancular-Ruins-Windows.zip`。

macOS 产物名为 `The-Cyancular-Ruins-macOS`，包含保留可执行权限的 `The-Cyancular-Ruins.zip`；下载后解开外层 artifact，再解开该 ZIP。CI 在 `macos-15` 构建一次通用包，然后在 `macos-15`（Apple Silicon）和 `macos-15-intel` 上测试同一产物：双架构及签名校验、武器注册表、无头服务端、进程生命周期、网络探针、导出服务端对局，以及官方 EasyTier UDP 直连与中继。测试失败日志显示在对应任务的控制台。

## 五、 自定义导出模板编译

`cyancular_build_profile.gdbuild` 定义了引擎功能裁剪配置。使用 Godot 4.7.1 源码与 SCons 编译自定义模板的命令示例：

```bat
python -m SCons platform=windows target=template_release production=yes optimize=size arch=x86_64 accesskit=no d3d12=no build_profile="D:/Codes/ChatGPT/cyr/the-cyancular-ruins/cyancular_build_profile.gdbuild" -j 8
```

将编译生成的 Windows release 模板安装至 `%APPDATA%/Godot/export_templates/4.7.1.stable/` 目录下（包含 `windows_release_x86_64.exe`、对应的 `console.exe` 以及记录版本号 `4.7.1.stable` 的 `version.txt`）。若项目后续新增了引擎核心类型，需同步更新裁剪配置文件并重新编译模板。
