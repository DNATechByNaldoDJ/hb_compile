[CmdletBinding()]
param(
   [Alias('Profile')]
   [string[]] $BuildProfile = @(),
   [switch] $All,
   [Alias('CygwinBash')]
   [string] $CygwinPath = '',
   [Alias('MsysBash')]
   [string] $MsysPath = '',
   [string] $CygwinSetup = '',
   [string] $WslDistro = '',
   [string] $WslUser = '',
   [string] $DockerImage = '',
   [ValidateRange(1, 86400)]
   [int] $TimeoutSeconds = 300,
   [switch] $CompileOnly,
   [switch] $DryRun,
   [switch] $SkipToolBootstrap,
   [switch] $Internal
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Config = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config\profiles.json') -Raw | ConvertFrom-Json
$ToolsRoot = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $Config.toolsRoot))
$OutputRoot = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $Config.outputRoot))

function Get-ConfigString {
   param(
      [Parameter(Mandatory = $true)] $Object,
      [Parameter(Mandatory = $true)][string] $Name,
      [string] $Default = ''
   )

   $property = $Object.PSObject.Properties[$Name]
   if ($property -and -not [string]::IsNullOrWhiteSpace([string] $property.Value)) {
      return [string] $property.Value
   }
   return $Default
}

function Get-InstallRoot {
   param([Parameter(Mandatory = $true)][string] $Name)

   $profileConfig = $Config.profiles.$Name
   if (-not $profileConfig) {
      throw "Perfil '$Name' nao existe."
   }
   $subdir = Get-ConfigString -Object $profileConfig -Name 'installSubdir' -Default $Name
   return Join-Path $OutputRoot $subdir
}

function Get-Hbmk2Path {
   param([Parameter(Mandatory = $true)][string] $Name)

   $binRoot = Join-Path (Get-InstallRoot -Name $Name) 'bin'
   foreach ($candidate in @((Join-Path $binRoot 'hbmk2.exe'), (Join-Path $binRoot 'hbmk2'))) {
      if (Test-Path -LiteralPath $candidate) {
         return [System.IO.Path]::GetFullPath($candidate)
      }
   }
   return ''
}

function Format-ShArgument {
   param([AllowEmptyString()][string] $Value)
   return "'" + ($Value -replace "'", "'\''") + "'"
}

function Format-CommandArgument {
   param([string] $Value)
   if ($Value -match '[\s"]') {
      return '"' + ($Value -replace '"', '\"') + '"'
   }
   return $Value
}

function Invoke-NativeCommandWithTimeout {
   param(
      [Parameter(Mandatory = $true)][string] $FilePath,
      [string[]] $Arguments = @(),
      [Parameter(Mandatory = $true)][string] $Description
   )

   $argumentLine = ($Arguments | ForEach-Object { Format-CommandArgument ([string] $_) }) -join ' '
   $process = Start-Process `
      -FilePath $FilePath `
      -ArgumentList $argumentLine `
      -NoNewWindow `
      -PassThru
   [void] $process.Handle
   $exitCode = 0
   try {
      if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
         & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
         throw "$Description excedeu o timeout de $TimeoutSeconds segundo(s)."
      }
      $exitCode = $process.ExitCode
   }
   finally {
      $process.Dispose()
   }
   return $exitCode
}

function ConvertTo-RunnerPath {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][ValidateSet('cygwin', 'msys', 'wsl', 'docker')][string] $Runner
   )

   $fullPath = [System.IO.Path]::GetFullPath($Path)
   if ($Runner -eq 'docker') {
      $projectFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
      if (-not $fullPath.Equals($projectFull, [System.StringComparison]::OrdinalIgnoreCase) -and
         -not $fullPath.StartsWith("$projectFull\", [System.StringComparison]::OrdinalIgnoreCase)) {
         throw "Path fora do volume Docker: $Path"
      }
      $relative = $fullPath.Substring($projectFull.Length).TrimStart('\').Replace('\', '/')
      return "/workspace/$relative".TrimEnd('/')
   }

   $root = [System.IO.Path]::GetPathRoot($fullPath)
   if ($root -notmatch '^([A-Za-z]):\\$') {
      throw "Nao foi possivel converter o path: $Path"
   }
   $drive = $matches[1].ToLowerInvariant()
   $relative = $fullPath.Substring($root.Length).Replace('\', '/')
   switch ($Runner) {
      'cygwin' { return "/cygdrive/$drive/$relative".TrimEnd('/') }
      'msys' { return "/$drive/$relative".TrimEnd('/') }
      'wsl' { return "/mnt/$drive/$relative".TrimEnd('/') }
   }
}

function Invoke-BashProbe {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][string] $Script
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
      if (-not $process.WaitForExit(5000)) {
         $process.Kill()
         return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'timeout' }
      }
      return [pscustomobject]@{
         ExitCode = $process.ExitCode
         StdOut = $process.StandardOutput.ReadToEnd()
         StdErr = $process.StandardError.ReadToEnd()
      }
   }
   catch {
      return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message }
   }
   finally {
      if ($process) {
         $process.Dispose()
      }
   }
}

function Test-BashEnvironment {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][ValidateSet('cygwin', 'msys')][string] $Environment
   )

   try {
      if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) {
         return $false
      }
   }
   catch {
      return $false
   }
   $probe = Invoke-BashProbe -Path $Path -Script 'uname -s'
   if ($Environment -eq 'cygwin') {
      return $probe.ExitCode -eq 0 -and $probe.StdOut -match 'CYGWIN'
   }
   return $probe.ExitCode -eq 0 -and $probe.StdOut -match 'MSYS|MINGW'
}

function Find-EnvironmentBash {
   param(
      [Parameter(Mandatory = $true)][string] $Root,
      [Parameter(Mandatory = $true)][ValidateSet('cygwin', 'msys')][string] $Environment
   )

   try {
      if (-not (Test-Path -LiteralPath $Root -ErrorAction Stop)) {
         return $null
      }
   }
   catch {
      return $null
   }
   if (Test-Path -LiteralPath $Root -PathType Leaf) {
      if (Test-BashEnvironment -Path $Root -Environment $Environment) {
         return (Get-Item -LiteralPath $Root)
      }
      return $null
   }

   return Get-ChildItem -LiteralPath $Root -Filter 'bash.exe' -Recurse -ErrorAction SilentlyContinue |
      Where-Object { Test-BashEnvironment -Path $_.FullName -Environment $Environment } |
      Sort-Object -Property FullName |
      Select-Object -First 1
}

function Resolve-EnvironmentBash {
   param(
      [Parameter(Mandatory = $true)][ValidateSet('cygwin', 'msys')][string] $Environment,
      [string] $ExplicitPath,
      [string] $SetupPath = ''
   )

   if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
      $explicitFull = if ([System.IO.Path]::IsPathRooted($ExplicitPath)) {
         [System.IO.Path]::GetFullPath($ExplicitPath)
      }
      else {
         [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $ExplicitPath))
      }
      $explicit = Find-EnvironmentBash -Root $explicitFull -Environment $Environment
      if ($explicit) {
         return $explicit.FullName
      }
      throw "$Environment nao encontrado em '$ExplicitPath'."
   }

   $local = Find-EnvironmentBash -Root (Join-Path $ToolsRoot $Environment) -Environment $Environment
   if ($local) {
      return $local.FullName
   }

   $candidates = New-Object System.Collections.Generic.List[string]
   foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
      if ($Environment -eq 'cygwin') {
         $candidates.Add((Join-Path $drive.Root 'cygwin64\bin\bash.exe'))
         $candidates.Add((Join-Path $drive.Root 'cygwin\bin\bash.exe'))
      }
      else {
         $candidates.Add((Join-Path $drive.Root 'msys64\usr\bin\bash.exe'))
         $candidates.Add((Join-Path $drive.Root 'msys32\usr\bin\bash.exe'))
      }
   }
   $pathBash = Get-Command 'bash.exe' -ErrorAction SilentlyContinue
   if ($pathBash) {
      $candidates.Add($pathBash.Source)
   }
   foreach ($candidate in @($candidates | Select-Object -Unique)) {
      if (Test-BashEnvironment -Path $candidate -Environment $Environment) {
         return [System.IO.Path]::GetFullPath($candidate)
      }
   }

   if ($DryRun) {
      $predicted = if ($Environment -eq 'cygwin') {
         Join-Path $ToolsRoot 'cygwin\bin\bash.exe'
      }
      else {
         Join-Path $ToolsRoot 'msys\msys64\usr\bin\bash.exe'
      }
      Write-Host "DryRun: prepararia $Environment com scripts\Bootstrap-Tools.ps1"
      return $predicted
   }

   if (-not $SkipToolBootstrap) {
      $bootstrapArgs = @{ Tool = if ($Environment -eq 'cygwin') { 'Cygwin' } else { 'MSYS' } }
      if ($Environment -eq 'cygwin' -and -not [string]::IsNullOrWhiteSpace($SetupPath)) {
         $bootstrapArgs['CygwinSetup'] = $SetupPath
      }
      & (Join-Path $PSScriptRoot 'Bootstrap-Tools.ps1') @bootstrapArgs
      $local = Find-EnvironmentBash -Root (Join-Path $ToolsRoot $Environment) -Environment $Environment
      if ($local) {
         return $local.FullName
      }
   }

   throw "Ambiente $Environment nao foi encontrado."
}

function Import-VsDevShell {
   if (Get-Command 'cl.exe' -ErrorAction SilentlyContinue) {
      return
   }

   $vswhere = @(
      "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
      "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
   ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
   if (-not $vswhere) {
      throw 'vswhere.exe nao foi encontrado para preparar o ambiente MSVC.'
   }

   $installPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
   $vcvars = Join-Path $installPath 'VC\Auxiliary\Build\vcvarsall.bat'
   if (-not (Test-Path -LiteralPath $vcvars)) {
      throw 'Visual Studio C++ Build Tools nao foi encontrado.'
   }

   $lines = & cmd.exe /d /s /c ('"' + $vcvars + '" amd64 >nul && set')
   foreach ($line in $lines) {
      if ($line -match '^([^=]+)=(.*)$') {
         [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
      }
   }
}

function Get-EnvironmentMap {
   param(
      [Parameter(Mandatory = $true)] $ProfileConfig,
      [Parameter(Mandatory = $true)][string] $InstallRoot,
      [Parameter(Mandatory = $true)][string] $Runner
   )

   $map = [ordered]@{ HB_INSTALL_PREFIX = $InstallRoot }
   foreach ($item in @($ProfileConfig.env.PSObject.Properties)) {
      $map[$item.Name] = [string] $item.Value
   }
   if ($Runner -ne 'windows') {
      $map['HB_INSTALL_PREFIX'] = ConvertTo-RunnerPath -Path $InstallRoot -Runner $Runner
   }
   return $map
}

function Get-EnvironmentAssignments {
   param([Parameter(Mandatory = $true)] $EnvironmentMap)

   return @($EnvironmentMap.Keys | ForEach-Object {
      "$_=$(Format-ShArgument ([string] $EnvironmentMap[$_]))"
   }) -join ' '
}

function Get-WslArguments {
   $arguments = @()
   if (-not [string]::IsNullOrWhiteSpace($WslDistro)) {
      $arguments += @('-d', $WslDistro)
   }
   if (-not [string]::IsNullOrWhiteSpace($WslUser)) {
      $arguments += @('--user', $WslUser)
   }
   return $arguments
}

function Invoke-SingleBuildTest {
   param([Parameter(Mandatory = $true)][string] $Name)

   $profileConfig = $Config.profiles.$Name
   if (-not $profileConfig) {
      throw "Perfil '$Name' nao existe."
   }

   $installRoot = Get-InstallRoot -Name $Name
   $hbmk2 = Get-Hbmk2Path -Name $Name
   if ([string]::IsNullOrWhiteSpace($hbmk2)) {
      throw "hbmk2 nao encontrado para '$Name' em: $installRoot"
   }

   $sample = Join-Path $ProjectRoot 'samples\hello.prg'
   $testRoot = Join-Path (Join-Path $ProjectRoot 'scratch\tests') $Name
   $outBase = Join-Path $testRoot 'hello'
   if (-not $DryRun) {
      New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
      foreach ($oldOutput in @("$outBase.exe", $outBase)) {
         if (Test-Path -LiteralPath $oldOutput -PathType Leaf) {
            Remove-Item -LiteralPath $oldOutput -Force
         }
      }
   }

   $runner = (Get-ConfigString -Object $profileConfig -Name 'runner' -Default 'windows').ToLowerInvariant()
   Write-Host "Perfil : $Name"
   Write-Host "Runner : $runner"
   Write-Host "hbmk2  : $hbmk2"

   if ($runner -eq 'windows') {
      $compiler = [string] $profileConfig.env.HB_COMPILER
      if (-not $DryRun -and -not $SkipToolBootstrap -and $compiler -like 'mingw*') {
         & (Join-Path $PSScriptRoot 'Bootstrap-Tools.ps1') -Tool MinGW64
      }
      elseif (-not $DryRun -and -not $SkipToolBootstrap -and $compiler -eq 'zig') {
         & (Join-Path $PSScriptRoot 'Bootstrap-Tools.ps1') -Tool Zig
      }
      elseif (-not $DryRun -and $compiler -like 'msvc*') {
         Import-VsDevShell
      }

      if ($DryRun) {
         Write-Host "DryRun: $hbmk2 $sample -o$outBase"
         return
      }

      & (Join-Path $PSScriptRoot 'Test-HarbourInstall.ps1') `
         -BuildProfile $Name `
         -CompileOnly:$CompileOnly
      return
   }

   $environmentMap = Get-EnvironmentMap -ProfileConfig $profileConfig -InstallRoot $installRoot -Runner $runner
   $assignments = Get-EnvironmentAssignments -EnvironmentMap $environmentMap

   if ($runner -eq 'cygwin' -or $runner -eq 'msys') {
      $explicitPath = if ($runner -eq 'cygwin') { $CygwinPath } else { $MsysPath }
      $bash = Resolve-EnvironmentBash -Environment $runner -ExplicitPath $explicitPath -SetupPath $CygwinSetup
      $binPath = ConvertTo-RunnerPath -Path (Split-Path -Parent $hbmk2) -Runner $runner
      $hbmkPath = ConvertTo-RunnerPath -Path $hbmk2 -Runner $runner
      $samplePath = ConvertTo-RunnerPath -Path $sample -Runner $runner
      $outPath = ConvertTo-RunnerPath -Path $outBase -Runner $runner
      $script = "export HOME=/tmp; export PATH=$(Format-ShArgument $binPath):`"`$PATH`"; env $assignments $(Format-ShArgument $hbmkPath) $(Format-ShArgument $samplePath) $(Format-ShArgument "-o$outPath")"
      if (-not $CompileOnly) {
         $script += " && $(Format-ShArgument "$outPath.exe")"
      }
      if ($DryRun) {
         Write-Host "DryRun: $bash -lc $(Format-ShArgument $script)"
         return
      }
      $exitCode = Invoke-NativeCommandWithTimeout `
         -FilePath $bash `
         -Arguments @('-lc', $script) `
         -Description "Teste $runner"
      if ($exitCode -ne 0) {
         throw "Teste $runner falhou com codigo $exitCode."
      }
      return
   }

   if ($runner -eq 'wsl') {
      $binPath = ConvertTo-RunnerPath -Path (Split-Path -Parent $hbmk2) -Runner wsl
      $hbmkPath = ConvertTo-RunnerPath -Path $hbmk2 -Runner wsl
      $samplePath = ConvertTo-RunnerPath -Path $sample -Runner wsl
      $outPath = ConvertTo-RunnerPath -Path $outBase -Runner wsl
      $script = "export PATH=$(Format-ShArgument $binPath):`"`$PATH`"; env $assignments $(Format-ShArgument $hbmkPath) $(Format-ShArgument $samplePath) $(Format-ShArgument "-o$outPath")"
      if (-not $CompileOnly) {
         $script += " && $(Format-ShArgument $outPath)"
      }
      if ($DryRun) {
         Write-Host "DryRun: wsl.exe $(@(Get-WslArguments) -join ' ') bash -c $(Format-ShArgument $script)"
         return
      }
      $wslArguments = @(Get-WslArguments) + @('bash', '-c', $script)
      $exitCode = Invoke-NativeCommandWithTimeout `
         -FilePath 'wsl.exe' `
         -Arguments $wslArguments `
         -Description 'Teste WSL'
      if ($exitCode -ne 0) {
         throw "Teste WSL falhou com codigo $exitCode."
      }
      return
   }

   if ($runner -eq 'docker') {
      $docker = Get-Command 'docker.exe' -ErrorAction SilentlyContinue
      if (-not $docker) {
         $docker = Get-Command 'docker' -ErrorAction SilentlyContinue
      }
      if (-not $docker) {
         throw 'Docker nao foi encontrado.'
      }
      $image = if ([string]::IsNullOrWhiteSpace($DockerImage)) {
         Get-ConfigString -Object $profileConfig -Name 'dockerImage' -Default 'hb-compile/linux:base'
      }
      else {
         $DockerImage
      }
      $binPath = ConvertTo-RunnerPath -Path (Split-Path -Parent $hbmk2) -Runner docker
      $hbmkPath = ConvertTo-RunnerPath -Path $hbmk2 -Runner docker
      $samplePath = ConvertTo-RunnerPath -Path $sample -Runner docker
      $outPath = ConvertTo-RunnerPath -Path $outBase -Runner docker
      $script = "export PATH=$(Format-ShArgument $binPath):`"`$PATH`"; env $assignments $(Format-ShArgument $hbmkPath) $(Format-ShArgument $samplePath) $(Format-ShArgument "-o$outPath")"
      if (-not $CompileOnly) {
         $script += " && $(Format-ShArgument $outPath)"
      }
      if ($DryRun) {
         Write-Host "DryRun: $($docker.Source) run --rm -v ${ProjectRoot}:/workspace -w /workspace $image bash -lc $(Format-ShArgument $script)"
         return
      }
      $dockerArguments = @('run', '--rm', '-v', "${ProjectRoot}:/workspace", '-w', '/workspace', $image, 'bash', '-lc', $script)
      $exitCode = Invoke-NativeCommandWithTimeout `
         -FilePath $docker.Source `
         -Arguments $dockerArguments `
         -Description 'Teste Docker'
      if ($exitCode -ne 0) {
         throw "Teste Docker falhou com codigo $exitCode."
      }
      return
   }

   throw "Runner nao suportado: $runner"
}

$requestedProfiles = @($BuildProfile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if (-not $Internal -and ($All -or $requestedProfiles.Count -ne 1)) {
   if ($requestedProfiles.Count -eq 0) {
      $requestedProfiles = @($Config.profiles.PSObject.Properties.Name | Where-Object {
         -not [string]::IsNullOrWhiteSpace((Get-Hbmk2Path -Name $_))
      })
   }
   if ($requestedProfiles.Count -eq 0) {
      throw 'Nenhum build Harbour instalado foi encontrado em out\.'
   }

   $powerShell = (Get-Command 'powershell.exe' -ErrorAction Stop).Source
   $results = New-Object System.Collections.Generic.List[object]
   foreach ($name in $requestedProfiles) {
      Write-Host ''
      Write-Host "===== $name ====="
      $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Profile', $name, '-Internal')
      if ($CompileOnly) { $childArgs += '-CompileOnly' }
      if ($DryRun) { $childArgs += '-DryRun' }
      if ($SkipToolBootstrap) { $childArgs += '-SkipToolBootstrap' }
      if (-not [string]::IsNullOrWhiteSpace($CygwinPath)) { $childArgs += @('-CygwinPath', $CygwinPath) }
      if (-not [string]::IsNullOrWhiteSpace($MsysPath)) { $childArgs += @('-MsysPath', $MsysPath) }
      if (-not [string]::IsNullOrWhiteSpace($CygwinSetup)) { $childArgs += @('-CygwinSetup', $CygwinSetup) }
      if (-not [string]::IsNullOrWhiteSpace($WslDistro)) { $childArgs += @('-WslDistro', $WslDistro) }
      if (-not [string]::IsNullOrWhiteSpace($WslUser)) { $childArgs += @('-WslUser', $WslUser) }
      if (-not [string]::IsNullOrWhiteSpace($DockerImage)) { $childArgs += @('-DockerImage', $DockerImage) }
      $childArgs += @('-TimeoutSeconds', [string] $TimeoutSeconds)

      $childArgumentLine = ($childArgs | ForEach-Object { Format-CommandArgument ([string] $_) }) -join ' '
      $childProcess = Start-Process `
         -FilePath $powerShell `
         -ArgumentList $childArgumentLine `
         -NoNewWindow `
         -PassThru
      [void] $childProcess.Handle
      if (-not $childProcess.WaitForExit(($TimeoutSeconds + 30) * 1000)) {
         & taskkill.exe /PID $childProcess.Id /T /F 2>$null | Out-Null
         $childExitCode = 124
         Write-Error "Teste '$name' excedeu o timeout de $TimeoutSeconds segundo(s)." -ErrorAction Continue
      }
      else {
         $childExitCode = $childProcess.ExitCode
      }
      $childProcess.Dispose()
      $results.Add([pscustomobject]@{
         Profile = $name
         Status = if ($childExitCode -eq 0) { 'OK' } else { 'FALHOU' }
         ExitCode = $childExitCode
      })
   }

   Write-Host ''
   Write-Host 'Resumo do sample hello.prg:'
   $results | Format-Table -AutoSize
   if (@($results | Where-Object { $_.ExitCode -ne 0 }).Count -gt 0) {
      throw 'Um ou mais builds falharam no teste de samples\hello.prg.'
   }
   return
}

if ($requestedProfiles.Count -ne 1) {
   throw 'Informe exatamente um perfil ou use -All.'
}

Invoke-SingleBuildTest -Name $requestedProfiles[0]
Write-Host "Teste concluido: $($requestedProfiles[0])"
