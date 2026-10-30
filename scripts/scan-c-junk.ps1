<#
.SYNOPSIS
    Windows 系统盘（C:）垃圾文件只读扫描，按「可安全删除 / 会重建 / 禁止删除」三级输出报告。

.DESCRIPTION
    只读：仅统计目录与文件大小，不删除、不移动、不修改任何文件。

    非管理员运行时自动请求提权；加 -NoElevate 则原地运行，受保护路径标记为「无权限」。

.PARAMETER OutFile
    报告输出路径，默认 <技能目录>\output\c_junk_scan.txt（不写系统盘 C:）。
    默认值在「提权之前的父进程」里解析成绝对路径再传给提权子进程，
    因此提权后也不会把文件写进管理员的 %TEMP% 或 C:\ProgramData。

.PARAMETER NoElevate
    不提权，按当前权限运行。

.PARAMETER TopN
    用户级目录排名显示前 N 项，默认 15。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scan-c-junk.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scan-c-junk.ps1 -NoElevate -OutFile "$env:TEMP\scan.txt"
#>
[CmdletBinding()]
param(
    [string]$OutFile = '',
    [switch]$NoElevate,
    [int]$TopN = 15
)

$ErrorActionPreference = 'SilentlyContinue'

# 默认报告路径：技能目录下的 output\（不写系统盘 C:）
if (-not $OutFile) {
    $OutFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'output\c_junk_scan.txt'
}

$lines = New-Object 'System.Collections.Generic.List[string]'
function Add-Line { param([string]$Text) $lines.Add($Text) }
function Fmt-MB { param($Bytes) if ($null -eq $Bytes) { '    n/a' } else { '{0,9:N1} MB' -f ([double]$Bytes / 1MB) } }

# ---------------------------------------------------------------- 大小测量
# 用 .NET 枚举，跳过 reparse point（junction / 符号链接），避免 C:\Users 被重复统计
function Measure-Dir {
    param([string]$Path)

    if (-not [System.IO.Directory]::Exists($Path)) {
        return [pscustomobject]@{ Size = $null; Status = 'missing' }
    }
    try {
        foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries($Path)) { break }
    } catch {
        return [pscustomobject]@{ Size = $null; Status = 'denied' }
    }

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
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($dir)) {
                try {
                    $attrs = [System.IO.File]::GetAttributes($d)
                    if (-not ($attrs -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($d) }
                } catch { }
            }
        } catch { }
    }
    return [pscustomobject]@{ Size = $total; Status = 'ok' }
}

function Measure-File {
    param([string]$Path)
    try {
        if (-not [System.IO.File]::Exists($Path)) { return $null }
        return [double](New-Object System.IO.FileInfo $Path).Length
    } catch { return $null }
}

# ---------------------------------------------------------------- 提权
$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and -not $NoElevate) {
    Write-Host '需要管理员权限，正在提权（请在 UAC 窗口点「是」）...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-OutFile', "`"$OutFile`"", '-TopN', [string]$TopN)
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList $argList
    } catch {
        Write-Host ("提权失败或被取消: " + $_.Exception.Message)
        Write-Host '可改用管理员终端手动执行，或加 -NoElevate 只扫用户级路径。'
        exit 1
    }
    if (Test-Path -LiteralPath $OutFile) {
        Write-Host ('Report: ' + $OutFile)
    } else {
        Write-Host '提权进程未生成报告（UAC 可能被取消）。'
    }
    exit
}

# ---------------------------------------------------------------- 报告头
Add-Line ('扫描时间    : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ('主机        : ' + $env:COMPUTERNAME + ' / ' + $env:USERNAME)
Add-Line ('权限        : ' + $(if ($isAdmin) { '管理员（受保护路径可读）' } else { '普通用户（部分路径标为无权限）' }))
Add-Line ''
Add-Line '===== 磁盘概况 ====='
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    Add-Line ('  {0} 总 {1,7:N0} GB / 可用 {2,7:N0} GB / 已用 {3,7:N0} GB' -f `
        $_.DeviceID, ($_.Size / 1GB), ($_.FreeSpace / 1GB), (($_.Size - $_.FreeSpace) / 1GB))
}

# ---------------------------------------------------------------- 分类清单
$safe = @(
    @{ Name = '用户临时文件 Temp';        Path = (Join-Path $env:LOCALAPPDATA 'Temp') }
    @{ Name = '系统临时文件 Windows\Temp'; Path = 'C:\Windows\Temp' }
    @{ Name = '传递优化缓存 (P2P)';        Path = 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization' }
    @{ Name = 'Windows 更新包缓存';        Path = 'C:\Windows\SoftwareDistribution\Download' }
    @{ Name = '程序崩溃转储 CrashDumps';   Path = (Join-Path $env:LOCALAPPDATA 'CrashDumps') }
    @{ Name = 'pip 下载缓存';              Path = (Join-Path $env:LOCALAPPDATA 'pip\Cache') }
    @{ Name = 'goimports 索引缓存';        Path = (Join-Path $env:LOCALAPPDATA 'goimports') }
    @{ Name = 'gopls 缓存';                Path = (Join-Path $env:LOCALAPPDATA 'gopls') }
    @{ Name = 'VS Code Cache';             Path = (Join-Path $env:APPDATA 'Code\Cache') }
    @{ Name = 'VS Code CachedData';        Path = (Join-Path $env:APPDATA 'Code\CachedData') }
    @{ Name = 'VS Code GPUCache';          Path = (Join-Path $env:APPDATA 'Code\GPUCache') }
    @{ Name = 'Edge 网页缓存';             Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache') }
    @{ Name = 'Chrome 网页缓存';           Path = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache') }
    @{ Name = 'CBS 组件日志';              Path = 'C:\Windows\Logs\CBS' }
    @{ Name = 'DISM 日志';                 Path = 'C:\Windows\Logs\DISM' }
    @{ Name = 'WER 报告队列';              Path = 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue' }
    @{ Name = 'WER 报告归档';              Path = 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive' }
    @{ Name = '用户级 WER';                Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER') }
    @{ Name = '内存小转储 Minidump';       Path = 'C:\Windows\Minidump' }
    @{ Name = '缩略图/图标缓存';           Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') }
    @{ Name = 'Prefetch 预读（删了会重建）'; Path = 'C:\Windows\Prefetch' }
)

$rebuild = @(
    @{ Name = 'vscode-cpptools IntelliSense 库'; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\vscode-cpptools') }
    @{ Name = 'GitHub Desktop 数据/旧版本';      Path = (Join-Path $env:LOCALAPPDATA 'GitHubDesktop') }
    @{ Name = 'uv 包缓存';                       Path = (Join-Path $env:LOCALAPPDATA 'uv') }
    @{ Name = 'D3D 着色器缓存';                  Path = (Join-Path $env:LOCALAPPDATA 'D3DSCache') }
    @{ Name = 'npm 缓存 (roaming)';              Path = (Join-Path $env:APPDATA 'npm-cache') }
    @{ Name = 'npm 缓存 (local)';                Path = (Join-Path $env:LOCALAPPDATA 'npm-cache') }
    @{ Name = 'NuGet 包缓存';                    Path = (Join-Path $env:USERPROFILE '.nuget\packages') }
    @{ Name = 'NuGet v3 缓存';                   Path = (Join-Path $env:LOCALAPPDATA 'NuGet\v3-cache') }
    @{ Name = 'JetBrains 缓存';                  Path = (Join-Path $env:LOCALAPPDATA 'JetBrains') }
    @{ Name = 'TypeScript 缓存';                 Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\TypeScript') }
    @{ Name = 'Packages (UWP 应用数据)';         Path = (Join-Path $env:LOCALAPPDATA 'Packages') }
    @{ Name = 'Edge 用户数据（非缓存）';         Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') }
    @{ Name = 'Chrome 用户数据（非缓存）';       Path = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') }
)

$forbidden = @(
    @{ Name = 'WinSxS 组件存储';            Path = 'C:\Windows\WinSxS' }
    @{ Name = 'Windows Installer (MSI 缓存)'; Path = 'C:\Windows\Installer' }
    @{ Name = 'ProgramData Package Cache';   Path = 'C:\ProgramData\Package Cache' }
)

$safeTotal = [double]0
$rebuildTotal = [double]0

Add-Line ''
Add-Line '===== 一、可安全删除（零副作用）====='
foreach ($t in $safe) {
    $m = Measure-Dir $t.Path
    if ($m.Status -eq 'ok') {
        $safeTotal += $m.Size
        Add-Line ('  {0}  {1}  {2}' -f (Fmt-MB $m.Size), $t.Name.PadRight(30), $t.Path)
    } elseif ($m.Status -eq 'denied') {
        Add-Line ('      无权限  {0}  {1}' -f $t.Name.PadRight(30), $t.Path)
    } else {
        Add-Line ('      不存在  {0}' -f $t.Name)
    }
}
Add-Line ('  --- 小计: {0}' -f (Fmt-MB $safeTotal))

Add-Line ''
Add-Line '===== 二、缓存/残留（删除后会重建或需重下，按需）====='
foreach ($t in $rebuild) {
    $m = Measure-Dir $t.Path
    if ($m.Status -eq 'ok') {
        $rebuildTotal += $m.Size
        Add-Line ('  {0}  {1}  {2}' -f (Fmt-MB $m.Size), $t.Name.PadRight(30), $t.Path)
    } elseif ($m.Status -eq 'denied') {
        Add-Line ('      无权限  {0}' -f $t.Name)
    }
}
Add-Line ('  --- 小计: {0}' -f (Fmt-MB $rebuildTotal))

Add-Line ''
Add-Line '===== 三、禁止手工删除 ====='
foreach ($t in $forbidden) {
    $m = Measure-Dir $t.Path
    Add-Line ('  {0}  {1}' -f (Fmt-MB $m.Size), $t.Name)
}
Add-Line '  说明：WinSxS 数值因硬链接虚高，只能用 DISM /StartComponentCleanup 清理；'
Add-Line '        Installer 与 Package Cache 删除后软件无法修复/卸载。详见 references/junk-catalog.md'

# ---------------------------------------------------------------- 大文件与根目录
Add-Line ''
Add-Line '===== 四、系统级大文件 ====='
$bigFiles = 'C:\hiberfil.sys', 'C:\pagefile.sys', 'C:\swapfile.sys', 'C:\Windows\MEMORY.DMP'
$anyBig = $false
foreach ($f in $bigFiles) {
    $s = Measure-File $f
    if ($null -ne $s) { Add-Line ('  {0}  {1}' -f (Fmt-MB $s), (Split-Path $f -Leaf)); $anyBig = $true }
}
if (-not $anyBig) { Add-Line '  无（休眠文件已关闭或未生成转储）' }

Add-Line ''
Add-Line '===== 五、系统盘一级目录 ====='
$roots = 'C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData', 'C:\Users', 'C:\Windows\Installer', 'C:\Windows\WinSxS'
$rootRows = @()
foreach ($r in $roots) {
    $m = Measure-Dir $r
    if ($m.Status -eq 'ok') { $rootRows += [pscustomobject]@{ Name = $r; Size = $m.Size } }
}
$rootRows | Sort-Object Size -Descending | ForEach-Object {
    Add-Line ('  {0}  {1}' -f (Fmt-MB $_.Size), $_.Name)
}

Add-Line ''
$rb = Measure-Dir 'C:\$Recycle.Bin'
Add-Line ('回收站: {0}' -f (Fmt-MB $rb.Size))

# ---------------------------------------------------------------- 用户级排名
Add-Line ''
Add-Line ('===== 六、用户级目录占用 Top {0} =====' -f $TopN)
foreach ($base in @((Join-Path $env:LOCALAPPDATA ''), (Join-Path $env:APPDATA ''))) {
    Add-Line ('--- ' + $base)
    $rows = @()
    Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return }
        $m = Measure-Dir $_.FullName
        if ($m.Status -eq 'ok' -and $m.Size -gt 50MB) {
            $rows += [pscustomobject]@{ Name = $_.Name; Size = $m.Size }
        }
    }
    $rows | Sort-Object Size -Descending | Select-Object -First $TopN | ForEach-Object {
        Add-Line ('  {0}  {1}' -f (Fmt-MB $_.Size), $_.Name)
    }
}

# ---------------------------------------------------------------- 汇总
Add-Line ''
Add-Line '===== 汇总 ====='
Add-Line ('  可安全删除合计 : {0}' -f (Fmt-MB $safeTotal))
Add-Line ('  缓存类合计     : {0}' -f (Fmt-MB $rebuildTotal))
Add-Line ('  报告路径       : {0}' -f $OutFile)

try {
    $outDir = Split-Path -Path $OutFile -Parent
    if ($outDir -and -not [System.IO.Directory]::Exists($outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
} catch {
    Write-Host ('无法写入报告: ' + $_.Exception.Message)
    exit 1
}

# 控制台是 GBK，中文可能乱码，这里只输出 ASCII 摘要
Write-Host ('Report: ' + $OutFile)
Write-Host ('Safe to delete : {0:N2} GB' -f ($safeTotal / 1GB))
Write-Host ('Rebuildable    : {0:N2} GB' -f ($rebuildTotal / 1GB))
