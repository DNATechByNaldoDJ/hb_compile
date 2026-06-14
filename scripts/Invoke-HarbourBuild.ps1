[CmdletBinding()]
param(
   [Alias('Profile')]
   [string] $BuildProfile = 'auto',
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
   [switch] $InstallSystemDependencies,
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
   [string] $ZigPath = '',
   [string] $MinGwPath = '',
   [switch] $SkipToolBootstrap,
   [string] $CygwinSetup = '',
   [string] $CygwinBash = '',
   [string] $MsysBash = '',
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

function Get-MinGwGccProbe {
   param([string] $GccPath = '')

   if ([string]::IsNullOrWhiteSpace($GccPath)) {
      $commands = @(
         'x86_64-w64-mingw32-gcc.exe',
         'gcc.exe',
         'x86_64-w64-mingw32-gcc',
         'gcc'
      )
      $firstInvalid = $null
      foreach ($commandName in $commands) {
         $gcc = Get-Command $commandName -ErrorAction SilentlyContinue
         if (-not $gcc) {
            continue
         }

         $probe = Get-MinGwGccProbe -GccPath ([string] $gcc.Source)
         if ($probe.Valid) {
            return $probe
         }

         if (-not $firstInvalid) {
            $firstInvalid = $probe
         }
      }

      if ($firstInvalid) {
         return $firstInvalid
      }

      return [pscustomobject]@{
         Found = $false
         Valid = $false
         Path = ''
         DumpMachine = ''
         Prefix = ''
         BinDir = ''
         Reason = 'gcc.exe MinGW-w64 nao foi encontrado no PATH.'
      }
   }

   if (-not (Test-Path -LiteralPath $GccPath)) {
      return [pscustomobject]@{
         Found = $false
         Valid = $false
         Path = $GccPath
         DumpMachine = ''
         Prefix = ''
         BinDir = ''
         Reason = "gcc.exe nao encontrado: $GccPath"
      }
   }

   $dumpMachine = ''
   try {
      $dumpMachine = (& $GccPath -dumpmachine 2>$null | Select-Object -First 1)
   }
   catch {
      $dumpMachine = ''
   }

   $leafName = [System.IO.Path]::GetFileName($GccPath)
   $prefix = ''
   if ($leafName -match '^(?<prefix>.+-)gcc(?:-\d[\d.]*)?\.exe$') {
      $prefix = [string] $Matches.prefix
   }

   $valid = $dumpMachine -match '^x86_64-.*(mingw|w64)' -and $dumpMachine -notmatch 'cygwin' -and $GccPath -notmatch '\\cygwin(64)?\\'
   $reason = if ($valid) {
      ''
   }
   elseif ($GccPath -match '\\cygwin(64)?\\' -or $dumpMachine -match 'cygwin') {
      "gcc do Cygwin encontrado ($GccPath; target=$dumpMachine)."
   }
   elseif ([string]::IsNullOrWhiteSpace($dumpMachine)) {
      "Nao foi possivel executar '$GccPath -dumpmachine'."
   }
   elseif ($dumpMachine -notmatch '^x86_64-') {
      "gcc MinGW incompativel encontrado ($GccPath; target=$dumpMachine); o perfil mingw64 requer x86_64."
   }
   else {
      "gcc incompativel encontrado ($GccPath; target=$dumpMachine)."
   }

   return [pscustomobject]@{
      Found = $true
      Valid = $valid
      Path = $GccPath
      DumpMachine = $dumpMachine
      Prefix = $prefix
      BinDir = [System.IO.Path]::GetDirectoryName($GccPath)
      Reason = $reason
   }
}

function Get-ZigProbe {
   param([string] $ZigPath = '')

   if ([string]::IsNullOrWhiteSpace($ZigPath)) {
      $zig = Get-Command 'zig.exe' -ErrorAction SilentlyContinue
      if (-not $zig) {
         $zig = Get-Command 'zig' -ErrorAction SilentlyContinue
      }

      if (-not $zig) {
         return [pscustomobject]@{
            Found = $false
            Valid = $false
            Path = ''
            Version = ''
            Reason = 'zig.exe nao foi encontrado no PATH.'
         }
      }

      $ZigPath = [string] $zig.Source
   }

   if (-not (Test-Path -LiteralPath $ZigPath)) {
      return [pscustomobject]@{
         Found = $false
         Valid = $false
         Path = $ZigPath
         Version = ''
         Reason = "zig.exe nao encontrado: $ZigPath"
      }
   }

   $version = ''
   try {
      $version = (& $ZigPath version 2>$null | Select-Object -First 1).Trim()
   }
   catch {
      $version = ''
   }

   $valid = -not [string]::IsNullOrWhiteSpace($version)
   $reason = if ($valid) {
      ''
   }
   else {
      "Nao foi possivel executar '$ZigPath version'."
   }

   return [pscustomobject]@{
      Found = $true
      Valid = $valid
      Path = $ZigPath
      Version = $version
      Reason = $reason
   }
}

function Find-MinGwGccInRoot {
   param([Parameter(Mandatory = $true)][string] $Root)

   if (-not (Test-Path -LiteralPath $Root)) {
      return $null
   }

   $rootFull = [System.IO.Path]::GetFullPath($Root)
   $directCandidates = @(
      (Join-Path $rootFull 'gcc.exe'),
      (Join-Path $rootFull 'bin\gcc.exe'),
      (Join-Path $rootFull 'mingw64\bin\gcc.exe'),
      (Join-Path $rootFull 'x86_64-w64-mingw32-gcc.exe'),
      (Join-Path $rootFull 'bin\x86_64-w64-mingw32-gcc.exe'),
      (Join-Path $rootFull 'mingw64\bin\x86_64-w64-mingw32-gcc.exe')
   )

   foreach ($candidate in $directCandidates) {
      $probe = Get-MinGwGccProbe -GccPath $candidate
      if ($probe.Valid) {
         return (Get-Item -LiteralPath $candidate)
      }
   }

   return Get-ChildItem -LiteralPath $rootFull -Filter '*gcc.exe' -Recurse -ErrorAction SilentlyContinue |
      Where-Object { (Get-MinGwGccProbe -GccPath $_.FullName).Valid } |
      Sort-Object -Property FullName |
      Select-Object -First 1
}

function Find-ZigExeInRoot {
   param([Parameter(Mandatory = $true)][string] $Root)

   if (-not (Test-Path -LiteralPath $Root)) {
      return $null
   }

   $rootFull = [System.IO.Path]::GetFullPath($Root)
   if ((Test-Path -LiteralPath $rootFull -PathType Leaf) -and
      ([System.IO.Path]::GetFileName($rootFull) -ieq 'zig.exe')) {
      $probe = Get-ZigProbe -ZigPath $rootFull
      if ($probe.Valid) {
         return (Get-Item -LiteralPath $rootFull)
      }
   }

   $directCandidates = @(
      (Join-Path $rootFull 'zig.exe'),
      (Join-Path $rootFull 'bin\zig.exe')
   )

   foreach ($candidate in $directCandidates) {
      $probe = Get-ZigProbe -ZigPath $candidate
      if ($probe.Valid) {
         return (Get-Item -LiteralPath $candidate)
      }
   }

   return Get-ChildItem -LiteralPath $rootFull -Filter 'zig.exe' -Recurse -ErrorAction SilentlyContinue |
      Where-Object { (Get-ZigProbe -ZigPath $_.FullName).Valid } |
      Sort-Object -Property FullName |
      Select-Object -First 1
}

function Add-PathPrefix {
   param([Parameter(Mandatory = $true)][string] $Directory)

   $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
   $parts = @($env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
   $alreadyPresent = @($parts | Where-Object { $_.TrimEnd('\') -ieq $fullDirectory.TrimEnd('\') }).Count -gt 0
   if (-not $alreadyPresent) {
      $env:PATH = "$fullDirectory;$env:PATH"
   }
}

function Add-MinGwToolchainPath {
   param([Parameter(Mandatory = $true)][string] $Path)

   $fullPath = Resolve-ProjectPath $Path
   $gcc = Find-MinGwGccInRoot -Root $fullPath
   if (-not $gcc) {
      throw "MinGW-w64 nao encontrado em '$Path'. Informe a pasta que contem bin\gcc.exe. A pasta de fontes mingw-w64 nao e um toolchain compilado."
   }

   Add-PathPrefix -Directory $gcc.Directory.FullName
   $probe = Get-MinGwGccProbe -GccPath $gcc.FullName
   Write-Host "Usando MinGW-w64: $($probe.Path) ($($probe.DumpMachine))"
}

function Add-ZigToolchainPath {
   param([Parameter(Mandatory = $true)][string] $Path)

   $fullPath = Resolve-ProjectPath $Path
   $zig = Find-ZigExeInRoot -Root $fullPath
   if (-not $zig) {
      throw "Zig nao encontrado em '$Path'. Informe zig.exe ou a pasta que contem zig.exe."
   }

   Add-PathPrefix -Directory $zig.Directory.FullName
   $probe = Get-ZigProbe -ZigPath $zig.FullName
   Write-Host "Usando Zig: $($probe.Path) ($($probe.Version))"
}

function Add-LocalToolPaths {
   param([Parameter(Mandatory = $true)][string] $ToolsRoot)

   $mingwRoot = Join-Path $ToolsRoot 'mingw64'
   if (Test-Path -LiteralPath $mingwRoot) {
      $gcc = Find-MinGwGccInRoot -Root $mingwRoot
      if ($gcc) {
         Add-PathPrefix -Directory $gcc.Directory.FullName
      }
   }

   $zigRoot = Join-Path $ToolsRoot 'zig'
   if (Test-Path -LiteralPath $zigRoot) {
      $zig = Find-ZigExeInRoot -Root $zigRoot
      if ($zig) {
         Add-PathPrefix -Directory $zig.Directory.FullName
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

function Invoke-BashProbe {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][string] $Script,
      [int] $TimeoutSeconds = 5
   )

   $process = $null
   try {
      $startInfo = New-Object System.Diagnostics.ProcessStartInfo
      $startInfo.FileName = $Path
      $startInfo.Arguments = "-lc $(Format-CommandArgument $Script)"
      $startInfo.UseShellExecute = $false
      $startInfo.CreateNoWindow = $true
      $startInfo.RedirectStandardOutput = $true
      $startInfo.RedirectStandardError = $true

      $process = New-Object System.Diagnostics.Process
      $process.StartInfo = $startInfo
      [void] $process.Start()

      if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
         try {
            $process.Kill()
         }
         catch {
         }

         return [pscustomobject]@{
            ExitCode = -1
            StdOut = ''
            StdErr = 'timeout'
         }
      }

      return [pscustomobject]@{
         ExitCode = $process.ExitCode
         StdOut = $process.StandardOutput.ReadToEnd()
         StdErr = $process.StandardError.ReadToEnd()
      }
   }
   catch {
      return [pscustomobject]@{
         ExitCode = -1
         StdOut = ''
         StdErr = $_.Exception.Message
      }
   }
   finally {
      if ($process) {
         $process.Dispose()
      }
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

function Format-ShArgument {
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

function Get-DependencyCatalog {
   $dependencyCatalogPath = Join-Path $ProjectRoot 'config\dependencies.json'
   if (-not (Test-Path -LiteralPath $dependencyCatalogPath)) {
      throw "Catalogo de dependencias nao encontrado: $dependencyCatalogPath"
   }

   return Get-Content -LiteralPath $dependencyCatalogPath -Raw | ConvertFrom-Json
}

function Add-UniqueString {
   param(
      [Parameter(Mandatory = $true)] $List,
      [string[]] $Values
   )

   foreach ($value in @($Values)) {
      $trimmed = ([string] $value).Trim()
      if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $List.Contains($trimmed)) {
         $List.Add($trimmed)
      }
   }
}

function Get-RequestedDependencyNames {
   param(
      [Parameter(Mandatory = $true)] $Catalog,
      [Parameter(Mandatory = $true)][string] $Set,
      [string[]] $Dependencies = @(),
      [string[]] $IgnoredDependencies = @()
   )

   $requested = New-Object System.Collections.Generic.List[string]
   $expandedDependencies = Expand-NameList -Values $Dependencies
   if ($expandedDependencies.Count -gt 0) {
      foreach ($dependency in $expandedDependencies) {
         Add-UniqueString -List $requested -Values @(Resolve-DependencyName -Catalog $Catalog -Name $dependency)
      }
   }
   else {
      $setProperty = $Catalog.sets.PSObject.Properties[$Set]
      if (-not $setProperty) {
         throw "Conjunto de dependencias desconhecido: $Set"
      }

      foreach ($dependency in @($setProperty.Value)) {
         Add-UniqueString -List $requested -Values @(Resolve-DependencyName -Catalog $Catalog -Name ([string] $dependency))
      }
   }

   $ignored = Expand-NameList -Values $IgnoredDependencies
   foreach ($ignoredDependency in $ignored) {
      $resolvedIgnored = Resolve-DependencyName -Catalog $Catalog -Name $ignoredDependency
      for ($index = $requested.Count - 1; $index -ge 0; $index--) {
         if ($requested[$index].Equals($resolvedIgnored, [System.StringComparison]::OrdinalIgnoreCase)) {
            $requested.RemoveAt($index)
         }
      }
   }

   return @($requested.ToArray())
}

function Get-SystemDependencyPlan {
   param(
      [Parameter(Mandatory = $true)][string] $Runner,
      [Parameter(Mandatory = $true)][string[]] $Dependencies
   )

   $packages = New-Object System.Collections.Generic.List[string]
   $manual = New-Object System.Collections.Generic.List[string]

   switch ($Runner) {
      'cygwin' {
         Add-UniqueString -List $packages -Values @(
            'gcc-core', 'make', 'binutils', 'git', 'pkg-config',
            'zlib-devel', 'libpcre-devel', 'libncurses-devel',
            'libslang-devel', 'libX11-devel', 'libsqlite3-devel',
            'libbz2-devel', 'libexpat-devel', 'unixODBC-devel',
            'libcups-devel'
         )

         $map = @{
            openssl = @('openssl-devel')
            curl = @('libcurl-devel')
            mysql = @('libmariadb-devel')
            pgsql = @('libpq-devel')
            cairo = @('libcairo-devel')
            freeimage = @('libfreeimage-devel')
            gd = @('libgd-devel')
            libmagic = @('libmagic-devel')
            ghostscript = @('ghostscript', 'libgs-devel')
         }
      }
      'msys' {
         Add-UniqueString -List $packages -Values @(
            'base-devel', 'make', 'binutils', 'gcc', 'git', 'pkgconf',
            'zlib-devel', 'pcre-devel', 'ncurses-devel', 'libsqlite-devel'
         )

         $map = @{
            openssl = @('openssl-devel')
            curl = @('libcurl-devel')
         }
      }
      'wsl' {
         Add-UniqueString -List $packages -Values @(
            'build-essential', 'git', 'make', 'binutils', 'pkg-config',
            'ca-certificates', 'file', 'zlib1g-dev', 'libpcre3-dev',
            'libncurses-dev', 'libslang2-dev', 'libx11-dev',
            'libsqlite3-dev', 'libbz2-dev', 'libexpat1-dev',
            'libcups2-dev', 'unixodbc-dev'
         )

         $map = @{
            openssl = @('libssl-dev')
            curl = @('libcurl4-openssl-dev')
            mysql = @('default-libmysqlclient-dev')
            pgsql = @('libpq-dev')
            qt = @('qt6-base-dev', 'qt6-base-dev-tools')
            cairo = @('libcairo2-dev')
            freeimage = @('libfreeimage-dev')
            gd = @('libgd-dev')
            libmagic = @('libmagic-dev')
            firebird = @('firebird-dev')
            ghostscript = @('ghostscript', 'libgs-dev')
            allegro = @('liballegro4-dev')
         }
      }
      'docker' {
         return [pscustomobject]@{
            Packages = @()
            Manual = @()
            Message = 'Docker instala dependencias do full durante o docker build usando config\docker\linux\Dockerfile.full.'
         }
      }
      default {
         return [pscustomobject]@{
            Packages = @()
            Manual = @()
            Message = "Runner '$Runner' nao tem instalador de dependencias do sistema."
         }
      }
   }

   foreach ($dependency in @($Dependencies)) {
      if ($map.ContainsKey($dependency)) {
         Add-UniqueString -List $packages -Values @($map[$dependency])
      }
      else {
         Add-UniqueString -List $manual -Values @($dependency)
      }
   }

   return [pscustomobject]@{
      Packages = @($packages.ToArray())
      Manual = @($manual.ToArray())
      Message = ''
   }
}

function Resolve-CygwinSetup {
   param(
      [string] $PreferredPath = '',
      [string] $BashPath = ''
   )

   $candidates = New-Object System.Collections.Generic.List[string]
   if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
      $candidates.Add($PreferredPath)
   }

   if (-not [string]::IsNullOrWhiteSpace($BashPath)) {
      $cygwinBin = Split-Path -Parent ([System.IO.Path]::GetFullPath($BashPath))
      $cygwinRoot = Split-Path -Parent $cygwinBin
      $candidates.Add((Join-Path $cygwinRoot 'setup-x86_64.exe'))
      $candidates.Add((Join-Path $cygwinRoot 'setup-x86.exe'))
   }

   foreach ($path in @(
      (Join-Path $ProjectRoot 'tools\setup-x86_64.exe'),
      'C:\cygwin64\setup-x86_64.exe',
      'C:\cygwin\setup-x86.exe',
      (Join-Path $env:USERPROFILE 'Downloads\setup-x86_64.exe')
   )) {
      $candidates.Add($path)
   }

   foreach ($candidate in ($candidates | Select-Object -Unique)) {
      if (Test-Path -LiteralPath $candidate) {
         return [System.IO.Path]::GetFullPath($candidate)
      }
   }

   throw 'setup-x86_64.exe do Cygwin nao foi encontrado. Baixe em https://cygwin.com/install.html ou informe -CygwinSetup C:\caminho\setup-x86_64.exe.'
}

function Invoke-SystemDependencyInstall {
   param(
      [Parameter(Mandatory = $true)][string] $Runner,
      [Parameter(Mandatory = $true)] $RunnerState,
      [string[]] $Packages = @(),
      [string[]] $Manual = @(),
      [string] $CygwinSetupPath = '',
      [string[]] $WslArguments = @(),
      [switch] $DryRun
   )

   if ($Packages.Count -eq 0) {
      return
   }

   if ($Manual.Count -gt 0) {
      Write-Warning "Dependencias sem pacote automatico para '$Runner': $($Manual -join ', '). Configure manualmente ou ignore com -IgnoreDependency."
   }

   switch ($Runner) {
      'cygwin' {
         $setup = Resolve-CygwinSetup -PreferredPath $CygwinSetupPath -BashPath $RunnerState.CygwinBash
         $cygwinRoot = Split-Path -Parent (Split-Path -Parent ([System.IO.Path]::GetFullPath($RunnerState.CygwinBash)))
         $arguments = @('--quiet-mode', '--root', $cygwinRoot, '--packages', ($Packages -join ','))
         if ($DryRun) {
            Write-Host "DryRun: $setup $($arguments -join ' ')"
            return
         }

         Write-Host "Instalando dependencias Cygwin: $($Packages -join ', ')"
         & $setup @arguments
         if ($LASTEXITCODE -ne 0) {
            throw "Instalacao de dependencias Cygwin falhou com codigo $LASTEXITCODE."
         }
      }
      'msys' {
         $script = "pacman -S --needed --noconfirm $(($Packages | ForEach-Object { Format-ShArgument ([string] $_) }) -join ' ')"
         if ($DryRun) {
            Write-Host "DryRun: $($RunnerState.MsysBash) -lc $(Format-ShArgument $script)"
            return
         }

         Write-Host "Instalando dependencias MSYS2: $($Packages -join ', ')"
         & $RunnerState.MsysBash -lc $script
         if ($LASTEXITCODE -ne 0) {
            throw "Instalacao de dependencias MSYS2 falhou com codigo $LASTEXITCODE. Rode 'pacman -Syu' no shell MSYS e tente novamente."
         }
      }
      'wsl' {
         $packageList = ($Packages | ForEach-Object { Format-ShArgument ([string] $_) }) -join ' '
         $script = "if [ `$(id -u) -eq 0 ]; then SUDO=; else SUDO=sudo; fi; `$SUDO apt-get update && `$SUDO apt-get install -y --no-install-recommends $packageList"
         $arguments = @($WslArguments) + @('bash', '-lc', $script)
         if ($DryRun) {
            $prefix = if ($WslArguments.Count -gt 0) { "wsl.exe $($WslArguments -join ' ')" } else { 'wsl.exe' }
            Write-Host "DryRun: $prefix bash -lc $(Format-ShArgument $script)"
            return
         }

         Write-Host "Instalando dependencias WSL: $($Packages -join ', ')"
         & wsl.exe @arguments
         if ($LASTEXITCODE -ne 0) {
            throw "Instalacao de dependencias WSL falhou com codigo $LASTEXITCODE."
         }
      }
      default {
         Write-Host "Instalacao automatica de dependencias nao se aplica ao runner '$Runner'."
      }
   }
}

function Test-CygwinBash {
   param([Parameter(Mandatory = $true)][string] $Path)

   if (-not (Test-Path -LiteralPath $Path)) {
      return $false
   }

   try {
      $probe = Invoke-BashProbe -Path $Path -Script 'uname -s'
      return ($probe.ExitCode -eq 0 -and $probe.StdOut -match 'CYGWIN')
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
   if ($pathBash -and ([string] $pathBash.Source) -notmatch '\\Windows\\System32\\bash\.exe$') {
      $candidates.Add($pathBash.Source)
   }

   foreach ($candidate in ($candidates | Select-Object -Unique)) {
      if (Test-CygwinBash -Path $candidate) {
         return [System.IO.Path]::GetFullPath($candidate)
      }
   }

   throw 'bash.exe do Cygwin nao foi encontrado. Instale Cygwin ou informe -CygwinBash C:\cygwin64\bin\bash.exe.'
}

function Test-MsysBash {
   param([Parameter(Mandatory = $true)][string] $Path)

   if (-not (Test-Path -LiteralPath $Path)) {
      return $false
   }

   try {
      $probe = Invoke-BashProbe -Path $Path -Script 'uname -s'
      return ($probe.ExitCode -eq 0 -and $probe.StdOut -match 'MSYS|MINGW')
   }
   catch {
      return $false
   }
}

function Resolve-MsysBash {
   param([string] $PreferredPath)

   $candidates = New-Object System.Collections.Generic.List[string]
   if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
      $candidates.Add($PreferredPath)
   }

   foreach ($path in @(
      'C:\msys64\usr\bin\bash.exe',
      'C:\msys32\usr\bin\bash.exe',
      'C:\tools\msys64\usr\bin\bash.exe'
   )) {
      $candidates.Add($path)
   }

   $pathBash = Get-Command 'bash.exe' -ErrorAction SilentlyContinue
   if ($pathBash -and ([string] $pathBash.Source) -notmatch '\\Windows\\System32\\bash\.exe$') {
      $candidates.Add($pathBash.Source)
   }

   foreach ($candidate in ($candidates | Select-Object -Unique)) {
      if (Test-MsysBash -Path $candidate) {
         return [System.IO.Path]::GetFullPath($candidate)
      }
   }

   throw 'bash.exe do MSYS2 nao foi encontrado. Instale MSYS2 ou informe -MsysBash C:\msys64\usr\bin\bash.exe.'
}

function Assert-CygwinTool {
   param(
      [Parameter(Mandatory = $true)][string] $BashPath,
      [Parameter(Mandatory = $true)][string] $Name
   )

   & $BashPath -lc "command -v $(Format-ShArgument $Name) >/dev/null"
   if ($LASTEXITCODE -ne 0) {
      throw "Ferramenta '$Name' nao foi encontrada dentro do Cygwin. Instale o pacote correspondente pelo setup do Cygwin."
   }
}

function Assert-MsysTool {
   param(
      [Parameter(Mandatory = $true)][string] $BashPath,
      [Parameter(Mandatory = $true)][string] $Name
   )

   & $BashPath -lc "command -v $(Format-ShArgument $Name) >/dev/null"
   if ($LASTEXITCODE -ne 0) {
      throw "Ferramenta '$Name' nao foi encontrada dentro do MSYS2. Instale o pacote correspondente com pacman."
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

   $arguments = (Get-WslArguments -Distro $Distro -User $User) + @('bash', '-lc', "command -v $(Format-ShArgument $Name) >/dev/null")
   & wsl.exe @arguments
   if ($LASTEXITCODE -ne 0) {
      throw "Ferramenta '$Name' nao foi encontrada no WSL. Instale os pacotes de build dentro da distro WSL."
   }
}

function Assert-WindowsMinGwToolchain {
   param(
      [Parameter(Mandatory = $true)][string] $Compiler,
      [Parameter(Mandatory = $true)][string] $ToolsRoot,
      [string] $ExplicitPath = '',
      [switch] $SkipBootstrap,
      [switch] $DryRun
   )

   if ($Compiler -notlike 'mingw*') {
      return
   }

   if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
      Add-MinGwToolchainPath -Path $ExplicitPath
   }

   $probe = Get-MinGwGccProbe
   if ($probe.Valid) {
      Write-Host "Toolchain MinGW-w64 detectado: $($probe.Path) ($($probe.DumpMachine))"
      return $probe
   }

   if (-not $SkipBootstrap) {
      $bootstrap = Join-Path $ProjectRoot 'scripts\Bootstrap-Tools.ps1'
      if (-not (Test-Path -LiteralPath $bootstrap)) {
         throw "Bootstrap de ferramentas nao encontrado: $bootstrap"
      }

      if ($DryRun) {
         Write-Host "DryRun: .\scripts\Bootstrap-Tools.ps1 -Tool MinGW64"
         return
      }

      Write-Host "MinGW-w64 valido nao encontrado ($($probe.Reason)). Baixando toolchain portatil..."
      & $bootstrap -Tool MinGW64
      if (-not $?) {
         throw 'Falha ao baixar MinGW-w64.'
      }

      Add-LocalToolPaths -ToolsRoot $ToolsRoot
      $probe = Get-MinGwGccProbe
      if ($probe.Valid) {
         Write-Host "Toolchain MinGW-w64 detectado: $($probe.Path) ($($probe.DumpMachine))"
         return $probe
      }
   }

   if ($probe.Path -match '\\cygwin(64)?\\' -or $probe.DumpMachine -match 'cygwin') {
      throw "Perfil '$Compiler' encontrou gcc do Cygwin ($($probe.Path); target=$($probe.DumpMachine)). Use -MinGwPath para informar um toolchain MinGW-w64, execute .\scripts\Bootstrap-Tools.ps1 -Tool MinGW64, ou coloque MinGW-w64/MSYS2 no PATH antes do Cygwin."
   }

   throw "Perfil '$Compiler' requer MinGW-w64, mas $($probe.Reason) Use -MinGwPath, execute .\scripts\Bootstrap-Tools.ps1 -Tool MinGW64, ou ajuste o PATH."
}

function Assert-ZigToolchain {
   param(
      [Parameter(Mandatory = $true)][string] $ToolsRoot,
      [string] $ExplicitPath = '',
      [switch] $SkipBootstrap,
      [switch] $DryRun
   )

   if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
      Add-ZigToolchainPath -Path $ExplicitPath
   }

   $probe = Get-ZigProbe
   if ($probe.Valid) {
      Write-Host "Toolchain Zig detectado: $($probe.Path) ($($probe.Version))"
      return
   }

   if (-not $SkipBootstrap) {
      $bootstrap = Join-Path $ProjectRoot 'scripts\Bootstrap-Tools.ps1'
      if (-not (Test-Path -LiteralPath $bootstrap)) {
         throw "Bootstrap de ferramentas nao encontrado: $bootstrap"
      }

      if ($DryRun) {
         Write-Host "DryRun: .\scripts\Bootstrap-Tools.ps1 -Tool Zig"
         return
      }

      Write-Host "Zig valido nao encontrado ($($probe.Reason)). Baixando toolchain portatil..."
      & $bootstrap -Tool Zig
      if (-not $?) {
         throw 'Falha ao baixar Zig.'
      }

      Add-LocalToolPaths -ToolsRoot $ToolsRoot
      $probe = Get-ZigProbe
      if ($probe.Valid) {
         Write-Host "Toolchain Zig detectado: $($probe.Path) ($($probe.Version))"
         return
      }
   }

   throw "Perfil Zig requer zig.exe, mas $($probe.Reason) Use -ZigPath, execute .\scripts\Bootstrap-Tools.ps1 -Tool Zig, ou ajuste o PATH."
}

function Initialize-Runner {
   param(
      [Parameter(Mandatory = $true)][string] $Runner,
      [string] $CygwinBashPath = '',
      [string] $MsysBashPath = '',
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
            MsysBash = ''
            WslArguments = @()
         }
      }
      'msys' {
         $bash = Resolve-MsysBash -PreferredPath $MsysBashPath
         if (-not $DryRun) {
            Assert-MsysTool -BashPath $bash -Name 'make'
            Assert-MsysTool -BashPath $bash -Name 'gcc'
         }

         return [pscustomobject]@{
            Name = 'msys'
            CygwinBash = ''
            MsysBash = $bash
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

   $converted = & $BashPath -lc "cygpath -au $(Format-ShArgument $Path)"
   if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $converted)) {
      throw "Falha ao converter path para Cygwin: $Path"
   }

   return [string] ($converted | Select-Object -Last 1)
}

function ConvertTo-MsysPath {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][string] $BashPath
   )

   $converted = & $BashPath -lc "cygpath -au $(Format-ShArgument $Path)" 2>$null
   if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string] $converted)) {
      return [string] ($converted | Select-Object -Last 1)
   }

   $fullPath = [System.IO.Path]::GetFullPath($Path)
   $root = [System.IO.Path]::GetPathRoot($fullPath)
   if ($root -match '^([A-Za-z]):\\$') {
      $drive = $matches[1].ToLowerInvariant()
      $relative = $fullPath.Substring($root.Length).Replace('\', '/')
      if ([string]::IsNullOrWhiteSpace($relative)) {
         return "/$drive"
      }

      return "/$drive/$relative"
   }

   throw "Falha ao converter path para MSYS2: $Path"
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
      'msys' { return ConvertTo-MsysPath -Path $Path -BashPath $RunnerState.MsysBash }
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
      "$key=$(Format-ShArgument ([string] $EnvMap[$key]))"
   }
   $commands = @()
   if ($CleanMakeArgs.Count -gt 0) {
      $cleanCommand = (@('make') + $CleanMakeArgs | ForEach-Object { Format-ShArgument ([string] $_) }) -join ' '
      $commands += "env $($assignments -join ' ') $cleanCommand"
   }

   $makeCommand = (@('make') + $MakeArgs | ForEach-Object { Format-ShArgument ([string] $_) }) -join ' '
   $commands += "env $($assignments -join ' ') $makeCommand"

   return "cd $(Format-ShArgument $targetRoot) && $($commands -join ' && ')"
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

$ProfileConfig = Get-ProfileConfig -Config $Config -Name $BuildProfile
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
   -MsysBashPath $MsysBash `
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
         Assert-ZigToolchain `
            -ToolsRoot $ToolsRoot `
            -ExplicitPath $ZigPath `
            -SkipBootstrap:$SkipToolBootstrap `
            -DryRun:$DryRun
      }
      'cygwin' {
         if ($runnerState.Name -ne 'cygwin') {
            throw "Perfil '$BuildProfile' requer Cygwin, mas usa runner '$($runnerState.Name)'."
         }
      }
      'msys' {
         if ($runnerState.Name -ne 'msys') {
            throw "Perfil '$BuildProfile' requer MSYS2, mas usa runner '$($runnerState.Name)'."
         }
      }
      'wsl' {
         if ($runnerState.Name -ne 'wsl') {
            throw "Perfil '$BuildProfile' requer WSL, mas usa runner '$($runnerState.Name)'."
         }
      }
      'docker' {
         if ($runnerState.Name -ne 'docker') {
            throw "Perfil '$BuildProfile' requer Docker, mas usa runner '$($runnerState.Name)'."
         }
      }
      default {
         throw "Pre-requisito desconhecido no perfil '$BuildProfile': $requirement"
      }
   }
}

if (-not $NoVsDevShell -and ($ProfileConfig.autoVsDevShell -eq $true)) {
   Import-VsDevShell -Arch $VsArch
}

$detectedMinGwToolchain = $null
if ($Runner -eq 'windows' -and -not $DryRun) {
   $detectedMinGwToolchain = Assert-WindowsMinGwToolchain `
      -Compiler ([string] $ProfileConfig.env.HB_COMPILER) `
      -ToolsRoot $ToolsRoot `
      -ExplicitPath $MinGwPath `
      -SkipBootstrap:$SkipToolBootstrap `
      -DryRun:$DryRun
}
elseif ($Runner -eq 'windows' -and $DryRun) {
   $detectedMinGwToolchain = Assert-WindowsMinGwToolchain `
      -Compiler ([string] $ProfileConfig.env.HB_COMPILER) `
      -ToolsRoot $ToolsRoot `
      -ExplicitPath $MinGwPath `
      -SkipBootstrap:$SkipToolBootstrap `
      -DryRun:$DryRun
}

$safeProfile = $BuildProfile -replace '[^A-Za-z0-9_.-]', '_'
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
      Write-Host "Perfil '$BuildProfile' usa dependencias do sistema; o resolvedor vcpkg do Windows sera ignorado."
      if ($SkipDependencyInstall) {
         Write-Host "Instalacao de dependencias do sistema ignorada por -SkipDependencyInstall."
      }
      elseif ($InstallSystemDependencies) {
         $dependencyCatalog = Get-DependencyCatalog
         $requestedSystemDependencies = Get-RequestedDependencyNames `
            -Catalog $dependencyCatalog `
            -Set $DependencySet `
            -Dependencies $Dependency `
            -IgnoredDependencies $IgnoreDependency
         $systemDependencyPlan = Get-SystemDependencyPlan -Runner $runnerState.Name -Dependencies $requestedSystemDependencies
         if (-not [string]::IsNullOrWhiteSpace($systemDependencyPlan.Message)) {
            Write-Host $systemDependencyPlan.Message
         }
         Invoke-SystemDependencyInstall `
            -Runner $runnerState.Name `
            -RunnerState $runnerState `
            -Packages @($systemDependencyPlan.Packages) `
            -Manual @($systemDependencyPlan.Manual) `
            -CygwinSetupPath $CygwinSetup `
            -WslArguments @($runnerState.WslArguments) `
            -DryRun:$DryRun
      }
      else {
         Write-Host "Use -InstallSystemDependencies para instalar os pacotes conhecidos do ambiente antes do build."
      }
   }
   else {
      throw "Modo de dependencia desconhecido no perfil '$BuildProfile': $DependencyMode"
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

$installRoot = Get-ProfileInstallRoot -Config $Config -Name $BuildProfile -OutputRoot $OutputRoot
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null

$envMap = [ordered]@{}
$envMap['HB_INSTALL_PREFIX'] = $installRoot

foreach ($item in @($ProfileConfig.env.PSObject.Properties)) {
   $envMap[$item.Name] = [string] $item.Value
}

if ($detectedMinGwToolchain -and $detectedMinGwToolchain.Valid -and -not [string]::IsNullOrWhiteSpace($detectedMinGwToolchain.BinDir)) {
   $compilerPath = [string] $detectedMinGwToolchain.BinDir
   if (-not $compilerPath.EndsWith('\')) {
      $compilerPath = "$compilerPath\"
   }

   if (-not $envMap.Contains('HB_CCPATH') -and [string]::IsNullOrWhiteSpace($env:HB_CCPATH)) {
      $envMap['HB_CCPATH'] = $compilerPath
   }

   $compilerPrefix = [string] $detectedMinGwToolchain.Prefix
   if (-not [string]::IsNullOrWhiteSpace($compilerPrefix) -and
      -not $envMap.Contains('HB_CCPREFIX') -and
      [string]::IsNullOrWhiteSpace($env:HB_CCPREFIX)) {
      $envMap['HB_CCPREFIX'] = $compilerPrefix
   }
}

$ignoredDependencyNames = Expand-NameList -Values $IgnoreDependency
$ignoredContribExcludes = New-Object System.Collections.Generic.List[string]
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

      if ($null -ne $dependencyConfig.PSObject.Properties['contribExcludes'] -and $null -ne $dependencyConfig.contribExcludes) {
         foreach ($contribExclude in @($dependencyConfig.contribExcludes)) {
            $contribExcludeName = [string] $contribExclude
            if (-not [string]::IsNullOrWhiteSpace($contribExcludeName) -and -not $ignoredContribExcludes.Contains($contribExcludeName)) {
               $ignoredContribExcludes.Add($contribExcludeName)
            }
         }
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
            throw "O perfil '$BuildProfile' requer HB_HOST_BIN. Compile primeiro o perfil '$hostProfile' ou defina HB_HOST_BIN."
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

if ($ignoredContribExcludes.Count -gt 0) {
   $currentContribFilter = ''
   if ($envMap.Contains('HB_BUILD_CONTRIBS')) {
      $currentContribFilter = [string] $envMap['HB_BUILD_CONTRIBS']
   }
   elseif (-not [string]::IsNullOrWhiteSpace($env:HB_BUILD_CONTRIBS)) {
      $currentContribFilter = [string] $env:HB_BUILD_CONTRIBS
   }

   if ([string]::IsNullOrWhiteSpace($currentContribFilter)) {
      $envMap['HB_BUILD_CONTRIBS'] = 'no ' + ($ignoredContribExcludes -join ' ')
   }
   elseif ($currentContribFilter -eq 'no') {
      $envMap['HB_BUILD_CONTRIBS'] = 'no ' + ($ignoredContribExcludes -join ' ')
   }
   elseif ($currentContribFilter -like 'no *') {
      $contribFilterParts = New-Object System.Collections.Generic.List[string]
      foreach ($part in @($currentContribFilter -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
         if (-not $contribFilterParts.Contains([string] $part)) {
            $contribFilterParts.Add([string] $part)
         }
      }
      foreach ($contribExclude in $ignoredContribExcludes) {
         if (-not $contribFilterParts.Contains([string] $contribExclude)) {
            $contribFilterParts.Add([string] $contribExclude)
         }
      }
      $envMap['HB_BUILD_CONTRIBS'] = ($contribFilterParts -join ' ')
   }
   else {
      Write-Warning "Nao foi possivel aplicar exclusoes de contrib para dependencias ignoradas porque HB_BUILD_CONTRIBS ja usa filtro positivo: $currentContribFilter"
   }
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
$safeProfile = $BuildProfile -replace '[^A-Za-z0-9_.-]', '_'
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
   "$(Format-ProjectPath $runnerState.CygwinBash) -lc $(Format-ShArgument $shellScript)"
}
elseif ($runnerState.Name -eq 'msys') {
   "$(Format-ProjectPath $runnerState.MsysBash) -lc $(Format-ShArgument $shellScript)"
}
elseif ($runnerState.Name -eq 'docker') {
   "$($runnerState.DockerCommand) $(($dockerRunArgs | ForEach-Object { Format-CommandArgument ([string] $_) }) -join ' ')"
}
else {
   $wslPrefix = if ($runnerState.WslArguments.Count -gt 0) { "wsl.exe $($runnerState.WslArguments -join ' ')" } else { 'wsl.exe' }
   "$wslPrefix bash -lc $(Format-ShArgument $shellScript)"
}
$dockerBuildDisplay = ''
if ($runnerState.Name -eq 'docker' -and -not $SkipDockerBuild) {
   $dockerBuildDisplay = "$($runnerState.DockerCommand) $(($dockerBuildArgs | ForEach-Object { Format-CommandArgument ([string] $_) }) -join ' ')"
}

Write-Host "HarbourRoot : $(Format-ProjectPath $HarbourRoot)"
Write-Host "Perfil      : $BuildProfile"
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
      elseif ($runnerState.Name -eq 'msys') {
         & $runnerState.MsysBash -lc $shellScript 2>&1 |
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

$global:LASTEXITCODE = 0
