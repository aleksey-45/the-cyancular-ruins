/* make_launchers.c — 所有双击启动器的 C 实现(取代全部 .bat)。
 * 同一份源码按 MODE 宏编译出多个 exe;运行时从自身位置向上找 project.godot 推导仓库根;
 * Godot 解析:环境变量 GODOT_EXE → 常见安装路径 → PATH。零机器专属路径。
 * 文件名全英文(win/mac 合法);报告/控制台文案为中文(源码 UTF-8,/utf-8 编译)。
 *
 * 编译(在 vcvarsall x64 环境):
 *   cl /nologo /O2 /utf-8 /DMODE=1 /Fe:build_exe.exe tools\make_launchers.c
 * DevTools 三个 GUI 启动器再加 /link /SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef MODE
#error "define MODE (1..10)"
#endif

/* ── 小工具 ── */
static int file_exists(const char *p) {
    DWORD a = GetFileAttributesA(p);
    return a != INVALID_FILE_ATTRIBUTES;
}

static void repo_root(char *out, size_t cap) {
    char exe[MAX_PATH], drive[_MAX_DRIVE], dpath[_MAX_DIR], dir[MAX_PATH], probe[MAX_PATH];
    GetModuleFileNameA(NULL, exe, MAX_PATH);
    _splitpath(exe, drive, dpath, NULL, NULL);
    _makepath(dir, drive, dpath, NULL, NULL);
    for (int up = 0; up < 3; up++) {
        snprintf(probe, sizeof(probe), "%sproject.godot", dir);
        if (file_exists(probe)) { snprintf(out, cap, "%s", dir); return; }
        strcat_s(dir, MAX_PATH, "..\\");
    }
    snprintf(out, cap, "%s", dir);
}

static int resolve_godot(char *out, size_t cap, int console_pref) {
    const char *env = getenv("GODOT_EXE");
    if (env && file_exists(env)) { snprintf(out, cap, "%s", env); return 1; }
    const char *gui[] = {
        "C:\\Godot\\Godot_v4.7.1-stable_win64.exe",
        "D:\\Godot\\Godot_v4.7.1-stable_win64.exe",
        "C:\\Program Files\\Godot\\Godot_v4.7.1-stable_win64.exe",
    };
    const char *con[] = {
        "C:\\Godot\\Godot_v4.7.1-stable_win64_console.exe",
        "D:\\Godot\\Godot_v4.7.1-stable_win64_console.exe",
        "C:\\Program Files\\Godot\\Godot_v4.7.1-stable_win64_console.exe",
    };
    const char **first = console_pref ? con : gui;
    const char **second = console_pref ? gui : con;
    for (int i = 0; i < 3; i++) if (file_exists(first[i])) { snprintf(out, cap, "%s", first[i]); return 1; }
    for (int i = 0; i < 3; i++) if (file_exists(second[i])) { snprintf(out, cap, "%s", second[i]); return 1; }
    char found[MAX_PATH];
    if (SearchPathA(NULL, "Godot_v4.7.1-stable_win64_console.exe", NULL, MAX_PATH, found, NULL) ||
        SearchPathA(NULL, "Godot_v4.7.1-stable_win64.exe", NULL, MAX_PATH, found, NULL) ||
        SearchPathA(NULL, "godot.exe", NULL, MAX_PATH, found, NULL)) {
        snprintf(out, cap, "%s", found); return 1;
    }
    return 0;
}

static int run_wait(const char *exe, const char *args, const char *cwd) {
    char cmd[8192];
    snprintf(cmd, sizeof(cmd), "\"%s\" %s", exe, args);
    STARTUPINFOA si; PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si)); ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, cwd, &si, &pi)) {
        printf("[ERROR] 启动失败: %s\n  命令: %s\n", exe, cmd);
        return -1;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return (int)code;
}

static void pause_key(void) {
    printf("\n按回车键关闭窗口... ");
    getchar();
}

static void console_init(void) {
    SetConsoleOutputCP(65001);
}

/* ── 各模式 ── */

#if MODE == MODE_BUILD
/* build_exe.exe(根目录):打包客户端+专用服务器,旧包归档 historyexe */
static int find_newest(const char *dir, const char *pattern, char *out, size_t cap) {
    char pat[MAX_PATH];
    snprintf(pat, sizeof(pat), "%s\\%s", dir, pattern);
    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) return 0;
    FILETIME bt = fd.ftLastWriteTime;
    char best[MAX_PATH];
    lstrcpyA(best, fd.cFileName);
    while (FindNextFileA(h, &fd)) {
        if (CompareFileTime(&fd.ftLastWriteTime, &bt) > 0) {
            bt = fd.ftLastWriteTime;
            lstrcpyA(best, fd.cFileName);
        }
    }
    FindClose(h);
    snprintf(out, cap, "%s\\%s", dir, best);
    return 1;
}

static int do_build(const char *repo, const char *godot) {
    char branch[128], stamp[40];
    read_branch(branch, sizeof(branch), repo);
    SYSTEMTIME st; GetLocalTime(&st);
    snprintf(stamp, sizeof(stamp), "%04d%02d%02d_%02d%02d", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute);

    char hist[MAX_PATH], out[MAX_PATH], srv[MAX_PATH], srvarc[MAX_PATH];
    snprintf(hist,   sizeof(hist),   "%s\\..\\historyexe", repo);
    snprintf(out,    sizeof(out),    "%s\\The Cyancular Ruins_%s_%s.exe", repo, branch, stamp);
    snprintf(srv,    sizeof(srv),    "%s\\Cyancular Ruins Server.exe", repo);
    snprintf(srvarc, sizeof(srvarc), "%s\\Cyancular Ruins Server_%s_%s.exe", hist, branch, stamp);

    printf("打包客户端: %s\n", out);
    printf("打包服务器: %s\n", srv);

    /* 归档旧包(根目录只保留最新一对) */
    char pattern[MAX_PATH], from[MAX_PATH], to[MAX_PATH];
    CreateDirectoryA(hist, NULL);
    snprintf(pattern, MAX_PATH, "%s\\The Cyancular Ruins_*.exe", repo);
    {
        WIN32_FIND_DATAA fd;
        HANDLE h = FindFirstFileA(pattern, &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
                snprintf(from, MAX_PATH, "%s\\%s", repo, fd.cFileName);
                snprintf(to,   MAX_PATH, "%s\\%s", hist, fd.cFileName);
                MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING);
            } while (FindNextFileA(h, &fd));
            FindClose(h);
        }
    }
    snprintf(pattern, MAX_PATH, "%s\\Cyancular Ruins Server*.exe", repo);
    {
        WIN32_FIND_DATAA fd;
        HANDLE h = FindFirstFileA(pattern, &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
                snprintf(from, MAX_PATH, "%s\\%s", repo, fd.cFileName);
                snprintf(to,   MAX_PATH, "%s\\%s", hist, fd.cFileName);
                MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING);
            } while (FindNextFileA(h, &fd));
            FindClose(h);
        }
    }

    /* 导出客户端(失败即停) */
    char args[2048];
    snprintf(args, sizeof(args),
        "--headless --path \"%s\" --export-release \"Windows Desktop\" \"%s\"", repo, out);
    printf("正在导出客户端...\n");
    if (run_wait(godot, args, repo) != 0) {
        printf("客户端打包失败!常见原因:游戏正在运行 / 预设名不对。\n");
        pause_key(); return 1;
    }

    /* 导出专用服务器(同一分支,与客户端同内容) */
    printf("正在导出服务器...\n");
    snprintf(args, sizeof(args),
        "--headless --path \"%s\" --export-release \"Dedicated Server\" \"%s\"", repo, srv);
    if (run_wait(godot, args, repo) != 0) {
        printf("服务器打包失败!常见原因:服务器 exe 正在运行 / 预设名不对。\n");
        pause_key(); return 1;
    }

    /* 服务器版本化副本进历史目录 */
    snprintf(from2 := 0 ? NULL : NULL, 0, ""); /* placeholder removed below */
    {
        char cpfrom[MAX_PATH], cpto[MAX_PATH];
        snprintf(cpfrom, MAX_PATH, "%s", srv);
        snprintf(cpto,   MAX_PATH, "%s\\%s", hist, srvarc);
        CopyFileA(cpfrom, cpto, FALSE);
    }

    printf("\n完成。\n  客户端: %s\n  服务端: %s(版本副本已归档)\n旧包已移至: %s\n", out, srv, hist);
    printf("提示:游戏大厅页有「启动/重启本机服务器」按钮。\n");
    pause_key();
    return 0;
}
#elif MODE == MODE_SERVER
int main(void) {
    console_init();
    char repo[MAX_PATH], godot[MAX_PATH], args[1024];
    repo_root(repo, sizeof(repo));
    if (!resolve_godot(godot, sizeof(godot), 1)) {
        printf("[ERROR] 未找到 Godot。请设置 GODOT_EXE。\n");
        pause_key(); return 1;
    }
    printf("本机服务器启动中(关闭服务器进程即结束)...\n");
    snprintf(args, sizeof(args), "--headless --path \"%s\" res://server/server_main.tscn", repo);
    int rc = run_wait(godot, args, repo);
    printf("服务器已退出(退出码 %d)。\n", rc);
    pause_key();
    return rc;
}
#elif MODE == MODE_LOGGED_GAME || MODE == MODE_LOGGED_SRV
int main(int argc, char **argv) {
    console_init();
    char repo[MAX_PATH];
    repo_root(repo, sizeof(repo));
    char ps[MAX_PATH];
    snprintf(ps, sizeof(ps), "%s\\tools\\gamelog\\capture_session.ps1", repo);
    if (!file_exists(ps)) {
        printf("[ERROR] 找不到 capture_session.ps1(请与本 exe 一起放置)\n");
        pause_key(); return 1;
    }
    char target[8];
#if MODE == MODE_LOGGED_GAME
    strcpy(target, "game");
#else
    strcpy(target, "server");
#endif
    /* argv[1](可选)= 指定要运行的游戏 exe(拖拽/参数) */
    char args[4096];
    snprintf(args, sizeof(args),
        "-NoProfile -ExecutionPolicy Bypass -File \"%s\" -Target %s", ps, target);
    if (argc > 1) {
        strncat(args, " -ExeOverride \"", sizeof(args) - strlen(args) - 1);
        strncat(args, argv[1], sizeof(args) - strlen(args) - 1);
        strncat(args, "\"", sizeof(args) - strlen(args) - 1);
    }
    char pw[260];
    if (!SearchPathA(NULL, "powershell.exe", NULL, sizeof(pw), pw, NULL)) {
        strcpy(pw, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    }
    char cmd[8192];
    snprintf(cmd, sizeof(cmd), "\"%s\" %s", pw, args);
    STARTUPINFOA si; PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si)); ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, repo, &si, &pi)) {
        printf("[ERROR] 启动 PowerShell 失败。\n");
        pause_key(); return 1;
    }
    WaitForSingleObject(pi.hProcess, INFINITE);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    pause_key();
    return 0;
}
#elif MODE == MODE_WATCH_START || MODE == MODE_WATCH_STOP || MODE == MODE_WATCH_REPORT
int main(int argc, char **argv) {
    console_init();
    char repo[MAX_PATH], py[260];
    repo_root(repo, sizeof(repo));
    if (!SearchPathA(NULL, "python.exe", NULL, sizeof(py), py, NULL) &&
        !SearchPathA(NULL, "py.exe", NULL, sizeof(py), py, NULL)) {
        printf("[ERROR] 未找到 Python(需要 3.x 运行看守脚本)\n");
        pause_key(); return 1;
    }
    char script[MAX_PATH];
    snprintf(script, sizeof(script), "%s\\tools\\crashlog_capture.py", repo);
    char args[512];
#if MODE == MODE_WATCH_START
    snprintf(args, sizeof(args), "\"%s\" start", script);
    printf("后台看守启动中...\n");
#elif MODE == MODE_WATCH_STOP
    snprintf(args, sizeof(args), "\"%s\" stop", script);
#else
    snprintf(args, sizeof(args), "\"%s\" report --last 20", script);
#endif
    int rc = run_wait(py, args, repo);
#if MODE == MODE_WATCH_START || MODE == MODE_WATCH_REPORT
    printf("完成。关闭本窗口不影响后台看守。\n");
#endif
    pause_key();
    return rc;
}
#endif

int main(void) {
    console_init();
#if MODE == MODE_BUILD
    char repo[MAX_PATH], godot[MAX_PATH];
    repo_root(repo, sizeof(repo));
    if (!resolve_godot(godot, sizeof(godot), 1)) {
        printf("[ERROR] 未找到 Godot。请设置环境变量 GODOT_EXE。\n");
        pause_key(); return 1;
    }
    return do_build(repo, godot);
#elif MODE == MODE_SERVER
    char repo[MAX_PATH], godot[MAX_PATH], args[1024];
    repo_root(repo, sizeof(repo));
    if (!resolve_godot(godot, sizeof(godot), 1)) {
        printf("[ERROR] 未找到 Godot。\n"); pause_key(); return 1;
    }
    snprintf(args, sizeof(args), "--headless --path \"%s\" res://server/server_main.tscn", repo);
    int rc = run_wait(godot, args, repo);
    printf("服务器已退出(退出码 %d)。\n", rc);
    pause_key(); return rc;
#elif MODE == MODE_LOGGED_GAME || MODE == MODE_LOGGED_SRV
    char repo[MAX_PATH];
    repo_root(repo, sizeof(repo));
    char ps_path[MAX_PATH];
    snprintf(ps_path, sizeof(ps_path), "%stools\\gamelog\\capture_session.ps1", repo);
    char pw[260];
    if (!SearchPathA(NULL, "powershell.exe", NULL, sizeof(pw), pw, NULL))
        lstrcpyA(pw, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    char target[16];
#if MODE == MODE_LOGGED_GAME
    strcpy(target, "game");
#else
    strcpy(target, "server");
#endif
    /* 组装:调用 ps1 引擎;可选 argv[1]=自定义游戏 exe(拖拽支持) */
    char cmdline[8192];
    snprintf(cmdline, sizeof(cmdline),
        "\"%s\" -NoProfile -ExecutionPolicy Bypass -File \"%stools\\gamelog\\capture_session.ps1\" -Target %s",
        pw, ps_path_dir, target);
    ...
#endif
}
