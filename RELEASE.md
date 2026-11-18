# 构建与发布

推送到 `siri` 后，在 [GitHub Actions](https://github.com/aleksey-45/the-cyancular-ruins/actions/workflows/build.yml?query=branch%3Asiri) 的运行页面下载 Windows 或 macOS ZIP。解压后只有一层 `The-Cyancular-Ruins/`，里面是游戏、联机所需组件和第三方许可证。macOS 产物支持 Apple Silicon 与 Intel，使用 ad-hoc 签名。

## 本地构建

使用与 Actions 相同的 [原生工具链](docs/tools.md#从源码运行)，并安装 Godot 4.7.1 标准版及同版本导出模板。将 Godot 加入 `PATH`，或通过 `GODOT_EDITOR` 指定编辑器可执行文件。

```sh
python -m pip install cmake==3.31.6 ninja==1.11.1.4
python tools/build_game.py
```

脚本自动获取官方最新 EasyTier nightly。ZIP 输出到 `builds/`，文件名为 `The-Cyancular-Ruins-Windows.zip` 或 `The-Cyancular-Ruins-macOS.zip`。

从解压后的 `The-Cyancular-Ruins/` 运行专用服务端。

```powershell
& ".\The Cyancular Ruins.exe" --headless -- --server --port 7777
```

```sh
"./The Cyancular Ruins.app/Contents/MacOS/The Cyancular Ruins" --headless -- --server --port 7777
```
