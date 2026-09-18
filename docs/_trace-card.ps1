# 给卡片脚本的临时副本注入打点，定位它到底停在哪一步
$ErrorActionPreference = 'Stop'
$src = 'D:\Codes\dsh-notify-desktop\assets\dsh-notify.ps1'
$tmp = Join-Path $env:TEMP '_card-traced.ps1'
$trace = Join-Path $env:TEMP '_card-trace.log'
Remove-Item $trace -Force -ErrorAction SilentlyContinue

$lines = [System.IO.File]::ReadAllLines($src, [System.Text.Encoding]::UTF8)
$out = New-Object System.Collections.Generic.List[string]

# 顶部插入 T 函数
$out.Add("`$script:TRACE = '$trace'")
$out.Add('function T([string]$m) { try { Add-Content -Path $script:TRACE -Value ((Get-Date).ToString("HH:mm:ss.fff") + " " + $m) -Encoding UTF8 } catch { } }')
foreach ($l in $lines) {
  if ($l -match '^\s*\$ErrorActionPreference = ') { $out.Add($l); $out.Add("T 'boot'"); continue }
  if ($l -match '^function Show-Popup') { $out.Add($l); $out.Add("  T 'popup-enter'"); continue }
  if ($l -match '\[void\]\[System\.Windows\.Forms\.Application\]::Run\(\$form\)') {
    $out.Add("    T 'before-run'")
    $out.Add($l)
    $out.Add("    T 'after-run'")
    continue
  }
  if ($l -match '^\s*\} catch \{$' -and $script:lastWasPopup) { $out.Add("    T ('catch: ' + `$_.Exception.Message)"); $out.Add($l); continue }
  if ($l -match '^\s*switch \(\$Style\)') { $out.Add("T ('before-switch style=' + `$Style)"); $out.Add($l); continue }
  if ($l -match "'popup' \{ \[void\]\(Show-Popup\) \}") { $out.Add("  'popup' { T 'branch-popup'; [void](Show-Popup) }"); continue }
  if ($l -match '^\s*default \{ \[void\]\(Show-Popup\) \}') { $out.Add("  default { T 'branch-default'; [void](Show-Popup) }"); continue }
  if ($l -match '\$hex = \$Accent\.TrimStart') { $out.Add("    T 'after-addtype'"); $out.Add($l); continue }
  if ($l -match 'Add-Type -Namespace DshNotify -Name Win') { $out.Add("    T 'before-addtype'"); $out.Add($l); continue }
  $out.Add($l)
}
[System.IO.File]::WriteAllText($tmp, ($out -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

$err = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$err)
Write-Output ("  traced copy parse errors: " + $(if ($err) { $err.Count } else { 0 }))
Copy-Item $tmp (Join-Path $env:TEMP '_card-traced-run.ps1') -Force

$json = Join-Path $env:TEMP '_trace-card.json'
[System.IO.File]::WriteAllText($json, '{"title":"trace","session":"trace","message":"trace","tag":"trace","seconds":8}', (New-Object System.Text.UTF8Encoding($false)))
Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"", '-FromJson', "`"$json`"" -WindowStyle Hidden
Start-Sleep -Seconds 6
Write-Output '  --- trace ---'
if (Test-Path $trace) {
  [System.IO.File]::ReadAllText($trace, [System.Text.Encoding]::UTF8) -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Output ("    " + $_) }
} else { Write-Output '    (no trace file at all - script never reached the top)' }
