<#
  构建发布产物：

    dist\dsh-shortcut-setup-<版本>.exe      Inno Setup 安装包
    dist\dsh-shortcut-portable-<版本>.zip   免安装版，解压即用

  用法：
    powershell -ExecutionPolicy Bypass -File .\installer\build.ps1
    powershell -ExecutionPolicy Bypass -File .\installer\build.ps1 -Version 0.2.0
    powershell -ExecutionPolicy Bypass -File .\installer\build.ps1 -LintOnly        # 只对账，不需要 Inno Setup
    powershell -ExecutionPolicy Bypass -File .\installer\build.ps1 -SkipInstaller   # 只出便携 ZIP

  关于 -LintOnly：Inno Setup 不是人人都有，而 .iss 最容易出的错是「漏了一个文件」
  或「路径写错」。这两类不依赖编译器就能查出来，所以在编译之前先对账：
    a) .iss 里 Source: 引用的每个文件都真的存在
    b) 清单里的每个文件都被 .iss 引用
    c) 仓库里所有 git 跟踪的文件，要么在清单里，要么在「故意不打包」名单里
       —— 这条能在你新加了一个 lib 却忘了打进产物时立刻报警
#>
[CmdletBinding()]
param(
  [string] $Version = '0.1.0',
  [switch] $LintOnly,
  [switch] $SkipInstaller,
  [switch] $SkipPortable
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$root = Split-Path -Parent $here
$dist = Join-Path $root 'dist'
$iss = Join-Path $here 'dsh-shortcut.iss'

# 要进产物的文件（相对仓库根）
$script:PackageFiles = @(
  'setup-gui.cmd'
  'setup-gui.ps1'
  'open-dsh.ps1'
  'install.ps1'
  'start-dsh-local.ps1'
  'lib\config.ps1'
  'lib\checks.ps1'
  'lib\deps.ps1'
  'lib\fetch.ps1'
  'lib\shortcut.ps1'
  'ui\wizard.xaml'
  'tests\setup-gui.tests.ps1'
  'tests\fetch.tests.ps1'
  'docs\dsh-tool-scheduler-symbol.md'
  'patches\fix-tool-scheduler-symbol.patch'
  'README.md'
  'LICENSE'
)

# 仓库里有、但**故意不**进产物的文件
$script:PackageExcludes = @(
  '.gitattributes'
  '.gitignore'
  'installer\build.ps1'
  'installer\dsh-shortcut.iss'
  '.github\workflows\ci.yml'
  '.github\workflows\release.yml'
)

function Write-Result {
  param([string] $Name, [bool] $Ok, [string] $Detail = '')
  if ($Ok) { Write-Host "  PASS  $Name" }
  else { Write-Host "  FAIL  $Name   [$Detail]" -ForegroundColor Red }
  return $Ok
}

# --- a) 清单里的文件都在磁盘上 ---
function Test-DshPackageFilesExist {
  $allOk = $true
  foreach ($rel in $script:PackageFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $rel))) {
      $allOk = (Write-Result "清单文件存在：$rel" $false '磁盘上找不到') -and $allOk
    }
  }
  if ($allOk) { Write-Host "  PASS  清单里 $($script:PackageFiles.Count) 个文件都存在" }
  return $allOk
}

# --- b) .iss 引用的文件都存在，且没有漏掉清单里的文件 ---
function Test-DshInstallerSources {
  if (-not (Test-Path -LiteralPath $iss)) {
    return (Write-Result '.iss 存在' $false $iss)
  }
  $text = Get-Content -LiteralPath $iss -Raw -Encoding UTF8
  $matches = [regex]::Matches($text, '(?m)^\s*Source:\s*"([^"]+)"')
  $referenced = New-Object System.Collections.Generic.List[string]
  $allOk = $true

  foreach ($m in $matches) {
    $raw = $m.Groups[1].Value.Replace('{#SourceRoot}', '..')
    $full = [System.IO.Path]::GetFullPath((Join-Path $here $raw))
    $rel = $full.Substring($root.Length).TrimStart('\')
    [void]$referenced.Add($rel)
    if (-not (Test-Path -LiteralPath $full)) {
      $allOk = (Write-Result ".iss 引用的文件存在：$rel" $false $full) -and $allOk
    }
  }
  Write-Host "  .iss 共引用 $($referenced.Count) 个文件"

  $notReferenced = @($script:PackageFiles | Where-Object { $referenced -notcontains $_ })
  if ($notReferenced.Count -gt 0) {
    $allOk = (Write-Result '.iss 覆盖了清单里的每个文件' $false ($notReferenced -join ', ')) -and $allOk
  } else {
    Write-Host '  PASS  .iss 覆盖了清单里的每个文件'
  }
  return $allOk
}

# --- c) 仓库里跟踪的文件没有「忘了打包」的 ---
function Test-DshPackageCoverage {
  $tracked = @(& git -C $root ls-files 2>$null)
  if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) {
    Write-Host '  SKIP  取不到 git 文件列表，跳过覆盖检查' -ForegroundColor Yellow
    return $true
  }
  $tracked = $tracked | ForEach-Object { $_ -replace '/', '\' }
  $unpackaged = @($tracked | Where-Object {
      ($script:PackageFiles -notcontains $_) -and ($script:PackageExcludes -notcontains $_)
    })
  if ($unpackaged.Count -gt 0) {
    return (Write-Result '仓库文件都被处置过（打包或明确排除）' $false "未处置：$($unpackaged -join ', ')")
  }
  Write-Host "  PASS  仓库 $($tracked.Count) 个跟踪文件都已处置"
  return $true
}

function Find-DshIscc {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { return $c }
  }
  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function New-DshPortableZip {
  param([Parameter(Mandatory)] [string] $Version)

  # 不用 Compress-Archive：它在 Windows 上把 ZIP 条目名写成 '\'，而 ZIP 规范要求 '/'，
  # 部分非 Windows 解压工具会把反斜杠当成文件名的一部分。这里自己写条目名。
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  Add-Type -AssemblyName System.IO.Compression

  $top = "dsh-shortcut-$Version"
  $zip = Join-Path $dist "dsh-shortcut-portable-$Version.zip"
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

  $stream = [System.IO.File]::Open($zip, [System.IO.FileMode]::CreateNew)
  try {
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
      foreach ($rel in $script:PackageFiles) {
        $entryName = "$top/" + ($rel -replace '\\', '/')
        $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $entryStream = $entry.Open()
        try {
          $src = [System.IO.File]::OpenRead((Join-Path $root $rel))
          try { $src.CopyTo($entryStream) } finally { $src.Dispose() }
        } finally { $entryStream.Dispose() }
      }
    } finally { $archive.Dispose() }
  } finally { $stream.Dispose() }

  return [pscustomobject]@{ Zip = $zip; TopLevel = $top }
}

# 解压回读校验：确认 ZIP 里真的是一个顶层目录 + 全部文件，而不是散落一地
function Test-DshPortableZip {
  param(
    [Parameter(Mandatory)] [string] $Zip,
    [Parameter(Mandatory)] [string] $TopLevel
  )
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($Zip)
  try {
    $entries = @($archive.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName })
  } finally {
    $archive.Dispose()
  }

  $allOk = $true

  # ZIP 规范要求 '/' 分隔。出现 '\' 说明有人换回了 Compress-Archive（它只写 '\'），
  # 那会让部分非 Windows 解压工具把反斜杠当成文件名的一部分。
  $backslashed = @($entries | Where-Object { $_ -like '*\*' })
  if ($backslashed.Count -gt 0) {
    $allOk = (Write-Result 'ZIP 条目名用正斜杠（ZIP 规范）' $false ($backslashed -join ', ')) -and $allOk
  } else {
    Write-Host '  PASS  ZIP 条目名用正斜杠（ZIP 规范）'
  }

  $prefix = "$TopLevel/"
  $strays = @($entries | Where-Object { -not $_.StartsWith($prefix) })
  if ($strays.Count -gt 0) {
    $allOk = (Write-Result 'ZIP 里所有文件都在同一个顶层目录下' $false ($strays -join ', ')) -and $allOk
  } else {
    Write-Host "  PASS  ZIP 顶层目录：$prefix"
  }

  $missing = New-Object System.Collections.ArrayList
  foreach ($rel in $script:PackageFiles) {
    $want = $prefix + ($rel -replace '\\', '/')
    if ($entries -notcontains $want) { [void]$missing.Add($rel) }
  }
  if ($missing.Count -gt 0) {
    $allOk = (Write-Result 'ZIP 包含清单里的每个文件' $false ($missing -join ', ')) -and $allOk
  } else {
    Write-Host "  PASS  ZIP 含全部 $($script:PackageFiles.Count) 个清单文件"
  }
  Write-Host "  ZIP 条目数：$($entries.Count)"
  return $allOk
}

# ================================================================ 主流程

$allOk = $true

Write-Host "`n=== 1) 发布一致性检查 ===" -ForegroundColor Cyan
$allOk = (Test-DshPackageFilesExist) -and $allOk
$allOk = (Test-DshInstallerSources) -and $allOk
$allOk = (Test-DshPackageCoverage) -and $allOk

if (-not $allOk) {
  Write-Host "`n一致性检查未通过，先修好再打包。" -ForegroundColor Red
  exit 1
}
Write-Host '一致性检查通过'

if ($LintOnly) {
  Write-Host "`n（-LintOnly：到此为止，未生成任何产物）"
  exit 0
}

New-Item -ItemType Directory -Force -Path $dist | Out-Null

if (-not $SkipPortable) {
  Write-Host "`n=== 2) 便携 ZIP ===" -ForegroundColor Cyan
  $built = New-DshPortableZip -Version $Version
  $allOk = (Test-DshPortableZip -Zip $built.Zip -TopLevel $built.TopLevel) -and $allOk
  Write-Host "  产物：$($built.Zip)"
}

if (-not $SkipInstaller) {
  Write-Host "`n=== 3) Inno Setup 安装包 ===" -ForegroundColor Cyan
  $iscc = Find-DshIscc
  if (-not $iscc) {
    Write-Host @'
  SKIP  没有找到 ISCC.exe，装不了安装包。
        装一下 Inno Setup 6（免费）：winget install JRSoftware.InnoSetup
        然后重跑本脚本；只想要便携版可以加 -SkipInstaller。
'@ -ForegroundColor Yellow
    exit 0
  }
  Write-Host "  编译器：$iscc"
  & $iscc "/DAppVersion=$Version" $iss
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Host "  FAIL  ISCC 退出码 $code" -ForegroundColor Red
    exit 1
  }
  $exe = Join-Path $dist "dsh-shortcut-setup-$Version.exe"
  $allOk = (Write-Result "生成 $([System.IO.Path]::GetFileName($exe))" (Test-Path -LiteralPath $exe) $exe) -and $allOk
}

Write-Host ''
if ($allOk) {
  Write-Host '构建完成' -ForegroundColor Green
  Get-ChildItem -LiteralPath $dist -File | ForEach-Object { "  {0,10:N0} B  {1}" -f $_.Length, $_.Name }
} else {
  Write-Host '构建有问题，见上面 FAIL。' -ForegroundColor Red
  exit 1
}
