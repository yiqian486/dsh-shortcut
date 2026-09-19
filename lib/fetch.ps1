<#
  从 GitHub 取一份 dsh 检出（方案 B 的「一键获取」）。

  依赖（按顺序 dot-source）：
      . .\lib\config.ps1
      . .\lib\checks.ps1
      . .\lib\deps.ps1
      . .\lib\fetch.ps1

  流程：前置门禁 → git clone --depth 1 →（可选）pnpm install →（可选）pnpm run build → 复查

  为什么默认浅克隆：dsh 检出很大，`--depth 1` 只取最新一次提交，省时间省流量；
  别人要完整历史可以自己 `git fetch --unshallow`。

  为什么默认不 build：启动器走的是**源码图**（tsx），只需要 pnpm install；
  `pnpm run build` 很慢，只有要用构建图（start-dsh-local.ps1 -Mode lib）时才需要。

  验证边界：本模块的真实 clone / pnpm install 无法在无网络环境里验证。
  计划生成、目标目录判定、门禁、输出流、失败处理都可以用替身命令验证（见 tests/）。
#>

$script:DshRepoUrl = 'https://github.com/deepseek-ai/deepseek-harness.git'

function Get-DshRepoUrl {
  return $script:DshRepoUrl
}

<#
  目标目录判定。下载前先看清目标位置能不能用，避免下到一半才发现目录非空。

  @returns { State, Detail }
    'create'            目标不存在，可以创建
    'empty'             目标存在但是空目录，可以用
    'existing-checkout' 已经是一份 dsh 检出，直接用，不必下载
    'occupied'          存在且非空，且不是 dsh 检出——需要用户换目录或确认清空
#>
function Test-DshFetchTarget {
  param([Parameter(Mandatory)] [string] $Target)

  if (-not (Test-Path -LiteralPath $Target)) {
    return [pscustomobject]@{ State = 'create'; Detail = '目标目录不存在，将会创建。' }
  }
  if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    return [pscustomobject]@{ State = 'occupied'; Detail = '目标已存在而且是个文件，请换一个路径。' }
  }

  $hasPkg = Test-Path -LiteralPath (Join-DshPath $Target 'package.json')
  $hasCli = Test-Path -LiteralPath (Join-DshPath $Target 'apps\cli\src\bin.ts')
  if ($hasPkg -and $hasCli) {
    return [pscustomobject]@{ State = 'existing-checkout'; Detail = '这里已经是一份 dsh 检出，可以直接用，不必下载。' }
  }

  $children = @(Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue)
  if ($children.Count -eq 0) {
    return [pscustomobject]@{ State = 'empty'; Detail = '目标目录是空的，可以用。' }
  }
  return [pscustomobject]@{ State = 'occupied'; Detail = "目标目录非空（$($children.Count) 项）且不是 dsh 检出，请换目录或先清空。" }
}

<#
  生成下载计划（不执行）。向导拿它预览，测试拿它断言。

  @returns 步骤数组，每项 { Kind, Text, File, Args, WorkingDirectory, Optional }
           注意：PowerShell 会把**单元素数组解包成标量**，而 Windows PowerShell 5.1 下
           PSCustomObject 没有 .Count。调用方要取数量请写 @(Get-DshFetchPlan ...).Count。
#>
function Get-DshFetchPlan {
  param(
    [Parameter(Mandatory)] [string] $Target,
    [string] $Url,
    [string] $Ref,
    [switch] $SkipInstall,
    [switch] $WithBuild
  )

  if (-not $Url) { $Url = $script:DshRepoUrl }

  $steps = New-Object System.Collections.ArrayList
  $parent = Split-Path -Parent $Target

  # --- 1) 浅克隆。目标用绝对路径，所以从哪儿执行都行 ---
  $cloneArgs = @('clone', '--depth', '1')
  if ($Ref) { $cloneArgs += @('--branch', $Ref) }
  $cloneArgs += @($Url, $Target)
  [void]$steps.Add([pscustomobject]@{
      Kind = 'git-clone'; Optional = $false; WorkingDirectory = $parent
      Text = "git clone --depth 1$($(if ($Ref) { " --branch $Ref" } else { '' })) $Url <目标>"
      File = 'git'; Args = $cloneArgs
    })

  if (-not $SkipInstall) {
    # --- 2) 装依赖。必须在检出目录里跑 ---
    [void]$steps.Add([pscustomobject]@{
        Kind = 'pnpm-install'; Optional = $false; WorkingDirectory = $Target
        Text = 'pnpm install'; File = 'pnpm'; Args = @('install')
      })

    if ($WithBuild) {
      [void]$steps.Add([pscustomobject]@{
          Kind = 'pnpm-build'; Optional = $true; WorkingDirectory = $Target
          Text = 'pnpm run build（可选，只有构建图需要）'; File = 'pnpm'; Args = @('run', 'build')
        })
    }
  }

  return $steps.ToArray()
}

<#
  执行下载。

  @param OnOutput - 接收输出行的脚本块（向导的日志窗口用）。
  @param DryRun   - 只返回计划与门禁结论，不执行任何命令。
  @param Plan     - 直接给定步骤（测试用替身命令，或先预览再执行）。不给就现算。
  @returns { Ok, Target, Gate, Steps, Messages[], FailedStep, NeedsManual }
#>
function Invoke-DshFetch {
  param(
    [Parameter(Mandatory)] [string] $Target,
    [string] $Url,
    [string] $Ref,
    [switch] $SkipInstall,
    [switch] $WithBuild,
    [scriptblock] $OnOutput,
    [switch] $DryRun,
    [object[]] $Plan
  )

  $emit = {
    param($m)
    if ($OnOutput) { & $OnOutput $m } else { Write-Host $m }
  }.GetNewClosure()

  $messages = New-Object System.Collections.ArrayList

  $targetState = Test-DshFetchTarget -Target $Target
  [void]$messages.Add($targetState.Detail)
  & $emit $targetState.Detail

  if (-not $Plan) {
    $Plan = Get-DshFetchPlan -Target $Target -Url $Url -Ref $Ref -SkipInstall:$SkipInstall -WithBuild:$WithBuild
  }

  # --- 前置门禁：先看 git / node / pnpm 齐不齐，不齐就别开始 ---
  $gate = Get-DshMissingDependencies
  $gateText = if ($gate.Ready) { '前置依赖齐备。' } else { "缺少前置依赖：$($gate.Missing -join '、')" }
  [void]$messages.Add($gateText)
  & $emit $gateText

  if ($DryRun) {
    foreach ($step in $Plan) { & $emit "> $($step.Text)" }
    return [pscustomobject]@{
      Ok = $false; Target = $Target; Gate = $gate; Steps = $Plan
      Messages = $messages.ToArray(); FailedStep = ''; NeedsManual = $false
    }
  }

  if ($targetState.State -eq 'existing-checkout') {
    return [pscustomobject]@{
      Ok = $true; Target = $Target; Gate = $gate; Steps = @()
      Messages = $messages.ToArray(); FailedStep = ''; NeedsManual = $false
    }
  }
  if ($targetState.State -eq 'occupied') {
    return [pscustomobject]@{
      Ok = $false; Target = $Target; Gate = $gate; Steps = $Plan
      Messages = $messages.ToArray(); FailedStep = 'target'; NeedsManual = $true
    }
  }
  if (-not $gate.Ready) {
    & $emit '请先在上面的自检里把缺的依赖装上，再回来点「获取 dsh」。'
    return [pscustomobject]@{
      Ok = $false; Target = $Target; Gate = $gate; Steps = $Plan
      Messages = $messages.ToArray(); FailedStep = 'gate'; NeedsManual = $true
    }
  }

  # --- 执行 ---
  $failed = ''
  foreach ($step in $Plan) {
    & $emit "> $($step.Text)"

    $exitCode = 1
    $at = $null
    try {
      if ($step.WorkingDirectory) { $at = $step.WorkingDirectory }
      if ($at -and (Test-Path -LiteralPath $at)) { Push-Location -LiteralPath $at }
      & $step.File @($step.Args) 2>&1 | ForEach-Object { & $emit "  $_" }
      $exitCode = $LASTEXITCODE
    } catch {
      & $emit "  执行失败：$($_.Exception.Message)"
      $exitCode = 1
    } finally {
      if ($at -and (Test-Path -LiteralPath $at)) { Pop-Location }
    }

    if ($exitCode -ne 0) {
      $failed = $step.Kind
      & $emit "  $($step.Kind) 以退出码 $exitCode 结束。"
      if ($step.Kind -eq 'git-clone') {
        & $emit '  clone 失败通常是网络问题：GitHub 在国内可能需要加速器/代理。'
      }
      if ($step.Optional) {
        & $emit '  这一步是可选的，继续。'
        $failed = ''
        continue
      }
      break
    }
  }

  # --- 复查：命令退出码为 0 不代表结果正确 ---
  $ok = ($failed -eq '')
  if ($ok) {
    $hasPkg = Test-Path -LiteralPath (Join-DshPath $Target 'package.json')
    $hasCli = Test-Path -LiteralPath (Join-DshPath $Target 'apps\cli\src\bin.ts')
    if (-not ($hasPkg -and $hasCli)) {
      $ok = $false
      $failed = 'verify-checkout'
      & $emit '  下载结束，但目标目录不像 dsh 检出（缺 package.json 或 apps\cli）。'
    }
  }
  if ($ok -and -not $SkipInstall) {
    if (-not (Test-Path -LiteralPath (Join-DshPath $Target 'node_modules\tsx\package.json'))) {
      $ok = $false
      $failed = 'verify-install'
      & $emit '  依赖装完后仍找不到 tsx，pnpm install 可能没成功。'
    }
  }

  $final = if ($ok) { "已获取 dsh 检出：$Target" } else { "获取未完成（失败于 $failed）。" }
  [void]$messages.Add($final)

  return [pscustomobject]@{
    Ok = $ok; Target = $Target; Gate = $gate; Steps = $Plan
    Messages = $messages.ToArray(); FailedStep = $failed; NeedsManual = (-not $ok)
  }
}
