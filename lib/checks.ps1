<#
  dsh-shortcut 的环境自检。

  被 open-dsh.ps1 / setup-gui.ps1 / install.ps1 用 dot-source 引入，本身不执行任何动作。

  每个检查项返回一个对象：
    Id      机器可读的键（node / git / pnpm / repo / tsx / build / credentials / port）
    Label   界面上显示的名字
    Status  'ok' | 'warn' | 'fail'
    Detail  当前状态的一句话描述
    Hint    Status 不是 ok 时给用户的下一步
    Fix     可选。需要装东西时填依赖名（git|node|pnpm），向导据此挂「一键安装」按钮

  约定：
    fail = 不解决就没法启动 dsh
    warn = 能启动，但某些功能用不了（例如没有 git 就不能让向导帮你取 dsh）
#>

# 找一个外部命令。不要用 Get-Command 的 -ErrorAction，缺命令时它会写错误记录。
function Get-DshCommandInfo {
  param([Parameter(Mandatory)] [string] $Name)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $cmd) {
    return [pscustomobject]@{ Present = $false; Path = $null }
  }
  return [pscustomobject]@{ Present = $true; Path = $cmd.Source }
}

# 取外部命令的第一行版本输出。命令不存在、非零退出、超时都返回 $null。
function Get-DshCommandVersion {
  param(
    [Parameter(Mandatory)] [string] $Command,
    [string[]] $Arguments = @('--version')
  )
  try {
    $out = & $Command @Arguments 2>&1 | Select-Object -First 1
    if ($LASTEXITCODE -eq 0 -and $out) { return ("$out").Trim() }
  } catch {
    # 命令不存在或执行失败，按“没有版本信息”处理
  }
  return $null
}

# TCP 探测。端口有人监听返回 $true。
function Test-DshTcpPort {
  param([Parameter(Mandatory)] [int] $Port, [int] $TimeoutMs = 800)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
    $client.EndConnect($async)
    return $true
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function New-DshCheck {
  param(
    [Parameter(Mandatory)] [string] $Id,
    [Parameter(Mandatory)] [string] $Label,
    [Parameter(Mandatory)] [ValidateSet('ok', 'warn', 'fail')] [string] $Status,
    [string] $Detail = '',
    [string] $Hint = '',
    [string] $Fix = ''
  )
  return [pscustomobject]@{
    Id = $Id; Label = $Label; Status = $Status; Detail = $Detail; Hint = $Hint; Fix = $Fix
  }
}

<#
  跑完整自检。

  @param Settings - Resolve-DshShortcutSettings 的返回值（需要 Repo / DshHome / Port）。
  @returns 检查项数组，顺序即为界面显示顺序。
#>
function Get-DshCheckResults {
  param([Parameter(Mandatory)] [object] $Settings)

  $results = New-Object System.Collections.ArrayList
  $repo    = $Settings.Repo
  $port    = $Settings.Port

  # --- Node.js：启动 dsh 的硬前提 ---
  $nodeInfo = Get-DshCommandInfo 'node'
  if ($nodeInfo.Present) {
    $v = Get-DshCommandVersion -Command 'node' -Arguments @('-v')
    [void]$results.Add((New-DshCheck -Id 'node' -Label 'Node.js' -Status 'ok' -Detail "$v"))
  } else {
    [void]$results.Add((New-DshCheck -Id 'node' -Label 'Node.js' -Status 'fail' `
      -Detail '未安装' -Hint 'dsh 需要 Node.js 才能启动，可一键安装。' -Fix 'node'))
  }

  # --- Git：只有“帮你去取 dsh 检出”才需要，所以缺了只算警告 ---
  $gitInfo = Get-DshCommandInfo 'git'
  if ($gitInfo.Present) {
    $v = Get-DshCommandVersion -Command 'git' -Arguments @('--version')
    [void]$results.Add((New-DshCheck -Id 'git' -Label 'Git' -Status 'ok' -Detail "$v"))
  } else {
    [void]$results.Add((New-DshCheck -Id 'git' -Label 'Git' -Status 'warn' `
      -Detail '未安装' -Hint '已有 dsh 检出时可以不管；要让向导帮你下载 dsh 才需要。' -Fix 'git'))
  }

  # --- pnpm：同上，取 dsh 之后装依赖要用 ---
  $pnpmInfo = Get-DshCommandInfo 'pnpm'
  if ($pnpmInfo.Present) {
    $v = Get-DshCommandVersion -Command 'pnpm' -Arguments @('-v')
    [void]$results.Add((New-DshCheck -Id 'pnpm' -Label 'pnpm' -Status 'ok' -Detail "$v"))
  } else {
    $corepack = Get-DshCommandInfo 'corepack'
    $how = if ($corepack.Present) { '可用 Node 自带的 corepack 启用' } else { '可用 npm install -g pnpm 安装' }
    [void]$results.Add((New-DshCheck -Id 'pnpm' -Label 'pnpm' -Status 'warn' `
      -Detail '未安装' -Hint "已有 dsh 检出且装好依赖时可以不管；$how。" -Fix 'pnpm'))
  }

  # --- dsh 检出 ---
  $pkgJson = Join-DshPath $repo 'package.json'
  $cliSrc  = Join-DshPath $repo 'apps\cli\src\bin.ts'
  if (-not (Test-Path -LiteralPath $pkgJson)) {
    [void]$results.Add((New-DshCheck -Id 'repo' -Label 'dsh 检出' -Status 'fail' `
      -Detail "找不到：$repo" -Hint '选择你已有的 dsh 检出目录，或让向导帮你取一份。'))
  } elseif (-not (Test-Path -LiteralPath $cliSrc)) {
    [void]$results.Add((New-DshCheck -Id 'repo' -Label 'dsh 检出' -Status 'fail' `
      -Detail "不像 dsh 检出（缺 apps\cli\src\bin.ts）：$repo" -Hint '确认选的是 deepseek-harness 的源码检出根目录。'))
  } else {
    [void]$results.Add((New-DshCheck -Id 'repo' -Label 'dsh 检出' -Status 'ok' -Detail $repo))
  }

  # --- 依赖（tsx）：源码图必需 ---
  $tsxPkg = Join-DshPath $repo 'node_modules\tsx\package.json'
  if (Test-Path -LiteralPath $tsxPkg) {
    $tsxVersion = $null
    try { $tsxVersion = (Get-Content -LiteralPath $tsxPkg -Raw | ConvertFrom-Json).version } catch { }
    [void]$results.Add((New-DshCheck -Id 'tsx' -Label '依赖（tsx）' -Status 'ok' -Detail "$tsxVersion"))
  } else {
    [void]$results.Add((New-DshCheck -Id 'tsx' -Label '依赖（tsx）' -Status 'fail' `
      -Detail '未安装' -Hint "在 $repo 里执行 pnpm install。"))
  }

  # --- 构建产物：只影响构建图，源码图不需要 ---
  $builtBin = Join-DshPath $repo 'apps\cli\lib\bin.js'
  if (Test-Path -LiteralPath $builtBin) {
    [void]$results.Add((New-DshCheck -Id 'build' -Label '构建产物' -Status 'ok' -Detail 'apps\cli\lib\bin.js'))
  } else {
    [void]$results.Add((New-DshCheck -Id 'build' -Label '构建产物' -Status 'warn' `
      -Detail '缺失（仅影响 start-dsh-local.ps1 的构建图模式）' -Hint '需要时执行 pnpm run build；源码图不受影响。'))
  }

  # --- 凭据 ---
  $cred = Join-DshPath $Settings.DshHome '.credentials.yaml'
  if (Test-Path -LiteralPath $cred) {
    [void]$results.Add((New-DshCheck -Id 'credentials' -Label '凭据' -Status 'ok' -Detail $cred))
  } else {
    [void]$results.Add((New-DshCheck -Id 'credentials' -Label '凭据' -Status 'warn' `
      -Detail "找不到：$cred" -Hint '先手动跑一次 dsh 配置 API key；启动器也会尝试从默认 home 复制一份。'))
  }

  # --- 端口 ---
  if (Test-DshTcpPort -Port $port) {
    [void]$results.Add((New-DshCheck -Id 'port' -Label '端口' -Status 'warn' `
      -Detail "$port 已被占用" -Hint '若占用者是 dsh，启动器会直接打开它；否则换一个端口。'))
  } else {
    [void]$results.Add((New-DshCheck -Id 'port' -Label '端口' -Status 'ok' -Detail "$port 空闲"))
  }

  return $results.ToArray()
}

# 汇总成一句话 + 计数，给向导底部用。
function Get-DshCheckSummary {
  param([Parameter(Mandatory)] [object[]] $Checks)
  $fail = @($Checks | Where-Object { $_.Status -eq 'fail' }).Count
  $warn = @($Checks | Where-Object { $_.Status -eq 'warn' }).Count
  $ok   = @($Checks | Where-Object { $_.Status -eq 'ok' }).Count
  $text = if ($fail -gt 0) { "有 $fail 项必须解决" }
          elseif ($warn -gt 0) { "$ok 项正常，$warn 项可忽略" }
          else { "全部 $ok 项正常" }
  return [pscustomobject]@{ Ok = $ok; Warn = $warn; Fail = $fail; Text = $text; CanStart = ($fail -eq 0) }
}
