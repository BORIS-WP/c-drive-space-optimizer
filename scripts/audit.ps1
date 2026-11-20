#Requires -Version 5.1
<#
.SYNOPSIS
  审计 Windows 系统盘占用：按目录分级列出大户，并列出既有目录联接。

.DESCRIPTION
  递归统计目录体积时会跳过重解析点（Junction/Symlink），避免把已经搬到其他盘的数据
  重复计入本盘。同时对系统文件、回收站、页面文件做单独统计，用于与 fsutil 口径交叉验证。

.PARAMETER Drive
  要审计的盘符，默认 C。

.PARAMETER Root
  指定审计根目录；默认使用 Drive 根。适合只扫某个用户目录。

.PARAMETER Top
  每一层列出前 N 项，默认 20。

.PARAMETER MinChildGB
  第二层展开阈值：只有超过该体积的目录才继续下钻，默认 0.5。

.PARAMETER OutFile
  报告输出文件路径；不填则只打印到控制台。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File audit.ps1 -Drive C -Top 20 -OutFile .\audit.txt
#>
param(
    [string]$Drive = 'C',
    [string]$Root,
    [int]$Top = 20,
    [double]$MinChildGB = 0.5,
    [string]$OutFile
)

$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]
function Emit($text) {
    $lines.Add([string]$text) | Out-Null
    Write-Output ([string]$text)
}

function Get-TreeStat {
    param([string]$Path)
    $bytes = [long]0
    $files = 0
    $links = 0
    $errors = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $children = $null
        try { $children = [System.IO.Directory]::EnumerateFileSystemEntries($dir) }
        catch { $errors++; continue }
        try {
            foreach ($entry in $children) {
                $info = $null
                try { $info = New-Object System.IO.FileInfo $entry } catch { $errors++; continue }
                $isDir = $false
                try { $isDir = [System.IO.Directory]::Exists($entry) } catch { }
                if ($isDir) {
                    $di = $null
                    try { $di = New-Object System.IO.DirectoryInfo $entry } catch { $errors++; continue }
                    if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $links++
                        continue
                    }
                    $stack.Push($entry)
                }
                else {
                    $files++
                    $bytes += $info.Length
                }
            }
        }
        catch { $errors++ }
    }
    [pscustomobject]@{
        Path   = $Path
        Bytes  = $bytes
        Files  = $files
        Links  = $links
        Errors = $errors
    }
}

function Format-GB($bytes) { return [math]::Round($bytes / 1GB, 2) }

# ---- 盘位概览 ----
Emit ('=== 盘位概览 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===')
Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    if ($null -ne $_.Used -and ($_.Used + $_.Free) -gt 0) {
        Emit ("{0}: used={1}GB free={2}GB total={3}GB" -f $_.Name,
            [math]::Round($_.Used / 1GB, 2),
            [math]::Round($_.Free / 1GB, 2),
            [math]::Round(($_.Used + $_.Free) / 1GB, 2))
    }
}

if (-not $Root) { $Root = $Drive.TrimEnd(':') + ':\' }
Emit ''
Emit ('=== 顶层目录（' + $Root + '，已跳过联接） ===')

$level1 = @()
foreach ($d in (Get-ChildItem -LiteralPath $Root -Force -Directory -ErrorAction SilentlyContinue)) {
    $st = Get-TreeStat -Path $d.FullName
    $level1 += [pscustomobject]@{ Path = $d.FullName; GB = (Format-GB $st.Bytes); Files = $st.Files; Links = $st.Links; Errors = $st.Errors }
}
$level1 = $level1 | Sort-Object GB -Descending
$level1 | Select-Object -First $Top | ForEach-Object {
    Emit ("{0,8} GB  files={1,-8} links={2,-4} errors={3,-4} {4}" -f $_.GB, $_.Files, $_.Links, $_.Errors, $_.Path)
}

Emit ''
Emit ('=== 第二层（体积 > ' + $MinChildGB + 'GB 的目录继续展开） ===')
$level2 = @()
foreach ($p in ($level1 | Where-Object { $_.GB -ge $MinChildGB })) {
    foreach ($c in (Get-ChildItem -LiteralPath $p.Path -Force -Directory -ErrorAction SilentlyContinue)) {
        $st = Get-TreeStat -Path $c.FullName
        $level2 += [pscustomobject]@{ Parent = $p.Path; Path = $c.FullName; GB = (Format-GB $st.Bytes); Files = $st.Files; Links = $st.Links }
    }
}
$level2 | Sort-Object GB -Descending | Select-Object -First ($Top * 2) | ForEach-Object {
    Emit ("{0,8} GB  files={1,-8} links={2,-4} {3}" -f $_.GB, $_.Files, $_.Links, $_.Path)
}

# ---- 系统文件 ----
Emit ''
Emit '=== 系统级占用 ==='
foreach ($f in 'pagefile.sys', 'hiberfil.sys', 'swapfile.sys') {
    $p = Join-Path ($Drive.TrimEnd(':') + ':\') $f
    if (Test-Path -LiteralPath $p) {
        $fi = Get-Item -LiteralPath $p -Force
        Emit ("{0,8} GB  {1}" -f (Format-GB $fi.Length), $p)
    }
    else { Emit ("       0 GB  {0} (不存在)" -f $p) }
}
$rb = Join-Path ($Drive.TrimEnd(':') + ':\') '$Recycle.Bin'
if (Test-Path -LiteralPath $rb) {
    $stat = Get-TreeStat -Path $rb
    Emit ("{0,8} GB  files={1}  {2}" -f (Format-GB $stat.Bytes), $stat.Files, $rb)
}
$winsxs = Join-Path ($Drive.TrimEnd(':') + ':\') 'Windows\WinSxS'
if (Test-Path -LiteralPath $winsxs) {
    $stat = Get-TreeStat -Path $winsxs
    Emit ("{0,8} GB  (含硬链接，实际占用更小)  {1}" -f (Format-GB $stat.Bytes), $winsxs)
}

# ---- 既有联接 ----
Emit ''
Emit '=== 既有目录联接 ==='
$junctions = @()
$userProfile = $env:USERPROFILE
foreach ($dir in @($userProfile, (Join-Path $userProfile 'AppData\Local'), (Join-Path $userProfile 'AppData\Roaming'), $Root)) {
    if (Test-Path -LiteralPath $dir) {
        foreach ($item in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($item.LinkType) {
                $junctions += $item
                Emit ("{0}  [{1}]  ->  {2}" -f $item.FullName, $item.LinkType, ($item.Target -join ','))
            }
        }
    }
}
if ($junctions.Count -eq 0) { Emit '（无）' }

# ---- 分级建议 ----
Emit ''
Emit '=== 分级建议（参考 references/decision-matrix.md） ==='
Emit '可搬：用户缓存/日志目录、包管理器缓存、IDE 索引、IM 收发文件、桌面与下载目录'
Emit '谨慎：运行中的应用数据、浏览器配置、Docker 数据（优先用应用内设置改路径）'
Emit '禁止：Program Files、Windows、WinSxS、驱动目录、AppData\Local\Programs 下的应用本体'

if ($OutFile) {
    $lines -join [Environment]::NewLine | Set-Content -LiteralPath $OutFile -Encoding UTF8
    Write-Host ('报告已写入 ' + $OutFile)
}
