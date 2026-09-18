# dsh-notify-card — 最小插件骨架 + API 考古结论

> 目标功能：**一轮会话结束时，屏幕右下角弹橙色常驻卡片；点一下，GUI 切到那个会话。**
> 宿主 Windows。卡片脚本 `%USERPROFILE%\.dsh\tools\dsh-notify.ps1`（已存在，未改动）。

本目录里是**可直接照抄、已实测跑通**的最小插件。所有 API 名字都来自本机安装的
`@deepseek-ai/dsh@0.1.5-rc.2` / `@deepseek-ai/cordis@4.0.2` 的编译产物与 README，
没有一条是凭印象写的。

---

## 0. 结论先行

**能做。没有硬阻塞。** 四个原本可能致命的点，逐个被排掉了：

| 风险点 | 结论 | 决定性的那行代码 |
|---|---|---|
| 端点必须鉴权，PowerShell 打不进来 | **不必须。** 自己在 `ctx.webServer` 上注册 exact 路由就完全没有鉴权 | `dsh-host-webserver/lib/index.js:322-331`（exact 表先于 prefix 表）；`dsh-host-webserver/README.md:113`（"No server-wide TLS, authentication, or origin policy"） |
| 拿不到会话标题 | **拿得到。** `ctx.sessionTitle.get(session).title` | `dsh-session-title/lib/types/index.d.ts:123` |
| 拿不到 session id | **拿得到。** `session/event` 的第一个参数就是 `Session` 对象 | `dsh-session/lib/types/index.d.ts:62` |
| 切「当前选中会话」 | **可以做，但必须写浏览器半边。** 宿主侧没有这个概念 | `dsh-api-session-controller/lib/types/client/contract/sessions.d.ts:42` `open(id: SessionId): void` |

**唯一的结构性约束（不是阻塞，是设计要求）：**
"当前选中会话" 是**纯浏览器状态**，宿主完全不知道它 —— 没有 RPC、没有 websocket 事件、
没有服务方法。所以这个插件**必须是双半插件**（host half + client half），
由浏览器半边调用 `ctx.sessions.open(id)`。

---

## 1. 文件清单

| 文件 | 作用 |
|---|---|
| `package.json` | 插件清单：`main`/`exports`、`dsh.bundle.patch`、`dsh.client` |
| `cordis.patch.yml` | bundle patch —— 把插件作为一个 row 插进 profile 的 cordis 树 |
| `lib/index.js` | **宿主半边**：订阅 `turn/end` → 读标题 → 拉起 PowerShell 卡片 + 注册两个 HTTP 路由 |
| `lib/client.js` | **浏览器半边**：轮询宿主的 pending 路由 → `ctx.sessions.open(id)` |
| `verify.mjs` | 实测脚本（35 条断言全绿）：用桩 ctx 加载 `lib/index.js`，跑通 turn/end → 弹卡片 → 点击 → pending |
| `verify-client.mjs` | 实测脚本（15 条断言全绿）：桩 `window.__ModuleLoader__`，跑通 轮询 → `sessions.open` → 失败重试 → teardown |
| `probe.ps1` | `dsh-notify.ps1` 的替身，把收到的 argv 写进文件，供 `verify.mjs` 断言 |
| `card-probe.mjs` | 用**真的** `dsh-notify.ps1` 做端到端验证，并复现 `detached: true` 的坑 |
| `spawn-probe.mjs` | `detached: true` 的对照实验 |
| `node_modules/@deepseek-ai/schemastery` | 指向 DSH 安装里的真包（junction），只为让 `verify.mjs` 能跑 |

跑验证：

```powershell
cd 'D:\work\dsh-notify-card-skeleton'
node verify.mjs          # 宿主半边
node verify-client.mjs   # 浏览器半边
```

---

## 2. 安装与调试

```powershell
# 1) 装进 web profile（本地未发布目录）
dsh plugin --profile web add 'D:\work\dsh-notify-card-skeleton'

# 2) 重启 dsh web
dsh web
```

- `dsh plugin --profile <name> <pnpm args>` 是**pnpm 的转发器**：
  `dsh/lib/bin.js:105-116` 定义命令，`dsh/lib/plugin-Ddi42qoW.js:109-113`
  执行 `spawnSync("pnpm", args.map(anchorPathSpec), { cwd: profileDir })`。
- **相对路径会被锚定到「你执行命令时所在的目录」**，不是 profile 目录：
  `plugin-Ddi42qoW.js:90-94`。所以 `add .` 要在插件目录里敲，或者干脆用绝对路径。
- 装完 DSH 会**自动**把包名追加进 `dsh.profile.bundles`，前提是包里声明了
  `dsh.bundle.patch`（`plugin-Ddi42qoW.js:32,53-56`）；否则只警告 "declares no dsh.bundle"。
- 别名写法要用绝对路径：`dsh plugin --profile web add dsh-notify-card@link:D:\...\dsh-notify-card-skeleton`
  —— 那个锚定正则 `^(?:(file|link):)?(\.{1,2}([/\\].*)?)$` 要求**整串**匹配，`name@file:../x` 匹配不上。

### 改什么要重启，改什么不用

| 改动 | 生效方式 | 证据 |
|---|---|---|
| **profile 自己的 `cordis.patch.yml`** | **热生效**（live watch） | `dsh/lib/profile-boot-Dk-7KqJc.js:321-338`；`dsh-app-boot/lib/index.js:1109-1122` |
| `$DSH_HOME\cordis.patch.yml` | 同上（本机这个文件不存在） | 同上一行 |
| **插件代码 `lib/*.js`** | **必须重启** | HMR 以 `config: { root: [] }` 挂载，模块监视是关的（`profile-boot-Dk-7KqJc.js:324-327`）；且 `node_modules/**` 被硬排除（`cordis-plugin-hmr/src/index.ts:41,351`） |
| **插件的 `cordis.patch.yml`** | **必须重启** | 只在 profile 加载时读一次（`dsh-app-boot/lib/index.js:851`），没有任何 watcher |
| `package.json` / `dsh.profile.bundles` | **必须重启** | 只在 boot 时读（`dsh-app-boot/lib/index.js:845`） |
| 浏览器半边 `lib/client.js` | 需要 `pnpm run dev:web` 重建才会被 `dsh-client-hmr` 换掉 | `dsh-client-hmr/README.md:12,32` |

> ⚠ 注意：`%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml` 里的注释
> "改完需要重启 dsh web 才生效" 对**它自己**是错的 —— 那个文件是 live-watched。
> 那句话对 bundle patch 和 `package.json` 才成立。

### 官方文档在哪

**没有。** `docs/user/develop/**`、`docs/config-catalog.md`、`reference/`、`AGENTS.md`
在本机安装里**全都不存在** —— dsh 包的 `files` 只有 `lib/*.js`，README 里所有
`../../../docs/...` 链接都是死链。实际能读的只有三类：

1. 各包的 `README.md` / `README.zh.md`（471 个）；
2. 各包的 `lib/types/*.d.ts`（**最权威** —— 方法签名、事件签名、JSDoc 都在这）；
3. `dsh-agent-presets/presets/cordis/skills/cordis-plugin-development/SKILL.md`（420 行，
   写动态 Cordis 插件用的，但 `ctx.get` / `ctx.effect` / `inject` 的用法讲得最细）。

---

## 3. 逐项 API 结论 + 证据

### A. 插件包的最小结构

**导出形状**（全安装里唯一一句明确说明）：

> `dsh-tool-todo/README.md:88-90`
> "The plugin is a function/namespace plugin: it exports `name` / `inject` / `apply`
> and **no default export**. A stray `export default` would make the Loader's
> `unwrapExports` collapse the module and drop `inject`."

机制在 `cordis-plugin-loader/src/index.ts:191-199`（`unwrapExports`）。
`Plugin` 类型的完整成员表：`cordis/lib/types/registry.d.ts:47-93` ——
`name` / `Config` / `inject` / `provide` / `intercept`，三种入口形状
（`function(ctx, config)` / `class` / `{ apply(ctx, config) }`）。

> 本骨架的 `inject` 是 `['webServer']` —— 只有它**必须**先存在；其余能力用
> `ctx.get()` 兜底（SKILL.md:100-125：「Read optional capabilities with `ctx.get(name)`
> by default ... Declare `inject` only when a Service is a hard dependency」）。

**DSH/Cordis 专有字段** —— `package.json` 的 `dsh` 段，类型定义在
`dsh-package-manifest/lib/types/types.d.ts:6-52`：

| 字段 | 作用 | 证据 |
|---|---|---|
| `dsh.bundle.patch` | profile 加载时按 `join(packageDir, patch)` 读这份 patch | `types.d.ts:24-28`；读取点 `dsh-app-boot/lib/index.js:851-853` |
| `dsh.client` | 声明浏览器半边（`platform` 必须是 `'web'`） | `types.d.ts:38-52`；`dsh-client-modules/README.md:32-34` |
| `dsh.client.inject` | 包级加载顺序（**不是** Cordis 服务注入） | `types.d.ts:42` "Informational package-name dependencies, not Cordis service injection" |

> `dsh.compatibility` / `dshReleases`（`dsh-memory-gate` 里写了）在 0.1.5-rc.2 里
> **没有任何消费者** —— 全量 grep 零命中。写了无害，但别指望它拦版本。

**peerDependencies**：本机所有官方包都是 `0.1.5-rc.2`（lockstep），
`@deepseek-ai/cordis` 是 `4.0.2`。参考 `dsh-memory-gate/package.json:77-83`，
`@deepseek-ai/schemastery` 放 **dependencies**（`^3.18.2`），不是 peer。

**配置 schema**：`@deepseek-ai/schemastery`。最小示例见 `lib/index.js` 的 `Config`，
写法与 `dsh-memory-gate/lib/config.js:1-28` 一致
（`Schema.object` / `.required()` / `.default()` / `Schema.union([...])` / `.min().max().step()`）。
Loader 会在 `apply` 之前按 schema 校验并填默认值 —— `cordis/lib/types/fiber.d.ts:26-31`。

---

### B. 订阅「一轮结束」

**⚠ 关键：`turn/end` 不是 Cordis 事件，是会话日志事件。**

- 日志事件声明：`dsh-session/lib/types/types.d.ts:260-263`
  ```ts
  'turn/end': { turn: number; reason: TurnEndReason };
  ```
- 追加点：`dsh-agent-loop/lib/index.js:994` `this.session.append("turn/end", {...})`（在 `finally` 里）
- 所以**不存在** `ctx.on('turn/end', ...)`。

真正能订阅的 Cordis 事件：

| Cordis 事件 | 语义 | 签名 | 证据 |
|---|---|---|---|
| **`session/event`** | 每次日志追加后的 fire-and-forget 订阅源 | `(session: Session, event: SessionEvent) => void` | 声明 `dsh-session/lib/types/index.d.ts:62`；emit `dsh-session/lib/index.js:1197` |
| `agent/turn-stopping` | turn **即将**关闭，`serial` 模式，可被否决/续命 | `({ agent, turn, signal }) => Promise<void>\|void` | `dsh-agent/lib/types/runtime-types.d.ts:396-400`；emit `dsh-agent-loop/lib/index.js:967` |
| `agent/status` | `idle ⇄ running` 翻转 | `({ agent, status }) => void` | `dsh-agent/lib/types/runtime-types.d.ts:247-250`；`AgentStatus = 'idle'\|'running'`（`:90`） |

> 别的都**不存在**（全量 grep 零命中，不要写）：
> `turn/start` `turn-end` `turnEnd` `agent/turn` `agent/turn-end` `tree/settled` `treeSettled`
> `session/title`（作为 Cordis 事件）`session/turn-end`。
> 注意 `settled` / `turn/end` 作为**普通词**在 DSH 里出现极多（`settledMs`、
> `kind: 'subagent-settled'` 是 message source，不是事件）—— 搜的时候别被带偏。

**「某个 session 的 turn 结束」vs「整棵子代理树落定」：**

- **没有** 「整棵树落定」这个事件。`tree/settled` / `treeSettled` 零命中。
- 逐个 child 落定的事件是 **`subagent/end`**：
  `dsh-subagent/lib/types/index.d.ts:94`，payload `SubagentRunEndInfo`
  = `{ runId, provider, id: SessionId, local, stopReason, lastAssistantMessage? }`
  （`dsh-subagent/lib/types/types.d.ts:85-110`），emit 在 `dsh-subagent/lib/types/lifecycle.js:66,73,119`。
  ⚠ 坑：对 **continuable child**，它是**每个驻留 epoch 一次**，不是每个逻辑任务一次。
  而且 payload 里**没有深度/父节点字段**，要自己用 `runId` 记账。
- **推荐**：长任务用 `session/event` 拿到 `turn/end` 之后，再等
  `agent.whenIdle()` 落定（`dsh-agent/lib/types/runtime-types.d.ts:164`
  —— "Resolve after the current whole-agent activity reaches quiescence"）。
  本骨架的 `idleOnly: true` 就是这个策略（默认开，带 `idleTimeoutMs` 保险丝）。
  理由：`agent-loop/lib/index.js:1002` 显示 turn 结束后若 inbox 还有活，loop 会继续跑，
  所以**单个 `turn/end` 不等于 agent 空闲**。

**怎么排除子代理**：子代理会话是**真的** `Session`，靠 header 区分 ——
`dsh-session/lib/types/types.d.ts:81` `readonly origin?: 'subagent'`、
`:87` `readonly delegationDepth?: number`。本骨架两个都检查。

**有没有 `session/title` 事件？** 有，但同样**只是日志事件**，声明方式是 merge 进
`SessionEventMap`（注意模块名是 `dsh-session/types`，不是 cordis）：
`dsh-session-title/lib/types/index.d.ts:36-44`。**不能** `ctx.on('session/title', ...)`。

---

### C. 读标题 & 切当前会话

#### 读标题

`Session` 对象上**没有** `title` 属性。标题是**投影**，通过服务读：

```js
const sessionTitle = ctx.get('sessionTitle');        // dsh-session-title/lib/types/index.d.ts:33
const snapshot = sessionTitle?.get(session);          // :123  -> SessionTitleSnapshot | undefined
snapshot?.title                                        // string
```

- `SessionTitleSnapshot` = `SessionTitleEventData & { eventSeq, updatedAt }`
  （`dsh-session-title/lib/types/types.d.ts:43-48`），`title: string`。
- 服务实现：`dsh-session-title/lib/index.js:281-283`（直接 fold 日志，
  所以冷会话/replay 会话也能读）。
- `dsh-session-title` 在 base bundle 里**是挂着的**：
  `dsh-base/cordis.patch.yml:48-53`（`fallbackMaxWords: 5` / `fallbackMaxBytes: 40` / `maxTitleBytes: 80`）。
- 兜底：服务不在就退回短 id。本骨架就是这么写的。

#### 切「当前选中会话」

**这是宿主侧的死路，必须走浏览器。**

宿主服务 `ctx.sessionController`（`dsh-api-session-controller/lib/index.js:2726`
`super(ctx, "sessionController", { namespace: "session" })`）的 19 个方法里
**没有**任何选中会话的方法；18 个 wire remote 里也没有
（`lib/typert.remote-client.js` 的 remote id 列表）。
宿主只声明 5 个事件，全是列表/状态变更：
`api-session/added|removed|status|activity|error`（`lib/types/types.d.ts:537-573`）。

宿主→浏览器的转发事件白名单是**编译期常量**，第三方扩不了：
`dsh-api-remotes/lib/types/remote-events.js:12-32`（19 条，没有选中相关的）。

选中状态在浏览器里，还落 `localStorage`：
`dsh-api-session-controller/lib/client.js:3058`
`createSnapshotStore({}, { persist: { name: "dsh.sessions.current" } })`。

**那个方法**：

```ts
open(id: SessionId): void
```
- 公开插件面：`dsh-api-session-controller/lib/types/client/contract/sessions.d.ts:38-42`
  > "Select a session as current. @param id - session id (must exist in the list; unknown ids fail loud)."
- 实现：`lib/types/client/sessions/service.js:152-154` `open(id) { this.manager.select(id) }`
- 真正干活的：`lib/types/client/sessions/manager.js:85-100`，未知 id 会
  `throw new Error('sessions.select: unknown session ...')`。
- 相关：`openSubagent(address)`、`clear()`、只读的 `list.getSnapshot().current`
- ⚠ 命名冲突：`ctx.sessions` 在**宿主**是 `SessionStore`（`dsh-session/lib/index.js:1311`），
  在**浏览器**是 `ClientSessions`（`dsh-api-session-controller/lib/client.js:3087`）。
  同名不同物。

**浏览器半边怎么声明**（真实消费者 `dsh-client-ui-session/lib/client.js:314,334-335`）：

```js
const inject = ['sessions', 'slots'];
function apply(ctx) { ... }
exports.apply = apply;
exports.inject = inject;
```

本骨架的 `lib/client.js` 就是这个形状，只是不注册 UI。

#### 注册本地 HTTP 端点（**重点：鉴权**）

**有两个注册表，选错必被 401。**

| 注册表 | 服务键 | 路径限制 | 鉴权 |
|---|---|---|---|
| `ctx.webServer.register(route)` | `webServer` | 任意绝对路径 | **无**（webserver 本身不带任何鉴权） |
| `ctx.connection.fetch.register(route)` | `connection` | **被 `assertFetchRoute` 强制在 `/api/**`** | **强制** 浏览器签 cookie，否则 401 |

- `ctx.webServer` 服务键：`dsh-host-webserver/lib/index.js:157` `super(ctx, "webServer")`。
- `register` 签名与形状（**只有 3 个字段**，没有 `auth`/`public`/`method`）：
  `dsh-host-webserver/lib/types/index.d.ts:30-39, 90`
  ```ts
  export type WebRouteKind = 'exact' | 'prefix';
  export interface WebRoute {
      kind: WebRouteKind;
      path: string;   // Absolute pathname, no trailing slash
      handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>;
  }
  register(route: WebRoute): () => void;   // 返回 disposer
  ```
- **路由匹配顺序：exact 全表 → 最长 prefix → fallback。**
  `dsh-host-webserver/lib/index.js:322-331`。
- webserver 无鉴权，是设计声明：`dsh-host-webserver/README.md:113`
  > "**No server-wide TLS, authentication, or origin policy** — route owners such as
  > `dsh-client-connection` enforce their own request policy."
- 唯一的 `/api` 关卡在 client-connection 自己的 prefix handler 里：
  `dsh-client-connection/lib/index.js:768-781`，调 `requestRejection`
  （`:552-556`：先 403 Host/Origin 围栏，再 401 cookie）。
  `isAuthenticated`（`:431-441`）要求一个**签过名的 cookie** —— PowerShell 没有 → **401**。
- `connection.fetch.register` 逃不出 `/api`：`assertFetchRoute`（`:696-700`）路径必须 `/api/...`。
- **端口**：`ctx.webServer.port`（getter，不是方法）—— `dsh-host-webserver/lib/types/index.d.ts:81`，
  实现 `lib/index.js:162-165`（`config.port: 0` 时是 OS 分配的真实端口）。
  web profile 默认 **3080**（`dsh-web-app/cordis.patch.yml:140`）。

**本骨架的写法**（`lib/index.js`）：

```js
ctx.effect(() => ctx.webServer.register({
  kind: 'exact',
  path: '/dsh-notify/click',
  handler: (req, res) => { /* 自己 writeHead + end */ },
}), 'dsh-notify-card: click route');
```

**真实先例（本机在跑的第三方插件）**：`dsh-deepseek-quota`
在 `ctx.webServer` 上注册 `/api/deepseek-balance` 和 `/api/deepseek-session-cost?sessionId=`，
它的浏览器半边直接 `fetch('/api/deepseek-balance', { cache: 'no-store' })`
（`dsh-deepseek-quota/lib/client.js:24,87`），宿主半边
`dsh-deepseek-quota/lib/index.js:45,417-491`。它甚至把路由放在 `/api/` 前缀下也照样跑通 ——
因为 `match()` 先查 exact 表。本骨架仍刻意用 `/dsh-notify/*`（不走 `/api`），
避免依赖这个巧合。

**宿主半边的 HTTP 路由不能用于鉴权场景** —— 这个端点是对 loopback 全开放的。
参考官方做法 `dsh-webhook-github/lib/index.js:117-127`（自建 HMAC 校验）。

---

## 4. ⚠ 实测踩到的坑：`detached: true` 会让 PowerShell 脚本根本不执行

`dsh-notify.ps1` 跑的是 WinForms 消息循环（`[System.Windows.Forms.Application]::Run($form)`，
脚本第 197 行），**会阻塞到卡片关闭**。所以必须分离启动、绝不能 await。

但实测（Node v24.20.0 + Windows PowerShell 5.1，见 `spawn-probe.mjs` / `card-probe.mjs`）：

| spawn 选项 | 结果 |
|---|---|
| `{ detached: true, stdio:'ignore', windowsHide:true }` | ❌ `exit 0`，脚本体**从未执行**，无 stderr、无 `error` 事件、目标文件不生成 |
| `{ detached: true, stdio:'ignore' }` | ❌ 同上 |
| `{ stdio:'ignore', windowsHide:true }` + `unref()` | ✅ **真脚本起来了，6 秒后仍活在 `Application.Run` 里，`$env:TEMP\dsh-notify-error.log` 无报错** |

**结论：用 `stdio:'ignore' + windowsHide + unref()`，不要加 `detached: true`。**
Windows 上 Node 不会因为父进程退出而杀掉子进程，`unref()` 已经足够。

（顺带：`Start-Process` / `start /b` 那套 —— 也就是 `dsh-notify.cmd:8` 的做法 —— 是另一条可行路径，
但它要经 `cmd.exe`，参数转义更麻烦。直接 spawn `powershell.exe` 更干净。）

---

## 5. 你没问但会撞上的两件事

1. **浏览器半边是预构建产物。** 宿主直接 serve `lib/client.js`
   （`dsh-client-modules/README.md:46`："the host serves built client bundles, so
   `pnpm run build` must have produced each `lib/client.js` before launch"）。
   本骨架手写的就是最终产物格式 —— `window.__ModuleLoader__.load({ id, factory })`，
   抄自本机可用的 `dsh-deepseek-quota/lib/client.js:10-14,780-806`。
   `id` **必须等于包名**（"the resolved manifest package name identifies the browser module"）。
   想写 TypeScript 就自己加构建步骤输出到这个文件。
2. **SKILL.md 里"不许用 `fetch` / `setInterval` 等全局"只适用于动态 Cordis 插件**
   （`dsh-cordis-client-runner` 里跑的沙箱代码）。静态 bundle 在浏览器里跑，
   普通全局都能用 —— `dsh-deepseek-quota/lib/client.js:451,479` 就用了 `setInterval`，
   `:87` 用了 `fetch`。本骨架客户端半边同样用。

---

## 6. 明确没查到 / 不确定的

1. **`detached: true` 失败的根因**没查透。只测出「Node 24.20.0 + powershell.exe 5.1 +
   `-File` + DETACHED_PROCESS」这个组合下脚本不执行；`cmd.exe /c echo` 用同样的 detached
   是正常的，所以不是 detached 本身全坏。**规避方式是确定的**（别用 detached），根因不是。
2. **`dsh.compatibility` / `dshReleases` 的实际消费者**没找到。全量 grep 零命中，
   只能说「0.1.5-rc.2 的启动器不读它」，不能说「没有任何工具读它」。
3. **两个浏览器标签页会不会抢** —— 本骨架的 pending 槽是「读一次就清空」的单消费者语义，
   所以只有先轮询到的那个 tab 会切。这是设计选择，不是从官方文档推出来的。
4. **`subagent/end` 会不会为孙代理冒泡到根** 未验证。payload 里没有深度字段，
   官方文档只说 scope-filtered dispatch 按「委托父节点」分派。
5. **没有实测过真实的 `dsh plugin --profile web add`**（会改 profile，本轮是只读考古）。
   pnpm 版本是 12.3.4；pnpm 12.0–12.2 有一个 `pnpm add <本地目录>` 的回归，
   12.3.0 修复（`pnpm/CHANGELOG.md:77,89`）。若换机器装不上，改用
   `dsh plugin --profile web add <name>@link:<绝对路径>`。
6. **没有真机点过卡片** —— `card-probe.mjs` 证明了卡片进程起来并阻塞在消息循环、
   错误日志为空，但没有做像素级确认。
