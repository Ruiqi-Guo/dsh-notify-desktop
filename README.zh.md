# dsh-notify-desktop

[English](README.md) | 中文

**给 DeepSeek Harness 的「叫得醒人」的完成提醒** —— 一个会话跑完，屏幕右下角弹一张**橙色常驻卡片**，上面写着**是哪个会话**跑完了；不点它就一直留着，点卡片会把浏览器拉到最前并切回那个会话，点右上角 ✕ 则只关掉卡片、不跳转。

> Windows 专用。宿主半边跑在 DSH 的 Node 进程里，卡片是一个零依赖的 PowerShell + WinForms 脚本。

---

## 为什么不用系统 Toast

这是设计取舍，不是没做：

| 需求 | 系统 Toast / 40 多个现成通知插件 | 本插件 |
|---|---|---|
| **橙色**（或任何自定义配色） | ❌ 外观由系统渲染，应用改不了 | ✅ |
| **不点不消失** | ❌ 系统会收起、送进操作中心 | ✅ |
| 多个会话同时完成不互相顶掉 | ❌ 新 Toast 顶掉旧的 | ✅ 竖向堆叠，各占一行 |
| **点击跳到对应会话** | ⚠️ 只能打开 GUI，切不到具体会话 | ✅ 见下 |
| 中文会话名 | — | ✅ 走 UTF-8 JSON，不经命令行 |

如果你只想要「系统原生的通知」，用 `dsh-notify-windows` 之类的插件更省事；**本插件是为「必须一眼看见、必须知道是哪个会话、必须能点回去」这个场景做的**。

---

## 效果

```
┌──────────────────────────────────┐
│ 会话完成                       ✕ │  ← ✕：只关卡片，不跳转
│ 会话： Fix login redirect · api-service          │  ← 一眼看出是哪个会话跑完了
│ Agent 结束了本轮工作，可以回来看…  │  ← 点卡片主体：浏览器到最前 + 切到该会话
└──────────────────────────────────┘
```

多个会话同时完成时**向上堆叠**，不会互相遮挡；卡片带 `WS_EX_NOACTIVATE`，**不会抢走你正在打字的焦点**。

---

## 安装

```powershell
dsh plugin --profile web add dsh-notify-desktop
# 然后重启 dsh web 生效（插件代码变更必须重启，profile 的 patch 才是热更新的）
```

还没发布到 npm 时，用本地路径：

```powershell
dsh plugin --profile web add 'D:\path\to\dsh-notify-desktop'
```

装完检查一下 profile 里的 bundles 是否多了 `dsh-notify-desktop`（`dsh.bundle.patch` 声明过，`dsh plugin add` 会自动追加）。

---

## 配置

配置写在 profile 的 `cordis.patch.yml` 里（本插件自带的默认值见 [`cordis.patch.yml`](./cordis.patch.yml)）：

```yaml
- id: dsh-notify-desktop
  config:
    title: '会话完成'
    accent: '#F7630C'
    persistUntilClick: true       # false = 10 秒后自动关
    reasons: []                   # 留空 = 所有结束原因都提醒
    skipSubagents: true           # 子代理跑完不提醒
    idleOnly: true                # 等 agent 真正空闲再提醒
    focusBrowser: true
    focusWindowTitle: 'Google Chrome'   # Edge 用 'Microsoft Edge'
```

| 字段 | 默认 | 含义 |
|---|---|---|
| `scriptPath` | `''` | 卡片脚本；留空 = 用包内 `assets/dsh-notify.ps1` |
| `title` / `message` | `会话完成` / 按原因取 | 卡片文案 |
| `persistUntilClick` | `true` | 不点不消失 |
| `style` | `popup` | `popup`（自绘卡片）/ `toast`（系统 Toast）/ `auto` |
| `accent` | `#F7630C` | 主色 |
| `reasons` | `[]` | 只提醒这些结束原因（`completed` / `aborted` / `blocked` / `error` / `max-tokens` / `interrupted`） |
| `skipSubagents` | `true` | 跳过子代理会话 |
| `idleOnly` / `idleTimeoutMs` | `true` / `300000` | 先等 `agent.whenIdle()` 再提醒 |
| `focusBrowser` | `true` | 点击时把浏览器窗口拉到前台 |
| `focusWindowTitle` / `focusWindowClass` | `Google Chrome` / `Chrome_WidgetWin` | 怎么找到浏览器窗口：先按标题子串，找不到再按窗口类兜底（Edge 用 `Microsoft Edge`） |
| `pendingPath` / `clickPath` | `/dsh-notify/*` | 两个内部路由 |

---

## 它是怎么工作的

```
宿主半边 (lib/index.js)
  ctx.on('session/event')  ──过滤──▶ event.type === 'turn/end'
        │                            （turn/end 是会话日志事件，不是 Cordis 事件）
        ├─ 跳过子代理会话
        ├─ 可选：等 agent.whenIdle()
        ├─ 取标题：ctx.get('sessionTitle').get(session).title
        └─ 起卡片 (lib/card.js → cmd /c start → powershell + WinForms)

卡片被点击（点右上角 ✕ 则只关卡片，不走下面任何一步）
  └─ -OnClickUrl ──▶ GET /dsh-notify/click?session=<id>
                        ├─ 宿主登记「待切会话」
                        └─ 宿主拉起 assets/dsh-focus-window.ps1 把浏览器窗口拉到前台

浏览器半边 (lib/client.js)
  每 1 秒轮询 GET /dsh-notify/pending
        └─ 有待切会话 ▶ ctx.sessions.open(id)   ← 切到那个会话
```

**为什么必须有浏览器半边**：「当前选中会话」是纯浏览器状态（还存在 `localStorage` 里），宿主既没有这个概念，也没有对应 RPC 或 websocket 事件。唯一能改它的地方是浏览器里的 `ctx.sessions.open(id)`。

**为什么两个路由不带鉴权**：它们注册在 `ctx.webServer` 上（exact 路由），而不是 `ctx.connection.fetch` —— 后者被硬锁在 `/api/**` 且在浏览器 cookie 鉴权栅栏之后，PowerShell 的请求会吃 401。

---

## 已知限制

- **只支持 Windows**（`os: ["win32"]`）：卡片是 PowerShell + WinForms。「点击跳到对应会话」还依赖浏览器**已打开 GUI**。
- **「拉到前台」是按窗口标题/类名找浏览器**，所以默认值认的是 Chrome（`Google Chrome` / `Chrome_WidgetWin`）。用 Edge 请把 `focusWindowTitle` 改成 `Microsoft Edge`（类名相同，不用改）。
- **`turn/end` ≠ 整棵树落定**：DSH 没有「所有子代理都跑完」的事件。长任务想要「整树落定才提醒一次」，现在只能靠 `idleOnly`（等 agent 空闲）近似。
- **多个浏览器标签页**：待切会话是单消费者（读一次就清空），所以只会有一个标签页跳过去 —— 这是刻意的。

---

## 真机验证记录

以下都在 Windows 10 Enterprise LTSC 2021 + `@deepseek-ai/dsh@0.1.5-rc.2` + Chrome 上实测过：

| 项 | 结果 |
|---|---|
| 会话跑完自动弹卡片 | ✅ |
| 卡片显示**会话名**（中文无乱码） | ✅ |
| **不点不消失** | ✅ 8+6 秒后仍在 |
| 右上角 **✕ 只关闭、不跳转** | ✅ |
| **点卡片 → 浏览器到前台 + GUI 切到该会话** | ✅ |
| 已在目标会话时点卡片 | ✅ 正常，且**不会取消窗口的最大化/全屏** |
| 普通窗口 / 最大化 / 全屏 三种状态下点击 | ✅ 窗口状态均不受影响 |
| 多个会话同时完成 | ✅ 竖向堆叠，各占一行 |
| 两个内部路由免鉴权可被 PowerShell 直接访问 | ✅ `/dsh-notify/pending` → 200 |

宿主半边另有 18 条断言的自测：`node verify.mjs`。

---

## 开发

```powershell
# 卡片脚本单独测（不经 DSH）—— 会真的弹卡片
node -e "import('./lib/card.js').then(async (m) => { const s = m.resolveCardScript(''); console.log(m.showCard({ script: s, title: '测试', session: 'dev', message: 'hello', seconds: 8 })) })"

# 聚焦脚本单独测（把浏览器窗口拉到前台）
powershell -NoProfile -ExecutionPolicy Bypass -File assets/dsh-focus-window.ps1

# 宿主半边自测（桩 ctx，不会真弹卡片）
node verify.mjs
```

工程笔记（几个花了很久才定位的坑，改代码前建议先看）见 [`docs/engineering-notes.md`](./docs/engineering-notes.md)；
插件 API 的一手考古与现成插件调研见 [`docs/research/`](./docs/research/)。

## License

MIT
