#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""docs_sync — 把本地 docs/DevelopHistoryAndPlan.xlsx 与腾讯文档云端那份绑定,检测哪边更新了,
漂移时弹通知提醒(可选注册计划任务定时检查)。

为什么只能"检测 + 提醒 + 引导",不能真自动传:
  1) 腾讯文档桌面客户端没有上传 CLI / IPC / 上传协议(tdoc:// 只能打开文档);
  2) 腾讯文档开放平台上传要注册第三方应用(client_id/secret + OAuth),且据查仅面向企业主体;
  3) 客户端的「同步盘」(文件夹双向同步)在 3.12.5 里被服务端开关关掉/已下线,本机也无同步根注册项。
  → 传输那一步只能由你在客户端里点一下;本工具负责"该传还是该拉"的判定、记账与提醒。

云侧事实来自客户端自己的元数据(只读,不修改客户端任何文件):
  cloud-store.json 的 updatedAt / url / lastModifierName —— 云端修改时间、地址、最后修改人。

用法:
  python tools/docs_sync.py bind [--cloud <id|名称>]   绑定云文档(按文件名解析,可手选)
  python tools/docs_sync.py status                     本地 / 云端 / 上次同步 三方对比
  python tools/docs_sync.py check [--notify] [--quiet] [--exit-code]   单次检查(计划任务用;加 --exit-code 则有漂移时退出码 10)
  python tools/docs_sync.py mark-local                 本地已上传后,记新基线
  python tools/docs_sync.py mark-cloud <下载件.xlsx>   导入云端导出件(备份后覆盖本地)并记基线
  python tools/docs_sync.py open                       在腾讯文档客户端打开本地文件(便于手动上传)
  python tools/docs_sync.py watch [--interval 60]      前台轮询,漂移时打印提示
  python tools/docs_sync.py install-task [--interval 30]   注册计划任务定时检查+提醒
  python tools/docs_sync.py uninstall-task             删除计划任务
"""
import argparse, hashlib, json, os, platform, shutil, subprocess, sys, time, glob, datetime

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCAL = os.path.join(REPO, "docs", "DevelopHistoryAndPlan.xlsx")
STATE = os.path.join(REPO, "docs", ".docs_sync.json")
LOG = os.path.join(REPO, "docs", ".docs_sync.log")
BACKUP_DIR = os.path.join(REPO, "docs", ".docs_sync_backup")
TASK_NAME = "CyancularRuins-DocsSyncCheck"
RENOTIFY_HOURS = 4          # 漂移一直没处理时,最多每 4 小时再提醒一次

CLIENT_CANDIDATES = {
    "Windows": [os.path.join(os.environ.get("APPDATA", ""), "DocsDesktop")],
    "Darwin": [os.path.expanduser("~/Library/Application Support/DocsDesktop")],
    "Linux": [os.path.expanduser("~/.config/DocsDesktop")],
}

EXIT_CLEAN, EXIT_DRIFT = 0, 10


def die(msg, code=2):
    print("错误: " + msg, file=sys.stderr)
    sys.exit(code)


def log(msg):
    line = "[%s] %s" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    return line


def ts(ms):
    try:
        return datetime.datetime.fromtimestamp(float(ms) / 1000).strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return str(ms)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------- 通知
_TOAST_PS = r'''
$ErrorActionPreference = "Stop"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
$tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$texts = $tpl.GetElementsByTagName("text")
$texts.Item(0).AppendChild($tpl.CreateTextNode($env:DOCSYNC_TITLE)) | Out-Null
$texts.Item(1).AppendChild($tpl.CreateTextNode($env:DOCSYNC_MSG)) | Out-Null
$toast = [Windows.UI.Notifications.ToastNotification]::new($tpl)
$appid = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appid).Show($toast)
'''


def notify(title, msg):
    """弹系统通知;失败只记日志,绝不抛错(计划任务里不能因此中断)。"""
    log("通知: %s — %s" % (title, msg))
    system = platform.system()
    try:
        if system == "Windows":
            env = dict(os.environ, DOCSYNC_TITLE=title, DOCSYNC_MSG=msg)
            r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                                "-Command", _TOAST_PS],
                               env=env, capture_output=True, timeout=25)
            if r.returncode != 0:
                err = (r.stderr or b"").decode("utf-8", "replace").strip()[:200]
                log("  (Windows 通知失败 rc=%d %s)" % (r.returncode, err))
                return False
            return True
        if system == "Darwin":
            def q(s):
                return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')
            subprocess.run(["osascript", "-e",
                            "display notification %s with title %s" % (q(msg), q(title))],
                           capture_output=True, timeout=15)
            return True
        subprocess.run(["notify-send", title, msg], capture_output=True, timeout=15)
        return True
    except Exception as e:
        log("  (通知异常: %s)" % e)
        return False


# ---------------------------------------------------------------- 客户端元数据
def find_stores():
    out = []
    for root in CLIENT_CANDIDATES.get(platform.system(), []):
        if not root or not os.path.isdir(root):
            continue
        out.extend(glob.glob(os.path.join(root, "accounts", "*", "docs", "cloud-store.json")))
    return out


def cloud_docs():
    """[(store_path, uid, node)] —— 所有云端 xlsx 文档。"""
    docs, seen = [], set()
    for store in find_stores():
        uid = os.path.basename(os.path.dirname(os.path.dirname(store)))
        try:
            with open(store, encoding="utf-8") as f:
                data = json.load(f)
        except Exception as e:
            print("警告: 读不了 %s (%s)" % (store, e), file=sys.stderr)
            continue
        for nid, node in (data.get("nodes") or {}).items():
            if not isinstance(node, dict) or node.get("isFolder") or node.get("type") != "xlsx":
                continue
            if (uid, nid) in seen:
                continue
            seen.add((uid, nid))
            docs.append((store, uid, node))
    return docs


def local_state():
    if not os.path.isfile(LOCAL):
        die("本地文件不存在: %s" % LOCAL)
    st = os.stat(LOCAL)
    return {"path": LOCAL, "sha256": sha256(LOCAL), "size": st.st_size,
            "mtime_ms": int(st.st_mtime * 1000)}


def load_state():
    if os.path.isfile(STATE):
        try:
            with open(STATE, encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}


def save_state(st):
    st["updated_at"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=2)
    print("已写入绑定/基线: %s" % STATE)


def resolve_cloud(want=None):
    docs = cloud_docs()
    if not docs:
        die("没找到腾讯文档客户端元数据。先运行一次桌面客户端并登录,确认文档在云端列表里。")
    if want:
        hit = [d for d in docs if want in (d[2].get("id"), d[2].get("name"))]
        if len(hit) != 1:
            die("--cloud %r 命中 %d 条,无法唯一确定" % (want, len(hit)))
        return hit[0]
    stem = os.path.splitext(os.path.basename(LOCAL))[0].lower()
    hit = [d for d in docs if stem in str(d[2].get("name", "")).lower()]
    if not hit:
        print("云端没有名字含 %r 的 xlsx。候选如下:" % stem)
        for _, uid, n in sorted(docs, key=lambda d: -(d[2].get("updatedAt") or 0))[:15]:
            print("  %-22s %-28s 更新于 %s" % (n.get("id"), n.get("name"), ts(n.get("updatedAt"))))
        die("请用 --cloud <id> 指定")
    if len(hit) > 1:
        print("注意: 命中 %d 条同名前缀的云文档,取 updatedAt 最新的一条;如不对请用 --cloud 指定:" % len(hit))
        for _, uid, n in hit:
            print("  %-22s %-28s 更新于 %s" % (n.get("id"), n.get("name"), ts(n.get("updatedAt"))))
    return max(hit, key=lambda d: d[2].get("updatedAt") or 0)


# ---------------------------------------------------------------- 判定
def evaluate(state):
    """返回 (cur, local_changed, cloud_changed, node, cloud_now);cloud_changed=None 表示云端未知。"""
    if not state.get("cloud"):
        die("还没绑定。先跑: python tools/docs_sync.py bind")
    cur = local_state()
    local_changed = (state.get("local") or {}).get("sha256") != cur["sha256"]
    cl = state["cloud"]
    node = next((n for _, _, n in cloud_docs() if n.get("id") == cl.get("id")), None)
    if node is None:
        return cur, local_changed, None, None, None
    return cur, local_changed, node.get("updatedAt") != cl.get("updated_at"), node, node.get("updatedAt")


def drift_text(local_changed, cloud_changed):
    bits = []
    if local_changed:
        bits.append("本地已改 → 需上传")
    if cloud_changed:
        bits.append("云端已改 → 需下载")
    if cloud_changed is None:
        bits.append("云端状态未知(不在客户端列表)")
    return " / ".join(bits)


def refresh_cloud_baseline(state):
    node = next((n for _, _, n in cloud_docs() if n.get("id") == (state.get("cloud") or {}).get("id")), None)
    if node:
        state["cloud"]["updated_at"] = node.get("updatedAt")
        state["cloud"]["last_modifier"] = node.get("lastModifierName")


# ---------------------------------------------------------------- 命令
def cmd_bind(args):
    state = load_state()
    _, uid, node = resolve_cloud(args.cloud)
    state["cloud"] = {"account": uid, "id": node.get("id"), "name": node.get("name"),
                      "url": node.get("url"), "updated_at": node.get("updatedAt"),
                      "last_modifier": node.get("lastModifierName")}
    state["local"] = local_state()
    state["synced_at"] = None
    state.pop("last_notice", None)
    save_state(state)
    c = state["cloud"]
    print("已绑定云文档: %s" % c["name"])
    print("  id      : %s" % c["id"])
    print("  url     : %s" % c["url"])
    print("  云端更新: %s (%s)" % (ts(c["updated_at"]), c["last_modifier"]))
    print("  本地基线: %s  %s 字节" % (state["local"]["sha256"][:12], state["local"]["size"]))
    log("bind %s -> %s" % (c["id"], LOCAL))


def cmd_status(args):
    state = load_state()
    cur, local_changed, cloud_changed, node, cloud_now = evaluate(state)
    cl = state["cloud"]
    print("本地文件: %s" % cur["path"])
    print("  当前  %s  %s 字节  改于 %s" % (cur["sha256"][:12], cur["size"], ts(cur["mtime_ms"])))
    print("  基线  %s" % str((state.get("local") or {}).get("sha256"))[:12])
    print("云文档  : %s  (%s)" % (cl.get("name"), cl.get("id")))
    print("  上次记录云端更新: %s (%s)" % (ts(cl.get("updated_at")), cl.get("last_modifier")))
    if node is not None:
        print("  当前云端更新    : %s (%s)" % (ts(cloud_now), node.get("lastModifierName")))
    print()
    if not (local_changed or cloud_changed is not False):
        if state.get("synced_at"):
            print("✔ 自上次同步(%s)以来两边都没有改动" % state["synced_at"])
        else:
            print("• 基线刚锚定:两边相对此刻都没动,但还没确认过一次真实的上传/下载")
            print("  本地改于 %s | 云端更新于 %s(云端更晚通常意味着已经传过)"
                  % (ts(cur["mtime_ms"]), ts(cl.get("updated_at"))))
    else:
        print("• " + drift_text(local_changed, cloud_changed))
        if local_changed and cloud_changed:
            print("  ⚠ 两边都改了 —— 先决定以哪边为准,再用 mark-local / mark-cloud 覆盖,避免互相盖掉")
        else:
            print("  上传: python tools/docs_sync.py open  然后在客户端里保存/上传")
            print("  下载: 从腾讯文档导出到本地,再 python tools/docs_sync.py mark-cloud <导出件.xlsx>")
    print("\n参考地址: %s" % cl.get("url"))


def cmd_check(args):
    state = load_state()
    cur, local_changed, cloud_changed, node, cloud_now = evaluate(state)
    drifted = bool(local_changed) or (cloud_changed is not False)
    code = EXIT_DRIFT if (drifted and args.exit_code) else EXIT_CLEAN
    if not drifted:
        if not args.quiet:
            print("✔ 无漂移")
        return code
    text = drift_text(local_changed, cloud_changed)
    if not args.quiet:
        print("• " + text)
    log("漂移: " + text)
    if not args.notify:
        return code
    # 只在漂移"状态变化"时提醒;一直没处理则最多每 RENOTIFY_HOURS 小时再提醒一次
    sig = {"local": bool(local_changed), "cloud": cloud_changed is not False}
    prev = state.get("last_notice") or {}
    same = prev.get("sig") == sig
    fresh = False
    if same and prev.get("at"):
        try:
            age = time.time() - datetime.datetime.strptime(prev["at"], "%Y-%m-%d %H:%M:%S").timestamp()
            fresh = age < RENOTIFY_HOURS * 3600
        except Exception:
            fresh = False
    if same and fresh:
        if not args.quiet:
            print("(同上一次提醒,静默)")
        return code
    notify("开发记录 需要同步", text + "\n" + os.path.basename(LOCAL))
    state["last_notice"] = {"sig": sig, "at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
    save_state(state)
    return code


def cmd_mark_local(args):
    state = load_state()
    state["local"] = local_state()
    state["synced_at"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    refresh_cloud_baseline(state)
    state.pop("last_notice", None)
    save_state(state)
    log("mark-local %s" % state["local"]["sha256"][:12])
    print("已把当前本地文件记为最新基线(视为已上传)。")


def cmd_mark_cloud(args):
    src = args.file
    if not os.path.isfile(src):
        die("找不到 %s" % src)
    with open(src, "rb") as f:
        if f.read(2) != b"PK":
            die("%s 不像 xlsx(zip)文件,先确认是腾讯文档导出的表格" % src)
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    bak = os.path.join(BACKUP_DIR, "%s_%s" % (stamp, os.path.basename(LOCAL)))
    shutil.copy2(LOCAL, bak)
    print("已备份本地旧版 → %s" % bak)
    shutil.copy2(src, LOCAL)
    state = load_state()
    state["local"] = local_state()
    state["synced_at"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    refresh_cloud_baseline(state)
    state.pop("last_notice", None)
    state.setdefault("history", []).append({"action": "pull", "src": src, "backup": bak, "at": stamp})
    save_state(state)
    log("pull from %s (backup %s)" % (src, bak))
    print("已用云端导出件覆盖本地,并记为新基线。")


def cmd_open(args):
    exe = None
    if platform.system() == "Windows":
        cands = glob.glob(r"C:\Program Files\TencentDocs\versions\*\TencentDocs.exe") + \
                [r"C:\Program Files\TencentDocs\TencentDocsLauncher.exe"]
        exe = next((p for p in cands if os.path.isfile(p)), None)
    print("将在腾讯文档客户端打开: %s" % LOCAL)
    print("提示: 这一步只负责把文件放到位,真正的上传要在客户端界面里确认(无 CLI 可调)。")
    if platform.system() == "Windows":
        os.startfile(LOCAL)
        print("已请求系统用默认程序打开。传完后跑: python tools/docs_sync.py mark-local")
    else:
        print("请手动用腾讯文档客户端打开该文件并上传;传完后跑 mark-local")


def cmd_watch(args):
    state = load_state()
    last = None
    print("开始监视(每 %d 秒;Ctrl+C 退出)" % args.interval)
    while True:
        try:
            st = load_state()
            cur, local_changed, cloud_changed, node, _ = evaluate(st)
            sig = (bool(local_changed), cloud_changed is not False)
            if sig != last:
                now = datetime.datetime.now().strftime("%H:%M:%S")
                if any(sig):
                    print("[%s] %s" % (now, drift_text(local_changed, cloud_changed)))
                else:
                    print("[%s] ✔ 无漂移" % now)
                last = sig
        except SystemExit:
            raise
        except Exception as e:
            print("监视出错: %s" % e, file=sys.stderr)
        time.sleep(args.interval)


# ---------------------------------------------------------------- 计划任务
def _pythonw():
    cand = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
    return cand if os.path.isfile(cand) else sys.executable


def cmd_install_task(args):
    if platform.system() != "Windows":
        die("计划任务注册目前只实现了 Windows;macOS 请用 launchd(或先手动跑 check --notify)")
    script = os.path.abspath(__file__)
    tr = '"%s" "%s" check --notify' % (_pythonw(), script)
    now = datetime.datetime.now().strftime("%H:%M")
    cmd = ["schtasks", "/Create", "/TN", TASK_NAME, "/SC", "MINUTE", "/MO", str(args.interval),
           "/ST", now, "/TR", tr, "/F"]
    r = subprocess.run(cmd, capture_output=True)
    out = (r.stdout or b"").decode("gbk", "replace").strip()
    err = (r.stderr or b"").decode("gbk", "replace").strip()
    if r.returncode != 0:
        die("注册计划任务失败:\n%s\n%s" % (out, err))
    print(out or "已注册计划任务")
    print("任务名: %s   每 %d 分钟检查一次,漂移才提醒(状态变化时才弹,最多每 %d 小时复提醒一次)"
          % (TASK_NAME, args.interval, RENOTIFY_HOURS))
    print("查看: schtasks /Query /TN %s" % TASK_NAME)
    print("删除: python tools/docs_sync.py uninstall-task")
    print("日志: %s" % LOG)
    log("install-task interval=%d cmd=%s" % (args.interval, tr))


def cmd_uninstall_task(args):
    if platform.system() != "Windows":
        die("仅 Windows")
    r = subprocess.run(["schtasks", "/Delete", "/TN", TASK_NAME, "/F"], capture_output=True)
    out = (r.stdout or b"").decode("gbk", "replace").strip()
    err = (r.stderr or b"").decode("gbk", "replace").strip()
    if r.returncode != 0:
        die("删除失败(可能本来就没注册):\n%s\n%s" % (out, err))
    print(out or "已删除计划任务")
    log("uninstall-task")


def main():
    ap = argparse.ArgumentParser(description="本地 xlsx ↔ 腾讯文档 云文档:绑定、漂移检测与提醒")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("bind", help="绑定云文档"); p.add_argument("--cloud"); p.set_defaults(func=cmd_bind)
    sub.add_parser("status", help="三方对比").set_defaults(func=cmd_status)
    p = sub.add_parser("check", help="单次检查(计划任务用)")
    p.add_argument("--notify", action="store_true")
    p.add_argument("--quiet", action="store_true")
    p.add_argument("--exit-code", action="store_true", help="有漂移时返回 10 供脚本判断(默认总是 0)")
    p.set_defaults(func=cmd_check)
    sub.add_parser("mark-local", help="本地已上传后记基线").set_defaults(func=cmd_mark_local)
    p = sub.add_parser("mark-cloud", help="导入云端导出件"); p.add_argument("file"); p.set_defaults(func=cmd_mark_cloud)
    sub.add_parser("open", help="在客户端打开本地文件").set_defaults(func=cmd_open)
    p = sub.add_parser("watch", help="前台轮询"); p.add_argument("--interval", type=int, default=60)
    p.set_defaults(func=cmd_watch)
    p = sub.add_parser("install-task", help="注册计划任务定时检查+提醒")
    p.add_argument("--interval", type=int, default=30); p.set_defaults(func=cmd_install_task)
    sub.add_parser("uninstall-task", help="删除计划任务").set_defaults(func=cmd_uninstall_task)
    args = ap.parse_args()
    rc = args.func(args)
    sys.exit(rc if isinstance(rc, int) else 0)


if __name__ == "__main__":
    main()
