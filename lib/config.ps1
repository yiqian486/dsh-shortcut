<#
  dsh-shortcut 的配置读写与路径解析。

  这个文件被 open-dsh.ps1 / start-dsh-local.ps1 / install.ps1 / setup-gui.ps1 用 dot-source 引入
  （`. .\lib\config.ps1`），本身不执行任何动作。

  配置文件位置：%USERPROFILE%\.dsh-shortcut\config.json（可用环境变量 DSH_SHORTCUT_CONFIG 覆盖）。

  解析优先级（高 → 低）：
    1. 命令行参数        -Repo / -DshHome / -DevHome / -Port
    2. 环境变量          DSH_REPO / DSH_HOME / DSH_DEV_HOME / DSH_PORT
    3. config.json       repo / dshHome / devHome / port
    4. 内置默认值

  没有 config.json 时行为与引入本文件之前完全一致（向后兼容）。
  只用 PowerShell 5.1 自带能力，不依赖任何模块。
#>

# 配置文件路径。DSH_SHORTCUT_CONFIG 可指向别处（测试/便携版用）。
function Get-DshShortcutConfigPath {
  if ($env:DSH_SHORTCUT_CONFIG) { return $env:DSH_SHORTCUT_CONFIG }
  return (Join-Path $env:USERPROFILE '.dsh-shortcut\config.json')
}

# 拼接路径。**不要用 Join-Path 做这里的活**：碰到不存在的盘符（例如别人传了
# -Repo 'E:\x' 而本机没有 E 盘），Join-Path 会抛 DriveNotFoundException，配合
# $ErrorActionPreference='Stop' 直接变成终止错误——用户只会看到一个闪掉的窗口，
# 连自检消息都来不及看。
# [System.IO.Path]::Combine 只做字符串拼接；之后交给 Test-Path 判断（它面对不存在的
# 盘符返回 $false，不抛异常）。
function Join-DshPath {
  param(
    [Parameter(Mandatory)] [string] $Base,
    [Parameter(Mandatory)] [string] $Child
  )
  return [System.IO.Path]::Combine($Base, $Child)
}

# 读配置。文件不存在或内容坏掉时返回 $null，只给一句警告，不抛错——
# 配置坏了不该让启动器直接不可用。
function Read-DshShortcutConfig {
  $path = Get-DshShortcutConfigPath
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch {
    Write-Warning "配置文件读取失败，已忽略：$path（$($_.Exception.Message)）"
    return $null
  }
}

# 写配置。JSON 不带 BOM（BOM 会让某些 JSON 解析器犯嘀咕）。
function Save-DshShortcutConfig {
  param([Parameter(Mandatory)] [System.Collections.IDictionary] $Values)

  $path = Get-DshShortcutConfigPath
  $dir = Split-Path -Parent $path
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $json = ($Values | ConvertTo-Json -Depth 6)
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
  return $path
}

# 按优先级挑一个值。$IsBound 表示「命令行显式传了」，这是唯一能和「参数默认值」区分开的信号。
function Resolve-DshShortcutSetting {
  param(
    [switch] $IsBound,
    [object] $BoundValue,
    [string] $EnvName,
    [object] $ConfigValue,
    [object] $Default
  )
  if ($IsBound -and $null -ne $BoundValue -and "$BoundValue".Trim() -ne '') { return $BoundValue }
  if ($EnvName) {
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv -and $fromEnv.Trim() -ne '') { return $fromEnv }
  }
  if ($null -ne $ConfigValue -and "$ConfigValue".Trim() -ne '') { return $ConfigValue }
  return $Default
}

# 端口单独处理：环境变量和 config 里都是字符串，得校验成数字再用。
function Resolve-DshShortcutPort {
  param(
    [switch] $IsBound,
    [object] $BoundValue,
    [object] $ConfigValue,
    [int] $Default = 3080
  )
  if ($IsBound -and "$BoundValue" -match '^\d+$') { return [int]$BoundValue }
  $fromEnv = [Environment]::GetEnvironmentVariable('DSH_PORT')
  if ($fromEnv -and $fromEnv -match '^\d+$') { return [int]$fromEnv }
  if ($null -ne $ConfigValue -and "$ConfigValue" -match '^\d+$') { return [int]$ConfigValue }
  return $Default
}

# 判断调用方是否显式传了某个参数。
# 注意：$PSBoundParameters 的实际类型是 Dictionary<string,object> 的子类，它的
# IDictionary.Contains 是显式接口实现，PowerShell 调不到（会报 "Cannot find an overload
# for Contains"）。所以统一走 Keys -contains，对 Hashtable / Dictionary / PSBoundParameters
# 三种都成立。
function Test-DshShortcutBound {
  param([System.Collections.IDictionary] $Bound, [string] $Name)
  if ($null -eq $Bound) { return $false }
  return ($Bound.Keys -contains $Name)
}

<#
  一次性解出全部路径与端口。

  @param Bound - 调用方的 $PSBoundParameters，用来区分「显式传参」和「参数默认值」。
  @returns 带 Repo / DshHome / DevHome / Port / Config / ConfigPath / RepoSource 的对象。
           RepoSource 取值 param|env|config|default，供向导提示「当前用的是哪来的」。
#>
function Resolve-DshShortcutSettings {
  param([System.Collections.IDictionary] $Bound = @{})

  if ($null -eq $Bound) { $Bound = @{} }
  $cfg = Read-DshShortcutConfig

  $repoBound = Test-DshShortcutBound -Bound $Bound -Name 'Repo'
  $homeBound = Test-DshShortcutBound -Bound $Bound -Name 'DshHome'
  $devBound  = Test-DshShortcutBound -Bound $Bound -Name 'DevHome'
  $portBound = Test-DshShortcutBound -Bound $Bound -Name 'Port'

  # 逐个来源试一遍，好知道最终这个值是打哪来的（向导要显示）
  $repo = $null
  $repoSource = 'default'
  if ($repoBound -and "$($Bound['Repo'])".Trim() -ne '') {
    $repo = $Bound['Repo']; $repoSource = 'param'
  } elseif ($env:DSH_REPO -and $env:DSH_REPO.Trim() -ne '') {
    $repo = $env:DSH_REPO; $repoSource = 'env'
  } elseif ($cfg -and $cfg.repo -and "$($cfg.repo)".Trim() -ne '') {
    $repo = $cfg.repo; $repoSource = 'config'
  } else {
    $repo = 'D:\deepseek-harness\deepseek-harness'
  }

  return [pscustomobject]@{
    Repo       = $repo
    RepoSource = $repoSource
    DshHome    = Resolve-DshShortcutSetting -IsBound:$homeBound -BoundValue $Bound['DshHome'] `
                   -EnvName 'DSH_HOME' -ConfigValue $cfg.dshHome -Default (Join-Path $env:USERPROFILE '.dsh')
    DevHome    = Resolve-DshShortcutSetting -IsBound:$devBound -BoundValue $Bound['DevHome'] `
                   -EnvName 'DSH_DEV_HOME' -ConfigValue $cfg.devHome -Default (Join-Path $env:USERPROFILE '.dsh-dev-home')
    Port       = Resolve-DshShortcutPort -IsBound:$portBound -BoundValue $Bound['Port'] `
                   -ConfigValue $cfg.port -Default 3080
    Config     = $cfg
    ConfigPath = Get-DshShortcutConfigPath
  }
}
