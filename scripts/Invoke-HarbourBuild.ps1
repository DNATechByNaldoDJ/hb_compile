[CmdletBinding()]
param(
   [string] $Profile = 'auto',
   [string[]] $Targets = @('install'),
   [switch] $Clean,
   [switch] $Minimal,
   [switch] $NoContrib,
   [switch] $Package,
   [string] $BuildParts,
   [int] $Jobs = 0,
   [string] $HarbourRoot,
   [string] $HarbourRepository,
   [string] $HarbourRef,
   [string[]] $MakeArg = @(),
   [hashtable] $Env = @{},
   [switch] $Full,
   [switch] $SkipDependencyInstall,
   [ValidateSet('full', 'network', 'database', 'gui', 'graphics')]
   [string] $DependencySet = 'full',
   [string[]] $Dependency = @(),
   [ValidateSet('vcpkg')]
   [string] $DependencyProvider = 'vcpkg',
   [string] $DependencyTriplet = '',
   [int] $DependencyInstallTimeoutMinutes = 120,
   [switch] $StrictDependencies,
   [switch] $DryRun,
   [switch] $ListProfiles,
   [switch] $NoVsDevShell,
   [string] $VsArch = 'amd64'
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $ProjectRoot 'config\profiles.json'

function Resolve-ProjectPath {
   param([Parameter(Mandatory = $true)][string] $Path)

   if ([System.IO.Path]::IsPathRooted($Path)) {
      return [System.IO.Path]::GetFullPath($Path)
   }

   return [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $Path))
}

function Format-ProjectPath {
   param([Parameter(Mandatory = $true)][string] $Path)

   $fullPath = [System.IO.Path]::GetFullPath($Path)
   $rootPath = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
   if ($fullPath.TrimEnd('\').Equals($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      return '.'
   }

   $fullRoot = "$rootPath\"
   if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      return ".\$($fullPath.Substring($fullRoot.Length))"
   }

   return $fullPath
}

function Format-DisplayValue {
   param([string] $Value)

   if ([string]::IsNullOrWhiteSpace($Value)) {
      return $Value
   }

   if ([System.IO.Path]::IsPathRooted($Value)) {
      return Format-ProjectPath $Value
   }

   return $Value
}

function Get-ProfileNames {
   param([Parameter(Mandatory = $true)] $Config)
   return @($Config.profiles.PSObject.Properties.Name)
}

function Get-ProfileConfig {
   param(
      [Parameter(Mandatory = $true)] $Config,
      [Parameter(Mandatory = $true)][string] $Name
   )

   $names = Get-ProfileNames -Config $Config
   if ($names -notcontains $Name) {
      throw "Perfil '$Name' nao existe. Use -ListProfiles para ver as opcoes."
   }

   return $Config.profiles.$Name
}

function Get-ProfileInstallRoot {
   param(
      [Parameter(Mandatory = $true)] $Config,
      [Parameter(Mandatory = $true)][string] $Name,
      [Parameter(Mandatory = $true)][string] $OutputRoot
   )

   $profileConfig = Get-ProfileConfig -Config $Config -Name $Name
   $subdir = $profileConfig.installSubdir
   if ([string]::IsNullOrWhiteSpace($subdir)) {
      $subdir = $Name
   }

   return Join-Path $OutputRoot $subdir
}

function Add-LocalToolPaths {
   param([Parameter(Mandatory = $true)][string] $ToolsRoot)

   $zigRoot = Join-Path $ToolsRoot 'zig'
   if (Test-Path -LiteralPath $zigRoot) {
      $zig = Get-ChildItem -LiteralPath $zigRoot -Filter 'zig.exe' -Recurse -ErrorAction SilentlyContinue |
         Sort-Object -Property FullName |
         Select-Object -First 1

      if ($zig) {
         $env:PATH = "$($zig.Directory.FullName);$env:PATH"
      }
   }
}

function Assert-Command {
   param(
      [Parameter(Mandatory = $true)][string] $Name,
      [Parameter(Mandatory = $true)][string] $Hint
   )

   if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
      throw "$Name nao foi encontrado. $Hint"
   }
}

function Get-ConfigString {
   param(
      [Parameter(Mandatory = $true)] $Config,
      [Parameter(Mandatory = $true)][string] $Name,
      [string] $Default = ''
   )

   $property = $Config.PSObject.Properties[$Name]
   if ($property -and -not [string]::IsNullOrWhiteSpace([string] $property.Value)) {
      return [string] $property.Value
   }

   return $Default
}

function Invoke-GitChecked {
   param(
      [Parameter(Mandatory = $true)][string[]] $Arguments,
      [Parameter(Mandatory = $true)][string] $FailureMessage
   )

   & git.exe @Arguments | Out-Host
   if ($LASTEXITCODE -ne 0) {
      throw $FailureMessage
   }
}

function Initialize-HarbourSource {
   param(
      [Parameter(Mandatory = $true)][string] $Root,
      [string] $Repository,
      [string] $Ref,
      [switch] $RepositorySpecified,
      [switch] $DryRun
   )

   if (Test-Path -LiteralPath $Root) {
      if ($RepositorySpecified -and (Get-Command 'git.exe' -ErrorAction SilentlyContinue)) {
         $origin = & git.exe -C $Root remote get-url origin 2>$null
         if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($origin) -and $origin -ne $Repository) {
            Write-Warning "HarbourRoot ja existe e usa '$origin'. Para clonar '$Repository', informe tambem outro -HarbourRoot."
         }
      }

      if (-not [string]::IsNullOrWhiteSpace($Ref)) {
         Write-Warning "HarbourRoot ja existe; -HarbourRef so e aplicado durante o clone. Use git -C `"$Root`" checkout $Ref se quiser trocar a ref."
      }

      return $true
   }

   if ([string]::IsNullOrWhiteSpace($Repository)) {
      throw "HarbourRoot nao existe: $Root. Informe -HarbourRepository ou configure harbourRepository."
   }

   $parent = Split-Path -Parent $Root

   if ($DryRun) {
      Write-Host "DryRun: git clone $Repository `"$(Format-ProjectPath $Root)`""
      if (-not [string]::IsNullOrWhiteSpace($Ref)) {
         Write-Host "DryRun: git -C `"$(Format-ProjectPath $Root)`" checkout $Ref"
      }
      return $false
   }

   Assert-Command -Name 'git.exe' -Hint 'Instale Git ou clone o Harbour manualmente e informe -HarbourRoot.'
   New-Item -ItemType Directory -Force -Path $parent | Out-Null

   Write-Host "Clonando Harbour: $Repository"
   Write-Host "Destino         : $(Format-ProjectPath $Root)"
   Invoke-GitChecked -Arguments @('clone', $Repository, $Root) -FailureMessage 'Falha ao clonar o repositorio do Harbour.'

   if (-not [string]::IsNullOrWhiteSpace($Ref)) {
      Write-Host "Selecionando ref: $Ref"
      Invoke-GitChecked -Arguments @('-C', $Root, 'checkout', $Ref) -FailureMessage "Falha ao selecionar a ref do Harbour: $Ref"
   }

   return $true
}

function Import-VsDevShell {
   param([string] $Arch = 'amd64')

   if (Get-Command 'cl.exe' -ErrorAction SilentlyContinue) {
      return
   }

   $vswhereCandidates = @(
      "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
      "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
   ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

   $vswhere = $vswhereCandidates | Select-Object -First 1
   if (-not $vswhere) {
      Write-Warning 'vswhere.exe nao foi encontrado; chame vcvarsall.bat antes de usar o perfil MSVC.'
      return
   }

   $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
   if ([string]::IsNullOrWhiteSpace($installPath)) {
      Write-Warning 'Visual Studio C++ Build Tools nao encontrado; chame vcvarsall.bat antes de usar o perfil MSVC.'
      return
   }

   $vcvars = Join-Path $installPath 'VC\Auxiliary\Build\vcvarsall.bat'
   if (-not (Test-Path -LiteralPath $vcvars)) {
      Write-Warning "vcvarsall.bat nao encontrado em '$vcvars'."
      return
   }

   Write-Host "Carregando ambiente MSVC: $vcvars $Arch"
   $cmd = '"' + $vcvars + '" ' + $Arch + ' >nul && set'
   $lines = & cmd.exe /d /s /c $cmd
   foreach ($line in $lines) {
      if ($line -match '^([^=]+)=(.*)$') {
         [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
      }
   }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
   throw "Arquivo de configuracao nao encontrado: $ConfigPath"
}

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$OutputRoot = Resolve-ProjectPath $Config.outputRoot
$LogsRoot = Resolve-ProjectPath $Config.logsRoot
$ToolsRoot = Resolve-ProjectPath $Config.toolsRoot
$harbourRepositoryWasSpecified = $PSBoundParameters.ContainsKey('HarbourRepository')

if ($ListProfiles) {
   $rows = foreach ($name in (Get-ProfileNames -Config $Config)) {
      $profileConfig = Get-ProfileConfig -Config $Config -Name $name
      [pscustomobject]@{
         Profile = $name
         Output = (Get-ProfileInstallRoot -Config $Config -Name $name -OutputRoot $OutputRoot)
         Description = $profileConfig.description
      }
   }

   $rows | Format-Table -AutoSize
   return
}

$ProfileConfig = Get-ProfileConfig -Config $Config -Name $Profile

if ([string]::IsNullOrWhiteSpace($HarbourRoot)) {
   $HarbourRoot = Get-ConfigString -Config $Config -Name 'harbourRoot' -Default 'scratch\harbour-core'
}
if ([string]::IsNullOrWhiteSpace($HarbourRepository)) {
   $HarbourRepository = Get-ConfigString -Config $Config -Name 'harbourRepository' -Default 'https://github.com/harbour/core.git'
}
$HarbourRoot = Resolve-ProjectPath $HarbourRoot

$harbourSourceReady = Initialize-HarbourSource `
   -Root $HarbourRoot `
   -Repository $HarbourRepository `
   -Ref $HarbourRef `
   -RepositorySpecified:$harbourRepositoryWasSpecified `
   -DryRun:$DryRun

$makeExe = Join-Path $HarbourRoot 'win-make.exe'
if (-not (Test-Path -LiteralPath $makeExe) -and ($harbourSourceReady -or -not $DryRun)) {
   throw "win-make.exe nao encontrado no HarbourRoot: $makeExe"
}

$makefile = Join-Path $HarbourRoot 'Makefile'
if (-not (Test-Path -LiteralPath $makefile) -and ($harbourSourceReady -or -not $DryRun)) {
   throw "Makefile do Harbour nao encontrado: $makefile"
}

New-Item -ItemType Directory -Force -Path $OutputRoot, $LogsRoot, $ToolsRoot | Out-Null
Add-LocalToolPaths -ToolsRoot $ToolsRoot

$generatedDeps = Join-Path $ProjectRoot 'config\external-deps.generated.ps1'
if ($Full) {
   $resolver = Join-Path $ProjectRoot 'scripts\Resolve-HarbourDeps.ps1'
   if (-not (Test-Path -LiteralPath $resolver)) {
      throw "Resolvedor de dependencias nao encontrado: $resolver"
   }

   $resolverArgs = @{
      Set = $DependencySet
      Provider = $DependencyProvider
      GenerateEnv = $true
      DependencyInstallTimeoutMinutes = $DependencyInstallTimeoutMinutes
   }

   if ($DependencyTriplet) {
      $resolverArgs.Triplet = $DependencyTriplet
   }
   if ($Dependency.Count -gt 0) {
      $resolverArgs.Dependency = $Dependency
   }
   if (-not $SkipDependencyInstall) {
      $resolverArgs.Install = $true
   }
   if ($StrictDependencies) {
      $resolverArgs.Strict = $true
   }
   if ($DryRun) {
      $resolverArgs.DryRun = $true
   }

   & $resolver @resolverArgs
   if (-not $?) {
      throw 'Falha ao resolver dependencias.'
   }
}

if (Test-Path -LiteralPath $generatedDeps) {
   . $generatedDeps
}

$externalDeps = Join-Path $ProjectRoot 'config\external-deps.local.ps1'
if (Test-Path -LiteralPath $externalDeps) {
   . $externalDeps
}

foreach ($requirement in (@($ProfileConfig.requires) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
   switch ($requirement) {
      'zig' {
         Assert-Command -Name 'zig.exe' -Hint 'Execute .\scripts\Bootstrap-Tools.ps1 -Tool Zig ou adicione o Zig ao PATH.'
      }
      default {
         throw "Pre-requisito desconhecido no perfil '$Profile': $requirement"
      }
   }
}

if (-not $NoVsDevShell -and ($ProfileConfig.autoVsDevShell -eq $true)) {
   Import-VsDevShell -Arch $VsArch
}

if ($Jobs -le 0) {
   if ($Config.defaultJobs -gt 0) {
      $Jobs = [int] $Config.defaultJobs
   }
   else {
      $Jobs = [System.Environment]::ProcessorCount
   }
}

$installRoot = Get-ProfileInstallRoot -Config $Config -Name $Profile -OutputRoot $OutputRoot
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null

$envMap = [ordered]@{}
$envMap['HB_INSTALL_PREFIX'] = $installRoot

foreach ($item in @($ProfileConfig.env.PSObject.Properties)) {
   $envMap[$item.Name] = [string] $item.Value
}

if ($ProfileConfig.hostBinProfile) {
   $hostProfile = [string] $ProfileConfig.hostBinProfile
   if (-not $envMap.Contains('HB_HOST_BIN') -and [string]::IsNullOrWhiteSpace($env:HB_HOST_BIN)) {
      $hostInstallRoot = Get-ProfileInstallRoot -Config $Config -Name $hostProfile -OutputRoot $OutputRoot
      $hostBin = Join-Path $hostInstallRoot 'bin'
      $hostHbmk2 = Join-Path $hostBin 'hbmk2.exe'

      if (-not (Test-Path -LiteralPath $hostHbmk2)) {
         $fallbackBin = Join-Path $HarbourRoot 'bin\win\zig'
         $fallbackHbmk2 = Join-Path $fallbackBin 'hbmk2.exe'
         if (Test-Path -LiteralPath $fallbackHbmk2) {
            $hostBin = $fallbackBin
         }
         else {
            throw "O perfil '$Profile' requer HB_HOST_BIN. Compile primeiro o perfil '$hostProfile' ou defina HB_HOST_BIN."
         }
      }

      $envMap['HB_HOST_BIN'] = $hostBin
   }
}

if ($Minimal) {
   $envMap['HB_BUILD_3RDEXT'] = 'no'
}

if ($NoContrib) {
   $envMap['HB_BUILD_CONTRIBS'] = 'no'
}

if ($Package) {
   $envMap['HB_BUILD_PKG'] = 'yes'
}

if ($Full) {
   $envMap['HB_INSTALL_3RDDYN'] = 'yes'
}

if (-not [string]::IsNullOrWhiteSpace($BuildParts)) {
   $envMap['HB_BUILD_PARTS'] = $BuildParts
}

foreach ($key in $Env.Keys) {
   $envMap[$key] = [string] $Env[$key]
}

$targetList = @()
if ($Clean -and ($Targets -notcontains 'clean')) {
   $targetList += 'clean'
}
$targetList += $Targets
if ($targetList.Count -eq 0) {
   $targetList += 'install'
}

$makeArgs = @("-j$Jobs") + $targetList + $MakeArg
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeProfile = $Profile -replace '[^A-Za-z0-9_.-]', '_'
$logPath = Join-Path $LogsRoot "$stamp-$safeProfile.log"

Write-Host "HarbourRoot : $(Format-ProjectPath $HarbourRoot)"
Write-Host "Perfil      : $Profile"
Write-Host "Install     : $(Format-ProjectPath $installRoot)"
Write-Host "Log         : $(Format-ProjectPath $logPath)"
Write-Host "Comando     : $(Format-ProjectPath $makeExe) $($makeArgs -join ' ')"
Write-Host ''
Write-Host 'Ambiente Harbour:'
foreach ($key in $envMap.Keys) {
   Write-Host ("  {0}={1}" -f $key, (Format-DisplayValue $envMap[$key]))
}
Write-Host ''

if ($DryRun) {
   Write-Host 'DryRun ativo: nenhum build foi iniciado.'
   return
}

$oldEnv = @{}
foreach ($key in $envMap.Keys) {
   $oldEnv[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
   [System.Environment]::SetEnvironmentVariable($key, $envMap[$key], 'Process')
}

try {
   Push-Location $HarbourRoot
   try {
      $previousErrorActionPreference = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
         & $makeExe @makeArgs 2>&1 |
            ForEach-Object { $_.ToString() } |
            Tee-Object -FilePath $logPath
         $exitCode = $LASTEXITCODE
      }
      finally {
         $ErrorActionPreference = $previousErrorActionPreference
      }
   }
   finally {
      Pop-Location
   }
}
finally {
   foreach ($key in $envMap.Keys) {
      [System.Environment]::SetEnvironmentVariable($key, $oldEnv[$key], 'Process')
   }
}

if ($exitCode -ne 0) {
   throw "Build falhou com codigo $exitCode. Veja o log: $logPath"
}

if ($targetList -contains 'install') {
   $binDir = Join-Path $installRoot 'bin'
   $hbmk2Exe = Join-Path $binDir 'hbmk2.exe'
   $hbmk2Unix = Join-Path $binDir 'hbmk2'
   if ((Test-Path -LiteralPath $hbmk2Exe) -or (Test-Path -LiteralPath $hbmk2Unix)) {
      Write-Host ''
      Write-Host "Build concluido. hbmk2 instalado em: $binDir"
   }
   else {
      Write-Warning "Build terminou, mas hbmk2 nao foi encontrado em '$binDir'. Confira o log."
   }
}
else {
   Write-Host ''
   Write-Host 'Build concluido.'
}
