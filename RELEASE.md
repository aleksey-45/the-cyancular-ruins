# The Cyancular Ruins — 编译与发布手册

本文档是 **单文件 exe demo** 的发布流程,以及自定义裁剪模板的编译方法。

> 目标:发布一个"仅单 exe"的 demo,体积约 **45 MB**(未裁剪的官方模板约 109 MB)。

## 0. 关键结论(先记住这三条)

1. **必须用 4.7.1 标准(非 mono)编辑器导出** —— mono 模板导出的 exe 直接 100MB+。
2. **永远不要对模板或成品 exe 用 UPX** —— Godot 4.7 把 PCK 内嵌在 exe 的一个 PE 节(`pck`)里,UPX 会弄丢这个节:导出报 `可执行文件"pck"区未找到`,或运行时空窗 / 闪退。
3. **裁剪 profile 里 webp 模块必须保留** —— Godot 4.7 导入无损贴图默认存成 WebP,运行时靠 `module_webp` 解码;关掉它所有贴图加载失败、游戏闪退。

## 1. 日常发布流程

### 1.1 开发与自测
- 用 **4.7.1 标准编辑器** 打开项目开发:`D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe`
- 改完先在编辑器里 playtest 确认没问题。

### 1.2 重新导出(二选一)

**图形界面**:项目 → 导出 → 选预设(`Windows Desktop` / `Dedicated Server` / `macOS` / `macOS Server`)→ 导出项目
**命令行**(推荐,一条命令):`python tools/build_release.py` —— 写版本信息 → Windows 客户端/服务端 → 打回控制台 → 冒烟 → macOS 客户端/服务端 → 归档,一键全做。

> **macOS 产物**:`The Cyancular Ruins (macOS).zip` / `Cyancular Ruins Server (macOS).zip`（zip 内含标准 `.app`；universal 架构，Intel + Apple Silicon 通吃；**未签名、未公证**）。mac 上是"解压 → 右键打开（或 `xattr -cr`）→ 双击"；服务端从终端跑：
> ```bash
> unzip "Cyancular Ruins Server (macOS).zip" && cd "Cyancular Ruins Server.app/Contents/MacOS"
> ./"Cyancular Ruins Server" --headless      # UDP 7777 + 7800–8299
> ```
> ⚠️ Windows 主机**不能执行** mac 二进制 ⇒ `build_release.py` 对两个 mac zip 只做「结构 + 体积」校验，**没有运行冒烟**；"能跑"只能在 mac 上由人确认。

> **版本号从哪来**:唯一来源是 `project.godot` 的 `application/config/version`,**只能写数字+点**。发布标识 = **`RoF_v<版本>_<YYYYMMDDHHMM>`**,由 [`tools/build_release.py`](tools/build_release.py) + [`tools/archive_build.py`](tools/archive_build.py) 拼:前缀取自 `project.godot` 的 `application/config/release_prefix`,拼法收在 `archive_build.py` 的 `release_version()` / `release_label()`。主菜单 / 信息页版本行、服务端启动自报、归档目录名与文件名都用它;`v` 前缀由脚本在展示与文件名上加。★ **别在任何文档里另抄一份版本号。**
> 导出前脚本把 `RoF_v<版本>` + 构建时间戳(`YYYYMMDDHHMM`)写进 [`core/config/build_info.gd`](core/config/build_info.gd),导出后**自动还原**成 dev 占位(工作区不脏);主菜单那行版本号读的就是它,服务端启动自报 `[server] 版本 … pid=…`。

> **导出后自动冒烟**:脚本各跑一次两个 **Windows** 产物(客户端直接起;服务端走 `-- --worker --port 7999`,不碰 7777),出现 `SCRIPT ERROR` / `Parse Error` / `Failed to load script` 即中止发布。服务端还要**断言输出里有「worker 就绪」**(只"没报错"会漏掉"零错误地跑错分支")。★ `--worker` 这类开关**必须写在 `--` 之后**(`server_main.gd` 读 `OS.get_cmdline_user_args()`),写在前面会被 Godot 丢掉、静默起成大厅并在 7777 上 bind。mac 两个 zip 只做结构与体积校验（见上），**不执行**。

> 手动重导出按序做:① 导 Windows 客户端 → ② 导 Windows 服务端 → ③ 服务端打回 CONSOLE → ④ 导 macOS 客户端 → ⑤ 导 macOS Server → ⑥ 归档。
> ```bash
> "D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
> "D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Dedicated Server" "Cyancular Ruins Server.exe"
> python tools/make_server_console.py "Cyancular Ruins Server.exe"   # ③ 不能漏:否则双击服务端无控制台
> "D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "macOS" "The Cyancular Ruins (macOS).zip"
> "D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "macOS Server" "Cyancular Ruins Server (macOS).zip"
> python tools/archive_build.py                                       # ⑥ 可选,按时间戳归档
> ```
> ⚠️ 服务端 exe 一导出就是 GUI 子系统(双击后台静默、无控制台)—— `make_server_console.py` 这步不能漏(只对 Windows；mac 的 `.app` 从终端跑就有输出)。`build_release.py` 自动做 ①②③④⑤⑥。

> **归档命名**:根目录只保留固定名产物(Windows 两个 exe + macOS 两个 zip,固定名 = 当前最新版,给 `start_server.bat` 与立即测试用);每次导出的成品按「发布标识」另存一份到 `builds/`,文件名 = `<原名> <发布标识>.<扩展名>`。`builds/` 不入库。

> **macOS 常见坑**:① 双击提示"无法验证开发者"是**未签名/未公证**的预期现象 —— 右键「打开」，或 `xattr -cr "xxx.app"`;② 从 zip 解压后若提示"已损坏"，先 `xattr -cr` 再试（zip 经浏览器下载会带 quarantine 属性）;③ mac 客户端的「启动/重启本机服务器」按钮**不可用**（`LocalServer` 是 Windows 专有实现），本机开房要手动从终端起 `Cyancular Ruins Server.app`;④ mac 与 Windows 可以互连（同一套 ENet 协议/`PROTO_VERSION`），但**两端必须同一次导出的构建**。
> **PvP 服务端 = 大厅 + 每局 worker**:大厅只监听 7777 做配对,每局配对完成自动拉起一个 headless worker 子进程、独占 UDP **7800 起**的端口(worker 结束后自行退出)。云 / 防火墙需放行 **7777 与 7800~8299 的 UDP**(端口池 = 7800 起 500 个)。

### 1.3 验证
- **把 exe 拷到项目目录外的干净文件夹再运行**:在项目目录里跑时 Godot 会用本地文件补缺失项,会掩盖打包漏项。
- 完整玩一遍(移动 / 射击 / HUD / 后处理 / 死亡效果),并确认地图 / 关卡正常加载。
- 单文件大小 ≈ 45 MB + 新增资源。

### 1.4 发布
把 `The Cyancular Ruins.exe` 这一个文件发出去即可。

### 1.5 时间戳归档(手动重导出后用)

```bash
python tools/archive_build.py                      # 归档根目录固定名产物(2 个 Windows exe + 2 个 mac zip),时间戳取当前时间
python tools/archive_build.py --stamp YYYYMMDDHHMM # 指定归档时间戳
```
★ 该脚本**只认 `--stamp` / `--version` 两个参数**(默认版本号读 `project.godot`,可临时覆盖);归档范围固定 = 根目录那几个固定名产物,不能单选文件。mac zip 缺失时只 warning（不拦 Windows-only 的归档）。

## 2. 自定义模板(一次性搭建)

> 已经搭好,正常开发不用重做。只有以下情况需要重做:重装 / 更新模板、升级 Godot 大版本、换机器。

### 2.1 环境要求

Python 3.10+(`python -m pip install scons`)、MSVC = VS 2022 Community、git,以及 4.7.1 源码(见 2.2)。

### 2.2 获取源码

GitHub 直连在国内不稳定,用 Gitee 镜像(源码路径 **`E:\Workspace\godot\godot-4.7.1-src`**):

```bash
git clone --depth 1 --branch 4.7.1-stable https://gitee.com/mirrors/godot.git E:\Workspace\godot\godot-4.7.1-src
```

### 2.3 裁剪配置(profile)

- 文件:**项目根 `cyancular_build_profile.gdbuild`**,定义 `disabled_build_options`(关掉的模块 + `disable_3d`)与 `disabled_classes`(游戏没用到的类)。
- 游戏用到的类**全部保留**在 profile 之外(`CharacterBody2D` / `Area2D` / `TileMapLayer` / `CanvasLayer` / `Control` / `ColorRect` / `Label` / `Tween` / `Timer` / `AtlasTexture` / `SpriteFrames` 等)。**改 profile 前自己 `grep` 一遍类名的实际使用。**
- 每新增一个之前没用过的类,就要从 `disabled_classes` 移除它并重编模板;缺的类**一次集齐再烘焙**(单次 ≈10~15 分钟近全量)。

### 2.4 编译模板

构建脚本:**仓库内 `tools/build_cyancular.bat`**(拷贝到引擎源码根 `E:\Workspace\godot\godot-4.7.1-src\build_cyancular.bat` 后运行,或直接改脚本内路径)。等价命令:

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64
cd /d E:\Workspace\godot\godot-4.7.1-src
python -m SCons platform=windows target=template_release production=yes optimize=size arch=x86_64 ^
    accesskit=no d3d12=no ^
    build_profile=E:\Workspace\godot\the-cyancular-ruins\cyancular_build_profile.gdbuild -j 8
```

- 首次全量编译约 13 分钟。**改 profile = 近全量重编**:`disabled_classes` 一改 → 重生成 `core/disabled_classes.gen.h` → 被 `core/object/class_db.h` include → 全引擎连锁重编,10~15 分钟;1~2 分钟的增量只有「不改 profile、单改引擎源码文件」这一种。
- 迭代:导出报 `missing class X` 时,先用**官方全功能模板**导个全量版跑一遍、一次记下所有缺的类,再一次放开、一次烘焙;平时改 GDScript 只需重导出,不重编模板。
- 产物:**`E:\Workspace\godot\godot-4.7.1-src\bin\godot.windows.template_release.x86_64.exe`**。

### 2.5 安装模板

```bash
# 备份官方模板(如尚未备份),再把自定义模板覆盖上去
cp "%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64.exe" "%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64.orig.exe"
cp "E:\Workspace\godot\godot-4.7.1-src\bin\godot.windows.template_release.x86_64.exe" "%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64.exe"
```

### 2.6 重新导出 + 验证

按第 1 节导出,然后**必须实际运行游戏验证**(改 profile 后只编译 + 导出不够,会漏运行时错误)。

> **升级 Godot 大版本(如 4.8)**:换源码目录 clone 新版本 → 复查 `cyancular_build_profile.gdbuild` 的类名 / 模块名 → 按 2.4~2.6 重编、安装、导出、验证;编辑器、导出模板、源码三者的版本必须一致。

## 3. 故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| 导出报 `可执行文件"pck"区未找到` | 模板被 UPX 过 / 缺 `pck` 节 | 恢复模板:把 `.orig.exe` 拷回,或重新编译模板 |
| 启动即闪退,stderr 一堆 `.ctex` / `CompressedTexture2D` 贴图错误 | **webp 模块被关**(贴图是 WebP 存的) | profile 里保留 `module_webp`,重编 + 重导出 |
| 运行时报 `missing class X` / 场景加载失败(如 `Could not find type "Label"`) | profile 裁掉了游戏要用的类 | 把类名从 `disabled_classes` 移除,重编 + 重导出;缺多个就**一次集齐再烘焙** |
| exe 突然变回 ~109 MB | 模板目录被官方模板覆盖(编辑器更新 / 重装) | 重新拷贝编译产物,见 2.5 |
| exe 一直是 Godot 默认图标 | 导出预设 `application/modify_resources=false` | 在导出预设里把 `modify_resources` 勾上(=true),重导出 |
| exe 离开项目目录后素材 / 地图丢失 | 原始文件(如 `.cyrm` / `.json`,无 `.import`)没被 `all_resources` 打包 | 在导出预设 `include_filter` 加模式强制打包(如 `maps/*.cyrm`),重导出 |
| 发布 exe 报 `Static function "X()" not found in base "res://..."` / `Identifier not found`,**编辑器里一切正常** | 导出前某步把某个脚本**整份重写**了(典型:`core/config/build_info.gd` 的版本信息生成器),把文件里别的内容一并抹掉 | 生成器只按行替换目标行,**别整份覆写**;`build_release.py` 的产物冒烟会拦住这一类 |
| 服务端起了但打的是「服务器就绪…(**大厅 7777**)」而不是「worker 就绪…(port 7999)」 | `--worker` / `--port` 写在了 `--` **之前**,被 Godot 当自己的参数丢掉 | 开关一律放 `--` 之后:`<exe> --headless --quit-after 120 -- --worker --port 7999`;`build_release.py` 的冒烟已按此写并断言「worker 就绪」 |

### 查看闪退错误的方法

GUI 版 exe 的错误打到 stderr:在项目根用命令行跑 `"./The Cyancular Ruins.exe" > stdout.log 2> stderr.log`,再看 `stderr.log`。
