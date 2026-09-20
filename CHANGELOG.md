# Changelog

本文件记录所有值得注意的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.1.0] — 2026-09-18

首个版本。

### 新增

- **会话完成时的橙色常驻卡片**：会话名独占一行，可直接看出是哪个会话跑完了。
- **不点不消失**（`persistUntilClick`，默认开）—— 与系统 Toast 的核心差别。
- **右上角关闭键**：只关闭卡片，**不触发跳转**。
- **多张卡片竖向堆叠**：跨进程命名互斥体 + 槽位文件做原子预留，并发弹出也不重叠。
- **点击卡片**：把浏览器拉到最前（`focusBrowser` + `webUrl`），并切换 GUI 到该会话。
- **不抢焦点**：卡片带 `WS_EX_NOACTIVATE`，不会打断正在进行的输入。
- **失败留痕**：卡片脚本出错会写 `%TEMP%\dsh-notify-error.log`。
- **只对顶层会话提醒**：子代理会话跳过；`idleOnly` 先等 `agent.whenIdle()` 再提醒。
- **可配置的结束原因白名单**：`completed` / `aborted` / `blocked` / `error` / `max-tokens` / `interrupted`。

### 工程备注

- 卡片内容经 **UTF-8 JSON 临时文件**传递，不经 `cmd.exe` 的命令行 —— 中文会话名不会乱码。
- 卡片进程一律经 `cmd /c start` 拉起：实测直接 `spawn('powershell.exe', …)` 会得到一个
  **活着但没有窗口**的进程，`detached: true` 更会让脚本根本不执行。
- 详见 [`docs/engineering-notes.md`](./docs/engineering-notes.md)。

### 修复

- **点击卡片不再取消浏览器的最大化/全屏**：聚焦脚本原先无条件调用
  `ShowWindow(SW_RESTORE)`，而该调用的语义是把最大化/全屏窗口还原成普通窗口。
  现在只在窗口**最小化**时才恢复。（用户实测踩到：正在全屏用浏览器时点卡片，
  浏览器被还原了。）

## [0.1.1] — 2026-09-20

### 修复

- **点击卡片无法切换会话**：`package.json` 里 `dsh.client.inject` 写的是**提供者包名**
  （`@deepseek-ai/dsh-api-session-controller`），而本机实际可用的第三方插件
  （`dsh-deepseek-quota`）两处用的都是**服务名**。名字不一致时 `ctx.sessions` 不会被注入，
  于是 `open()` 抛错、又被 `select()` 的 try/catch 吞掉 —— 表现就是「点了卡片什么都没发生」，
  而轮询仍在正常消费点击，很难怀疑到这一层。现已改成 `"sessions"`。

### 变更

- 浏览器半边的失败不再静默：启动时打印一行自检（浏览器半边是否就绪、`ctx.sessions` 是否注入成功），
  切换成功/失败也会打印对应日志。

### 新增

- **点击卡片会切回 DSH 标签页**，而不只是把浏览器窗口拉到最前。做法：先激活窗口，
  再用 `Ctrl+Tab` 逐个切换标签、每切一次读窗口标题（窗口标题始终等于当前活动标签的标题），
  直到出现 `focusTabTitle`（默认 `DeepSeek Harness`）为止。
- 本轮同时修正了上一版的错误做法：**打开 GUI 的精确地址并不会让 Chrome 复用已有标签页**，
  只会多开一个新标签（实测）。该做法已移除。
