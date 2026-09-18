# 工程笔记：几个花了很久才定位的坑

写下来是因为它们**全部表现为「什么都没发生」**，而"什么都没发生"是最难查的一类症状。
改代码前建议先扫一遍。

---

## 1. PowerShell 脚本语法错误 = 完全静默的失败

`.ps1` 一旦有语法错误（哪怕只是一个 `.GetNewClosure()` 写在了方法参数列表里 —— 解析器不支持那种写法），
后果是：

- 进程正常起来、正常退出，**退出码 0**
- **没有任何输出**，连 `try/catch` 都没进去，所以脚本自己的错误日志一声不吭
- 如果你是用 `-WindowStyle Hidden` 或 `stdio: 'ignore'` 起的，**连报错都看不见**

**规矩**：每次改完 `.ps1`，先过一遍解析器，解析不过就立刻停下，别接着做功能测试。

```powershell
$err = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$err)
```

---

## 2. `Add_Shown` 里抛异常 → 窗口永远不可见，但消息循环照跑

```powershell
$form.Add_Shown({
  $ex = [Win]::GetWindowLong($form.Handle, -20)      # ← 这里一抛
  [Win]::SetWindowLong($form.Handle, -20, $ex -bor 0x08000000)
  [Win]::SetWindowPos($form.Handle, [IntPtr](-1), ...)
})
```

在 `$ErrorActionPreference = 'Stop'` 下，这个事件处理器抛异常会**打断窗口的显示流程**，
而 `Application.Run` 的消息循环**继续跑**。于是观测到的现象是：

- 进程一直活着（像是"卡片开着"）
- `Application.Run` 确实进去了
- **屏幕上什么都没有**，连隐藏窗口都枚举不到

**规矩**：所有"锦上添花"的 UI 调整（置顶、不抢焦点、改边距）一律包 `try/catch` ——
它们没资格把卡片本身搞挂。本仓库的 `assets/dsh-notify.ps1` 已经这么做了。

---

## 3. 从 Node 拉 PowerShell GUI：只有 `cmd /c start` 能出可见窗口

同一台机器、同一个脚本、同一批参数，实测（Node v24.20.0 + Windows PowerShell 5.1）：

| 调用方式 | 结果 |
|---|---|
| `spawn('powershell.exe', args, { stdio:'ignore', windowsHide:true })` | ❌ 进程活着、`Application.Run` 在跑、**零窗口、零报错** |
| `spawn('powershell.exe', args, { detached:true, ... })` | ❌ 进程立刻 exit 0，**脚本体从未执行**（无 stderr、无 error 事件） |
| `spawn('cmd.exe', ['/c','start','','/b','powershell.exe', ...])` | ✅ **卡片正常出现** |
| `Start-Process powershell.exe -ArgumentList ...`（走 ShellExecute） | ✅ 卡片正常出现 |

所以 `lib/card.js` 一律走 `cmd /c start`。根因没有查透（`detached` 为什么连脚本都不执行、
直接 `spawn` 为什么没有窗口，都还没定位到机制层），但**规避方式是确定的、可复现的**。

---

## 4. 中文不能经 `cmd.exe` 的命令行

参数要经过 `cmd.exe`，而它按 **OEM 代码页**解释 argv —— 中文会话名会变乱码。

**做法**：卡片内容全部写进 **UTF-8 的 JSON 临时文件**，命令行上只留纯 ASCII 的路径，
脚本用 `-FromJson <path>` 读回来（并且用 `[System.IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)` 读，
不要用 `Get-Content -Raw` —— 后者按 ANSI 读，中文会乱）。

---

## 5. 并发弹出的卡片不能用「数已有窗口」来堆叠

三张卡片在同一毫秒弹出时，每一张都会把"已有卡片数量"读成 0，
于是算出同一个 Y —— 三张完全重叠。改用"位置冲突检测"也一样会落空，因为那时三张都还没创建窗口。

**做法**：跨进程原子预留 —— 命名互斥体（`Global\dsh-notify-slots`）+ 每个卡片一个槽位文件，
预留时顺手清掉已退出卡片占的槽，卡片关闭时释放自己的槽。

---

## 6. PowerShell 里回调改不了外层变量

```powershell
function F {
  $count = 0
  $cb = [SomeDelegate]{ param($h,$x) $script:count++ }   # ❌ 写的是脚本作用域，不是 $count
  ...
}
```

`$script:x++` 和函数局部 `$x` **是两个变量**。跨作用域共享状态要用**对象引用 + 方法调用**：

```powershell
$list = New-Object System.Collections.Generic.List[object]
$cb = [SomeDelegate]{ param($h,$x) [void]$list.Add($h) }   # ✅ 引用同一个对象
```

---

## 7. `Start-Process -ArgumentList` 里含空格的值必须加引号

```powershell
Start-Process node -ArgumentList 'D:\work\x.mjs', 'start'   # ❌ 被拆成两个参数
Start-Process node -ArgumentList '"D:\work\x.mjs"', 'start' # ✅
```

不加引号时 `D:\work` 会变成脚本路径、`Agent\x.mjs` 变成多余参数，
进程**静默退出**（尤其配了 `-WindowStyle Hidden` 时）。

---

## 8. 读日志时的编码假象

PowerShell 5.1 的 `Get-Content` 默认按 **ANSI** 读文件。用它读一个 UTF-8 日志，
中文会显示成乱码 —— 但**文件本身是好的**。别据此判断"写入坏了"。
要确认就用 `[System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)`。
本仓库的 `logs/record-analysis.log`（同类工具）索性把标签写成 ASCII，避免这种歧义。

---

## 9. `ShowWindow(SW_RESTORE)` 会把最大化/全屏窗口还原掉

激活一个已有窗口时，很容易顺手写：

```powershell
[void][Win]::ShowWindow($h, 9)   # SW_RESTORE —— 错
[void][Win]::SetForegroundWindow($h)
```

但 `SW_RESTORE` 的语义是「把最小化/最大化/全屏的窗口还原成**普通窗口**」。
用户正在全屏用浏览器时点通知卡片，浏览器就被还原了（实测踩到）。

正确做法 —— **只在最小化时才恢复**：

```powershell
if ([Win]::IsIconic($h)) { [void][Win]::ShowWindow($h, 9) }   # 9 = SW_RESTORE
[void][Win]::BringWindowToTop($h)
[void][Win]::SetForegroundWindow($h)
```

验证方式：开个记事本 → `ShowWindow(SW_MAXIMIZE)` → 跑聚焦逻辑 →
`IsZoomed()` 必须仍为真。
