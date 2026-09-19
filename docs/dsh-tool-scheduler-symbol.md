# 本地 dsh 修复说明（`reading 'prepare'` 崩溃）

> 这是针对 `deepseek-ai/deepseek-harness` 某个具体版本（`0.1.6-alpha.2`）的排查记录与临时补丁。
> 上游若已修复，请以你的实际代码为准。

## 现状（已确认可用）

- 3080 上的 GUI 是**本地源码版**：`pnpm dsh web` → `node --import tsx/esm apps/cli/src/bin.ts "web"`，
  `@deepseek-ai/dsh-root@0.1.6-alpha.2`，工作目录为你的 dsh 检出，`DSH_HOME=%USERPROFILE%\.dsh`。
- 工具调用正常（会话记录中 `toolMs` 持续累加，不再出现 `reading 'prepare'`）。
- 修复前同一路径可 100% 复现：`dsh: UNKNOWN: Cannot read properties of undefined (reading 'prepare')`，
  且表现为「聊天正常、第一个工具调用必崩」（旧会话日志里连续 4 次都是这样）。

## 根因

`packages/core/tools/src/index.ts` 里的工具调度器键是**模块私有的 Symbol**：

```ts
export const TOOL_RUNTIME_SCHEDULER: unique symbol = Symbol('@deepseek-ai/dsh-tools.scheduler')
```

而 `dsh-agent-loop` 是这样取它的：

```ts
// packages/core/agent-loop/src/tool-calls.ts:170
const prepared = await ctx.tools[TOOL_RUNTIME_SCHEDULER].prepare(call.exec)
```

本地检出里同时存在两套模块图：

| 图 | 入口 | 解析方式 |
| --- | --- | --- |
| 源码图 | `pnpm dsh`（`apps/cli/src/bin.ts`） | tsx + `tsconfig.base.json` 的 `paths` → `packages/*/src/*.ts` |
| 构建图 | `node apps/cli/lib/bin.js` | package `exports` → `packages/*/lib/*.js` |

`Symbol()` 每个模块实例各造一个，两份 `dsh-tools` 的键不相等，于是 `ctx.tools[SYM]` 取到 `undefined`，
`.prepare` 抛错。只有当「提供 `ctx.tools` 的实例」和「读 Symbol 的实例」是同一份时才能对上。

仓库自身的策略也说明核心包必须共享单实例：`scripts/package-dependency-policy.ts` 中可安全重复安装的包只有
`dsh-brand / dsh-lazy-require / dsh-typert-protocol / dsh-util-crypto / dsh-util-values`。

## 修复

一行改动（补丁见 `patches/fix-tool-scheduler-symbol.patch`）：

```diff
-export const TOOL_RUNTIME_SCHEDULER: unique symbol = Symbol('@deepseek-ai/dsh-tools.scheduler')
+export const TOOL_RUNTIME_SCHEDULER: unique symbol = Symbol.for('@deepseek-ai/dsh-tools.scheduler')
```

`Symbol.for` 走全局符号注册表，任意份数的实例都命中同一个键。改完 `pnpm run build` 会从这份 src 重新生成产物，
不需要再手工同步 `lib/`。

```powershell
# 在 dsh 检出根目录执行（假设本工具箱就在检出的隔壁或任意位置）
git apply <本工具箱>\patches\fix-tool-scheduler-symbol.patch
pnpm install
pnpm run build
```

> 如果你的检出**已经**打过这个补丁，`git apply` 会报 `patch does not apply` —— 这说明修复已生效。
> 可以用 `git apply --check -R <补丁>` 反向确认：反向能应用 = 当前就是修复后的状态，直接跳过这一步。

⚠️ 不要把这行改回 `Symbol(...)`：改回后重启源码模式会立刻回到原来的崩溃。
`git pull` 时这一行会有冲突，按上游实际实现取舍（理想情况是上游改成 `Symbol.for` 或加显式单实例校验）。

## 验证方法（可重复）

```powershell
# 1) 源码图与构建图共用同一个键（修复后应为 true；未修复时为 false）
node --input-type=module -e "const r='<你的 dsh 检出>';const a=await import('file:///'+r.replace(/\\/g,'/')+'/packages/core/tools/src/index.ts');const b=await import('file:///'+r.replace(/\\/g,'/')+'/packages/core/tools/lib/index.js');console.log('libEqualsSrc:',a.TOOL_RUNTIME_SCHEDULER===b.TOOL_RUNTIME_SCHEDULER)"

# 2) 源码模式端到端（打补丁前必然失败）
cd <你的 dsh 检出>
$env:DSH_HOME="$env:USERPROFILE\.dsh-dev-home"   # 用独立 home，别污染正在用的 ~/.dsh
pnpm dsh --profile headless "用 read 工具读 pnpm-workspace.yaml，然后只回复 DONE"
```

## 日常启动

```powershell
# 源码图（与 GUI 当前形态一致，能看到 ~/.dsh 里的历史会话）
.\open-dsh.ps1

# 开发用：构建图 / 源码图切换到独立 dev home，可并存换端口
.\start-dsh-local.ps1 -Port 3081
.\start-dsh-local.ps1 -Mode src -Port 3081
```

- 想和已经在跑的实例并存 → 换端口。
- `start-dsh-local.ps1` 会强制使用独立 `DSH_HOME`（默认 `%USERPROFILE%\.dsh-dev-home`，可用
  `-DevHome` 或环境变量 `DSH_DEV_HOME` 覆盖）并复用一份凭据副本，避免和 `%USERPROFILE%\.dsh` 里的正式安装互相踩。
- `src` 模式改源码免构建；`lib` 模式等价于已安装消费者的解析方式，最接近正式安装。

## 可选清理（下次重启本地实例时再做）

切安装方式时，`~/.dsh/profiles/node_modules/@deepseek-ai/*` 可能残留指向 npx 缓存的陈旧链接。
当前 runtime 解析模式会绕过它们，所以**不影响正在跑的进程**；若想让本地安装彻底接管这个 home：

```powershell
# 先停掉本地 dsh，然后：
Remove-Item -Recurse -Force "$env:USERPROFILE\.dsh\profiles\node_modules"
Remove-Item -Recurse -Force "$env:USERPROFILE\.dsh\profiles\web\.dsh-module-fallback"
# 重新启动 dsh web，让它按当前安装重建
```

之后不要再拿另一种安装方式的 dsh 启动同一个 home（一个 home 只归一个安装）。
会话历史在 `~/.dsh/sessions` 下，属于 home 级别——换 home 会看不到旧会话，这是保留共享 home 的唯一理由。

## 上游 issue 草稿（英文，可直接贴）

**Title:** `Cannot read properties of undefined (reading 'prepare')` when the source and built module graphs of `@deepseek-ai/dsh-tools` coexist

**Body:**

- Repo: `deepseek-ai/deepseek-harness`, master `ddefc45fbc` (`0.1.6-alpha.2`), Windows 11, Node 24/26, pnpm 11.7.
- Repro: `pnpm install && pnpm run build && pnpm dsh web` from a fresh clone; then send any prompt that makes the model call a tool
  (e.g. "list this folder with glob"). Chat works, the first tool call fails the whole turn:
  `{"kind":"error","error":{"message":"Cannot read properties of undefined (reading 'prepare')","code":"UNKNOWN"}}`.
- Cause: `TOOL_RUNTIME_SCHEDULER` is a module-private `Symbol('@deepseek-ai/dsh-tools.scheduler')`
  (`packages/core/tools/src/index.ts:463`) stored as an instance field on `ToolRuntime`, while
  `packages/core/agent-loop/src/tool-calls.ts:170` reads `ctx.tools[TOOL_RUNTIME_SCHEDULER].prepare(...)`.
  In a dev checkout the CLI runs from `src` (tsx + tsconfig `paths`) while the profile's plugin tree can resolve to
  `lib` (package `exports` / the profile module fallback), so the two module instances disagree on the symbol and the
  lookup yields `undefined`. Verified: the same specifier resolves to `packages/core/tools/lib/index.js` under plain
  Node and to `packages/core/tools/src/index.ts` under `tsx`; the two exported symbols are not equal.
- Suggested fixes: declare the key with `Symbol.for(...)` (shared symbol registry), or make the consumer
  fail loudly with the expected/provided symbol descriptions instead of a bare property access.
