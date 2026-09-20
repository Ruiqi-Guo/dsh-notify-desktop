# dsh-focus-window.ps1 —— 把浏览器拉到前台，并定位到 DSH 的界面
#
# 三件事，按情况组合：
#   1) 激活浏览器窗口（AttachThreadInput + SetForegroundWindow；单独调 SetForegroundWindow 会被前台锁挡住）
#   2) 有 GUI 标签时：用 Ctrl+Tab 逐个切标签，每切一次读窗口标题，直到匹配 $TabTitle 为止
#   3) 没有 GUI 标签时（宿主传了 -OpenUrl）：打开该地址新起一个标签
#      —— 新标签加载后会自己轮询 /dsh-notify/pending 并消费这次点击，于是自动跳到对应会话
#
# 为什么不用 UI Automation 找标签：本机实测 Chrome 只暴露 1 个 Pane、零个 TabItem/Tab，
# 它的无障碍树没有被激活。而「窗口标题 == 当前活动标签的标题」这一点是可用的，
# 所以「切一次、读一次」是这里唯一可靠的办法。
#
# 为什么不用「打开 GUI 地址让 Chrome 复用已有标签」：实测 Chrome 对外部启动的 URL
# 一律新开标签，不会复用。复用靠上面的切标签，新开只用于「本来就没有标签」的情况。
#
# 注意：故意不用 [CmdletBinding()]、也故意不 exit —— 那样写会报
# 「ArgumentException: Argument type cannot be System.Void」。

param(
  [string]$Title = 'Google Chrome',
  [string]$Class = 'Chrome_WidgetWin',
  [string]$TabTitle = 'DeepSeek Harness',
  [string]$OpenUrl = '',
  # 宿主明确说「现在没有 GUI 标签可切」时置位 —— 跳过逐个切标签那一步。
  # 用开关而不是传空字符串：powershell -File 会把空字符串参数直接吞掉。
  [switch]$NoTabSearch
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

$mainWindow = [IntPtr]::Zero
if ($target -ne [IntPtr]::Zero) {
  $fg = [DshFocus.Win]::GetForegroundWindow()
  $tFg = [DshFocus.Win]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
  $tMe = [DshFocus.Win]::GetCurrentThreadId()
  [void][DshFocus.Win]::AttachThreadInput($tMe, $tFg, $true)
  # 只在最小化时恢复 —— 无条件 SW_RESTORE 会把最大化/全屏的窗口还原成普通窗口
  if ([DshFocus.Win]::IsIconic($target)) { [void][DshFocus.Win]::ShowWindow($target, 9) }
  [void][DshFocus.Win]::BringWindowToTop($target)
  [void][DshFocus.Win]::SetForegroundWindow($target)
  [void][DshFocus.Win]::AttachThreadInput($tMe, $tFg, $false)
  if ([DshFocus.Win]::GetForegroundWindow() -eq $target) { Write-Output 'focused' }
  else { Write-Output 'raised but not foreground' }
  $mainWindow = $target
} else {
  Write-Output 'no matching window'
}

# ── 切到 DSH 标签页（宿主没说"没有标签"、且窗口标题还不匹配时才动手） ───────────
if (-not $NoTabSearch -and $mainWindow -ne [IntPtr]::Zero -and $TabTitle -ne '') {
  Add-Type -AssemblyName System.Windows.Forms

  $buf = New-Object System.Text.StringBuilder 512
  [DshFocus.Win]::GetWindowText($mainWindow, $buf, 512) | Out-Null
  if ($buf.ToString() -notlike "*$TabTitle*") {
    for ($i = 0; $i -lt 15; $i++) {
      try { [System.Windows.Forms.SendKeys]::SendWait('^{TAB}') } catch { break }
      Start-Sleep -Milliseconds 160
      $buf = New-Object System.Text.StringBuilder 512
      [DshFocus.Win]::GetWindowText($mainWindow, $buf, 512) | Out-Null
      if ($buf.ToString() -like "*$TabTitle*") { break }
    }
  }
  $buf2 = New-Object System.Text.StringBuilder 512
  [DshFocus.Win]::GetWindowText($mainWindow, $buf2, 512) | Out-Null
  if ($buf2.ToString() -like "*$TabTitle*") { Write-Output 'tab focused' }
  else { Write-Output 'tab not found' }
}

# ── 没有 GUI 标签可切时：新起一个 DSH 标签 ──────────────────────────────────────
# 新标签加载后会自己轮询 /dsh-notify/pending 并消费这次点击，于是自动跳到对应会话。
if ($OpenUrl -ne '') {
  try {
    Start-Process $OpenUrl
    Write-Output 'tab opened'
  } catch {
    Write-Output ('tab open failed: ' + $_.Exception.Message)
  }
}
