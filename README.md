# c-drive-space-optimizer

一个通用的 Windows 系统盘（C 盘）空间优化 Skill，适用于任意 Windows 10/11 电脑与任意用户。

核心思路：**数据搬到其他盘，原路径用目录联接（Junction）顶住，程序读写无感，随时可回滚**。

> A universal Windows 10/11 system drive cleanup skill: audit disk usage, relocate large directories to another drive as junctions, clean system-level space (recycle bin, WinSxS, reserved storage, page file), then verify and roll back if needed.

## 它解决什么问题

C 盘越用越满，但里面很大一部分是缓存、索引、聊天接收文件、桌面和下载目录。这类数据可以整体搬到其他分区，只要在原路径留一个目录联接，程序完全察觉不到路径变了。相比改注册表、重装软件、重新配置，这套做法可逆、可验证、失败能回滚。

## 能力

- **审计**：跳过联接真实统计占用，避开"已搬到别的盘却被算回本盘"的虚高
- **迁移**：`robocopy` 复制 + 前后字节数校验 + `mklink /J` + 失败自动回滚
- **系统级**：回收站、WinSxS（DISM）、保留存储、更新缓存、页面文件、休眠文件
- **长效导向**：TMP/TEMP、桌面、下载目录改到非系统盘
- **验证**：联接有效性、目标盘在线状态、空间对比

## 目录

```
SKILL.md                       Skill 入口与完整流程
references/decision-matrix.md  可搬 / 谨慎 / 禁止三档目录判定（按路径模式，不依赖具体软件）
references/pitfalls.md         20 条实战踩坑与处置
scripts/audit.ps1              占用审计
scripts/migrate.ps1            目录迁移 + 建立 Junction
scripts/system-cleanup.ps1     系统级清理（自动请求管理员）
scripts/verify.ps1             联接验证
```

## 安装

把整个目录放进对应平台的 Skill 目录，例如：

- Claude 风格 Agent：`~/.claude/skills/c-drive-space-optimizer/`
- 其他支持 Skill 的 Agent：放入其 `skills` 或 `user_skills` 目录

无需安装依赖，只用到 Windows 自带的 PowerShell、robocopy、mklink、DISM。

## 快速使用

```powershell
# 1. 审计（看谁占了盘）
powershell -ExecutionPolicy Bypass -File scripts/audit.ps1 -Drive C -Top 20

# 2. 先看迁移计划，不改动任何文件
powershell -ExecutionPolicy Bypass -File scripts/migrate.ps1 `
  -Source "$env:USERPROFILE\.cache" -Destination "D:\Offload\cache" -DryRun

# 3. 正式迁移
powershell -ExecutionPolicy Bypass -File scripts/migrate.ps1 `
  -Source "$env:USERPROFILE\.cache" -Destination "D:\Offload\cache"

# 4. 系统级清理（会弹 UAC）
powershell -ExecutionPolicy Bypass -File scripts/system-cleanup.ps1 -Recycle -Dism -ReservedStorage

# 5. 验证
powershell -ExecutionPolicy Bypass -File scripts/verify.ps1 -TargetDrive D
```

`D:\Offload` 只是推荐写法，换成任意目标盘的任意目录即可。

## 安全边界

- 不搬程序安装目录、系统目录、驱动目录
- 不搬正在写入的目录（脚本会检测并自动放弃）
- 任何失败都保留源目录，只做回滚
- 系统级清理不可逆，脚本会先请求管理员并记录日志

## 注意

`.ps1` 内含中文字符串，Windows PowerShell 5.1 需要 **UTF-8 with BOM**。若克隆后出现乱码或语法报错，用 PowerShell 7（`pwsh`）运行，或按 `SKILL.md` 里的转码片段处理。

## 许可

MIT
