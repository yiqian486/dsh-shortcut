<#
  启动本地源码仓库里的 dsh。

  路径解析优先级（高 → 低）：
    1. 命令行参数   -Repo / -DevHome / -Port
    2. 环境变量     DSH_REPO / DSH_DEV_HOME / DSH_PORT
    3. config.json  %USERPROFILE%\.dsh-shortcut\config.json（由 setup-gui.ps1 写入）
    4. 内置默认值   -Repo 默认 D:\deepseek-harness\deepseek-harness（作者本机路径），
                    -DevHome 默认 %USERPROFILE%\.dsh-dev-home

  背景（为什么需要这个脚本）：
  1. 本地检出里同时存在两套模块图：
       - 源码图：apps/cli/src/*.ts，由 tsx + tsconfig.base.json 的 paths 映射加载（`pnpm dsh` 走这条）；
       - 构建图：packages/*/lib/*.js，由 package exports 加载（已安装消费者 / `node apps/cli/lib/bin.js` 走这条）。
     @deepseek-ai/dsh-tools 的工具调度器以 Symbol 作键。两份实例原本各自持有私有的
     Symbol('@deepseek-ai/dsh-tools.scheduler')，于是只要进程里混进两份 dsh-tools，工具调度就会拿到
     undefined，任何工具调用都以 "Cannot read properties of undefined (reading 'prepare')" 结束
     （聊天正常，第一个工具调用必崩）。
     packages/core/tools/src/index.ts 已改为 Symbol.for('@deepseek-ai/dsh-tools.scheduler')，
     两种图共用全局注册表里的同一个键；源码模式与构建模式均已端到端验证通过。
  2. 本地开发必须用独立的 DSH_HOME：dev CLI 启动时会重写 profile 根配置，
     共用 ~/.dsh 会破坏你正在使用的正式安装（npx 安装）的 profile。

  用法：
    pwsh -File .\start-dsh-local.ps1                 # 构建图（默认，最稳，等价于已安装消费者）
    pwsh -File .\start-dsh-local.ps1 -Mode src       # 源码图（tsx，改源码免重新构建）
    pwsh -File .\start-dsh-local.ps1 -Port 3081      # 换端口，避免和已在跑的 dsh 抢 3080
    pwsh -File .\start-dsh-local.ps1 -Open           # 启动后自动打开浏览器
    pwsh -File .\start-dsh-local.ps1 -Repo 'C:\src\deepseek-harness'  # 检出不在默认路径时
    pwsh -File .\start-dsh-local.ps1 -DevHome 'C:\tmp\dsh-dev-home'   # 改开发用 home
#>
param(
  [ValidateSet('lib', 'src')] [string] $Mode = 'lib',
  [int] $Port = 3080,
  [switch] $Open,
  [string] $Repo,
  [string] $DevHome
)

$ErrorActionPreference = 'Stop'

# 统一路径解析,见 lib/config.ps1
. (Join-Path $PSScriptRoot 'lib\config.ps1')
$settings = Resolve-DshShortcutSettings -Bound $PSBoundParameters
$Repo    = $settings.Repo
$DevHome = $settings.DevHome
$Port    = $settings.Port

# 和 open-dsh.ps1 行为一致：出错时把窗口停住，别让报错一闪而过
function Stop-WithMessage {
  param([string] $Message)
  Write-Host ''
  Write-Host "[dsh] $Message" -ForegroundColor Red
  Write-Host ''
  Write-Host '按 Enter 关闭此窗口...' -ForegroundColor Yellow
  [void](Read-Host)
  exit 1
}

# 总兜底：任何没被预期分支接住的终止错误都停下来等回车，别让窗口一闪而过。
trap { Stop-WithMessage "意外错误：$($_.Exception.Message)" }

$pkgJson = Join-DshPath $Repo 'package.json'
if (-not (Test-Path -LiteralPath $pkgJson)) {
  Stop-WithMessage "找不到本地检出：$Repo（用 -Repo <你的检出路径>、环境变量 DSH_REPO 或 config.json 指定）"
}
if ($Mode -eq 'lib' -and -not (Test-Path -LiteralPath (Join-DshPath $Repo 'apps\cli\lib\bin.js'))) {
  Stop-WithMessage "构建产物缺失，请先在 $Repo 执行：pnpm install; pnpm run build"
}
if ($Mode -eq 'src' -and -not (Test-Path -LiteralPath (Join-DshPath $Repo 'node_modules\tsx\package.json'))) {
  Stop-WithMessage "源码图需要 tsx：$Repo 的依赖不完整，请先在该目录执行 pnpm install"
}

New-Item -ItemType Directory -Force -Path $DevHome | Out-Null
if (-not (Test-Path (Join-Path $DevHome '.credentials.yaml'))) {
  $shared = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
  if (Test-Path $shared) {
    Copy-Item $shared (Join-Path $DevHome '.credentials.yaml')
    Write-Host "已复用凭据：$shared -> $DevHome"
  } else {
    Write-Warning "未找到凭据文件；首次在 $DevHome 里运行需要先配置 API key。"
  }
}

$env:DSH_HOME = $DevHome
$webArgs = @('web', '--port', "$Port")
if (-not $Open) { $webArgs += '--no-open' }

Write-Host ("本地 dsh：mode={0}  DSH_HOME={1}  http://127.0.0.1:{2}" -f $Mode, $DevHome, $Port)

Push-Location $Repo
try {
  if ($Mode -eq 'src') {
    node --import tsx/esm apps/cli/src/bin.ts @webArgs
  } else {
    node apps/cli/lib/bin.js @webArgs
  }
} finally {
  Pop-Location
}
