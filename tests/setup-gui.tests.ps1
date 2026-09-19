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

# 记下项目目录里那个真实快捷方式在测试前是否存在：测试不该改动它。
# 断言比的是「状态没变」而不是「一定存在」—— CI 上本来就没有这个文件。
$script:realLnkBefore = Test-Path -LiteralPath (Join-Path $here '打开 DSH.lnk')

$workDir = Join-Path $here '.dsh-test-wizard'
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$env:DSH_SHORTCUT_CONFIG = Join-Path $workDir 'config.json'
$global:tempPlace = Join-Path $workDir 'shortcuts'
Remove-Item -LiteralPath $env:DSH_SHORTCUT_CONFIG -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $global:tempPlace -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $global:tempPlace | Out-Null

# 造一份「假 dsh 检出」。测试**不能**依赖机器上真有一份检出，更不能依赖作者本机的默认路径 ——
# 之前第 2 段用的是默认值、第 5 段把路径写死成 D:\deepseek-harness\deepseek-harness，
# 于是本地全绿、CI 上必红（CI 没有那个目录）。
$fakeCheckout = Join-Path $workDir 'fake-checkout'
New-Item -ItemType Directory -Force -Path (Join-Path $fakeCheckout 'apps\cli\src') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $fakeCheckout 'node_modules\tsx') | Out-Null
'{}' | Set-Content -LiteralPath (Join-Path $fakeCheckout 'package.json')
'x' | Set-Content -LiteralPath (Join-Path $fakeCheckout 'apps\cli\src\bin.ts')
'{"version":"4.22.4"}' | Set-Content -LiteralPath (Join-Path $fakeCheckout 'node_modules\tsx\package.json')

. (Join-Path $here 'setup-gui.ps1') -NoRun

function GetBtn {
  param($Row)
  $b = $Row.FindName('btnFix')
  if (-not $b) { $b = $Row.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Button] } | Select-Object -First 1 }
  return $b
}

# 从自检行里取出标签文字。行的结构是
#   Border > Grid > [ Ellipse, StackPanel > StackPanel > TextBlock, Button ]
# 取不到就返回一个显眼的占位串，让断言失败时能看出是结构变了，而不是假装通过。
function GetRowLabels {
  param($Panel)
  $labels = New-Object System.Collections.ArrayList
  foreach ($row in $Panel.Children) {
    $grid = $row.Child
    $outer = $grid.Children | Where-Object { $_ -is [System.Windows.Controls.StackPanel] } | Select-Object -First 1
    $inner = $outer.Children | Where-Object { $_ -is [System.Windows.Controls.StackPanel] } | Select-Object -First 1
    $label = $inner.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] } | Select-Object -First 1
    [void]$labels.Add($(if ($label) { $label.Text } else { '<取不到标签>' }))
  }
  return $labels.ToArray()
}

Write-Host "`n=== 1) 载入界面 + 装配 ===" -ForegroundColor Cyan
$w = Import-DshWizardXaml -Path (Get-DshWizardWindowPath)
Initialize-DshWizardWindow -Window $w
Check 'XAML 载入成功' ($null -ne $w)
Check 'tbRepo 已预填' ("$($w.FindName('tbRepo').Text)" -ne '') "$($w.FindName('tbRepo').Text)"
Check 'tbPort 已预填为数字' ("$($w.FindName('tbPort').Text)" -match '^\d+$') "$($w.FindName('tbPort').Text)"
Check 'tbName 已预填' ("$($w.FindName('tbName').Text)" -ne '') "$($w.FindName('tbName').Text)"
Check '来源提示已填' ("$($w.FindName('tbRepoSource').Text)" -ne '') "$($w.FindName('tbRepoSource').Text)"
Check '「获取 dsh」按钮存在' ($null -ne $w.FindName('btnFetch')) ''
Check '「前置依赖」容器存在' ($null -ne $w.FindName('pnlDeps')) ''
Check '「前置依赖」摘要控件存在' ($null -ne $w.FindName('tbDepsSummary')) ''
Write-Host "     来源提示 = $($w.FindName('tbRepoSource').Text)"

Write-Host "`n=== 2) 同步自检：有效检出 ===" -ForegroundColor Cyan
# 显式指向假检出，不用默认值 —— 默认值是作者本机路径，CI 上不存在
$w.FindName('tbRepo').Text = $fakeCheckout
Start-DshWizardCheck -Window $w -Synchronous
$depCount = $w.FindName('pnlDeps').Children.Count
$envCount = $w.FindName('pnlChecks').Children.Count
Check '「前置依赖」渲染 3 行' ($depCount -eq 3) "实际 $depCount"
Check '「环境自检」渲染 5 行' ($envCount -eq 5) "实际 $envCount"
Check '两处合计仍是 8 项' (($depCount + $envCount) -eq 8) "$depCount + $envCount"
Check '「前置依赖」摘要已填' ("$($w.FindName('tbDepsSummary').Text)" -ne '') "$($w.FindName('tbDepsSummary').Text)"
$depLabels = @(GetRowLabels -Panel $w.FindName('pnlDeps'))
$envLabels = @(GetRowLabels -Panel $w.FindName('pnlChecks'))
Check 'Node/Git/pnpm 都落在「前置依赖」块' (($depLabels -contains 'Node.js') -and ($depLabels -contains 'Git') -and ($depLabels -contains 'pnpm')) "$($depLabels -join ' | ')"
Check '检出相关项都落在「环境自检」块' (($envLabels -contains 'dsh 检出') -and ($envLabels -contains '依赖（tsx）') -and ($envLabels -contains '构建产物') -and ($envLabels -contains '凭据') -and ($envLabels -contains '端口')) "$($envLabels -join ' | ')"
Check '依赖项没有混进「环境自检」块' (-not ($envLabels -contains 'Node.js')) "$($envLabels -join ' | ')"
Write-Host "     前置依赖 = $($depLabels -join ', ')  [$($w.FindName('tbDepsSummary').Text)]"
Write-Host "     环境自检 = $($envLabels -join ', ')"
Check '摘要非空' ("$($w.FindName('tbSummary').Text)" -ne '') ''
Check '安装按钮可用' ($w.FindName('btnInstall').IsEnabled -eq $true) ''
Write-Host "     摘要 = $($w.FindName('tbSummary').Text)"

# 「前置依赖」那句摘要的三条分支都要覆盖到
Update-DshWizardChecks -Window $w -Checks @(
  [pscustomobject]@{ Id = 'node'; Label = 'Node.js'; Status = 'fail'; Detail = '未安装'; Hint = ''; Fix = 'node'; Group = 'dep' },
  [pscustomobject]@{ Id = 'repo'; Label = 'dsh 检出'; Status = 'ok'; Detail = 'C:\x'; Hint = ''; Fix = ''; Group = 'env' }
) | Out-Null
Check '缺必需依赖时摘要说「必须先装」' ("$($w.FindName('tbDepsSummary').Text)" -match '必须先装') "$($w.FindName('tbDepsSummary').Text)"
Update-DshWizardChecks -Window $w -Checks @(
  [pscustomobject]@{ Id = 'git'; Label = 'Git'; Status = 'warn'; Detail = '未安装'; Hint = ''; Fix = 'git'; Group = 'dep' },
  [pscustomobject]@{ Id = 'repo'; Label = 'dsh 检出'; Status = 'ok'; Detail = 'C:\x'; Hint = ''; Fix = ''; Group = 'env' }
) | Out-Null
Check '只缺可选依赖时摘要说只影响「获取 dsh」' ("$($w.FindName('tbDepsSummary').Text)" -match '只影响') "$($w.FindName('tbDepsSummary').Text)"

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
$w.FindName('tbRepo').Text = $fakeCheckout
$w.FindName('tbPort').Text = '3080'
$w.FindName('cbDesktop').IsChecked = $true
$w.FindName('cbStartMenu').IsChecked = $false
$res = Invoke-DshWizardInstall -Window $w
Check '安装返回 Ok' ($res.Ok -eq $true) ($res.Errors -join '; ')
Check 'config.json 已写' (Test-Path -LiteralPath $res.ConfigPath) "$($res.ConfigPath)"
Check '快捷方式已建' (@($res.Shortcuts).Count -eq 1 -and (Test-Path -LiteralPath @($res.Shortcuts)[0])) "$($res.Shortcuts -join ', ')"
if (Test-Path -LiteralPath $res.ConfigPath) {
  $cfg = Get-Content -LiteralPath $res.ConfigPath -Raw | ConvertFrom-Json
  Check 'config.repo 正确' ($cfg.repo -eq $fakeCheckout) "$($cfg.repo)"
  Check 'config.port = 3080' ($cfg.port -eq 3080) "$($cfg.port)"
}
if (@($res.Shortcuts).Count -eq 1) {
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
$w.FindName('tbRepo').Text = $fakeCheckout
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
Check '项目目录里的快捷方式未被改动' ((Test-Path -LiteralPath (Join-Path $here '打开 DSH.lnk')) -eq $script:realLnkBefore) ''

if ($ShowWindow) {
  Write-Host "`n=== 9) 真开窗口：异步自检 + 获取 dsh 的完整链路 ===" -ForegroundColor Cyan
  $real = Import-DshWizardXaml -Path (Get-DshWizardWindowPath)
  Initialize-DshWizardWindow -Window $real
  # 这里是「不显示窗口就测不到」的那条链路：ContentRendered 触发异步自检，
  # DispatcherTimer 轮询 runspace，完成后回来渲染行。必须真的跑消息循环。
  $real.Add_ContentRendered({ Start-DshWizardCheck -Window $real }.GetNewClosure()) | Out-Null

  # 顺带把「获取 dsh」的异步链路也走一遍。目标故意指向一个**被占用**的目录：
  # Invoke-DshFetch 在联网之前就会拒绝，所以这里不碰网络，却能验证
  # runspace → 共享队列 → DispatcherTimer → 日志窗口 这条完整通路。
  $occupiedDir = Join-Path $workDir 'occupied-target'
  New-Item -ItemType Directory -Force -Path $occupiedDir | Out-Null
  'stray' | Set-Content -LiteralPath (Join-Path $occupiedDir 'stray.txt')

  $phase = 0
  $auto = New-Object System.Windows.Threading.DispatcherTimer
  $auto.Interval = [TimeSpan]::FromMilliseconds(1200)
  $tickAuto = {
    $phase++
    if ($phase -eq 1) {
      Start-DshWizardFetch -Window $real -Target $occupiedDir
    } elseif ($phase -ge 4) {
      $auto.Stop()
      $real.Close()
    }
  }.GetNewClosure()
  $auto.Add_Tick($tickAuto)
  $auto.Start()
  [void]$real.ShowDialog()

  # 异步路径也要走同一条分流逻辑，所以这里一并验证两块的行数
  $renderedDeps = $real.FindName('pnlDeps').Children.Count
  $renderedEnv = $real.FindName('pnlChecks').Children.Count
  Check '开窗后异步自检渲染出 3 + 5 行' (($renderedDeps -eq 3) -and ($renderedEnv -eq 5)) "$renderedDeps + $renderedEnv"
  Check '开窗后摘要已更新' ("$($real.FindName('tbSummary').Text)" -ne '') ''
  $fetchLog = "$($real.FindName('tbLog').Text)"
  Check '获取流程的输出进了日志窗口' ($fetchLog -match '非空') "日志=$fetchLog"
  Check '获取结束后「获取 dsh」按钮恢复可用' ($real.FindName('btnFetch').IsEnabled -eq $true) "IsEnabled=$($real.FindName('btnFetch').IsEnabled)"
  Write-Host "     摘要 = $($real.FindName('tbSummary').Text)"
}

Remove-Item -LiteralPath $env:DSH_SHORTCUT_CONFIG -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $global:tempPlace -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "全部通过" -ForegroundColor Green }
else { Write-Host "$($script:fail) 项失败" -ForegroundColor Red; exit 1 }
