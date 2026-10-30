# C 盘垃圾判定目录（分类依据与实测基准）

基准环境：Windows 11 + 300 GB 系统盘，实测于 2026-10，用于校核扫描结果是否异常。

## 一、可安全删除（零副作用）

| 位置 | 实测 | 为什么能删 |
|---|---|---|
| `%LOCALAPPDATA%\Temp` | 0.7~4.4 GB（波动大） | 用户级临时文件，应用重启后自动重建；占比最大的单项 |
| `C:\Windows\Temp` | 0.3~0.5 GB | 系统级临时文件，需管理员 |
| `C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization` | 1.5 GB | 更新 P2P 分发缓存，删后按需重新下载；**普通扫描最容易漏掉的一项**，因为在 NetworkService 配置文件下 |
| `C:\Windows\SoftwareDistribution\Download` | 20~200 MB | 已安装更新的安装包残留 |
| `%LOCALAPPDATA%\CrashDumps` | 0~200 MB | 崩溃转储，仅在排查崩溃时需要 |
| `%LOCALAPPDATA%\pip\Cache` | 150 MB | pip wheel 缓存，`pip cache purge` 等价 |
| `%LOCALAPPDATA%\goimports`、`%LOCALAPPDATA%\gopls` | 各 15~130 MB | Go 工具索引缓存，重新打开项目即重建 |
| `%APPDATA%\Code\Cache`、`CachedData`、`GPUCache` | 合计约 0.5 GB | VS Code 运行时缓存与旧版本编译产物 |
| `C:\Windows\Logs\CBS`、`C:\Windows\Logs\DISM` | 各几 MB | 组件安装日志 |
| `C:\ProgramData\Microsoft\Windows\WER\ReportQueue|ReportArchive` | 几 MB | 错误报告队列/归档 |
| `C:\Windows\Prefetch` | 20~30 MB | 预读数据，删后短期启动变慢再恢复；收益小，可不做 |
| `%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db` | 几 MB~几十 MB | 缩略图缓存；删除前需结束 explorer.exe，收益低于风险，建议跳过 |

## 二、缓存/残留（会重建或需重下）

| 位置 | 实测 | 判断要点 |
|---|---|---|
| `%LOCALAPPDATA%\Microsoft\vscode-cpptools` | **2.3 GB** | C/C++ 扩展 IntelliSense 数据库，删后重开 C/C++ 项目自动重建（重建期间 CPU 高、提示变慢） |
| `%LOCALAPPDATA%\GitHubDesktop` | 1.5 GB → 0.9 GB | 含程序本体与旧版本目录；先看是否有多个 `app-x.y.z` 版本目录 |
| `%LOCALAPPDATA%\DingTalk_<数字>` | 1.2 GB | 数字不是当前版本号即为旧版本残留 |
| `%LOCALAPPDATA%\Packages` | 0.7 GB | UWP 应用数据，**含应用状态不是纯缓存**，只删已卸载应用的目录 |
| `%LOCALAPPDATA%\uv` | 80 MB | uv 包缓存，`uv cache clean` 等价 |
| `%LOCALAPPDATA%\NuGet\v3-cache`、`~\.nuget\packages` | 0~若干 GB | 包缓存，删后下次还原重新下载 |
| `%APPDATA%\npm-cache` | 视使用量 | `npm cache clean --force` 等价 |
| `%LOCALAPPDATA%\D3DSCache` | 几 MB | 着色器缓存，会重建 |
| `Edge / Chrome 的 User Data` | 2.7 / 0.6 GB | ⚠️ **不是缓存**：书签、密码、扩展、会话都在里面。只清其中的 `Default\Cache`、`Code Cache`、`GPUCache` |
| 已卸载程序留下的目录（如 `io.github.clash-verge-rev.clash-verge-rev`、`clash_win`） | 几十~几百 MB | 确认主程序已卸载后再删 |

## 三、禁止手工删除

| 位置 | 实测 | 原因 |
|---|---|---|
| `C:\Windows\WinSxS` | 报 13 GB（实际独占约一半） | 组件存储，硬链接结构；删了系统更新与修复失效。唯一合法清理：`DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase`（`/ResetBase` 后无法卸载已装更新） |
| `C:\Windows\Installer` | 4.5 GB | MSI/MSP 源缓存，卸载/修复/更新时要回读；删了对应软件无法卸载或修复 |
| `C:\ProgramData\Package Cache` | 2.9 GB | VS / VC++ 运行库的安装源，同上 |
| `C:\Windows\System32` 及各类 `%SystemRoot%` 子目录 | — | 系统文件 |
| `pagefile.sys` | 视内存而定 | 页面文件；只在用户明确要求且理解后果时用系统属性调整 |

## 四、系统级大文件处理

| 文件 | 典型大小 | 处置 |
|---|---|---|
| `hiberfil.sys` | 8~16 GB（≈ 内存的 40~100%） | 休眠 + 快速启动。`powercfg /h off` 关闭并释放；`powercfg /h /size 40` 折中。**必须用户决定**，关闭后失去休眠与快速启动 |
| `pagefile.sys` | 视内存 | 不建议删除；内存 ≥ 32 GB 可考虑限制大小 |
| `swapfile.sys` | 256 MB | 系统托管，别动 |
| `C:\Windows\MEMORY.DMP` | 可达数 GB | 蓝屏完整转储，排查完可删 |

## 五、测量口径

- 脚本用 `.NET` 枚举并**跳过 reparse point**（junction / 符号链接），否则 `C:\Users` 会因 `All Users`、`Default User` 等 junction 被重复统计而虚高。
- 硬链接仍会重复计数（WinSxS 最典型），所以「禁止删除」段的数值仅供排序参考。
- `hiberfil.sys`、`pagefile.sys` 受 ACL 保护，`Get-Item` 可能报「路径不存在」的假象；`System.IO.FileInfo.Length` 才能读到真实大小，脚本已按此实现。
- 扫描期间 Temp 会被其他程序增删，两次扫描结果不一致属正常，差异在 10% 以内可忽略。

## 六、判定「是不是垃圾」的三条通用规则

1. **删了会不会自动重建**？会 → 缓存，可删（但可能短期变慢）。
2. **删了会不会丢用户创建的东西**？会 → 不是垃圾（书签、密码、文稿、项目文件、软件配置）。
3. **是不是卸载/修复/更新要用**？是 → 禁止（Installer、Package Cache、WinSxS）。

三条都答「否」才算零风险。
