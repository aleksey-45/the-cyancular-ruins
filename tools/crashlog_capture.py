#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""crashlog_capture — 每次游戏(exe)跑完自动归档日志,并记下 Windows 崩溃事件。

为什么要它:Godot 自己就把每次运行的日志写在 user://logs/,但那份东西位置隐蔽、
会被后续运行轮转覆盖,而且原生崩溃(0xc0000005)常常来不及写完就没了。本工具:
  1) 后台看守游戏 exe 的起与落(按进程名前缀匹配,兼容带日期后缀的构建名);
  2) 每次跑完把这一轮产生的日志复制到 crashlogs/<时间>_<exe>/ 留档;
  3) 从 Windows 应用程序事件日志(Id 1000/1001)里取出这次是否崩溃、异常代码、
     故障模块与故障偏移量,写进 run.json;
  4) 保留最近若干轮(崩溃那几轮永不删)。

用法:
  python tools/crashlog_capture.py install-task   设置登录自启(免管理员)+ 立刻启动看守
  python tools/crashlog_capture.py start / stop   手动启停看守(无窗口)
  python tools/crashlog_capture.py status                                现在是否在跑 / 上一次运行
  python tools/crashlog_capture.py report [--last 20] [--days 30]        汇总归档 + 崩溃历史
  python tools/crashlog_capture.py watch [--interval 2] [--duration 0] [--exe 前缀]  前台看守
  python tools/crashlog_capture.py uninstall-task                        移除自启并停止
  python tools/crashlog_capture.py selftest       自检:验证事件查询与归档管线(不启动游戏)
"""
import argparse, ctypes, datetime, hashlib, json, os, platform, shutil, subprocess, sys, tempfile, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARCHIVE = os.path.join(REPO, "crashlogs")
STATE = os.path.join(ARCHIVE, ".capture_state.json")
CAPLOG = os.path.join(ARCHIVE, "capture.log")
PIDFILE = os.path.join(ARCHIVE, ".watcher.pid")
TASK_NAME = "CyancularRuins-CrashlogCapture"
# 按前缀匹配进程名:导出的构建名带日期后缀(如 The Cyancular Ruins_KH_v1_1_3_PubServer_20260911_2349.exe)
# 也纳入带符号的调试引擎(复现崩溃时跑的就是它,godot-4.7.1-src/bin/)
EXE_PREFIXES = ["The Cyancular Ruins", "Cyancular Ruins Server", "godot.windows.template_debug"]
KEEP_RUNS = 100          # 非崩溃轮最多保留这么多
PROJECT_NAME = "The Cyancular Ruins"   # 决定 user:// 目录名


def log(msg):
    os.makedirs(ARCHIVE, exist_ok=True)
    line = "[%s] %s" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        with open(CAPLOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass
    return line


def now_str():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def godot_log_dir():
    if platform.system() == "Windows":
        base = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata", PROJECT_NAME, "logs")
    elif platform.system() == "Darwin":
        base = os.path.expanduser("~/Library/Application Support/Godot/app_userdata/%s/logs" % PROJECT_NAME)
    else:
        base = os.path.expanduser("~/.local/share/godot/app_userdata/%s/logs" % PROJECT_NAME)
    return base


# ---------------------------------------------------------------- 进程枚举(ctypes,零外部依赖)
def list_processes():
    """{pid: image_name} —— Windows 走 ctypes,tasklist 兜底;其它平台用 pgrep。"""
    out = {}
    if platform.system() == "Windows":
        try:
            from ctypes import wintypes

            class PROCESSENTRY32W(ctypes.Structure):
                _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                            ("th32ProcessID", wintypes.DWORD),
                            ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
                            ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                            ("th32ParentProcessID", wintypes.DWORD),
                            ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
                            ("szExeFile", ctypes.c_wchar * 260)]

            k32 = ctypes.WinDLL("kernel32", use_last_error=True)
            TH32CS_SNAPPROCESS = 0x00000002
            INVALID = ctypes.c_void_p(-1).value
            snap = k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
            if snap == INVALID:
                raise OSError("CreateToolhelp32Snapshot failed")
            try:
                e = PROCESSENTRY32W()
                e.dwSize = ctypes.sizeof(PROCESSENTRY32W)
                ok = k32.Process32FirstW(snap, ctypes.byref(e))
                while ok:
                    out[int(e.th32ProcessID)] = e.szExeFile
                    ok = k32.Process32NextW(snap, ctypes.byref(e))
            finally:
                k32.CloseHandle(snap)
            return out
        except Exception as ex:
            log("进程枚举 ctypes 失败(%s),回退 tasklist" % ex)
        r = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True)
        for line in (r.stdout or b"").decode("gbk", "replace").splitlines():
            parts = [p.strip('"') for p in line.split('","')]
            if len(parts) >= 2 and parts[1].isdigit():
                out[int(parts[1])] = parts[0]
        return out
    r = subprocess.run(["pgrep", "-a", ""], capture_output=True)
    if r.returncode == 0:
        for line in r.stdout.decode("utf-8", "replace").splitlines():
            bits = line.split(None, 1)
            if len(bits) == 2 and bits[0].isdigit():
                out[int(bits[0])] = os.path.basename(bits[1])
    return out


def canonical_name(name):
    """把系统报出的进程名对齐到登记的写法(系统有时报全大写),同时保留构建日期后缀。"""
    for p in EXE_PREFIXES:
        if name.lower().startswith(p.lower()):
            return p + name[len(p):]
    return name


def matching_processes():
    procs = list_processes()
    return {pid: canonical_name(n) for pid, n in procs.items()
            if any(n.lower().startswith(p.lower()) for p in EXE_PREFIXES)}


# ---------------------------------------------------------------- 事件日志查询
_PS_QUERY = r'''
$ErrorActionPreference = 'Continue'
$rows = @()
$start = [datetime]::ParseExact($env:CLW_START, 'yyyy-MM-dd HH:mm:ss', $null)
$end   = [datetime]::ParseExact($env:CLW_END,   'yyyy-MM-dd HH:mm:ss', $null)
# 只取 1000(应用程序错误):它带异常代码与故障偏移量;1001 是 WER 报告完成事件,与 1000 重复
foreach ($id in 1000) {
  $evs = @()
  try { $evs = Get-WinEvent -FilterHashtable @{LogName='Application'; Id=$id; StartTime=$start; EndTime=$end} -ErrorAction Stop }
  catch { $evs = @() }
  foreach ($e in $evs) {
    $m = $e.Message
    $hit = $false
    foreach ($n in ($env:CLW_NAMES -split ';')) { if ($n -and $m -like "*$n*") { $hit = $true } }
    if (-not $hit) { continue }
    $code = ''; $mod = ''; $off = ''; $fpid = ''; $app = ''
    if ($m -match '(?:异常代码|Exception code)[:：]?\s*(0x[0-9a-fA-F]+|\S+)') { $code = $Matches[1] }
    if ($m -match '(?:错误模块名称|故障模块名称|Faulting module name)[:：]?\s*([^,，\r\n]+)') { $mod = $Matches[1].Trim() }
    if ($m -match '(?:错误偏移量|故障偏移量|Faulting offset)[:：]?\s*(0x[0-9a-fA-F]+)') { $off = $Matches[1] }
    # 注意不能用 $pid:那是 PowerShell 自动变量,赋值会被忽略
    if ($m -match '(?:错误进程 ID|Faulting process id)[:：]?\s*(0x[0-9a-fA-F]+)') { $fpid = $Matches[1] }
    if ($m -match '(?:错误应用程序路径|Faulting application path)[:：]?\s*(.+)') { $app = $Matches[1].Trim() }
    $rows += [pscustomobject]@{ id=$id; time=$e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); code=$code; module=$mod; offset=$off; pid=$fpid; app=$app }
  }
}
if ($rows.Count -eq 0) { '[]' | Set-Content -LiteralPath $env:CLW_OUT -Encoding UTF8 }
else { $rows | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:CLW_OUT -Encoding UTF8 }
'''


def query_crash_events(start_dt, end_dt, names=None):
    """查 Windows 事件日志里这段时间内与游戏 exe 相关的崩溃事件(Id 1000/1001)。"""
    if platform.system() != "Windows":
        return []
    names = names or EXE_PREFIXES
    tmp_ps = os.path.join(tempfile.gettempdir(), "clw_query.ps1")
    tmp_out = os.path.join(tempfile.gettempdir(), "clw_query.json")
    # 必须 utf-8-sig:PowerShell 5.1 读无 BOM 的 .ps1 会按系统码页(GBK)解析,中文正则会失效
    with open(tmp_ps, "w", encoding="utf-8-sig") as f:
        f.write(_PS_QUERY)
    if os.path.exists(tmp_out):
        os.remove(tmp_out)
    env = dict(os.environ,
               CLW_START=start_dt.strftime("%Y-%m-%d %H:%M:%S"),
               CLW_END=end_dt.strftime("%Y-%m-%d %H:%M:%S"),
               CLW_NAMES=";".join(names), CLW_OUT=tmp_out)
    r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", tmp_ps], env=env, capture_output=True, timeout=120)
    if not os.path.exists(tmp_out):
        err = (r.stderr or b"").decode("utf-8", "replace").strip()[:300]
        log("事件查询未产出文件 rc=%d %s" % (r.returncode, err))
        return []
    raw = open(tmp_out, encoding="utf-8-sig").read().strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except Exception as e:
        log("事件查询 JSON 解析失败: %s" % e)
        return []
    return data if isinstance(data, list) else [data]


def _run_ps(script, extra_env=None, out_file=None, timeout=120):
    """跑一段 PowerShell(落成带 BOM 的 .ps1,避免中文被按 GBK 解析);返回输出文件内容。"""
    tmp_ps = os.path.join(tempfile.gettempdir(), "clw_%d.ps1" % abs(hash(script)))
    with open(tmp_ps, "w", encoding="utf-8-sig") as f:
        f.write(script)
    env = dict(os.environ, **(extra_env or {}))
    r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", tmp_ps],
                       env=env, capture_output=True, timeout=timeout)
    if out_file and os.path.isfile(out_file):
        raw = open(out_file, encoding="utf-8-sig").read().strip()
        if raw:
            try:
                return json.loads(raw)
            except Exception:
                return raw
    return (r.stdout or b"").decode("utf-8", "replace").strip()


# 免管理员的登录自启:启动文件夹里的快捷方式(ONLOGON 计划任务需要管理员,会「拒绝访问」)
_PS_LNK = r'''
$ErrorActionPreference = 'Stop'
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($env:CLW_LNK)
$lnk.TargetPath = $env:CLW_TARGET
$lnk.Arguments = $env:CLW_ARGS
$lnk.WorkingDirectory = $env:CLW_CWD
$lnk.WindowStyle = 7
$lnk.Description = 'Cyancular Ruins crashlog capture'
$lnk.Save()
'LNK-OK'
'''

_PS_PSLIST = r'''
$rows = @()
$rows += Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    $_.Name -like 'python*' -and
    $_.CommandLine -and
    $_.CommandLine -like '*crashlog_capture.py*watch*'
  } |
  ForEach-Object { [pscustomobject]@{ pid = $_.ProcessId; cmd = $_.CommandLine } }
if ($rows.Count -eq 0) { '[]' | Set-Content -LiteralPath $env:CLW_OUT -Encoding UTF8 }
else { $rows | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:CLW_OUT -Encoding UTF8 }
'''


def startup_lnk():
    if platform.system() != "Windows":
        return ""
    return os.path.join(os.environ.get("APPDATA", ""), "Microsoft", "Windows",
                        "Start Menu", "Programs", "Startup", "%s.lnk" % TASK_NAME)


def wmi_watcher_pids():
    """WMI 兜底:能发现没写 pid 文件的实例。注意 Get-CimInstance 会间歇性返回空,不可单独依赖。"""
    if platform.system() != "Windows":
        return []
    out = os.path.join(tempfile.gettempdir(), "clw_plist.json")
    if os.path.exists(out):
        os.remove(out)
    data = _run_ps(_PS_PSLIST, {"CLW_OUT": out}, out_file=out, timeout=60)
    if not isinstance(data, list):
        return []
    return [int(d["pid"]) for d in data if isinstance(d, dict) and "pid" in d]


def watcher_pids():
    """看守 pid:以 pid 文件为准(WMI 查询不稳),WMI 只用于兜底发现漏网实例。"""
    pids = set()
    try:
        pid = int(open(PIDFILE, encoding="utf-8").read().strip())
        procs = list_processes()
        if procs.get(pid, "").lower().startswith("python"):
            pids.add(pid)
        else:
            os.remove(PIDFILE)
    except (OSError, ValueError):
        pass
    try:
        pids.update(wmi_watcher_pids())
    except Exception:
        pass
    return sorted(pids)


# ---------------------------------------------------------------- 归档
def log_snapshot():
    d = godot_log_dir()
    snap = {}
    if os.path.isdir(d):
        for n in os.listdir(d):
            if n.endswith(".log"):
                p = os.path.join(d, n)
                try:
                    st = os.stat(p)
                    snap[p] = (st.st_size, int(st.st_mtime))
                except OSError:
                    pass
    return snap


def archive_run(run, crash_events):
    os.makedirs(ARCHIVE, exist_ok=True)
    stamp = run["started"].strftime("%Y%m%d_%H%M%S")
    exe_stem = os.path.splitext(run["exes"][0])[0][:40] if run["exes"] else "game"
    folder = os.path.join(ARCHIVE, "%s_%s" % (stamp, exe_stem))
    os.makedirs(folder, exist_ok=True)

    before = run["snapshot"]
    d = godot_log_dir()
    copied = []
    if os.path.isdir(d):
        for n in sorted(os.listdir(d)):
            if not n.endswith(".log"):
                continue
            p = os.path.join(d, n)
            try:
                st = os.stat(p)
            except OSError:
                continue
            # 只收这一轮动过/新出现的日志;godot.log 永远收(它就是当前这轮)
            if n != "godot.log" and before.get(p) == (st.st_size, int(st.st_mtime)):
                continue
            dst = os.path.join(folder, n)
            try:
                shutil.copy2(p, dst)
            except OSError as e:
                log("复制 %s 失败: %s" % (p, e))
                continue
            b = open(dst, "rb").read()
            copied.append({"name": n, "bytes": len(b),
                           "sha256": hashlib.sha256(b).hexdigest()[:16],
                           "ends_with_newline": b.endswith(b"\n") if b else None,
                           "possibly_truncated": bool(b) and not b.endswith(b"\n")})

    crash = None
    if crash_events:
        ev = crash_events[0]
        crash = {"detected": True, "event_id": ev.get("id"), "time": ev.get("time"),
                 "exception_code": ev.get("code"), "faulting_module": ev.get("module"),
                 "faulting_offset": ev.get("offset"), "faulting_pid": ev.get("pid"),
                 "app_path": ev.get("app"), "total_events": len(crash_events)}
    rec = {"exe": run["exes"], "started_at": run["started"].strftime("%Y-%m-%d %H:%M:%S"),
           "ended_at": now_str(), "duration_s": round(run["duration"], 1),
           "logs": copied, "crash": crash}
    with open(os.path.join(folder, "run.json"), "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False, indent=2)

    tag = "崩溃" if crash else "正常"
    log("%s | %s | %.1fs | 日志 %d 份%s" % (tag, ", ".join(run["exes"]), run["duration"],
        len(copied), (" | %s @ %s %s" % (crash["exception_code"], crash["faulting_module"],
                                         crash["faulting_offset"])) if crash else ""))
    prune_runs()
    return folder, rec


def prune_runs():
    """保留最近 KEEP_RUNS 轮(崩溃轮永不删)。"""
    dirs = []
    for n in os.listdir(ARCHIVE):
        p = os.path.join(ARCHIVE, n)
        if not os.path.isdir(p) or n.startswith("."):
            continue
        rj = os.path.join(p, "run.json")
        crashed = False
        if os.path.isfile(rj):
            try:
                crashed = bool(json.load(open(rj, encoding="utf-8")).get("crash"))
            except Exception:
                pass
        dirs.append((os.path.getmtime(p), p, crashed))
    dirs.sort(reverse=True)
    keep = 0
    for _, p, crashed in dirs:
        if crashed:
            continue
        keep += 1
        if keep > KEEP_RUNS:
            shutil.rmtree(p, ignore_errors=True)
            log("清理旧归档 %s" % os.path.basename(p))


# ---------------------------------------------------------------- watch
def watch(interval, duration):
    os.makedirs(ARCHIVE, exist_ok=True)
    with open(PIDFILE, "w", encoding="utf-8") as f:
        f.write(str(os.getpid()))
    log("看守启动: pid=%d 匹配进程前缀 %s;每 %.1fs 轮询" % (os.getpid(), EXE_PREFIXES, interval))
    start_all = time.time()
    active = None
    prev = {}
    try:
        while True:
            cur = matching_processes()
            if cur and not prev:
                active = {"started": datetime.datetime.now(), "snapshot": log_snapshot(),
                          "exes": sorted({n for n in cur.values()}), "duration": 0.0}
                log("检测到启动: %s (pid %s)" % (", ".join(active["exes"]), sorted(cur)))
            elif active and not cur:
                active["duration"] = (datetime.datetime.now() - active["started"]).total_seconds()
                # 等 Godot 落盘,再查这段时间的事件日志
                time.sleep(1.5)
                # 事件窗口从"启动前 15s"开始,容忍观察滞后
                s = active["started"] - datetime.timedelta(seconds=15)
                e = datetime.datetime.now() + datetime.timedelta(seconds=90)
                evs = query_crash_events(s, e, active["exes"])
                folder, rec = archive_run(active, evs)
                print("[%s] %s%s" % (now_str(), "崩溃: " if rec["crash"] else "正常: ",
                                     os.path.basename(folder)))
                active = None
            prev = cur
            if duration and (time.time() - start_all) > duration:
                log("看守到时退出(--duration %d)" % duration)
                if active:
                    log("注意: 退出时游戏仍在运行,这一轮未归档")
                return 0
            time.sleep(interval)
    finally:
        try:
            if os.path.isfile(PIDFILE) and open(PIDFILE, encoding="utf-8").read().strip() == str(os.getpid()):
                os.remove(PIDFILE)
        except OSError:
            pass
        log("看守退出: pid=%d" % os.getpid())


def cmd_watch(args):
    global EXE_PREFIXES
    if args.exe:
        EXE_PREFIXES = [s.strip() for s in args.exe.split(",") if s.strip()]
    return watch(args.interval, args.duration)


def cmd_status(args):
    pids = watcher_pids()
    print("看守进程: %s" % ("运行中 → pid %s" % pids if pids else "没在运行(用 start 启动 / install-task 设置登录自启)"))
    cur = matching_processes()
    print("游戏进程: %s" % ("在跑 → pid %s" % sorted(cur) if cur else "没在跑"))
    lnk = startup_lnk()
    print("登录自启: %s" % ("已设置 → %s" % lnk if lnk and os.path.isfile(lnk) else "未设置"))
    print("Godot 日志目录: %s" % godot_log_dir())
    print("归档目录: %s" % ARCHIVE)
    runs = sorted([n for n in os.listdir(ARCHIVE) if os.path.isdir(os.path.join(ARCHIVE, n))],
                  reverse=True) if os.path.isdir(ARCHIVE) else []
    print("已归档 %d 轮" % len(runs))
    if runs:
        print("最近一轮: %s" % runs[0])
    return 0


def cmd_start(args):
    if watcher_pids():
        print("看守已在运行,不重复启动。")
        return 0
    DETACHED_PROCESS, CREATE_NO_WINDOW = 0x00000008, 0x08000000
    subprocess.Popen([_pythonw(), os.path.abspath(__file__), "watch"],
                     cwd=REPO, creationflags=DETACHED_PROCESS | CREATE_NO_WINDOW, close_fds=True)
    # 解释器冷启动 + CIM 查询有延迟,重试几轮再下结论
    pids = []
    for _ in range(8):
        time.sleep(1.5)
        pids = watcher_pids()
        if pids:
            break
    if pids:
        print("看守已在后台启动(pythonw,无窗口)→ pid %s" % pids)
        log("start watcher pid=%s" % pids)
    else:
        print("启动命令已发出,但 12 秒内没查到看守进程;可手动跑 watch 看报错。")
    return 0


def cmd_stop(args):
    pids = watcher_pids()
    if not pids:
        print("看守没在运行。")
        return 0
    for p in pids:
        subprocess.run(["taskkill", "/F", "/PID", str(p)], capture_output=True)
    print("已停止 %d 个看守进程 %s" % (len(pids), pids))
    log("stop watcher pids=%s" % pids)
    return 0


def cmd_report(args):
    print("=" * 72)
    print("崩溃事件历史(Windows 应用程序日志,Id 1000/1001)")
    print("=" * 72)
    s = datetime.datetime.now() - datetime.timedelta(days=args.days)
    evs = query_crash_events(s, datetime.datetime.now() + datetime.timedelta(minutes=5))
    if not evs:
        print("  最近 %d 天没有与游戏相关的崩溃事件。" % args.days)
    for ev in evs[:40]:
        print("  %s  %s  偏移=%s  pid=%s  模块=%s" % (ev.get("time"), ev.get("code"),
                                                    ev.get("offset"), ev.get("pid"),
                                                    ev.get("module")))
    if len(evs) > 40:
        print("  … 共 %d 条" % len(evs))
    if evs:
        from collections import Counter
        cnt = Counter((e.get("code"), e.get("offset")) for e in evs)
        print()
        print("按签名聚合(异常代码 + 故障偏移量;同一偏移反复出现 = 同一个崩点):")
        for (code, off), n in cnt.most_common(10):
            print("  %-12s %-20s %3d 次" % (code or "?", off or "?", n))

    print()
    print("=" * 72)
    print("已归档的运行")
    print("=" * 72)
    if not os.path.isdir(ARCHIVE):
        print("  还没有归档。")
        return 0
    dirs = sorted([n for n in os.listdir(ARCHIVE) if os.path.isdir(os.path.join(ARCHIVE, n))],
                  reverse=True)
    if not dirs:
        print("  还没有归档。")
        return 0
    crash_dirs = []
    for n in dirs[:args.last]:
        rj = os.path.join(ARCHIVE, n, "run.json")
        if not os.path.isfile(rj):
            print("  %-46s (无 run.json)" % n)
            continue
        r = json.load(open(rj, encoding="utf-8"))
        c = r.get("crash")
        mark = "崩溃" if c else "正常"
        extra = ""
        if c:
            extra = "  %s @ %s %s" % (c.get("exception_code"), c.get("faulting_module"), c.get("faulting_offset"))
            crash_dirs.append(n)
        trunc = [l["name"] for l in r.get("logs", []) if l.get("possibly_truncated")]
        print("  %-46s %s  %5.1fs%s%s" % (n, mark, r.get("duration_s", 0), extra,
                                          ("  截断:" + ",".join(trunc)) if trunc else ""))
    print()
    print("合计 %d 轮归档,其中崩溃 %d 轮优先保留。" % (len(dirs), len(crash_dirs)))
    return 0


# ---------------------------------------------------------------- 计划任务
def _pythonw():
    c = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
    return c if os.path.isfile(c) else sys.executable


def cmd_install_task(args):
    if platform.system() != "Windows":
        die("登录自启目前只实现了 Windows(macOS 可自行加 launchd 项)")
    script = os.path.abspath(__file__)
    # 先试计划任务(更规范);ONLOGON 需要管理员,被拒则退回启动文件夹快捷方式
    tr = '"%s" "%s" watch' % (_pythonw(), script)
    r = subprocess.run(["schtasks", "/Create", "/TN", TASK_NAME, "/SC", "ONLOGON", "/TR", tr, "/F"],
                       capture_output=True)
    if r.returncode == 0:
        print((r.stdout or b"").decode("gbk", "replace").strip() or "已注册计划任务")
        print("自启方式: 计划任务 %s(登录时触发)" % TASK_NAME)
    else:
        lnk = startup_lnk()
        os.makedirs(os.path.dirname(lnk), exist_ok=True)
        res = _run_ps(_PS_LNK, {"CLW_LNK": lnk, "CLW_TARGET": _pythonw(), "CLW_ARGS": '"%s" watch' % script,
                                "CLW_CWD": REPO}, timeout=60)
        if "LNK-OK" not in str(res):
            die("两种自启方式都失败。计划任务报: %s\n快捷方式报: %s"
                % ((r.stderr or b"").decode("gbk", "replace").strip(), res))
        print("自启方式: 启动文件夹快捷方式(免管理员)→ %s" % lnk)
        print("(计划任务 ONLOGON 需要管理员权限,已自动改用此方式)")
    print("归档与日志: %s" % ARCHIVE)
    log("install-autostart: %s" % tr)
    cmd_start(args)


def cmd_uninstall_task(args):
    if platform.system() != "Windows":
        die("仅 Windows")
    removed = []
    r = subprocess.run(["schtasks", "/Delete", "/TN", TASK_NAME, "/F"], capture_output=True)
    if r.returncode == 0:
        removed.append("计划任务 %s" % TASK_NAME)
    lnk = startup_lnk()
    if lnk and os.path.isfile(lnk):
        try:
            os.remove(lnk)
            removed.append("启动快捷方式 %s" % lnk)
        except OSError as e:
            print("删快捷方式失败: %s" % e)
    cmd_stop(args)
    print("已移除自启: %s" % (", ".join(removed) if removed else "本来就没设置"))
    log("uninstall-autostart")


def cmd_selftest(args):
    ok = True
    print("1) 进程枚举:", end=" ")
    procs = list_processes()
    print("%d 个进程%s" % (len(procs), "" if procs else "  ← 失败"))
    ok = ok and bool(procs)
    print("2) Godot 日志目录:", godot_log_dir())
    snap = log_snapshot()
    print("   当前 %d 份 .log %s" % (len(snap), "(目录不存在)" if not os.path.isdir(godot_log_dir()) else ""))
    print("3) 崩溃事件查询(最近 %d 天):" % args.days, end=" ")
    evs = query_crash_events(datetime.datetime.now() - datetime.timedelta(days=args.days),
                             datetime.datetime.now() + datetime.timedelta(minutes=5))
    print("%d 条" % len(evs))
    for ev in evs[:3]:
        print("     %s %s 偏移=%s" % (ev.get("time"), ev.get("code"), ev.get("offset")))
    print("4) 匹配中的游戏进程:", matching_processes() or "无")
    print("\n自检%s" % ("通过" if ok else "有问题"))
    return 0 if ok else 1


def die(msg, code=2):
    print("错误: " + msg, file=sys.stderr)
    sys.exit(code)


def main():
    ap = argparse.ArgumentParser(description="每次游戏跑完自动归档日志 + 记录 Windows 崩溃事件")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("watch", help="后台看守"); p.add_argument("--interval", type=float, default=2.0)
    p.add_argument("--duration", type=int, default=0)
    p.add_argument("--exe", help="覆盖监视的进程名前缀(逗号分隔;默认 %s)" % ",".join(EXE_PREFIXES))
    p.set_defaults(func=cmd_watch)
    sub.add_parser("status", help="当前状态").set_defaults(func=cmd_status)
    p = sub.add_parser("report", help="汇总归档与崩溃历史")
    p.add_argument("--last", type=int, default=20); p.add_argument("--days", type=int, default=30)
    p.set_defaults(func=cmd_report)
    p = sub.add_parser("selftest", help="自检"); p.add_argument("--days", type=int, default=7)
    p.set_defaults(func=cmd_selftest)
    sub.add_parser("start", help="后台启动看守(无窗口)").set_defaults(func=cmd_start)
    sub.add_parser("stop", help="停止看守进程").set_defaults(func=cmd_stop)
    sub.add_parser("install-task", help="设置登录自启 + 立即启动").set_defaults(func=cmd_install_task)
    sub.add_parser("uninstall-task", help="移除自启并停止看守").set_defaults(func=cmd_uninstall_task)
    args = ap.parse_args()
    rc = args.func(args)
    sys.exit(rc if isinstance(rc, int) else 0)


if __name__ == "__main__":
    main()
