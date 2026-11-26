# 构建与发布

推送到 `feat/upstream-main-migration` 分支会触发 Windows 和 macOS 构建，也可以在 GitHub Actions 中手动运行。构建包可从对应的工作流运行页面下载。[GitHub Actions](https://github.com/aleksey-45/the-cyancular-ruins/actions/workflows/build.yml?query=branch%3Afeat%2Fupstream-main-migration)

| 平台 | ZIP 文件 | 包内组件 |
|---|---|---|
| Windows x64 | `The-Cyancular-Ruins-Windows.zip` | 游戏可执行文件、原生扩展、`easytier/` |
| macOS | `The-Cyancular-Ruins-macOS.zip` | 游戏应用包，内含原生扩展和 EasyTier。支持 Apple Silicon 与 Intel，使用 ad-hoc 签名 |

两个 ZIP 都以 `The-Cyancular-Ruins/` 为顶层目录。`maps/` 目录中的示例地图可以直接在地图编辑器中打开。包内另附 [第三方声明](THIRD_PARTY_NOTICES.txt)。

## 本地构建

本地与 CI 使用相同的[原生扩展工具链](docs/tools.md#从源码运行)。导出使用 Godot 4.7.1 标准版和同版本的导出模板。可通过环境变量 `GODOT_EDITOR` 指定 Godot 可执行文件，默认从 `PATH` 查找 `godot`。

```sh
python -m pip install cmake==3.31.6 ninja==1.11.1.4
python tools/build_game.py
```

[构建脚本](tools/build_game.py) 编译原生扩展、导出游戏并下载 EasyTier 官方 nightly 组件，将 ZIP 写入 `builds/`。`--skip-native` 使用本地已有的原生扩展。Windows 的 EasyTier 组件放在可执行文件旁的 `easytier/`，macOS 放在应用包的 `Contents/Helpers/`。

## 发布包中的专用服务器

在解压后的 `The-Cyancular-Ruins/` 目录中运行对应命令，即可启动监听 UDP 7777 端口的无头专用服务器。

```powershell
& ".\The Cyancular Ruins.exe" --headless -- --server --port 7777
```

```sh
"./The Cyancular Ruins.app/Contents/MacOS/The Cyancular Ruins" --headless -- --server --port 7777
```
