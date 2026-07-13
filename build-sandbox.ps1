[CmdletBinding()]
param(
   [Alias('Profile')]
   [ValidateSet('zig', 'zig-win64-gnu', 'zig-win64-msvc', 'zig-win32-gnu', 'zig-win-arm64', 'zig-linux-x64', 'zig-linux-arm64', 'mingw64')]
   [string] $BuildProfile = 'zig',
   [switch] $Full,
   [switch] $Clean,
   [switch] $Minimal,
   [switch] $NoContrib,
   [switch] $Package,
   [int] $Jobs = 0,
   [string] $HarbourRepository = '',
   [string] $HarbourRef = '',
   [string[]] $MakeArg = @(),
   [string[]] $Dependency = @(),
   [string[]] $IgnoreDependency = @(),
   [switch] $SkipDependencyInstall,
   [switch] $StrictDependencies,
   [switch] $SkipToolBootstrap,
   [switch] $DryRun,
   [int] $MemoryInMB = 8192,
   [int] $SandboxTimeoutMinutes = 240,
   [switch] $NoNetworking,
   [switch] $KeepOpen,
   [switch] $KeepSession,
   [switch] $LocalWorkspace
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$SandboxExe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'

if (-not (Test-Path -LiteralPath $SandboxExe)) {
   throw 'Windows Sandbox nao esta disponivel. Habilite o recurso opcional Containers-DisposableClientVM.'
}
if ($SandboxTimeoutMinutes -le 0) {
   throw 'SandboxTimeoutMinutes deve ser maior que zero.'
}

$activeSandbox = Get-Process -ErrorAction SilentlyContinue |
   Where-Object { $_.ProcessName -in @('WindowsSandboxRemoteSession', 'WindowsSandboxServer', 'vmmemWindowsSandbox') } |
   Select-Object -First 1
if ($activeSandbox) {
   throw "Ja existe uma instancia do Windows Sandbox em execucao (processo $($activeSandbox.ProcessName), PID $($activeSandbox.Id)). Feche-a antes de iniciar outro build."
}

foreach ($directory in @('scratch', 'tools', 'logs', 'out')) {
   $path = Join-Path $ProjectRoot $directory
   if (-not (Test-Path -LiteralPath $path)) {
      [void] (New-Item -ItemType Directory -Path $path)
   }
}

$sessionId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$sessionBase = Join-Path ([System.IO.Path]::GetTempPath()) 'hb_compile-sandbox'
$sessionRoot = Join-Path $sessionBase $sessionId
[void] (New-Item -ItemType Directory -Path $sessionRoot -Force)
$guestSession = 'C:\SandboxSession'

function ConvertTo-XmlText {
   param([Parameter(Mandatory = $true)][string] $Value)
   return [System.Security.SecurityElement]::Escape($Value)
}

$request = [ordered]@{
   BuildProfile = $BuildProfile
   Full = [bool] $Full
   Clean = [bool] $Clean
   Minimal = [bool] $Minimal
   NoContrib = [bool] $NoContrib
   Package = [bool] $Package
   Jobs = $Jobs
   HarbourRepository = $HarbourRepository
   HarbourRef = $HarbourRef
   MakeArg = @($MakeArg)
   Dependency = @($Dependency)
   IgnoreDependency = @($IgnoreDependency)
   SkipDependencyInstall = [bool] $SkipDependencyInstall
   StrictDependencies = [bool] $StrictDependencies
   SkipToolBootstrap = [bool] $SkipToolBootstrap
   DryRun = [bool] $DryRun
   KeepOpen = [bool] $KeepOpen
   LocalWorkspace = [bool] $LocalWorkspace
}
$request | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $sessionRoot 'request.json') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'scripts\Invoke-SandboxBuild.ps1') -Destination $sessionRoot

$sourceSnapshot = Join-Path $sessionRoot 'source'
& robocopy.exe $ProjectRoot $sourceSnapshot /E /XD .git scratch tools logs out | Out-Null
if ($LASTEXITCODE -ge 8) {
   throw "Nao foi possivel preparar o snapshot para o Sandbox (robocopy=$LASTEXITCODE)."
}

$mappings = @(
   @{ Host = (Join-Path $ProjectRoot 'scratch'); Guest = 'C:\Persistent\scratch'; ReadOnly = 'false' },
   @{ Host = (Join-Path $ProjectRoot 'tools'); Guest = 'C:\Persistent\tools'; ReadOnly = 'false' },
   @{ Host = (Join-Path $ProjectRoot 'logs'); Guest = 'C:\Persistent\logs'; ReadOnly = 'false' },
   @{ Host = (Join-Path $ProjectRoot 'out'); Guest = 'C:\Persistent\out'; ReadOnly = 'false' },
   @{ Host = $sessionRoot; Guest = $guestSession; ReadOnly = 'false' }
)
$mappingXml = ($mappings | ForEach-Object {
   "<MappedFolder><HostFolder>$(ConvertTo-XmlText $_.Host)</HostFolder><SandboxFolder>$($_.Guest)</SandboxFolder><ReadOnly>$($_.ReadOnly)</ReadOnly></MappedFolder>"
}) -join "`r`n      "
$networking = if ($NoNetworking) { 'Disable' } else { 'Default' }
$command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $guestSession\Invoke-SandboxBuild.ps1"
$wsb = @"
<Configuration>
  <MappedFolders>
      $mappingXml
  </MappedFolders>
  <Networking>$networking</Networking>
  <MemoryInMB>$MemoryInMB</MemoryInMB>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <LogonCommand><Command>$(ConvertTo-XmlText $command)</Command></LogonCommand>
</Configuration>
"@
$wsbPath = Join-Path $sessionRoot 'hb-compile.wsb'
$wsb | Set-Content -LiteralPath $wsbPath -Encoding UTF8

Write-Host "Sandbox session: $sessionRoot"
Write-Host "Perfil:         $BuildProfile"
Write-Host "Workspace:      $(if ($LocalWorkspace) { 'local ao Sandbox' } else { 'diretorios mapeados do host' })"
Write-Host "Configuracao:   $wsbPath"

$process = Start-Process -FilePath $SandboxExe -ArgumentList ('"' + $wsbPath + '"') -PassThru

$resultPath = Join-Path $sessionRoot 'result.json'
$resultDeadline = (Get-Date).AddMinutes($SandboxTimeoutMinutes)
$startupDeadline = (Get-Date).AddSeconds(60)
$result = $null
while ($null -eq $result -and (Get-Date) -lt $resultDeadline) {
   if (Test-Path -LiteralPath $resultPath) {
      try {
         $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
      }
      catch {
         $result = $null
      }
   }
   if ($null -ne $result) { break }

   if ((Get-Date) -ge $startupDeadline -and $process.HasExited) {
      $sandboxRunning = Get-Process -ErrorAction SilentlyContinue |
         Where-Object { $_.ProcessName -in @('WindowsSandboxRemoteSession', 'WindowsSandboxServer', 'vmmemWindowsSandbox') } |
         Select-Object -First 1
      if (-not $sandboxRunning) {
         throw "O launcher do Windows Sandbox encerrou sem iniciar a VM. Consulte: $sessionRoot"
      }
   }

   Start-Sleep -Milliseconds 500
}
if ($null -eq $result) {
   throw "O Sandbox nao gravou resultado em $SandboxTimeoutMinutes minuto(s). Consulte: $sessionRoot"
}
if (-not $KeepSession -and $result.ExitCode -eq 0) {
   Remove-Item -LiteralPath $sessionRoot -Recurse -Force
}
if ($result.ExitCode -ne 0) {
   $errorMessage = [string] $result.Error
   if (-not [string]::IsNullOrWhiteSpace($errorMessage)) {
      # Paths reported by the build refer to the guest workspace. The persistent
      # directories are mapped to the project on the host, so expose a path the
      # caller can actually open after the Sandbox closes.
      $guestProjectPrefix = 'C:\hb_compile\'
      if ($errorMessage.StartsWith($guestProjectPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
         $errorMessage = Join-Path $ProjectRoot $errorMessage.Substring($guestProjectPrefix.Length)
      }
      else {
         $escapedGuestPrefix = [regex]::Escape($guestProjectPrefix)
         $errorMessage = [regex]::Replace(
            $errorMessage,
            $escapedGuestPrefix,
            { param($match) $ProjectRoot.TrimEnd('\') + '\' },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
         )
      }
   }
   $detail = if ([string]::IsNullOrWhiteSpace($errorMessage)) { '' } else { " Erro: $errorMessage" }
   throw "Build no Sandbox falhou com codigo $($result.ExitCode).$detail Sessao: $sessionRoot"
}
Write-Host 'Build no Windows Sandbox concluido.' -ForegroundColor Green
