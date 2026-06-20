[CmdletBinding()]
param(
    [switch] $AutoFix
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$needsFix = $false
$fixApplied = $false

Write-Host "=== Verificando dependências do Qt ===" -ForegroundColor Cyan

# 1. Verifica versão do Windows SDK
Write-Host "`n[1] Verificando Windows SDK..." -ForegroundColor Yellow

$sdkPath = "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots"
$sdkVersion = $null

try {
    if (Test-Path $sdkPath) {
        $versions = Get-ChildItem $sdkPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^\d+(?:\.\d+){1,3}$' } |
            Sort-Object -Property { [version] $_.PSChildName } -Descending |
            ForEach-Object { $_.PSChildName }

        if ($versions) {
            $sdkVersion = $versions[0]
            Write-Host "  ✓ Windows SDK encontrado: versão $sdkVersion" -ForegroundColor Green

            # Windows 11 requer SDK 22621+ para DWM rounded corners
            $parsedSdkVersion = [version] $sdkVersion
            if ($parsedSdkVersion.Major -lt 10 -or
                ($parsedSdkVersion.Major -eq 10 -and $parsedSdkVersion.Build -lt 22621)) {
                Write-Host "  ⚠ Aviso: SDK build < 22621 pode não ter suporte para DWM_WINDOW_CORNER_PREFERENCE" -ForegroundColor Yellow
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

# 4. Solução: configurar o triplet que o resolvedor passa ao vcpkg
Write-Host "`n[4] Verificando correção DWM..." -ForegroundColor Yellow
$tripletDir = Join-Path $vcpkgRoot 'triplets\custom'
$tripletFile = Join-Path $tripletDir 'x64-windows-no-dwm.cmake'
$tripletReady = $false
if (Test-Path -LiteralPath $tripletFile) {
    $tripletContent = Get-Content -LiteralPath $tripletFile -Raw
    $tripletReady = $tripletContent -match '(?m)^\s*set\(VCPKG_CMAKE_CONFIGURE_OPTIONS.*FEATURE_system_dwm_api=OFF'
}

if ($AutoFix) {
    New-Item -ItemType Directory -Path $tripletDir -Force | Out-Null
    @'
# Qt sem a API DWM que requer Windows SDK recente.
include(${CMAKE_CURRENT_LIST_DIR}/../x64-windows.cmake)
set(VCPKG_CMAKE_CONFIGURE_OPTIONS "-DFEATURE_system_dwm_api=OFF")
'@ | Set-Content -LiteralPath $tripletFile -Encoding ASCII
    $tripletReady = $true
    $fixApplied = $true
    Write-Host "  ✓ Triplet criado/atualizado: $tripletFile" -ForegroundColor Green
}
elseif ($tripletReady) {
    Write-Host "  ✓ Triplet DWM já está configurado" -ForegroundColor Green
}
elseif ($needsFix) {
    Write-Host "  ⚠ Correção necessária; execute novamente com -AutoFix" -ForegroundColor Yellow
}
else {
    Write-Host "  ✓ SDK atual não requer a correção" -ForegroundColor Green
}

Write-Host "`n[5] Resumo" -ForegroundColor Cyan
$solutionStatus = if ($fixApplied) {
    'Triplet DWM criado/atualizado'
}
elseif ($tripletReady) {
    'Triplet DWM já configurado'
}
elseif ($needsFix) {
    'Pendente; execute com -AutoFix'
}
else {
    'Não necessária para o SDK detectado'
}
Write-Host @"
  Windows SDK: $(if ($sdkVersion) { $sdkVersion } else { "Não detectado" })
  Solução: $solutionStatus

  Build recomendado após uma correção:
    .\build-full-msvc64.ps1 -Clean
"@ -ForegroundColor Gray

Write-Host "`n=== Verificação concluída ===" -ForegroundColor Cyan
