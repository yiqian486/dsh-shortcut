<#
  lib/fetch.ps1（一键获取 dsh 检出）的测试。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\fetch.tests.ps1

  真实的 git clone / pnpm install 需要网络，这里测不了——那两条只能靠本机实测。
  本文件覆盖的是：计划生成、目标目录判定、前置门禁、输出回传、退出码处理、
  可选步骤、以及**用替身命令走通的完整成功路径与失败路径**。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot
$script:fail = 0

function Check {
  param([string] $Name, [bool] $Cond, [string] $Detail = '')
  if ($Cond) { Write-Host "  PASS  $Name" }
  else { Write-Host "  FAIL  $Name   [$Detail]" -ForegroundColor Red; $script:fail++ }
}

. (Join-Path $here 'lib\config.ps1')
. (Join-Path $here 'lib\checks.ps1')
. (Join-Path $here 'lib\deps.ps1')
. (Join-Path $here 'lib\fetch.ps1')

$work = Join-Path $here '.dsh-test-fetch'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null

$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# 造一个「像 dsh 检出」的目录的辅助脚本，给替身步骤当副作用用
$maker = Join-Path $work 'make-checkout.ps1'
@'
param([string] $Target)
New-Item -ItemType Directory -Force -Path (Join-Path $Target 'apps\cli\src') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Target 'node_modules\tsx') | Out-Null
'{}' | Set-Content -LiteralPath (Join-Path $Target 'package.json')
'x'  | Set-Content -LiteralPath (Join-Path $Target 'apps\cli\src\bin.ts')
'{"version":"4.22.4"}' | Set-Content -LiteralPath (Join-Path $Target 'node_modules\tsx\package.json')
'@ | Set-Content -LiteralPath $maker -Encoding UTF8

Write-Host "`n=== 1) 计划生成 ===" -ForegroundColor Cyan
$target = Join-Path $work 'checkout'
$plan = Get-DshFetchPlan -Target $target
Check '默认两步（克隆 + 装依赖）' (@($plan).Count -eq 2) "实际 $(@($plan).Count)"
Check '克隆用浅克隆' (($plan[0].Args -contains '--depth') -and ($plan[0].Args -contains '1')) ($plan[0].Args -join ' ')
Check '克隆目标是绝对路径' ($plan[0].Args[-1] -eq $target) "$($plan[0].Args[-1])"
Check '装依赖的工作目录是检出目录' ($plan[1].WorkingDirectory -eq $target) "$($plan[1].WorkingDirectory)"
Write-Host "     步骤1: $($plan[0].Text)"
Write-Host "     步骤2: $($plan[1].Text)"

$planB = Get-DshFetchPlan -Target $target -WithBuild -Ref 'main'
Check '-WithBuild 变三步' (@($planB).Count -eq 3) "实际 $(@($planB).Count)"
Check '-Ref 生成 --branch' (($planB[0].Args -contains '--branch') -and ($planB[0].Args -contains 'main')) ($planB[0].Args -join ' ')
Check 'build 标为可选' ($planB[2].Optional -eq $true) ''
# 这一行原来是 (...).Count，在 Windows PowerShell 5.1 下**必然失败**：
# PowerShell 把单元素数组解包成标量，而 5.1 的 PSCustomObject 没有 .Count（pwsh 7 才有）。
# 所以凡是对「可能只有一个元素」的返回值取数量，一律先 @() 包一层。
Check '-SkipInstall 时不出现 install' (@(Get-DshFetchPlan -Target $target -SkipInstall).Count -eq 1) ''

Write-Host "`n=== 2) 目标目录判定 ===" -ForegroundColor Cyan
Check '不存在 → create' ((Test-DshFetchTarget -Target (Join-Path $work 'nope')).State -eq 'create') ''
$empty = Join-Path $work 'empty'
New-Item -ItemType Directory -Force -Path $empty | Out-Null
Check '空目录 → empty' ((Test-DshFetchTarget -Target $empty).State -eq 'empty') ''
$occupied = Join-Path $work 'occupied'
New-Item -ItemType Directory -Force -Path $occupied | Out-Null
'x' | Set-Content -LiteralPath (Join-Path $occupied 'something.txt')
Check '非空且不是检出 → occupied' ((Test-DshFetchTarget -Target $occupied).State -eq 'occupied') ''
$existing = Join-Path $work 'existing'
& $ps51 -NoProfile -ExecutionPolicy Bypass -File $maker -Target $existing
Check '已是 dsh 检出 → existing-checkout' ((Test-DshFetchTarget -Target $existing).State -eq 'existing-checkout') ''

Write-Host "`n=== 3) DryRun 不产生副作用 ===" -ForegroundColor Cyan
$dryTarget = Join-Path $work 'dry-target'
$dry = Invoke-DshFetch -Target $dryTarget -DryRun
Check 'DryRun 没有创建目录' (-not (Test-Path -LiteralPath $dryTarget)) ''
Check 'DryRun 返回计划' (@($dry.Steps).Count -eq 2) "实际 $(@($dry.Steps).Count)"
Check 'DryRun 带门禁结论' ($null -ne $dry.Gate) ''

Write-Host "`n=== 4) 前置门禁：缺 git 时拒绝执行 ===" -ForegroundColor Cyan
$global:captured = New-Object System.Collections.ArrayList
function Get-DshCommandInfo { param([string] $Name) return [pscustomobject]@{ Present = $false; Path = $null } }
$gateTarget = Join-Path $work 'gate-target'
$gateRes = Invoke-DshFetch -Target $gateTarget -OnOutput { param($m) [void]$global:captured.Add("$m") }
Check '被门禁拦下' ($gateRes.FailedStep -eq 'gate') "$($gateRes.FailedStep)"
Check '列出全部缺失项' (($gateRes.Gate.Missing -join ',') -eq 'git,node,pnpm') "$($gateRes.Gate.Missing -join ',')"
Check '拦下时没有创建目录' (-not (Test-Path -LiteralPath $gateTarget)) ''
Check '拦下时提示先装依赖' (($global:captured -join "`n") -match '先在上面的自检里') ''
# 后面几段测的是「执行与失败恢复」，不是门禁本身。这里把依赖探测固定为「全部齐备」，
# 免得测试结果取决于跑测机器上有没有 pnpm（CI 的 windows-latest 默认没有）。
function Get-DshCommandInfo {
  param([string] $Name)
  return [pscustomobject]@{ Present = $true; Path = "$env:SystemRoot\System32\cmd.exe" }
}

Write-Host "`n=== 5) 成功路径（替身命令，不联网） ===" -ForegroundColor Cyan
$global:captured = New-Object System.Collections.ArrayList
$fresh = Join-Path $work 'fresh-checkout'
$successPlan = @([pscustomobject]@{
    Kind = 'git-clone'; Optional = $false; WorkingDirectory = $work
    Text = 'stub clone'; File = $ps51
    Args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $maker, '-Target', $fresh)
  })
$ok = Invoke-DshFetch -Target $fresh -Plan $successPlan -SkipInstall -OnOutput { param($m) [void]$global:captured.Add("$m") }
Check '成功路径 Ok' ($ok.Ok -eq $true) "FailedStep=$($ok.FailedStep)"
Check '替身真造出了检出' (Test-Path -LiteralPath (Join-Path $fresh 'apps\cli\src\bin.ts')) ''
Check '含复查通过的消息' (($ok.Messages -join ' ') -match '已获取 dsh 检出') "$($ok.Messages -join ' | ')"

Write-Host "`n=== 6) 失败路径：clone 非零退出 ===" -ForegroundColor Cyan
$global:captured = New-Object System.Collections.ArrayList
$failTarget = Join-Path $work 'fail-target'
$failPlan = @([pscustomobject]@{
    Kind = 'git-clone'; Optional = $false; WorkingDirectory = $work
    Text = 'stub clone failing'; File = $ps51; Args = @('-NoProfile', '-Command', 'exit 3')
  })
$failRes = Invoke-DshFetch -Target $failTarget -Plan $failPlan -SkipInstall -OnOutput { param($m) [void]$global:captured.Add("$m") }
Check '失败被识别' ($failRes.Ok -eq $false -and $failRes.FailedStep -eq 'git-clone') "Ok=$($failRes.Ok) Failed=$($failRes.FailedStep)"
Check '报告了退出码' (($global:captured -join "`n") -match '退出码 3') ''
Check '给了网络排查提示' (($global:captured -join "`n") -match '加速器') ''

Write-Host "`n=== 7) 可选步骤失败不应中断 ===" -ForegroundColor Cyan
$global:captured = New-Object System.Collections.ArrayList
$optionalTarget = Join-Path $work 'optional-target'
$optionalPlan = @(
  [pscustomobject]@{ Kind = 'pnpm-build'; Optional = $true; WorkingDirectory = $work
    Text = 'stub optional build failing'; File = $ps51; Args = @('-NoProfile', '-Command', 'exit 7') },
  [pscustomobject]@{ Kind = 'git-clone'; Optional = $false; WorkingDirectory = $work
    Text = 'stub clone'; File = $ps51; Args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $maker, '-Target', $optionalTarget) }
)
$optRes = Invoke-DshFetch -Target $optionalTarget -Plan $optionalPlan -SkipInstall -OnOutput { param([string] $m) [void]$global:captured.Add($m) }
Check '可选步骤失败后继续并最终成功' ($optRes.Ok -eq $true) "FailedStep=$($optRes.FailedStep)"
Check '提示该步是可选的' (($global:captured -join "`n") -match '这一步是可选的') ''

Write-Host "`n=== 8) 目标目录被占用时拒绝 ===" -ForegroundColor Cyan
$occRes = Invoke-DshFetch -Target $occupied -SkipInstall
Check 'occupied 被拒' ($occRes.Ok -eq $false -and $occRes.FailedStep -eq 'target') "Ok=$($occRes.Ok) Failed=$($occRes.FailedStep)"

Write-Host "`n=== 9) 本来就有检出时直接复用 ===" -ForegroundColor Cyan
$exRes = Invoke-DshFetch -Target $existing -SkipInstall
Check 'existing-checkout 直接成功' ($exRes.Ok -eq $true) "FailedStep=$($exRes.FailedStep)"
Check '复用时不执行任何步骤' (@($exRes.Steps).Count -eq 0) "实际 $(@($exRes.Steps).Count)"

Write-Host "`n=== 10) 依赖 DryRun 的步数文案（5.1 下 .Count 的回归） ===" -ForegroundColor Cyan
# lib/deps.ps1 里那句「将执行 N 个步骤」原本写的是 $steps.Count，单步依赖在 5.1 下会变成空白。
$dryGit = Install-DshDependency -Name 'git' -DryRun
Check 'git 计划文案步数正确' ($dryGit.Message -match '将执行 1 个步骤') "$($dryGit.Message)"
$dryPnpm = Install-DshDependency -Name 'pnpm' -DryRun
Check 'pnpm 计划文案步数为数字' ($dryPnpm.Message -match '将执行 [0-9]+ 个步骤') "$($dryPnpm.Message)"

Write-Host "`n=== 11) 失败恢复：清理本次留下的半个目录 ===" -ForegroundColor Cyan
# clone 中断会留下「非空但又不是检出」的目录；不清理，用户重试就会被「目录非空」挡住。
$partialTarget = Join-Path $work 'partial-target'
$makePartial = "New-Item -ItemType Directory -Force -Path '$partialTarget' | Out-Null; 'half' | Set-Content -LiteralPath '$partialTarget\.git-partial'"
$partialPlan = @(
  [pscustomobject]@{ Kind = 'git-clone'; Optional = $false; WorkingDirectory = $work
    Text = 'stub partial clone'; File = $ps51; Args = @('-NoProfile', '-Command', $makePartial) },
  [pscustomobject]@{ Kind = 'pnpm-install'; Optional = $false; WorkingDirectory = $partialTarget
    Text = 'stub install failing'; File = $ps51; Args = @('-NoProfile', '-Command', 'exit 5') }
)
$global:captured = New-Object System.Collections.ArrayList
$partialRes = Invoke-DshFetch -Target $partialTarget -Plan $partialPlan -OnOutput { param($m) [void]$global:captured.Add("$m") }
Check '整体判定为失败' ($partialRes.Ok -eq $false) "Ok=$($partialRes.Ok)"
Check '半个目录被清理掉' (-not (Test-Path -LiteralPath $partialTarget)) '目录还在'
Check '日志说明了已清理' (($global:captured -join "`n") -match '已清理本次失败留下的目录') ''
Check '清理后重试不再被「目录非空」挡住' ((Test-DshFetchTarget -Target $partialTarget).State -eq 'create') ''

# 同一个失败场景加 -KeepFailedTarget：应当保留现场
$keepTarget = Join-Path $work 'keep-target'
$keepPartial = "New-Item -ItemType Directory -Force -Path '$keepTarget' | Out-Null; 'half' | Set-Content -LiteralPath '$keepTarget\.git-partial'"
$keepPlan = @(
  [pscustomobject]@{ Kind = 'git-clone'; Optional = $false; WorkingDirectory = $work
    Text = 'stub partial clone'; File = $ps51; Args = @('-NoProfile', '-Command', $keepPartial) },
  [pscustomobject]@{ Kind = 'pnpm-install'; Optional = $false; WorkingDirectory = $keepTarget
    Text = 'stub install failing'; File = $ps51; Args = @('-NoProfile', '-Command', 'exit 5') }
)
$keepRes = Invoke-DshFetch -Target $keepTarget -Plan $keepPlan -KeepFailedTarget
Check '-KeepFailedTarget 时保留现场' (Test-Path -LiteralPath $keepTarget) '现场被删了'

# 安全断言：就算失败，也不能删掉一个**有效检出**（可能只是依赖没装上，留着让用户修）
$safeTarget = Join-Path $work 'safe-target'
$safePlan = @(
  [pscustomobject]@{ Kind = 'git-clone'; Optional = $false; WorkingDirectory = $work
    Text = 'stub full checkout'; File = $ps51
    Args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $maker, '-Target', $safeTarget) },
  [pscustomobject]@{ Kind = 'pnpm-install'; Optional = $false; WorkingDirectory = $safeTarget
    Text = 'stub install failing'; File = $ps51; Args = @('-NoProfile', '-Command', 'exit 5') }
)
$safeRes = Invoke-DshFetch -Target $safeTarget -Plan $safePlan
Check '失败于装依赖时仍判定失败' ($safeRes.Ok -eq $false) "Ok=$($safeRes.Ok)"
Check '有效检出不会被误删' (Test-Path -LiteralPath (Join-DshPath $safeTarget 'package.json')) '检出被删了'

# 目标目录本来就存在（empty）时，失败也不该删别人的目录
$preTarget = Join-Path $work 'pre-existing'
New-Item -ItemType Directory -Force -Path $preTarget | Out-Null
$prePlan = @([pscustomobject]@{ Kind = 'git-clone'; Optional = $false; WorkingDirectory = $work
    Text = 'stub failing clone'; File = $ps51; Args = @('-NoProfile', '-Command', 'exit 5') })
$preRes = Invoke-DshFetch -Target $preTarget -Plan $prePlan
Check '预先存在的目录失败后仍保留' (Test-Path -LiteralPath $preTarget) '被删了'

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host "全部通过" -ForegroundColor Green }
else { Write-Host "$($script:fail) 项失败" -ForegroundColor Red; exit 1 }
