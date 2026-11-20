#Requires -Version 5.1
<#
.SYNOPSIS
  验证目录联接是否有效，并输出系统盘清理前后的空间对比。

.DESCRIPTION
  逐个检查用户目录、AppData 与系统盘根下的联接：目标是否存在、是否位于指定盘、
  链接内可见条目数。目标缺失通常意味着目标盘未挂载或目标目录被移动/删除，
  此时应立即停止使用该路径并恢复数据。

.PARAMETER TargetDrive
  期望承接数据的盘符，例如 D。为空则不做盘符校验。

.PARAMETER OutFile
  报告输出文件。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File verify.ps1 -TargetDrive D
#>
param(
    [string]$TargetDrive,
    [string]$OutFile
)

$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]
function Emit($text) {
    $lines.Add([string]$text) | Out-Null
    Write-Output ([string]$text)
}

$sysDrive = $env:SystemDrive
$driveLetter = $sysDrive.TrimEnd(':')

Emit ('=== 联接验证 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===')

$roots = @(
    $env:USERPROFILE,
    (Join-Path $env:USERPROFILE 'AppData\Local'),
    (Join-Path $env:USERPROFILE 'AppData\Roaming'),
    $sysDrive + '\'
)

$total = 0
$broken = 0
$wrongDrive = 0
foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($item in (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
        if (-not $item.LinkType) { continue }
        $total++
        $target = ($item.Target -join ',')
        $exists = $false
        if ($item.Target) { $exists = Test-Path -LiteralPath ($item.Target | Select-Object -First 1) }

        $status = 'OK'
        if (-not $exists) { $status = 'BROKEN'; $broken++ }
        if ($TargetDrive -and $item.Target) {
            $t = ($item.Target | Select-Object -First 1)
            $expected = $TargetDrive.TrimEnd(':').ToUpper()
            $actual = ''
            if ($t.Length -ge 2 -and $t.Substring(1, 1) -eq ':') { $actual = $t.Substring(0, 1).ToUpper() }
            if ($actual -ne $expected) { $status = $status + ' WRONGDRIVE(' + $actual + ')'; $wrongDrive++ }
        }

        $count = 0
        try { $count = (Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue).Count } catch { }

        Emit ("{0,-6} {1}  ->  {2}  items={3}" -f $status, $item.FullName, $target, $count)
    }
}

Emit ''
Emit ('联接总数=' + $total + '  失效=' + $broken + '  盘符不符=' + $wrongDrive)
if ($broken -gt 0) { Emit '警告：存在失效联接，请检查目标盘是否已卸载，或目标目录是否被移动/删除。' }

Emit ''
Emit '=== 磁盘空间 ==='
Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    if ($null -ne $_.Used -and ($_.Used + $_.Free) -gt 0) {
        Emit ("{0}: used={1}GB free={2}GB total={3}GB" -f $_.Name,
            [math]::Round($_.Used / 1GB, 2),
            [math]::Round($_.Free / 1GB, 2),
            [math]::Round(($_.Used + $_.Free) / 1GB, 2))
    }
}

Emit ''
Emit '=== 页面文件与休眠文件位置 ==='
foreach ($p in 'pagefile.sys', 'hiberfil.sys') {
    foreach ($d in (Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Free })) {
        $f = Join-Path ($d.Name + ':\') $p
        if (Test-Path -LiteralPath $f) {
            $fi = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            Emit ("{0}: {1}GB" -f $f, [math]::Round($fi.Length / 1GB, 2))
        }
    }
}
Emit ('休眠状态: ' + (& powercfg.exe /a 2>&1 | Select-Object -First 1))

if ($OutFile) {
    $lines -join [Environment]::NewLine | Set-Content -LiteralPath $OutFile -Encoding UTF8
    Write-Host ('报告已写入 ' + $OutFile)
}
