# dsh-focus-window.ps1 —— 把浏览器拉到前台，并定位到 DSH 的界面
#
# 做三件事，按情况组合：
#   1) 激活浏览器窗口（AttachThreadInput + SetForegroundWindow；单独调 SetForegroundWindow 会被前台锁挡住）
#   2) 用 Ctrl+Tab 逐个切标签，每切一次读窗口标题，直到匹配 $TabTitle —— 最多 $TabSearchTries 次
#   3) **只有确实没找到标签**，才打开 $OpenUrl 新起一个
#      —— 新标签加载后会自己轮询 /dsh-notify/pending 并消费这次点击，于是自动跳到对应会话
#
# 为什么是「先切、切不到才开」而不是「先判断有没有标签」：
#   判断（宿主用"最近 5 秒有没有轮询"）会在页面刚重启、轮询短暂中断时失真，
#   于是明明有标签却开了新的。先切后兜底则自我纠正 —— 判断错了结果也对。
#
# 为什么不用 UI Automation 找标签：本机实测 Chrome 只暴露 1 个 Pane、零个 TabItem/Tab，
# 无障碍树没被激活。而「窗口标题 == 当前活动标签的标题」这点可用，所以「切一次、读一次」。
#
# 为什么不用「打开 GUI 地址让 Chrome 复用已有标签」：实测 Chrome 对外部启动的 URL
# 一律新开标签，从不复用。复用只能靠上面的切标签。
#
# 注意：故意不用 [CmdletBinding()]、也故意不 exit —— 那样写会报
# 「ArgumentException: Argument type cannot be System.Void」。

param(
  [string]$Title = 'Google Chrome',
  [string]$Class = 'Chrome_WidgetWin',
  [string]$TabTitle = 'DeepSeek Harness',
  [string]$OpenUrl = '',
  # 最多试几次 Ctrl+Tab。有标签时给足以免漏掉，没标签时给少以免白闪。
  [int]$TabSearchTries = 15,
  # 置位则完全跳过切标签（保留给手动调试用）
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

function Get-WindowTitle([System.IntPtr]$h) {
  $b = New-Object System.Text.StringBuilder 512
  [DshFocus.Win]::GetWindowText($h, $b, 512) | Out-Null
  return $b.ToString()
}

$byTitle = New-Object System.Collections.Generic.List[System.IntPtr]
$byClass = New-Object System.Collections.Generic.List[System.IntPtr]

$cb = [DshFocus.Win+EnumProc]{
  param($h, $x)
  if (-not [DshFocus.Win]::IsWindowVisible($h)) { return $true }
  $text = Get-WindowTitle $h
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

# ── 切到 DSH 标签页 ─────────────────────────────────────────────────────────────
$tabFound = $false
if (-not $NoTabSearch -and $mainWindow -ne [IntPtr]::Zero -and $TabTitle -ne '') {
  Add-Type -AssemblyName System.Windows.Forms

  if ((Get-WindowTitle $mainWindow) -like "*$TabTitle*") { $tabFound = $true }

  if (-not $tabFound) {
    for ($i = 0; $i -lt $TabSearchTries; $i++) {
      try { [System.Windows.Forms.SendKeys]::SendWait('^{TAB}') } catch { break }
      Start-Sleep -Milliseconds 160
      if ((Get-WindowTitle $mainWindow) -like "*$TabTitle*") { $tabFound = $true; break }
    }
  }

  if ($tabFound) { Write-Output 'tab focused' } else { Write-Output 'tab not found' }
}

# ── 确实没有 DSH 标签时才新起一个 ───────────────────────────────────────────────
if ($OpenUrl -ne '' -and -not $tabFound) {
  try {
    Start-Process $OpenUrl
    Write-Output 'tab opened'
  } catch {
    Write-Output ('tab open failed: ' + $_.Exception.Message)
  }
}
