#Requires -Version 5.1
<#
.SYNOPSIS
  系统盘系统级清理：回收站、WinSxS 组件、保留存储、更新缓存、页面文件、休眠文件。

.DESCRIPTION
  这些操作会改变系统状态且不可逆（页面文件与休眠改动需重启生效）。
  建议在目录迁移完成后再执行，并且收尾时再清一次回收站：前序删除动作可能把文件转入回收站。

  需管理员权限运行；非管理员启动时脚本会自行提升。

.PARAMETER Recycle
  清空系统盘回收站。先试 Clear-RecycleBin，失败则逐项 rd /s /q。

.PARAMETER Dism
  运行 DISM StartComponentCleanup /ResetBase 压缩 WinSxS。耗时通常 5-20 分钟。

.PARAMETER ReservedStorage
  关闭 Windows 保留存储（释放约 7GB）。恢复用 -EnableReservedStorage。

.PARAMETER WindowsUpdateCache
  清空 SoftwareDistribution\Download。

.PARAMETER MovePagefile
  把页面文件迁到指定盘，例如 D:。需重启生效。

.PARAMETER DisableHibernate
  关闭休眠并删除 hiberfil.sys（powercfg /h off）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File system-cleanup.ps1 -Recycle -Dism -ReservedStorage
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File system-cleanup.ps1 -MovePagefile D:
#>
param(
    [switch]$Recycle,
    [switch]$Dism,
    [switch]$ReservedStorage,
    [switch]$EnableReservedStorage,
    [switch]$WindowsUpdateCache,
    [string]$MovePagefile,
    [switch]$DisableHibernate,
    [string]$LogFile
)

$sysDrive = $env:SystemDrive
$driveLetter = $sysDrive.TrimEnd(':')
if (-not $LogFile) { $LogFile = Join-Path (Get-Location) 'system-cleanup.log' }

function Write-Log($msg) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-FreeGB { return [math]::Round((Get-PSDrive -Name $driveLetter).Free / 1GB, 2) }

function Get-WinSxSGB {
    $p = Join-Path $sysDrive '\Windows\WinSxS'
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    return [math]::Round((Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum / 1GB, 2)
}

# ---- 管理员检查 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '需要管理员权限，正在请求提升……' -ForegroundColor Yellow
    $args = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    if ($Recycle) { $args += ' -Recycle' }
    if ($Dism) { $args += ' -Dism' }
    if ($ReservedStorage) { $args += ' -ReservedStorage' }
    if ($EnableReservedStorage) { $args += ' -EnableReservedStorage' }
    if ($WindowsUpdateCache) { $args += ' -WindowsUpdateCache' }
    if ($DisableHibernate) { $args += ' -DisableHibernate' }
    if ($MovePagefile) { $args += (' -MovePagefile ' + $MovePagefile) }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args
    return
}

Write-Log ('=== 开始 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===')
Write-Log ('free=' + (Get-FreeGB) + 'GB  WinSxS=' + (Get-WinSxSGB) + 'GB')

# ---- 回收站 ----
if ($Recycle) {
    Write-Log '--- 回收站 ---'
    $rb = Join-Path $sysDrive '\$Recycle.Bin'
    try {
        Clear-RecycleBin -DriveLetter $driveLetter -Force -ErrorAction Stop
        Write-Log 'Clear-RecycleBin 成功'
    }
    catch {
        Write-Log ('Clear-RecycleBin 失败: ' + $_.Exception.Message + '，改为逐项删除')
        Get-ChildItem -LiteralPath $rb -Force -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $sid = $_.FullName
            Get-ChildItem -LiteralPath $sid -Force -ErrorAction SilentlyContinue | ForEach-Object {
                cmd /c "rd /s /q `"$($_.FullName)`"" 2>$null
            }
        }
    }
    $rem = Get-ChildItem -LiteralPath $rb -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    Write-Log ('回收站残留 files=' + $rem.Count + ' GB=' + [math]::Round($rem.Sum / 1GB, 2))
    Write-Log ('free=' + (Get-FreeGB) + 'GB')
}

# ---- WinSxS ----
if ($Dism) {
    Write-Log '--- DISM StartComponentCleanup /ResetBase ---'
    $before = Get-FreeGB
    $w0 = Get-WinSxSGB
    $output = & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1
    Write-Log ('dism exit=' + $LASTEXITCODE)
    foreach ($line in ($output | Select-Object -Last 4)) { Write-Log ('dism: ' + $line) }
    $after = Get-FreeGB
    $w1 = Get-WinSxSGB
    Write-Log ('WinSxS ' + $w0 + ' -> ' + $w1 + 'GB; free ' + $before + ' -> ' + $after + 'GB')
    if ($LASTEXITCODE -ne 0 -and ($after - $before) -le 0.1) {
        Write-Log '提示：DISM 返回非 0 且空间未变化，可能需要先执行 DISM /Online /Cleanup-Image /StartComponentCleanup 或检查组件存储健康'
    }
}

# ---- 保留存储 ----
if ($ReservedStorage -or $EnableReservedStorage) {
    Write-Log '--- 保留存储 ---'
    $before = Get-FreeGB
    if ($ReservedStorage -and -not $EnableReservedStorage) {
        $out = & dism.exe /Online /Set-ReservedStorageState /State:Disabled 2>&1
        Write-Log ('disable exit=' + $LASTEXITCODE)
    }
    else {
        $out = & dism.exe /Online /Set-ReservedStorageState /State:Enabled 2>&1
        Write-Log ('enable exit=' + $LASTEXITCODE)
    }
    foreach ($line in ($out | Select-Object -Last 3)) { Write-Log ('dism: ' + $line) }
    Write-Log ('free ' + $before + ' -> ' + (Get-FreeGB) + 'GB')
}

# ---- 更新缓存 ----
if ($WindowsUpdateCache) {
    Write-Log '--- Windows Update 缓存 ---'
    $dl = Join-Path $sysDrive '\Windows\SoftwareDistribution\Download'
    if (Test-Path -LiteralPath $dl) {
        Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $dl -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        Write-Log ('已清空 ' + $dl)
    }
    Write-Log ('free=' + (Get-FreeGB) + 'GB')
}

# ---- 休眠 ----
if ($DisableHibernate) {
    Write-Log '--- 休眠 ---'
    & powercfg.exe /h off
    Write-Log ('powercfg exit=' + $LASTEXITCODE + ' hiberfil exists=' + (Test-Path -LiteralPath (Join-Path $sysDrive '\hiberfil.sys')))
    Write-Log ('free=' + (Get-FreeGB) + 'GB')
}

# ---- 页面文件 ----
if ($MovePagefile) {
    Write-Log '--- 页面文件 -> ' + $MovePagefile + ' ---'
    $target = $MovePagefile.TrimEnd('\') + '\pagefile.sys'
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($cs.AutomaticManagedPagefile) {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
            Write-Log '已关闭系统自动管理'
        }
        $existing = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue
        foreach ($pf in $existing) {
            Write-Log ('移除旧设置 ' + $pf.Name)
            Remove-CimInstance -InputObject $pf -ErrorAction Continue
        }
        $created = New-CimInstance -ClassName Win32_PageFileSetting -Property @{
            Name        = $target
            InitialSize = 8192
            MaximumSize = 16384
        } -ErrorAction Stop
        Write-Log ('已创建 ' + $created.Name + ' 初始 8192MB 上限 16384MB')
        Write-Log '需要重启后生效，旧盘上的 pagefile.sys 会在重启后消失'
    }
    catch {
        Write-Log ('FAIL: ' + $_.Exception.Message + '；可改用图形界面：系统属性→高级→性能→虚拟内存')
    }
}

Write-Log ('freeEnd=' + (Get-FreeGB) + 'GB  WinSxS=' + (Get-WinSxSGB) + 'GB')
Write-Log '=== 结束 ==='
