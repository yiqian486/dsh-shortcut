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
| `install.ps1` | 生成 Windows 快捷方式（`.lnk`），可放桌面 / 开始菜单 / 指定目录 |
| `start-dsh-local.ps1` | 开发用启动器：可切换源码图（tsx）与构建图，并可并存换端口 |
| `docs/dsh-tool-scheduler-symbol.md` | `reading 'prepare'` 崩溃的根因、修复与验证方法 |
| `patches/fix-tool-scheduler-symbol.patch` | 上述修复的一行补丁 |

## 环境要求

- Windows 10/11，系统自带的 Windows PowerShell 5.1 即可（PowerShell 7 也兼容，脚本按 5.1 语法写）
- `node` 在 `PATH` 里（快捷方式里调用 `node`）
- 一份 dsh 源码检出，并且已经 `pnpm install`（源码图需要 `tsx`）
- `%USERPROFILE%\.dsh\.credentials.yaml` 里有可用的凭据（正常跑过一次 dsh 就会有）

## 快速开始

### 1. 生成快捷方式

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

### 2. 或者直接用脚本

```powershell
.\open-dsh.ps1
.\open-dsh.ps1 -Port 3081
.\open-dsh.ps1 -Repo 'C:\src\deepseek-harness'
```

### 3. 开发用启动器

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
