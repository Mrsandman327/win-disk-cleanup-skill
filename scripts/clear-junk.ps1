<#
.SYNOPSIS
    按内置白名单清理 Windows 系统盘垃圾文件（默认 dry-run）。

.DESCRIPTION
    只清「可安全删除」这一档：临时文件、崩溃转储、各类工具缓存、系统日志、更新包缓存。
    受保护路径（WinSxS / Windows\Installer / Package Cache / 用户数据）不在白名单内，
    脚本不会触碰。

    默认 dry-run，只列清单不删除；必须显式加 -Execute 才真正删除。

    删除方式是「清空目录内容、保留目录本身」，避免某些程序因目录缺失报错。
    占用中的文件会被跳过并计入失败数，不影响其余项目。

.PARAMETER Execute
    真正执行删除。不加此参数只做 dry-run。

.PARAMETER NoElevate
    不提权，按当前权限运行（系统级路径会大量失败，仅用于自检）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File clear-junk.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File clear-junk.ps1 -Execute
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$NoElevate,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'

# 默认日志路径：技能目录下的 output\（不写系统盘 C:）
if (-not $LogFile) {
    $LogFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\c_junk_clear.txt'
}
$logFile = $LogFile
$lines = New-Object 'System.Collections.Generic.List[string]'
function Add-Line { param([string]$Text) $lines.Add($Text) }
function Fmt-MB { param($Bytes) '{0,9:N1} MB' -f ([double]$Bytes / 1MB) }

function Measure-Path {
    param([string]$Path)
    $total = [double]0
    $stack = New-Object 'System.Collections.Stack'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
                try { $total += (New-Object System.IO.FileInfo $f).Length } catch { }
            }
        } catch { }
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) }
        } catch { }
    }
    return $total
}

$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $NoElevate) {
    Write-Host '需要管理员权限，正在提权（请在 UAC 窗口点「是」）...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-LogFile', "`"$logFile`"")
    if ($Execute) { $argList += '-Execute' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList $argList
    } catch {
        Write-Host ('提权失败或被取消: ' + $_.Exception.Message)
        exit 1
    }
    if (Test-Path -LiteralPath $logFile) { Write-Host ('Log: ' + $logFile) }
    exit
}

# ---------------------------------------------------------------- 白名单
$targets = @(
    @{ Name = '用户临时文件';     Path = (Join-Path $env:LOCALAPPDATA 'Temp') }
    @{ Name = '系统临时文件';     Path = 'C:\Windows\Temp' }
    @{ Name = '传递优化缓存';     Path = 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization' }
    @{ Name = 'Windows 更新缓存'; Path = 'C:\Windows\SoftwareDistribution\Download' }
    @{ Name = '崩溃转储';         Path = (Join-Path $env:LOCALAPPDATA 'CrashDumps') }
    @{ Name = 'pip 缓存';         Path = (Join-Path $env:LOCALAPPDATA 'pip\Cache') }
    @{ Name = 'goimports 缓存';   Path = (Join-Path $env:LOCALAPPDATA 'goimports') }
    @{ Name = 'gopls 缓存';       Path = (Join-Path $env:LOCALAPPDATA 'gopls') }
    @{ Name = 'VS Code Cache';    Path = (Join-Path $env:APPDATA 'Code\Cache') }
    @{ Name = 'VS Code CachedData'; Path = (Join-Path $env:APPDATA 'Code\CachedData') }
    @{ Name = 'VS Code GPUCache'; Path = (Join-Path $env:APPDATA 'Code\GPUCache') }
    @{ Name = 'CBS 组件日志';     Path = 'C:\Windows\Logs\CBS' }
    @{ Name = 'DISM 日志';        Path = 'C:\Windows\Logs\DISM' }
    @{ Name = 'WER 报告队列';     Path = 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue' }
    @{ Name = 'WER 报告归档';     Path = 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive' }
)

# 安全检查：路径形态不对就整条跳过
$blocked = 'C:\Windows\WinSxS', 'C:\Windows\Installer', 'C:\ProgramData\Package Cache', 'C:\Windows\System32', 'C:\Windows\SysWOW64'

Add-Line ('执行时间 : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ('模式     : ' + $(if ($Execute) { 'EXECUTE（真正删除）' } else { 'DRY-RUN（仅列出）' }))
Add-Line ''

$grandTotal = [double]0
$failTotal = 0

foreach ($t in $targets) {
    $path = $t.Path
    $label = $t.Name

    if (-not $path -or $path.Length -lt 10 -or $path -match '^[A-Za-z]:\\?$') {
        Add-Line ('跳过（路径异常）: {0}  {1}' -f $label, $path); continue
    }
    $isBlocked = $false
    foreach ($b in $blocked) { if ($path.TrimEnd('\') -like ($b + '*')) { $isBlocked = $true } }
    if ($isBlocked) { Add-Line ('跳过（受保护）: {0}' -f $path); continue }

    if (-not [System.IO.Directory]::Exists($path)) {
        Add-Line ('不存在: {0}' -f $label); continue
    }

    $children = @()
    try { $children = @([System.IO.Directory]::EnumerateFileSystemEntries($path)) } catch {
        Add-Line ('无权限: {0}' -f $label); continue
    }

    $freed = [double]0
    $fail = 0
    foreach ($c in $children) {
        $sz = Measure-Path $c
        if ($Execute) {
            try {
                if ([System.IO.Directory]::Exists($c)) {
                    Remove-Item -LiteralPath $c -Recurse -Force -ErrorAction Stop
                } else {
                    Remove-Item -LiteralPath $c -Force -ErrorAction Stop
                }
                $freed += $sz
            } catch {
                $fail++
            }
        } else {
            $freed += $sz
        }
    }

    $grandTotal += $freed
    $failTotal += $fail
    $verb = if ($Execute) { '已清理' } else { '预计释放' }
    Add-Line ('{0} {1}  {2}  ({3} 项)' -f $verb, (Fmt-MB $freed), $label, $children.Count)
    if ($fail -gt 0) { Add-Line ('      跳过 {0} 个占用中/无法删除的项' -f $fail) }
}

Add-Line ''
if ($Execute) {
    Add-Line ('合计释放 : {0}' -f (Fmt-MB $grandTotal))
} else {
    Add-Line ('合计可释放 : {0}' -f (Fmt-MB $grandTotal))
}
Add-Line ('失败项   : {0}' -f $failTotal)

try {
    $outDir = Split-Path -Path $logFile -Parent
    if ($outDir -and -not [System.IO.Directory]::Exists($outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $lines | Set-Content -LiteralPath $logFile -Encoding UTF8
} catch { }

$lines | ForEach-Object { Write-Host $_ }
Write-Host ('Log: ' + $logFile)
Write-Host ('Freed: {0:N2} GB' -f ($grandTotal / 1GB))
