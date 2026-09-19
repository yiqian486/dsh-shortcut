<#
  dsh-shortcut 的依赖安装（git / node / pnpm）。

  依赖 lib/checks.ps1（Get-DshCommandInfo）和 lib/config.ps1（Join-DshPath），
  用之前请按这个顺序 dot-source：

      . .\lib\config.ps1
      . .\lib\checks.ps1
      . .\lib\deps.ps1

  设计原则：
    1. 优先 winget —— 有包 id、可静默、可升级，是最接近“一键”的路径。
    2. winget 不可用（老 Win10 / 精简系统）就退到打开官方下载页，让用户自己点。
       不做“替用户抓安装包再静默执行”——那既有直链解析的脆弱性，又等于绕过 UAC 装机器级软件。
    3. 装完必须刷新 PATH。当前进程的 PATH 是启动时的快照，不刷新就会出现
       “明明装好了却还是找不到”的经典现象。
    4. 任何路径都不改变系统状态，除非调用方明确调用了 Install-DshDependency。
#>

# winget 可执行文件。Get-Command 在部分环境下拿不到 WindowsApps 里的别名，
# 所以补一条兜底路径。
function Get-DshWingetPath {
  $cmd = Get-Command winget -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
  if (Test-Path -LiteralPath $alias) { return $alias }
  return $null
}

<#
  从注册表重读 Machine + User 的 PATH 并回填当前进程。

  装完 git/node 之后必须调用，否则新装的命令在当前会话里找不到。
  顺带补几个常见目录：winget 装的 Node/Git 有时不会立刻出现在注册表 PATH 里。
#>
function Update-DshProcessPath {
  $parts = New-Object System.Collections.ArrayList
  foreach ($scope in @('Machine', 'User')) {
    $value = [Environment]::GetEnvironmentVariable('Path', $scope)
    if (-not $value) { continue }
    foreach ($p in ($value -split ';')) {
      $t = $p.Trim()
      if ($t -and -not $parts.Contains($t)) { [void]$parts.Add($t) }
    }
  }
  foreach ($extra in @(
      (Join-Path $env:ProgramFiles 'nodejs'),
      (Join-Path $env:ProgramFiles 'Git\cmd'),
      (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd'),
      (Join-Path $env:APPDATA 'npm'),
      (Join-Path $env:LOCALAPPDATA 'Programs\nodejs')
    )) {
    if ($extra -and (Test-Path -LiteralPath $extra) -and -not $parts.Contains($extra)) { [void]$parts.Add($extra) }
  }
  $env:PATH = ($parts -join ';')
}

# 每个依赖的安装情报：winget 包 id、官方下载页、是否机器级（会弹 UAC）。
function Get-DshDependencyPlan {
  param([Parameter(Mandatory)] [ValidateSet('git', 'node', 'pnpm')] [string] $Name)
  switch ($Name) {
    'git' {
      return [pscustomobject]@{
        Name = 'git'; Label = 'Git'; WingetId = 'Git.Git'
        DownloadPage = 'https://git-scm.com/download/win'; NeedsAdmin = $true
      }
    }
    'node' {
      return [pscustomobject]@{
        Name = 'node'; Label = 'Node.js'; WingetId = 'OpenJS.NodeJS.LTS'
        DownloadPage = 'https://nodejs.org/en/download'; NeedsAdmin = $true
      }
    }
    'pnpm' {
      # pnpm 没有官方 winget 包，走 Node 自带的 corepack，退路是 npm -g。
      return [pscustomobject]@{
        Name = 'pnpm'; Label = 'pnpm'; WingetId = ''
        DownloadPage = 'https://pnpm.io/installation'; NeedsAdmin = $false
      }
    }
  }
}

<#
  生成安装步骤（不执行）。向导用它预览、Install-DshDependency 用它执行、测试用它断言。

  @returns 步骤数组，每项 { Kind, Text, File?, Args? }；Kind 取值 winget|corepack|npm|open。
#>
function Get-DshDependencySteps {
  param([Parameter(Mandatory)] [ValidateSet('git', 'node', 'pnpm')] [string] $Name)

  $spec = Get-DshDependencyPlan -Name $Name
  $steps = New-Object System.Collections.ArrayList

  if ($Name -eq 'pnpm') {
    # pnpm 优先 corepack（Node 自带，不额外装东西）
    if ((Get-DshCommandInfo 'corepack').Present) {
      [void]$steps.Add([pscustomobject]@{ Kind = 'corepack'; Text = 'corepack enable'; File = 'corepack'; Args = @('enable') })
      [void]$steps.Add([pscustomobject]@{ Kind = 'corepack'; Text = 'corepack prepare pnpm@latest --activate'; File = 'corepack'; Args = @('prepare', 'pnpm@latest', '--activate') })
    } elseif ((Get-DshCommandInfo 'npm').Present) {
      [void]$steps.Add([pscustomobject]@{ Kind = 'npm'; Text = 'npm install -g pnpm'; File = 'npm'; Args = @('install', '-g', 'pnpm') })
    } else {
      [void]$steps.Add([pscustomobject]@{ Kind = 'open'; Text = $spec.DownloadPage; File = $spec.DownloadPage; Args = @() })
    }
    return $steps.ToArray()
  }

  $winget = Get-DshWingetPath
  if ($winget) {
    $args = @('install', '--id', $spec.WingetId, '-e', '--source', 'winget',
      '--accept-package-agreements', '--accept-source-agreements')
    [void]$steps.Add([pscustomobject]@{
        Kind = 'winget'
        Text = "winget install --id $($spec.WingetId) -e --source winget --accept-package-agreements --accept-source-agreements"
        File = $winget; Args = $args
      })
  } else {
    [void]$steps.Add([pscustomobject]@{ Kind = 'open'; Text = $spec.DownloadPage; File = $spec.DownloadPage; Args = @() })
  }
  return $steps.ToArray()
}

<#
  安装一个依赖。

  @param OnOutput - 接收输出行的脚本块（向导的日志窗口用）；不传就写控制台。
  @param DryRun   - 只返回将要执行的步骤，不真的执行。测试和“预览”用。
  @returns { Name, Label, Ok, Method, Message, Steps[], NeedsManual, DownloadPage }
#>
function Install-DshDependency {
  param(
    [Parameter(Mandatory)] [ValidateSet('git', 'node', 'pnpm')] [string] $Name,
    [scriptblock] $OnOutput,
    [switch] $DryRun
  )

  $spec  = Get-DshDependencyPlan -Name $Name
  $steps = Get-DshDependencySteps -Name $Name
  $emit  = {
    param($m)
    if ($OnOutput) { & $OnOutput $m } else { Write-Host $m }
  }.GetNewClosure()

  if ($DryRun) {
    return [pscustomobject]@{
      Name = $Name; Label = $spec.Label; Ok = $false; Method = 'dryrun'
      Message = "将执行 $($steps.Count) 个步骤（DryRun，未真正执行）"
      Steps = $steps; NeedsManual = $false; DownloadPage = $spec.DownloadPage
    }
  }

  # 已经装好了就不用再装
  if ((Get-DshCommandInfo $Name).Present) {
    return [pscustomobject]@{
      Name = $Name; Label = $spec.Label; Ok = $true; Method = 'already'
      Message = "$($spec.Label) 已经存在，无需安装。"
      Steps = @(); NeedsManual = $false; DownloadPage = $spec.DownloadPage
    }
  }

  $method = ''
  $ok = $false

  if ($spec.NeedsAdmin) {
    & $emit "提示：安装 $($spec.Label) 是机器级操作，可能会弹出 UAC 授权框，请点「是」。"
  }

  foreach ($step in $steps) {
    if ($step.Kind -eq 'open') {
      & $emit "自动安装不可用，打开官方下载页：$($step.File)"
      try { Start-Process $step.File } catch { & $emit "打开浏览器失败：$($_.Exception.Message)" }
      $method = 'open'
      break
    }

    & $emit "> $($step.Text)"
    try {
      & $step.File @($step.Args) 2>&1 | ForEach-Object { & $emit "  $_" }
      $code = $LASTEXITCODE
    } catch {
      & $emit "执行失败：$($_.Exception.Message)"
      $code = 1
    }
    if ($code -ne 0) {
      & $emit "$($spec.Label) 安装命令以退出码 $code 结束。"
      $method = $step.Kind
      break
    }
    $method = $step.Kind
  }

  # 关键：重读 PATH，否则新装的命令在当前进程里找不到
  Update-DshProcessPath

  $present = (Get-DshCommandInfo $Name).Present
  $ok = $present

  $message = if ($ok) {
    "$($spec.Label) 安装完成。"
  } elseif ($method -eq 'open') {
    "已打开官方下载页，请手动安装 $($spec.Label) 后回来点「重新检测」。"
  } else {
    "$($spec.Label) 安装未成功，可改用官方下载页手动安装。"
  }

  return [pscustomobject]@{
    Name = $Name; Label = $spec.Label; Ok = $ok; Method = $method
    Message = $message; Steps = $steps; NeedsManual = (-not $ok)
    DownloadPage = $spec.DownloadPage
  }
}
