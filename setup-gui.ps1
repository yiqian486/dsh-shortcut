<#
  DSH 启动器 · 安装向导（WPF）

  入口是 setup-gui.cmd（双击）：
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File setup-gui.ps1

  WPF 必须 STA。Windows PowerShell 5.1 默认就是 STA，所以 .cmd 里用 powershell.exe 最稳；
  如果改用 pwsh，必须显式加 -STA。

  结构说明：
    - 界面在 ui/wizard.xaml，是**宽松 XAML**（无 code-behind），所以不能写 Click="..."。
      所有事件都在本文件里用 Add_Click / Add_MouseLeftButtonDown 挂。
    - 自检每一行由 New-DshCheckRow 现场构造（不走 ItemsControl + DataTemplate）：
      DataTemplate 里的按钮要等布局生成容器后才存在，遍历视觉树才能挂事件，
      那样就没法在不开窗的情况下验证。现在这样是可测的。
    - Invoke-DshWizardInstall 只从控件读值、再调共享库，所以测试可以加载界面、
      直接给控件赋值、调用它，全程不用显示窗口。
#>
[CmdletBinding()]
param(
  # 只定义函数、不显示窗口。自动化测试用。
  [switch] $NoRun
)

$ErrorActionPreference = 'Stop'

$script:DshRoot = $PSScriptRoot

. (Join-Path $script:DshRoot 'lib\config.ps1')
. (Join-Path $script:DshRoot 'lib\checks.ps1')
. (Join-Path $script:DshRoot 'lib\deps.ps1')
. (Join-Path $script:DshRoot 'lib\shortcut.ps1')

# ---------------------------------------------------------------- 基础设施

function Initialize-DshWizardAssemblies {
  Add-Type -AssemblyName PresentationFramework
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase
  Add-Type -AssemblyName System.Windows.Forms   # 文件夹选择框（WPF 没有原生文件夹选择器）
}

function ConvertTo-DshBrush {
  param([Parameter(Mandatory)] [string] $Hex)
  $converter = New-Object System.Windows.Media.BrushConverter
  return $converter.ConvertFromString($Hex)
}

function Import-DshWizardXaml {
  param([string] $Path)
  Initialize-DshWizardAssemblies
  if (-not (Test-Path -LiteralPath $Path)) { throw "找不到界面文件：$Path" }
  $xml = New-Object System.Xml.XmlDocument
  $xml.Load($Path)
  return [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
}

function Get-DshWizardWindowPath {
  return (Join-Path $script:DshRoot 'ui\wizard.xaml')
}

function Add-DshWizardLog {
  param([Parameter(Mandatory)] [object] $Window, [Parameter(Mandatory)] [string] $Line)
  $log = $Window.FindName('tbLog')
  $title = $Window.FindName('tbLogTitle')
  $title.Visibility = [System.Windows.Visibility]::Visible
  $log.Visibility = [System.Windows.Visibility]::Visible
  $log.AppendText("$Line`r`n")
  $log.ScrollToEnd()
}

# 安装按钮是否可用，由「上一次自检的结论」决定，而不是由忙/闲决定。
# 忙的时候一律禁用；闲下来时按最近一次自检的 CanStart 恢复。
# （早先的写法是闲下来就直接 IsEnabled=$true，会把自检算出来的“有 fail 就禁用”覆盖掉。）
function Update-DshWizardInstallState {
  param([Parameter(Mandatory)] [object] $Window)
  $summary = $Window.Tag
  $canStart = $true
  if ($null -ne $summary) { $canStart = [bool] $summary.CanStart }
  $Window.FindName('btnInstall').IsEnabled = $canStart
  return $canStart
}

function Set-DshWizardBusy {
  param([Parameter(Mandatory)] [object] $Window, [Parameter(Mandatory)] [bool] $Busy)
  $Window.FindName('btnRecheck').IsEnabled = (-not $Busy)
  $Window.FindName('btnBrowse').IsEnabled = (-not $Busy)
  $Window.FindName('btnFetch').IsEnabled = (-not $Busy)
  if ($Busy) {
    $Window.FindName('btnInstall').IsEnabled = $false
  } else {
    Update-DshWizardInstallState -Window $Window | Out-Null
  }
  $progressVisibility = if ($Busy) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
  $Window.FindName('pbProgress').Visibility = $progressVisibility
}

function Set-DshWizardSummary {
  param([Parameter(Mandatory)] [object] $Window, [string] $Text, [string] $Level = 'info')
  $block = $Window.FindName('tbSummary')
  $block.Text = $Text
  $block.Foreground = ConvertTo-DshBrush $(switch ($Level) {
      'ok'   { '#4CAF50' }
      'warn' { '#E6A23C' }
      'fail' { '#E5484D' }
      default { '#9A9AA6' }
    })
}

# ---------------------------------------------------------------- 自检行

# 行的外观写成 XAML 片段，比在 PowerShell 里手搓 Grid/ColumnDefinition 清楚得多。
# 文本一律先做 XML 转义——路径里可能有 & 或 <。
$script:DshCheckRowTemplate = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        CornerRadius="6" Background="#2A2A31" Padding="10,8" Margin="0,0,0,6">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <Ellipse Width="8" Height="8" Fill="__COLOR__" VerticalAlignment="Top" Margin="0,5,10,0"/>
    <StackPanel Grid.Column="1">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="__LABEL__" Foreground="#E9E9EE" FontSize="12.5" FontWeight="SemiBold"/>
        <TextBlock Text="__DETAIL__" Foreground="#9A9AA6" FontSize="11.5" Margin="10,1,0,0"/>
      </StackPanel>
      <TextBlock Text="__HINT__" Foreground="#9A9AA6" FontSize="11" TextWrapping="Wrap"
                 Margin="0,3,0,0" Visibility="__HINTVIS__"/>
    </StackPanel>
    <Button x:Name="btnFix" Grid.Column="2" Content="一键安装" Padding="12,5"
            Foreground="#0E1A17" FontWeight="SemiBold" Cursor="Hand"
            Background="#35C6A5" BorderThickness="0" Visibility="__FIXVIS__"/>
  </Grid>
</Border>
'@

function New-DshCheckRow {
  param(
    [Parameter(Mandatory)] [object] $Check,
    [scriptblock] $OnFix
  )

  $color = switch ($Check.Status) {
    'ok'   { '#4CAF50' }
    'warn' { '#E6A23C' }
    default { '#E5484D' }
  }
  $hasFix  = [bool] $Check.Fix
  $hasHint = [bool] $Check.Hint

  $xaml = $script:DshCheckRowTemplate.
    Replace('__COLOR__', $color).
    Replace('__LABEL__', [System.Security.SecurityElement]::Escape("$($Check.Label)")).
    Replace('__DETAIL__', [System.Security.SecurityElement]::Escape("$($Check.Detail)")).
    Replace('__HINT__', [System.Security.SecurityElement]::Escape("$($Check.Hint)")).
    Replace('__HINTVIS__', $(if ($hasHint) { 'Visible' } else { 'Collapsed' })).
    Replace('__FIXVIS__', $(if ($hasFix) { 'Visible' } else { 'Collapsed' }))

  $row = [Windows.Markup.XamlReader]::Parse($xaml)

  if ($hasFix) {
    $button = $row.FindName('btnFix')
    if (-not $button) {
      # 片段没建 namescope 时兜底：直接找唯一的 Button
      $button = $row.Child.Children | Where-Object { $_ -is [System.Windows.Controls.Button] } | Select-Object -First 1
    }
    if ($button) {
      # Tag 是元数据，不论有没有传事件处理器都要写上
      $fixName = $Check.Fix
      $button.Tag = $fixName
      if ($OnFix) { $button.Add_Click({ & $OnFix $fixName }.GetNewClosure()) }
    }
  }
  return $row
}

function Update-DshWizardChecks {
  param(
    [Parameter(Mandatory)] [object] $Window,
    [Parameter(Mandatory)] [object[]] $Checks
  )

  $panel = $Window.FindName('pnlChecks')
  $panel.Children.Clear()

  $onFix = {
    param($fixName)
    Set-DshWizardBusy -Window $Window -Busy $true
    Set-DshWizardSummary -Window $Window -Text "正在安装 $fixName …"
    Add-DshWizardLog -Window $Window -Line "=== 安装 $fixName ==="
    try {
      $result = Install-DshDependency -Name $fixName -OnOutput {
        param($line)
        Add-DshWizardLog -Window $Window -Line $line
      }
      Add-DshWizardLog -Window $Window -Line $result.Message
      Set-DshWizardSummary -Window $Window -Text $result.Message -Level $(if ($result.Ok) { 'ok' } else { 'warn' })
    } catch {
      Add-DshWizardLog -Window $Window -Line "失败：$($_.Exception.Message)"
      Set-DshWizardSummary -Window $Window -Text "安装失败：$($_.Exception.Message)" -Level 'fail'
    } finally {
      Set-DshWizardBusy -Window $Window -Busy $false
      Start-DshWizardCheck -Window $Window -Synchronous
    }
  }.GetNewClosure()

  foreach ($c in $Checks) {
    $panel.Children.Add((New-DshCheckRow -Check $c -OnFix $onFix)) | Out-Null
  }

  $summary = Get-DshCheckSummary -Checks $Checks
  $level = if ($summary.Fail -gt 0) { 'fail' } elseif ($summary.Warn -gt 0) { 'warn' } else { 'ok' }
  Set-DshWizardSummary -Window $Window -Text $summary.Text -Level $level

  # 记下这次结论：忙/闲切换时靠它恢复安装按钮；有 fail 时不让点“安装”
  $Window.Tag = $summary
  Update-DshWizardInstallState -Window $Window | Out-Null
  return $summary
}

# ---------------------------------------------------------------- 自检取数

# 从当前控件读出这次自检用的输入（等价于命令行的 -Repo / -Port）
function Get-DshWizardBound {
  param([Parameter(Mandatory)] [object] $Window)
  $bound = @{}
  $repo = $Window.FindName('tbRepo').Text
  if ($repo -and $repo.Trim()) { $bound['Repo'] = $repo.Trim() }
  $port = $Window.FindName('tbPort').Text
  if ($port -and $port.Trim() -match '^\d+$') { $bound['Port'] = [int]$port.Trim() }
  return $bound
}

function Get-DshWizardChecks {
  param([System.Collections.IDictionary] $Bound = @{})
  return Get-DshCheckResults -Settings (Resolve-DshShortcutSettings -Bound $Bound)
}

# 在独立 runspace 里跑自检，避免调外部命令（node -v / git --version / 端口探测）时界面假死。
function Start-DshWizardCheckAsync {
  param([Parameter(Mandatory)] [object] $Window)

  $bound = Get-DshWizardBound -Window $Window
  $root  = $script:DshRoot

  $shell = [powershell]::Create()
  [void]$shell.AddScript({
      param($root, $bound)
      . (Join-Path $root 'lib\config.ps1')
      . (Join-Path $root 'lib\checks.ps1')
      Get-DshCheckResults -Settings (Resolve-DshShortcutSettings -Bound $bound)
    }).AddArgument($root).AddArgument($bound)

  $handle = $shell.BeginInvoke()

  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(120)

  # GetNewClosure 是必需的：DispatcherTimer 的 Tick 在事件里跑，
  # 拿不到 Start-DshWizardCheckAsync 的局部变量。
  $tick = {
    if (-not $handle.IsCompleted) { return }
    $timer.Stop()
    $checks = @()
    try   { $checks = @($shell.EndInvoke($handle)) }
    catch { Add-DshWizardLog -Window $Window -Line "自检失败：$($_.Exception.Message)" }
    finally { $shell.Dispose() }
    Update-DshWizardChecks -Window $Window -Checks $checks
    Set-DshWizardBusy -Window $Window -Busy $false
  }.GetNewClosure()
  $timer.Add_Tick($tick)
  $timer.Start()
}

function Start-DshWizardCheck {
  param([Parameter(Mandatory)] [object] $Window, [switch] $Synchronous)

  Set-DshWizardBusy -Window $Window -Busy $true
  if ($Synchronous) {
    Update-DshWizardChecks -Window $Window -Checks (Get-DshWizardChecks -Bound (Get-DshWizardBound -Window $Window)) | Out-Null
    Set-DshWizardBusy -Window $Window -Busy $false
    return
  }
  Start-DshWizardCheckAsync -Window $Window
}

# ---------------------------------------------------------------- 安装

<#
  执行安装：校验输入 → 写 config.json → 按勾选生成快捷方式。

  只从控件读值，所以测试可以加载界面、直接赋控件值后调用它，不必显示窗口。
  @returns { Ok, Errors[], Messages[], ConfigPath, Shortcuts[] }
#>
function Invoke-DshWizardInstall {
  param([Parameter(Mandatory)] [object] $Window)

  $errors = New-Object System.Collections.ArrayList
  $messages = New-Object System.Collections.ArrayList

  $repo = $Window.FindName('tbRepo').Text
  if ($repo) { $repo = $repo.Trim() }
  $portText = "$($Window.FindName('tbPort').Text)".Trim()
  $name = "$($Window.FindName('tbName').Text)".Trim()
  if (-not $name) { $name = '打开 DSH' }
  $wantDesktop  = [bool] $Window.FindName('cbDesktop').IsChecked
  $wantStartMenu = [bool] $Window.FindName('cbStartMenu').IsChecked

  if (-not $repo) {
    [void]$errors.Add('请先选择 dsh 检出目录。')
  } elseif (-not (Test-Path -LiteralPath (Join-DshPath $repo 'package.json'))) {
    [void]$errors.Add("这个目录不像 dsh 检出（找不到 package.json）：$repo")
  }

  $port = 3080
  if ($portText -notmatch '^\d+$') {
    [void]$errors.Add("端口必须是数字：$portText")
  } else {
    $port = [int] $portText
    if ($port -lt 1 -or $port -gt 65535) { [void]$errors.Add("端口超出范围：$port") }
  }

  if (-not $wantDesktop -and -not $wantStartMenu) {
    [void]$errors.Add('至少要选一个快捷方式位置（桌面或开始菜单）。')
  }

  if ($errors.Count -gt 0) {
    return [pscustomobject]@{ Ok = $false; Errors = $errors.ToArray(); Messages = @(); ConfigPath = ''; Shortcuts = @() }
  }

  # 写 config.json：向导生成的快捷方式不带 -Repo，路径以后就靠这里
  $values = [ordered]@{
    repo      = $repo
    port      = $port
    updatedAt = (Get-Date).ToString('o')
    shortcuts = [ordered]@{ desktop = $wantDesktop; startMenu = $wantStartMenu; name = $name }
  }
  $configPath = Save-DshShortcutConfig -Values $values
  [void]$messages.Add("已写入配置：$configPath")

  $launcher = Join-Path $script:DshRoot 'open-dsh.ps1'
  $shortcuts = New-Object System.Collections.ArrayList

  $places = @()
  if ($wantDesktop)  { $places += 'Desktop' }
  if ($wantStartMenu) { $places += 'StartMenu' }

  foreach ($place in $places) {
    try {
      # 注意：不传 -Repo。传了就会烧进快捷方式，而参数优先级高于 config.json，
      # 以后在向导里改路径会被旧值压住。
      $result = New-DshShortcut -LauncherPath $launcher -Name $name -Place $place -Port $port -Force
      [void]$shortcuts.Add($result.Path)
      [void]$messages.Add($result.Message)
    } catch {
      [void]$errors.Add("创建 $place 快捷方式失败：$($_.Exception.Message)")
    }
  }

  return [pscustomobject]@{
    Ok = ($errors.Count -eq 0)
    Errors = $errors.ToArray()
    Messages = $messages.ToArray()
    ConfigPath = $configPath
    Shortcuts = $shortcuts.ToArray()
  }
}

# ---------------------------------------------------------------- 装配窗口

<#
  后台获取 dsh 检出，输出实时流进日志窗口。

  为什么用 ConcurrentQueue：worker 跑在独立 runspace 里，把界面脚本块传进去当回调是行不通的
  （脚本块不能跨 runspace）。所以让 worker 往一个共享队列里塞行，界面线程用 DispatcherTimer
  定期排空并写进 TextBox。

  真实 clone / pnpm install 可能要几分钟，所以整个过程不阻塞界面：
  worker 在跑，计时器每 150ms 把新行刷出来。
#>
function Start-DshWizardFetch {
  param([Parameter(Mandatory)] [object] $Window, [string] $Target)

  if (-not $Target) { $Target = Join-Path $env:USERPROFILE 'deepseek-harness' }

  $repoBox = $Window.FindName('tbRepo')
  $log = $Window.FindName('tbLog')
  $log.Clear()
  $Window.FindName('tbLogTitle').Visibility = [System.Windows.Visibility]::Visible
  $log.Visibility = [System.Windows.Visibility]::Visible
  $Window.FindName('pbProgress').IsIndeterminate = $true
  Set-DshWizardBusy -Window $Window -Busy $true
  Set-DshWizardSummary -Window $Window -Text "正在获取 dsh 检出，可能要几分钟 …"

  $queue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
  $root = $script:DshRoot

  $shell = [powershell]::Create()
  [void]$shell.AddScript({
      param($rootPath, $targetPath, $sink)
      . (Join-Path $rootPath 'lib\config.ps1')
      . (Join-Path $rootPath 'lib\checks.ps1')
      . (Join-Path $rootPath 'lib\deps.ps1')
      . (Join-Path $rootPath 'lib\fetch.ps1')
      Invoke-DshFetch -Target $targetPath -OnOutput {
        param($line)
        $sink.Enqueue([string]$line)
      }
    }).AddArgument($root).AddArgument($Target).AddArgument($queue)

  $handle = $shell.BeginInvoke()

  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(150)

  $tick = {
    # 先把队列排空，再判断是否结束 —— 反过来会丢掉最后几行
    [string] $line = $null
    while ($queue.TryDequeue([ref]$line)) { $log.AppendText("$line`r`n") }
    $log.ScrollToEnd()

    if (-not $handle.IsCompleted) { return }
    $timer.Stop()

    $result = $null
    try   { $result = $shell.EndInvoke($handle) }
    catch { $log.AppendText("获取失败：$($_.Exception.Message)`r`n") }
    finally { $shell.Dispose() }

    $Window.FindName('pbProgress').IsIndeterminate = $false
    Set-DshWizardBusy -Window $Window -Busy $false

    if ($result -and $result.Ok) {
      $repoBox.Text = $result.Target
      Set-DshWizardSummary -Window $Window -Text $result.Messages[-1] -Level 'ok'
    } elseif ($result) {
      Set-DshWizardSummary -Window $Window -Text $result.Messages[-1] -Level 'fail'
    }
    # 取完重新自检：依赖/检出/tsx 的状态都变了
    Start-DshWizardCheck -Window $Window -Synchronous
  }.GetNewClosure()

  $timer.Add_Tick($tick)
  $timer.Start()
}

function Initialize-DshWizardWindow {
  param([Parameter(Mandatory)] [object] $Window)

  $settings = Resolve-DshShortcutSettings
  $Window.FindName('tbRepo').Text = $settings.Repo
  $Window.FindName('tbPort').Text = "$($settings.Port)"
  $Window.FindName('tbName').Text = '打开 DSH'

  $sourceText = switch ($settings.RepoSource) {
    'param'   { '来自命令行参数' }
    'env'     { '来自环境变量 DSH_REPO' }
    'config'  { '来自 config.json' }
    default   { '内置默认值（作者本机路径）' }
  }
  $Window.FindName('tbRepoSource').Text = $sourceText

  # 无边框窗口要自己实现拖动和关闭
  $Window.FindName('btnClose').Add_Click({ $Window.Close() }.GetNewClosure())
  $Window.FindName('titleBar').Add_MouseLeftButtonDown({
      try { $Window.DragMove() } catch { }
    }.GetNewClosure())
  $Window.Add_KeyDown({
      param($sender, $e)
      if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $Window.Close() }
    }.GetNewClosure())

  $Window.FindName('btnRecheck').Add_Click({
      Start-DshWizardCheck -Window $Window
    }.GetNewClosure())

  $Window.FindName('btnBrowse').Add_Click({
      $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
      $dialog.Description = '选择 dsh 检出根目录（含 apps\cli）'
      $current = $Window.FindName('tbRepo').Text
      if ($current -and (Test-Path -LiteralPath $current)) { $dialog.SelectedPath = $current }
      if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $Window.FindName('tbRepo').Text = $dialog.SelectedPath
        Start-DshWizardCheck -Window $Window
      }
    }.GetNewClosure())

  $Window.FindName('btnFetch').Add_Click({
      $target = "$($Window.FindName('tbRepo').Text)".Trim()
      Start-DshWizardFetch -Window $Window -Target $target
    }.GetNewClosure())

  $Window.FindName('btnInstall').Add_Click({
      Set-DshWizardBusy -Window $Window -Busy $true
      Add-DshWizardLog -Window $Window -Line '=== 安装 ==='
      try {
        $result = Invoke-DshWizardInstall -Window $Window
        foreach ($m in $result.Messages) { Add-DshWizardLog -Window $Window -Line $m }
        if ($result.Ok) {
          Set-DshWizardSummary -Window $Window -Text '安装完成，可以双击快捷方式打开 DSH 了。' -Level 'ok'
        } else {
          foreach ($e in $result.Errors) { Add-DshWizardLog -Window $Window -Line "错误：$e" }
          Set-DshWizardSummary -Window $Window -Text ($result.Errors -join ' ') -Level 'fail'
        }
      } catch {
        Add-DshWizardLog -Window $Window -Line "失败：$($_.Exception.Message)"
        Set-DshWizardSummary -Window $Window -Text "安装失败：$($_.Exception.Message)" -Level 'fail'
      } finally {
        Set-DshWizardBusy -Window $Window -Busy $false
      }
    }.GetNewClosure())
}

function Start-DshWizard {
  Initialize-DshWizardAssemblies
  $window = Import-DshWizardXaml -Path (Get-DshWizardWindowPath)
  Initialize-DshWizardWindow -Window $window
  $window.Add_ContentRendered({ Start-DshWizardCheck -Window $window }.GetNewClosure()) | Out-Null
  [void]$window.ShowDialog()
}

if (-not $NoRun) {
  Start-DshWizard
}
