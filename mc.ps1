# language: PowerShell 7, file: gb_otp.ps1, target: Windows 11
# ============================================================================
# GOT-BEAMED — Gmail OTP runner (attach mode)
#
#   Drive your REAL Chrome, opened with a debug port.
#   No profile cloning. No cookie copying. Your real Gmails, already logged in.
#
#   before first run (one time):
#     1. fully close Chrome (every window)
#     2. launch it like this:
#        & "C:\Program Files\Google\Chrome\Application\chrome.exe" `
#            --remote-debugging-port=9222 `
#            --user-data-dir="$env:LOCALAPPDATA\Google\Chrome\User Data"
#     3. log into the Gmails you want (they persist from your normal session)
#     4. run this script
#
#   flow per gmail:
#     POST /secure {email} -> statusUrl / submitUrl / sentTo
#     route sentTo -> the gmail tab holding it
#     wait awaiting_otp -> wait for the code mail -> scrape -> POST submitUrl
#     poll statusUrl until completed
# ============================================================================

param(
    [string]$EmailFile,                    # optional — else uses every gmail found in open tabs
    [int]$DebugPort      = 9222,

    [int]$AwaitOtpSecs   = 90,             # wait for status=awaiting_otp
    [int]$MailArriveSecs = 300,            # wait for the code mail to land
    [int]$Interval       = 4,              # poll cadence
    [int]$BetweenEmails  = 2,

    [string]$ForbidFile = "forbidden.txt",
    [string]$DumpDir    = ".\gb_dumps",

    [switch]$UseApiKeyHeader,
    [switch]$OpenMissingGmailTabs          # open a tab for any gmail in the file that isn't already open
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# config — put your key here
# ============================================================================
$ApiKey = 'ek_wpdh3ld6Iosnj_jJalowEe1xiRTqETNoJ6P9OgM3Bq0'
$Base   = 'https://got-beamed.lol/api/v1'
$Root   = 'https://got-beamed.lol'

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw 'set $ApiKey at the top of this script'
}

$Headers = @{ 'Content-Type' = 'application/json' }
if ($UseApiKeyHeader) { $Headers['X-API-Key'] = $ApiKey } else { $Headers['Authorization'] = "Bearer $ApiKey" }

if (-not (Test-Path $DumpDir)) { New-Item -ItemType Directory -Path $DumpDir | Out-Null }

function Trace-Url([string]$Label, [string]$Url) {
    if ($VerbosePreference -ne 'SilentlyContinue') { Write-Verbose ("    {0}: {1}" -f $Label, $Url) }
}
function Write-TextNoBom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# ============================================================================
# attach to a Chrome already running with --remote-debugging-port
# ============================================================================
function Get-DebugTabs {
    try {
        return Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json" -TimeoutSec 4
    } catch {
        return $null
    }
}

function Assert-ChromeAttached {
    $tabs = Get-DebugTabs
    if ($null -eq $tabs) {
        $chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        if (-not (Test-Path $chrome)) { $chrome = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" }
        $udd = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
        Write-Host ""
        Write-Host "[!] no chrome on debug port $DebugPort" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    1. close every chrome window" -ForegroundColor Yellow
        Write-Host "    2. run:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "       & `"$chrome`" ``" -ForegroundColor Cyan
        Write-Host "           --remote-debugging-port=$DebugPort ``" -ForegroundColor Cyan
        Write-Host "           --user-data-dir=`"$udd`"" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "    3. log into your gmails" -ForegroundColor Yellow
        Write-Host "    4. rerun this script" -ForegroundColor Yellow
        Write-Host ""
        throw "chrome not attached on $DebugPort"
    }
    return $tabs
}

function Get-GmailTabs {
    $tabs = Get-DebugTabs
    $gm = $tabs | Where-Object { $_.url -match 'mail\.google\.com' -and $_.type -eq 'page' }
    $out = @()
    foreach ($t in $gm) {
        $chip = Get-TabAccountChip -WsUrl $t.webSocketDebuggerUrl
        $out += [pscustomobject]@{
            TargetId = $t.id
            WsUrl    = $t.webSocketDebuggerUrl
            Url      = $t.url
            Chip     = $chip
        }
    }
    return $out
}

function Get-TabAccountChip {
    param([string]$WsUrl)
    try {
        $text = Read-PageText -WsUrl $WsUrl
        $m = [regex]::Match($text, '[A-Za-z0-9._%+\-]+@(?:gmail\.com|googlemail\.com)')
        if ($m.Success) { return $m.Value }
        $m2 = [regex]::Match($text, '[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}')
        if ($m2.Success) { return $m2.Value }
    } catch { }
    return $null
}

function Open-GmailTab {
    param([string]$Address)
    $url = "https://mail.google.com/mail/u/0/"
    try {
        $new = Invoke-RestMethod -Method Put -Uri "http://127.0.0.1:$DebugPort/json/new?$([uri]::EscapeDataString($url))" -TimeoutSec 5
        Start-Sleep -Seconds 5
        return $new
    } catch {
        Write-Host "    [!] could not open tab: $($_.Exception.Message)"
        return $null
    }
}

# ============================================================================
# CDP page read (unwraps the envelope)
# ============================================================================
function Read-PageText {
    param([string]$WsUrl)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ct = [System.Threading.CancellationToken]::None
    $ws.ConnectAsync([Uri]$WsUrl, $ct).Wait()

    $msg = @{ id = 1; method = 'Runtime.evaluate'; params = @{ expression = 'document.body.innerText'; returnByValue = $true } } | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()

    $buf = New-Object byte[] 1048576
    $out = New-Object Text.StringBuilder
    do {
        $rseg = New-Object System.ArraySegment[byte] -ArgumentList @(,$buf)
        $res = $ws.ReceiveAsync($rseg, $ct).Result
        [void]$out.Append([Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
    } while (-not $res.EndOfMessage)
    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $ct).Wait()

    $raw = $out.ToString()
    try {
        $env = $raw | ConvertFrom-Json
        if ($env.result -and $env.result.result -and ($env.result.result.PSObject.Properties.Name -contains 'value')) {
            return [string]$env.result.result.value
        }
    } catch { }
    return $raw
}

function Refresh-Tab {
    param([object]$Tab)
    try {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ct = [System.Threading.CancellationToken]::None
        $ws.ConnectAsync([Uri]$Tab.WsUrl, $ct).Wait()
        $msg = @{ id = 2; method = 'Page.reload'; params = @{ ignoreCache = $true } } | ConvertTo-Json -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        $seg = New-Object System.ArraySegment[byte] -ArgumentList @(,$bytes)
        $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
        Start-Sleep -Milliseconds 200
        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $ct).Wait()
    } catch {
        Write-Verbose "    refresh failed on $($Tab.Chip): $($_.Exception.Message)"
    }
}

# ============================================================================
# locale-aware OTP extraction
# ============================================================================
$script:DigitMap = @{}
0x0660..0x0669 | ForEach-Object { $script:DigitMap[[char]$_] = [string]($_ - 0x0660) }
0x06F0..0x06F9 | ForEach-Object { $script:DigitMap[[char]$_] = [string]($_ - 0x06F0) }
0x0966..0x096F | ForEach-Object { $script:DigitMap[[char]$_] = [string]($_ - 0x0966) }
0x09E6..0x09EF | ForEach-Object { $script:DigitMap[[char]$_] = [string]($_ - 0x09E6) }
0x0A66..0x0A6F | ForEach-Object { $script:DigitMap[[char]$_] = [string]($_ - 0x0A66) }
0x0AE6..0x0AEF | ForEach-Object { $script:DigitMap[[char]$_] = [string]($_ - 0x0AE6) }
0x0E50..0x0E59 | ForEach-Object { $script:DigitMap[[char]$_] = [string]($_ - 0x0E50) }
0xFF10..0xFF19 | ForEach-Object { $script:DigitMap[[char]$_] = [string]($_ - 0xFF10) }

function Normalize-Digits([string]$s) {
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ($script:DigitMap.ContainsKey($ch)) { [void]$sb.Append($script:DigitMap[$ch]) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

$OtpKeywords = @(
    'code','otp','verification','verify','passcode','pin','security',
    'código','codigo','codi','kode','kod','密码','驗證碼','验证码','コード','認証',
    'رمز','الرمز','كود','कोड','सत्यापन','કોડ','কোড','รหัส','mã'
) -join '|'

function Extract-Otp([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $n = Normalize-Digits $text
    $n = $n -replace '[\u00A0\u202F\u2007\u2060]', ' '
    $n = $n -replace '[\u2010-\u2015\u2212]', '-'

    $kw = [regex]"(?is)(?:$OtpKeywords)[^\d]{0,40}?(\d[\d \-]{4,10}\d)"
    $m = $kw.Match($n)
    if ($m.Success) {
        $cand = ($m.Groups[1].Value -replace '[^\d]','')
        if ($cand.Length -eq 6) { return $cand }
        if ($cand.Length -ge 4 -and $cand.Length -le 8) { return $cand }
    }
    foreach ($mm in [regex]::Matches($n, '(?<!\d)(\d{6})(?!\d)')) { return $mm.Groups[1].Value }
    foreach ($mm in [regex]::Matches($n, '(?<!\d)(\d{3})[ \-](\d{3})(?!\d)')) {
        return $mm.Groups[1].Value + $mm.Groups[2].Value
    }
    return $null
}

# ============================================================================
# forbidden
# ============================================================================
$Forbidden = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path $ForbidFile) {
    Get-Content $ForbidFile | Where-Object { $_.Trim() } |
        ForEach-Object { [void]$Forbidden.Add($_.Trim().ToLower()) }
}
function Add-Forbidden([string]$Addr, [string]$Why) {
    $a = $Addr.Trim().ToLower()
    if ($Forbidden.Add($a)) { Add-Content -Path $ForbidFile -Value $a }
    Write-Host "[x] forbidden: $a ($Why)"
}

# ============================================================================
# URL + http
# ============================================================================
function Resolve-Url([string]$U) {
    if ([string]::IsNullOrWhiteSpace($U)) { return $U }
    if ($U -match '^https?://') { return $U }
    if ($U.StartsWith('/'))     { return "$Root$U" }
    return "$Base/$U"
}

function Invoke-Gb {
    param([string]$Url, [string]$Method = 'Get', $Body, [string]$Tag)
    $p = @{ Uri = $Url; Headers = $Headers; Method = $Method; TimeoutSec = 25; SkipHttpErrorCheck = $true }
    if ($Body) { $p['Body'] = ($Body | ConvertTo-Json -Compress -Depth 6) }
    Trace-Url "$Method $Tag" $Url
    try {
        $raw = Invoke-WebRequest @p
        $body = $null
        try { $body = $raw.Content | ConvertFrom-Json } catch { $body = $raw.Content }
        if ($Tag) { Write-TextNoBom (Join-Path $DumpDir "$Tag.json") $raw.Content }
        return @{ ok = ($raw.StatusCode -ge 200 -and $raw.StatusCode -lt 300); status = $raw.StatusCode; body = $body; raw = $raw.Content }
    } catch {
        $st = $null; $pd = $null; $rawText = $null
        $r = $_.Exception.Response
        if ($r) {
            $st = [int]$r.StatusCode
            try {
                $rawText = (New-Object IO.StreamReader($r.GetResponseStream())).ReadToEnd()
                if ($rawText) { try { $pd = $rawText | ConvertFrom-Json } catch { $pd = $rawText } }
            } catch { }
        }
        if ($Tag -and $rawText) { Write-TextNoBom (Join-Path $DumpDir "$Tag.err.json") $rawText }
        return @{ ok = $false; status = $st; body = $pd; raw = $rawText; error = $_.Exception.Message }
    }
}
function Get-Field($Obj, [string[]]$Names) {
    if (-not $Obj) { return $null }
    foreach ($n in $Names) {
        if ($Obj.PSObject.Properties.Name -contains $n) {
            $v = $Obj.$n
            if ($null -ne $v -and "$v" -ne '') { return $v }
        }
    }
    return $null
}
function Get-AllFields($Obj) { if ($Obj) { return ($Obj.PSObject.Properties.Name -join ', ') } return '' }

# ============================================================================
# route sentTo -> open tab
# ============================================================================
function Find-TabForInbox {
    param([string]$SentTo, [object[]]$Tabs)
    if (-not $SentTo) { return $null }
    $target = $SentTo.Trim().ToLower()
    foreach ($t in $Tabs) {
        if ($t.Chip -and $t.Chip.ToLower() -eq $target) { return $t }
    }
    foreach ($t in $Tabs) {
        try {
            $text = Read-PageText -WsUrl $t.WsUrl
            if ($text -and $text.ToLower().Contains($target)) { return $t }
        } catch { }
    }
    return $null
}

# ============================================================================
# one task
# ============================================================================
function Invoke-OneTask {
    param([string]$Target, [object[]]$Tabs)
    $tag = $Target -replace '[^a-zA-Z0-9]','_'

    $r = Invoke-Gb -Url "$Base/secure" -Method Post -Body @{ method='otp'; email=$Target } -Tag "secure_$tag"
    if ($r.status -eq 401) { return @{ ok=$false; reason='auth'; fatal=$true } }
    if (-not $r.ok -or -not $r.body.success) {
        $err = if ($r.body.error) { $r.body.error } else { $r.error }
        return @{ ok=$false; reason="secure: $err" }
    }
    $d = $r.body.data
    $submitUrl = Resolve-Url (Get-Field $d @('submitUrl'))
    $statusUrl = Resolve-Url (Get-Field $d @('statusUrl'))
    if (-not $submitUrl) { return @{ ok=$false; reason="no submitUrl — fields: $(Get-AllFields $d)" } }

    if ($VerbosePreference -ne 'SilentlyContinue') {
        Write-Verbose ("    task:      {0}" -f $Target)
        Write-Verbose ("    taskId:    {0}" -f (Get-Field $d @('taskId','id')))
        Write-Verbose ("    statusUrl: {0}" -f $statusUrl)
        Write-Verbose ("    submitUrl: {0}" -f $submitUrl)
    }

    $sentTo = $null
    if ($d.accounts -and @($d.accounts).Count -gt 0) { $sentTo = $d.accounts[0].sentTo }
    Write-Host "    sentTo: $sentTo"

    $tab = Find-TabForInbox -SentTo $sentTo -Tabs $Tabs
    if (-not $tab) { return @{ ok=$false; reason="no open gmail tab for $sentTo" } }
    Write-Host "    routed to tab: chip=$($tab.Chip)"

    if ($statusUrl) {
        $deadline0 = (Get-Date).AddSeconds($AwaitOtpSecs)
        while ((Get-Date) -lt $deadline0) {
            $t = Invoke-Gb -Url $statusUrl -Tag "status_$tag"
            if ($t.ok -and $t.body.success) {
                $st = Get-Field $t.body.data @('status','state')
                if ($st -in @('awaiting_otp','completed','failed')) { break }
            }
            Start-Sleep -Seconds $Interval
        }
    }

    Write-Host "    waiting up to ${MailArriveSecs}s for code mail in $($tab.Chip)..."
    $deadline = (Get-Date).AddSeconds($MailArriveSecs)
    $lastRefresh = [datetime]::MinValue
    $otp = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $text = Read-PageText -WsUrl $tab.WsUrl
            $otp  = Extract-Otp $text
            if ($otp) { break }
        } catch { }
        if (((Get-Date) - $lastRefresh).TotalSeconds -ge 20) {
            Refresh-Tab -Tab $tab
            $lastRefresh = Get-Date
        }
        Start-Sleep -Seconds $Interval
    }
    if (-not $otp) { return @{ ok=$false; reason="no otp arrived in $($tab.Chip) for $sentTo" } }
    Write-Host "    otp: $otp (from $($tab.Chip))"

    $s = Invoke-Gb -Url $submitUrl -Method Post -Body @{ otp=$otp } -Tag "submit_$tag"
    if ($s.status -eq 401) { return @{ ok=$false; reason='auth'; fatal=$true } }
    if (-not ($s.ok -and $s.body.success)) {
        $err = if ($s.body.error) { $s.body.error } else { $s.error }
        return @{ ok=$false; reason="submit: $err" }
    }

    if ($statusUrl) {
        $deadline2 = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline2) {
            $t = Invoke-Gb -Url $statusUrl -Tag "task_$tag"
            if ($t.ok -and $t.body.success) {
                $st = Get-Field $t.body.data @('status','state')
                if ($st -eq 'completed') { return @{ ok=$true; reason="completed via $($tab.Chip)" } }
                if ($st -eq 'failed')    { return @{ ok=$false; reason='task failed after submit' } }
            }
            Start-Sleep -Seconds $Interval
        }
        return @{ ok=$true; reason='otp accepted (confirm timed out)' }
    }
    return @{ ok=$true; reason='otp accepted' }
}

# ============================================================================
# main
# ============================================================================
Write-Host "[*] attaching to chrome on port $DebugPort"
[void](Assert-ChromeAttached)

$tabs = Get-GmailTabs
if (-not $tabs -or $tabs.Count -eq 0) {
    throw "no gmail tabs open. open mail.google.com in at least one tab and rerun."
}
Write-Host "[*] open gmail tabs: $($tabs.Count)"
foreach ($t in $tabs) {
    $chipTxt = if ($t.Chip) { $t.Chip } else { '(chip unread)' }
    Write-Host "    - $chipTxt"
}

if ($EmailFile) {
    if (-not (Test-Path $EmailFile)) { throw "no such file: $EmailFile" }
    $emails = Get-Content $EmailFile |
        Where-Object { $_.Trim() } |
        ForEach-Object { $_.Trim().TrimStart([char]0xFEFF) } |
        Where-Object { $_ }
} else {
    $emails = $tabs | ForEach-Object { $_.Chip } | Where-Object { $_ } | Select-Object -Unique
    Write-Host "[*] no EmailFile — using every gmail found in open tabs"
}
if (-not $emails) { throw 'no targets to run' }

if ($OpenMissingGmailTabs) {
    foreach ($e in $emails) {
        $have = $tabs | Where-Object { $_.Chip -and $_.Chip.ToLower() -eq $e.ToLower() }
        if (-not $have) {
            Write-Host "[*] opening tab for $e"
            [void](Open-GmailTab -Address $e)
        }
    }
    $tabs = Get-GmailTabs
}

$queue = $emails | Where-Object { -not $Forbidden.Contains($_.ToLower()) }
Write-Host "[*] queue — $($queue.Count)/$($emails.Count) targets (skipping forbidden)"
Write-Host ""

$okCount = 0; $forbidCount = 0; $authFail = $false

foreach ($addr in $queue) {
    Write-Host "[>] $addr"
    $res = try { Invoke-OneTask -Target $addr -Tabs $tabs }
           catch { @{ ok=$false; reason="exception: $($_.Exception.Message)" } }

    if ($res.ok)          { $okCount++; Write-Host "[+] $addr — $($res.reason)" }
    elseif ($res.fatal)   { Write-Host '[!] auth failed — stopping'; $authFail = $true; break }
    else                  { Add-Forbidden -Addr $addr -Why $res.reason; $forbidCount++ }

    if (-not $authFail) { Start-Sleep -Seconds $BetweenEmails }
}

Write-Host ""
Write-Host "[*] batch done — ok:$okCount forbidden:$forbidCount"
