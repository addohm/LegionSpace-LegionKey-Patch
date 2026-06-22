<#
  Patch-LegionKey.ps1
  -------------------
  Customises Legion Space's controller "Function Shortcut" behaviour on the Legion Go.

  Edits (all in Legion Space's web UI bundle, all reversible via .bak):

   1) free-legion-L
      Guard rejecting a lone Legion button:
          if((o.includes(1)||o.includes(2)) && o.length===1){ reject }
      ->  o.includes(1)||o.includes(2)  becomes  o.includes(2)
      so a lone Legion L can be assigned (lone Legion R stays reserved; -FreeBoth frees both).

   2) relabel-legion-space-row
      The fixed "Short Press -> Legion Space" row reads "Check quick access shortcuts below"
      when Legion L (key id 1) is bound standalone, else stays "Legion Space".

  IMPORTANT - process handling:
      We do NOT stop the daemon service (DAService / LSDaemon.exe). Stopping it drops the
      controller handshake ("connect controllers" prompt + lost bindings). The JS edits take
      effect by editing the loose file (its new timestamp invalidates the V8 code cache) and
      bouncing only the LegionSpace UI processes, which the daemon relaunches.

  Run from an ELEVATED (Administrator) PowerShell.

  Options:
    -Restore        Roll back every patched file from its .bak.
    -FreeBoth       Free BOTH Legion L and Legion R (default: only L).
    -NoStop         Don't bounce the UI (you reopen Legion Space yourself).
    -InstallTask    Register a SYSTEM scheduled task that reapplies this patch after updates.
    -UninstallTask  Remove that scheduled task.
#>

param(
  [string]$InstallRoot = "C:\Program Files\Lenovo\LegionSpace",
  [switch]$Restore,
  [switch]$FreeBoth,
  [switch]$NoStop,
  [switch]$InstallTask,
  [switch]$UninstallTask,
  [switch]$Task            # internal: quiet mode used by the scheduled task
)

$ErrorActionPreference = 'Stop'
$TaskName  = 'LegionSpace-LegionKeyPatch'
$UIProcs   = @('LegionSpace','LegionSettingMenu','LegionGoQuickSettings','CefViewWing')  # NOT LSDaemon
$ScriptPath = $PSCommandPath

# --- elevation check ---
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Warning "Not elevated. Right-click PowerShell > 'Run as administrator', then re-run."
  return
}
if (-not (Test-Path $InstallRoot)) { throw "Install root not found: $InstallRoot" }

function Say($msg, $color='Gray') { if (-not $Task) { Write-Host $msg -ForegroundColor $color } }

# --- scheduled task install/uninstall ---
if ($UninstallTask) {
  try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green }
  catch { Write-Warning "No scheduled task '$TaskName' to remove (or removal failed): $($_.Exception.Message)" }
  return
}
if ($InstallTask) {
  $a  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`" -Task"
  $t1 = New-ScheduledTaskTrigger -AtLogOn
  $t2 = New-ScheduledTaskTrigger -AtStartup
  $pp = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName $TaskName -Action $a -Trigger $t1,$t2 -Principal $pp -Settings $set -Force | Out-Null
  Write-Host "Installed scheduled task '$TaskName' (runs as SYSTEM at logon + startup; reapplies after updates)." -ForegroundColor Green
  Write-Host "It is idempotent: it does nothing when the patch is already present." -ForegroundColor DarkGray
  return
}

# --- edits ---
$relabelFind    = 'S=h(()=>g.GOS===p.value?w0:f0)'
$relabelReplace = 'S=h(()=>(g.GOS===p.value?w0:f0).map(it=>it.id===2&&Object.values(u.value||{}).some(k=>Array.isArray(k)&&k.length===1&&k[0]===1)?Object.assign({},it,{value:"Check quick access shortcuts below"}):it))'
$Edits = @(
  @{ Name='free-legion-L'; Glob='index-*.js'; Find='o.includes(1)||o.includes(2)';
     Replace=$(if($FreeBoth){'false||o.includes(99)'}else{'o.includes(2)'}) },
  @{ Name='relabel-legion-space-row'; Glob='useShortKey-*.js'; Find=$relabelFind; Replace=$relabelReplace }
)

function Find-EditFile($edit) {
  Get-ChildItem $InstallRoot -Recurse -Filter $edit.Glob -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\HTML\\' } |
    Where-Object { [System.IO.File]::ReadAllText($_.FullName).IndexOf($edit.Find,[System.StringComparison]::Ordinal) -ge 0 } |
    Select-Object -First 1
}
function Bounce-UI {
  $any = $false
  for ($i=0; $i -lt 4; $i++) {
    $procs = @(Get-Process -Name $UIProcs -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { break }
    $any = $true; $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
  }
  if ($any) { Say "  bounced UI (daemon will relaunch it with the patched files)." 'DarkCyan' }
}
function Clear-CacheBestEffort {
  $roots = @("$env:LOCALAPPDATA\Lenovo\LegionSpace","$env:APPDATA\Lenovo\LegionSpace") | Where-Object { Test-Path $_ }
  foreach ($r in $roots) {
    Get-ChildItem $r -Recurse -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -in @('Code Cache','GPUCache','Cache') } |
      ForEach-Object { try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop } catch {} }
  }
}

# --- RESTORE ---
if ($Restore) {
  $baks = Get-ChildItem $InstallRoot -Recurse -Filter '*.bak' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\HTML\\' }
  if (-not $baks) { Write-Host "No .bak backups under $InstallRoot\...\HTML. Nothing to restore." -ForegroundColor Yellow; return }
  foreach ($b in $baks) { $orig = $b.FullName.Substring(0,$b.FullName.Length-4); Copy-Item $b.FullName $orig -Force; Say "  restored: $orig" 'Green' }
  if (-not $NoStop) { Clear-CacheBestEffort; Bounce-UI }
  Write-Host "Restore complete." -ForegroundColor Green
  return
}

# --- figure out pending edits before touching anything ---
$pending = @()
foreach ($e in $Edits) {
  $f = Find-EditFile $e
  if ($f) { $pending += [pscustomobject]@{ Edit=$e; File=$f }; Say "[$($e.Name)] will patch: $($f.Name)" }
  else    { Say "[$($e.Name)] already applied or not present - skip" 'DarkGray' }
}
if ($pending.Count -eq 0) { Say "Nothing to do - all edits already applied." 'Yellow'; return }

# --- apply ---
foreach ($p in $pending) {
  $path = $p.File.FullName; $e = $p.Edit
  $text = [System.IO.File]::ReadAllText($path)
  $bak  = $path + '.bak'
  if (-not (Test-Path $bak)) { Copy-Item $path $bak -Force; Say "  backup: $bak" 'DarkGray' }
  $new = $text.Replace($e.Find, $e.Replace)
  if ($new -eq $text) { Say "  [$($e.Name)] no change produced - skipped" 'Yellow'; continue }
  [System.IO.File]::WriteAllText($path, $new)
  Say "[$($e.Name)] patched $($p.File.Name)" 'Green'
}

# --- reload the UI (NOT the daemon) ---
if (-not $NoStop) { Clear-CacheBestEffort; Bounce-UI }

if (-not $Task) {
  Write-Host "`nDone." -ForegroundColor Green
  Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
  Write-Host "NOTICE - for the remapped Legion key to work right after boot:" -ForegroundColor Yellow
  Write-Host "  Turn OFF 'Boot automatically into Legion Space' in Legion Space settings." -ForegroundColor Yellow
  Write-Host "  Otherwise the GUI opens in the foreground at boot and swallows the first" -ForegroundColor DarkGray
  Write-Host "  press until you dismiss it. The daemon runs either way, so the remap still" -ForegroundColor DarkGray
  Write-Host "  fires once the window isn't grabbing focus." -ForegroundColor DarkGray
  Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
  Write-Host "Tip: run with -InstallTask to auto-reapply this patch after Legion Space updates." -ForegroundColor Cyan
}
