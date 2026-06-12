[CmdletBinding()]
param(
   [ValidateSet('full', 'network', 'database', 'gui', 'graphics')]
   [string] $Set = 'full',
   [string[]] $Dependency = @(),
   [ValidateSet('vcpkg')]
   [string] $Provider = 'vcpkg',
   [string] $Triplet = '',
   [string] $VcpkgRoot = '',
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
$GeneratedEnvPath = Join-Path $ProjectRoot 'config\external-deps.generated.ps1'
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

function Find-Dependency {
   param(
      [Parameter(Mandatory = $true)] $DependencyConfig,
      [string] $InstalledRoot
   )

   $roots = New-Object System.Collections.Generic.List[string]
   $envVar = [string] $DependencyConfig.envVar
   if (-not [string]::IsNullOrWhiteSpace($envVar)) {
      $current = [System.Environment]::GetEnvironmentVariable($envVar, 'Process')
      if (-not [string]::IsNullOrWhiteSpace($current)) {
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

function Install-VcpkgPorts {
   param(
      [Parameter(Mandatory = $true)][string] $VcpkgExe,
      [Parameter(Mandatory = $true)][string] $TripletName,
      [Parameter(Mandatory = $true)][string[]] $Ports,
      [Parameter(Mandatory = $true)][string] $LogsRoot,
      [int] $TimeoutMinutes = 0
   )

   New-Item -ItemType Directory -Force -Path $LogsRoot | Out-Null
   $installResults = New-Object System.Collections.Generic.List[object]

   foreach ($port in $Ports) {
      # Para qtbase, usa triplet customizado que desabilita DWM
      $triplet = if ($port -eq "qtbase") { "x64-windows-no-dwm" } else { $TripletName }
      $spec = "$port`:$triplet"

      # Prepara argumentos adicionais
      $vcpkgArgs = @($spec)

      # Se for qtbase, usa overlay de triplets
      if ($port -eq "qtbase") {
         $vcpkgRoot = Split-Path -Parent $VcpkgExe
         $tripletDir = Join-Path $vcpkgRoot "triplets\custom"
         if (Test-Path $tripletDir) {
            $vcpkgArgs += "--overlay-triplets=$tripletDir"
         }
      }

      if ($DryRun) {
         Write-Host "DryRun: $VcpkgExe install $($vcpkgArgs -join ' ')"
         $installResults.Add([pscustomobject]@{
            Success = $true
            Port = $port
            Spec = $spec
            Message = 'dry-run'
            StdOutPath = ''
            StdErrPath = ''
         })
         continue
      }

      $safeSpec = Get-SafeFileName $spec
      $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
      $stdoutPath = Join-Path $LogsRoot "$stamp-vcpkg-$safeSpec.out.log"
      $stderrPath = Join-Path $LogsRoot "$stamp-vcpkg-$safeSpec.err.log"
      $activity = "vcpkg install $spec"

      Write-Host "$activity"
      Write-Host "  Logs: $stdoutPath / $stderrPath"

      $processResult = Invoke-ProcessWithTimeout `
         -FilePath $VcpkgExe `
         -Arguments (@('install') + $vcpkgArgs) `
         -WorkingDirectory (Split-Path -Parent $VcpkgExe) `
         -StdOutPath $stdoutPath `
         -StdErrPath $stderrPath `
         -Activity $activity `
         -TimeoutMinutes $TimeoutMinutes

      $success = ($processResult.ExitCode -eq 0 -and -not $processResult.TimedOut)
      $installResults.Add([pscustomobject]@{
         Success = $success
         Port = $port
         Spec = $spec
         Message = $processResult.Message
         StdOutPath = $processResult.StdOutPath
         StdErrPath = $processResult.StdErrPath
      })

      if (-not $success) {
         Write-Warning "$activity falhou ($($processResult.Message)). A dependencia sera desativada e o processo continuara."
         Write-Warning "Consulte os logs: $($processResult.StdOutPath) / $($processResult.StdErrPath)"
         break
      }
   }

   $failed = @($installResults | Where-Object { -not $_.Success } | Select-Object -First 1)
   $failedItem = $null
   if ($failed.Count -gt 0) {
      $failedItem = $failed[0]
   }

   return [pscustomobject]@{
      Success = ($failed.Count -eq 0)
      Failed = $failedItem
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

   foreach ($directory in @($ToolConfig.directories)) {
      $candidate = Join-NativePath -Root $InstalledRoot -Child (Join-Path $directory $ToolConfig.name)
      if (Test-Path -LiteralPath $candidate) {
         return Split-Path -Parent $candidate
      }
   }

   $found = Get-ChildItem -LiteralPath $InstalledRoot -Filter $ToolConfig.name -Recurse -ErrorAction SilentlyContinue |
      Select-Object -First 1
   if ($found) {
      return $found.Directory.FullName
   }

   return ''
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

if (-not (Test-Path -LiteralPath $CatalogPath)) {
   throw "Catalogo de dependencias nao encontrado: $CatalogPath"
}

$Catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$Profiles = Get-Content -LiteralPath $ProfilesPath -Raw | ConvertFrom-Json
$LogsRoot = Resolve-ProjectPath $Profiles.logsRoot

if (Test-Path -LiteralPath $LocalEnvPath) {
   . $LocalEnvPath
}

if ($DependencyInstallTimeoutMinutes -lt 0) {
   throw 'DependencyInstallTimeoutMinutes deve ser zero ou maior. Use 0 para desabilitar o timeout.'
}

if ([string]::IsNullOrWhiteSpace($Triplet)) {
   $Triplet = if ($Catalog.defaultTriplet) { [string] $Catalog.defaultTriplet } else { 'x64-windows' }
}

if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
   $toolsRoot = Resolve-ProjectPath $Profiles.toolsRoot
   $VcpkgRoot = Join-Path $toolsRoot 'vcpkg'
}
else {
   $VcpkgRoot = Resolve-ProjectPath $VcpkgRoot
}

$dependencyNames = Get-DependencyNames -Catalog $Catalog -SetName $Set -Requested $Dependency
$installedRoot = Join-Path $VcpkgRoot "installed\$Triplet"
$envValues = @{}
$results = New-Object System.Collections.Generic.List[object]

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

      if ($dependencyAutoInstall -and $dependencyConfig.vcpkgPorts) {
         $needsVcpkg = $true
         break
      }
   }
}

$vcpkgExe = ''
if ($Install -and $needsVcpkg) {
   $vcpkgExe = Initialize-Vcpkg -Root $VcpkgRoot
}

foreach ($name in $dependencyNames) {
   $dep = $Catalog.dependencies.$name
   if (-not $dep) {
      throw "Dependencia desconhecida no catalogo: $name"
   }

   $found = Find-Dependency -DependencyConfig $dep -InstalledRoot $installedRoot
   $autoInstall = $true
   if ($null -ne $dep.autoInstall) {
      $autoInstall = [bool] $dep.autoInstall
   }

   $installResult = $null
   $disableReason = ''
   $providerName = if ($autoInstall) { $Provider } else { 'manual' }
   $sourceFallback = Get-DependencySourceFallback -DependencyConfig $dep

   if (-not $found.Found -and $Install -and $autoInstall -and $dep.vcpkgPorts) {
      $installResult = Install-VcpkgPorts `
         -VcpkgExe $vcpkgExe `
         -TripletName $Triplet `
         -Ports @($dep.vcpkgPorts) `
         -LogsRoot $LogsRoot `
         -TimeoutMinutes $DependencyInstallTimeoutMinutes

      if ($installResult.Success) {
         $found = Find-Dependency -DependencyConfig $dep -InstalledRoot $installedRoot
      }
      else {
         $failedInstall = $installResult.Failed
         $disableReason = "instalacao falhou para $($failedInstall.Spec): $($failedInstall.Message)"
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
         $providerName = 'source'
      }
      else {
         $disableReason = "fallback $($installResult.Spec) falhou: $($installResult.Message)"
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

            $toolValue = Find-ToolEnv -InstalledRoot $installedRoot -ToolConfig $tool
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
   $ports = if ($dep.vcpkgPorts) { (@($dep.vcpkgPorts) -join ', ') } else { '' }
   $noteParts = @()
   if (-not [string]::IsNullOrWhiteSpace($disableReason)) {
      $noteParts += $disableReason
   }
   if (-not [string]::IsNullOrWhiteSpace($dep.note)) {
      $noteParts += [string] $dep.note
   }

   $results.Add([pscustomobject]@{
      Name = $name
      Status = $status
      EnvVar = $dep.envVar
      EnvValue = if ($found.Found) { $found.EnvValue } elseif ($dep.envVar) { 'no' } else { '' }
      Header = $found.Header
      Provider = $providerName
      Ports = $ports
      Note = ($noteParts -join ' ')
   })
}

if ($GenerateEnv) {
   Write-GeneratedEnv -Path $GeneratedEnvPath -Values $envValues
}

$results | Format-Table -AutoSize

$missing = @($results | Where-Object { $_.Status -ne 'ok' })
if ($Strict -and $missing.Count -gt 0) {
   throw "Dependencias pendentes: $($missing.Name -join ', ')"
}

if ($GenerateEnv -and -not $DryRun) {
   Write-Host ''
   Write-Host "Ambiente gerado: $GeneratedEnvPath"
}
