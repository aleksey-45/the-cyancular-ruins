# Windows 构建与发布

使用 Godot 4.7.1 标准编辑器、同版本 Windows 导出模板、Python、SCons 4.9.1 和 MSVC。进程扩展也支持 MINGW_PREFIX 指定 LLVM MinGW。

~~~powershell
python -m pip install scons==4.9.1
python tools/fetch_easytier.py --source D:/Codes/ChatGPT/cyr/easytier-windows-x86_64
python tools/build_release.py
~~~

build_release.py 支持 --version 和 --stamp，默认读取工程版本并生成时间戳。构建顺序为原生扩展编译、写入发布信息、导出客户端与服务端、设置服务端控制台子系统、独立目录冒烟、还原发布信息和归档。

冒烟要求退出码零、成功标记，以及无 SCRIPT ERROR、Parse Error 或 Failed to load script。服务端验证使用 --port 0；游戏参数放在 -- 之后。

builds/ 保存当前发布目录，releases/ 保存目录副本。运行文件包括客户端、服务端、同目录 process_group.windows.x86_64.dll、THIRD_PARTY_NOTICES.txt 和 easytier/ 联机组件。

Windows 运行环境为 Windows 10 及以上 x64；分发完整目录。扩展构建见 [开发工具](docs/eng/tools.md)，联机会话见 [联机系统](docs/eng/netplay.md)。



## 导出模板

cyancular_build_profile.gdbuild 定义引擎裁剪配置。使用 Godot 4.7.1 源码和 SCons 编译模板：

~~~bat
python -m SCons platform=windows target=template_release production=yes optimize=size arch=x86_64 accesskit=no d3d12=no build_profile="D:/Codes/ChatGPT/cyr/the-cyancular-ruins/cyancular_build_profile.gdbuild" -j 8
~~~

将生成的 windows release 模板安装到 %APPDATA%/Godot/export_templates/4.7.1.stable/，包含 windows_release_x86_64.exe、对应 console.exe 和内容为 4.7.1.stable 的 version.txt。新增引擎类时同步更新裁剪配置并重新编译模板。

第三方组件许可证和版权声明统一放在发布目录根部的 THIRD_PARTY_NOTICES.txt。easytier/ 包含内核、CLI、Packet.dll、wintun.dll、WinDivert64.sys 和 relay.txt。
