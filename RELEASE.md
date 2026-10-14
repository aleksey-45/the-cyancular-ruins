# Windows 构建与发布指南

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

## 三、 GitHub Actions 持续集成

代码推送到 `siri_v*` 分支或在 GitHub Actions 页面手动触发 `Build Windows game` 工作流即可自动执行打包。CI 环境基于 Godot 4.7.1、MSVC 与官方 EasyTier v2.7.0，自动完成资产导入与完整导出测试。

工作流生成的产物命名为 `The-Cyancular-Ruins`，可在对应运行记录的 Artifacts 区域下载 `The-Cyancular-Ruins.zip`。

## 四、 自定义导出模板编译

`cyancular_build_profile.gdbuild` 定义了引擎功能裁剪配置。使用 Godot 4.7.1 源码与 SCons 编译自定义模板的命令示例：

```bat
python -m SCons platform=windows target=template_release production=yes optimize=size arch=x86_64 accesskit=no d3d12=no build_profile="D:/Codes/ChatGPT/cyr/the-cyancular-ruins/cyancular_build_profile.gdbuild" -j 8
```

将编译生成的 Windows release 模板安装至 `%APPDATA%/Godot/export_templates/4.7.1.stable/` 目录下（包含 `windows_release_x86_64.exe`、对应的 `console.exe` 以及记录版本号 `4.7.1.stable` 的 `version.txt`）。若项目后续新增了引擎核心类型，需同步更新裁剪配置文件并重新编译模板。
