<#
  setup-gui.ps1（WPF 向导）的自动化测试。

  用法：
    # 无头模式：不开窗，验证界面构建、事件装配、安装动作、输入校验、异步取数
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\setup-gui.tests.ps1

    # 额外真开一次窗口，3 秒后自动关闭。验证 ContentRendered -> 异步自检 -> 渲染 这条真实链路。
    # 需要桌面会话；无人值守环境别加。
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\setup-gui.tests.ps1 -ShowWindow

  隔离措施：config.json 写到 %DSH_SHORTCUT_CONFIG% 指定的临时文件，快捷方式写到临时目录，
  测试结束会检查真实环境（真实 config、桌面快捷方式）没有被波及。
#>
[CmdletBinding()]
param([switch] $ShowWindow)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot
$script:fail = 0

function Check {
  param([string] $Name, [bool] $Cond, [string] $Detail = '')
  if ($Cond) { Write-Host "  PASS  $Name" }
  else { Write-Host "  FAIL  $Name   [$Detail]" -ForegroundColor Red; $script:fail++ }
}

$workDir = Join-Path $here '.dsh-test-wizard'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$env:DSH_SHORTCUT_CONFIG = Join-Path $workDir 'config.json'
$global:tempPlace = Join-Path $workDir 'shortcuts'
Remove-Item -LiteralPath $env:DSH_SHORTCUT_CONFIG -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $global:tempPlace -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $global:tempPlace | Out-Null

. (Join-Path $here 'setup-gui.ps1') -NoRun

function GetBtn {
  param($Row)
  $b = $Row.FindName('btnFix')
  if (-not $b) { $b = $Row.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Button] } | Select-Object -First 1 }
  return $b
}

Write-Host "`n=== 1) 载入界面 + 装配 ===" -ForegroundColor Cyan
$w = Import-DshWizardXaml -Path (Get-DshWizardWindowPath)
Initialize-DshWizardWindow -Window $w
Check 'XAML 载入成功' ($null -ne $w)
Check 'tbRepo 已预填' ("$($w.FindName('tbRepo').Text)" -ne '') "$($w.FindName('tbRepo').Text)"
Check 'tbPort 已预填为数字' ("$($w.FindName('tbPort').Text)" -match '^\d+$') "$($w.FindName('tbPort').Text)"
Check 'tbName 已预填' ("$($w.FindName('tbName').Text)" -ne '') "$($w.FindName('tbName').Text)"
Check '来源提示已填' ("$($w.FindName('tbRepoSource').Text)" -ne '') "$($w.FindName('tbRepoSource').Text)"
Write-Host "     来源提示 = $($w.FindName('tbRepoSource').Text)"

Write-Host "`n=== 2) 同步自检：有效检出 ===" -ForegroundColor Cyan
Start-DshWizardCheck -Window $w -Synchronous
$rowCount = $w.FindName('pnlChecks').Children.Count
Check '自检渲染 8 行' ($rowCount -eq 8) "实际 $rowCount"
Check '摘要非空' ("$($w.FindName('tbSummary').Text)" -ne '') ''
Check '安装按钮可用' ($w.FindName('btnInstall').IsEnabled -eq $true) ''
Write-Host "     摘要 = $($w.FindName('tbSummary').Text)"

Write-Host "`n=== 3) 有 fail 项时安装按钮应禁用 ===" -ForegroundColor Cyan
$w.FindName('tbRepo').Text = 'C:\no-such-dsh'
Start-DshWizardCheck -Window $w -Synchronous
Check '安装按钮被禁用' ($w.FindName('btnInstall').IsEnabled -eq $false) "IsEnabled=$($w.FindName('btnInstall').IsEnabled)"
Write-Host "     摘要 = $($w.FindName('tbSummary').Text)"

Write-Host "`n=== 4) 一键安装按钮只出现在缺依赖的行 ===" -ForegroundColor Cyan
$withFix = [pscustomobject]@{ Id = 'node'; Label = 'Node.js'; Status = 'fail'; Detail = '未安装'; Hint = '需要 Node'; Fix = 'node' }
$noFix   = [pscustomobject]@{ Id = 'repo'; Label = 'dsh 检出'; Status = 'ok'; Detail = 'C:\x'; Hint = ''; Fix = '' }
$row1 = New-DshCheckRow -Check $withFix
$row2 = New-DshCheckRow -Check $noFix
Check '有 Fix 的行按钮可见' ($null -ne (GetBtn $row1) -and (GetBtn $row1).Visibility -eq [System.Windows.Visibility]::Visible) ''
Check '无 Fix 的行按钮折叠' ((GetBtn $row2).Visibility -eq [System.Windows.Visibility]::Collapsed) ''
Check '按钮 Tag 记录了依赖名' ((GetBtn $row1).Tag -eq 'node') "$((GetBtn $row1).Tag)"

$clicked = New-Object System.Collections.ArrayList
$row3 = New-DshCheckRow -Check $withFix -OnFix { param($n) [void]$clicked.Add($n) }
$btn3 = GetBtn $row3
$btn3.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
Check '点击按钮会调用 OnFix 并带上依赖名' (($clicked.Count -eq 1) -and ($clicked[0] -eq 'node')) "clicked=$($clicked -join ',')"

Write-Host "`n=== 5) 安装（重定向到临时目录） ===" -ForegroundColor Cyan
function Get-DshPlaceDirectory { param([string] $Place) return $global:tempPlace }
$w.FindName('tbRepo').Text = 'D:\deepseek-harness\deepseek-harness'
$w.FindName('tbPort').Text = '3080'
$w.FindName('cbDesktop').IsChecked = $true
$w.FindName('cbStartMenu').IsChecked = $false
$res = Invoke-DshWizardInstall -Window $w
Check '安装返回 Ok' ($res.Ok -eq $true) ($res.Errors -join '; ')
Check 'config.json 已写' (Test-Path -LiteralPath $res.ConfigPath) "$($res.ConfigPath)"
Check '快捷方式已建' ($res.Shortcuts.Count -eq 1 -and (Test-Path -LiteralPath $res.Shortcuts[0])) "$($res.Shortcuts -join ', ')"
if (Test-Path -LiteralPath $res.ConfigPath) {
  $cfg = Get-Content -LiteralPath $res.ConfigPath -Raw | ConvertFrom-Json
  Check 'config.repo 正确' ($cfg.repo -eq 'D:\deepseek-harness\deepseek-harness') "$($cfg.repo)"
  Check 'config.port = 3080' ($cfg.port -eq 3080) "$($cfg.port)"
}
if ($res.Shortcuts.Count -eq 1) {
  $shell = New-Object -ComObject WScript.Shell
  $lnkArgs = ($shell.CreateShortcut($res.Shortcuts[0])).Arguments
  Check '快捷方式不带 -Repo（让 config 生效）' ($lnkArgs -notmatch '-Repo') "$lnkArgs"
  Check '快捷方式带 -Port 3080' ($lnkArgs -match '-Port 3080') "$lnkArgs"
  Write-Host "     args = $lnkArgs"
}

Write-Host "`n=== 6) 输入校验 ===" -ForegroundColor Cyan
$w.FindName('tbPort').Text = 'abc'
$bad = Invoke-DshWizardInstall -Window $w
Check '非法端口被拦' (($bad.Ok -eq $false) -and (($bad.Errors -join ' ') -match '端口')) ($bad.Errors -join '; ')
$w.FindName('tbPort').Text = '3080'
$w.FindName('tbRepo').Text = 'C:\no-such-dsh'
$badRepo = Invoke-DshWizardInstall -Window $w
Check '无效检出被拦' (($badRepo.Ok -eq $false) -and (($badRepo.Errors -join ' ') -match 'dsh 检出')) ($badRepo.Errors -join '; ')
$w.FindName('tbRepo').Text = 'D:\deepseek-harness\deepseek-harness'
$w.FindName('cbDesktop').IsChecked = $false
$none = Invoke-DshWizardInstall -Window $w
Check '两个位置都不勾被拦' (($none.Ok -eq $false) -and (($none.Errors -join ' ') -match '快捷方式')) ($none.Errors -join '; ')

Write-Host "`n=== 7) 异步取数的 runspace 传参（Hashtable 跨 runspace） ===" -ForegroundColor Cyan
$shellPs = [powershell]::Create()
[void]$shellPs.AddScript({
    param($root, $bound)
    . (Join-Path $root 'lib\config.ps1')
    . (Join-Path $root 'lib\checks.ps1')
    Get-DshCheckResults -Settings (Resolve-DshShortcutSettings -Bound $bound)
  }).AddArgument($here).AddArgument(@{ Repo = 'C:\no-such-dsh' })
$handle = $shellPs.BeginInvoke()
$deadline = (Get-Date).AddSeconds(30)
while (-not $handle.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
$async = @($shellPs.EndInvoke($handle))
$shellPs.Dispose()
Check '异步返回 8 项' ($async.Count -eq 8) "实际 $($async.Count)"
$repoRow = @($async | Where-Object { $_.Id -eq 'repo' })[0]
Check '异步结果里 repo 为 fail（bound 真的传进去了）' ($repoRow.Status -eq 'fail') "$($repoRow.Status)"

Write-Host "`n=== 8) 真实环境未被波及 ===" -ForegroundColor Cyan
Check '真实 config 未被创建' (-not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.dsh-shortcut\config.json'))) ''
Check '真实快捷方式仍在' (Test-Path -LiteralPath (Join-Path $here '打开 DSH.lnk')) ''

if ($ShowWindow) {
  Write-Host "`n=== 9) 真开一次窗口（3 秒后自动关闭） ===" -ForegroundColor Cyan
  $real = Import-DshWizardXaml -Path (Get-DshWizardWindowPath)
  Initialize-DshWizardWindow -Window $real
  # 这里是「不显示窗口就测不到」的那条链路：ContentRendered 触发异步自检，
  # DispatcherTimer 轮询 runspace，完成后回来渲染行。必须真的跑消息循环。
  $real.Add_ContentRendered({ Start-DshWizardCheck -Window $real }.GetNewClosure()) | Out-Null
  $auto = New-Object System.Windows.Threading.DispatcherTimer
  $auto.Interval = [TimeSpan]::FromSeconds(3)
  $auto.Add_Tick({ $auto.Stop(); $real.Close() }.GetNewClosure())
  $auto.Start()
  [void]$real.ShowDialog()
  $rendered = $real.FindName('pnlChecks').Children.Count
  Check '开窗后异步自检渲染出 8 行' ($rendered -eq 8) "实际 $rendered"
  Check '开窗后摘要已更新' ("$($real.FindName('tbSummary').Text)" -ne '') ''
  Write-Host "     摘要 = $($real.FindName('tbSummary').Text)"
}

Remove-Item -LiteralPath $env:DSH_SHORTCUT_CONFIG -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $global:tempPlace -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "全部通过" -ForegroundColor Green }
else { Write-Host "$($script:fail) 项失败" -ForegroundColor Red; exit 1 }
