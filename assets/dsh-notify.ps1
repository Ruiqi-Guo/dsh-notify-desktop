# dsh-notify.ps1 —— DSH「干完活了」右下角提醒卡片
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File dsh-notify.ps1 `
#       [-Title 标题] [-Session 会话名] [-Message 正文] [-Seconds 0] `
#       [-Style popup|toast|auto] [-Accent '#F7630C'] [-OnClick <URL 或 exe>] [-Tag <标签>]
#
# 样式：
#   popup（默认）自绘橙色右下角置顶卡片 —— 颜色可控、不抢焦点、**默认不自动消失**
#   toast        Windows 系统 Toast —— 外观由系统渲染、改不了颜色、会自动消失
#   auto         先试 Toast，失败退回卡片
#
# 关键参数：
#   -Session  会话名，显示在标题下面一行，用来区分"是哪个 session 跑完了"
#   -Seconds  0（默认）= 不自动消失，点一下才关；>0 = 到时自动关
#   -OnClick  点击卡片时执行的 URL 或可执行文件（例如把浏览器拉到前台）
#   -Tag      去重标识：多张卡片会**竖向堆叠**，不会互相盖住
#
# 要点：
#   1. 卡片带 WS_EX_NOACTIVATE + SWP_NOACTIVATE，**不会抢走你正在打字的焦点**。
#   2. 无论哪条路失败都必须 exit 0 —— 它挂在 DSH 的钩子上，
#      退出码 2 会被 hook 桥接解释为「阻塞」并强制模型再跑一轮。
#   3. 必须带 UTF-8 BOM 保存：PowerShell 5.1 读无 BOM 的 UTF-8 中文会乱码。
#   4. 卡片会阻塞到关闭，所以从钩子调用要经 dsh-notify.cmd（用 start 分离）。

[CmdletBinding()]
param(
  [string]$Title = 'DSH 已完成',
  [string]$Session = '',
  [string]$Message = 'Agent 结束了本轮工作，可以回来看结果了',
  [int]$Seconds = 0,
  [ValidateSet('popup', 'toast', 'auto')]
  [string]$Style = 'popup',
  [string]$Accent = '#F7630C',
  [string]$OnClick = '',
  [string]$OnClickUrl = '',
  [string]$Tag = '',
  [string]$FromJson = ''
)

$ErrorActionPreference = 'Stop'

# -FromJson：从 UTF-8 JSON 读卡片内容。
# 为什么需要它：内容要经过 cmd.exe 才能拉出可见窗口，而 cmd 按 OEM 代码页解释 argv，
# 中文会话名会变乱码。所以插件把内容写进 JSON，命令行上只留纯 ASCII 的路径。
if ($FromJson -and (Test-Path $FromJson)) {
  try {
    $json = [System.IO.File]::ReadAllText($FromJson, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($json.title) { $Title = [string]$json.title }
    if ($json.session) { $Session = [string]$json.session }
    if ($json.message) { $Message = [string]$json.message }
    if ($json.tag) { $Tag = [string]$json.tag }
    if ($json.accent) { $Accent = [string]$json.accent }
    if ($json.onClick) { $OnClick = [string]$json.onClick }
    if ($json.onClickUrl) { $OnClickUrl = [string]$json.onClickUrl }
    if ($null -ne $json.seconds) { $Seconds = [int]$json.seconds }
  } catch { }
  Remove-Item $FromJson -Force -ErrorAction SilentlyContinue
}

function Escape-Xml([string]$s) {
  return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Show-Toast {
  try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    $line2 = $Message
    if ($Session) { $line2 = "$Session - $Message" }
    $xmlStr = @"
<toast scenario="reminder">
  <visual>
    <binding template="ToastGeneric">
      <text>$(Escape-Xml $Title)</text>
      <text>$(Escape-Xml $line2)</text>
    </binding>
  </visual>
</toast>
"@
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($xmlStr)
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
    return $true
  } catch {
    return $false
  }
}

function Show-Popup {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ('DshNotify.Win' -as [type])) {
      Add-Type -Namespace DshNotify -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int i);
[DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr h, int i, int v);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
    }

    $hex = $Accent.TrimStart('#')
    $accentColor = [System.Drawing.Color]::FromArgb(
      [Convert]::ToInt32($hex.Substring(0, 2), 16),
      [Convert]::ToInt32($hex.Substring(2, 2), 16),
      [Convert]::ToInt32($hex.Substring(4, 2), 16))
    $barColor = [System.Drawing.Color]::FromArgb(255, 214, 150)
    $dimColor = [System.Drawing.Color]::FromArgb(255, 240, 222)

    # 会话名占一行，卡片高度随之调整
    $hasSession = [bool]$Session
    $cardH = 104
    if ($hasSession) { $cardH = 126 }

    # 统计已有的同族卡片，决定本卡排第几行（竖向堆叠，互不遮挡）
    $marker = 'DSH-NOTIFY'
    $found = New-Object System.Collections.Generic.List[object]
    $cb = [DshNotify.Win+EnumProc]{
      param($h, $x)
      $t = New-Object System.Text.StringBuilder 256
      [DshNotify.Win]::GetWindowText($h, $t, 256) | Out-Null
      if ([DshNotify.Win]::IsWindowVisible($h) -and $t.ToString().StartsWith($marker)) { [void]$found.Add($h) }
      return $true
    }
    [DshNotify.Win]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.BackColor = $accentColor
    $form.Size = New-Object System.Drawing.Size(380, $cardH)
    if ($Tag) { $form.Text = "$marker $Tag" } else { $form.Text = $marker }

    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $gap = 10
    $x = $area.Right - 400
    # 跨进程槽位预留：三张卡片可能在同一毫秒内弹出，此时「数已有窗口」和「查位置占用」
    # 都会一起落空（都还没创建窗口）。所以用命名互斥体 + 槽位文件做真正的原子预留，
    # 并在预留时顺手清掉已退出卡片占的槽。
    $slotDir = Join-Path $env:TEMP 'dsh-notify-slots'
    New-Item -ItemType Directory -Force -Path $slotDir | Out-Null
    $slotFile = Join-Path $slotDir "$PID.slot"
    $slot = 0
    try {
      $mtx = New-Object System.Threading.Mutex($false, 'Global\dsh-notify-slots')
      [void]$mtx.WaitOne(4000)
      $used = New-Object System.Collections.Generic.List[int]
      foreach ($sf in Get-ChildItem $slotDir -Filter '*.slot' -ErrorAction SilentlyContinue) {
        $owner = 0
        if (-not [int]::TryParse($sf.BaseName, [ref]$owner)) { Remove-Item $sf.FullName -Force -ErrorAction SilentlyContinue; continue }
        if ($owner -eq $PID) { continue }
        if (Get-Process -Id $owner -ErrorAction SilentlyContinue) {
          $v = -1
          if ([int]::TryParse((Get-Content $sf.FullName -Raw -ErrorAction SilentlyContinue), [ref]$v)) { [void]$used.Add($v) }
        } else {
          Remove-Item $sf.FullName -Force -ErrorAction SilentlyContinue
        }
      }
      while ($used -contains $slot) { $slot++ }
      Set-Content -Path $slotFile -Value $slot -Encoding ASCII
      [void]$mtx.ReleaseMutex()
    } catch { }

    $y = $area.Bottom - $cardH - 12 - ($slot * ($cardH + $gap))
    if ($y -lt $area.Top + 10) { $y = $area.Top + 10 }

    # 并发竞态兜底：多张卡片几乎同时弹出时，每张都会把「已有数量」读成 0、算出同一个 Y。
    # 所以再按「该位置是否已被占用」往上挪，保证永不重叠。
    $occupied = New-Object System.Collections.Generic.List[int]
    $cbOcc = [DshNotify.Win+EnumProc]{
      param($h, $x)
      $t = New-Object System.Text.StringBuilder 256
      [DshNotify.Win]::GetWindowText($h, $t, 256) | Out-Null
      if ([DshNotify.Win]::IsWindowVisible($h) -and $t.ToString().StartsWith($marker)) {
        $r = New-Object DshNotify.Win+RECT
        [DshNotify.Win]::GetWindowRect($h, [ref]$r) | Out-Null
        [void]$occupied.Add($r.Top)
      }
      return $true
    }
    [DshNotify.Win]::EnumWindows($cbOcc, [IntPtr]::Zero) | Out-Null
    $guard = 0
    while (($occupied -contains $y) -and ($y -gt ($area.Top + 10)) -and ($guard -lt 30)) {
      $y -= ($cardH + $gap)
      $guard++
    }
    if ($y -lt $area.Top + 10) { $y = $area.Top + 10 }
    $form.Location = New-Object System.Drawing.Point($x, $y)

    # 卡片关掉就释放槽位，后面的卡片能补上
    $form.Add_Closed({ Remove-Item $slotFile -Force -ErrorAction SilentlyContinue }.GetNewClosure())

    $bar = New-Object System.Windows.Forms.Panel
    $bar.BackColor = $barColor
    $bar.Location = New-Object System.Drawing.Point(0, 0)
    $bar.Size = New-Object System.Drawing.Size(6, $cardH)
    $form.Controls.Add($bar)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = $Title
    $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.BackColor = [System.Drawing.Color]::Transparent
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 12)
    $lblTitle.Size = New-Object System.Drawing.Size(318, 26)
    $form.Controls.Add($lblTitle)

    # 右上角关闭键：**只关卡片，不跳转** —— 跳转只由点卡片主体触发。
    # WinForms 的 Label 点击不会冒泡到父窗体，所以这里给它单独的处理器就够了。
    $lblClose = New-Object System.Windows.Forms.Label
    $lblClose.Text = [char]0x2715              # ✕
    $lblClose.ForeColor = [System.Drawing.Color]::FromArgb(255, 236, 220)
    $lblClose.BackColor = [System.Drawing.Color]::Transparent
    $lblClose.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $lblClose.TextAlign = 'MiddleCenter'
    $lblClose.Cursor = 'Hand'
    $lblClose.Location = New-Object System.Drawing.Point(344, 6)
    $lblClose.Size = New-Object System.Drawing.Size(28, 26)
    $lblClose.Add_Click({ $form.Close() }.GetNewClosure())
    $enterHandler = { $lblClose.BackColor = [System.Drawing.Color]::FromArgb(90, 255, 255, 255) }.GetNewClosure()
    $lblClose.Add_MouseEnter($enterHandler)
    $leaveHandler = { $lblClose.BackColor = [System.Drawing.Color]::Transparent }.GetNewClosure()
    $lblClose.Add_MouseLeave($leaveHandler)
    $form.Controls.Add($lblClose)

    $nextY = 40
    if ($hasSession) {
      $lblSession = New-Object System.Windows.Forms.Label
      $lblSession.Text = "会话： $Session"
      $lblSession.ForeColor = [System.Drawing.Color]::White
      $lblSession.BackColor = [System.Drawing.Color]::Transparent
      $lblSession.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
      $lblSession.Location = New-Object System.Drawing.Point(20, $nextY)
      $lblSession.Size = New-Object System.Drawing.Size(346, 22)
      $form.Controls.Add($lblSession)
      $nextY += 24
    }

    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Text = $Message
    $lblMsg.ForeColor = $dimColor
    $lblMsg.BackColor = [System.Drawing.Color]::Transparent
    $lblMsg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $lblMsg.Location = New-Object System.Drawing.Point(20, $nextY)
    $lblMsg.Size = New-Object System.Drawing.Size(346, ($cardH - $nextY - 8))
    $form.Controls.Add($lblMsg)

    # 点一下：先执行 -OnClick，再关卡片
    $onClickCmd = $OnClick
    $onClickUrl = $OnClickUrl
    $clickHandler = {
      if ($onClickUrl) {
        try { Invoke-WebRequest -Uri $onClickUrl -TimeoutSec 3 -UseBasicParsing | Out-Null } catch { }
      }
      if ($onClickCmd) {
        try { Start-Process $onClickCmd } catch { }
      }
      $form.Close()
    }.GetNewClosure()

    foreach ($c in @($form, $lblTitle, $lblMsg, $bar)) { $c.Add_Click($clickHandler) }
    if ($hasSession) { $lblSession.Add_Click($clickHandler) }

    # 只有 -Seconds > 0 才自动消失；默认 0 = 一直留着，点一下才关
    if ($Seconds -gt 0) {
      $timer = New-Object System.Windows.Forms.Timer
      $timer.Interval = $Seconds * 1000
      $timer.Add_Tick({ $timer.Stop(); $form.Close() })
      $timer.Start()
    }

    # 这段只是锦上添花（不抢焦点 + 强制显示），**出错绝不能影响卡片本身**：
    # 早先它在 $ErrorActionPreference='Stop' 下抛异常，窗口就一直不可见，而消息循环照跑 ——
    # 表现为「进程活着但屏幕上什么都没有」，排查成本极高。
    $form.Add_Shown({
      try {
        $ex = [DshNotify.Win]::GetWindowLong($form.Handle, -20)
        [void][DshNotify.Win]::SetWindowLong($form.Handle, -20, $ex -bor 0x08000000)   # WS_EX_NOACTIVATE
        [void][DshNotify.Win]::SetWindowPos($form.Handle, [IntPtr](-1), $form.Location.X, $form.Location.Y, $form.Width, $form.Height, 0x0010 -bor 0x0040)  # SWP_NOACTIVATE|SWP_SHOWWINDOW
      } catch {
        Add-Content -Path (Join-Path $env:TEMP 'dsh-notify-error.log') -Value ('[shown-handler] ' + $_.Exception.Message) -Encoding UTF8
      }
    })

    [void][System.Windows.Forms.Application]::Run($form)
    return $true
  } catch {
    # 钩子调用的脚本出错必须留痕，否则表现就是"什么都没发生"
    try {
      $log = Join-Path $env:TEMP 'dsh-notify-error.log'
      Add-Content -Path $log -Value ("[{0}] {1}`r`n{2}`r`n" -f (Get-Date).ToString('s'), $_.Exception.Message, $_.ScriptStackTrace) -Encoding UTF8
    } catch { }
    return $false
  }
}

switch ($Style) {
  'toast' { [void](Show-Toast) }
  'auto'  { if (-not (Show-Toast)) { [void](Show-Popup) } }
  default { [void](Show-Popup) }
}

# 挂在钩子上，必须永远成功退出
exit 0
