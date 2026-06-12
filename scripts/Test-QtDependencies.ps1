[CmdletBinding()]
param(
    [switch] $AutoFix
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot

Write-Host "=== Verificando dependências do Qt ===" -ForegroundColor Cyan

# 1. Verifica versão do Windows SDK
Write-Host "`n[1] Verificando Windows SDK..." -ForegroundColor Yellow

$sdkPath = "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots"
$sdkVersion = $null

try {
    if (Test-Path $sdkPath) {
        $versions = Get-ChildItem $sdkPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match "^\d+\.\d+" } |
            ForEach-Object { $_.PSChildName } |
            Sort-Object -Descending

        if ($versions) {
            $sdkVersion = $versions[0]
            Write-Host "  ✓ Windows SDK encontrado: versão $sdkVersion" -ForegroundColor Green

            # Windows 11 requer SDK 22621+ para DWM rounded corners
            $majorMinor = $sdkVersion -split '\.' | Select-Object -First 2
            if ([int]$majorMinor[0] -lt 22 -or ([int]$majorMinor[0] -eq 22 -and [int]$majorMinor[1] -lt 621)) {
                Write-Host "  ⚠ Aviso: SDK < 22.621 pode não ter suporte para DWM_WINDOW_CORNER_PREFERENCE" -ForegroundColor Yellow
                $needsFix = $true
            }
        }
    }
}
catch {
    Write-Host "  ⚠ Não foi possível verificar Windows SDK: $_" -ForegroundColor Yellow
}

if ($null -eq $sdkVersion) {
    Write-Host "  ✗ Windows SDK não encontrado ou versão indeterminada" -ForegroundColor Red
    $needsFix = $true
}

# 2. Verifica MSVC
Write-Host "`n[2] Verificando MSVC..." -ForegroundColor Yellow

$vswhereCandidates = @(
    "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
    "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

$vswhere = $vswhereCandidates | Select-Object -First 1
if ($vswhere) {
    $msvcRoot = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not [string]::IsNullOrWhiteSpace($msvcRoot)) {
        $msvcToolsRoot = Join-Path $msvcRoot 'VC\Tools\MSVC'
        $version = Get-ChildItem -LiteralPath $msvcToolsRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property Name -Descending |
            Select-Object -First 1

        if ($version) {
            Write-Host "  ✓ MSVC encontrado: $($version.Name)" -ForegroundColor Green
        }
        else {
            Write-Host "  ⚠ MSVC Tools não encontrado em $msvcToolsRoot" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  ⚠ Visual Studio C++ Build Tools não encontrado pelo vswhere" -ForegroundColor Yellow
    }
}
else {
    Write-Host "  ⚠ vswhere.exe não encontrado; não foi possível autodetectar MSVC" -ForegroundColor Yellow
}

# 3. Verifica vcpkg
Write-Host "`n[3] Verificando vcpkg..." -ForegroundColor Yellow

$vcpkgRoot = Join-Path $ProjectRoot "tools\vcpkg"
$vcpkgExe = Join-Path $vcpkgRoot "vcpkg.exe"

if (Test-Path $vcpkgExe) {
    Write-Host "  ✓ vcpkg encontrado: $vcpkgExe" -ForegroundColor Green
}
else {
    Write-Host "  ✗ vcpkg.exe não encontrado" -ForegroundColor Red
}

# 4. Solução: Criar overlay para desabilitar DWM se necessário
if ($needsFix -or $AutoFix) {
    Write-Host "`n[4] Aplicando correção..." -ForegroundColor Yellow

    $overlayDir = Join-Path $vcpkgRoot "overlays\qtbase"

    if (-not (Test-Path $overlayDir)) {
        New-Item -ItemType Directory -Path $overlayDir -Force | Out-Null
        Write-Host "  ✓ Diretório de overlay criado: $overlayDir" -ForegroundColor Green
    }

    # Copia portfile.cmake para overlay e desabilita a feature
    $sourcePortfile = Join-Path $vcpkgRoot "ports\qtbase\portfile.cmake"
    $overlayPortfile = Join-Path $overlayDir "portfile.cmake"

    if (Test-Path $sourcePortfile) {
        Copy-Item $sourcePortfile $overlayPortfile -Force
        Write-Host "  ✓ portfile.cmake copiado para overlay" -ForegroundColor Green

        # Modifica para desabilitar a feature problemática
        $content = Get-Content $overlayPortfile -Raw

        # Verifica se já tem a configuração
        if ($content -notmatch "FEATURE_system_dwm_api") {
            # Encontra a seção qt_cmake_build_args e adiciona a flag
            if ($content -match 'set\(qt_cmake_build_args') {
                $newContent = $content -replace `
                    '(set\(qt_cmake_build_args[^)]*)', `
                    '$1 -DFEATURE_system_dwm_api=OFF'

                Set-Content $overlayPortfile -Value $newContent
                Write-Host "  ✓ Feature FEATURE_system_dwm_api desabilitada" -ForegroundColor Green
            }
        }
    }

    # Cria vcpkg.json com overlay config
    $configFile = Join-Path $overlayDir "vcpkg.json"
    if (-not (Test-Path $configFile)) {
        @{
            name = "qtbase"
            version = "6.11.1"
        } | ConvertTo-Json | Set-Content $configFile
        Write-Host "  ✓ vcpkg.json criado para overlay" -ForegroundColor Green
    }
}

Write-Host "`n[5] Resumo" -ForegroundColor Cyan
Write-Host @"
  Windows SDK: $(if ($sdkVersion) { $sdkVersion } else { "Não detectado" })
  Solução: Overlay para desabilitar DWM criado/verificado

  Para compilar com segurança, execute:
    .\build-full-zig.ps1 -Clean
"@ -ForegroundColor Gray

Write-Host "`n=== Verificação concluída ===" -ForegroundColor Cyan
