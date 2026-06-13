[CmdletBinding()]
param(
   [ValidateSet('full', 'network', 'database', 'gui', 'graphics')]
   [string] $Set = 'full',
   [string[]] $Dependency = @(),
   [Alias('Ignore', 'DependencyIgnore', 'SkipDependency')]
   [string[]] $IgnoreDependency = @(),
   [ValidateSet('vcpkg')]
   [string] $Provider = 'vcpkg',
   [string] $Triplet = '',
   [string] $VcpkgRoot = '',
   [string] $GeneratedEnvPath = '',
   [string] $HarbourCompiler = '',
   [switch] $Install,
   [switch] $Check,
   [switch] $GenerateEnv,
   [switch] $Strict,
   [int] $DependencyInstallTimeoutMinutes = 120,
   [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

function Resolve-PhysicalPath {
   param([Parameter(Mandatory = $true)][string] $Path)

   $full = [System.IO.Path]::GetFullPath($Path)
   $root = [System.IO.Path]::GetPathRoot($full)
   $rest = $full.Substring($root.Length)
   $segments = @($rest -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
   $resolved = $root

   foreach ($segment in $segments) {
      $candidate = Join-Path $resolved $segment
      $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
      if ($item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -and $item.Target) {
         $target = [string] @($item.Target)[0]
         if (-not [System.IO.Path]::IsPathRooted($target)) {
            $target = Join-Path (Split-Path -Parent $candidate) $target
         }
         $resolved = [System.IO.Path]::GetFullPath($target)
      }
      else {
         $resolved = $candidate
      }
   }

   return [System.IO.Path]::GetFullPath($resolved)
}

$ProjectRoot = Resolve-PhysicalPath (Split-Path -Parent $PSScriptRoot)
$CatalogPath = Join-Path $ProjectRoot 'config\dependencies.json'
$ProfilesPath = Join-Path $ProjectRoot 'config\profiles.json'
$DefaultGeneratedEnvPath = Join-Path $ProjectRoot 'config\external-deps.generated.ps1'
$LocalEnvPath = Join-Path $ProjectRoot 'config\external-deps.local.ps1'

function Resolve-ProjectPath {
   param([Parameter(Mandatory = $true)][string] $Path)

   if ([System.IO.Path]::IsPathRooted($Path)) {
      return Resolve-PhysicalPath $Path
   }

   return Resolve-PhysicalPath (Join-Path $ProjectRoot $Path)
}

function Convert-ToNativePath {
   param([Parameter(Mandatory = $true)][string] $Path)
   return ($Path -replace '/', '\')
}

function Join-NativePath {
   param(
      [Parameter(Mandatory = $true)][string] $Root,
      [Parameter(Mandatory = $true)][string] $Child
   )

   return Join-Path $Root (Convert-ToNativePath $Child)
}

function Get-SafeFileName {
   param([Parameter(Mandatory = $true)][string] $Name)
   return ($Name -replace '[^A-Za-z0-9_.-]', '_')
}

function Get-ConfigPropertyValue {
   param(
      [Parameter(Mandatory = $true)] $Config,
      [Parameter(Mandatory = $true)][string] $Name,
      $Default = $null
   )

   $property = $Config.PSObject.Properties[$Name]
   if ($property -and $null -ne $property.Value) {
      return $property.Value
   }

   return $Default
}

function Get-DependencyDisplayName {
   param(
      [Parameter(Mandatory = $true)][string] $DependencyName,
      [Parameter(Mandatory = $true)] $DependencyConfig
   )

   $displayName = [string] (Get-ConfigPropertyValue -Config $DependencyConfig -Name 'displayName' -Default '')
   if ([string]::IsNullOrWhiteSpace($displayName)) {
      return $DependencyName
   }

   return $displayName
}

function Get-DependencyVcpkgPorts {
   param([Parameter(Mandatory = $true)] $DependencyConfig)

   if ($null -eq $DependencyConfig.PSObject.Properties['vcpkgPorts'] -or $null -eq $DependencyConfig.vcpkgPorts) {
      return @()
   }

   return @($DependencyConfig.vcpkgPorts) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
}

function Get-DependencyTriplet {
   param(
      [Parameter(Mandatory = $true)] $DependencyConfig,
      [Parameter(Mandatory = $true)][string] $DefaultTriplet
   )

   if ($null -ne $DependencyConfig.PSObject.Properties['triplets'] -and $null -ne $DependencyConfig.triplets) {
      $exactTriplet = $DependencyConfig.triplets.PSObject.Properties[$DefaultTriplet]
      if ($exactTriplet -and -not [string]::IsNullOrWhiteSpace([string] $exactTriplet.Value)) {
         return [string] $exactTriplet.Value
      }

      foreach ($tripletMap in @($DependencyConfig.triplets.PSObject.Properties)) {
         if ($DefaultTriplet -like $tripletMap.Name -and -not [string]::IsNullOrWhiteSpace([string] $tripletMap.Value)) {
            return [string] $tripletMap.Value
         }
      }
   }

   $configuredTriplet = [string] (Get-ConfigPropertyValue -Config $DependencyConfig -Name 'triplet' -Default '')
   if (-not [string]::IsNullOrWhiteSpace($configuredTriplet)) {
      return $configuredTriplet
   }

   return $DefaultTriplet
}

function Test-DependencyTripletSupported {
   param(
      [Parameter(Mandatory = $true)] $DependencyConfig,
      [Parameter(Mandatory = $true)][string] $TripletName
   )

   $unsupportedTriplets = @()
   if ($null -ne $DependencyConfig.PSObject.Properties['unsupportedTriplets'] -and $null -ne $DependencyConfig.unsupportedTriplets) {
      $unsupportedTriplets = @($DependencyConfig.unsupportedTriplets) |
         Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
   }

   foreach ($pattern in $unsupportedTriplets) {
      if ($TripletName -like [string] $pattern) {
         return [pscustomobject]@{
            Supported = $false
            Reason = "triplet '$TripletName' marcado como nao suportado"
         }
      }
   }

   $supportedTriplets = @()
   if ($null -ne $DependencyConfig.PSObject.Properties['supportedTriplets'] -and $null -ne $DependencyConfig.supportedTriplets) {
      $supportedTriplets = @($DependencyConfig.supportedTriplets) |
         Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
   }

   if ($supportedTriplets.Count -gt 0) {
      foreach ($pattern in $supportedTriplets) {
         if ($TripletName -like [string] $pattern) {
            return [pscustomobject]@{
               Supported = $true
               Reason = ''
            }
         }
      }

      return [pscustomobject]@{
         Supported = $false
         Reason = "triplet '$TripletName' fora da lista suportada"
      }
   }

   return [pscustomobject]@{
      Supported = $true
      Reason = ''
   }
}

function Get-DependencyInstallTimeoutMinutes {
   param(
      [Parameter(Mandatory = $true)] $DependencyConfig,
      [int] $DefaultMinutes = 0
   )

   $configuredTimeout = Get-ConfigPropertyValue -Config $DependencyConfig -Name 'installTimeoutMinutes' -Default $null
   if ($null -eq $configuredTimeout -or [string]::IsNullOrWhiteSpace([string] $configuredTimeout)) {
      return $DefaultMinutes
   }

   $minutes = 0
   if (-not [int]::TryParse([string] $configuredTimeout, [ref] $minutes) -or $minutes -lt 0) {
      throw "installTimeoutMinutes invalido em uma dependencia: $configuredTimeout"
   }

   return $minutes
}

function Get-VcpkgInstalledRoot {
   param(
      [Parameter(Mandatory = $true)][string] $VcpkgRoot,
      [Parameter(Mandatory = $true)][string] $TripletName
   )

   return Join-Path $VcpkgRoot "installed\$TripletName"
}

function Test-PathUnderRoot {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][string] $Root
   )

   if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
      return $false
   }

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

function Get-VcpkgStampPath {
   param(
      [Parameter(Mandatory = $true)][string] $StateRoot,
      [Parameter(Mandatory = $true)][string] $Port,
      [Parameter(Mandatory = $true)][string] $TripletName
   )

   $safeName = Get-SafeFileName "vcpkg-$Port-$TripletName"
   return Join-Path $StateRoot "$safeName.done"
}

function Write-VcpkgStamp {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][string] $Port,
      [Parameter(Mandatory = $true)][string] $TripletName
   )

   if ($DryRun) {
      Write-Host "DryRun: gravaria stamp $Path"
      return
   }

   $parent = Split-Path -Parent $Path
   New-Item -ItemType Directory -Force -Path $parent | Out-Null
   @(
      "port=$Port",
      "triplet=$TripletName",
      "completedAt=$((Get-Date).ToString('o'))"
   ) | Set-Content -LiteralPath $Path -Encoding ASCII
}

function Get-DependencyNames {
   param($Catalog, [string] $SetName, [string[]] $Requested)

   if ($Requested.Count -gt 0) {
      return $Requested
   }

   $setValues = $Catalog.sets.$SetName
   if (-not $setValues) {
      throw "Conjunto de dependencias desconhecido: $SetName"
   }

   return @($setValues)
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

function Test-HeaderInRoot {
   param(
      [Parameter(Mandatory = $true)][string] $Root,
      [Parameter(Mandatory = $true)] $DependencyConfig
   )

   foreach ($header in @($DependencyConfig.headers)) {
      $candidate = Join-NativePath -Root $Root -Child $header
      if (Test-Path -LiteralPath $candidate) {
         $headerDir = Split-Path -Parent $candidate
         $includeRoot = $Root
         if ($DependencyConfig.setTo -eq 'headerDir') {
            return [pscustomobject]@{
               Found = $true
               EnvValue = $headerDir
               Header = $candidate
            }
         }

         return [pscustomobject]@{
            Found = $true
            EnvValue = $includeRoot
            Header = $candidate
         }
      }
   }

   return [pscustomobject]@{
      Found = $false
      EnvValue = ''
      Header = ''
   }
}

function Test-DependencyEnvRoot {
   param(
      [Parameter(Mandatory = $true)][string] $Root,
      [string] $InstalledRoot
   )

   if ([string]::IsNullOrWhiteSpace($Root)) {
      return $false
   }

   if ([string]::IsNullOrWhiteSpace($InstalledRoot) -or -not [System.IO.Path]::IsPathRooted($Root)) {
      return $true
   }

   try {
      $trimChars = [char[]] '\/'
      $installedRootFull = [System.IO.Path]::GetFullPath($InstalledRoot).TrimEnd($trimChars)
      $installedParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $installedRootFull)).TrimEnd($trimChars)
      $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd($trimChars)
      $installedParentPrefix = "$installedParent\"
      $installedRootPrefix = "$installedRootFull\"

      if ($rootFull.StartsWith($installedParentPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
          -not ($rootFull.Equals($installedRootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
             $rootFull.StartsWith($installedRootPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
         return $false
      }
   }
   catch {
   }

   return $true
}

function Find-Dependency {
   param(
      [Parameter(Mandatory = $true)] $DependencyConfig,
      [string] $InstalledRoot
   )

   $roots = New-Object System.Collections.Generic.List[string]
   $envVar = [string] $DependencyConfig.envVar
   if (-not [string]::IsNullOrWhiteSpace($envVar)) {
      $current = [System.Environment]::GetEnvironmentVariable($envVar, 'Process')
      if (-not [string]::IsNullOrWhiteSpace($current) -and (Test-DependencyEnvRoot -Root $current -InstalledRoot $InstalledRoot)) {
         $roots.Add($current)
      }
   }

   if (-not [string]::IsNullOrWhiteSpace($InstalledRoot)) {
      $roots.Add((Join-Path $InstalledRoot 'include'))
      foreach ($child in @('include\mysql', 'include\postgresql', 'include\cairo', 'include\ghostscript', 'include\firebird')) {
         $roots.Add((Join-Path $InstalledRoot $child))
      }
   }

   foreach ($root in $roots | Select-Object -Unique) {
      if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) {
         continue
      }

      $result = Test-HeaderInRoot -Root $root -DependencyConfig $DependencyConfig
      if ($result.Found) {
         return $result
      }
   }

   return [pscustomobject]@{
      Found = $false
      EnvValue = ''
      Header = ''
   }
}

function Initialize-Vcpkg {
   param([Parameter(Mandatory = $true)][string] $Root)

   $vcpkgExe = Join-Path $Root 'vcpkg.exe'
   if (Test-Path -LiteralPath $vcpkgExe) {
      return $vcpkgExe
   }

   if ($DryRun) {
      Write-Host "DryRun: git clone https://github.com/microsoft/vcpkg.git `"$Root`""
      Write-Host "DryRun: `"$Root\bootstrap-vcpkg.bat`" -disableMetrics"
      return $vcpkgExe
   }

   if (-not (Get-Command 'git.exe' -ErrorAction SilentlyContinue)) {
      throw 'git.exe nao encontrado. Instale Git ou clone o vcpkg manualmente em tools\vcpkg.'
   }

   $parent = Split-Path -Parent $Root
   New-Item -ItemType Directory -Force -Path $parent | Out-Null

   if (-not (Test-Path -LiteralPath $Root)) {
      & git clone https://github.com/microsoft/vcpkg.git $Root | Out-Host
      if ($LASTEXITCODE -ne 0) {
         throw 'Falha ao clonar vcpkg.'
      }
   }

   $bootstrap = Join-Path $Root 'bootstrap-vcpkg.bat'
   if (-not (Test-Path -LiteralPath $bootstrap)) {
      throw "bootstrap-vcpkg.bat nao encontrado em: $bootstrap"
   }

   & $bootstrap -disableMetrics | Out-Host
   if ($LASTEXITCODE -ne 0) {
      throw 'Falha ao executar bootstrap-vcpkg.bat.'
   }

   if (-not (Test-Path -LiteralPath $vcpkgExe)) {
      throw "vcpkg.exe nao foi criado em: $vcpkgExe"
   }

   return $vcpkgExe
}

function Initialize-VcpkgBinaryCache {
   param([Parameter(Mandatory = $true)][string] $CacheRoot)

   $existing = [System.Environment]::GetEnvironmentVariable('VCPKG_BINARY_SOURCES', 'Process')
   if (-not [string]::IsNullOrWhiteSpace($existing)) {
      Write-Host "VCPKG_BINARY_SOURCES existente preservado: $existing"
      return [pscustomobject]@{
         Source = 'env'
         Value = $existing
         Root = ''
      }
   }

   $value = "clear;files,$CacheRoot,readwrite"

   if ($DryRun) {
      Write-Host "DryRun: configuraria VCPKG_BINARY_SOURCES=$value"
      return [pscustomobject]@{
         Source = 'dry-run'
         Value = $value
         Root = $CacheRoot
      }
   }

   New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
   [System.Environment]::SetEnvironmentVariable('VCPKG_BINARY_SOURCES', $value, 'Process')
   Write-Host "VCPKG_BINARY_SOURCES configurado: $value"

   return [pscustomobject]@{
      Source = 'local'
      Value = $value
      Root = $CacheRoot
   }
}

function Format-ActivityElapsed {
   param([Parameter(Mandatory = $true)][TimeSpan] $Elapsed)

   if ($Elapsed.TotalHours -ge 1) {
      return "{0:00}:{1:00}:{2:00}" -f [int] $Elapsed.TotalHours, $Elapsed.Minutes, $Elapsed.Seconds
   }

   return "{0:00}:{1:00}" -f [int] $Elapsed.TotalMinutes, $Elapsed.Seconds
}

function Get-ConsoleStatusWidth {
   try {
      $width = [int] $Host.UI.RawUI.WindowSize.Width
      if ($width -gt 10) {
         return ($width - 1)
      }
   }
   catch {
   }

   return 100
}

function Write-ActivityStatus {
   param(
      [Parameter(Mandatory = $true)][string] $Activity,
      [Parameter(Mandatory = $true)][TimeSpan] $Elapsed,
      [int] $TimeoutMinutes = 0,
      [Parameter(Mandatory = $true)][string] $Frame,
      [int] $PreviousLength = 0
   )

   $timeoutText = if ($TimeoutMinutes -gt 0) { " / limite ${TimeoutMinutes}min" } else { "" }
   $status = "{0} {1} em andamento ({2}{3})" -f $Frame, $Activity, (Format-ActivityElapsed $Elapsed), $timeoutText
   $maxWidth = Get-ConsoleStatusWidth
   if ($status.Length -gt $maxWidth) {
      $status = $status.Substring(0, [Math]::Max(0, $maxWidth - 3)) + '...'
   }

   $padding = ''
   if ($PreviousLength -gt $status.Length) {
      $padding = ' ' * ($PreviousLength - $status.Length)
   }

   Write-Host -NoNewline ("`r{0}{1}" -f $status, $padding)
   return $status.Length
}

function Clear-ActivityStatus {
   param([int] $Length = 0)

   if ($Length -le 0) {
      return
   }

   Write-Host -NoNewline ("`r{0}`r" -f (' ' * $Length))
}

function Invoke-ProcessWithTimeout {
   param(
      [Parameter(Mandatory = $true)][string] $FilePath,
      [Parameter(Mandatory = $true)][string[]] $Arguments,
      [Parameter(Mandatory = $true)][string] $WorkingDirectory,
      [Parameter(Mandatory = $true)][string] $StdOutPath,
      [Parameter(Mandatory = $true)][string] $StdErrPath,
      [Parameter(Mandatory = $true)][string] $Activity,
      [int] $TimeoutMinutes = 0
   )

   $startedAt = Get-Date
   $process = Start-Process -FilePath $FilePath `
      -ArgumentList $Arguments `
      -WorkingDirectory $WorkingDirectory `
      -RedirectStandardOutput $StdOutPath `
      -RedirectStandardError $StdErrPath `
      -WindowStyle Hidden `
      -PassThru

   $lastNotice = $startedAt
   $spinnerFrames = @('|', '/', '-', '\')
   $spinnerIndex = 0
   $statusLength = 0
   $canAnimate = $true
   try {
      $canAnimate = -not [Console]::IsOutputRedirected
   }
   catch {
   }

   while (-not $process.HasExited) {
      Start-Sleep -Seconds 1
      $process.Refresh()
      $elapsed = (Get-Date) - $startedAt

      if ($canAnimate) {
         $statusLength = Write-ActivityStatus `
            -Activity $Activity `
            -Elapsed $elapsed `
            -TimeoutMinutes $TimeoutMinutes `
            -Frame $spinnerFrames[$spinnerIndex % $spinnerFrames.Count] `
            -PreviousLength $statusLength
         $spinnerIndex++
      }

      if ($TimeoutMinutes -gt 0 -and $elapsed.TotalMinutes -ge $TimeoutMinutes) {
         if ($canAnimate) {
            Clear-ActivityStatus -Length $statusLength
            $statusLength = 0
         }

         Write-Warning "$Activity excedeu o tempo limite de $TimeoutMinutes minuto(s). Encerrando processo e desativando a dependencia."
         & taskkill.exe /PID $process.Id /T /F | Out-Null
         $process.WaitForExit(10000) | Out-Null

         return [pscustomobject]@{
            ExitCode = -1
            TimedOut = $true
            Message = "timeout apos $TimeoutMinutes minuto(s)"
            StdOutPath = $StdOutPath
            StdErrPath = $StdErrPath
         }
      }

      if ($elapsed.TotalMinutes -ge (($lastNotice - $startedAt).TotalMinutes + 5)) {
         $lastNotice = Get-Date
         if ($canAnimate) {
            Clear-ActivityStatus -Length $statusLength
            $statusLength = 0
         }

         Write-Host ("Ainda executando {0} ({1:N0} min)..." -f $Activity, $elapsed.TotalMinutes)
      }
   }

   if ($canAnimate) {
      Clear-ActivityStatus -Length $statusLength
   }

   return [pscustomobject]@{
      ExitCode = $process.ExitCode
      TimedOut = $false
      Message = if ($process.ExitCode -eq 0) { 'ok' } else { "codigo de saida $($process.ExitCode)" }
      StdOutPath = $StdOutPath
      StdErrPath = $StdErrPath
   }
}

function Find-PatternInDirectories {
   param(
      [Parameter(Mandatory = $true)][string] $Root,
      [Parameter(Mandatory = $true)][string[]] $Directories,
      [Parameter(Mandatory = $true)][string] $Pattern
   )

   foreach ($directory in $Directories) {
      $searchRoot = if ([string]::IsNullOrWhiteSpace($directory)) {
         $Root
      }
      else {
         Join-NativePath -Root $Root -Child $directory
      }

      if (-not (Test-Path -LiteralPath $searchRoot)) {
         continue
      }

      $found = Get-ChildItem -LiteralPath $searchRoot -Filter $Pattern -ErrorAction SilentlyContinue |
         Select-Object -First 1
      if ($found) {
         return $found.FullName
      }
   }

   return ''
}

function Find-ToolPath {
   param(
      [Parameter(Mandatory = $true)][string] $InstalledRoot,
      [Parameter(Mandatory = $true)] $ToolConfig
   )

   $toolName = [string] $ToolConfig.name
   if ([string]::IsNullOrWhiteSpace($toolName)) {
      return ''
   }

   foreach ($directory in @($ToolConfig.directories)) {
      if ([string]::IsNullOrWhiteSpace([string] $directory)) {
         continue
      }

      $candidate = Join-NativePath -Root $InstalledRoot -Child (Join-Path ([string] $directory) $toolName)
      if (Test-Path -LiteralPath $candidate) {
         return $candidate
      }
   }

   $found = Get-ChildItem -LiteralPath $InstalledRoot -Filter $toolName -Recurse -ErrorAction SilentlyContinue |
      Select-Object -First 1
   if ($found) {
      return $found.FullName
   }

   return ''
}

function Test-DependencyInstalledArtifacts {
   param(
      [Parameter(Mandatory = $true)] $DependencyConfig,
      [Parameter(Mandatory = $true)][string] $InstalledRoot
   )

   $missing = New-Object System.Collections.Generic.List[string]
   $headerResult = [pscustomobject]@{
      Found = $false
      EnvValue = ''
      Header = ''
   }

   if (-not (Test-Path -LiteralPath $InstalledRoot)) {
      $missing.Add("raiz instalada nao encontrada: $InstalledRoot")
      return [pscustomobject]@{
         Success = $false
         Found = $headerResult
         MissingItems = @($missing)
         Missing = ($missing -join '; ')
      }
   }

   $includeRoot = Join-Path $InstalledRoot 'include'
   if (Test-Path -LiteralPath $includeRoot) {
      $headerResult = Test-HeaderInRoot -Root $includeRoot -DependencyConfig $DependencyConfig
   }

   if (-not $headerResult.Found) {
      $firstHeader = [string] (@($DependencyConfig.headers) | Select-Object -First 1)
      if ([string]::IsNullOrWhiteSpace($firstHeader)) {
         $missing.Add("headers nao configurados no catalogo")
      }
      else {
         $missing.Add("header nao encontrado: $firstHeader")
      }
   }

   $requiredDllPatterns = @()
   if ($null -ne $DependencyConfig.PSObject.Properties['requiredDllPatterns'] -and $null -ne $DependencyConfig.requiredDllPatterns) {
      $requiredDllPatterns = @($DependencyConfig.requiredDllPatterns) |
         Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }
   }

   if ($requiredDllPatterns.Count -gt 0) {
      foreach ($pattern in $requiredDllPatterns) {
         $patternText = [string] $pattern
         $dll = Find-PatternInDirectories -Root $InstalledRoot -Directories @('bin', 'debug\bin') -Pattern $patternText
         if ([string]::IsNullOrWhiteSpace($dll)) {
            $missing.Add("DLL nao encontrada: $patternText")
         }
      }
   }
   elseif ($null -ne $DependencyConfig.PSObject.Properties['dllPatterns'] -and $null -ne $DependencyConfig.dllPatterns) {
      $dllPatterns = @($DependencyConfig.dllPatterns) |
         Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) }

      if ($dllPatterns.Count -gt 0) {
         $dllFound = $false
         foreach ($pattern in $dllPatterns) {
            $dll = Find-PatternInDirectories -Root $InstalledRoot -Directories @('bin', 'debug\bin') -Pattern ([string] $pattern)
            if (-not [string]::IsNullOrWhiteSpace($dll)) {
               $dllFound = $true
               break
            }
         }

         if (-not $dllFound) {
            $missing.Add("DLL nao encontrada (uma de): $($dllPatterns -join ', ')")
         }
      }
   }

   if ($null -ne $DependencyConfig.PSObject.Properties['tools'] -and $null -ne $DependencyConfig.tools) {
      foreach ($tool in @($DependencyConfig.tools)) {
         $toolName = [string] $tool.name
         if ([string]::IsNullOrWhiteSpace($toolName)) {
            continue
         }

         $toolPath = Find-ToolPath -InstalledRoot $InstalledRoot -ToolConfig $tool
         if ([string]::IsNullOrWhiteSpace($toolPath)) {
            $missing.Add("ferramenta nao encontrada: $toolName")
         }
      }
   }

   return [pscustomobject]@{
      Success = ($missing.Count -eq 0)
      Found = $headerResult
      MissingItems = @($missing)
      Missing = ($missing -join '; ')
   }
}

function Get-VcpkgOverlayTripletsArgument {
   param(
      [Parameter(Mandatory = $true)][string] $VcpkgRoot,
      [Parameter(Mandatory = $true)] $DependencyConfig
   )

   $overlayTriplets = [string] (Get-ConfigPropertyValue -Config $DependencyConfig -Name 'overlayTriplets' -Default '')
   if ([string]::IsNullOrWhiteSpace($overlayTriplets)) {
      return ''
   }

   $overlayPath = if ([System.IO.Path]::IsPathRooted($overlayTriplets)) {
      Resolve-PhysicalPath $overlayTriplets
   }
   else {
      Resolve-PhysicalPath (Join-Path $VcpkgRoot (Convert-ToNativePath $overlayTriplets))
   }

   if (Test-Path -LiteralPath $overlayPath) {
      return "--overlay-triplets=$overlayPath"
   }

   Write-Warning "overlayTriplets configurado, mas nao encontrado: $overlayPath"
   return ''
}

function Install-VcpkgPorts {
   param(
      [Parameter(Mandatory = $true)][string] $DependencyName,
      [Parameter(Mandatory = $true)] $DependencyConfig,
      [Parameter(Mandatory = $true)][string] $VcpkgExe,
      [Parameter(Mandatory = $true)][string] $TripletName,
      [Parameter(Mandatory = $true)][string[]] $Ports,
      [Parameter(Mandatory = $true)][string] $LogsRoot,
      [Parameter(Mandatory = $true)][string] $StateRoot,
      [int] $TimeoutMinutes = 0
   )

   New-Item -ItemType Directory -Force -Path $LogsRoot, $StateRoot | Out-Null
   $installResults = New-Object System.Collections.Generic.List[object]
   $vcpkgRoot = Split-Path -Parent $VcpkgExe
   $installedRoot = Get-VcpkgInstalledRoot -VcpkgRoot $vcpkgRoot -TripletName $TripletName
   $displayName = Get-DependencyDisplayName -DependencyName $DependencyName -DependencyConfig $DependencyConfig

   foreach ($port in $Ports) {
      $spec = "$port`:$TripletName"
      $stampPath = Get-VcpkgStampPath -StateRoot $StateRoot -Port $port -TripletName $TripletName
      $artifactState = Test-DependencyInstalledArtifacts -DependencyConfig $DependencyConfig -InstalledRoot $installedRoot
      $hasStamp = Test-Path -LiteralPath $stampPath

      if ($hasStamp -and $artifactState.Success) {
         Write-Host "vcpkg $spec ja validado por stamp: $stampPath"
         $installResults.Add([pscustomobject]@{
            Success = $true
            Port = $port
            Spec = $spec
            Action = 'stamp'
            Message = 'stamp valido'
            StdOutPath = ''
            StdErrPath = ''
            StampPath = $stampPath
         })
         continue
      }

      if ($artifactState.Success) {
         Write-Host "vcpkg $spec ja esta instalado e valido em: $installedRoot"
         Write-VcpkgStamp -Path $stampPath -Port $port -TripletName $TripletName
         $installResults.Add([pscustomobject]@{
            Success = $true
            Port = $port
            Spec = $spec
            Action = 'cache'
            Message = 'instalacao existente validada'
            StdOutPath = ''
            StdErrPath = ''
            StampPath = $stampPath
         })
         continue
      }

      $vcpkgArgs = @($spec)
      $overlayArg = Get-VcpkgOverlayTripletsArgument -VcpkgRoot $vcpkgRoot -DependencyConfig $DependencyConfig
      if (-not [string]::IsNullOrWhiteSpace($overlayArg)) {
         $vcpkgArgs += $overlayArg
      }

      if ($DryRun) {
         Write-Host "DryRun: $VcpkgExe install $($vcpkgArgs -join ' ')"
         $installResults.Add([pscustomobject]@{
            Success = $true
            Port = $port
            Spec = $spec
            Action = 'dry-run'
            Message = 'dry-run'
            StdOutPath = ''
            StdErrPath = ''
            StampPath = $stampPath
         })
         continue
      }

      $safeSpec = Get-SafeFileName $spec
      $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
      $stdoutPath = Join-Path $LogsRoot "$stamp-vcpkg-$safeSpec.out.log"
      $stderrPath = Join-Path $LogsRoot "$stamp-vcpkg-$safeSpec.err.log"
      $activity = "vcpkg install $spec"

      Write-Host "$activity"
      Write-Host "  Dependencia: $displayName"
      Write-Host "  Triplet: $TripletName"
      if ($TimeoutMinutes -gt 0) {
         Write-Host "  Timeout: $TimeoutMinutes minuto(s)"
      }
      Write-Host "  Logs: $stdoutPath / $stderrPath"

      try {
         $processResult = Invoke-ProcessWithTimeout `
            -FilePath $VcpkgExe `
            -Arguments (@('install') + $vcpkgArgs) `
            -WorkingDirectory $vcpkgRoot `
            -StdOutPath $stdoutPath `
            -StdErrPath $stderrPath `
            -Activity $activity `
            -TimeoutMinutes $TimeoutMinutes
      }
      catch {
         $processResult = [pscustomobject]@{
            ExitCode = -1
            TimedOut = $false
            Message = $_.Exception.Message
            StdOutPath = $stdoutPath
            StdErrPath = $stderrPath
         }
      }

      $success = ($processResult.ExitCode -eq 0 -and -not $processResult.TimedOut)
      $message = $processResult.Message
      if ($success) {
         $artifactState = Test-DependencyInstalledArtifacts -DependencyConfig $DependencyConfig -InstalledRoot $installedRoot
         if ($artifactState.Success) {
            Write-VcpkgStamp -Path $stampPath -Port $port -TripletName $TripletName
            $message = 'ok'
         }
         else {
            $success = $false
            $message = "instalacao terminou, mas a validacao falhou: $($artifactState.Missing)"
         }
      }

      $portAction = if ($success) { 'build' } else { 'failed' }
      $installResults.Add([pscustomobject]@{
         Success = $success
         Port = $port
         Spec = $spec
         Action = $portAction
         Message = $message
         StdOutPath = $processResult.StdOutPath
         StdErrPath = $processResult.StdErrPath
         StampPath = $stampPath
      })

      if (-not $success) {
         Write-Warning "$activity falhou ($message). A dependencia sera desativada e o processo continuara."
         Write-Warning "Consulte os logs: $($processResult.StdOutPath) / $($processResult.StdErrPath)"
         break
      }
   }

   $failed = @($installResults | Where-Object { -not $_.Success } | Select-Object -First 1)
   $failedItem = $null
   if ($failed.Count -gt 0) {
      $failedItem = $failed[0]
   }

   $portResults = @($installResults | ForEach-Object { $_ })
   $installAction = 'none'
   if ($failed.Count -gt 0) {
      $installAction = 'failed'
   }
   elseif (@($portResults | Where-Object { $_.Action -eq 'build' }).Count -gt 0) {
      $installAction = 'build'
   }
   elseif (@($portResults | Where-Object { $_.Action -eq 'dry-run' }).Count -gt 0) {
      $installAction = 'dry-run'
   }
   elseif (@($portResults | Where-Object { $_.Action -eq 'cache' }).Count -gt 0) {
      if (@($portResults | Where-Object { $_.Action -eq 'stamp' }).Count -gt 0) {
         $installAction = 'cache/stamp'
      }
      else {
         $installAction = 'cache'
      }
   }
   elseif (@($portResults | Where-Object { $_.Action -eq 'stamp' }).Count -gt 0) {
      $installAction = 'stamp'
   }

   return [pscustomobject]@{
      Success = ($failed.Count -eq 0)
      Failed = $failedItem
      Ports = $portResults
      Action = $installAction
   }
}

function Get-DependencySourceFallback {
   param([Parameter(Mandatory = $true)] $DependencyConfig)

   if ($null -ne $DependencyConfig.PSObject.Properties['sourceFallback'] -and $null -ne $DependencyConfig.sourceFallback) {
      return $DependencyConfig.sourceFallback
   }

   return $null
}

function Install-SourceFallback {
   param(
      [Parameter(Mandatory = $true)][string] $DependencyName,
      [Parameter(Mandatory = $true)] $DependencyConfig,
      [Parameter(Mandatory = $true)] $FallbackConfig
   )

   $displayName = if (-not [string]::IsNullOrWhiteSpace($FallbackConfig.displayName)) {
      [string] $FallbackConfig.displayName
   }
   else {
      "source fallback for $DependencyName"
   }

   $repository = [string] $FallbackConfig.repository
   $rootValue = [string] $FallbackConfig.root
   $ref = [string] $FallbackConfig.ref
   $includeRootValue = [string] $FallbackConfig.includeRoot

   if ([string]::IsNullOrWhiteSpace($rootValue)) {
      return [pscustomobject]@{
         Success = $false
         Found = $null
         Spec = $displayName
         Message = 'sourceFallback.root nao configurado'
      }
   }

   $sourceRoot = Resolve-ProjectPath $rootValue
   $includeRoot = if ([string]::IsNullOrWhiteSpace($includeRootValue)) {
      $sourceRoot
   }
   else {
      Join-NativePath -Root $sourceRoot -Child $includeRootValue
   }

   if (-not (Test-Path -LiteralPath $sourceRoot)) {
      if ([string]::IsNullOrWhiteSpace($repository)) {
         return [pscustomobject]@{
            Success = $false
            Found = $null
            Spec = $displayName
            Message = "diretorio nao existe e sourceFallback.repository nao foi configurado: $sourceRoot"
         }
      }

      if ($DryRun) {
         Write-Host "DryRun: git clone $repository `"$sourceRoot`""
         if (-not [string]::IsNullOrWhiteSpace($ref)) {
            Write-Host "DryRun: git -C `"$sourceRoot`" checkout $ref"
         }

         $plannedHeader = Join-NativePath -Root $includeRoot -Child ([string] @($DependencyConfig.headers)[0])
         return [pscustomobject]@{
            Success = $true
            Found = [pscustomobject]@{
               Found = $true
               EnvValue = $includeRoot
               Header = $plannedHeader
            }
            Spec = $displayName
            Message = 'dry-run'
         }
      }

      if (-not (Get-Command 'git.exe' -ErrorAction SilentlyContinue)) {
         return [pscustomobject]@{
            Success = $false
            Found = $null
            Spec = $displayName
            Message = 'git.exe nao encontrado'
         }
      }

      $parent = Split-Path -Parent $sourceRoot
      New-Item -ItemType Directory -Force -Path $parent | Out-Null

      Write-Host "Clonando fallback '$displayName' para '$DependencyName': $repository"
      & git.exe clone --depth 1 $repository $sourceRoot | Out-Host
      if ($LASTEXITCODE -ne 0) {
         return [pscustomobject]@{
            Success = $false
            Found = $null
            Spec = $displayName
            Message = "git clone falhou com codigo $LASTEXITCODE"
         }
      }

      if (-not [string]::IsNullOrWhiteSpace($ref)) {
         Write-Host "Selecionando ref do fallback '$displayName': $ref"
         & git.exe -C $sourceRoot checkout $ref | Out-Host
         if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{
               Success = $false
               Found = $null
               Spec = $displayName
               Message = "git checkout falhou com codigo $LASTEXITCODE"
            }
         }
      }
   }
   elseif (-not [string]::IsNullOrWhiteSpace($ref)) {
      Write-Warning "Fallback '$displayName' ja existe em '$sourceRoot'; sourceFallback.ref so e aplicado durante o clone."
   }

   $found = Test-HeaderInRoot -Root $includeRoot -DependencyConfig $DependencyConfig
   if ($found.Found) {
      return [pscustomobject]@{
         Success = $true
         Found = $found
         Spec = $displayName
         Message = 'ok'
      }
   }

   return [pscustomobject]@{
      Success = $false
      Found = $found
      Spec = $displayName
      Message = "header nao encontrado em $includeRoot"
   }
}

function Find-ToolEnv {
   param(
      [Parameter(Mandatory = $true)][string] $InstalledRoot,
      [Parameter(Mandatory = $true)] $ToolConfig
   )

   $toolPath = Find-ToolPath -InstalledRoot $InstalledRoot -ToolConfig $ToolConfig
   if (-not [string]::IsNullOrWhiteSpace($toolPath)) {
      return Split-Path -Parent $toolPath
   }

   return ''
}

function Add-UniqueWords {
   param(
      $Words,
      [string] $Value
   )

   foreach ($word in @($Value -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
      if (-not $Words.Contains($word)) {
         $Words.Add($word)
      }
   }
}

function Get-VcpkgLibPathFlag {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][string] $TripletName,
      [string] $Compiler = ''
   )

   $normalizedCompiler = $Compiler.ToLowerInvariant()
   if ($normalizedCompiler -like 'msvc*' -or ($TripletName -like '*windows*' -and $TripletName -notlike '*mingw*')) {
      return "-libpath:$Path"
   }

   return "-L$($Path.Replace('\', '/'))"
}

function Add-VcpkgLinkerFlags {
   param(
      [Parameter(Mandatory = $true)][hashtable] $Values,
      [Parameter(Mandatory = $true)][object[]] $Results,
      [Parameter(Mandatory = $true)][string] $VcpkgRoot,
      [string] $Compiler = ''
   )

   $ldFlags = New-Object System.Collections.Generic.List[string]
   $dyFlags = New-Object System.Collections.Generic.List[string]
   Add-UniqueWords -Words $ldFlags -Value ([System.Environment]::GetEnvironmentVariable('HB_USER_LDFLAGS', 'Process'))
   Add-UniqueWords -Words $dyFlags -Value ([System.Environment]::GetEnvironmentVariable('HB_USER_DFLAGS', 'Process'))
   $existingGeneratedFlags = ''
   if ($Values.ContainsKey('HB_USER_LDFLAGS')) {
      $existingGeneratedFlags = [string] $Values['HB_USER_LDFLAGS']
   }
   Add-UniqueWords -Words $ldFlags -Value $existingGeneratedFlags

   $existingGeneratedDyFlags = ''
   if ($Values.ContainsKey('HB_USER_DFLAGS')) {
      $existingGeneratedDyFlags = [string] $Values['HB_USER_DFLAGS']
   }
   Add-UniqueWords -Words $dyFlags -Value $existingGeneratedDyFlags

   foreach ($tripletName in @($Results | Where-Object { $_.Status -eq 'ok' -and $_.Provider -eq 'vcpkg' } | ForEach-Object { $_.Triplet } | Select-Object -Unique)) {
      if ([string]::IsNullOrWhiteSpace([string] $tripletName)) {
         continue
      }

      $libRoot = Join-Path (Get-VcpkgInstalledRoot -VcpkgRoot $VcpkgRoot -TripletName ([string] $tripletName)) 'lib'
      if (Test-Path -LiteralPath $libRoot) {
         $flag = Get-VcpkgLibPathFlag -Path $libRoot -TripletName ([string] $tripletName) -Compiler $Compiler
         if (-not $ldFlags.Contains($flag)) {
            $ldFlags.Add($flag)
         }
         if (-not $dyFlags.Contains($flag)) {
            $dyFlags.Add($flag)
         }
      }
   }

   if ($ldFlags.Count -gt 0) {
      $Values['HB_USER_LDFLAGS'] = ($ldFlags -join ' ')
   }
   if ($dyFlags.Count -gt 0) {
      $Values['HB_USER_DFLAGS'] = ($dyFlags -join ' ')
   }
}

function Write-GeneratedEnv {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][hashtable] $Values
   )

   $lines = New-Object System.Collections.Generic.List[string]
   $lines.Add('# Generated by scripts/Resolve-HarbourDeps.ps1. Do not edit manually.')
   $lines.Add('# Override values in config/external-deps.local.ps1 if needed.')
   $lines.Add('')

   foreach ($key in ($Values.Keys | Sort-Object)) {
      $escaped = [string] $Values[$key]
      $escaped = $escaped.Replace("'", "''")
      $lines.Add("`$env:$key = '$escaped'")
   }

   if ($DryRun) {
      Write-Host "DryRun: gravaria $Path"
      $lines | ForEach-Object { Write-Host $_ }
      return
   }

   Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}

function Join-DependencyResultNames {
   param([object[]] $Items)

   $names = @($Items | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
   if ($names.Count -eq 0) {
      return '(nenhuma)'
   }

   return ($names -join ', ')
}

function Write-DependencyReport {
   param([Parameter(Mandatory = $true)][object[]] $Results)

   $found = @($Results | Where-Object { $_.Status -eq 'ok' })
   $installed = @($Results | Where-Object { $_.InstallState -in @('build', 'source') })
   $stampSkipped = @($Results | Where-Object { ([string] $_.InstallState) -like '*stamp*' })
   $cacheSkipped = @($Results | Where-Object { ([string] $_.InstallState) -like '*cache*' })
   $ignored = @($Results | Where-Object { $_.Status -eq 'ignored' })
   $failed = @($Results | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_.Failure) })
   $unavailable = @($Results | Where-Object { $_.Status -ne 'ok' -and $_.Status -ne 'ignored' })
   $qt = @($Results | Where-Object { $_.Name -eq 'qt' } | Select-Object -First 1)

   Write-Host ''
   Write-Host 'Relatorio final de dependencias:'
   Write-Host "  Encontradas: $(Join-DependencyResultNames -Items $found)"
   Write-Host "  Instaladas: $(Join-DependencyResultNames -Items $installed)"
   Write-Host "  Puladas por stamp: $(Join-DependencyResultNames -Items $stampSkipped)"
   Write-Host "  Puladas por cache: $(Join-DependencyResultNames -Items $cacheSkipped)"
   Write-Host "  Ignoradas: $(Join-DependencyResultNames -Items $ignored)"
   Write-Host "  Falhadas: $(Join-DependencyResultNames -Items $failed)"
   Write-Host "  Indisponiveis/desativadas: $(Join-DependencyResultNames -Items $unavailable)"

   if ($qt.Count -gt 0) {
      $qtSource = switch ([string] $qt[0].InstallState) {
         'stamp' { 'stamp valido' }
         'cache' { 'cache/instalacao existente validada' }
         'cache/stamp' { 'cache e stamp' }
         'build' { 'build novo via vcpkg' }
         'dry-run' { 'dry-run' }
         default { [string] $qt[0].InstallState }
      }

      if ($qt[0].Status -eq 'ignored') {
         $qtSource = 'ignorado'
      }
      elseif ([string]::IsNullOrWhiteSpace($qtSource)) {
         $qtSource = [string] $qt[0].Status
      }

      Write-Host "  Qt: $qtSource; triplet=$($qt[0].Triplet); tempo=$($qt[0].Duration)"
   }

   Write-Host ''
   Write-Host 'Tempo por dependencia:'
   $Results | Select-Object Name, Duration, InstallState | Format-Table -AutoSize
}

if (-not (Test-Path -LiteralPath $CatalogPath)) {
   throw "Catalogo de dependencias nao encontrado: $CatalogPath"
}

$Catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$Profiles = Get-Content -LiteralPath $ProfilesPath -Raw | ConvertFrom-Json
$LogsRoot = Resolve-ProjectPath $Profiles.logsRoot
$ToolsRoot = Resolve-ProjectPath $Profiles.toolsRoot
$StateRoot = Resolve-ProjectPath 'scratch\state'

if (Test-Path -LiteralPath $LocalEnvPath) {
   . $LocalEnvPath
}

if ($DependencyInstallTimeoutMinutes -lt 0) {
   throw 'DependencyInstallTimeoutMinutes deve ser zero ou maior. Use 0 para desabilitar o timeout.'
}

if ([string]::IsNullOrWhiteSpace($GeneratedEnvPath)) {
   $GeneratedEnvPath = $DefaultGeneratedEnvPath
}
else {
   $GeneratedEnvPath = Resolve-ProjectPath $GeneratedEnvPath
}

if ([string]::IsNullOrWhiteSpace($Triplet)) {
   $Triplet = if ($Catalog.defaultTriplet) { [string] $Catalog.defaultTriplet } else { 'x64-windows' }
}

if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
   $VcpkgRoot = Join-Path $ToolsRoot 'vcpkg'
}
else {
   $VcpkgRoot = Resolve-ProjectPath $VcpkgRoot
}

$requestedDependencies = Expand-NameList -Values $Dependency
$ignoredDependencies = @(Expand-NameList -Values $IgnoreDependency | ForEach-Object { Resolve-DependencyName -Catalog $Catalog -Name $_ })
$dependencyNames = Get-DependencyNames -Catalog $Catalog -SetName $Set -Requested $requestedDependencies
$dependencyNames = @($dependencyNames | ForEach-Object { Resolve-DependencyName -Catalog $Catalog -Name $_ })
$dependencyNames = @($dependencyNames | Where-Object { $ignoredDependencies -notcontains $_ })
$envValues = @{}
$results = New-Object System.Collections.Generic.List[object]

foreach ($ignoredName in $ignoredDependencies) {
   $dep = $Catalog.dependencies.$ignoredName
   $depTriplet = Get-DependencyTriplet -DependencyConfig $dep -DefaultTriplet $Triplet
   if ($dep.envVar) {
      $envValues[[string] $dep.envVar] = 'no'
      if ($GenerateEnv) {
         Write-Warning "Gerando $($dep.envVar)=no para ignorar '$ignoredName' no build."
      }
   }

   $depPorts = @(Get-DependencyVcpkgPorts -DependencyConfig $dep)
   $results.Add([pscustomobject]@{
      Name = $ignoredName
      Status = 'ignored'
      EnvVar = $dep.envVar
      EnvValue = if ($dep.envVar) { 'no' } else { '' }
      Header = ''
      Provider = 'ignore'
      Triplet = $depTriplet
      Ports = if ($depPorts.Count -gt 0) { ($depPorts -join ', ') } else { '' }
      InstallState = 'ignored'
      TimeoutMinutes = 0
      Duration = '00:00'
      Failure = ''
      Note = 'ignorada via -IgnoreDependency'
   })
}

$needsVcpkg = $false
if ($Install) {
   foreach ($dependencyName in $dependencyNames) {
      $dependencyConfig = $Catalog.dependencies.$dependencyName
      if (-not $dependencyConfig) {
         throw "Dependencia desconhecida no catalogo: $dependencyName"
      }

      $dependencyAutoInstall = $true
      if ($null -ne $dependencyConfig.autoInstall) {
         $dependencyAutoInstall = [bool] $dependencyConfig.autoInstall
      }

      $dependencyPorts = @(Get-DependencyVcpkgPorts -DependencyConfig $dependencyConfig)
      if ($dependencyAutoInstall -and $dependencyPorts.Count -gt 0) {
         $needsVcpkg = $true
         break
      }
   }
}

$vcpkgExe = ''
if ($Install -and $needsVcpkg) {
   $vcpkgExe = Initialize-Vcpkg -Root $VcpkgRoot
   Initialize-VcpkgBinaryCache -CacheRoot (Join-Path $ToolsRoot 'vcpkg-cache') | Out-Null
}

foreach ($name in $dependencyNames) {
   $dependencyStartedAt = Get-Date
   $dep = $Catalog.dependencies.$name
   if (-not $dep) {
      throw "Dependencia desconhecida no catalogo: $name"
   }

   $depTriplet = Get-DependencyTriplet -DependencyConfig $dep -DefaultTriplet $Triplet
   $depInstalledRoot = Get-VcpkgInstalledRoot -VcpkgRoot $VcpkgRoot -TripletName $depTriplet
   $depInstallTimeout = Get-DependencyInstallTimeoutMinutes -DependencyConfig $dep -DefaultMinutes $DependencyInstallTimeoutMinutes
   $depPorts = @(Get-DependencyVcpkgPorts -DependencyConfig $dep)

   if ($name -eq 'qt') {
      Write-Host ''
      Write-Host "Qt detectado no conjunto de dependencias."
      Write-Host "  qtbase e uma etapa pesada e pode levar horas em build limpo."
      Write-Host "  Triplet efetivo: $depTriplet"
      Write-Host "  Timeout efetivo: $depInstallTimeout minuto(s)"
   }

   $found = Find-Dependency -DependencyConfig $dep -InstalledRoot $depInstalledRoot
   $autoInstall = $true
   if ($null -ne $dep.autoInstall) {
      $autoInstall = [bool] $dep.autoInstall
   }

   $installResult = $null
   $installState = if ($found.Found) { 'found' } else { '' }
   $disableReason = ''
   $failure = ''
   $providerName = if ($autoInstall) { $Provider } else { 'manual' }
   $sourceFallback = Get-DependencySourceFallback -DependencyConfig $dep
   $foundInVcpkg = $found.Found -and (Test-PathUnderRoot -Path $found.Header -Root $depInstalledRoot)
   $tripletSupport = Test-DependencyTripletSupported -DependencyConfig $dep -TripletName $depTriplet
   if (-not $tripletSupport.Supported -and -not $found.Found) {
      $autoInstall = $false
      $providerName = 'manual'
      $disableReason = "$($tripletSupport.Reason); dependencia desativada no build"
   }

   if ($foundInVcpkg) {
      $artifactState = Test-DependencyInstalledArtifacts -DependencyConfig $dep -InstalledRoot $depInstalledRoot
      if ($artifactState.Success) {
         if ($name -eq 'qt') {
            Write-Host "  Qt ja esta valido em: $depInstalledRoot"
         }
      }
      else {
         Write-Warning "Instalacao vcpkg incompleta para '$name' em '$depInstalledRoot': $($artifactState.Missing)"
         $found = [pscustomobject]@{
            Found = $false
            EnvValue = ''
            Header = ''
         }
         $foundInVcpkg = $false
         $installState = ''
      }
   }

   $shouldUseVcpkg = $Install -and $autoInstall -and $depPorts.Count -gt 0 -and (-not $found.Found -or $foundInVcpkg)
   if ($shouldUseVcpkg) {
      $installResult = Install-VcpkgPorts `
         -DependencyName $name `
         -DependencyConfig $dep `
         -VcpkgExe $vcpkgExe `
         -TripletName $depTriplet `
         -Ports $depPorts `
         -LogsRoot $LogsRoot `
         -StateRoot $StateRoot `
         -TimeoutMinutes $depInstallTimeout

      if ($installResult.Success) {
         $installState = [string] $installResult.Action
         if ($installState -ne 'dry-run') {
            $found = Find-Dependency -DependencyConfig $dep -InstalledRoot $depInstalledRoot
         }
      }
      else {
         $failedInstall = $installResult.Failed
         $disableReason = "instalacao falhou para $($failedInstall.Spec): $($failedInstall.Message)"
         $failure = $disableReason
         Write-Warning "Dependencia '$name' desativada: $disableReason"
      }
   }

   if (-not $found.Found -and $Install -and $sourceFallback) {
      $installResult = Install-SourceFallback `
         -DependencyName $name `
         -DependencyConfig $dep `
         -FallbackConfig $sourceFallback

      if ($installResult.Success) {
         $found = $installResult.Found
         $disableReason = ''
         $failure = ''
         $installState = 'source'
         $providerName = 'source'
      }
      else {
         $disableReason = "fallback $($installResult.Spec) falhou: $($installResult.Message)"
         $failure = $disableReason
         Write-Warning "Dependencia '$name' desativada: $disableReason"
      }
   }

   if ($found.Found -and $dep.envVar) {
      $envValues[[string] $dep.envVar] = $found.EnvValue
      if ($null -ne $dep.PSObject.Properties['extraEnv'] -and $null -ne $dep.extraEnv) {
         foreach ($item in @($dep.extraEnv.PSObject.Properties)) {
            if (-not [string]::IsNullOrWhiteSpace($item.Name)) {
               $envValues[$item.Name] = [string] $item.Value
            }
         }
      }

      if ($null -ne $dep.PSObject.Properties['tools'] -and $null -ne $dep.tools) {
         foreach ($tool in @($dep.tools)) {
            $toolEnvVar = [string] $tool.envVar
            if ([string]::IsNullOrWhiteSpace($toolEnvVar)) {
               continue
            }

            $toolValue = Find-ToolEnv -InstalledRoot $depInstalledRoot -ToolConfig $tool
            if (-not [string]::IsNullOrWhiteSpace($toolValue)) {
               $envValues[$toolEnvVar] = $toolValue
            }
         }
      }
   }
   elseif ($dep.envVar) {
      $envValues[[string] $dep.envVar] = 'no'
      if ([string]::IsNullOrWhiteSpace($disableReason)) {
         $disableReason = if ($autoInstall) {
             'nao encontrada; dependencia desativada no build'
          }
          elseif ($sourceFallback) {
             'nao encontrada; execute com -Install para usar o fallback de codigo-fonte'
          }
          else {
             'instalacao manual pendente; dependencia desativada no build'
          }
      }

      if ($GenerateEnv) {
         Write-Warning "Gerando $($dep.envVar)=no para desativar '$name' no build: $disableReason"
      }
   }

   $status = if ($found.Found) { 'ok' } elseif ($installResult -and -not $installResult.Success) { 'disabled' } elseif ($autoInstall -or $sourceFallback) { 'missing' } else { 'manual' }
   if ($found.Found -and [string]::IsNullOrWhiteSpace($installState)) {
      $installState = if ($foundInVcpkg) { 'found' } else { 'manual' }
   }

   $ports = if ($depPorts.Count -gt 0) { ($depPorts -join ', ') } else { '' }
   $noteParts = @()
   if (-not [string]::IsNullOrWhiteSpace($disableReason)) {
      $noteParts += $disableReason
   }
   if (-not [string]::IsNullOrWhiteSpace($dep.note)) {
      $noteParts += [string] $dep.note
   }

   $duration = Format-ActivityElapsed ((Get-Date) - $dependencyStartedAt)
   $results.Add([pscustomobject]@{
      Name = $name
      Status = $status
      EnvVar = $dep.envVar
      EnvValue = if ($found.Found) { $found.EnvValue } elseif ($dep.envVar) { 'no' } else { '' }
      Header = $found.Header
      Provider = $providerName
      Triplet = $depTriplet
      Ports = $ports
      InstallState = $installState
      TimeoutMinutes = $depInstallTimeout
      Duration = $duration
      Failure = $failure
      Note = ($noteParts -join ' ')
   })

   if ($Strict -and $status -ne 'ok') {
      throw "Dependencia '$name' pendente: $disableReason"
   }
}

$resultRows = @($results | ForEach-Object { $_ })
if ($GenerateEnv) {
   Add-VcpkgLinkerFlags -Values $envValues -Results $resultRows -VcpkgRoot $VcpkgRoot -Compiler $HarbourCompiler
   Write-GeneratedEnv -Path $GeneratedEnvPath -Values $envValues
}

$resultRows | Select-Object Name, Status, Provider, Triplet, Ports, InstallState, Duration, EnvVar, EnvValue, Note |
   Format-Table -AutoSize
Write-DependencyReport -Results $resultRows

$missing = @($results | Where-Object { $_.Status -ne 'ok' -and $_.Status -ne 'ignored' })
if ($Strict -and $missing.Count -gt 0) {
   throw "Dependencias pendentes: $($missing.Name -join ', ')"
}

if ($GenerateEnv -and -not $DryRun) {
   Write-Host ''
   Write-Host "Ambiente gerado: $GeneratedEnvPath"
}
