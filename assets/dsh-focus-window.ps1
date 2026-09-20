﻿# dsh-focus-window.ps1 —— 把浏览器窗口拉到前台
#
# 为什么单独一个脚本、而不是塞进卡片脚本：
#   卡片脚本的显示流程很脆弱（见 docs/engineering-notes.md 第 2 条），
#   往里加代码有把卡片搞挂的风险。而这个动作发生在**点击之后**，由宿主（插件）触发更合适。
#
# 为什么不用 Start-Process 打开 GUI 的 URL：
#   GUI 首页要求鉴权，用户实际打开的地址带 token 且可能随重启变化 ——
#   靠 URL 匹配只会开出一个「需要鉴权」的废标签页。直接激活窗口最稳。
#
# 用法（注意：故意不用 [CmdletBinding()]，也故意不 exit ——
#   实测带 CmdletBinding + exit 的版本会报
#   「ArgumentException: Argument type cannot be System.Void」，原因未深究）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File dsh-focus-window.ps1 [-Title Google Chrome] [-Class Chrome_WidgetWin]
#
# 匹配顺序：
#   1) 标题包含 -Title 的可见顶层窗口
#   2) 没有就退化为「窗口类名以 -Class 开头」的第一个可见顶层窗口
#      —— 窗口标题只反映**当前活动标签**：用户不在 DSH 标签上时按标题找不到，
#         但按窗口类一定找得到浏览器。会话本身已由浏览器半边切好。

param(
  [string]$Title = 'Google Chrome',
  [string]$Class = 'Chrome_WidgetWin',
  # 目标标签页标题里应包含的子串（例如 DeepSeek Harness）。
  # 我们会用 Ctrl+Tab 逐个切标签、每切一次读窗口标题，直到匹配为止 ——
  # 非浏览器进程读不到 Chrome 的标签列表（UIA 实测只有 1 个 Pane），
  # 但「窗口标题 = 当前活动标签标题」这一点是可用的。
  # GUI 的地址（含 token 最好）。没有 GUI 标签可切时，打开它会新起一个 DSH 标签，
  # 那个新标签会自己轮询并消费这次点击，从而跳到对应会话。
  [string]$OpenUrl = ''
  [string]$TabTitle = 'DeepSeek Harness'
)

$ErrorActionPreference = 'Continue'

Add-Type -Namespace DshFocus -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, System.IntPtr pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@

$byTitle = New-Object System.Collections.Generic.List[System.IntPtr]
$byClass = New-Object System.Collections.Generic.List[System.IntPtr]

$cb = [DshFocus.Win+EnumProc]{
  param($h, $x)
  if (-not [DshFocus.Win]::IsWindowVisible($h)) { return $true }
  $t = New-Object System.Text.StringBuilder 512
  [DshFocus.Win]::GetWindowText($h, $t, 512) | Out-Null
  $text = $t.ToString()
  if ($text -eq '') { return $true }
  if ($Title -ne '' -and $text -like "*$Title*") { [void]$byTitle.Add($h) }
  if ($Class -ne '') {
    $c = New-Object System.Text.StringBuilder 128
    [DshFocus.Win]::GetClassName($h, $c, 128) | Out-Null
    if ($c.ToString() -like "$Class*") { [void]$byClass.Add($h) }
  }
  return $true
}
[void][DshFocus.Win]::EnumWindows($cb, [IntPtr]::Zero)

$target = [IntPtr]::Zero
if ($byTitle.Count -gt 0) { $target = $byTitle[0] }
elseif ($byClass.Count -gt 0) { $target = $byClass[0] }

if ($target -ne [IntPtr]::Zero) {
  # 单独调 SetForegroundWindow 会被前台锁挡住，必须先 AttachThreadInput 到当前前台线程
  $fg = [DshFocus.Win]::GetForegroundWindow()
  $tFg = [DshFocus.Win]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
  $tMe = [DshFocus.Win]::GetCurrentThreadId()
  [void][DshFocus.Win]::AttachThreadInput($tMe, $tFg, $true)
  # 只在「最小化」时恢复。绝不能无条件 SW_RESTORE ——
  # 那会把最大化/全屏的浏览器还原成普通窗口（用户实测踩到）。
  if ([DshFocus.Win]::IsIconic($target)) { [void][DshFocus.Win]::ShowWindow($target, 9) }
  [void][DshFocus.Win]::BringWindowToTop($target)
  [void][DshFocus.Win]::SetForegroundWindow($target)
  [void][DshFocus.Win]::AttachThreadInput($tMe, $tFg, $false)
  if ([DshFocus.Win]::GetForegroundWindow() -eq $target) { Write-Output 'focused' }
  else { Write-Output 'raised but not foreground' }
} else {
  Write-Output 'no matching window'
}
# 切回 DSH 标签页：先看标题是否已经是它，不是就用 Ctrl+Tab 逐个切、每切一次读标题。
# 为什么这么绕：非浏览器进程没有直接切 Chrome 标签页的 API（UIA 在这台机器上读不到
# 任何 TabItem，只有 1 个 Pane），而 Chrome 对外部启动的 URL 会开新标签而不是复用。
# 窗口标题始终等于「当前活动标签的标题」，所以「切一次、读一次」可以可靠地找到目标。
Add-Type -AssemblyName System.Windows.Forms
$needle = $TabTitle
if ($needle -ne '') {
  $win = [DshFocus.Win]::GetForegroundWindow()
  $buf = New-Object System.Text.StringBuilder 512
  [DshFocus.Win]::GetWindowText($win, $buf, 512) | Out-Null
  if ($buf.ToString() -notlike "*$needle*") {
    for ($i = 0; $i -lt 15; $i++) {
      try { [System.Windows.Forms.SendKeys]::SendWait('^{TAB}') } catch { break }
      Start-Sleep -Milliseconds 160
      $buf = New-Object System.Text.StringBuilder 512
      [DshFocus.Win]::GetWindowText($win, $buf, 512) | Out-Null
      if ($buf.ToString() -like "*$needle*") { break }
    }
  }
  $buf2 = New-Object System.Text.StringBuilder 512
  [DshFocus.Win]::GetWindowText($win, $buf2, 512) | Out-Null
  if ($buf2.ToString() -like "*$needle*") { Write-Output 'tab focused' } else { Write-Output 'tab not found' }
}

# 没有 GUI 标签可切时：打开这个地址，让浏览器新起一个 DSH 标签。
# 新标签加载后会自己轮询 /dsh-notify/pending 并消费这次点击 —— 于是自动跳到对应会话。
if ($OpenUrl -ne '') {
  try { Start-Process $OpenUrl } catch { }
}
