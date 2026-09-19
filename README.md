# dsh-shortcut

**一键打开本地 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（`dsh`）Web GUI 的 Windows 小工具箱。**

A tiny Windows toolkit that opens your local DeepSeek Harness Web GUI with one double-click:
it starts `dsh web` from your source checkout when nothing is running, and otherwise just opens the
browser at the already-running instance. See [English quick start](#english-quick-start).

---

## 它解决什么

从源码检出跑 `dsh`，每次都要开终端、`cd` 到检出、设 `DSH_HOME`、敲 `pnpm dsh web`。这个小工具把它变成一次双击：

| 双击时的状态 | 行为 |
| --- | --- |
| 3080 没在监听 | 用你的检出启动 `dsh web`，dsh 自己带上一次性 token 打开浏览器；这个控制台窗口就是服务进程 |
| 3080 已经在跑且确认是 DSH | 直接开浏览器，**不会**重复起进程、不会撞端口 |
| 3080 被别的服务占用 | 明确报错并提示换端口，不盲目覆盖、不误开页面 |

顺带收录一份本地 dsh 的崩溃排查记录与补丁：源码图与构建图的 `Symbol` 键不一致，导致「聊天正常、第一个工具调用必崩」。

## 文件

| 文件 | 作用 |
| --- | --- |
| `open-dsh.ps1` | 启动器本体。探测端口 → 已在跑就开浏览器，没跑就启动 `dsh web` |
| `setup-gui.cmd` | **图形向导（双击这个）**：自检环境 → 选路径/端口 → 写配置 → 生成快捷方式 |
| `install.ps1` | 命令行的快捷方式生成器（向导的 CLI 版），可放桌面 / 开始菜单 / 指定目录 |
| `start-dsh-local.ps1` | 开发用启动器：可切换源码图（tsx）与构建图，并可并存换端口 |
| `lib/config.ps1` | 配置读写与路径解析：参数 > 环境变量 > `config.json` > 默认 |
| `lib/checks.ps1` | 环境自检：node / git / pnpm / 检出 / tsx / 构建产物 / 凭据 / 端口 |
| `lib/deps.ps1` | 依赖安装：winget 优先，退到官方下载页，装完回填 `PATH` |
| `lib/fetch.ps1` | 一键获取 dsh 检出：前置门禁 → `git clone --depth 1` → `pnpm install` → 复查 |
| `lib/shortcut.ps1` | 生成 / 删除 `.lnk`（向导与命令行共用同一份） |
| `ui/wizard.xaml` | 向导界面 |
| `tests/setup-gui.tests.ps1` | 向导的自动化测试（无头 + 可选开窗） |
| `tests/fetch.tests.ps1` | 获取检出流程的测试（用替身命令，不联网） |
| `installer/build.ps1` | 出安装包与便携 ZIP，并在编译前做发布一致性对账 |
| `installer/dsh-shortcut.iss` | Inno Setup 打包脚本 |
| `docs/dsh-tool-scheduler-symbol.md` | `reading 'prepare'` 崩溃的根因、修复与验证方法 |
| `patches/fix-tool-scheduler-symbol.patch` | 上述修复的一行补丁 |

## 环境要求

- Windows 10/11，系统自带的 Windows PowerShell 5.1 即可（PowerShell 7 也兼容，脚本按 5.1 语法写）
- `node` 在 `PATH` 里（快捷方式里调用 `node`）
- 一份 dsh 源码检出，并且已经 `pnpm install`（源码图需要 `tsx`）
- `%USERPROFILE%\.dsh\.credentials.yaml` 里有可用的凭据（正常跑过一次 dsh 就会有）

## 快速开始

### 1. 图形向导（推荐）

双击 **`setup-gui.cmd`**。它会：

1. **自检环境**，逐项标出 ✅ 正常 / ⚠️ 可忽略 / ❌ 必须解决
2. 缺 **Node.js / Git / pnpm** 时，那一行会出现「**一键安装**」按钮 —— 走 winget；winget 不可用就打开官方下载页
3. **还没有 dsh 检出**？点「**获取 dsh**」：先过前置门禁（缺 git/node/pnpm 会先让你装），
   再 `git clone --depth 1` + `pnpm install`，输出实时打在日志区。
   失败会说明原因（clone 失败会提示可能是网络/加速器）；失败留下的半个目录会自动清理，
   再点一次就是重试 —— 但**有效检出绝不会被删**，`-KeepFailedTarget` 可保留现场用于排查
4. 选 dsh 检出目录（带「浏览」）、端口、快捷方式名字与位置
5. 点「**安装**」：写入 `%USERPROFILE%\.dsh-shortcut\config.json`，并按勾选生成快捷方式

> 向导生成的快捷方式**不带** `-Repo`，路径统一由 `config.json` 决定。
> 因为命令行参数优先级高于配置，如果快捷方式里烧了旧路径，以后在向导里改路径就会被它压住。

### 2. 命令行生成快捷方式

```powershell
.\install.ps1
```

默认放到桌面。常用变体：

```powershell
# 放开始菜单
.\install.ps1 -Place StartMenu

# 放指定目录,并把你自己的 dsh 检出路径烧进快捷方式
.\install.ps1 -Dir 'C:\tools\dsh-shortcut' -Repo 'C:\src\deepseek-harness'

# 换端口、换名字(方便和已经在跑的实例并存)
.\install.ps1 -Port 3081 -Name 'DSH (3081)'
```

已存在同名快捷方式时不会覆盖，加 `-Force` 才会。

### 3. 或者直接用脚本

```powershell
.\open-dsh.ps1
.\open-dsh.ps1 -Port 3081
.\open-dsh.ps1 -Repo 'C:\src\deepseek-harness'
```

### 4. 开发用启动器

```powershell
# 构建图(package exports -> packages/*/lib/*.js),等价于已安装消费者,最稳
.\start-dsh-local.ps1 -Port 3081

# 源码图(tsx + tsconfig paths -> packages/*/src/*.ts),改源码免重新构建
.\start-dsh-local.ps1 -Mode src -Port 3081
```

`start-dsh-local.ps1` 会强制使用**独立的** `DSH_HOME`（默认 `%USERPROFILE%\.dsh-dev-home`），
避免和 `%USERPROFILE%\.dsh` 里的正式安装互相踩，并自动复用一份凭据副本。
注意独立 home 里没有历史会话——会话历史是 home 级别的。

## 路径和别人不一样怎么办

两个脚本的 `-Repo` 默认值是作者本机的 `D:\deepseek-harness\deepseek-harness`，**不是自动探测的**。

| 情况 | 结果 |
| --- | --- |
| `-Repo 'C:\你的\deepseek-harness'` | ✅ 正常 |
| 设了环境变量 `DSH_REPO` | ✅ 正常 |
| 什么都不传 | ❌ 自检直接失败并明确报错，窗口停住等你按回车 |

`-DshHome` 默认 `%USERPROFILE%\.dsh`，`-DevHome` 默认 `%USERPROFILE%\.dsh-dev-home`，本身就是可移植的，
分别可用 `DSH_HOME` / `DSH_DEV_HOME` 覆盖。

`install.ps1 -Repo 'C:\你的\...'` 会把路径烧进快捷方式，之后双击就不用再管了。

> ⚠️ 前提：本工具箱需要一份 **dsh 源码检出**（目录里有 `apps\cli\`，且已经 `pnpm install`）。
> 如果你用的是 npm 全局安装或打包好的二进制，这些脚本不适用。

## 参数与配置

`open-dsh.ps1`：

| 参数 | 环境变量 | 默认值 |
| --- | --- | --- |
| `-Repo` | `DSH_REPO` | `D:\deepseek-harness\deepseek-harness` |
| `-DshHome` | `DSH_HOME` | `%USERPROFILE%\.dsh` |
| `-Port` | – | `3080` |

`start-dsh-local.ps1` 额外有：

| 参数 | 环境变量 | 默认值 |
| --- | --- | --- |
| `-Mode` | – | `lib`（可选 `src`） |
| `-DevHome` | `DSH_DEV_HOME` | `%USERPROFILE%\.dsh-dev-home` |

> ⚠️ `-Repo` 的默认值是**作者本机路径**，不是自动探测的。在别的机器上请显式传 `-Repo`，
> 或设 `DSH_REPO`，或用 `install.ps1 -Repo <检出>` 直接烧进快捷方式。详见上一节。

## 认证是怎么工作的

`dsh web` 默认会打印一个带一次性 token 的 URL 并打开浏览器；token 是**进程级**的，外面拿不到。
所以：

- **由本工具启动**时，浏览器是 dsh 自己用带 token 的 URL 打开的，一定可用。
- **已经有人在跑**时，本工具打开的是裸 `http://127.0.0.1:<port>`，靠浏览器里已有的登录 cookie
  （cookie 用持久化密钥签名、有效期按天算）。如果 cookie 过期或换了浏览器，页面会提示
  `authentication required`，此时关掉 dsh 重新双击即可——重启动会让 dsh 用新 token 打开。

## 安全 / 隐私

- 仓库里**不含任何凭据**。`.gitignore` 已排除 `.credentials.yaml`、临时 DSH home、`*.lnk`。
- 启动器不写凭据，只在目标 home 里没有凭据文件时，从 `%USERPROFILE%\.dsh\.credentials.yaml` 复制一份。
- 端口探测只连 `127.0.0.1`，不监听、不对外暴露任何东西。
- `dsh web` 自身拒绝 `--host 0.0.0.0`，本工具也不放宽这一点。

## 已知限制

- 仅 Windows（`.lnk`、`powershell.exe`、`WScript.Shell` 都是 Windows 专有）。
- 在受限沙箱里（例如禁止命名管道的 CI，或 dsh 自带的 file sandbox），源码图会以
  `spawn EPERM` 失败：tsx 需要 esbuild 以管道 stdio 派生转换进程。这是环境限制，不是脚本问题，
  正常桌面双击不受影响；受限环境请用构建图（`start-dsh-local.ps1` 默认 `-Mode lib`）。
- 「已在跑」那条路径不做深度健康检查，只确认端口在监听且返回的是 DSH 的页面。

## 测试

```powershell
# 无头模式：界面构建、事件装配、安装动作、输入校验、异步取数
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\setup-gui.tests.ps1

# 额外真开一次窗口，3 秒后自动关闭 —— 验证 ContentRendered → 异步自检 → 渲染 这条真实链路
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\setup-gui.tests.ps1 -ShowWindow
```

测试全程隔离：`config.json` 写进 `%DSH_SHORTCUT_CONFIG%` 指向的临时文件，快捷方式写进临时目录，
跑完还会断言真实的 `config.json` 与桌面快捷方式没有被波及。

## 打包与发布

```powershell
# 出便携 ZIP（不需要额外装东西）
.\installer\build.ps1 -SkipInstaller

# 出安装包 + 便携 ZIP（需要 Inno Setup 6：winget install JRSoftware.InnoSetup）
.\installer\build.ps1

# 只做发布一致性对账，不产出任何文件（不需要 Inno Setup）
.\installer\build.ps1 -LintOnly
```

产物落在 `dist/`（已被 git 忽略）：

| 产物 | 说明 |
| --- | --- |
| `dsh-shortcut-setup-<版本>.exe` | 安装包。**免管理员**装到 `%LOCALAPPDATA%\Programs\dsh-shortcut`，带卸载器，装完可直接启动配置向导 |
| `dsh-shortcut-portable-<版本>.zip` | 免安装。解压到任意目录，双击里面的 `setup-gui.cmd` |

### 编译前的对账（`-LintOnly`）

`.iss` 最容易出的错是「漏了一个文件」或「路径写错」，这两类不需要编译器就能查出来：

1. `.iss` 里 `Source:` 引用的每个文件都真的存在
2. 打包清单里的每个文件都被 `.iss` 引用
3. 仓库里所有 git 跟踪的文件，要么在打包清单里，要么在「故意不打包」名单里
   —— **新加了一个 lib 却忘了打进产物时，这条会立刻报警**

### 两个打包注意点

- **Inno Setup 6 官方不带简体中文语言文件**，所以 `[Languages]` 目前只有英文。
  要中文界面得自己放 `ChineseSimplified.isl`（步骤写在 `installer/dsh-shortcut.iss` 顶部注释里）；
  直接引用它会让编译当场失败。
- **`.iss` 还没经过真实编译验证** —— 写这份脚本的机器上没有 Inno Setup。
  上面那套对账覆盖的是文件清单类错误；编译器层面的问题（语法、段落名）
  要等你装好 Inno Setup 跑一次 `build.ps1` 才能确认。便携 ZIP 那条路径是完整验证过的。

## 相关

- 上游项目：[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)（MIT）
- 崩溃排查与补丁：[`docs/dsh-tool-scheduler-symbol.md`](docs/dsh-tool-scheduler-symbol.md)

## English quick start

```powershell
# 1. create a shortcut on the desktop
.\install.ps1 -Repo 'C:\src\deepseek-harness'

# 2. or just run the launcher
.\open-dsh.ps1 -Repo 'C:\src\deepseek-harness'
```

Double-clicking the shortcut opens the DeepSeek Harness Web GUI: it starts `dsh web` from your
checkout when nothing is listening on the port, and otherwise opens the browser at the running
instance. Windows only. `-Repo` must point at your own `deepseek-harness` checkout, or set the
`DSH_REPO` environment variable.

## License

[MIT](LICENSE)
