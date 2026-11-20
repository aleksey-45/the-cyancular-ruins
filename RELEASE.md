# 构建与发布

GitHub Actions 在 `siri` 分支收到推送时构建 Windows 和 macOS 版本，也支持手动运行。构建产物列在对应的工作流运行页面。[GitHub Actions](https://github.com/aleksey-45/the-cyancular-ruins/actions/workflows/build.yml?query=branch%3Asiri)

| 平台 | ZIP 文件 | 包内组件 |
|---|---|---|
| Windows x64 | `The-Cyancular-Ruins-Windows.zip` | 游戏可执行文件、原生扩展、`easytier/` |
| macOS | `The-Cyancular-Ruins-macOS.zip` | 游戏应用包，内含原生扩展和 EasyTier。支持 Apple Silicon 与 Intel，使用 ad-hoc 签名 |

两个 ZIP 都以 `The-Cyancular-Ruins/` 为顶层目录，并包含 [第三方声明](THIRD_PARTY_NOTICES.txt)。

## 本地构建

本地与 CI 使用相同的 [原生扩展工具链](docs/tools.md#从源码运行)。导出使用 Godot 4.7.1 标准版及同版本的导出模板。脚本通过 `GODOT_EDITOR` 指定 Godot 可执行文件，未设置时从 `PATH` 查找 `godot`。

```sh
python -m pip install cmake==3.31.6 ninja==1.11.1.4
python tools/build_game.py
```

[构建脚本](tools/build_game.py) 编译原生扩展、导出游戏并下载 EasyTier 官方 nightly 组件，将 ZIP 写入 `builds/`。`--skip-native` 使用本地已有的原生扩展。Windows 的 EasyTier 组件放在可执行文件旁的 `easytier/`，macOS 放在应用包的 `Contents/Helpers/`。

## 发布包中的专用服务器

游戏可执行文件带 `--server` 时进入服务器场景。以下命令以解压后的 `The-Cyancular-Ruins/` 为工作目录，监听 UDP 7777。

```powershell
& ".\The Cyancular Ruins.exe" --headless -- --server --port 7777
```

```sh
"./The Cyancular Ruins.app/Contents/MacOS/The Cyancular Ruins" --headless -- --server --port 7777
```

局域网发现使用 UDP 7788：房主/服务端的防火墙需同时放行游戏端口与 7788（公网联机另需放行 EasyTier 隧道端口）。
