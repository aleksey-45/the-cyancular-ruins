# The Cyancular Ruins — 编译与发布手册

发布产物是**整包目录**:客户端、服务端两个 exe 平铺 + `easytier/` 四件套
(`easytier-core.exe`、`easytier-cli.exe`、`Packet.dll`、`wintun.dll`)与 `relay.txt`。
客户端单 exe ≈ 45 MB(未裁剪的官方模板约 109 MB)。

---

## 1. 日常发布

### 1.1 一键发布

```bash
GODOT_EDITOR="D:/Codes/Zcode/cyr/godot-build/editor/Godot_v4.7.1-stable_win64.exe" \
  python tools/build_release.py
```

- `GODOT_EDITOR` = 4.7.1 标准编辑器路径(脚本内置默认是旧机器路径,需覆盖)。
- 可选参数:`--version 1.2.0`(默认读 `project.godot` 的 `config/version`,只能数字+点)、
  `--stamp YYYYMMDDHHMM`。

脚本依次执行,任何一步失败即中止:

1. **写发布信息**:`v.<版本>` 与时间戳写进 `core/config/build_info.gd`(游戏内主菜单与服务端
   日志读它),导出后自动还原为 dev 占位,`git status` 不因此变脏。
2. **导出客户端**(`Windows Desktop` 预设)与**服务端**(`Dedicated Server` 预设)。
3. **服务端打回 CONSOLE 子系统**(`tools/make_server_console.py`),双击才有控制台窗口。
4. **冒烟**:
   - 客户端直接启动;
   - 服务端 `--headless --quit-after 120 -- --port 7999`,输出须含「服务器就绪」
     (7999 不碰服主正在跑的 7777);
   - 仓库根 `easytier/` 四件套齐全时,另跑 `-- --port 7999 --tunnel --room 48213`,
     输出须含「隧道就绪」;不齐全则跳过这一步。
   - 出现 `SCRIPT ERROR` / `Parse Error` / `Failed to load script` 即中止发布。
   - 命令行开关一律写在 `--` 之后:引擎只解析 `--` 之前,游戏读 `--` 之后。
5. **归档**:`tools/archive_build.py` 先清空 `builds/`,再建立唯一一份
   `builds/The Cyancular Ruins <版本> <时间戳>/` —— 两个 exe 平铺(客户端按自己所在目录
   找服务端)+ `easytier/` 四件套与 `relay.txt`(客户端按自己所在目录找它们)。

### 1.2 手动重导出(不走一键脚本时)

```bash
"<编辑器>" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
"<编辑器>" --headless --path . --export-release "Dedicated Server" "Cyancular Ruins Server.exe"
python tools/make_server_console.py "Cyancular Ruins Server.exe"   # 漏了它服务端无控制台
python tools/archive_build.py                                      # 补打包进 builds/
```

`tools/archive_build.py` 支持 `--stamp` / `--version`;每次归档**只保留最新一份**。

### 1.3 验证与发布

- 把 `builds/` 整包**拷到项目目录外**运行:在项目目录里跑会掩盖打包缺漏。
- 完整玩一遍(移动/射击/HUD/死亡效果/地图生成)。
- 远程联机:两端用同一整包,一边建房一边输码;日志在两侧的
  `log/easytier-host-<pid>` / `log/easytier-guest-<pid>`(详见 `docs/netplay.md`)。
- 发布 = 把 `builds/` 下整包目录整个发出;单发 exe 等于没装远程联机。
- 查闪退:命令行运行并重定向 stderr(`"./The Cyancular Ruins.exe" > stdout.log 2> stderr.log`)。

---

## 2. 自定义裁剪模板(换机器 / 升级引擎时重做)

### 2.1 环境

| 依赖 | 说明 |
|---|---|
| Python 3.10+ | `python -m venv godot-build\venv` → `godot-build\venv\Scripts\python -m pip install scons` |
| MSVC(VS 2022) | 默认工具链,scons 自动探测,不需要 vcvarsall |
| MinGW-w64 x86_64(备选) | 需在 PATH 上;`use_mingw=yes lto=none` 两个参数成对使用 |
| git | 拉源码 |

### 2.2 引擎源码与裁剪配置

- 源码:`godot-build\godot-4.7.1-stable\`(GitHub codeload zip;Gitee 镜像:
  `git clone --depth 1 --branch 4.7.1-stable https://gitee.com/mirrors/godot.git`)。
- 裁剪配置:项目根 `cyancular_build_profile.gdbuild`,含 `disabled_build_options`(关模块,
  含 `disable_3d`;`module_webp` 必须保留)与 `disabled_classes`(关类)。
- **项目新用一个类,就把它从 `disabled_classes` 移出并重编模板**
  (已有先例:`Label`、`PacketPeerUDP`、`TCPServer`)。改 profile 是近全量重编,攒批一次做;
  平时改 GDScript 只需重导出。

### 2.3 编译(工作目录 `godot-build\godot-4.7.1-stable\`)

**默认:MSVC**(全量约 5 分钟,模板 ≈ 40 MB):

```bat
D:\Codes\Zcode\cyr\godot-build\venv\Scripts\python.exe -m SCons ^
    platform=windows target=template_release production=yes optimize=size arch=x86_64 ^
    accesskit=no d3d12=no ^
    build_profile="D:\Codes\Zcode\cyr\the-cyancular-ruins\cyancular_build_profile.gdbuild" -j 8
```

**备选:MinGW**(`use_mingw=yes lto=none` 成对使用,缺一不可):

```bat
D:\Codes\Zcode\cyr\godot-build\venv\Scripts\python.exe -m SCons ^
    platform=windows target=template_release production=yes optimize=size arch=x86_64 ^
    lto=none use_mingw=yes accesskit=no d3d12=no ^
    build_profile="D:\Codes\Zcode\cyr\the-cyancular-ruins\cyancular_build_profile.gdbuild" -j 8
```

产物:`bin\godot.windows.template_release.x86_64.exe` 及同名 `.console.exe`
(`tests/` 的 headless 探针用 console 版)。

### 2.4 安装

```bat
copy bin\godot.windows.template_release.x86_64.exe         "%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64.exe"
copy bin\godot.windows.template_release.x86_64.console.exe "%APPDATA%\Godot\export_templates\4.7.1.stable\windows_release_x86_64_console.exe"
```

目录内需有 `version.txt`(内容 `4.7.1.stable`)。安装后按 §1 走一遍发布即完成验证。

---

## 3. 常见问题

| 现象 | 处理 |
|---|---|
| 导出报 `可执行文件"pck"区未找到` | 模板或 exe 被 UPX 处理过 —— 恢复模板,不要对它们用 UPX |
| 启动闪退,stderr 一堆 `.ctex` / `CompressedTexture2D` 错误 | profile 里 `module_webp` 被关 —— 保留并重编 |
| 运行时报 `missing class X` / `Could not find type "X"` | 该类还在 `disabled_classes` 里 —— 移出并重编模板 |
| scons 配置阶段报 d3d12 依赖缺失后中止 | 命令里加 `d3d12=no`(或跑 `misc/scripts/install_d3d12_sdk_windows.py`) |
| MinGW 链接报 `collect2.exe: fatal error: CreateProcess` | 命令里加 `lto=none` |
| 要编 MinGW 却在编 MSVC | 命令里加 `use_mingw=yes` |
| exe 变回 ~109 MB | `%APPDATA%` 里的模板被官方模板覆盖 —— 重新安装(§2.4) |
| 服务端起在默认端口 7777 | 开关没写在 `--` 之后,被引擎丢弃 |
| easytier-core 双击/拉起零输出立刻退出 | `easytier/` 缺 `Packet.dll` / `wintun.dll` —— 四件套整包放齐 |
| exe 离开项目目录后素材/地图丢失 | 导出预设 `include_filter` 补模式(如 `maps/*.cyrm`) |
| 图标不生效 | 导出预设勾 `application/modify_resources` |
| mono 编辑器导出的 exe 双击起不来 | 用标准编辑器(`godot-build\editor\`)导出 |

---

## 4. 升级 Godot 大版本

1. 新版本源码解到 `godot-build\` 下的新目录;编辑器换同版本(`Godot_v<版本>_win64.exe.zip`
   解到 `godot-build\editor\`)。
2. 复查 `cyancular_build_profile.gdbuild`(类名、模块名可能随版本变化)。
3. 按 §2.3–2.4 重编并安装模板,按 §1 重导出、验证。
4. 用新版 `easytier-core.exe --help` 核对 `core/config/tunnel_meta.gd` 里的隧道参数清单。

---

## 附:路径速查

| 用途 | 路径 |
|---|---|
| 项目 | `D:\Codes\Zcode\cyr\the-cyancular-ruins` |
| 标准编辑器 | `D:\Codes\Zcode\cyr\godot-build\editor\Godot_v4.7.1-stable_win64.exe` |
| 导出模板目录 | `%APPDATA%\Godot\export_templates\4.7.1.stable\` |
| Godot 源码 | `D:\Codes\Zcode\cyr\godot-build\godot-4.7.1-stable\` |
| SCons venv | `D:\Codes\Zcode\cyr\godot-build\venv\` |
| 裁剪 profile | `D:\Codes\Zcode\cyr\the-cyancular-ruins\cyancular_build_profile.gdbuild` |
| 模板编译产物 | `godot-build\godot-4.7.1-stable\bin\godot.windows.template_release.x86_64.exe` |
| 发布 exe(固定名) | `<项目>\The Cyancular Ruins.exe`、`<项目>\Cyancular Ruins Server.exe` |
| 发布归档(只留最新一份) | `<项目>\builds\The Cyancular Ruins <版本> <时间戳>\` |
| 远程联机文档 | `<项目>\docs\netplay.md` |
