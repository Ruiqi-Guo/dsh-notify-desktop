# 单独验证 Focus-WindowLike：用脚本里真实的类型名 DshNotify.Win
$ErrorActionPreference = 'Continue'
$src = 'D:\Codes\dsh-notify-desktop\assets\dsh-notify.ps1'
$text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)

# 取出脚本里那段真实的 P/Invoke 定义
$m = [regex]::Match($text, "(?s)Add-Type -Namespace DshNotify -Name Win -MemberDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { Write-Output 'FAIL: cannot locate P/Invoke block'; exit 1 }
Add-Type -Namespace DshNotify -Name Win -MemberDefinition $m.Groups[1].Value
Write-Output '1) P/Invoke compiles: OK'

# 只保留函数定义（去掉 param 块与末尾 switch），然后调用 Focus-WindowLike
$body = [regex]::Replace($text, '(?s)\[CmdletBinding\(\)\].*?\r?\n\)\r?\n', '')
$body = [regex]::Replace($body, '(?s)switch \(\$Style\).*$', '')
Invoke-Expression $body
Write-Output '2) functions loaded: OK'

Write-Output ('3) focus by title DeepSeek Harness -> ' + (Focus-WindowLike 'DeepSeek Harness'))
$fg = [DshNotify.Win]::GetForegroundWindow()
$buf = New-Object System.Text.StringBuilder 512
[DshNotify.Win]::GetWindowText($fg, $buf, 512) | Out-Null
Write-Output ('4) foreground now: ' + $buf.ToString())

Write-Output ('5) nonsense title (class fallback) -> ' + (Focus-WindowLike 'zzz-never-exists-zzz'))
$fg2 = [DshNotify.Win]::GetForegroundWindow()
$buf2 = New-Object System.Text.StringBuilder 512
[DshNotify.Win]::GetWindowText($fg2, $buf2, 512) | Out-Null
Write-Output ('6) foreground now: ' + $buf2.ToString())
