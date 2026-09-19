; DSH 启动器 · Inno Setup 打包脚本
;
; 编译：
;   ISCC.exe installer\dsh-shortcut.iss
;   或直接用 installer\build.ps1（会顺带做一致性检查、并生成便携 ZIP）
;   覆盖版本号：ISCC.exe /DAppVersion=0.2.0 installer\dsh-shortcut.iss
;
; 只装「启动器」本身，**不装 dsh**：dsh 需要 git clone + pnpm install，
; 那是向导里「获取 dsh」按钮的活，装的时候不该偷偷干。
;
; 为什么 [Languages] 只有英文：
;   Inno Setup 6 官方**不带简体中文**（ChineseSimplified.isl 是非官方翻译）。
;   这里引用它会让编译直接失败。要中文界面的话：
;     1) 下载 ChineseSimplified.isl 放到 Inno Setup 的 Languages 目录
;     2) 在下面 [Languages] 里加一行
;        Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#define AppName "DSH Launcher"
#define AppShortName "DSH 启动器"
#define AppPublisher "yiqian486"
#define AppUrl "https://github.com/yiqian486/dsh-shortcut"
; {app} 下所有文件都来自仓库根目录，相对于本 .iss 所在目录
#define SourceRoot ".."

[Setup]
; 固定 AppId：升级安装要靠它认亲，改了会被当成另一个软件
AppId={{93417471-10AB-471D-9CB2-F37B527965F7}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}
VersionInfoVersion={#AppVersion}

; 免管理员：装到用户目录，不弹 UAC
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\dsh-shortcut
DefaultGroupName={#AppShortName}
DisableProgramGroupPage=yes
AllowNoIcons=yes

OutputDir={#SourceRoot}\dist
OutputBaseFilename=dsh-shortcut-setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceRoot}\setup-gui.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\setup-gui.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\open-dsh.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\install.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\start-dsh-local.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\lib\config.ps1"; DestDir: "{app}\lib"; Flags: ignoreversion
Source: "{#SourceRoot}\lib\checks.ps1"; DestDir: "{app}\lib"; Flags: ignoreversion
Source: "{#SourceRoot}\lib\deps.ps1"; DestDir: "{app}\lib"; Flags: ignoreversion
Source: "{#SourceRoot}\lib\fetch.ps1"; DestDir: "{app}\lib"; Flags: ignoreversion
Source: "{#SourceRoot}\lib\shortcut.ps1"; DestDir: "{app}\lib"; Flags: ignoreversion
Source: "{#SourceRoot}\ui\wizard.xaml"; DestDir: "{app}\ui"; Flags: ignoreversion
Source: "{#SourceRoot}\tests\setup-gui.tests.ps1"; DestDir: "{app}\tests"; Flags: ignoreversion
Source: "{#SourceRoot}\tests\fetch.tests.ps1"; DestDir: "{app}\tests"; Flags: ignoreversion
Source: "{#SourceRoot}\docs\dsh-tool-scheduler-symbol.md"; DestDir: "{app}\docs"; Flags: ignoreversion
Source: "{#SourceRoot}\patches\fix-tool-scheduler-symbol.patch"; DestDir: "{app}\patches"; Flags: ignoreversion
Source: "{#SourceRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; 开始菜单只放「配置向导」和卸载。「打开 DSH」由向导在配置完成后生成——
; 它需要 config.json 里的检出路径，安装时还不知道。
Name: "{group}\{#AppShortName}（配置向导）"; Filename: "{app}\setup-gui.cmd"; WorkingDir: "{app}"
Name: "{group}\卸载 {#AppShortName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\setup-gui.cmd"; Description: "立即运行配置向导"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
; 向导按用户在界面里填的名字生成快捷方式，默认是「打开 DSH」。
; 用户改过名字的那份残留不在掌握中，卸载说明里提一句。
Type: files; Name: "{userdesktop}\打开 DSH.lnk"
Type: files; Name: "{userprograms}\打开 DSH.lnk"

[UninstallRun]
; 无
