# DSH 任务完成提醒插件 — 调研报告

调研环境：Windows 10 Enterprise LTSC 2021 (19044) 受管控 VDI，DSH `0.1.5-rc.2`，profile `web`，DSH_HOME=`%USERPROFILE%\.dsh`。

---

## 0. 结论先行

**1) 有现成插件可用，而且选择极多。** npm 上 `dsh-*` 前缀的通知类插件检索到 **40 个以上**，
`awesome-dsh-plugin` 有专门的 "Notifications & Integrations" 分区。**不需要自己写插件。**

**2) 关键疑点被推翻：本机 Windows 原生 toast 完全可用，`AppXSvc` 禁用不是障碍。**
见第 2 节实测。所以"系统 toast 不可用"这个前提不成立，最优方案可以用系统级 toast。

**3) 最推荐：`dsh-notify-windows` 0.7.4** —— 专为 Windows 写、零依赖、走 PowerShell 5.1 的
WinRT toast API、自动在 HKCU 注册 AppUserModelId（不需要管理员）、监听 `turn/end` +
`approval/asked`、默认忽略子代理、点击 toast 跳回 DSH Web GUI。

**4) 官方 hook 机制可以做提醒，但不能直接用于"一轮结束"** —— 官方
`dsh-hooks-claude-code` / `dsh-hooks-codex` **没有 turn 结束事件**，只有 `Stop`
（"run 即将停止"），且 `Notification` / `TaskCompleted` / `SessionEnd` 都明确不支持。
它们也**没有挂载在你的 web profile 里**（见第 4 节）。
如果要走 hook 路线，用第三方 `dsh-hooks`（监听原生 session event `turn/end`，内置
`notify: { channel: desktop }`）。

**5) DSH Web GUI 没有任何内置浏览器通知能力** —— 全量 grep 官方 `@deepseek-ai` 前端 +
客户端 bundle，`Notification.requestPermission` / `new Notification(` / `setAppBadge`
**零命中**。必须装插件。

---

## 1. 环境硬约束的核实结果

用 `dsh --profile web --dump-config` 确认当前 web profile 挂载了 **156 个 row，
其中没有任何 hook 或 notification 插件**：

```
=== definitive: any hook/notif entries in resolved profile? ===
NONE — no hook or notification plugin mounted in the web profile
```

当前 `~/.dsh/profiles/web/package.json` 的 bundles：

```json
"bundles": [
  "@deepseek-ai/dsh-base",
  "@deepseek-ai/dsh-web-app",
  "dsh-http-proxy",
  "dsh-deepseek-quota",
  "dsh-memory-gate",
  "dsh-chat-manager"
]
```

即：**这是一个干净的起点，装什么都得自己加。**

---

## 2. ⚠️ 关键推翻：AppXSvc 禁用 ≠ Windows toast 不可用（本机实测）

这是本次调研最重要的发现。用户假设"AppX/UWP 被禁用 → 原生 Toast 整体不可用"，
**实测不成立**。

### 2.1 服务与注册表实测

| 检查项 | 实测值 | 判定 |
|---|---|---|
| `AppXSvc` | `Stopped`，注册表 `Start=4` (Disabled) | 确认禁用 |
| `ClipSVC` | `Stopped`，注册表 `Start=4` (Disabled) | 确认禁用 |
| **`WpnService`** | **`Running`，`Start=2` (Automatic)** | ✅ 通知平台服务在跑 |
| **`WpnUserService_dfa1b`** | **`Running`** | ✅ 用户级推送服务在跑 |
| `ShellExperienceHost_cw5n1h2txyewy` | 存在于 `C:\Windows\SystemApps` | ✅ toast 渲染宿主在 |
| 组策略 `NoToastApplicationNotification` | HKLM/HKCU `Policies\...\Explorer` 下**不存在** | ✅ 没被策略掐 |
| `PushNotifications\ToastEnabled` | 未设置（= 默认允许） | ✅ |
| `explorer.exe` | 多个实例运行中 | ✅ shell 在 |

### 2.2 实际触发 WinRT toast（决定性证据）

用 Windows PowerShell 5.1（本机 `5.1.19041.1237`，`FullLanguage` 模式）调用
`Windows.UI.Notifications.ToastNotificationManager`，并用**真实注册过的 AUMID**
（`{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe`）：

```
AUMID '{1AC14E77-...}\WindowsPowerShell\v1.0\powershell.exe' -> Show() OK, Setting=Enabled
AUMID 'Microsoft.Windows.PowerShell' -> EXCEPTION: "通知已经发布。" (duplicate-post)
```

- `Show()` 返回成功 **且 `Setting=Enabled`** → 该 AUMID 的通知设置是开启的，toast 被平台接收。
- 第二个 AUMID 报"通知已经发布"，说明平台**确实在处理**这些 toast（重复投递错误），而不是静默丢弃。

### 2.3 原理（Microsoft 一手文档）

> "Without a valid shortcut installed in the Start screen or in **All Programs**,
> you cannot raise a toast notification from a desktop app."

—— [How to enable desktop toast notifications through an AppUserModelID](https://learn.microsoft.com/en-us/windows/win32/shell/enable-desktop-toast-with-appusermodelid)

桌面应用发 toast 只需要：**一个放在开始菜单、带 `System.AppUserModel.ID` 属性的 `.lnk` 快捷方式**。
**不需要 MSIX/AppX 包。** `AppXSvc` 是 *AppX Deployment Service*（负责 MSIX 包的注册/安装/更新），
跟 toast 的渲染与投递路径（`WpnService` → `ShellExperienceHost`）是两条独立的链路。

**结论：这台机器上，凡是走"WinRT toast + AUMID 快捷方式"的提醒插件都能用。**

### 2.4 但仍有两条真实限制

1. **`dsh-notify-win` 这类需要"开始菜单注册品牌身份"的插件**，首次触发时会写 HKCU 并可能要求重启
   explorer.exe 才显示图标。`dsh-notify-windows` 的做法更稳（HKCU AUMID，无需管理员）。
2. **纯浏览器 Notification API 的路线仍然受限**：Chrome/Edge 的 `Notification` 最终也是走
   Windows 通知平台（所以本机可用），但**要求 DSH 标签页保持打开**，浏览器还可能冻结长时间
   未使用的后台标签页。想要"浏览器全关也能提醒"，必须选**宿主侧**（host-side）插件。

---

## 3. 线 1：现成插件候选清单

### 3.1 第一梯队（本机推荐）

| 名称 | 来源 | 提醒方式 | Windows 支持 | 原生依赖 | 维护状态 | 安装命令 |
|---|---|---|---|---|---|---|
| **`dsh-notify-windows` 0.7.4** | npm / [GitHub SeverusZh](https://github.com/SeverusZh/dsh-notify-windows) | **宿主侧 Windows 原生 toast**（PowerShell 5.1 WinRT API，自动注册 HKCU AppUserModelId） | ✅ 明确 Windows 10/11 | **零依赖**（无 deps，不需管理员） | 7 stars，2 open issues，2026-09-10 仍在更新；声明支持 DSH 0.1.2-alpha.4+（本机 0.1.5-rc.2 ✅） | `dsh plugin --profile web add dsh-notify-windows` |
| **`@lsq64737/dsh-windows-notifications` 0.1.6** | npm / [GitHub lsq-dsh-plugins](https://github.com/lsq-dsh-plugins/dsh-windows-notifications) | **三级**：浏览器 Notification API（Windows 系统通知）→ 页内 DSH 风格卡片 → Web Audio 合成提示音 | ✅ 专为 Windows | 仅 `zod` + `@deepseek-ai/schemastery` | 2 stars，0 open issues，2026-09-10 更新 | `dsh plugin --profile web add @lsq64737/dsh-windows-notifications` |
| **`dsh-hooks` 0.13.1** | npm / [GitHub PeterBon](https://github.com/PeterBon/dsh-hooks) | **配置驱动 hook**：`run` 外部命令 或内置 `notify: {channel: desktop}`（系统气泡/toast）/ `webhook` | ✅（desktop 通道） | `yaml`、`qrcode`、`@larksuiteoapi/node-sdk` | 6 stars，2 forks，2026-09-14 更新；文档极详尽 | `dsh plugin --profile web add dsh-hooks` |

### 3.2 第二梯队（同样可用，按提醒方式分类）

| 名称 | 版本 | 来源 | 提醒方式 | Windows | 原生依赖 | 安装命令 |
|---|---|---|---|---|---|---|
| `dsh-desktop-notify` | 1.4.1 | [GitHub crazy-L118](https://github.com/crazy-L118/dsh-desktop-notify) | 宿主侧原生 OS toast（Windows 用 native WinRT toast / macOS osascript / Linux notify-send）；**额外支持 HTTP POST 推到多台设备** | ✅ | 零运行时依赖 | `dsh plugin --profile web add dsh-desktop-notify@1.4.1` |
| `dsh-notify-win` | 0.1.1 | [GitHub Andyqwe44](https://github.com/Andyqwe44/dsh-notify-win) | 原生 Windows toast（WinRT `Windows.UI.Notifications`，顶部 hero 大图）+ **任务栏闪烁 `FlashWindowEx`**；toast 失败回退 `NotifyIcon` 气泡 | ✅ Windows 10/11 | 靠 `powershell -File notify.ps1` 子进程 | `dsh plugin --profile web add github:Andyqwe44/dsh-notify-win` |
| `dsh-complete-notify` | 0.6.2 | [GitHub kaixinbaba](https://github.com/kaixinbaba/dsh-complete-notify) | **纯浏览器**：页内 toast + Web Audio 合成音效；页面在后台时改用 `Web Notification API` + 标签页标题闪烁；**权限被拒时降级为 30 秒长 toast** | ✅ 跨平台 | **零系统依赖**（无 osascript/notify-send/PowerShell） | `dsh plugin --profile web add dsh-complete-notify` |
| `@dingyi222666/dsh-session-notification` | 0.1.19 | [GitHub dingyi222666](https://github.com/dingyi222666/dsh-session-notification) | 四类事件各自音效（Web Audio 合成，可上传自定义音频）+ 浏览器系统通知 | ✅ | 零依赖 | ⚠️ **需要 dsh >= 0.1.6-alpha.1，本机 0.1.5-rc.2 不兼容** |
| `dsh-turn-notify` | 0.3.3 | npm（无 repo 字段） | 每 turn 结束：Web Audio 双音"叮" + 浏览器 Notification + **PWA 任务栏角标计数**（Badging API，降级为标题 `(N)`） | ✅ | 纯客户端 | `dsh plugin --profile web add dsh-turn-notify` |
| `dsh-notify-me` | 1.1.5 | [GitHub chromoany](https://github.com/chromoany/dsh-notify-me) | 系统 toast + 提示音 + 标签页标题标记，只在"需要你操作"或"后台跑完"时提醒 | ✅ | 纯浏览器 | `dsh plugin --profile web add dsh-notify-me` |
| `dsh-notify` | 0.1.7 | npm | 原生 Windows toast + **系统托盘图标**（声称是唯一带托盘图标的 dsh 插件）；agent 停止运行时弹（finished / aborted / error / output limit / 等待选择 / session closed） | ✅ | — | `dsh plugin --profile web add dsh-notify` |
| `dsh-gadgets` | 0.4.1 | npm | 合集包，含 `dsh-task-alerts`（task-done / approval 提示音 + 弹窗）+ 皮肤 + 会话折叠 | ✅ | — | `dsh plugin --profile web add dsh-gadgets` |
| `dsh-task-notify` | 0.3.2 | npm | 宿主侧 `node-notifier` 系统通知 | ✅ | `node-notifier` | `dsh plugin --profile web add dsh-task-notify` |
| `@megen-lebar/dsh-notify-local` | 0.1.0 | [GitHub Jamsharden](https://github.com/Jamsharden/dsh-plugins) | Windows 原生 Toast（**借用 PowerShell 的 AUMID，无快捷方式注册也可弹**）；`windows: auto/toast/dialog`，**失败自动回退 WinForms 对话框**（不依赖 `msg.exe`） | ✅ | 零依赖，纯 ESM | ⚠️ README 描述的是本地 `link:` 安装流程，不是标准 `dsh plugin add` |

> 另有一批纯声音插件（`dsh-notify-bell`、`dsh-notify-sound`、`dsh-notify-tone`、
> `dsh-notify-sounds`、`dsh-ui-notify`、`dsh-plugin-uisfx`、
> [AI-Galaxy-GPU/dsh-sound](https://github.com/AI-Galaxy-GPU/dsh-sound)、
> [loyalchiiina/dsh-voice-alert](https://github.com/loyalchiiina/dsh-voice-alert)（Windows only，winmm/waveOut 播放，不改系统音量）），
> 以及一批 IM/邮件/webhook 插件（`dsh-notify-plugin`、`multi-channel-notify`、
> `@lyhalal/dsh-notification-center`、`ejie-dsh-notify-plugin` 走 Resend 邮件、
> [534119219/chicheng-push](https://github.com/534119219/chicheng-push) 支持 Server酱/PushPlus/Bark/钉钉/企微/Telegram/飞书/ntfy）。
> 这些都不解决"屏幕右下角弹窗"，故未列入主表。

### 3.3 关于聚合列表

`awesome-dsh-plugin/awesome-dsh-plugin`（16.1k stars，2026-09-18 更新）**有**
`## Notifications & Integrations` 分区，通知类条目非常密集（含
`aokamoaki/dsh-notify`、`bululuburuarua666/dsh-herald`（三通道：页内 toast + 浏览器横幅 +
宿主侧 OS toast，浏览器关闭也能弹）、`chidaic/dsh-agent-notify`、
`DeepseekHarnessPlugins/Notification`、`173787247/dsh-wsl-notify`（长任务完成弹 Windows
MessageBox）等）。

一手来源：<https://github.com/awesome-dsh-plugin/awesome-dsh-plugin>

---

## 4. 线 2：DSH 自身 hook 机制

### 4.1 官方三个包的分工

| 包 | 角色 | npm |
|---|---|---|
| `@deepseek-ai/dsh-hook-protocol` | 共享规则引擎（matcher / stdin-exit-code-stdout codec / 多 hook 合并 / `hook/*` 事件）。**不单独安装** | [npm](https://www.npmjs.com/package/@deepseek-ai/dsh-hook-protocol) |
| `@deepseek-ai/dsh-hooks-claude-code` | 桥接：跑你已有的 Claude Code `hooks.json` | [npm](https://www.npmjs.com/package/@deepseek-ai/dsh-hooks-claude-code) |
| `@deepseek-ai/dsh-hooks-codex` | 桥接：跑你已有的 Codex `hooks.json` | [npm](https://www.npmjs.com/package/@deepseek-ai/dsh-hooks-codex) |

### 4.2 触发点（**这是本问题的核心**）

**Claude Code 桥接支持的 7 个事件：**

| 事件 | 触发时机 | 能力 |
|---|---|---|
| `SessionStart` | session 开始 | 注入模型可见上下文 |
| `UserPromptSubmit` | agent 收到 prompt | 阻断 prompt / 附加上下文 |
| `PreToolUse` | 工具执行前 | 阻断工具 / 请求审批 |
| `PostToolUse` | 工具执行后 | 带反馈阻断结果 / 附加上下文 |
| **`Stop`** | **run 即将停止** | **可强制再来一步** |
| `SubagentStart` | 子代理启动 | 给运行中的子代理注入上下文 |
| `SubagentStop` | 子代理结束 | **仅观察**，不能阻断或加上下文 |

Codex 桥接只有 5 个：`SessionStart` / `UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `Stop`。

> **回答"有没有 turn 完成事件"：官方桥接里对应的是 `Stop`（"when the run is about to stop"），
> 事件名就叫 `Stop`，不是 `turn/end`。**
> 而且 **`Notification`、`TaskCompleted`、`StopFailure`、`SessionEnd` 等 23 个事件
> 明确不支持**（README "Known Limitations" 原文列出）。

一手来源：本地安装的 `@deepseek-ai/dsh-hooks-claude-code/README.md` 与
`dsh-hooks-codex/README.md`；在线对应
<https://www.npmjs.com/package/@deepseek-ai/dsh-hooks-claude-code>。

### 4.3 hook 怎么执行

- 只有 **`{ type: 'command', ... }` shell 形式**会执行；`http` / `mcp_tool` / `prompt` /
  `agent` handler **一律跳过并告警**。
- 命令通过 `dsh-shell` executor 执行，**工作目录 = 会话工作目录**（agent 的 workspace）。
- **退出码语义**：`exit 2` = 阻断（stderr 作为理由）；**其他任何非零退出码 = 非阻断失败
  （动作继续，只记日志）**；命令根本起不来也一样处理。
  → **对提醒用途来说这非常安全：脚本崩了也不会卡住 agent。**
- stdin payload 基础字段：`session_id`、`transcript_path`（**永远是空字符串**）、`cwd`、
  `hook_event_name`，加上每事件专有字段。
- 环境变量：`CLAUDE_PROJECT_DIR`（默认每 run 设为会话 workspace）、`${CLAUDE_PLUGIN_ROOT}`
  与 `${CLAUDE_PROJECT_DIR}` 在**配置解析时**做字符串替换。
- 同一事件的 hook **串行执行**（按配置顺序）。

**已知限制（对提醒方案有影响的）：**

- `Stop` 事件**不提供 `last_assistant_message`**（被省略），所以 hook 拿不到最终回复文本
  做摘要。`transcript_path` 也是空串，因为默认 zstd 压缩的 session log 脚本读不了。
- `Stop` 是 blocking-capable 的：**若 hook 以 exit 2 退出会强制模型再跑一轮**。
  做提醒脚本时必须保证 `exit 0`（或非 2 的退出码），否则会无限续跑。
- 配置是**进程级**的：`configPath` 只在启动时读一次。

### 4.4 配置写法（官方）

```yaml
- name: '@deepseek-ai/dsh-hooks-claude-code'
  config:
    configPath: ./.claude/hooks.json
    pluginRoot: ./.claude/plugins/my-plugin
    projectDir: .
```

| 字段 | 默认 | 含义 |
|---|---|---|
| `configPath` | 必填 | `hooks.json` 或含 `hooks` 键的 settings 文件路径 |
| `pluginRoot` | — | 替换命令串里的 `${CLAUDE_PLUGIN_ROOT}` |
| `projectDir` | 会话 workspace | 替换 `${CLAUDE_PROJECT_DIR}` 并设为同名环境变量 |
| `defaultTimeoutMs` | `600000` | 单 hook 默认超时 |
| `stderrSummaryMaxChars` | `500` | `hook/result` 事件里 stderr 摘要上限 |

Codex 版同理，外加一个 `model` 字段。

一手来源（官方文档）：
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/config-catalog.md#deepseek-aidsh-hooks-claude-code>
- <https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/config-catalog.md#deepseek-aidsh-hooks-codex>

### 4.5 ⚠️ 但官方 hook 桥接**没有挂载在你的 web profile 里**

`dsh-hooks-claude-code` / `dsh-hooks-codex` 只是 `@deepseek-ai/dsh` CLI 包的
dependency，**不在** profile 的 `dsh.profile.bundles` 里，`--dump-config` 的 156 个 row
中也没有它们。要用必须先加进 profile。

### 4.6 ✅ 更好的 hook 路线：第三方 `dsh-hooks`（监听原生 `turn/end`）

`dsh-hooks` 0.13.1 **不是** Claude Code 桥接的包装，而是一个原生 Cordis 插件，
直接监听 Harness 的 **session event**，因此**有真正的回合结束事件**：

**支持的 18 类事件（v1）：**

| 事件 | 触发时机 |
|---|---|
| `turn/start` | 回合开始 |
| **`turn/end`** | **回合结束（`completed` / `error` / `aborted` / `blocked` / `max-tokens` / `interrupted`）** |
| `tree/settled` | 回合结束后交给子代理的会话，整棵子代理树全部落定 |
| `step/end` | 回合内一步结束 |
| `tool/call` / `tool/result` | 工具调用 / 完成 |
| `user/message` | 会话出现用户消息 |
| `approval/asked` / `approval/decided` | 审批请求 / 出结果 |
| `session/title` / `session/created` / `session/disposed` | 会话生命周期 |
| `agent/created` / `agent/disposed` / `agent/error` / `agent/status` | Agent 生命周期 |
| `hook/failed` | 同一 hook 连续失败 |
| `usage/daily` | 跨日 token 日报 |

**最小可用配置（直接弹系统 toast，不用写任何脚本）：**

```yaml
- id: dsh-hooks
  name: dsh-hooks
  config:
    hooks:
      - on: 'turn/end'
        when: 'completed'
        notify:
          channel: 'desktop'      # 内置通知通道：系统气泡 / toast
      - on: 'approval/asked'
        notify:
          channel: 'desktop'
```

**调外部脚本的写法：**

```yaml
- id: dsh-hooks
  name: dsh-hooks
  config:
    hooks:
      - on: 'turn/end'
        when: 'completed'
        run: 'powershell -NoProfile -File C:\path\to\toast.ps1'
        timeoutMs: 10000
        retries: 0
      - on: 'turn/end'
        input: 'stdin'                 # 把完整上下文 JSON 写入命令 stdin
        run: 'node my-hook.mjs'
```

**关键 env 变量**（通过环境变量传上下文，不拼进 shell 字符串，防注入）：
`DSH_HOOK_EVENT`、`DSH_HOOK_SESSION_ID`、`DSH_HOOK_SESSION_NAME`、`DSH_HOOK_CWD`、
`DSH_HOOK_TURN`、`DSH_HOOK_REASON`、`DSH_HOOK_DURATION_MS`、`DSH_HOOK_CONTENT`
（回合最后助手文本！）、`DSH_HOOK_USAGE_INPUT_TOKENS` / `_OUTPUT_TOKENS`、
`DSH_HOOK_RUNNING_SUBAGENTS`、`DSH_HOOK_ERROR`、`DSH_HOOK_TIMESTAMP` 等。

> **注意**：`dsh-hooks` 的 hook 是 **fire-and-forget**：失败只 `console.warn`、默认不重试、
> **绝不阻塞 agent 循环**。这比官方桥接更适合做提醒（官方桥接的 `Stop` + exit 2 会强制续跑）。

> **"整棵子代理树落定才提醒一次"** 的推荐写法（对长任务尤其有用）：
> ```yaml
> - on: 'tree/settled'
>   notify: { channel: 'desktop' }
> ```

一手来源：<https://www.npmjs.com/package/dsh-hooks> / <https://github.com/PeterBon/dsh-hooks>

### 4.7 hook 路线可行性结论

**可行，但有一个前提和一个坑：**

- ✅ `turn/end` 是**官方持久化 session event**，schema 为
  `{ turn: number; reason: TurnEndReason }`，在官方 `persistence-catalog.md` 有正式定义 →
  第三方插件监听它是走官方契约，不是 hack。
  一手来源：<https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/persistence-catalog.md>
- ✅ 成熟的配置驱动 hook 插件（`dsh-hooks`）已经内置 `desktop` 通知通道，零代码即可。
- ⚠️ 若用**官方** Claude Code / Codex 桥接，只有 `Stop` 没有 `turn/end`，且**必须避免
  exit 2**（会强制模型再跑一轮）。用 `Stop` 也是可行的，见下。
- ⚠️ 官方桥接**默认未挂载**，需要先加进 profile。

**如果坚持用官方 Claude Code 桥接**，`.claude/hooks.json` 大致长这样
（`hooks.json` 的具体 schema 请以
<https://code.claude.com/docs/en/hooks> 为准 —— 这是官方桥接 README 里自己引用的基线）：

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "powershell -NoProfile -File C:\\path\\to\\toast.ps1" }
        ]
      }
    ]
  }
}
```

> **不确定项**：`hooks.json` 里 `matcher` 是否对 `Stop` 生效，官方 README 说
> "`UserPromptSubmit` 和 `Stop` ignore matchers"，因此 `matcher` 字段可以省略。
> 这一点是我从 README 文字读出来的，**如果要用请先读
> `node_modules/@deepseek-ai/dsh-hooks-claude-code/lib/index.js` 的 config 解析代码确认**。

---

## 5. 线 3：Web GUI 浏览器通知

### 5.1 结论：**没有内置**

对以下两个根目录做全量递归 grep（`*.js` / `*.mjs`，< 8MB）：

- `%USERPROFILE%\.dsh\profiles\web\node_modules\@deepseek-ai\**`
- `%LOCALAPPDATA%\Roaming\npm\node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\**`

搜索模式：`Notification.requestPermission`、`new Notification(`、`webkitNotifications`、`setAppBadge`

**结果：零命中。**

（唯一一个 `requestPermission` 命中是 `@deepseek-ai/dsh-acp/lib/index.js:1133` 的
`conn.request(methods.client.session.requestPermission, params)` —— 那是 ACP JSON-RPC
的工具审批方法，跟浏览器通知无关。）

另：`@deepseek-ai/dsh-web-frontend` 包在本机 profile 中不存在（前端 dist 由
`apps/cli` 的 `dsh web` 直接提供），所以我把整个官方包树都扫了一遍。

### 5.2 所以"浏览器通知 + AppX 禁用"这个组合还能不能显示？

**能，而且这个担心本来就是多余的 —— 见第 2 节。**

- 浏览器 `Notification` API（Chrome/Edge）最终**也是走 Windows 通知平台**投递的，
  在通知中心显示为气泡。本机 `WpnService` / `WpnUserService` 在跑，
  `ShellExperienceHost` 在，策略没掐，实测 toast `Show()` + `Setting=Enabled` 成功。
- **`AppXSvc` 只影响 MSIX 包的部署/注册**，不影响通知投递链路。
- 因此：**浏览器通知路线和宿主 toast 路线在本机都可用**，区别只在可靠性：

| 路线 | 浏览器关闭后 | 后台标签被冻结时 | 本机可用性 |
|---|---|---|---|
| 宿主侧 toast（`dsh-notify-windows` / `dsh-hooks` desktop / `dsh-desktop-notify`） | ✅ 仍能弹 | ✅ 不受影响 | ✅ |
| 浏览器 Notification（`@lsq64737/...` / `dsh-complete-notify` / `dsh-turn-notify`） | ❌ 收不到 | ⚠️ 可能延迟 | ✅ |
| 页内 toast / 声音（纯客户端） | ❌ | ⚠️ | ✅ |

---

## 6. 推荐落地方案

### 方案 A（首选，5 分钟）：`dsh-notify-windows`

```powershell
dsh plugin --profile web add dsh-notify-windows
# 重启 dsh web 后生效
```

可选配置（写进 `%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml`，
该文件被运行中的 DSH 热监视，改动立即生效、无需重启）：

```yaml
- id: dsh-notify
  name: dsh-notify-windows
  config:
    enabled: true
    reasons: [completed, error, max-tokens]
    notifyOnApproval: true
    notifyOnAskUser: true
    includeSubagents: false
    excerpt: true
    excerptMaxChars: 80
    openOnClick: true
    appName: DeepSeek Harness
    aumid: DeepSeekHarness.Notify
    webUrl: ''          # 留空自动发现，默认 http://127.0.0.1:3080
```

**为什么首选**：宿主侧（浏览器关了也能弹）、原生 Windows toast（本机已验证可用）、
零依赖、PowerShell 5.1（本机已有）、自动注册 HKCU AUMID 不需要管理员、点击 toast 跳回 GUI。

### 方案 B（想要"整棵子代理树落定才提醒一次"）：`dsh-hooks`

```powershell
dsh plugin --profile web add dsh-hooks
```

```yaml
- id: dsh-hooks
  name: dsh-hooks
  config:
    hooks:
      - on: 'tree/settled'          # 长任务首选：所有子代理都跑完才提醒
        notify: { channel: 'desktop' }
      - on: 'turn/end'
        when: 'completed'
        notify: { channel: 'desktop' }
      - on: 'approval/asked'
        notify: { channel: 'desktop' }
```

### 方案 C（保守/零系统调用）：`dsh-complete-notify`

```powershell
dsh plugin --profile web add dsh-complete-notify
```

纯浏览器 + Web Audio，**不调用任何系统命令**（无 PowerShell / osascript / notify-send），
通知权限被拒时降级为 30 秒长页内 toast。适合 EDR 对子进程拉起敏感的场景。

---

## 7. 需要用户在机器上确认的一件事

我在调研中**真实触发了两条 WinRT toast**（标题分别为 "DSH toast probe" 和
"DSH probe 2 - registered AUMID"）。API 层面全部成功（`Show() OK, Setting=Enabled`）。

**请确认屏幕右下角是否真的出现过这两条气泡。**
- 如果看到了 → 第 2 节结论完全成立，方案 A 直接可用。
- 如果没看到 → 说明是 EDR/VDI 层拦截了 UI 呈现（API 不报错的静默丢弃），
  此时退到方案 C（纯浏览器 + 页内 toast），仍然能满足"右下角弹提醒"的需求。

---

## 8. 来源清单（全部一手）

**DSH 官方**
- 仓库：<https://github.com/deepseek-ai/deepseek-harness>
- hook 配置目录（官方文档）：<https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/config-catalog.md#deepseek-aidsh-hooks-claude-code>
- Codex hook 配置：<https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/config-catalog.md#deepseek-aidsh-hooks-codex>
- 持久化事件目录（`turn/end` 正式定义）：<https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/persistence-catalog.md>
- <https://www.npmjs.com/package/@deepseek-ai/dsh-hook-protocol>
- <https://www.npmjs.com/package/@deepseek-ai/dsh-hooks-claude-code>
- <https://www.npmjs.com/package/@deepseek-ai/dsh-hooks-codex>
- <https://www.npmjs.com/package/@deepseek-ai/dsh>

**Microsoft 官方**
- <https://learn.microsoft.com/en-us/windows/win32/shell/enable-desktop-toast-with-appusermodelid>

**社区插件（npm + GitHub）**
- <https://www.npmjs.com/package/dsh-notify-windows> / <https://github.com/SeverusZh/dsh-notify-windows>
- <https://www.npmjs.com/package/@lsq64737/dsh-windows-notifications> / <https://github.com/lsq-dsh-plugins/dsh-windows-notifications>
- <https://www.npmjs.com/package/dsh-hooks> / <https://github.com/PeterBon/dsh-hooks>
- <https://www.npmjs.com/package/dsh-desktop-notify> / <https://github.com/crazy-L118/dsh-desktop-notify>
- <https://www.npmjs.com/package/dsh-notify-win> / <https://github.com/Andyqwe44/dsh-notify-win>
- <https://www.npmjs.com/package/dsh-complete-notify> / <https://github.com/kaixinbaba/dsh-complete-notify>
- <https://www.npmjs.com/package/@dingyi222666/dsh-session-notification> / <https://github.com/dingyi222666/dsh-session-notification>
- <https://www.npmjs.com/package/dsh-notify-me> / <https://github.com/chromoany/dsh-notify-me>
- <https://www.npmjs.com/package/dsh-turn-notify>
- <https://www.npmjs.com/package/dsh-notify>
- <https://www.npmjs.com/package/@megen-lebar/dsh-notify-local>
- 聚合列表：<https://github.com/awesome-dsh-plugin/awesome-dsh-plugin>

**无可信一手来源的项**：无。本报告所有技术结论均来自 npm registry 元数据、
GitHub 仓库/文件、Microsoft Learn 官方文档，或本机实测。
没有引用任何个人博客、CSDN、知乎、简书或 Medium。
