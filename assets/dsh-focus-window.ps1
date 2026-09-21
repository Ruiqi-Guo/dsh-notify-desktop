# dsh-focus-window.ps1 —— 把浏览器拉到前台，并定位到 DSH 的界面
#
# 做三件事，按情况组合：
#   1) 激活浏览器窗口（AttachThreadInput + SetForegroundWindow；单独调会被前台锁挡住）
#   2) 用 Ctrl+Tab 逐个切标签，每切一次读窗口标题，直到匹配 $TabTitle —— 最多 $TabSearchTries 次
#   3) **只有确实没找到标签**，才打开 $OpenUrl 新起一个
#      —— 新标签加载后会自己轮询 /dsh-notify/pending 并消费这次点击，于是自动跳到对应会话
#
# 为什么「先切、切不到才开」而不是「先判断有没有标签」：
#   判断会在页面刚重启、轮询中断时失真，于是明明有标签却开新的。先切后兜底则自我纠正。
#
# 为什么不用 UI Automation：本机实测 Chrome 只暴露 1 个 Pane、零个 TabItem/Tab。
# 而「窗口标题 == 当前活动标签的标题」可用，所以「切一次、读一次」是这里唯一可靠的办法。
#
# 注意：故意不用 [CmdletBinding()]、也故意不 exit —— 那样写会报
# 「ArgumentException: Argument type cannot be System.Void」。
#
# 每次运行都会往 %TEMP%\dsh-focus.log 追加诊断（排查「为什么又开了新标签」用）。

param(
  [string]$Title = 'Google Chrome',
  [string]$Class = 'Chrome_WidgetWin',
  [string]$TabTitle = 'DeepSeek Harness',
  [string]$OpenUrl = '',
  [int]$TabSearchTries = 15,
  [switch]$NoTabSearch
)

$ErrorActionPreference = 'Continue'
$logFile = Join-Path $env:TEMP 'dsh-focus.log'
function Log([string]$m) {
  try { Add-Content -Path $logFile -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m) -Encoding UTF8 } catch { }
}

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

$candidates = New-Object System.Collections.Generic.List[object]
$cb = [DshFocus.Win+EnumProc]{
  param($h, $x)
  if (-not [DshFocus.Win]::IsWindowVisible($h)) { return $true }
  $text = Get-WindowTitle $h
  if ($text -eq '') { return $true }
  $c = New-Object System.Text.StringBuilder 128
  [DshFocus.Win]::GetClassName($h, $c, 128) | Out-Null
  $cls = $c.ToString()
  $score = 0
  if ($Class -ne '' -and $cls -like "$Class*") { $score = 1 }
  if ($Title -ne '' -and $text -like "*$Title*") { $score = 2 }
  # 标题里已经带 TabTitle 的窗口，最可能就是"已经停在 DSH 上"的那个 —— 优先选它。
  # 这条很重要：Electron 应用（例如 Yoda）的窗口类同样是 Chrome_WidgetWin_1，
  # 只按类名选可能选错窗口，于是在错的窗口里 Ctrl+Tab，自然找不到 DSH 标签。
  if ($TabTitle -ne '' -and $text -like "*$TabTitle*") { $score = 3 }
  if ($score -gt 0) { [void]$candidates.Add([pscustomobject]@{ H = $h; Text = $text; Score = $score }) }
  return $true
}
[void][DshFocus.Win]::EnumWindows($cb, [IntPtr]::Zero)

Log ('--- run: TabTitle=' + $TabTitle + ' tries=' + $TabSearchTries + ' openUrl=' + $OpenUrl)
foreach ($c in $candidates) { Log ('  candidate score=' + $c.Score + ' : ' + $c.Text) }

$target = [IntPtr]::Zero
$picked = ''
if ($candidates.Count -gt 0) {
  $best = $candidates | Sort-Object -Property Score -Descending | Select-Object -First 1
  $target = $best.H
  $picked = $best.Text
}
Log ('  picked: ' + $picked)

$mainWindow = [IntPtr]::Zero
if ($target -ne [IntPtr]::Zero) {
  $fg = [DshFocus.Win]::GetForegroundWindow()
  $tFg = [DshFocus.Win]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
  $tMe = [DshFocus.Win]::GetCurrentThreadId()
  [void][DshFocus.Win]::AttachThreadInput($tMe, $tFg, $true)
  if ([DshFocus.Win]::IsIconic($target)) { [void][DshFocus.Win]::ShowWindow($target, 9) }
  [void][DshFocus.Win]::BringWindowToTop($target)
  [void][DshFocus.Win]::SetForegroundWindow($target)
  [void][DshFocus.Win]::AttachThreadInput($tMe, $tFg, $false)
  if ([DshFocus.Win]::GetForegroundWindow() -eq $target) { Write-Output 'focused'; Log 'focused' }
  else { Write-Output 'raised but not foreground'; Log 'raised but not foreground' }
  $mainWindow = $target
} else {
  Write-Output 'no matching window'
  Log 'no matching window'
}

# ── 切到 DSH 标签页 ─────────────────────────────────────────────────────────────
$tabFound = $false
if (-not $NoTabSearch -and $mainWindow -ne [IntPtr]::Zero -and $TabTitle -ne '') {
  Add-Type -AssemblyName System.Windows.Forms

  if ((Get-WindowTitle $mainWindow) -like "*$TabTitle*") { $tabFound = $true }
  Log ('  title at start: ' + (Get-WindowTitle $mainWindow) + '  matched=' + $tabFound)

  if (-not $tabFound) {
    for ($i = 0; $i -lt $TabSearchTries; $i++) {
      try { [System.Windows.Forms.SendKeys]::SendWait('^{TAB}') } catch { Log ('  SendKeys failed: ' + $_.Exception.Message); break }
      Start-Sleep -Milliseconds 160
      $now = Get-WindowTitle $mainWindow
      if ($i -lt 3) { Log ('  try ' + ($i + 1) + ' -> ' + $now) }
      if ($now -like "*$TabTitle*") { $tabFound = $true; break }
    }
  }

  if ($tabFound) { Write-Output 'tab focused'; Log 'tab focused' }
  else { Write-Output 'tab not found'; Log ('tab not found; final title=' + (Get-WindowTitle $mainWindow)) }
}

# ── 确实没有 DSH 标签时才新起一个 ───────────────────────────────────────────────
if ($OpenUrl -ne '' -and -not $tabFound) {
  try {
    Start-Process $OpenUrl
    Write-Output 'tab opened'
    Log ('tab opened: ' + $OpenUrl)
  } catch {
    Write-Output ('tab open failed: ' + $_.Exception.Message)
    Log ('tab open failed: ' + $_.Exception.Message)
  }
} else {
  Log '  (did not open a url)'
}
