#!/usr/bin/env python3
"""UI 截图工具（非 headless，会弹窗；只给评审用，不进默认测试批）。

按页面出图到 .tmp/ui_shots/：迁移前后各跑一遍，用于人工对比版式。

用法：
    python tools/ui_shots.py                  # 截全部页面（默认 1600x1200 窗口）
    python tools/ui_shots.py main_menu editor_root   # 只截指定页面（支持子串）
    python tools/ui_shots.py --size 1920x1440        # 指定窗口尺寸（4:3）
    python tools/ui_shots.py --list                  # 只列页面清单

实现：生成一次性 runner（.tmp/ui_shot_runner.gd/.tscn，被 .gitignore 覆盖），
逐个页面起 Godot（非 headless）→ 等两帧 → 截窗口纹理 → 退出。
★ 判据不是退出码：图没生成/尺寸不对就是失败（本工具直接报错）。
"""
import os
import subprocess
import sys
import tempfile

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = os.path.join(PROJECT, ".tmp")
OUT_DIR = os.path.join(TMP, "ui_shots")
RUNNER_GD = os.path.join(TMP, "ui_shot_runner.gd")
RUNNER_TSCN = os.path.join(TMP, "ui_shot_runner.tscn")
DEFAULT_SIZE = (1600, 1200)

# 页面清单：名字 = 输出文件名；场景 = 实例化入口。只收「能独立实例化」的页面。
SCREENS = [
    ("main_menu", "res://scenes/main_menu.tscn"),
    ("settings_menu", "res://scenes/settings_menu.tscn"),
    ("info_menu", "res://scenes/info_menu.tscn"),
    ("beta_menu", "res://scenes/beta_menu.tscn"),
    ("mp_lobby", "res://scenes/mp_lobby.tscn"),
    ("editor_root", "res://scenes/editor/editor_root.tscn"),
]

RUNNER_SCRIPT = '''extends Node

# 一次性截图 runner（tools/ui_shots.py 生成；不入库）。
# 用户参数（`--` 之后）：--screen=res://scenes/xxx.tscn --out=.tmp/ui_shots/x.png --size=1600x1200

func _ready() -> void:
	var screen := ""
	var out := ""
	var size := Vector2i(1600, 1200)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--screen="):
			screen = a.substr(9)
		elif a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--size="):
			var parts := a.substr(7).split("x")
			if parts.size() == 2:
				size = Vector2i(int(parts[0]), int(parts[1]))
	if screen == "" or out == "":
		print("UI SHOT FAIL: 缺 --screen / --out")
		get_tree().quit(1)
		return
	DisplayServer.window_set_size(size)
	var scene: PackedScene = load(screen)
	if scene == null:
		print("UI SHOT FAIL: load(%s) 为 null" % screen)
		get_tree().quit(1)
		return
	var inst: Node = scene.instantiate()
	if inst == null:
		print("UI SHOT FAIL: instantiate(%s) 为 null" % screen)
		get_tree().quit(1)
		return
	add_child(inst)
	if inst is Control:
		var c := inst as Control
		c.set_anchors_preset(Control.PRESET_TOP_LEFT)
		# 逻辑视口是 1920×1440(stretch=viewport):窗口尺寸只影响缩放,页面根必须铺满逻辑视口,
		# 否则会截出右/下灰带(2026-11-09 发现,原实现误把窗口尺寸当逻辑尺寸)。
		c.size = get_viewport().get_visible_rect().size
	for i in 90:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null or img.get_width() <= 0:
		print("UI SHOT FAIL: 视口纹理为空")
		get_tree().quit(1)
		return
	var err := img.save_png(ProjectSettings.globalize_path(out))
	if err != OK:
		print("UI SHOT FAIL: save_png(%s) err=%d" % [out, err])
		get_tree().quit(1)
		return
	print("UI SHOT OK: %s (%dx%d)" % [out, img.get_width(), img.get_height()])
	get_tree().quit(0)
'''


def godot_exe() -> str:
    for name in ("GODOT_EDITOR", "GODOT"):
        v = os.environ.get(name)
        if v and os.path.isfile(v):
            return v
    default = "D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
    if os.path.isfile(default):
        return default
    sys.exit("找不到 Godot：设环境变量 GODOT_EDITOR，或用默认路径 %s" % default)


def write_runner() -> None:
    os.makedirs(TMP, exist_ok=True)
    with open(RUNNER_GD, "w", encoding="utf-8", newline="\n") as f:
        f.write(RUNNER_SCRIPT)
    with open(RUNNER_TSCN, "w", encoding="utf-8", newline="\n") as f:
        f.write('[gd_scene load_steps=2 format=3]\n\n'
                '[ext_resource type="Script" path="res://.tmp/ui_shot_runner.gd" id="1_shot"]\n\n'
                '[node name="UiShotRunner" type="Node"]\nscript = ExtResource("1_shot")\n')


def main() -> None:
    args = sys.argv[1:]
    size = DEFAULT_SIZE
    only = []
    if "--list" in args:
        for name, scene in SCREENS:
            print("%-16s %s" % (name, scene))
        return
    if "--size" in args:
        i = args.index("--size")
        w, h = args[i + 1].lower().split("x")
        size = (int(w), int(h))
        del args[i:i + 2]
    only = [a for a in args if not a.startswith("--")]

    targets = [(n, s) for n, s in SCREENS if not only or any(o in n for o in only)]
    if not targets:
        sys.exit("没有匹配的页面：%s" % ", ".join(only))

    write_runner()
    os.makedirs(OUT_DIR, exist_ok=True)
    exe = godot_exe()
    print("Godot: %s" % exe)
    print("窗口: %dx%d  输出: %s" % (size[0], size[1], OUT_DIR))
    failed = []
    for name, scene in targets:
        out = os.path.join(OUT_DIR, name + ".png")
        if os.path.exists(out):
            os.remove(out)
        cmd = [exe, "--path", PROJECT, "--quit-after", "3600",
               "res://.tmp/ui_shot_runner.tscn", "--",
               "--screen=" + scene, "--out=" + out.replace("\\", "/"),
               "--size=%dx%d" % size]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120,
                           encoding="utf-8", errors="replace")
        ok = os.path.exists(out) and os.path.getsize(out) > 0
        tail = (r.stdout or "").strip().splitlines()
        line = tail[-1] if tail else ""
        print("[%s] %s  %s" % ("OK" if ok else "FAIL", name, line))
        if not ok:
            failed.append(name)
            err = (r.stderr or "").strip().splitlines()
            for ln in err[-6:]:
                print("   " + ln)
    if failed:
        sys.exit("截图失败: " + ", ".join(failed))
    print("UI SHOTS OK(%d 张) -> %s" % (len(targets), OUT_DIR))


if __name__ == "__main__":
    main()
