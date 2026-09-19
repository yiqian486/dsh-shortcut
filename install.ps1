<#
  为 open-dsh.ps1 创建 Windows 快捷方式(.lnk)。

  这个脚本只是命令行外壳；真正的生成逻辑在 lib/shortcut.ps1，向导 setup-gui.ps1 用同一份，
  避免两处逻辑漂移。

  用法:
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Place StartMenu
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Dir 'C:\tools\dsh-shortcut'
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Port 3081 -Name 'DSH (3081)'
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Repo 'C:\src\deepseek-harness'

  生成的快捷方式指向:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<本目录>\open-dsh.ps1" [-Port N] [-Repo <检出>]

  关于 -Repo:
    传了就把检出路径烧进快捷方式；**不传则不烧**，由 open-dsh.ps1 在运行时按
    「命令行参数 > DSH_REPO > config.json > 内置默认」解析。
    向导生成的快捷方式走的就是「不烧」这条路——否则快捷方式里的旧值（参数优先级更高）
    会压过用户之后在向导里改的 config.json。
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

$here = $PSScriptRoot
. (Join-Path $here 'lib\shortcut.ps1')

$launcher = Join-Path $here 'open-dsh.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { throw "找不到 open-dsh.ps1：$launcher" }

$placeKind = if ($Dir) { '指定目录' } elseif ($Place -eq 'Desktop') { '桌面' } else { '开始菜单' }

$result = New-DshShortcut -LauncherPath $launcher -Name $Name -Directory $Dir -Place $Place `
  -Port $Port -Repo $Repo -Force:$Force

if ($result.Skipped) {
  Write-Host "[install] $($result.Message)" -ForegroundColor Yellow
  exit 0
}

Write-Host "[install] 已创建($placeKind):$($result.Path)" -ForegroundColor Green
Write-Host "[install] target : $($result.TargetPath)"
Write-Host "[install] args   : $($result.Arguments)"
Write-Host "[install] workdir: $($result.WorkingDirectory)"
if (-not $Repo) {
  Write-Host '[install] 未绑定检出路径：启动时按 参数 > DSH_REPO > config.json > 默认 解析。' -ForegroundColor DarkGray
}
