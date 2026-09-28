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
    Write-Host '.env já existe; mantendo os valores dele (-DataRoot e -ServerHost são ignorados).'
} else {
    $content = Get-Content (Join-Path $root '.env.example') -Raw
    if ($DataRoot) { $content = $content -replace '(?m)^DATA_ROOT=.*$', "DATA_ROOT=$($DataRoot -replace '\\','/')" }
    if ($ServerHost) { $content = $content -replace '(?m)^SERVER_HOST=.*$', "SERVER_HOST=$ServerHost" }
    Set-Content -Path $envFile -Value $content -NoNewline -Encoding utf8NoBOM
    Write-Host ".env criado em $envFile"
}

# Gera as chaves de API vazias e troca a senha de exemplo (ou vazia) por uma aleatória.
# Vale também para um .env copiado à mão do .env.example.
$content = Get-Content $envFile -Raw
$filled = $content
foreach ($k in 'RADARR_API_KEY', 'SONARR_API_KEY', 'PROWLARR_API_KEY') {
    $filled = $filled -replace "(?m)^$k=[ \t]*(?=\r?$)", "$k=$(New-Hex 16)"
}
$filled = $filled -replace '(?m)^ADMIN_PASSWORD=(troque-esta-senha)?[ \t]*(?=\r?$)', "ADMIN_PASSWORD=$(New-Hex 8)"
if ($filled -ne $content) {
    Set-Content -Path $envFile -Value $filled -NoNewline -Encoding utf8NoBOM
    Write-Host 'Chaves de API e/ou senha geradas no .env'
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
