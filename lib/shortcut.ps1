<#
  生成 / 删除 Windows 快捷方式（.lnk）。

  install.ps1（命令行）和 setup-gui.ps1（向导）共用这一份，避免两处逻辑漂移。
  本文件不依赖其它 lib，可单独 dot-source。

  关于 -Repo：
    传了就把检出路径烧进快捷方式的参数里；不传则不烧，让 open-dsh.ps1 在运行时按
    「命令行参数 > 环境变量 > config.json > 内置默认」解析。
    向导生成的快捷方式一律**不传** -Repo，否则快捷方式里的旧值会压过用户在向导里改的
    config.json —— 参数优先级高于 config。
#>

# 解析「桌面 / 开始菜单」的真实目录。
# 注意：某些环境下 [Environment]::GetFolderPath('Desktop') 会返回不存在的路径，
# 所以拿到后一律做存在性校验，不行再退回 USERPROFILE / APPDATA 下的常规位置。
# 全都不存在时返回 $null，由调用方决定怎么报错。
function Get-DshPlaceDirectory {
  param([Parameter(Mandatory)] [ValidateSet('Desktop', 'StartMenu')] [string] $Place)

  if ($Place -eq 'Desktop') {
    $candidates = @(
      [Environment]::GetFolderPath('Desktop'),
      [System.IO.Path]::Combine($env:USERPROFILE, 'Desktop')
    )
  } else {
    $candidates = @(
      [Environment]::GetFolderPath('StartMenu'),
      [System.IO.Path]::Combine($env:APPDATA, 'Microsoft\Windows\Start Menu\Programs')
    )
  }
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  return $null
}

# 组装快捷方式的参数串。用 -File 指向启动器，再按需附加 -Port / -Repo。
function Get-DshShortcutArguments {
  param(
    [Parameter(Mandatory)] [string] $LauncherPath,
    [int] $Port,
    [string] $Repo
  )
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$LauncherPath`""
  if ($Port) { $arguments += " -Port $Port" }
  if ($Repo) { $arguments += " -Repo `"$Repo`"" }
  return $arguments
}

# 图标：优先 node.exe（实际运行时），其次 powershell.exe。
function Get-DshShortcutIcon {
  $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
  if ($nodeExe -and (Test-Path -LiteralPath $nodeExe)) { return "$nodeExe,0" }
  return 'powershell.exe,0'
}

<#
  创建快捷方式。

  @param LauncherPath - 快捷方式要跑的 .ps1（通常是 open-dsh.ps1）。
  @param Name         - 快捷方式名字（不含 .lnk）。
  @param Directory    - 目标目录。给了就用它；不给就按 -Place 解析。
  @param Place        - Desktop | StartMenu，仅在没给 -Directory 时生效。
  @param Port / Repo  - 附加到快捷方式参数里；不传就不附加。
  @param IconLocation - 覆盖默认图标。
  @param Force        - 已存在时是否覆盖。
  @returns { Path, Created, Skipped, Arguments, TargetPath, WorkingDirectory, Message }
           已存在且未加 -Force 时 Skipped=$true 且 Created=$false。
#>
function New-DshShortcut {
  param(
    [Parameter(Mandatory)] [string] $LauncherPath,
    [Parameter(Mandatory)] [string] $Name,
    [string] $Directory,
    [ValidateSet('Desktop', 'StartMenu')] [string] $Place = 'Desktop',
    [int] $Port,
    [string] $Repo,
    [string] $IconLocation,
    [switch] $Force
  )

  if (-not (Test-Path -LiteralPath $LauncherPath)) {
    throw "找不到启动器：$LauncherPath"
  }

  $workingDirectory = Split-Path -Parent $LauncherPath

  if ($Directory) {
    if (-not (Test-Path -LiteralPath $Directory)) {
      New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    }
    $placeDir = (Resolve-Path -LiteralPath $Directory).ProviderPath
  } else {
    $placeDir = Get-DshPlaceDirectory -Place $Place
    if (-not $placeDir) {
      throw "找不到可用的目标目录（$Place）；请用 -Directory 指定一个。"
    }
  }

  $lnkPath = [System.IO.Path]::Combine($placeDir, "$Name.lnk")

  if ((Test-Path -LiteralPath $lnkPath) -and (-not $Force)) {
    return [pscustomobject]@{
      Path = $lnkPath; Created = $false; Skipped = $true
      Arguments = ''; TargetPath = ''; WorkingDirectory = $workingDirectory
      Message = "已存在：$lnkPath（要覆盖请加 -Force）"
    }
  }

  $powershellExe = [System.IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0\powershell.exe')
  if (-not (Test-Path -LiteralPath $powershellExe)) { $powershellExe = 'powershell.exe' }

  $arguments = Get-DshShortcutArguments -LauncherPath $LauncherPath -Port $Port -Repo $Repo
  if (-not $IconLocation) { $IconLocation = Get-DshShortcutIcon }

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($lnkPath)
  $shortcut.TargetPath       = $powershellExe
  $shortcut.Arguments        = $arguments
  $shortcut.WorkingDirectory = $workingDirectory
  $shortcut.IconLocation     = $IconLocation
  $shortcut.Description      = 'Open the local DeepSeek Harness Web GUI (starts it first when it is not running)'
  $shortcut.WindowStyle      = 1
  $shortcut.Save()

  if (-not (Test-Path -LiteralPath $lnkPath)) {
    throw "快捷方式创建失败：$lnkPath"
  }

  return [pscustomobject]@{
    Path = $lnkPath; Created = $true; Skipped = $false
    Arguments = $arguments; TargetPath = $powershellExe; WorkingDirectory = $workingDirectory
    Message = "已创建：$lnkPath"
  }
}

<# 删除快捷方式。文件本来就不存在时返回 $false（不算错误）。 #>
function Remove-DshShortcut {
  param([Parameter(Mandatory)] [string] $Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  Remove-Item -LiteralPath $Path -Force
  return (-not (Test-Path -LiteralPath $Path))
}
