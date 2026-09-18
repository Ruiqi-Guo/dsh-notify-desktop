# 给卡片脚本补「聚焦浏览器」能力：按标题匹配 + 按浏览器窗口类兜底
$ErrorActionPreference = 'Stop'
$ps1 = 'D:\Codes\dsh-notify-desktop\assets\dsh-notify.ps1'
$c = [System.IO.File]::ReadAllText($ps1, [System.Text.Encoding]::UTF8)
$nl = "`n"
if ($c -match "`r`n") { $nl = "`r`n" }

Write-Output '################ 1) Focus-WindowLike 加按窗口类兜底 ################'
$a = @'
  [void][DshNotify.Win]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
  if ($found.Count -eq 0) { return $false }
  $target = $found[0]
'@
$b = @'
  [void][DshNotify.Win]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null

  # 兜底：窗口标题只反映「当前活动标签」。如果用户此刻不在 DSH 标签上，
  # 按标题就找不到 —— 这时退化为激活任意一个 Chrome/Edge 主窗口。
  # 会话本身已由浏览器半边切好，用户切回 DSH 标签就能看到。
  if ($found.Count -eq 0) {
    $cbBrowser = [DshNotify.Win+EnumProc]{
      param($h, $x)
      if (-not [DshNotify.Win]::IsWindowVisible($h)) { return $true }
      $cls = New-Object System.Text.StringBuilder 128
      [DshNotify.Win]::GetClassName($h, $cls, 128) | Out-Null
      if ($cls.ToString() -like 'Chrome_WidgetWin*') { [void]$found.Add($h) }
      return $true
    }
    [void][DshNotify.Win]::EnumWindows($cbBrowser, [IntPtr]::Zero) | Out-Null
  }

  if ($found.Count -eq 0) { return $false }
  $target = $found[0]
'@
$b = $b.Replace("`r`n", $nl)
$before = $c
$c = $c.Replace($a, $b)
if ($c -ne $before) { Write-Output '  兜底逻辑: OK' } else { Write-Output '  兜底逻辑: MISS' }

Write-Output '################ 2) P/Invoke 补 GetClassName ################'
$a2 = '[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, System.IntPtr pid);'
$b2 = $a2 + $nl + '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);'
$before = $c
$c = $c.Replace($a2, $b2)
if ($c -ne $before) { Write-Output '  GetClassName: OK' } else { Write-Output '  GetClassName: MISS' }

[System.IO.File]::WriteAllText($ps1, $c, (New-Object System.Text.UTF8Encoding($true)))
$err = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ps1, [ref]$null, [ref]$err)
if ($err) { Write-Output ("  解析错误 " + $err.Count + ": " + $err[0].Message) } else { Write-Output '  解析错误: 0 OK' }
Copy-Item $ps1 '%USERPROFILE%\.dsh\tools\dsh-notify.ps1' -Force

Write-Output ''
Write-Output '################ 3) 测试（用脚本里真实的类型名 DshNotify.Win） ################'
$t = @'
$ErrorActionPreference = 'Continue'
$src = [System.IO.File]::ReadAllText('D:\Codes\dsh-notify-desktop\assets\dsh-notify.ps1', [System.Text.Encoding]::UTF8)
$body = [regex]::Replace($src, '(?s)\[CmdletBinding\(\)\].*?\r?\n\)\r?\n', '')
$body = [regex]::Replace($body, '(?s)switch \(\$Style\).*$', '')
Invoke-Expression $body
$m = [regex]::Match($src, "(?s)Add-Type -Namespace DshNotify -Name Win -MemberDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { Write-Output '  FAIL 找不到 P/Invoke 段'; exit 1 }
Add-Type -Namespace DshNotify -Name Win -MemberDefinition $m.Groups[1].Value
Write-Output '  1) P/Invoke 编译: OK'
Write-Output ('  2) Focus-WindowLike DeepSeek Harness -> ' + (Focus-WindowLike 'DeepSeek Harness'))
Write-Output ('  3) Focus-WindowLike 不存在的串(走兜底) -> ' + (Focus-WindowLike 'zzz-never-exists-zzz'))
$fg = [DshNotify.Win]::GetForegroundWindow()
$buf = New-Object System.Text.StringBuilder 512
[DshNotify.Win]::GetWindowText($fg, $buf, 512) | Out-Null
Write-Output ('  4) 当前前台窗口: ' + $buf.ToString())
'@
Set-Content -Path "$env:TEMP\_focusfn3.ps1" -Value $t -Encoding UTF8
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\_focusfn3.ps1" 2>&1 | ForEach-Object { "  $_" }
Write-Output ("  exit=" + $LASTEXITCODE)
