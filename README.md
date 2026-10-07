# The Cyancular Ruins

<p align="center">
  <img src="icon.svg" alt="The Cyancular Ruins" width="128" height="128" />
</p>

[![Godot 4.7.1](https://img.shields.io/badge/Godot-4.7.1-478CBF?logo=godotengine&logoColor=white)](https://godotengine.org/)
[![许可证](https://img.shields.io/badge/许可证-MIT-green)](LICENSE)

像素风 2D 横版平台动作射击游戏演示项目，基于 Godot 引擎开发，内置 P2P 联机支持。

- [架构文档与索引](CLAUDE.md)
- [网络架构文档](docs/netplay.md)
- [编译与发布手册](RELEASE.md)

---

## 快速开始

开发与测试环境需要 [Godot Engine 4.7.1](https://godotengine.org/download)（标准版，64 位）。

```bash
git clone https://github.com/aleksey-45/the-cyancular-ruins.git
```

使用 Godot 编辑器导入项目根目录的 `project.godot`，按 `F5` 即可运行。

### 打包发布

```bash
python tools/build_release.py
```

### 启动专用服务端

```bash
"Cyancular Ruins Server.exe" -- --port 7777
```

### 自动化测试

```bash
godot --headless --path . -s res://tests/smoke/grain_account_smoke.gd
godot --headless --path . -s res://tests/smoke/time_field_smoke.gd
godot --headless --path . -s res://tests/probe/subcell_probe.gd
godot --headless --path . -s res://tests/probe/netplay_probe.gd
godot --headless --path . -s res://tests/smoke/enemy_logic_smoke.gd
```

---

## 致谢

- [Godot Engine](https://godotengine.org/) — 开源游戏引擎（遵循 MIT 许可证）
- [EasyTier](https://github.com/EasyTier/EasyTier) — 分布式网络隧道（遵循 LGPL-3.0 许可证）
- GNU Unifont — 点阵字体（遵循 SIL OFL 1.1 许可证）
- Less Perfect DOS VGA — 像素字体（Zeh Fernando / Laemeur）

世界观受博尔赫斯《环形废墟》与艾略特《四个四重奏》启发。

## 许可证

MIT 许可证。第三方资源遵循各自原始开源许可证。
