---
name: c-drive-space-optimizer
description: Windows 系统盘空间优化与目录重定向，适用于任意 Windows 10/11 电脑与任意用户。当需要清理 C 盘、释放系统盘空间、把大目录搬到其他盘并建立目录联接（junction）、排查磁盘占用、或让新增文件默认落到非系统盘时使用。覆盖占用审计、目录分级迁移、系统级清理（回收站/WinSxS/保留存储/页面文件）、联接验证与回滚。不适用于 Linux/容器环境、分区调整、镜像克隆与数据恢复。Windows system drive cleanup: audit, relocate directories to another drive with junctions, system-level cleanup, verification and rollback.
---

# C 盘空间优化器

以"数据搬走、路径不变、使用无感"为原则优化 Windows 系统盘：把可搬迁目录移到其他盘，在原位置建立目录联接（Junction），程序仍按原路径读写。全程可回滚。

适用于任意 Windows 10/11 机器，不依赖特定硬件、特定软件或特定用户名。以下 `<目标盘>`、`<离线目录>` 由使用者按实际情况替换，推荐形如 `D:\Offload`。

## 先决条件

- Windows 10/11，PowerShell 可用；系统级步骤需管理员。
- 目标盘有足够空闲空间（至少为待迁移总量的 1.2 倍），且必须是固定磁盘；不要用移动硬盘、U 盘、网络盘、虚拟光驱做联接目标。
- 迁移前提醒使用者保存工作、退出会被搬动的程序；正在写入的目录一律不搬。
- 多用户机器上，每个用户目录需要单独处理，不要跨用户搬迁。

## 硬规则

1. **只搬数据，不搬程序本体**。`Program Files`、`Program Files (x86)`、`Windows`、`WinSxS`、驱动目录，以及 `%LOCALAPPDATA%\Programs` 下的应用安装目录都不搬；这些路径被安装器、卸载器、更新器、服务注册和 COM 注册写死，搬走会导致卸载失败、升级失败、开机不自启。
2. **运行中持续写入的目录不搬**。典型是 AI 助手/代码助手的数据目录、浏览器配置、打开中的 IDE 工作区、数据库文件、正在下载的目录。复制过程中源目录大小发生变化即视为不安全，必须放弃本次迁移。
3. **联接必须是 Junction（目录联接），不要用符号链接**。Junction 不需要开发者模式、跨盘可用、对绝大多数程序透明，删除联接不会删除目标数据。用 `mklink /J`，不要用 `mklink /D`。
4. **迁移前先量，迁移后必验**。复制前后源目录字节数必须一致才允许切换；切换后立刻校验联接可达、条目数一致。
5. **迁移失败只回滚，不硬删**。一旦 `mklink` 失败，把 `.moved.bak` 改名回原目录即可完全恢复；任何情况下不得先删除源目录再建链接。
6. **系统级操作单独一轮**。回收站清空、DISM 组件清理、保留存储开关都会改变系统状态，先做目录迁移（可回滚），再做系统级清理（不可回滚）。
7. **先给使用者看方案再动手**。列出待搬清单、预计释放量、不搬项及原因，确认后执行；已明确授权的范围内可连续执行。

## 流程

### 第 1 步：审计

用 `scripts/audit.ps1` 生成占用报告。手动审计时必须避开两个失真源：

- **不要用 `Get-ChildItem -Recurse` 直接量带联接的目录**。它会穿透联接，把已经搬到其他盘的数据重复计入本盘，得出虚高体积。正确做法是遇到 `Attributes -band ReparsePoint` 就停止下钻。
- **用 `fsutil volume diskfree C:` 交叉验证**。目录求和与系统口径不一致时，差额通常来自页面文件、休眠文件、卷影副本、系统还原点或权限不可读区域。

审计输出三类清单：可搬目录（缓存/日志/用户数据）、需谨慎目录（运行中的应用数据）、禁止搬目录（程序与系统）。判定依据见 `references/decision-matrix.md`。

### 第 2 步：迁移

逐个目录执行 `scripts/migrate.ps1`。单个目录的完整动作是：

1. 预检：源存在、不是联接、目标不存在、目标盘空间足够。
2. `robocopy /E /COPY:DAT /DCOPY:DAT /R:1 /W:1` 复制到目标。
3. 复测源目录字节数：与预检值不同 → 判定写入活跃，保留源目录、结束。
4. 字节数一致 → 源目录改名 `<name>.moved.bak` → `mklink /J` 原路径指向目标 → 校验可访问 → 删除 `.moved.bak`。
5. `.moved.bak` 删不掉说明仍有句柄占用，保留备份、报告"联接已建、备份待删"，下次重启后清理。

### 第 3 步：系统级清理

用 `scripts/system-cleanup.ps1`（自动请求管理员）按需组合：

- **回收站**：系统盘回收站按分区独立，搬到其他盘不会让它变小。`Clear-RecycleBin` 在条目损坏或跨账户时经常报"找不到文件"，此时改为逐项 `rd /s /q`。
- **WinSxS**：`dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase`，通常释放 3–5GB。**DISM 返回 5（拒绝访问）不代表没生效**，必须用前后空闲空间和 WinSxS 体积判定。
- **保留存储**：`dism /Online /Set-ReservedStorageState /State:Disabled` 可释放约 7GB，代价是后续系统更新需要更多可用空间。恢复用 `State:Enabled`。
- **休眠与页面文件**：`powercfg /h off` 关闭休眠释放 hiberfil.sys；页面文件用 `-MovePagefile <盘符>:` 或图形界面"系统属性→高级→性能→虚拟内存"改到其他盘，改完必须重启。
- **更新缓存**：清空 `SoftwareDistribution\Download`。

回收站与 DISM 必须放在**最后一轮**，因为前面每一次删除都可能被系统或工具转入回收站，等于空间没释放。

### 第 4 步：后续导向

让增量文件默认落到目标盘，避免清理成果被慢慢吃掉：

- 环境变量：用户级 `TMP`/`TEMP` 指向目标盘目录。
- 用户目录：`Desktop`、`Downloads`、`Documents`、`Pictures` 可用同一套脚本整体搬迁并建联接。
- 包管理器缓存：npm/pnpm/pip/cargo/go 等优先用各自的配置命令改缓存位置，或直接迁移缓存目录。
- 容器、网盘、虚拟机：在应用自身设置里改数据目录，不要用联接。

### 第 5 步：验证

用 `scripts/verify.ps1` 输出联接清单与状态：目标是否存在、是否在指定盘、条目数是否正常；同时给出空间对比。验收标准：

- 系统盘可用空间确有增长，且增量与迁移总量、清理项之和大致相符（差额通常在 1GB 内，用于容纳日志与临时文件）。
- 所有联接可用，抽查原路径能正常读文件。
- 被搬动的程序能正常启动、能正常创建新文件。
- 关键应用（IDE、浏览器、聊天客户端、容器）启动无报错。

### 常见失败处置

对照 `references/pitfalls.md`：写入活跃导致字节数不符、长路径导致 robocopy 报错、联接被误删、目标盘掉线、迁移后桌面空白等，均有对应恢复动作。

## 脚本

脚本内含中文字符串。Windows PowerShell 5.1 读取无 BOM 的 UTF-8 会按 ANSI 解码，导致中文乱码甚至语法报错；请确保 `.ps1` 为 **UTF-8 with BOM**，或改用 PowerShell 7（`pwsh`）运行。转换方式：

```powershell
$p = 'scripts/audit.ps1'
$t = [IO.File]::ReadAllText($p, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))
```

| 脚本 | 作用 | 权限 |
| --- | --- | --- |
| `scripts/audit.ps1` | 盘点各盘占用、按目录分级列出大户、列出既有联接 | 普通 |
| `scripts/migrate.ps1` | 单目录/批量迁移并建立 Junction，含预检、校验、回滚 | 普通 |
| `scripts/system-cleanup.ps1` | 回收站、WinSxS、保留存储、更新缓存、页面文件、休眠 | 管理员 |
| `scripts/verify.ps1` | 联接有效性、目标可达性、空间对比 | 普通 |

用法示例（`<目标盘>` 换成实际盘符，如 D）：

```powershell
# 审计
powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Drive C -Top 20

# 单个目录迁移，先看计划
powershell -ExecutionPolicy Bypass -File scripts/migrate.ps1 `
  -Source "$env:USERPROFILE\.cache" -Destination "D:\Offload\cache" -DryRun

# 正式迁移
powershell -ExecutionPolicy Bypass -File scripts/migrate.ps1 `
  -Source "$env:USERPROFILE\.cache" -Destination "D:\Offload\cache"

# 批量迁移，从 JSON 读清单
powershell -ExecutionPolicy Bypass -File scripts/migrate.ps1 -Plan plan.json

# 系统级清理（会弹 UAC 请求管理员）
powershell -ExecutionPolicy Bypass -File scripts/system-cleanup.ps1 -Recycle -Dism -ReservedStorage
powershell -ExecutionPolicy Bypass -File scripts/system-cleanup.ps1 -MovePagefile D:

# 验证
powershell -ExecutionPolicy Bypass -File scripts/verify.ps1 -TargetDrive D
```

`plan.json` 格式（迁移脚本唯一需要的输入文件）：

```json
{
  "retire": "D:\\Offload",
  "pairs": [
    { "source": "C:\\Users\\me\\.cache", "name": "cache" },
    { "source": "C:\\Users\\me\\AppData\\Local\\Temp", "name": "Temp" }
  ]
}
```

## 回滚

- 单个目录：读日志找到 `.moved.bak`；若已存在，先 `rd /s /q` 删除联接，再把备份改回原名；数据仍在目标盘，需要时用 `robocopy` 反向复制回去再删目标。
- 全部回滚：按 `verify.ps1` 输出的联接清单逐个反做。
- 系统级操作：保留存储可用 `State:Enabled` 恢复；页面文件可改回系统托管；DISM 与回收站不可逆，执行前需确认。
