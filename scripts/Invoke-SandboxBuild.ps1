[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sessionRoot = 'C:\SandboxSession'
$workRoot = 'C:\hb_compile'
$resultPath = Join-Path $sessionRoot 'result.json'
$logPath = Join-Path $sessionRoot 'sandbox.log'
$exitCode = 1
$errorMessage = ''
$request = $null
$localWorkspaceReady = $false

function Invoke-CheckedRobocopy {
   param(
      [Parameter(Mandatory = $true)][string] $Source,
      [Parameter(Mandatory = $true)][string] $Destination,
      [Parameter(Mandatory = $true)][string] $Operation
   )

   if (-not (Test-Path -LiteralPath $Source)) {
      return
   }
   New-Item -ItemType Directory -Path $Destination -Force | Out-Null
   & robocopy.exe $Source $Destination /E /R:2 /W:2 | Out-Host
   if ($LASTEXITCODE -ge 8) {
      throw "$Operation falhou (robocopy=$LASTEXITCODE): $Source -> $Destination"
   }
}

try {
   Start-Transcript -LiteralPath $logPath -Force | Out-Null
   & robocopy.exe (Join-Path $sessionRoot 'source') $workRoot /E | Out-Host
   if ($LASTEXITCODE -ge 8) {
      throw "Falha ao copiar o projeto (robocopy=$LASTEXITCODE)."
   }

   $request = Get-Content -LiteralPath (Join-Path $sessionRoot 'request.json') -Raw | ConvertFrom-Json
   foreach ($directory in @('scratch', 'tools', 'logs', 'out')) {
      $target = Join-Path $workRoot $directory
      if (Test-Path -LiteralPath $target) {
         Remove-Item -LiteralPath $target -Recurse -Force
      }
      if ($request.LocalWorkspace) {
         New-Item -ItemType Directory -Path $target -Force | Out-Null
         Invoke-CheckedRobocopy `
            -Source "C:\Persistent\$directory" `
            -Destination $target `
            -Operation "Copia inicial de $directory"
      }
      else {
         New-Item -ItemType Junction -Path $target -Target "C:\Persistent\$directory" | Out-Null
      }
   }
   $localWorkspaceReady = [bool] $request.LocalWorkspace

   $invokeParameters = @{
      BuildProfile = [string] $request.BuildProfile
   }
   foreach ($name in @('Full', 'Clean', 'Minimal', 'NoContrib', 'Package', 'SkipDependencyInstall', 'StrictDependencies', 'SkipToolBootstrap', 'DryRun')) {
      if ($request.$name) { $invokeParameters[$name] = $true }
   }
   if ($request.Jobs -gt 0) { $invokeParameters.Jobs = [int] $request.Jobs }
   foreach ($name in @('HarbourRepository', 'HarbourRef')) {
      if (-not [string]::IsNullOrWhiteSpace($request.$name)) {
         $invokeParameters[$name] = [string] $request.$name
      }
   }
   foreach ($name in @('MakeArg', 'Dependency', 'IgnoreDependency')) {
      $values = @($request.$name | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) })
      if ($values.Count -gt 0) {
         $invokeParameters[$name] = [string[]] $values
      }
   }

   Set-Location $workRoot
   & (Join-Path $workRoot 'scripts\Invoke-HarbourBuild.ps1') @invokeParameters
   $exitCode = if ($?) { 0 } else { 1 }
}
catch {
   $errorMessage = $_.Exception.Message
   Write-Host "ERRO: $errorMessage" -ForegroundColor Red
   Write-Host $_.ScriptStackTrace
   $exitCode = 1
}
finally {
   if ($localWorkspaceReady) {
      try {
         foreach ($directory in @('scratch', 'tools', 'logs', 'out')) {
            Invoke-CheckedRobocopy `
               -Source (Join-Path $workRoot $directory) `
               -Destination "C:\Persistent\$directory" `
               -Operation "Sincronizacao final de $directory"
         }
      }
      catch {
         $syncError = $_.Exception.Message
         Write-Host "ERRO DE SINCRONIZACAO: $syncError" -ForegroundColor Red
         $errorMessage = if ([string]::IsNullOrWhiteSpace($errorMessage)) {
            $syncError
         }
         else {
            "$errorMessage Sincronizacao: $syncError"
         }
         $exitCode = 1
      }
   }
   try { Stop-Transcript | Out-Null } catch { }
   @{ ExitCode = $exitCode; Error = $errorMessage; FinishedAt = (Get-Date).ToString('o') } |
      ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
}

if (-not $request.KeepOpen) {
   Stop-Computer -Force
}
exit $exitCode
