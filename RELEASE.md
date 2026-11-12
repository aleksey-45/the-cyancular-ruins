# 构建与发布

发布脚本使用 Godot 4.7.1 标准编辑器和同版本导出模板。原生工具链见 [运行与工具](docs/tools.md#从源码运行)。当前项目版本为 `1.0.0`，发布标识为 `siri_v1`。前缀和版本取自 [project.godot](project.godot) 的 `application/config/release_prefix` 和 `application/config/version`。次版本和补丁版本均为 0 时，发布标识只显示主版本。Windows 和 macOS 构建入口均支持 `--version`、`--stamp`，默认时间戳为 UTC+8。

## Windows

```powershell
$env:GODOT_EDITOR = "C:/path/to/Godot_v4.7.1-stable_win64.exe"
python tools/fetch_easytier.py --platform windows
python tools/build_release.py
```

`fetch_easytier.py` 使用官方 nightly 组件，也可用 `--source` 指定本地 Windows 官方包目录。发布脚本编译进程管理与 GNS 扩展，导入资源并导出 `The Cyancular Ruins.exe`。运行目录含两个原生 DLL、许可证和 `easytier/`。归档脚本生成 `builds/The-Cyancular-Ruins-YYYYMMDDHHMM/` 和 `releases/The-Cyancular-Ruins.zip`。

发布包内的程序可作为专用服务端运行。

```powershell
& ".\The Cyancular Ruins.exe" --headless -- --server --port 7777
```

## macOS

```sh
export GODOT_EDITOR="/Applications/Godot.app/Contents/MacOS/Godot"
python tools/build_macos.py
```

脚本构建 arm64 与 x86_64 通用扩展，获取两种架构的 EasyTier，导出并以 ad-hoc 签名打包。`builds/macos/The-Cyancular-Ruins.zip` 包含通用 `The Cyancular Ruins.app`。原生扩展位于 `Contents/Frameworks`，EasyTier 可执行文件位于 `Contents/Helpers`，默认中继配置位于 `Contents/Resources/relay.txt`。

```sh
"./The Cyancular Ruins.app/Contents/MacOS/The Cyancular Ruins" --headless -- --server --port 7777
```

## GitHub Actions

[Build game](.github/workflows/build.yml) 在推送到 `siri_v*` 分支或手动触发时构建 Windows 与 macOS，并运行 [行为检查](docs/tests.md)。产物名称为 `The-Cyancular-Ruins-Windows` 和 `The-Cyancular-Ruins-macOS`。
