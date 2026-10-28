# 测试入口

默认运行 9 项核心检查：

```powershell
python tools/run_regression.py --godot $env:GODOT --scenes
```

`--all` 运行保留的行为测试，`--only <名称>` 指定测试。网络探针使用 `--kind network`；真实多人对局使用 `tests/network/run_matches.py`。不自动运行截图和手动性能诊断。

成功要求退出码为 0、有明确成功标记，且没有脚本错误。测试按可观察行为组织，避免重复断言、固定文案和源码形式检查。精简范围和覆盖限制见[记录](../docs/eng/test_cleanup_20261028.md)。

- `smoke/`：输入、数值规则、背包与几何查询。
- `probe/`：脚本/资源加载、地形、预测、回溯和日志。
- `network/`：协议、权威、播放及真实对局驱动。
- `harness/`、`lib/`：共享夹具和辅助代码。
- `scripts/`：手动诊断和数据工具。

独立 `-s` 脚本在 autoload 初始化前编译，测试需避免静态引入依赖单例的场景代码。网络测试只清理自己启动的进程。
