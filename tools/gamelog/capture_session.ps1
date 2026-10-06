# ============================================================================
# capture_session.ps1 - Game process session logger (report content: Chinese)
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File capture_session.ps1 `
#       -Target game            [-ExeOverride <exe>] [-ExeArgs "<args>"]
#   powershell -NoProfile -ExecutionPolicy Bypass -File capture_session.ps1 `
#       -Target server          [-ExeOverride <exe>] [-ExeArgs "<args>"]
#   ... -QuickTest   (headless 90-frame run, for automated verification)
# Output: gamelogs/<yyyyMMdd_HHmmss>_<game|server>/  with stdout.log / stderr.log /
#         report.txt (Chinese, human readable: start/end/duration/exit reason/issues)
# ============================================================================
param(
    [string]$Target = "game",
    [string]$ExeOverride = "",
    [string]$ExeArgs = "",
    [switch]$QuickTest
)

$ErrorActionPreference = "Continue"
# repo root = two levels up from this script (tools/gamelog)
$repo = (Get-Item (Join-Path $PSScriptRoot "..\..")).FullName
# ---- resolve Godot (portable): env GODOT_EXE -> common paths -> PATH ----
$godot = $env:GODOT_EXE
if (-not $godot -or -not (Test-Path $godot)) {
    $godot = @(
        "C:\Godot\Godot_v4.7.1-stable_win64_console.exe",
        "C:\Godot\Godot_v4.7.1-stable_win64.exe",
        "$env:LOCALAPPDATA\Programs\Godot\Godot_v4.7.1-stable_win64_console.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $godot) {
        $cmd = Get-Command godot -ErrorAction SilentlyContinue
        if ($cmd) { $godot = $cmd.Source }
    }
}
if (-not $godot) {
    Write-Host "[ERROR] Godot not found. Set environment variable GODOT_EXE to your Godot exe."
}

# ---- resolve exe + args -----------------------------------------------------
$exe = ""
$argList = ""
$label = "game"
$fallbackNote = ""

if ($ExeOverride -ne "") {
    $exe = $ExeOverride
    $argList = $ExeArgs
    if ($Target -ne "server") { $Target = "game" }
} elseif ($QuickTest) {
    $exe = $godot
    $argList = "--headless --path `"$repo`" --quit-after 90"
    $fallbackNote = "QuickTest: headless 90 帧自动验证运行"
} elseif ($Target -eq "server") {
    $label = "server"
    $latest = Get-ChildItem -Path $repo -Filter "Cyancular Ruins Server*.exe" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest -ne $null) {
        $exe = $latest.FullName
    } elseif (Test-Path $godot) {
        $exe = $godot
        $argList = "--headless --path `"$repo`" res://server/server_main.tscn"
        $fallbackNote = "未找到服务器 exe,已回退为用 Godot 运行工程内服务端"
    }
} else {
    $latest = Get-ChildItem -Path $repo -Filter "The Cyancular Ruins_*.exe" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest -ne $null) {
        $exe = $latest.FullName
    } elseif (Test-Path $godot) {
        $exe = $godot
        $argList = "--path `"$repo`""
        $fallbackNote = "未找到游戏 exe,已回退为用 Godot 运行工程(主菜单)"
    }
}

# ---- session directory ------------------------------------------------------
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$dir = Join-Path $repo ("gamelogs\" + $stamp + "_" + $label)
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$outLog = Join-Path $dir "stdout.log"
$errLog = Join-Path $dir "stderr.log"
$report = Join-Path $dir "report.txt"

Write-Host "==============================================" 
Write-Host " 日志记录器:本次运行将被完整记录" 
Write-Host " 会话目录: $dir" 
Write-Host " 启动: $exe $argList" 
Write-Host " (关闭游戏窗口后,自动生成中文报告 report.txt)" 
Write-Host "==============================================" 

# ---- run --------------------------------------------------------------------
$start = Get-Date
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$exitCode = $null
$launchError = ""
try {
    if ($argList -ne "") {
        $p = Start-Process -FilePath $exe -ArgumentList $argList `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
            -WorkingDirectory $repo -PassThru
    } else {
        $p = Start-Process -FilePath $exe `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
            -WorkingDirectory $repo -PassThru
    }
    if ($p -ne $null) {
        $null = $p.Handle   # 先取句柄:否则 WaitForExit 后 ExitCode 为 null(PS 已知行为)
        $p.WaitForExit()
        $exitCode = $p.ExitCode
    }
} catch {
    $launchError = $_.Exception.Message
}
$sw.Stop()
$end = Get-Date

# ---- classify exit ----------------------------------------------------------
$verdict = ""
$verdictKind = "ok"   # ok / warn / crash
if ($launchError -ne "") {
    $verdictKind = "crash"
    $verdict = "[X] 未能启动进程:$launchError"
} elseif ($exitCode -eq $null) {
    $verdictKind = "warn"
    $verdict = "[!] 无法获取退出码(进程可能被外部终止)"
} elseif ($exitCode -eq 0) {
    $verdict = "[OK] 正常退出:退出码 0 —— 游戏自己关闭,没有崩溃。"
} else {
    $hex = "0x{0:X8}" -f ($exitCode -band 0xFFFFFFFF)
    $crashMap = @{
        "0xC0000005" = "内存访问冲突(最常见的闪退原因,即段错误)"
        "0xC0000409" = "栈缓冲区溢出保护触发"
        "0x80000003" = "断点异常(调试中断)"
        "0xC0000135" = "缺少运行所需的 DLL 文件"
        "0xC0000142" = "DLL 初始化失败"
    }
    if ($crashMap.ContainsKey($hex)) {
        $verdictKind = "crash"
        $verdict = "[X] 崩溃:退出码 $exitCode ($hex) = " + $crashMap[$hex]
    } elseif ($hex.StartsWith("C000") -or $hex.StartsWith("8000")) {
        $verdictKind = "crash"
        $verdict = "[X] 崩溃:退出码 $exitCode ($hex)= Windows 异常(闪退)。"
    } else {
        $verdictKind = "warn"
        $verdict = "[!] 异常退出:退出码 $exitCode ($hex) —— 程序遇到错误后自行结束。"
    }
    # Windows Event Log: faulting module (App crash Id 1000 / WER 1001)
    try {
        $exeName = Split-Path -Leaf $exe
        $evt = Get-WinEvent -FilterHashtable @{LogName = "Application"; Id = 1000, 1001; StartTime = $start.AddSeconds(-2) } `
            -MaxEvents 8 -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -like "*$exeName*" } | Select-Object -First 1
        if ($evt -ne $null) {
            $verdict += "`n   Windows 事件日志记录到本次崩溃,故障应用/模块详情见事件查看器(时间 $([string]::Format('{0:yyyy-MM-dd HH:mm:ss}', $evt.TimeCreated)))。"
        }
    } catch { }
}

# ---- error line extraction ---------------------------------------------------
$script:issues = New-Object System.Collections.Generic.List[string]
function Add-Issues([string]$file, [string]$tagName) {
    if (-not (Test-Path $file)) { return }
    $lines = [System.IO.File]::ReadAllLines($file)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $ln = $lines[$i]
        if ($ln -match "SCRIPT ERROR|Parse Error|ERROR:|Failed to load|Failed loading|Unable to|Cannot open|Exception") {
            $cat = "其他错误"
            $why = "需要开发者结合上下文判断"
            if ($ln -match "SCRIPT ERROR|Parse Error") {
                $cat = "脚本错误"; $why = "游戏逻辑代码(GDScript)运行出错:多为空引用/逻辑/语法问题"
            } elseif ($ln -match "ENet|enet|socket|channel|Network|peer") {
                $cat = "网络错误"; $why = "联网通讯报错:检查端口/防火墙,单机游玩可忽略"
            } elseif ($ln -match "Vulkan|D3D|RenderingDevice|OpenGL|driver") {
                $cat = "渲染相关"; $why = "显卡/渲染层报错:偶发一两条可忽略,频繁出现需更新显卡驱动"
            } elseif ($ln -match "Failed to load|Cannot open|Failed loading|missing") {
                $cat = "资源缺失"; $why = "文件/资源加载失败:可能打包遗漏或路径不对"
            }
            $script:issues.Add(("[{0}] {1} 第 {2} 行: {3}" -f $cat, $tagName, ($i + 1), $ln.Trim()))
            if ($script:issues.Count -ge 60) { return }
            # 附带一行堆栈上下文
            if ($i + 1 -lt $lines.Length -and $lines[$i + 1] -match "^\s+at:") {
                $script:issues.Add("           " + $lines[$i + 1].Trim())
            }
        }
    }
}
Add-Issues $errLog "stderr"
Add-Issues $outLog "stdout"

# ---- report ------------------------------------------------------------------
$FMT = "{0:yyyy-MM-dd HH:mm:ss}"
$durationTxt = "{0}小时{1}分{2}秒" -f [int][math]::Floor($sw.Elapsed.TotalHours), $sw.Elapsed.Minutes, $sw.Elapsed.Seconds
$sr = ""
$sr += "==================================================`r`n"
$sr += " 游戏运行日志报告(由日志记录器自动生成)`r`n"
$sr += "==================================================`r`n`r`n"
$sr += "【怎么读这份报告】`r`n"
$sr += " 1. 先看下面的「退出结论」: [OK]=正常; [!]=有异常但程序自己结束了; [X]=崩溃(闪退);`r`n"
$sr += " 2. 再看「问题清单」: 自动从日志中挑出的报错行,每条已归类并附中文解释;`r`n"
$sr += " 3. 向开发者反馈问题时: 把本文件夹整个压缩发过去(内有 stdout/stderr 原始日志)。`r`n`r`n"
$sr += "【本次运行信息】`r`n"
$sr += " 运行类型: $(if ($Target -eq 'server') { '专用服务器(server)' } else { '游戏客户端(game)' })`r`n"
$sr += " 启动程序: $exe`r`n"
if ($argList -ne "") { $sr += " 启动参数: $argList`r`n" }
if ($fallbackNote -ne "") { $sr += " 备注: $fallbackNote`r`n" }
$sr += " 启动时间: " + ($FMT -f $start) + "`r`n"
$sr += " 结束时间: " + ($FMT -f $end) + "`r`n"
$sr += " 运行时长: $durationTxt($([int]$sw.Elapsed.TotalSeconds) 秒)`r`n`r`n"
$sr += "【退出结论】`r`n"
$sr += " " + $verdict + "`r`n`r`n"
$sr += "【问题清单】(自动抽取,共 $($issues.Count) 条;完整原文见 stderr.log / stdout.log)`r`n"
if ($issues.Count -eq 0) {
    $sr += " (无报错行 —— 本次运行日志干净)`r`n"
} else {
    foreach ($s in $issues) { $sr += " " + $s + "`r`n" }
}
$sr += "`r`n【文件清单】`r`n"
$sr += " stdout.log(正常输出)/ stderr.log(错误输出)/ report.txt(本文件)`r`n"
[System.IO.File]::WriteAllText($report, $sr, (New-Object System.Text.UTF8Encoding $true))

Write-Host "==============================================="
Write-Host " 报告已生成: $report"
Write-Host " " $verdict
Write-Host "==============================================="
