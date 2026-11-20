#Requires -Version 5.1
<#
.SYNOPSIS
  把单个目录（或 JSON 清单中的多个目录）迁到其他盘，并在原路径建立 Junction。

.DESCRIPTION
  安全顺序：预检 -> robocopy 复制 -> 复测源目录是否被写入 -> 源目录改名备份 -> mklink /J
  -> 校验 -> 删除备份。任一步失败都保留源目录，不会丢数据。

  只有复制期间源目录字节数保持不变才允许切换；写入活跃的目录会被自动跳过。

.PARAMETER Source
  一个源目录的绝对路径。

.PARAMETER Destination
  对应目标绝对路径（必须不存在）。

.PARAMETER Plan
  JSON 清单文件，批量迁移。格式：
  { "retire": "D:\\Offload",
    "pairs": [ { "source": "C:\\Users\\me\\.cache", "name": "cache" } ] }
  name 为相对 retire 的子路径。

.PARAMETER DryRun
  只做预检与体积统计，不复制、不改动。

.PARAMETER KeepBackup
  切换成功后保留 .moved.bak（默认删除）。

.PARAMETER LogFile
  日志路径，默认在当前目录创建 migrate.log。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File migrate.ps1 -Plan plan.json -DryRun
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File migrate.ps1 -Source 'C:\Users\me\.cache' -Destination 'D:\Offload\cache'
#>
param(
    [string]$Source,
    [string]$Destination,
    [string]$Plan,
    [switch]$DryRun,
    [switch]$KeepBackup,
    [string]$LogFile
)

$ErrorActionPreference = 'Continue'
if (-not $LogFile) { $LogFile = Join-Path (Get-Location) 'migrate.log' }

function Write-Log($msg) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-DirBytes {
    param([string]$Path)
    $sum = [long]0
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
    }
    catch { }
    if ($null -eq $sum) { $sum = 0 }
    return [long]$sum
}

function Format-Size($bytes) {
    if ($bytes -ge 1GB) { return ([string]([math]::Round($bytes / 1GB, 2)) + 'GB') }
    return ([string]([math]::Round($bytes / 1MB, 2)) + 'MB')
}

function Move-One {
    param([string]$Src, [string]$Dst)

    Write-Log ('==== ' + $Src + ' -> ' + $Dst)

    if (-not (Test-Path -LiteralPath $Src)) { Write-Log 'SKIP: 源不存在'; return 'skip' }
    $item = Get-Item -LiteralPath $Src -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Write-Log 'SKIP: 源已是联接/符号链接'; return 'skip'
    }
    if (Test-Path -LiteralPath $Dst) { Write-Log 'SKIP: 目标已存在'; return 'skip' }

    # 目标盘空间预检
    $targetRoot = [System.IO.Path]::GetPathRoot($Dst)
    $driveLetter = $targetRoot.TrimEnd('\').TrimEnd(':')
    $free = (Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue).Free
    $srcSize = Get-DirBytes -Path $Src
    Write-Log ('源体积=' + (Format-Size $srcSize) + ', 目标盘可用=' + [math]::Round($free / 1GB, 2) + 'GB')
    if ($null -eq $free) { Write-Log 'FAIL: 找不到目标盘'; return 'fail' }
    if ($free -lt ($srcSize * 1.2)) { Write-Log 'FAIL: 目标盘空间不足（需 1.2 倍余量）'; return 'fail' }

    if ($DryRun) { Write-Log 'DRY RUN: 跳过复制'; return 'dryrun' }

    $parent = Split-Path -Parent $Dst
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    $leaf = Split-Path -Leaf $Src
    $rcLog = Join-Path (Split-Path -Parent $LogFile) ('_robocopy_' + ($leaf -replace '[\\/:*?"<>|]', '_') + '.log')
    robocopy $Src $Dst /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NP /NFL /NDL /LOG:$rcLog | Out-Null
    $rc = $LASTEXITCODE
    Write-Log ('robocopy rc=' + $rc)
    if ($rc -ge 8) {
        Write-Log 'FAIL: robocopy 出错（rc>=8），保留源目录，目标副本请人工确认后清理'
        return 'fail'
    }

    # 复测源目录：写入活跃则放弃
    $srcAfter = Get-DirBytes -Path $Src
    if ($srcAfter -ne $srcSize) {
        Write-Log ('ABORT: 复制期间源目录被写入（' + $srcSize + ' -> ' + $srcAfter + '），保留源目录')
        Write-Log ('提示：如需清理目标副本，执行 rd /s /q "' + $Dst + '"')
        return 'busy'
    }

    $dstSize = Get-DirBytes -Path $Dst
    Write-Log ('目标体积=' + $dstSize)
    if ($dstSize -lt $srcSize) {
        Write-Log 'FAIL: 目标文件不完整，保留源目录'
        return 'fail'
    }

    $bak = $Src + '.moved.bak'
    if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue }
    try {
        Rename-Item -LiteralPath $Src -NewName ($leaf + '.moved.bak') -ErrorAction Stop
        Write-Log '源目录已改名备份'
    }
    catch {
        Write-Log ('FAIL: 源目录被占用，无法改名 -> ' + $_.Exception.Message)
        return 'fail'
    }

    cmd /c mklink /J "$Src" "$Dst" | Out-Null
    if (-not (Test-Path -LiteralPath $Src)) {
        Write-Log 'FAIL: 联接创建失败，正在回滚'
        Rename-Item -LiteralPath $bak -NewName $leaf
        return 'fail'
    }

    $link = Get-Item -LiteralPath $Src -Force
    Write-Log ('联接已建立: ' + $Src + ' -> ' + ($link.Target -join ','))
    Write-Log ('联接内文件数=' + (Get-ChildItem -LiteralPath $Src -Force -ErrorAction SilentlyContinue).Count)

    if ($KeepBackup) {
        Write-Log ('按要求保留备份 ' + $bak)
    }
    else {
        Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $bak) { Write-Log ('WARN: 备份仍被占用，稍后手动删除 ' + $bak) }
        else { Write-Log '备份已删除' }
    }
    return 'done'
}

$sysDrive = $env:SystemDrive.TrimEnd(':')
$sysFree = [math]::Round((Get-PSDrive -Name $sysDrive).Free / 1GB, 2)
Write-Log ('迁移开始 ' + $sysDrive + ': free=' + $sysFree + 'GB')

$results = @()

if ($Plan) {
    if (-not (Test-Path -LiteralPath $Plan)) { Write-Log ('FAIL: 清单不存在 ' + $Plan); exit 1 }
    $cfg = Get-Content -LiteralPath $Plan -Raw -Encoding UTF8 | ConvertFrom-Json
    $retire = $cfg.retire
    foreach ($p in $cfg.pairs) {
        $dst = Join-Path $retire $p.name
        $results += [pscustomobject]@{ Source = $p.source; Result = (Move-One -Src $p.source -Dst $dst) }
    }
}
elseif ($Source -and $Destination) {
    $results += [pscustomobject]@{ Source = $Source; Result = (Move-One -Src $Source -Dst $Destination) }
}
else {
    Write-Log 'FAIL: 需要 -Plan，或同时提供 -Source 与 -Destination'
    exit 1
}

Write-Log ''
Write-Log '=== 汇总 ==='
foreach ($r in $results) { Write-Log ($r.Result + '  ' + $r.Source) }
$sysFreeEnd = [math]::Round((Get-PSDrive -Name $sysDrive).Free / 1GB, 2)
Write-Log ('结束 ' + $sysDrive + ': free=' + $sysFreeEnd + 'GB')
