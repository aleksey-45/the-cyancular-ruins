# The Cyancular Ruins — 编译与发布手册

本文档记录本项目的 **单文件 exe demo** 发布流程,以及自定义裁剪模板的编译方法。

> 目标:发布一个"仅单 exe"的 demo,体积约 **37 MB**(未裁剪的官方模板约 109 MB)。

---

## 0. 关键结论(先记住这三条)

1. **必须用 4.7.1 标准(非 mono)编辑器导出** —— 用 4.4.1 mono 编辑器会走 mono 模板,exe 直接 100MB+。
2. **永远不要对模板或成品 exe 用 UPX** —— Godot 4.7 把 PCK 内嵌在 exe 的一个 PE 节(`pck`)里,UPX 会弄丢这个节,导出直接报 `可执行文件"pck"区未找到`,或运行时空窗/闪退。
3. **裁剪 profile 里 webp 模块必须保留** —— Godot 4.7 导入无损贴图默认存成 WebP,运行时靠 `module_webp` 解码;关掉它所有贴图加载失败、游戏闪退(已踩过坑)。

---

## 1. 日常发布流程(每次改完游戏后)

### 1.1 开发与自测
- 用 **4.7.1 标准编辑器** 打开项目开发:
  `D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe`
- 改完先在编辑器里 playtest 确认没问题。

### 1.2 重新导出(二选一)

**图形界面**:项目 → 导出 → Windows Desktop → 导出项目

**命令行**(推荐,一条命令):
```bash
python tools/build_release.py                      # 客户端+服务端+服务端打回控制台+时间戳归档,一键全做
```

> 只想手动重导出(不开一键脚本)时,按序做:**① 导客户端** → **② 导服务端** → **③ 服务端打回 CONSOLE** → **④ 归档**(见 §1.5):
> ```bash
> "D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
> "D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Dedicated Server" "Cyancular Ruins Server.exe"
> python tools/make_server_console.py "Cyancular Ruins Server.exe"   # ③ 必须做:否则双击服务端无控制台(看不见日志)
> python tools/archive_build.py                                       # ④ 可选,按时间戳归档
> ```
> **⚠️ 服务端 exe 导出一出来就是 GUI 子系统(双击后台静默、无控制台)**——`make_server_console.py` 这步**不能漏**。漏了 = 双击服务端没窗口、以为没起来(2026-09-06 已踩坑)。`build_release.py` 自动做 ①②③④,不会漏。

> **发布归档命名习惯**:每次导出的成品按时间戳归档到 `builds/`,文件名 = `<原名> <YYYYMMDDHHMM>.exe`(如 `The Cyancular Ruins 202609062126.exe`、`Cyancular Ruins Server 202609062126.exe`);**根目录只保留两个固定名 exe**(`The Cyancular Ruins.exe` / `Cyancular Ruins Server.exe`,固定名=当前最新版,给 start_server.bat / 立即测试用)。`builds/` 不入库(gitignore 已配)。`build_release.py` 每次导完自动归档一份时间戳副本;想用别的历史名可 `python tools/build_release.py --stamp 202609062126`。手动重导出(上方命令行)只更新固定名,归档请另跑 `tools/archive_build.py`(见 §1.5)或手动复制。

> **PvP 服务端 = 大厅 + 每局 worker**:大厅只监听 7777 做配对,每局配对完成自动拉起一个 headless worker 子进程、独占 UDP **7800 起**的端口(worker 结束后自行退出)。云/防火墙需放行 **7777 与 7800~7999 的 UDP**;局域网/本机不受限。

### 1.3 验证
- **把 exe 拷到项目目录外的干净文件夹再运行**(比如桌面/临时目录)。在项目目录里跑时,Godot 可能从本地文件系统补齐缺失文件,会**掩盖打包漏项**——这是最容易误判的地方。
- 完整玩一遍(移动/射击/HUD/后处理/死亡效果),并确认地图/关卡正常生成。
- 单文件大小 ≈ 37 MB + 新增资源;只要资源不涨,体积基本不变。

### 1.4 发布
把 `The Cyancular Ruins.exe` 这一个文件发出去即可。

### 1.5 时间戳归档(手动重导出后用)
只跑了 §1.2 的手动命令行(仅更新固定名)时,补一份时间戳副本进 `builds/`:
```bash
python tools/archive_build.py                      # 归档根目录两个固定名 exe,时间戳取当前时间
python tools/archive_build.py --stamp 202609062126 # 指定归档时间戳(追溯/对齐用)
python tools/archive_build.py --file "Some.exe"    # 只归档指定文件
```
`build_release.py`(§1.2 一键打包)导出后已自动调用它,无需再手动归档。

---

## 2. 首次搭建自定义模板(一次性)

> 已经搭好,正常开发不用重做。只有以下情况需要重做:
> 重装/更新模板、升级 Godot 大版本、换机器。

### 2.1 环境要求
| 依赖 | 说明 |
|---|---|
| Python 3.10+ | `python -m pip install scons` 装 SCons |
| MSVC | VS 2022 Community(`vcvarsall.bat` 路径见 2.4) |
| git | 用于拉源码 |
| Godot 4.7.1 源码 | 见 2.2 |

### 2.2 获取源码
GitHub 直连在国内不稳定,用 Gitee 镜像:
```bash
git clone --depth 1 --branch 4.7.1-stable https://gitee.com/mirrors/godot.git E:\Workspace\godot\godot-4.7.1-src
```
> 源码路径:**`E:\Workspace\godot\godot-4.7.1-src`**

### 2.3 裁剪配置(profile)
- 文件:**项目根 `cyancular_build_profile.gdbuild`**
- 它定义:
  - `disabled_build_options`:关闭的模块(3D、音频格式、网络、导航、XR、图片格式等)+ `disable_3d`。
  - `disabled_classes`:游戏没用到的类(音频播放器、粒子、AnimationPlayer、GUI 控件等)。
- 游戏用到的类**全部保留**在 profile 之外(`CharacterBody2D`/`Area2D`/`TileMapLayer`/`Parallax2D`/`CanvasLayer`/`Control`/`ColorRect`/`Label`/`Tween`/`Timer`/`AtlasTexture`/`SpriteFrames` 等)。
  > `Label` 是击杀计数(HUD 文本)首次引入的 GUI 类——**每新增一个之前没用过的类,就要从 `disabled_classes` 移除它并重编模板**(见 3 排查表)。
  > **别加一个类就重编一次**:改 classes/模块列表 = 近全量重编 10~15 分钟(见 §2.4),把缺的类一次集齐再烘焙。

### 2.4 编译模板
构建脚本:**仓库内 `tools/build_cyancular.bat`**(已入库,来源副本;使用时拷贝到引擎源码根
`E:\Workspace\godot\godot-4.7.1-src\build_cyancular.bat` 后运行,或直接改脚本内路径)。等价命令:

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64
cd /d E:\Workspace\godot\godot-4.7.1-src
python -m SCons platform=windows target=template_release production=yes optimize=size arch=x86_64 ^
    accesskit=no d3d12=no ^
    build_profile=E:\Workspace\godot\the-cyancular-ruins\cyancular_build_profile.gdbuild -j 8
```

- 首次全量编译约 13 分钟。
- **改 profile 不是 1~2 分钟的廉价增量,实测近全量、10~15 分钟**:`disabled_classes` 一改 → 重生成 `core/disabled_classes.gen.h` → 它被 `core/object/class_db.h` include → 全引擎数百个 .cpp 连锁重编(实测只放开几十个类就重编了 377/1519 个 obj,约 13 分钟);开关整个模块还会重生成 `modules/modules_enabled.gen.h` + 第三方库,更接近全量。真正 1~2 分钟的增量只有「**不改 profile**、单改引擎源码文件」这一种情况。
- **迭代建议**:发现导出 exe 报 `missing class X`,先用**官方全功能模板**导个全量版跑一遍,一次性记下所有缺的类,再一次放开、一次烘焙;平时改 GDScript 只需重导出、不要重编模板。
- 产物:**`E:\Workspace\godot\godot-4.7.1-src\bin\godot.windows.template_release.x86_64.exe`**(约 36 MB)。

### 2.5 安装模板
```bash
# 备份官方模板(如尚未备份)
cp "%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64.exe" \
   "%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64.orig.exe"

# 覆盖安装自定义模板
cp "E:\Workspace\godot\godot-4.7.1-src\bin\godot.windows.template_release.x86_64.exe" \
   "%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64.exe"
```

### 2.6 重新导出 + 验证
按第 1 节导出,然后**必须实际运行游戏验证**(改 profile 后只编译+导出不够,会漏运行时错误)。

---

## 3. 故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| 导出报 `可执行文件"pck"区未找到` | 模板被 UPX 过 / 缺 `pck` 节 | 恢复模板:把 `.orig.exe` 拷回,或重新编译模板 |
| 启动即闪退,stderr 一堆 `.ctex` / `CompressedTexture2D` 贴图错误 | **webp 模块被关**(贴图是 WebP 存的) | profile 里保留 `module_webp`,重编+重导出 |
| 运行时报 `missing class X` / 场景加载失败 | profile 裁掉了游戏要用的类 | 把类名从 `disabled_classes` 里移除,重编+重导出;缺多个就**一次集齐再烘焙**(单次≈10~15 分钟近全量) |
| 重编模板一次 10~15 分钟,不像「增量 1~2 分钟」 | 改 classes/模块列表连锁重编 gen 头,**正常现象** | 迭代用官方模板定位缺类;profile 改动攒批一次烘焙(见 §2.4) |
| 发布 exe 报 `Could not find type "Label"`(hud.gd 解析失败),项目目录里一切正常 | 加了项目之前没用过的 GUI 类(首个文本 UI 就是 `Label`)但 profile 仍裁着它 | 从 `disabled_classes` 移除该类,重编模板+重导出(见 2.4~2.6) |
| exe 突然变回 ~109 MB | 模板目录被官方模板覆盖(编辑器更新/重装) | 重新拷贝编译产物,见 2.5 |
| exe 一直是 Godot 默认图标,自定义 icon 不生效 | 导出预设 `application/modify_resources=false` | 在导出预设里把 `modify_resources` 勾上(=true),重导出 |
| exe 离开项目目录后素材/地图丢失 | 原始文件(如 `.cyrm`/`.json`,无 `.import`)没被 `all_resources` 打包 | 在导出预设 `include_filter` 加模式强制打包,如 `maps/*.cyrm`,重导出 |
| 在项目目录里测 exe 一切正常,拷出去就缺东西 | 项目目录运行时 Godot 用本地文件补齐,掩盖了打包漏项 | 务必**拷到项目外**测试打包完整性 |
| 用了 4.4.1 mono 编辑器导出 | 强行走 mono 模板 | 换 4.7.1 标准编辑器 |

### 查看闪退错误的方法
GUI 版 exe 错误打到 stderr,用命令行跑并重定向:
```bash
cd E:\Workspace\godot\the-cyancular-ruins
"./The Cyancular Ruins.exe" > stdout.log 2> stderr.log
cat stderr.log
```

---

## 4. 升级 Godot 大版本(如 4.8)

1. 重新下载对应版本源码(Gitee 镜像),clone 到新目录。
2. 复用/复查 `cyancular_build_profile.gdbuild`:类名、模块名可能随版本变化(比如 `disable_advanced_gui` 在 4.7 已失效)。
3. 按 2.4~2.6 重新编译、安装、导出、验证。
4. 编辑器、导出模板、源码三者的版本必须一致。

---

## 附:相关路径速查

| 用途 | 路径 |
|---|---|
| 项目 | `E:\Workspace\godot\the-cyancular-ruins` |
| 4.7.1 标准编辑器 | `D:\Program Files\Godot_v4.7.1-stable_win64\Godot_v4.7.1-stable_win64.exe` |
| 导出模板目录 | `%APPDATA%\Godot\export_templates\4.7.1.stable\` |
| 官方模板备份 | `%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64.orig.exe` |
| Godot 源码 | `E:\Workspace\godot\godot-4.7.1-src` |
| 裁剪 profile | `E:\Workspace\godot\the-cyancular-ruins\cyancular_build_profile.gdbuild` |
| 构建脚本 | `E:\Workspace\godot\godot-4.7.1-src\build_cyancular.bat` |
| 编译产物 | `E:\Workspace\godot\godot-4.7.1-src\bin\godot.windows.template_release.x86_64.exe` |
| 发布 exe | `E:\Workspace\godot\the-cyancular-ruins\The Cyancular Ruins.exe` |
