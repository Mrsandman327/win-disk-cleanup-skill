---
name: win-disk-cleanup
description: 只读扫描 Windows 系统盘（C:）垃圾并按「可安全删除 / 会重建 / 禁止删除」三级出报告，再按内置白名单逐项清理。当用户说 C 盘满了 / 清理 C 盘 / 磁盘空间不足 / 查一下 C 盘垃圾 / 看看有哪些能删 / 系统盘占用分析，或问临时文件、传递优化缓存、WinSxS、Windows Installer、ProgramData Package Cache、hiberfil.sys、VS Code / Go / pip / NuGet 缓存占了多少时使用。
---

# Windows C 盘垃圾扫描与清理

## 铁律

1. **默认只读**：`scripts/scan-c-junk.ps1` 只统计大小，不删除、不移动、不修改任何文件。
2. **先出清单，得到用户确认后才删**：删除只走 `scripts/clear-junk.ps1`，且必须显式加 `-Execute`（默认 dry-run）。
3. **永不删除**：`C:\Windows\WinSxS`、`C:\Windows\Installer`、`C:\ProgramData\Package Cache`。理由见 `references/junk-catalog.md`。
4. **结论从报告文件读**：PowerShell 控制台是 GBK，中文会乱码；脚本已把结果写成 UTF-8 文件，用 `read` 工具读文件，不要依赖控制台回显。

## 1. 扫描

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<技能目录>\scripts\scan-c-junk.ps1"
```

脚本会自动请求管理员权限（UAC 点「是」）。跑完用 `read` 读 `output\c_junk_scan.txt`（技能目录下，不写 C 盘）。

```powershell
# 不提权，只扫用户级路径（自检 / 不想弹 UAC 时）
... -NoElevate
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-OutFile` | `<技能目录>\output\c_junk_scan.txt` | 报告路径。默认值在提权**之前**解析成绝对路径再传给子进程，所以提权后也不会落到管理员账户目录或系统盘 |
| `-NoElevate` | 关 | 不提权，受保护路径标「无权限」 |
| `-TopN` | 15 | AppData 下目录排行条数 |

整轮扫描约 1~3 分钟（WinSxS 与 AppData 最慢），不要中断。

## 2. 读报告

报告分六段，对应三类判断：

| 段 | 含义 | 处置 |
|---|---|---|
| 一、可安全删除 | 临时文件、崩溃转储、工具缓存、系统日志、更新包缓存 | 可直接清，零副作用 |
| 二、缓存/残留 | IntelliSense 库、包管理器缓存、UWP 数据、浏览器用户数据 | 清前逐项确认；浏览器用户数据**不是缓存**，删了丢书签/密码 |
| 三、禁止手工删除 | WinSxS / Installer / Package Cache | 只用 DISM，绝不 `Remove-Item` |
| 四、系统级大文件 | `hiberfil.sys` / `pagefile.sys` / `MEMORY.DMP` | 休眠文件常常是最大单项，见下方提示 |
| 五、一级目录 | Windows / Users / Program Files 占比 | 判断增长方向 |
| 六、用户级 Top N | `AppData\Local` 与 `Roaming` 排行 | 找旧版本残留、异常增长的应用 |

### 三个必查点

- **`hiberfil.sys` 很大**（常见 8~16 GB）：说明休眠/快速启动开着。用户同意后可 `powercfg /h off`（管理员的决定权在用户，不要自行执行）。
- **WinSxS 数值虚高**：硬链接导致重复计数，实测报 13 GB 而实际独占约一半。只能 `DISM /Online /Cleanup-Image /StartComponentCleanup`。
- **`xxx_<数字>` 目录**（如 `DingTalk_133`）：多为旧版本残留，与当前版本号比对后再建议删除。

## 3. 清理（用户确认后）

```powershell
# 先 dry-run 看清单
powershell -NoProfile -ExecutionPolicy Bypass -File "<技能目录>\scripts\clear-junk.ps1"

# 用户确认后执行
... -Execute
```

脚本特性：

- 只清「一、可安全删除」这一档，白名单硬编码；受保护路径有二次拦截。
- **清空目录内容、保留目录本身**，避免程序因目录缺失报错。
- 占用中的文件自动跳过并计入失败数，不影响其他项。
- 日志写 `output\c_junk_clear.txt`（UTF-8，技能目录下），用 `read` 读。

清完想复核就再跑一次扫描，对比「一」段小计。

## 4. 汇报格式

给用户的清单按三档列表格，每行写「大小 / 位置 / 一句话理由」，末尾给出可回收合计。不要只报总数，也不要把「禁止删除」项混进可清理项。

声称「已清理」之前必须以 `clear-junk.ps1` 的日志或复核扫描为证据。

## 5. 常见坑

| 现象 | 原因与对策 |
|---|---|
| UAC 弹窗一过就 `The operation was canceled by the user` | 提权被取消；重试，或让用户开管理员终端手动跑 |
| 提权后读不到报告 | 子进程的 stdout 不会回传给父进程；一律读 `output\` 下的 UTF-8 文件 |
| 报告别写进 C: | 默认已在技能目录 `output\`；`-OutFile` 指到系统盘就是给自己造垃圾 |
| 控制台中文乱码 | 控制台 GBK；只信 UTF-8 报告文件 |
| 目录大小比 `资源管理器` 大/小很多 | 硬链接、重解析点、稀疏文件差异；脚本已跳过 reparse point |
| `C:\Windows\Temp` 显示「无权限」 | 未提权；属正常降级 |

逐项判定依据、DISM 命令、以及每一项「为什么能删/不能删」的完整说明见 `references/junk-catalog.md`。
