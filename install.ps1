<#
  为 open-dsh.ps1 创建 Windows 快捷方式(.lnk)。

  用法:
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Place StartMenu
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Dir 'C:\tools\dsh-shortcut'
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Port 3081 -Name 'DSH (3081)'
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo 'C:\src\deepseek-harness'

  生成的快捷方式指向:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<本目录>\open-dsh.ps1" [-Port N] [-Repo <检出>]

  -Repo 会把你的 dsh 检出路径烧进快捷方式,这样别人(或换了机器)不用再设 DSH_REPO。
#>
[CmdletBinding()]
param(
  [ValidateSet('Desktop', 'StartMenu')] [string] $Place = 'Desktop',
  [string] $Dir,
  [string] $Name = '打开 DSH',
  [int]    $Port,
  [string] $Repo,
  [switch] $Force
)

$ErrorActionPreference = 'Stop'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here 'open-dsh.ps1'

if (-not (Test-Path $target)) { throw "找不到 open-dsh.ps1:$target" }

# 解析放置目录。注意:某些环境下 [Environment]::GetFolderPath('Desktop') 会返回不存在的路径,
# 所以拿到后一律做存在性校验,不行就退回 USERPROFILE / APPDATA 下的常规位置。
function Resolve-PlaceDirectory {
  param([string] $Place)
  if ($Place -eq 'Desktop') {
    $candidates = @(
      [Environment]::GetFolderPath('Desktop'),
      (Join-Path $env:USERPROFILE 'Desktop')
    )
  } else {
    $candidates = @(
      [Environment]::GetFolderPath('StartMenu'),
      (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    )
  }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  throw "找不到可用的目录:$($candidates -join ' | ')"
}

if ($Dir) {
  if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
  $placeDir = (Resolve-Path -LiteralPath $Dir).ProviderPath
  $placeKind = '指定目录'
} else {
  $placeDir  = Resolve-PlaceDirectory -Place $Place
  $placeKind = if ($Place -eq 'Desktop') { '桌面' } else { '开始菜单' }
}

$lnkPath = Join-Path $placeDir "$Name.lnk"
if ((Test-Path -LiteralPath $lnkPath) -and (-not $Force)) {
  Write-Host "[install] 已存在:$lnkPath(要覆盖请加 -Force)" -ForegroundColor Yellow
  exit 0
}

$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellExe)) { $powershellExe = 'powershell.exe' }

$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$target`""
if ($Port) { $arguments += " -Port $Port" }
if ($Repo) { $arguments += " -Repo `"$Repo`"" }

# 图标:优先用 node.exe(实际运行时),没有就用 PowerShell 自己的
$icon = 'powershell.exe,0'
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if ($nodeExe -and (Test-Path -LiteralPath $nodeExe)) { $icon = "$nodeExe,0" }

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnkPath)
$shortcut.TargetPath       = $powershellExe
$shortcut.Arguments        = $arguments
$shortcut.WorkingDirectory = $here
$shortcut.IconLocation     = $icon
$shortcut.Description      = 'Open the local DeepSeek Harness Web GUI (starts it first when it is not running)'
$shortcut.WindowStyle      = 1
$shortcut.Save()

if (Test-Path -LiteralPath $lnkPath) {
  Write-Host "[install] 已创建($placeKind):$lnkPath" -ForegroundColor Green
  Write-Host "[install] target : $powershellExe"
  Write-Host "[install] args   : $arguments"
  Write-Host "[install] workdir: $here"
} else {
  throw "创建失败:$lnkPath"
}
