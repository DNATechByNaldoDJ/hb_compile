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
   [Alias('Ignore', 'DependencyIgnore', 'SkipDependency')]
   [string[]] $IgnoreDependency = @(),
   [ValidateSet('vcpkg')]
   [string] $DependencyProvider = 'vcpkg',
   [string] $DependencyTriplet = '',
   [int] $DependencyInstallTimeoutMinutes = 120,
   [switch] $StrictDependencies,
   [switch] $DryRun,
   [switch] $ListProfiles,
   [switch] $NoVsDevShell,
   [string] $VsArch = 'amd64',
   [string] $CygwinBash = '',
   [string] $WslDistro = '',
   [string] $WslUser = '',
   [string] $DockerImage = '',
   [string] $Dockerfile = '',
   [switch] $SkipDockerBuild,
   [string[]] $DockerArg = @(),
   [string[]] $DockerBuildArg = @()
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

   if ($Value.StartsWith('/')) {
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

function Get-ConfigBoolean {
   param(
      [Parameter(Mandatory = $true)] $Config,
      [Parameter(Mandatory = $true)][string] $Name,
      [bool] $Default = $false
   )

   $property = $Config.PSObject.Properties[$Name]
   if ($property -and $null -ne $property.Value) {
      return [System.Convert]::ToBoolean($property.Value)
   }

   return $Default
}

function Quote-ShArgument {
   param([string] $Value)

   if ($null -eq $Value) {
      return "''"
   }

   return "'" + ($Value -replace "'", "'\''") + "'"
}

function Format-CommandArgument {
   param([string] $Value)

   if ($null -eq $Value) {
      return '""'
   }

   if ($Value -match '[\s"]') {
      return '"' + ($Value -replace '"', '\"') + '"'
   }

   return $Value
}

function Test-PathUnderRoot {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][string] $Root
   )

   try {
      $trimChars = [char[]] '\/'
      $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd($trimChars)
      $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd($trimChars)
      return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
         $fullPath.StartsWith("$fullRoot\", [System.StringComparison]::OrdinalIgnoreCase)
   }
   catch {
      return $false
   }
}

function Resolve-DockerCommand {
   param([switch] $DryRun)

   $docker = Get-Command 'docker.exe' -ErrorAction SilentlyContinue
   if ($docker) {
      return $docker.Source
   }

   $docker = Get-Command 'docker' -ErrorAction SilentlyContinue
   if ($docker) {
      return $docker.Source
   }

   if ($DryRun) {
      return 'docker.exe'
   }

   throw 'docker.exe nao foi encontrado. Instale Docker Desktop ou adicione o Docker ao PATH.'
}

function Expand-NameList {
   param([string[]] $Values)

   $names = New-Object System.Collections.Generic.List[string]
   foreach ($value in @($Values)) {
      foreach ($name in ([string] $value -split ',')) {
         $trimmed = $name.Trim()
         if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $names.Contains($trimmed)) {
            $names.Add($trimmed)
         }
      }
   }

   return @($names)
}

function Resolve-DependencyName {
   param(
      [Parameter(Mandatory = $true)] $Catalog,
      [Parameter(Mandatory = $true)][string] $Name
   )

   foreach ($candidate in @($Catalog.dependencies.PSObject.Properties.Name)) {
      if ($candidate.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) {
         return $candidate
      }
   }

   throw "Dependencia desconhecida no catalogo: $Name"
}

function Test-CygwinBash {
   param([Parameter(Mandatory = $true)][string] $Path)

   if (-not (Test-Path -LiteralPath $Path)) {
      return $false
   }

   try {
      $uname = & $Path -lc 'uname -s' 2>$null
      return ($LASTEXITCODE -eq 0 -and (($uname -join "`n") -match 'CYGWIN'))
   }
   catch {
      return $false
   }
}

function Resolve-CygwinBash {
   param([string] $PreferredPath)

   $candidates = New-Object System.Collections.Generic.List[string]
   if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
      $candidates.Add($PreferredPath)
   }

   foreach ($path in @('C:\cygwin64\bin\bash.exe', 'C:\cygwin\bin\bash.exe')) {
      $candidates.Add($path)
   }

   $pathBash = Get-Command 'bash.exe' -ErrorAction SilentlyContinue
   if ($pathBash) {
      $candidates.Add($pathBash.Source)
   }

   foreach ($candidate in ($candidates | Select-Object -Unique)) {
      if (Test-CygwinBash -Path $candidate) {
         return [System.IO.Path]::GetFullPath($candidate)
      }
   }

   throw 'bash.exe do Cygwin nao foi encontrado. Instale Cygwin ou informe -CygwinBash C:\cygwin64\bin\bash.exe.'
}

function Assert-CygwinTool {
   param(
      [Parameter(Mandatory = $true)][string] $BashPath,
      [Parameter(Mandatory = $true)][string] $Name
   )

   & $BashPath -lc "command -v $(Quote-ShArgument $Name) >/dev/null"
   if ($LASTEXITCODE -ne 0) {
      throw "Ferramenta '$Name' nao foi encontrada dentro do Cygwin. Instale o pacote correspondente pelo setup do Cygwin."
   }
}

function Get-WslArguments {
   param(
      [string] $Distro,
      [string] $User = ''
   )

   $arguments = @()
   if (-not [string]::IsNullOrWhiteSpace($Distro)) {
      $arguments += @('-d', $Distro)
   }
   if (-not [string]::IsNullOrWhiteSpace($User)) {
      $arguments += @('--user', $User)
   }

   return $arguments
}

function Assert-WslTool {
   param(
      [Parameter(Mandatory = $true)][string] $Name,
      [string] $Distro = '',
      [string] $User = ''
   )

   $arguments = (Get-WslArguments -Distro $Distro -User $User) + @('bash', '-lc', "command -v $(Quote-ShArgument $Name) >/dev/null")
   & wsl.exe @arguments
   if ($LASTEXITCODE -ne 0) {
      throw "Ferramenta '$Name' nao foi encontrada no WSL. Instale os pacotes de build dentro da distro WSL."
   }
}

function Assert-WindowsMinGwToolchain {
   param(
      [Parameter(Mandatory = $true)][string] $Compiler
   )

   if ($Compiler -notlike 'mingw*') {
      return
   }

   $gcc = Get-Command 'gcc.exe' -ErrorAction SilentlyContinue
   if (-not $gcc) {
      throw "Perfil '$Compiler' requer MinGW-w64 no PATH, mas gcc.exe nao foi encontrado. Instale MSYS2/MinGW-w64 ou ajuste o PATH antes do Cygwin."
   }

   $gccPath = [string] $gcc.Source
   $dumpMachine = ''
   try {
      $dumpMachine = (& $gccPath -dumpmachine 2>$null | Select-Object -First 1)
   }
   catch {
      $dumpMachine = ''
   }

   if ($gccPath -match '\\cygwin(64)?\\' -or $dumpMachine -match 'cygwin') {
      throw "Perfil '$Compiler' encontrou gcc do Cygwin ($gccPath; target=$dumpMachine). Use o perfil 'cygwin' para esse toolchain ou coloque um MinGW-w64/MSYS2 gcc no PATH antes do Cygwin."
   }

   if ($dumpMachine -and $dumpMachine -notmatch 'mingw|w64') {
      throw "Perfil '$Compiler' encontrou gcc incompativel ($gccPath; target=$dumpMachine). Use um toolchain MinGW-w64/MSYS2."
   }
}

function Initialize-Runner {
   param(
      [Parameter(Mandatory = $true)][string] $Runner,
      [string] $CygwinBashPath = '',
      [string] $Distro = '',
      [string] $WslUserName = '',
      [string] $DockerImageName = '',
      [string] $DockerfilePath = '',
      [string] $DockerBuildContext = '',
      [string] $HarbourRootPath = '',
      [switch] $DryRun
   )

   switch ($Runner) {
      'windows' {
         return [pscustomobject]@{
            Name = 'windows'
            CygwinBash = ''
            WslArguments = @()
         }
      }
      'cygwin' {
         $bash = Resolve-CygwinBash -PreferredPath $CygwinBashPath
         if (-not $DryRun) {
            Assert-CygwinTool -BashPath $bash -Name 'make'
            Assert-CygwinTool -BashPath $bash -Name 'gcc'
         }

         return [pscustomobject]@{
            Name = 'cygwin'
            CygwinBash = $bash
            WslArguments = @()
         }
      }
      'wsl' {
         Assert-Command -Name 'wsl.exe' -Hint 'Instale/ative o WSL e uma distro Linux, ou use outro perfil.'
         if (-not $DryRun) {
            Assert-WslTool -Name 'make' -Distro $Distro -User $WslUserName
            Assert-WslTool -Name 'gcc' -Distro $Distro -User $WslUserName
         }

         return [pscustomobject]@{
            Name = 'wsl'
            CygwinBash = ''
            WslArguments = @(Get-WslArguments -Distro $Distro -User $WslUserName)
         }
      }
      'docker' {
         $dockerCommand = Resolve-DockerCommand -DryRun:$DryRun
         if ([string]::IsNullOrWhiteSpace($DockerImageName)) {
            throw "Imagem Docker nao configurada para o perfil."
         }
         if ([string]::IsNullOrWhiteSpace($DockerfilePath)) {
            throw "Dockerfile nao configurado para o perfil."
         }

         $pathMaps = New-Object System.Collections.Generic.List[object]
         $volumes = New-Object System.Collections.Generic.List[string]
         $projectRootFull = [System.IO.Path]::GetFullPath($DockerBuildContext)
         $pathMaps.Add([pscustomobject]@{
            HostRoot = $projectRootFull
            ContainerRoot = '/workspace'
         })
         $volumes.Add("${projectRootFull}:/workspace")

         if (-not [string]::IsNullOrWhiteSpace($HarbourRootPath) -and -not (Test-PathUnderRoot -Path $HarbourRootPath -Root $projectRootFull)) {
            $harbourRootFull = [System.IO.Path]::GetFullPath($HarbourRootPath)
            $pathMaps.Add([pscustomobject]@{
               HostRoot = $harbourRootFull
               ContainerRoot = '/harbour-src'
            })
            $volumes.Add("${harbourRootFull}:/harbour-src")
         }

         return [pscustomobject]@{
            Name = 'docker'
            CygwinBash = ''
            WslArguments = @()
            DockerCommand = $dockerCommand
            DockerImage = $DockerImageName
            Dockerfile = $DockerfilePath
            DockerBuildContext = $projectRootFull
            DockerPathMaps = @($pathMaps.ToArray())
            DockerVolumes = @($volumes.ToArray())
         }
      }
      default {
         throw "Runner desconhecido no perfil: $Runner"
      }
   }
}

function ConvertTo-CygwinPath {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][string] $BashPath
   )

   $converted = & $BashPath -lc "cygpath -au $(Quote-ShArgument $Path)"
   if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $converted)) {
      throw "Falha ao converter path para Cygwin: $Path"
   }

   return [string] ($converted | Select-Object -Last 1)
}

function ConvertTo-WslPath {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [string[]] $WslArguments = @()
   )

   $fullPath = [System.IO.Path]::GetFullPath($Path)
   $root = [System.IO.Path]::GetPathRoot($fullPath)
   if ($root -match '^([A-Za-z]):\\$') {
      $drive = $matches[1].ToLowerInvariant()
      $relative = $fullPath.Substring($root.Length).Replace('\', '/')
      if ([string]::IsNullOrWhiteSpace($relative)) {
         return "/mnt/$drive"
      }

      return "/mnt/$drive/$relative"
   }

   $converted = & wsl.exe @WslArguments wslpath -a $Path
   if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $converted)) {
      throw "Falha ao converter path para WSL: $Path"
   }

   return [string] ($converted | Select-Object -Last 1)
}

function ConvertTo-DockerPath {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)] $RunnerState
   )

   $fullPath = [System.IO.Path]::GetFullPath($Path)
   foreach ($map in @($RunnerState.DockerPathMaps)) {
      if (Test-PathUnderRoot -Path $fullPath -Root $map.HostRoot) {
         $hostRoot = [System.IO.Path]::GetFullPath([string] $map.HostRoot).TrimEnd('\')
         $containerRoot = ([string] $map.ContainerRoot).TrimEnd('/')
         if ($fullPath.TrimEnd('\').Equals($hostRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $containerRoot
         }

         $relative = $fullPath.Substring($hostRoot.Length).TrimStart('\').Replace('\', '/')
         return "$containerRoot/$relative"
      }
   }

   throw "Path nao esta montado no container Docker: $Path"
}

function Convert-PathForRunner {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)] $RunnerState
   )

   switch ($RunnerState.Name) {
      'cygwin' { return ConvertTo-CygwinPath -Path $Path -BashPath $RunnerState.CygwinBash }
      'wsl' { return ConvertTo-WslPath -Path $Path -WslArguments $RunnerState.WslArguments }
      'docker' { return ConvertTo-DockerPath -Path $Path -RunnerState $RunnerState }
      default { return $Path }
   }
}

function Convert-EnvValueForRunner {
   param(
      [Parameter(Mandatory = $true)][string] $Key,
      [string] $Value,
      [Parameter(Mandatory = $true)] $RunnerState
   )

   if ($RunnerState.Name -eq 'windows' -or [string]::IsNullOrWhiteSpace($Value)) {
      return $Value
   }

   if ($Key -eq 'HB_USER_LIBPATHS') {
      $parts = @($Value -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $convertedParts = foreach ($part in $parts) {
         if ([System.IO.Path]::IsPathRooted($part)) {
            Convert-PathForRunner -Path $part -RunnerState $RunnerState
         }
         else {
            $part
         }
      }

      return ($convertedParts -join ' ')
   }

   $isPathLike = $Key -eq 'HB_INSTALL_PREFIX' -or
      $Key -eq 'HB_HOST_BIN' -or
      $Key -eq 'HB_QTPATH' -or
      $Key -like 'HB_WITH_*'

   if ($isPathLike -and [System.IO.Path]::IsPathRooted($Value)) {
      return Convert-PathForRunner -Path $Value -RunnerState $RunnerState
   }

   return $Value
}

function Convert-EnvMapForRunner {
   param(
      [Parameter(Mandatory = $true)] $EnvMap,
      [Parameter(Mandatory = $true)] $RunnerState
   )

   $converted = [ordered]@{}
   foreach ($key in $EnvMap.Keys) {
      $converted[$key] = Convert-EnvValueForRunner -Key $key -Value ([string] $EnvMap[$key]) -RunnerState $RunnerState
   }

   return $converted
}

function New-ShellBuildScript {
   param(
      [Parameter(Mandatory = $true)][string] $HarbourRoot,
      [Parameter(Mandatory = $true)] $EnvMap,
      [Parameter(Mandatory = $true)][string[]] $MakeArgs,
      [string[]] $CleanMakeArgs = @(),
      [Parameter(Mandatory = $true)] $RunnerState
   )

   $targetRoot = Convert-PathForRunner -Path $HarbourRoot -RunnerState $RunnerState
   $assignments = foreach ($key in $EnvMap.Keys) {
      "$key=$(Quote-ShArgument ([string] $EnvMap[$key]))"
   }
   $commands = @()
   if ($CleanMakeArgs.Count -gt 0) {
      $cleanCommand = (@('make') + $CleanMakeArgs | ForEach-Object { Quote-ShArgument ([string] $_) }) -join ' '
      $commands += "env $($assignments -join ' ') $cleanCommand"
   }

   $makeCommand = (@('make') + $MakeArgs | ForEach-Object { Quote-ShArgument ([string] $_) }) -join ' '
   $commands += "env $($assignments -join ' ') $makeCommand"

   return "cd $(Quote-ShArgument $targetRoot) && $($commands -join ' && ')"
}

function New-DockerBuildArguments {
   param(
      [Parameter(Mandatory = $true)] $RunnerState,
      [string[]] $ExtraArgs = @()
   )

   return @('build', '-f', $RunnerState.Dockerfile, '-t', $RunnerState.DockerImage) + $ExtraArgs + @($RunnerState.DockerBuildContext)
}

function New-DockerRunArguments {
   param(
      [Parameter(Mandatory = $true)] $RunnerState,
      [Parameter(Mandatory = $true)][string] $ShellScript,
      [string[]] $ExtraArgs = @()
   )

   $arguments = @('run', '--rm')
   foreach ($volume in @($RunnerState.DockerVolumes)) {
      $arguments += @('-v', [string] $volume)
   }

   $arguments += @('-w', '/workspace')
   $arguments += $ExtraArgs
   $arguments += @($RunnerState.DockerImage, 'bash', '-lc', $ShellScript)
   return $arguments
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
$Runner = (Get-ConfigString -Config $ProfileConfig -Name 'runner' -Default 'windows').ToLowerInvariant()
$defaultDependencyMode = if ($Runner -eq 'windows') { 'vcpkg' } else { 'system' }
$DependencyMode = (Get-ConfigString -Config $ProfileConfig -Name 'dependencyMode' -Default $defaultDependencyMode).ToLowerInvariant()
$LoadExternalDeps = Get-ConfigBoolean -Config $ProfileConfig -Name 'loadExternalDeps' -Default ($Runner -eq 'windows')
$dockerImageName = ''
$dockerfilePath = ''

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

$makeExe = if ($Runner -eq 'windows') { Join-Path $HarbourRoot 'win-make.exe' } else { 'make' }
if ($Runner -eq 'windows' -and -not (Test-Path -LiteralPath $makeExe) -and ($harbourSourceReady -or -not $DryRun)) {
   throw "win-make.exe nao encontrado no HarbourRoot: $makeExe"
}

$makefile = Join-Path $HarbourRoot 'Makefile'
if (-not (Test-Path -LiteralPath $makefile) -and ($harbourSourceReady -or -not $DryRun)) {
   throw "Makefile do Harbour nao encontrado: $makefile"
}

New-Item -ItemType Directory -Force -Path $OutputRoot, $LogsRoot, $ToolsRoot | Out-Null
Add-LocalToolPaths -ToolsRoot $ToolsRoot

if ($Runner -eq 'docker') {
   $dockerImageDefault = if ($Full) {
      Get-ConfigString -Config $ProfileConfig -Name 'dockerFullImage' -Default 'hb-compile/linux:full'
   }
   else {
      Get-ConfigString -Config $ProfileConfig -Name 'dockerImage' -Default 'hb-compile/linux:base'
   }
   $dockerfileDefault = if ($Full) {
      Get-ConfigString -Config $ProfileConfig -Name 'dockerFullDockerfile' -Default 'config\docker\linux\Dockerfile.full'
   }
   else {
      Get-ConfigString -Config $ProfileConfig -Name 'dockerfile' -Default 'config\docker\linux\Dockerfile'
   }

   $dockerImageName = if ([string]::IsNullOrWhiteSpace($DockerImage)) { $dockerImageDefault } else { $DockerImage }
   $dockerfileValue = if ([string]::IsNullOrWhiteSpace($Dockerfile)) { $dockerfileDefault } else { $Dockerfile }
   $dockerfilePath = Resolve-ProjectPath $dockerfileValue
}

$runnerState = Initialize-Runner `
   -Runner $Runner `
   -CygwinBashPath $CygwinBash `
   -Distro $WslDistro `
   -WslUserName $WslUser `
   -DockerImageName $dockerImageName `
   -DockerfilePath $dockerfilePath `
   -DockerBuildContext $ProjectRoot `
   -HarbourRootPath $HarbourRoot `
   -DryRun:$DryRun

foreach ($requirement in (@($ProfileConfig.requires) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
   switch ($requirement) {
      'zig' {
         Assert-Command -Name 'zig.exe' -Hint 'Execute .\scripts\Bootstrap-Tools.ps1 -Tool Zig ou adicione o Zig ao PATH.'
      }
      'cygwin' {
         if ($runnerState.Name -ne 'cygwin') {
            throw "Perfil '$Profile' requer Cygwin, mas usa runner '$($runnerState.Name)'."
         }
      }
      'wsl' {
         if ($runnerState.Name -ne 'wsl') {
            throw "Perfil '$Profile' requer WSL, mas usa runner '$($runnerState.Name)'."
         }
      }
      'docker' {
         if ($runnerState.Name -ne 'docker') {
            throw "Perfil '$Profile' requer Docker, mas usa runner '$($runnerState.Name)'."
         }
      }
      default {
         throw "Pre-requisito desconhecido no perfil '$Profile': $requirement"
      }
   }
}

if (-not $NoVsDevShell -and ($ProfileConfig.autoVsDevShell -eq $true)) {
   Import-VsDevShell -Arch $VsArch
}

if ($Runner -eq 'windows' -and -not $DryRun) {
   Assert-WindowsMinGwToolchain -Compiler ([string] $ProfileConfig.env.HB_COMPILER)
}

$safeProfile = $Profile -replace '[^A-Za-z0-9_.-]', '_'
$generatedDeps = Join-Path $ProjectRoot "config\external-deps.generated.$safeProfile.ps1"
if ($Full) {
   if ($DependencyMode -eq 'vcpkg') {
      $resolver = Join-Path $ProjectRoot 'scripts\Resolve-HarbourDeps.ps1'
      if (-not (Test-Path -LiteralPath $resolver)) {
         throw "Resolvedor de dependencias nao encontrado: $resolver"
      }

      $resolverArgs = @{
         Set = $DependencySet
         Provider = $DependencyProvider
         GenerateEnv = $true
         GeneratedEnvPath = $generatedDeps
         HarbourCompiler = [string] $ProfileConfig.env.HB_COMPILER
         DependencyInstallTimeoutMinutes = $DependencyInstallTimeoutMinutes
      }

      if ($DependencyTriplet) {
         $resolverArgs.Triplet = $DependencyTriplet
      }
      if ($Dependency.Count -gt 0) {
         $resolverArgs.Dependency = $Dependency
      }
      if ($IgnoreDependency.Count -gt 0) {
         $resolverArgs.IgnoreDependency = $IgnoreDependency
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
   elseif ($DependencyMode -eq 'system') {
      Write-Host "Perfil '$Profile' usa dependencias do sistema; o resolvedor vcpkg do Windows sera ignorado."
   }
   else {
      throw "Modo de dependencia desconhecido no perfil '$Profile': $DependencyMode"
   }
}

if ($Full -and $LoadExternalDeps -and (Test-Path -LiteralPath $generatedDeps)) {
   . $generatedDeps
}

$externalDeps = Join-Path $ProjectRoot 'config\external-deps.local.ps1'
if ($LoadExternalDeps -and (Test-Path -LiteralPath $externalDeps)) {
   . $externalDeps
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

$ignoredDependencyNames = Expand-NameList -Values $IgnoreDependency
if ($ignoredDependencyNames.Count -gt 0) {
   $dependencyCatalogPath = Join-Path $ProjectRoot 'config\dependencies.json'
   if (-not (Test-Path -LiteralPath $dependencyCatalogPath)) {
      throw "Catalogo de dependencias nao encontrado: $dependencyCatalogPath"
   }

   $dependencyCatalog = Get-Content -LiteralPath $dependencyCatalogPath -Raw | ConvertFrom-Json
   foreach ($ignoredDependency in $ignoredDependencyNames) {
      $resolvedDependency = Resolve-DependencyName -Catalog $dependencyCatalog -Name $ignoredDependency
      $dependencyConfig = $dependencyCatalog.dependencies.$resolvedDependency
      if ($dependencyConfig.envVar) {
         $envMap[[string] $dependencyConfig.envVar] = 'no'
      }
   }
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

$requestedTargets = @($Targets)
if ($requestedTargets.Count -eq 0) {
   $requestedTargets = @('install')
}

$targetList = @()
$cleanTargetRequested = $false
foreach ($target in $requestedTargets) {
   if ([string] $target -ieq 'clean') {
      $cleanTargetRequested = $true
   }
   else {
      $targetList += $target
   }
}

$runCleanFirst = $Clean -or ($cleanTargetRequested -and $targetList.Count -gt 0)
if ($Clean -and $cleanTargetRequested -and $targetList.Count -eq 0) {
   $runCleanFirst = $false
   $targetList = @('clean')
}
elseif (-not $runCleanFirst -and $cleanTargetRequested -and $targetList.Count -eq 0) {
   $targetList = @('clean')
}
if ($targetList.Count -eq 0) {
   $targetList = @('install')
}

$cleanMakeArgs = @()
if ($runCleanFirst) {
   $cleanMakeArgs = @('clean') + @($MakeArg)
}
$makeArgs = @("-j$Jobs") + $targetList + $MakeArg
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeProfile = $Profile -replace '[^A-Za-z0-9_.-]', '_'
$logPath = Join-Path $LogsRoot "$stamp-$safeProfile.log"
$targetEnvMap = Convert-EnvMapForRunner -EnvMap $envMap -RunnerState $runnerState
$shellScript = ''
if ($runnerState.Name -ne 'windows') {
   $shellScript = New-ShellBuildScript -HarbourRoot $HarbourRoot -EnvMap $targetEnvMap -MakeArgs $makeArgs -CleanMakeArgs $cleanMakeArgs -RunnerState $runnerState
}
$dockerBuildArgs = @()
$dockerRunArgs = @()
if ($runnerState.Name -eq 'docker') {
   $effectiveDockerBuildArg = @($DockerBuildArg)
   $hasQtBuildArg = @($effectiveDockerBuildArg | Where-Object { [string] $_ -match 'INSTALL_QT' }).Count -gt 0
   if ($Full -and -not $hasQtBuildArg -and (@($ignoredDependencyNames | Where-Object { $_ -ieq 'qt' }).Count -gt 0)) {
      $effectiveDockerBuildArg += @('--build-arg', 'INSTALL_QT=0')
   }

   $dockerBuildArgs = New-DockerBuildArguments -RunnerState $runnerState -ExtraArgs $effectiveDockerBuildArg
   $dockerRunArgs = New-DockerRunArguments -RunnerState $runnerState -ShellScript $shellScript -ExtraArgs $DockerArg
}

$cleanCommandDisplay = if ($cleanMakeArgs.Count -gt 0 -and $runnerState.Name -eq 'windows') {
   "$(Format-ProjectPath $makeExe) $($cleanMakeArgs -join ' ')"
}
else {
   ''
}

$commandDisplay = if ($runnerState.Name -eq 'windows') {
   "$(Format-ProjectPath $makeExe) $($makeArgs -join ' ')"
}
elseif ($runnerState.Name -eq 'cygwin') {
   "$(Format-ProjectPath $runnerState.CygwinBash) -lc $(Quote-ShArgument $shellScript)"
}
elseif ($runnerState.Name -eq 'docker') {
   "$($runnerState.DockerCommand) $(($dockerRunArgs | ForEach-Object { Format-CommandArgument ([string] $_) }) -join ' ')"
}
else {
   $wslPrefix = if ($runnerState.WslArguments.Count -gt 0) { "wsl.exe $($runnerState.WslArguments -join ' ')" } else { 'wsl.exe' }
   "$wslPrefix bash -lc $(Quote-ShArgument $shellScript)"
}
$dockerBuildDisplay = ''
if ($runnerState.Name -eq 'docker' -and -not $SkipDockerBuild) {
   $dockerBuildDisplay = "$($runnerState.DockerCommand) $(($dockerBuildArgs | ForEach-Object { Format-CommandArgument ([string] $_) }) -join ' ')"
}

Write-Host "HarbourRoot : $(Format-ProjectPath $HarbourRoot)"
Write-Host "Perfil      : $Profile"
Write-Host "Runner      : $($runnerState.Name)"
if ($runnerState.Name -eq 'docker') {
   Write-Host "DockerImage : $($runnerState.DockerImage)"
   Write-Host "Dockerfile  : $(Format-ProjectPath $runnerState.Dockerfile)"
}
Write-Host "Install     : $(Format-ProjectPath $installRoot)"
Write-Host "Log         : $(Format-ProjectPath $logPath)"
if (-not [string]::IsNullOrWhiteSpace($dockerBuildDisplay)) {
   Write-Host "DockerBuild : $dockerBuildDisplay"
}
if (-not [string]::IsNullOrWhiteSpace($cleanCommandDisplay)) {
   Write-Host "Limpeza     : $cleanCommandDisplay"
}
Write-Host "Comando     : $commandDisplay"
Write-Host ''
Write-Host 'Ambiente Harbour:'
foreach ($key in $targetEnvMap.Keys) {
   Write-Host ("  {0}={1}" -f $key, (Format-DisplayValue $targetEnvMap[$key]))
}
Write-Host ''

if ($DryRun) {
   Write-Host 'DryRun ativo: nenhum build foi iniciado.'
   return
}

$exitCode = 0
if ($runnerState.Name -eq 'windows') {
   $oldEnv = @{}
   foreach ($key in $targetEnvMap.Keys) {
      $oldEnv[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
      [System.Environment]::SetEnvironmentVariable($key, $targetEnvMap[$key], 'Process')
   }

   try {
      Push-Location $HarbourRoot
      try {
         $previousErrorActionPreference = $ErrorActionPreference
         $ErrorActionPreference = 'Continue'
         try {
             if ($cleanMakeArgs.Count -gt 0) {
                & $makeExe @cleanMakeArgs 2>&1 |
                   ForEach-Object { $_.ToString() } |
                   Tee-Object -FilePath $logPath
                $exitCode = $LASTEXITCODE
             }

             if ($exitCode -eq 0) {
                $teeArgs = @{
                   FilePath = $logPath
                }
                if ($cleanMakeArgs.Count -gt 0) {
                   $teeArgs['Append'] = $true
                }

                & $makeExe @makeArgs 2>&1 |
                   ForEach-Object { $_.ToString() } |
                   Tee-Object @teeArgs
                $exitCode = $LASTEXITCODE
             }
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
      foreach ($key in $targetEnvMap.Keys) {
         [System.Environment]::SetEnvironmentVariable($key, $oldEnv[$key], 'Process')
      }
   }
}
else {
   $previousErrorActionPreference = $ErrorActionPreference
   $ErrorActionPreference = 'Continue'
   try {
      if ($runnerState.Name -eq 'cygwin') {
         & $runnerState.CygwinBash -lc $shellScript 2>&1 |
            ForEach-Object { $_.ToString() } |
            Tee-Object -FilePath $logPath
      }
      elseif ($runnerState.Name -eq 'docker') {
         if (-not $SkipDockerBuild) {
            if (-not (Test-Path -LiteralPath $runnerState.Dockerfile)) {
               throw "Dockerfile nao encontrado: $($runnerState.Dockerfile)"
            }

            $dockerBuildLogPath = Join-Path $LogsRoot "$stamp-$safeProfile-docker-build.log"
            Write-Host "Preparando imagem Docker: $($runnerState.DockerImage)"
            & $runnerState.DockerCommand @dockerBuildArgs 2>&1 |
               ForEach-Object { $_.ToString() } |
               Tee-Object -FilePath $dockerBuildLogPath
            if ($LASTEXITCODE -ne 0) {
               throw "docker build falhou com codigo $LASTEXITCODE. Veja o log: $dockerBuildLogPath"
            }
         }

         & $runnerState.DockerCommand @dockerRunArgs 2>&1 |
            ForEach-Object { $_.ToString() } |
            Tee-Object -FilePath $logPath
      }
      else {
         $wslProcessArgs = @($runnerState.WslArguments) + @('bash', '-lc', $shellScript)
         & wsl.exe @wslProcessArgs 2>&1 |
            ForEach-Object { $_.ToString() } |
            Tee-Object -FilePath $logPath
      }
      $exitCode = $LASTEXITCODE
   }
   finally {
      $ErrorActionPreference = $previousErrorActionPreference
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
