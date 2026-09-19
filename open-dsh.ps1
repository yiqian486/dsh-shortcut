<#
  打开 DSH(DeepSeek Harness Web GUI)。快捷方式“打开 DSH.lnk”就是指到这个脚本。

  行为:
    1. 3080 已在监听,且确认是 DSH 的 Web 服务  -> 直接打开默认浏览器,不新起进程。
    2. 3080 没在监听                          -> 用本地检出源码图启动 dsh web --port 3080
                                                (DSH_HOME = %USERPROFILE%\.dsh,与当前实例一致),
                                                dsh 启动后会自己带上一次性 token 打开浏览器;
                                                本窗口就是服务进程。
    3. 3080 被别的服务占用                     -> 报错停住,提示换端口,不盲目覆盖、不误开页面。

  注意:第 2 种情况下,**关掉这个窗口就等于停掉 dsh**;第 1 种情况下窗口会很快自动关闭。

  手动用法:
    powershell -ExecutionPolicy Bypass -File .\open-dsh.ps1
    powershell -ExecutionPolicy Bypass -File .\open-dsh.ps1 -Port 3081
    powershell -ExecutionPolicy Bypass -File .\open-dsh.ps1 -Repo 'C:\src\deepseek-harness'

  参数:
    -Repo    你的 dsh 检出根目录。优先取环境变量 DSH_REPO;默认值是作者本机路径,
             在别的机器上请显式指定(或用 install.ps1 -Repo 直接烧进快捷方式)。
    -DshHome dsh 的 home。优先取已有的 DSH_HOME,否则用 %USERPROFILE%\.dsh。
    -Port    监听端口,默认 3080。
#>
[CmdletBinding()]
param(
  [string] $Repo    = $(if ($env:DSH_REPO) { $env:DSH_REPO } else { 'D:\deepseek-harness\deepseek-harness' }),
  [string] $DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { "$env:USERPROFILE\.dsh" }),
  [int]    $Port    = 3080
)

$ErrorActionPreference = 'Stop'
$url = "http://127.0.0.1:$Port"

# 端口是否有人监听
function Test-TcpPort {
  param([int] $Port, [int] $TimeoutMs = 800)
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

# 手写一个最小 HTTP GET:不依赖 Invoke-WebRequest 的异常语义,PowerShell 5.1 / 7 行为一致。
# 返回原始响应文本;连不上或完全没有响应时返回 $null。
function Get-HttpResponse {
  param([int] $Port, [int] $TimeoutMs = 4000)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne(1500)) { return $null }
    $client.EndConnect($async)
    $client.ReceiveTimeout = $TimeoutMs
    $client.SendTimeout    = $TimeoutMs
    $stream  = $client.GetStream()
    $request = "GET / HTTP/1.1`r`nHost: 127.0.0.1:$Port`r`nConnection: close`r`nUser-Agent: dsh-launcher`r`n`r`n"
    $bytes   = [System.Text.Encoding]::ASCII.GetBytes($request)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    $buffer = New-Object byte[] 8192
    $text   = New-Object System.Text.StringBuilder
    while ($true) {
      try   { $read = $stream.Read($buffer, 0, $buffer.Length) }
      catch { break }   # 读超时或对端断开:用已经读到的内容
      if ($read -le 0) { break }
      [void]$text.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $read))
    }
    return $text.ToString()
  } catch {
    return $null
  } finally {
    $client.Close()
  }
}

function Stop-WithMessage {
  param([string] $Message)
  Write-Host ''
  Write-Host "[dsh] $Message" -ForegroundColor Red
  Write-Host ''
  Write-Host '按 Enter 关闭此窗口...' -ForegroundColor Yellow
  [void](Read-Host)
  exit 1
}

try { $Host.UI.RawUI.WindowTitle = "DSH  (127.0.0.1:$Port)  -  关闭本窗口即停止" } catch { }

# ---- 1) 已经在跑?------------------------------------------------------------
if (Test-TcpPort -Port $Port) {
  $response = Get-HttpResponse -Port $Port
  if ($null -eq $response) {
    Stop-WithMessage "端口 $Port 有人监听,但连上后收不到任何 HTTP 响应(可能是别的服务)。请换端口,例如 -Port 3081。"
  }
  if ($response -notmatch '(?i)deepseek harness|__DSH_BOOT__|\bdsh web\b') {
    Stop-WithMessage "端口 $Port 被另一个 Web 服务占用了,它不是 DSH。请换端口,例如 -Port 3081。"
  }

  Write-Host "[dsh] $url 已在运行,打开浏览器。" -ForegroundColor Green
  Write-Host '[dsh] 若页面显示 authentication required:说明浏览器里那个登录 cookie 已过期(或换了浏览器)。' -ForegroundColor DarkGray
  Write-Host '[dsh] 处理办法:关掉正在运行的 dsh,再双击本快捷方式重新启动,让 dsh 自己带新 token 打开。' -ForegroundColor DarkGray
  Start-Process $url
  Start-Sleep -Milliseconds 500
  exit 0
}

# ---- 2) 启动前自检 ------------------------------------------------------------
$entry = Join-Path $Repo 'apps\cli\src\bin.ts'
if (-not (Test-Path (Join-Path $Repo 'package.json'))) {
  Stop-WithMessage "找不到本地检出:$Repo"
}
if (-not (Test-Path $entry)) {
  Stop-WithMessage "找不到 CLI 入口:$entry"
}
if (-not (Test-Path (Join-Path $Repo 'node_modules\tsx\package.json'))) {
  Stop-WithMessage "缺 tsx:$Repo 的依赖不完整,请先在该目录执行 pnpm install"
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Stop-WithMessage 'PATH 里找不到 node,请确认 Node.js 已安装并在 PATH 中。'
}

New-Item -ItemType Directory -Force -Path $DshHome | Out-Null
if (-not (Test-Path (Join-Path $DshHome '.credentials.yaml'))) {
  $shared = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
  if ((Test-Path $shared) -and ((Split-Path $shared -Parent) -ne $DshHome)) {
    Copy-Item $shared (Join-Path $DshHome '.credentials.yaml')
    Write-Host "[dsh] 已复用凭据:$shared" -ForegroundColor DarkGray
  } else {
    Write-Warning "未找到凭据文件 $DshHome\.credentials.yaml,首次运行需要先配置 API key。"
  }
}

$env:DSH_HOME = $DshHome

Write-Host '[dsh] 未在运行,启动本地源码图...' -ForegroundColor Cyan
Write-Host "[dsh] repo     : $Repo"
Write-Host "[dsh] DSH_HOME : $DshHome"
Write-Host "[dsh] GUI      : $url"
Write-Host '[dsh] dsh 就绪后会自己打开浏览器;若没弹出来,复制下面 “dsh web:” 那行的完整 URL 手动打开。' -ForegroundColor DarkGray
Write-Host '[dsh] 关闭本窗口即停止 dsh。' -ForegroundColor DarkGray
Write-Host ''

# ---- 3) 起服务(dsh web 默认自带 openBrowser)-----------------------------------
Push-Location $Repo
try {
  & node --import tsx/esm apps/cli/src/bin.ts web --port $Port
  $code = $LASTEXITCODE
} finally {
  Pop-Location
}

if ($code -ne 0) {
  Stop-WithMessage "dsh 退出,退出码 $code。"
}
Write-Host '[dsh] 已停止。' -ForegroundColor DarkGray
