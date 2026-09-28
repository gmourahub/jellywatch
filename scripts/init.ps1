# Cria o .env a partir do .env.example com chaves e senha aleatórias.
# Uso: .\scripts\init.ps1 [-DataRoot D:/Jellyfin/data] [-ServerHost 192.168.0.10] [-Up]
param(
    [string]$DataRoot,
    [string]$ServerHost,
    [switch]$Up
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root '.env'

function New-Hex([int]$bytes) {
    -join ((1..$bytes) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
}

if (Test-Path $envFile) {
    Write-Host '.env já existe; mantendo o atual.'
} else {
    $content = Get-Content (Join-Path $root '.env.example') -Raw
    $content = $content -replace '(?m)^RADARR_API_KEY=.*$', "RADARR_API_KEY=$(New-Hex 16)"
    $content = $content -replace '(?m)^SONARR_API_KEY=.*$', "SONARR_API_KEY=$(New-Hex 16)"
    $content = $content -replace '(?m)^PROWLARR_API_KEY=.*$', "PROWLARR_API_KEY=$(New-Hex 16)"
    $content = $content -replace '(?m)^ADMIN_PASSWORD=.*$', "ADMIN_PASSWORD=$(New-Hex 8)"
    if ($DataRoot) { $content = $content -replace '(?m)^DATA_ROOT=.*$', "DATA_ROOT=$($DataRoot -replace '\\','/')" }
    if ($ServerHost) { $content = $content -replace '(?m)^SERVER_HOST=.*$', "SERVER_HOST=$ServerHost" }
    Set-Content -Path $envFile -Value $content -NoNewline -Encoding utf8NoBOM
    Write-Host ".env criado em $envFile"
}

# Credenciais opcionais vindas do ambiente ($env:OPENSUBTITLES_USERNAME / $env:OPENSUBTITLES_PASSWORD)
foreach ($k in 'OPENSUBTITLES_USERNAME', 'OPENSUBTITLES_PASSWORD') {
    $v = [Environment]::GetEnvironmentVariable($k)
    if (-not $v) { continue }
    $lines = @(Get-Content $envFile | Where-Object { $_ -notmatch "^$k=" }) + "$k=$v"
    Set-Content -Path $envFile -Value $lines -Encoding utf8NoBOM
    Write-Host "$k definido a partir do ambiente"
}

$dataRootValue = (Select-String -Path $envFile -Pattern '^DATA_ROOT=(.*)$').Matches[0].Groups[1].Value
New-Item -ItemType Directory -Force -Path $dataRootValue | Out-Null
Write-Host "DATA_ROOT: $dataRootValue"
Get-Content $envFile | Select-String '^(ADMIN_USER|ADMIN_PASSWORD)='

if ($Up) {
    Push-Location $root
    try {
        docker compose up -d
        docker compose logs -f setup
    } finally { Pop-Location }
}
