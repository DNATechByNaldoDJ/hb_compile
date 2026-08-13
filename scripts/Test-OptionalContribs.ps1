[CmdletBinding()]
param(
   [Alias('Profile')] [string] $BuildProfile = 'zig',
   [switch] $WithHbdap,
   [switch] $WithOpenAds,
   [ValidateSet('Smoke', 'Full')]
   [string] $HbdapValidation = 'Smoke',
   [string] $HbdapRoot = '',
   [string] $WslDistro = '',
   [string] $WslUser = '',
   [string] $DockerImage = '',
   [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$config = Get-Content (Join-Path $ProjectRoot 'config\profiles.json') -Raw | ConvertFrom-Json
$profile = $config.profiles.$BuildProfile
if (-not $profile) { throw "Perfil desconhecido: $BuildProfile" }
if (-not $WithHbdap -and -not $WithOpenAds) { throw 'Informe -WithHbdap e/ou -WithOpenAds.' }
$runnerProperty = $profile.PSObject.Properties['runner']
$runner = if ($runnerProperty -and $runnerProperty.Value) { [string] $runnerProperty.Value } else { 'windows' }
$installRoot = Join-Path $ProjectRoot (Join-Path 'out' ([string] $profile.installSubdir))
$hbmk2Relative = if ($runner -eq 'windows') { 'bin\hbmk2.exe' } else { 'bin\hbmk2' }
$hbmk2 = Join-Path $installRoot $hbmk2Relative

function Resolve-HbdapRoot {
   if (-not [string]::IsNullOrWhiteSpace($HbdapRoot)) {
      return [System.IO.Path]::GetFullPath($HbdapRoot)
   }
   $sibling = Join-Path (Split-Path -Parent $ProjectRoot) 'hbdap'
   if (Test-Path -LiteralPath $sibling -PathType Container) {
      return [System.IO.Path]::GetFullPath($sibling)
   }
   throw 'Checkout HBDAP nao encontrado. Informe -HbdapRoot para executar a suite completa.'
}

function Invoke-HbdapFullSuite {
   $resolvedHbdapRoot = Resolve-HbdapRoot
   $suite = Join-Path $resolvedHbdapRoot 'test-hb_compile.ps1'
   if (-not (Test-Path -LiteralPath $suite -PathType Leaf)) {
      throw "Suite HBDAP nao encontrada: $suite"
   }

   if ($runner -eq 'windows' -or -not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
      [System.Runtime.InteropServices.OSPlatform]::Windows
   )) {
      & $suite -HbCompileRoot $ProjectRoot
      if ($LASTEXITCODE -ne 0) { throw "Suite completa HBDAP falhou com codigo $LASTEXITCODE." }
      return
   }

   if ($runner -eq 'wsl') {
      $args = @()
      if ($WslUser) { $args += @('--user', $WslUser) }
      if ($WslDistro) { $args += @('-d', $WslDistro) }
      $wslSuite = ([string] (& wsl.exe @args --exec wslpath -a -u $suite)).Trim()
      $wslHbCompile = ([string] (& wsl.exe @args --exec wslpath -a -u $ProjectRoot)).Trim()
      & wsl.exe @args --exec pwsh -NoProfile -File $wslSuite -HbCompileRoot $wslHbCompile
      if ($LASTEXITCODE -ne 0) { throw "Suite completa HBDAP no WSL falhou com codigo $LASTEXITCODE." }
      return
   }

   throw "Suite completa HBDAP para '$runner' deve rodar em host Linux com pwsh; o smoke continua disponivel neste host."
}

function Find-Artifact {
   param([string] $Pattern)
   $roots = @($installRoot, (Join-Path $ProjectRoot "out\openads-$BuildProfile")) | Where-Object { Test-Path -LiteralPath $_ }
   return $roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -ErrorAction SilentlyContinue } | Where-Object Name -Match $Pattern | Select-Object -First 1
}

if ($WithHbdap) {
   foreach ($entry in @(
      @{ Name = 'biblioteca hbdap'; Pattern = '^(lib)?hbdap(?:-.*)?\.(a|lib|dll)$' },
      @{ Name = 'adapter'; Pattern = '^hbdap_adapter(\.exe)?$' },
      @{ Name = 'CLI'; Pattern = '^hbdap_cli(\.exe)?$' },
      @{ Name = 'manifesto'; Pattern = '^HBDAP_MANIFEST\.json$' }
   )) {
      if (-not (Find-Artifact $entry.Pattern)) { throw "$($entry.Name) nao encontrado em $installRoot" }
   }
   $manifest = Get-Content (Join-Path $installRoot 'HBDAP_MANIFEST.json') -Raw | ConvertFrom-Json
   if (-not $manifest.harbour.revision -or -not $manifest.hbdap.revision) { throw 'Manifesto HBDAP sem revisoes Harbour/HBDAP.' }

   $sample = Join-Path $ProjectRoot 'samples\hbdap-smoke.prg'
   $testRoot = Join-Path $ProjectRoot "scratch\tests\optional-$BuildProfile"
   New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
   $output = Join-Path $testRoot 'hbdap-smoke'
   if ($DryRun) { Write-Host "DryRun: compilar e executar consumidor HBDAP no runner $runner" }
   elseif ($runner -eq 'windows') {
      & $hbmk2 $sample 'hbdap.hbc' "-o$output"
      if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar consumidor HBDAP.' }
      $result = & "$output.exe"
      if ($LASTEXITCODE -ne 0 -or $result -notcontains 'HBDAP_SMOKE_OK') { throw 'Smoke funcional HBDAP falhou.' }
   }
   elseif ($runner -eq 'wsl') {
      $args = @(); if ($WslUser) { $args += @('--user', $WslUser) }; if ($WslDistro) { $args += @('-d', $WslDistro) }
      $toWsl = { param($p) ([string](& wsl.exe @args --exec wslpath -a -u $p)).Trim() }
      $lh=&$toWsl $hbmk2; $ls=&$toWsl $sample; $lo=&$toWsl $output
      & wsl.exe @args --exec bash -lc "'$lh' '$ls' hbdap.hbc '-o$lo' && '$lo'"
      if ($LASTEXITCODE -ne 0) { throw 'Smoke funcional HBDAP no WSL falhou.' }
   }
   elseif ($runner -eq 'docker') {
      if (-not $DockerImage) {
         $fullImageProperty = $profile.PSObject.Properties['dockerFullImage']
         $imageProperty = $profile.PSObject.Properties['dockerImage']
         $DockerImage = if ($fullImageProperty -and $fullImageProperty.Value) { [string] $fullImageProperty.Value } else { [string] $imageProperty.Value }
      }
      $ri=[System.IO.Path]::GetRelativePath($ProjectRoot,$installRoot).Replace('\','/'); $rs=[System.IO.Path]::GetRelativePath($ProjectRoot,$sample).Replace('\','/'); $ro=[System.IO.Path]::GetRelativePath($ProjectRoot,$output).Replace('\','/')
      & docker run --rm -v "${ProjectRoot}:/workspace" -w /workspace $DockerImage bash -lc "'/workspace/$ri/bin/hbmk2' '/workspace/$rs' hbdap.hbc '-o/workspace/$ro' && '/workspace/$ro'"
      if ($LASTEXITCODE -ne 0) { throw 'Smoke funcional HBDAP no Docker falhou.' }
   }
   else { throw "Runner ainda nao suportado pelo smoke HBDAP: $runner" }
   Write-Host "PASS HBDAP: artefatos, manifesto e consumidor publico ($BuildProfile)"
   if ($HbdapValidation -eq 'Full') {
      if ($DryRun) { Write-Host "DryRun: executar suite completa HBDAP no runner $runner" }
      else { Invoke-HbdapFullSuite }
      Write-Host "PASS HBDAP FULL: core, transporte, adapter, CLI e corpus ($BuildProfile)"
   }
}

if ($WithOpenAds) {
   foreach ($entry in @(
      @{ Name = 'librddads'; Pattern = '^(lib)?rddads(?:-.*)?\.(a|lib|dll)$' },
      @{ Name = 'libace'; Pattern = '^(lib)?(open)?ace(?:64)?\.(so|a|dll|lib)$' }
   )) {
      if (-not (Find-Artifact $entry.Pattern)) { throw "$($entry.Name) nao encontrado em $installRoot" }
   }
   Write-Host "PASS OpenADS: artefatos instalados ($BuildProfile); smoke de tabela permanece pendente."
}
