# Windows 构建与发布

发布压缩包名称为 **The-Cyancular-Ruins.zip**，内部目录为 **The-Cyancular-Ruins-YYYYMMDDHHMM/**，时间戳使用 UTC+8。版本号从 project.godot 的 application/config/version 读取，供游戏界面和日志显示。

## 一键构建

依赖 Godot 4.7.1 标准编辑器及同版本 Windows 导出模板、Python、SCons 4.9.1 和 MSVC。进程扩展也支持通过 MINGW_PREFIX 指定 LLVM MinGW。

~~~powershell
$env:GODOT_EDITOR = "D:/Codes/ChatGPT/cyr/godot-build/editor/Godot_v4.7.1-stable_win64.exe"
python -m pip install scons==4.9.1
python tools/fetch_easytier.py --source D:/Codes/ChatGPT/cyr/easytier-windows-x86_64
python tools/build_release.py
~~~

build_release.py 支持 --version 和 --stamp，默认读取工程版本并生成时间戳。构建过程：

1. 编译 Windows Job 原生扩展。
2. 将版本与时间戳写入 build_info.gd。
3. 导出 Windows Desktop 客户端与 Dedicated Server。
4. 将服务端 PE 子系统设为控制台。
5. 在独立临时目录验证客户端启动、全部武器注册表和服务端 --port 0 的 SERVER READY。
6. 还原 build_info.gd，归档至 builds/，保存 releases/ 副本并生成 ZIP。

冒烟要求退出码零、预期成功标记，以及无 SCRIPT ERROR、Parse Error 或 Failed to load script。自定义游戏参数放在 -- 之后。

## 产物结构

~~~text
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
~~~

builds/ 保存当前构建目录，releases/ 保存带时间戳的目录副本和最新的 The-Cyancular-Ruins.zip。archive_build.py 可单独执行，支持 --stamp。

第三方组件的许可证和版权声明统一放在发布目录根部的 THIRD_PARTY_NOTICES.txt。

Windows 运行环境为 Windows 10 及以上 x64。分发完整压缩包；解压后从同一目录启动客户端、服务端和隧道。原生扩展编译和许可见 [开发工具](docs/eng/tools.md)，联机会话与日志行为见 [联机系统](docs/eng/netplay.md)。

## GitHub Actions

推送到 siri_v* 分支或手动运行 Build Windows game 触发构建。工作流使用 Godot 4.7.1、MSVC 和官方 EasyTier v2.7.0，执行资源导入及完整发布流程。

upload-artifact 的名称为 The-Cyancular-Ruins，上传根目录为 builds/。Actions 下载得到 The-Cyancular-Ruins.zip，里面保留带时间戳的游戏目录。在运行记录底部的 Artifacts 区域下载。

## 导出模板

cyancular_build_profile.gdbuild 定义引擎裁剪配置。使用 Godot 4.7.1 源码和 SCons 编译模板：

~~~bat
python -m SCons platform=windows target=template_release production=yes optimize=size arch=x86_64 accesskit=no d3d12=no build_profile="D:/Codes/ChatGPT/cyr/the-cyancular-ruins/cyancular_build_profile.gdbuild" -j 8
~~~

将生成的 windows release 模板安装到 %APPDATA%/Godot/export_templates/4.7.1.stable/，包含 windows_release_x86_64.exe、对应 console.exe 和内容为 4.7.1.stable 的 version.txt。新增引擎类时同步更新裁剪配置并重新编译模板。
