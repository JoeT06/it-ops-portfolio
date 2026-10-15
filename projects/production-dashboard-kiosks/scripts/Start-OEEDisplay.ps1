<#
  Start-OEEDisplay.ps1
  Launches Edge in kiosk mode, auto-logs into Aptean OEE, refreshes every hour,
  re-logs in if the session expires, and relaunches the browser if it closes or hangs.
  Runs at logon via the "OEE Display" scheduled task.

  To pause for maintenance: create an empty file named STOP in C:\OEEDisplay,
  then close Edge (Alt+F4). Delete STOP and reboot to resume.
#>

$ErrorActionPreference = 'Stop'

# ================= CONFIG (edit these) =================
$StartUrl       = 'https://YOUR-TENANT.factorymes.apteancloud.com/mviusers/appframes.jsp'
$DashboardText  = 'Line 1 Dashboard'   # screen the TV must show; script clicks to it if needed
$UserSelector   = 'input[type="text"], input:not([type])'
$PassSelector   = 'input[type="password"]'
$SubmitSelector = 'button[type="submit"], input[type="submit"]'   # falls back to any element labeled "SIGN IN"
$RefreshMinutes = 60
# =======================================================

$BaseDir    = 'C:\OEEDisplay'
$CredFile   = Join-Path $BaseDir 'oee-cred.xml'
$LogFile    = Join-Path $BaseDir 'oee-display.log'
$StopFile   = Join-Path $BaseDir 'STOP'
$ProfileDir = Join-Path $BaseDir 'EdgeProfile'
$DebugPort  = 9222

$BrowserPath = @(
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$script:CdpId = 0

function Write-Log([string]$Message) {
  if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
    Move-Item $LogFile "$LogFile.old" -Force
  }
  "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message" | Add-Content $LogFile
}

# ---------- Credentials (DPAPI, readable only by this user on this PC) ----------
$CredJson = Join-Path $BaseDir 'oee-cred.json'
if (Test-Path $CredJson) {
  # Machine-scope DPAPI (written by Setup-OEETV.ps1 / Set-OEECredential.ps1)
  Add-Type -AssemblyName System.Security
  $c       = Get-Content $CredJson -Raw | ConvertFrom-Json
  $OeeUser = $c.User
  $OeePass = [Text.Encoding]::UTF8.GetString(
    [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($c.Pass), $null, 'LocalMachine'))
} elseif (Test-Path $CredFile) {
  # Older per-user format
  $cred    = Import-Clixml $CredFile
  $OeeUser = $cred.UserName
  $OeePass = $cred.GetNetworkCredential().Password
} else { Write-Log "No saved Aptean login. Run Set-OEECredential.ps1 as admin."; exit 1 }

# ---------- Chrome DevTools Protocol helpers ----------
function Invoke-Cdp {
  param([string]$Method, [hashtable]$Params = @{})
  $targets = Invoke-RestMethod "http://127.0.0.1:$DebugPort/json" -TimeoutSec 5
  $page = $targets | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
  if (-not $page) { throw 'No browser page found' }

  $ws  = New-Object System.Net.WebSockets.ClientWebSocket
  $cts = New-Object System.Threading.CancellationTokenSource 30000
  try {
    $ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $cts.Token).Wait()
    $script:CdpId++
    $msg   = @{ id = $script:CdpId; method = $Method; params = $Params } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $ws.SendAsync([ArraySegment[byte]]$bytes, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()

    $buffer = New-Object byte[] 65536
    while ($true) {
      $ms = New-Object System.IO.MemoryStream
      do {
        $seg = New-Object 'ArraySegment[byte]' -ArgumentList (,$buffer)
        $r = $ws.ReceiveAsync($seg, $cts.Token).Result
        $ms.Write($buffer, 0, $r.Count)
      } while (-not $r.EndOfMessage)
      $resp = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
      $ms.Dispose()
      if ($resp.id -eq $script:CdpId) { return $resp }
    }
  } finally { $ws.Dispose(); $cts.Dispose() }
}

function Invoke-Js([string]$Expression) {
  $r = Invoke-Cdp 'Runtime.evaluate' @{ expression = $Expression; returnByValue = $true }
  return $r.result.result.value
}

function Test-Browser {
  try { Invoke-RestMethod "http://127.0.0.1:$DebugPort/json/version" -TimeoutSec 5 | Out-Null; return $true }
  catch { return $false }
}

function Wait-PageReady([int]$TimeoutSec = 60) {
  $end = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $end) {
    try { if ((Invoke-Js 'document.readyState') -eq 'complete') { Start-Sleep 3; return } } catch {}
    Start-Sleep 2
  }
}

# ---------- Login ----------
$jsUser = $OeeUser | ConvertTo-Json
$jsPass = $OeePass | ConvertTo-Json
$jsUSel = $UserSelector | ConvertTo-Json
$jsPSel = $PassSelector | ConvertTo-Json
$jsBSel = $SubmitSelector | ConvertTo-Json

# Shared helper: searches the page and any same-origin frames (appframes.jsp uses frames)
$FindJs = @"
function allDocs(d, out){ out.push(d);
  var fs = d.querySelectorAll('iframe,frame');
  for (var i=0;i<fs.length;i++){ try{ if(fs[i].contentDocument) allDocs(fs[i].contentDocument,out); }catch(e){} }
  return out; }
function visible(el){ return el && el.getClientRects().length > 0; }
function firstVisible(d, sel){ var l=d.querySelectorAll(sel); for(var i=0;i<l.length;i++){ if(visible(l[i])) return l[i]; } return null; }
function findLogin(){ var ds=allDocs(document,[]);
  for (var i=0;i<ds.length;i++){ var p=firstVisible(ds[i], $jsPSel); if(p) return {d:ds[i], p:p}; }
  return null; }
"@

$CheckJs = "(function(){ $FindJs return findLogin() ? 'login' : 'no-login'; })()"

$LoginJs = @"
(function(){
  $FindJs
  var f = findLogin();
  if (!f) return 'no-login';
  var d = f.d, p = f.p, win = d.defaultView;
  var u = firstVisible(d, $jsUSel);
  var setter = Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, 'value').set;
  function setVal(el, v){ el.focus(); setter.call(el, v);
    el.dispatchEvent(new Event('input', {bubbles:true}));
    el.dispatchEvent(new Event('change', {bubbles:true})); }
  if (u && u !== p) setVal(u, $jsUser);
  setVal(p, $jsPass);
  var b = firstVisible(d, $jsBSel);
  if (!b) {
    var c = d.querySelectorAll('button,a,div,span,td,input[type=button]');
    for (var j=0;j<c.length;j++){
      var t = (c[j].innerText || c[j].value || '').trim().toUpperCase();
      if (t === 'SIGN IN' && visible(c[j])) { b = c[j]; break; }
    }
  }
  if (b) { b.click(); return 'submitted'; }
  ['keydown','keypress','keyup'].forEach(function(k){
    p.dispatchEvent(new win.KeyboardEvent(k, {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true})); });
  if (p.form) p.form.submit();
  return 'submitted';
})()
"@

$jsDash = $DashboardText | ConvertTo-Json

$OnDashJs = "(function(){ $FindJs var ds=allDocs(document,[]); for(var i=0;i<ds.length;i++){ if(ds[i].body && ds[i].body.innerText.indexOf($jsDash) >= 0) return 'yes'; } return 'no'; })()"

# Clicks the deepest visible element whose text is exactly the dashboard name
$GoDashJs = @"
(function(){ $FindJs
  var ds=allDocs(document,[]), hit=null;
  for (var i=0;i<ds.length;i++){ var els=ds[i].querySelectorAll('*');
    for (var j=0;j<els.length;j++){ var t=(els[j].innerText||'').trim();
      if (t === $jsDash && visible(els[j])) hit = els[j]; } }
  if (hit) { hit.click(); return 'clicked'; }
  return 'not-found';
})()
"@

# Clicks Aptean's own refresh icon (keeps the session and current screen)
$RefreshJs = @"
(function(){ $FindJs
  var ds=allDocs(document,[]);
  for (var i=0;i<ds.length;i++){ var els=ds[i].querySelectorAll('[title],[aria-label],[class*="refresh" i],[id*="refresh" i]');
    for (var j=0;j<els.length;j++){ var e=els[j];
      var s=((e.getAttribute('title')||'')+' '+(e.getAttribute('aria-label')||'')+' '+(e.className||'')+' '+(e.id||'')).toLowerCase();
      if (s.indexOf('refresh')>=0 && visible(e)) { e.click(); return 'clicked'; } } }
  return 'none';
})()
"@

# Turns off Aptean alert()/confirm() pop-ups so they can't freeze the page
$NoAlertJs = "(function(){ $FindJs var ds=allDocs(document,[]); for(var i=0;i<ds.length;i++){ try{ var w=ds[i].defaultView; w.alert=function(){}; w.confirm=function(){return true;}; }catch(e){} } return 'ok'; })()"

function Ensure-Dashboard {
  if ((Invoke-Js $OnDashJs) -eq 'yes') { return }
  Write-Log "Not on $DashboardText, trying to open it"
  $r = Invoke-Js $GoDashJs
  Start-Sleep 8
  if ((Invoke-Js $OnDashJs) -eq 'yes') { Write-Log "Opened $DashboardText" }
  else { Write-Log "Could not open $DashboardText ($r)" }
}

function Invoke-Refresh {
  if ((Invoke-Js $RefreshJs) -eq 'clicked') { Write-Log 'Hourly refresh (Aptean refresh button)'; Start-Sleep 10 }
  else {
    Write-Log 'Hourly refresh (full page reload)'
    Invoke-Cdp 'Page.reload' @{ ignoreCache = $true } | Out-Null
    Wait-PageReady
  }
}

function Ensure-LoggedIn {
  for ($i = 1; $i -le 3; $i++) {
    if ((Invoke-Js $LoginJs) -eq 'no-login') { return $true }
    Write-Log "Login form found, submitted credentials (attempt $i)"
    Start-Sleep 15
    Wait-PageReady
    if ((Invoke-Js $CheckJs) -eq 'no-login') {
      Write-Log 'Login successful'
      return $true
    }
  }
  Write-Log 'Login failed after 3 attempts'
  return $false
}

# ---------- Browser launch ----------
function Wait-Network {
  $hostName = ([Uri]$StartUrl).Host
  for ($i = 0; $i -lt 60; $i++) {
    try { [System.Net.Dns]::GetHostAddresses($hostName) | Out-Null; return } catch { Start-Sleep 5 }
  }
  Write-Log "Network/DNS not ready for $hostName after 5 minutes, continuing anyway"
}

function Start-Display {
  Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 3
  Wait-Network

  $edgeArgs = @(
    "--kiosk", $StartUrl,
    "--edge-kiosk-type=fullscreen",
    "--remote-debugging-port=$DebugPort",
    "--user-data-dir=`"$ProfileDir`"",
    "--no-first-run",
    "--noerrdialogs",
    "--disable-session-crashed-bubble",
    "--overscroll-history-navigation=0"
  )
  Start-Process $BrowserPath -ArgumentList $edgeArgs
  Write-Log 'Edge launched'

  for ($i = 0; $i -lt 30 -and -not (Test-Browser); $i++) { Start-Sleep 2 }
  Wait-PageReady
  try {
    Invoke-Js $NoAlertJs | Out-Null
    if (Ensure-LoggedIn) { Ensure-Dashboard }
  } catch { Write-Log "Startup check error: $($_.Exception.Message)" }
}

# ---------- Main loop ----------
if (-not $BrowserPath) { Write-Log 'Edge not found'; exit 1 }
if (Test-Path $StopFile) { Write-Log 'STOP file present, exiting'; exit 0 }

Write-Log '=== OEE Display starting ==='
Start-Display
$lastRefresh = Get-Date
$failCount   = 0

while ($true) {
  Start-Sleep 60
  if (Test-Path $StopFile) { Write-Log 'STOP file found, exiting'; exit 0 }
  try {
    if (-not (Test-Browser)) {
      Write-Log 'Browser not responding, relaunching'
      Start-Display
      $lastRefresh = Get-Date
      continue
    }
    Invoke-Js $NoAlertJs | Out-Null
    if (((Get-Date) - $lastRefresh).TotalMinutes -ge $RefreshMinutes) {
      Invoke-Refresh
      $lastRefresh = Get-Date
      Invoke-Js $NoAlertJs | Out-Null
    }
    # Every minute: re-login if the session expired, and return to the dashboard if it moved
    if (Ensure-LoggedIn) { Ensure-Dashboard }
    $failCount = 0
  } catch {
    $failCount++
    Write-Log "Error ($failCount in a row): $($_.Exception.Message)"
    if ($failCount -ge 3) {
      Write-Log 'Page not responding (possible pop-up), relaunching Edge'
      Start-Display
      $lastRefresh = Get-Date
      $failCount = 0
    }
  }
}
