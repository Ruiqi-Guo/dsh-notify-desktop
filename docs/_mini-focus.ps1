# 最小化定位：聚焦脚本到底哪一步炸
$ErrorActionPreference = 'Continue'
Write-Output 'step1: start'

Add-Type -Namespace Mini -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr l);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, System.IntPtr pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@
Write-Output 'step2: add-type ok'

$byTitle = New-Object System.Collections.Generic.List[System.IntPtr]
$cb = [Mini.Win+EnumProc]{
  param($h, $x)
  if (-not [Mini.Win]::IsWindowVisible($h)) { return $true }
  $t = New-Object System.Text.StringBuilder 512
  [Mini.Win]::GetWindowText($h, $t, 512) | Out-Null
  $text = $t.ToString()
  if ($text -eq '') { return $true }
  if ($text -like '*Chrome*') { [void]$byTitle.Add($h) }
  return $true
}
Write-Output 'step3: callback defined'
[void][Mini.Win]::EnumWindows($cb, [IntPtr]::Zero)
Write-Output ('step4: enumerated, matched ' + $byTitle.Count)

if ($byTitle.Count -gt 0) {
  $target = $byTitle[0]
  $fg = [Mini.Win]::GetForegroundWindow()
  $tFg = [Mini.Win]::GetWindowThreadProcessId($fg, [IntPtr]::Zero)
  $tMe = [Mini.Win]::GetCurrentThreadId()
  Write-Output ('step5: target=' + $target + ' fgThread=' + $tFg + ' me=' + $tMe)
  [void][Mini.Win]::AttachThreadInput($tMe, $tFg, $true)
  [void][Mini.Win]::ShowWindow($target, 9)
  [void][Mini.Win]::BringWindowToTop($target)
  [void][Mini.Win]::SetForegroundWindow($target)
  [void][Mini.Win]::AttachThreadInput($tMe, $tFg, $false)
  $now = [Mini.Win]::GetForegroundWindow()
  Write-Output ('step6: focused=' + ($now -eq $target))
  $buf = New-Object System.Text.StringBuilder 512
  [Mini.Win]::GetWindowText($now, $buf, 512) | Out-Null
  Write-Output ('step7: foreground=' + $buf.ToString())
} else {
  Write-Output 'step5: no match'
}
Write-Output 'done'
