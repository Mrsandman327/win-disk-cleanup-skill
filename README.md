# win-disk-cleanup

Windows 系统盘（C:）垃圾**只读扫描**与**白名单清理**工具。PowerShell 脚本，零依赖，面向 AI agent 调用。

设计前提：**「垃圾」不是一个性质**。临时文件删了零副作用，网页缓存删了要重新下载，而 `C:\Windows\Installer` 删了对应软件就再也卸载不掉。通用清理工具把这三类混在一起一键处理，是这个领域最常见的事故来源。本工具的做法是**先把三类分清楚，再只动第一类**。

> 面向 agent 的操作手册（含逐条铁律与排障）见 [SKILL.md](SKILL.md)。
> 每一项「为什么能删 / 为什么不能删」的判定依据与实测数据见 [references/junk-catalog.md](references/junk-catalog.md)。

---

## 安全模型

这是本文档最重要的部分 —— 这个工具具备删除能力，所以它的安全设计比功能更值得说明。

| # | 闸门 | 实现 |
|---|---|---|
| 1 | **扫描只读** | `scan-c-junk.ps1` 只统计大小，不删除、不移动、不修改任何文件 |
| 2 | **默认 dry-run** | `clear-junk.ps1` 不加 `-Execute` 时只列清单，不删任何东西 |
| 3 | **白名单硬编码** | 清理范围写死在脚本里，不接受外部传入路径 |
| 4 | **受保护路径二次拦截** | `WinSxS` / `Windows\Installer` / `Package Cache` / `System32` / `SysWOW64` 命中即跳过 |
| 5 | **路径形态校验** | 路径为空、过短（<10 字符）或仅盘符（`C:\`）时整条跳过，防误伤整盘 |
| 6 | **清空内容、保留目录** | 删除的是目录**内容**，目录本身留下，避免程序因目录缺失报错 |
| 7 | **占用文件不阻塞** | 单个文件删不掉只计入失败数并继续，不影响其余项 |

**结论从报告文件读，不从控制台读** —— 详见下方「关键设计决策」。

---

## 三级分类法

扫描报告把所有项目固定归入三档，清理脚本只处理第一档。

| 档位 | 含义 | 典型内容 | 处置 |
|---|---|---|---|
| **一、可安全删除** | 删了会自动重建，或完全没有保留价值 | 临时文件、崩溃转储、工具缓存、系统日志、更新包残留 | 可直接清，零副作用 |
| **二、缓存 / 残留** | 删了要重建或重新下载，可能短期变慢 | IntelliSense 数据库、包管理器缓存、UWP 应用数据、浏览器用户数据 | **逐项确认**后再清 |
| **三、禁止手工删除** | 系统或安装器回读依赖 | `WinSxS`、`Windows\Installer`、`ProgramData\Package Cache` | 只用 DISM，**绝不** `Remove-Item` |

> ⚠️ `Edge / Chrome 的 User Data` 被放在第二档并明确标注「**不是缓存**」——
> 书签、密码、扩展、会话都在里面。只应清理其中的 `Default\Cache`、`Code Cache`、`GPUCache`。

判定「是不是垃圾」的三条通用规则（三条都答「否」才算零风险）：

1. 删了会不会自动重建？→ 会，则是缓存。
2. 删了会不会丢用户创建的东西？→ 会，则不是垃圾。
3. 是不是卸载 / 修复 / 更新要用？→ 是，则禁止。

---

## 快速开始

### 1. 扫描（只读）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-c-junk.ps1
```

脚本在非管理员下**自动请求提权**（UAC 点「是」）。整轮约 **1~3 分钟**（WinSxS 与 AppData 最慢），不要中断。

不想弹 UAC、只扫用户级路径：

```powershell
... -NoElevate
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-OutFile` | `<技能目录>\output\c_junk_scan.txt` | 报告路径。默认值在**提权之前**解析成绝对路径再传给子进程 |
| `-NoElevate` | 关 | 不提权，受保护路径标「无权限」 |
| `-TopN` | 15 | AppData 目录排行条数 |

### 2. 读报告

报告是 UTF-8 文本，**用文件读取而非控制台回显**（控制台是 GBK，中文会乱码）：

```
output\c_junk_scan.txt
```

报告分六段：

| 段 | 内容 | 用途 |
|---|---|---|
| 一 | 可安全删除 | 直接可清，含小计 |
| 二 | 缓存 / 残留 | 逐项判断 |
| 三 | 禁止手工删除 | 仅供了解水位 |
| 四 | 系统级大文件 | `hiberfil.sys` / `pagefile.sys` / `MEMORY.DMP` |
| 五 | 系统盘一级目录 | 判断增长方向 |
| 六 | 用户级 Top N | 找旧版本残留、异常增长的应用 |

### 3. 清理（用户确认后）

```powershell
# dry-run：只列清单
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clear-junk.ps1

# 用户确认后真正删除
... -Execute
```

日志写 `output\c_junk_clear.txt`（UTF-8）。

清完想复核就再跑一次扫描，对比第一段小计。

---

## 三个必查点

| 现象 | 说明 | 处置 |
|---|---|---|
| **`hiberfil.sys` 很大**（常见 8~16 GB） | 休眠 + 快速启动开着，通常是最大单项 | `powercfg /h off` 关闭并释放，或 `/size 40` 折中。**必须由用户决定** —— 关闭后失去休眠与快速启动 |
| **`WinSxS` 数值虚高** | 硬链接导致重复计数。实测报 13 GB，实际独占约一半 | 唯一合法清理：`DISM /Online /Cleanup-Image /StartComponentCleanup`（加 `/ResetBase` 后无法卸载已装更新） |
| **`xxx_<数字>` 目录**（如 `DingTalk_133`） | 多为旧版本残留 | 与当前版本号比对后再建议删除 |

---

## 目录结构

```
win-disk-cleanup/
├── README.md                    本文件（项目总览、安全模型、设计取舍）
├── SKILL.md                     agent 操作手册（铁律、工作流、排障）
├── references/
│   └── junk-catalog.md          逐项判定依据 + 实测基准
└── scripts/
    ├── scan-c-junk.ps1          只读扫描，自动提权，输出 UTF-8 报告
    └── clear-junk.ps1           白名单清理，默认 dry-run
```

运行期会在技能目录下生成 `output/`（不写系统盘 C:）。

---

## 关键设计决策

| 决策 | 原因 |
|---|---|
| **报告写 UTF-8 文件，不依赖 stdout** | PowerShell 控制台是 GBK，中文必然乱码；且提权后**子进程的 stdout 不会回传给父进程**，只能读文件 |
| **默认 `-OutFile` 在提权前解析成绝对路径** | 否则提权后的子进程会把报告写进管理员的 `%TEMP%` 或 `C:\ProgramData` —— 等于给系统盘造垃圾 |
| **`.NET` 枚举并跳过 reparse point** | `C:\Users` 下有 `All Users`、`Default User` 等 junction，不跳过会重复统计导致虚高 |
| **用 `System.IO.FileInfo.Length` 读大文件大小** | `hiberfil.sys` / `pagefile.sys` 受 ACL 保护，`Get-Item` 会报「路径不存在」的假象 |
| **清理白名单比扫描的白名单更窄** | 扫描第一档列出 21 项，清理只覆盖其中 15 项。刻意排除：Edge/Chrome 网页缓存（浏览器可能正在写）、用户级 WER、Minidump、缩略图缓存（需先结束 `explorer.exe`，收益低于风险）、Prefetch（收益小、删后短期变慢） |
| **清空内容而非删除目录** | 某些程序在目录缺失时会报错或反复重建失败 |
| **只清第一档** | 第二档含用户数据（书签、密码、应用状态），第三档是安装器回读依赖 —— 交给脚本自动判断的收益远低于风险 |

---

## 实测基准

基准环境：**Windows 11 + 300 GB 系统盘**，实测于 2026-10。用于判断扫描结果是否异常。

### 第一档（可安全删除）主要项

| 位置 | 实测 | 备注 |
|---|---|---|
| `%LOCALAPPDATA%\Temp` | 0.7~4.4 GB（波动大） | 占比最大的单项 |
| `DeliveryOptimization`（NetworkService 下） | ~1.5 GB | **普通扫描最容易漏**，因为在 NetworkService 配置文件下 |
| `%APPDATA%\Code\{Cache,CachedData,GPUCache}` | 合计 ~0.5 GB | VS Code 运行时缓存 |
| `C:\Windows\Temp` | 0.3~0.5 GB | 需管理员 |
| `C:\Windows\SoftwareDistribution\Download` | 20~200 MB | 已安装更新的残留 |
| `%LOCALAPPDATA%\pip\Cache` | ~150 MB | 等价 `pip cache purge` |
| `Prefetch` / 各类日志 / WER | 各几 MB~几十 MB | 收益小 |

### 第三档（禁止删除）实测水位

| 位置 | 实测 | 独占估算 |
|---|---|---|
| `C:\Windows\WinSxS` | 报 13 GB | 实际约一半（硬链接重复计数） |
| `C:\Windows\Installer` | 4.5 GB | — |
| `C:\ProgramData\Package Cache` | 2.9 GB | — |

### 系统级大文件

| 文件 | 典型大小 | 处置 |
|---|---|---|
| `hiberfil.sys` | 8~16 GB（≈ 内存的 40~100%） | `powercfg /h off`，**必须用户决定** |
| `pagefile.sys` | 视内存 | 不建议删除 |
| `swapfile.sys` | 256 MB | 系统托管，别动 |
| `C:\Windows\MEMORY.DMP` | 可达数 GB | 蓝屏完整转储，排查完可删 |

---

## 已知限制

1. **硬链接仍会重复计数** —— 只有 reparse point 被跳过，硬链接无法区分。WinSxS 段的数值仅供排序参考，不能当真实可回收量。
2. **两次扫描结果会不一致** —— 扫描期间 Temp 会被其他程序增删，差异 10% 以内属正常。
3. **与资源管理器显示的大小可能有落差** —— 重解析点、稀疏文件、硬链接的统计口径不同。
4. **未提权时部分路径显示「无权限」** —— 属正常降级，不是错误。
5. **`clear-junk.ps1` 只清第一档的 15 项** —— 见上文「关键设计决策」，这不是遗漏而是刻意收窄。
6. **不处理 WinSxS 的 DISM 清理** —— 属于需要单独判断后果的操作（`/ResetBase` 不可逆），只给命令不给自动化。
7. **不做定期调度** —— 不内置计划任务，何时清理由调用方决定。

---

## 与 SKILL.md 的分工

| 文件 | 定位 |
|---|---|
| **README.md**（本文件） | 为什么这么设计、能做什么、边界在哪 |
| **SKILL.md** | 怎么用：铁律、命令、参数、汇报格式、常见坑 |

执行任何清理动作前，先读 SKILL.md 的「铁律」一节。
