[CmdletBinding()]
param(
   [string] $HarbourRoot,
   [string] $HarbourRepository
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $ProjectRoot 'config\profiles.json'
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

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

function Add-PathPrefix {
   param([Parameter(Mandatory = $true)][string] $Directory)

   $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
   $parts = @($env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
   $alreadyPresent = @($parts | Where-Object { $_.TrimEnd('\') -ieq $fullDirectory.TrimEnd('\') }).Count -gt 0
   if (-not $alreadyPresent) {
      $env:PATH = "$fullDirectory;$env:PATH"
   }
}

function Test-MinGwGcc {
   param([Parameter(Mandatory = $true)][string] $Path)

   if (-not (Test-Path -LiteralPath $Path)) {
      return $false
   }

   try {
      $dumpMachine = (& $Path -dumpmachine 2>$null | Select-Object -First 1)
      return (-not [string]::IsNullOrWhiteSpace($dumpMachine) -and
         $dumpMachine -match '^x86_64-.*(mingw|w64)' -and
         $dumpMachine -notmatch 'cygwin')
   }
   catch {
      return $false
   }
}

function Find-MinGwGcc {
   param([Parameter(Mandatory = $true)][string] $Root)

   if (-not (Test-Path -LiteralPath $Root)) {
      return $null
   }

   $directCandidates = @(
      (Join-Path $Root 'gcc.exe'),
      (Join-Path $Root 'bin\gcc.exe'),
      (Join-Path $Root 'mingw64\bin\gcc.exe'),
      (Join-Path $Root 'x86_64-w64-mingw32-gcc.exe'),
      (Join-Path $Root 'bin\x86_64-w64-mingw32-gcc.exe'),
      (Join-Path $Root 'mingw64\bin\x86_64-w64-mingw32-gcc.exe')
   )

   foreach ($candidate in $directCandidates) {
      if (Test-MinGwGcc -Path $candidate) {
         return (Get-Item -LiteralPath $candidate)
      }
   }

   return Get-ChildItem -LiteralPath $Root -Filter '*gcc.exe' -Recurse -ErrorAction SilentlyContinue |
      Where-Object { Test-MinGwGcc -Path $_.FullName } |
      Sort-Object -Property FullName |
      Select-Object -First 1
}

function Add-LocalToolPaths {
   param([Parameter(Mandatory = $true)][string] $ToolsRoot)

   $mingwRoot = Join-Path $ToolsRoot 'mingw64'
   if (Test-Path -LiteralPath $mingwRoot) {
      $gcc = Find-MinGwGcc -Root $mingwRoot
      if ($gcc) {
         Add-PathPrefix -Directory $gcc.Directory.FullName
      }
   }

   $zigRoot = Join-Path $ToolsRoot 'zig'
   if (Test-Path -LiteralPath $zigRoot) {
      $zig = Get-ChildItem -LiteralPath $zigRoot -Filter 'zig.exe' -Recurse -ErrorAction SilentlyContinue |
         Sort-Object -Property FullName |
         Select-Object -First 1
      if ($zig) {
         Add-PathPrefix -Directory $zig.Directory.FullName
      }
   }
}

if ([string]::IsNullOrWhiteSpace($HarbourRoot)) {
   $HarbourRoot = Get-ConfigString -Config $Config -Name 'harbourRoot' -Default 'scratch\harbour-core'
}
if ([string]::IsNullOrWhiteSpace($HarbourRepository)) {
   $HarbourRepository = Get-ConfigString -Config $Config -Name 'harbourRepository' -Default 'https://github.com/harbour/core.git'
}

$harbourRoot = Resolve-ProjectPath $HarbourRoot
$outputRoot = Resolve-ProjectPath $Config.outputRoot
$toolsRoot = Resolve-ProjectPath $Config.toolsRoot
Add-LocalToolPaths -ToolsRoot $toolsRoot

Write-Host "Projeto     : $(Format-ProjectPath $ProjectRoot)"
Write-Host "HarbourRepo : $HarbourRepository"
Write-Host "HarbourRoot : $(Format-ProjectPath $harbourRoot)"
Write-Host "OutputRoot  : $(Format-ProjectPath $outputRoot)"
Write-Host ''

$makeExe = Join-Path $harbourRoot 'win-make.exe'
$makeStatus = if (Test-Path -LiteralPath $makeExe) { Format-ProjectPath $makeExe } else { 'NAO ENCONTRADO' }
$zig = Get-Command 'zig.exe' -ErrorAction SilentlyContinue
$zigStatus = if ($zig) { "$($zig.Source) ($((& $zig.Source version).Trim()))" } else { 'NAO ENCONTRADO' }
$gcc = Get-Command 'x86_64-w64-mingw32-gcc.exe' -ErrorAction SilentlyContinue
if (-not $gcc) {
   $gcc = Get-Command 'gcc.exe' -ErrorAction SilentlyContinue
}
if (-not $gcc) {
   $gcc = Get-Command 'x86_64-w64-mingw32-gcc' -ErrorAction SilentlyContinue
}
if (-not $gcc) {
   $gcc = Get-Command 'gcc' -ErrorAction SilentlyContinue
}
$mingwStatus = 'NAO ENCONTRADO'
if ($gcc) {
   $dumpMachine = ''
   try {
      $dumpMachine = (& $gcc.Source -dumpmachine 2>$null | Select-Object -First 1)
   }
   catch {
      $dumpMachine = ''
   }

   $mingwStatus = if ($dumpMachine -match '^x86_64-.*(mingw|w64)' -and $dumpMachine -notmatch 'cygwin') {
      "$($gcc.Source) ($dumpMachine)"
   }
   else {
      "$($gcc.Source) (target=$dumpMachine; nao MinGW-w64)"
   }
}
$docker = Get-Command 'docker.exe' -ErrorAction SilentlyContinue
if (-not $docker) {
   $docker = Get-Command 'docker' -ErrorAction SilentlyContinue
}
$dockerStatus = if ($docker) { $docker.Source } else { 'NAO ENCONTRADO' }

Write-Host "win-make    : $makeStatus"
Write-Host "zig         : $zigStatus"
Write-Host "mingw64     : $mingwStatus"
Write-Host "docker      : $dockerStatus"
if (-not (Test-Path -LiteralPath $harbourRoot)) {
   Write-Host "Fonte       : ausente; sera clonado no primeiro build"
}

if (Get-Command 'git.exe' -ErrorAction SilentlyContinue) {
   try {
      $rev = & git -C $harbourRoot rev-parse --short HEAD 2>$null
      if ($LASTEXITCODE -eq 0 -and $rev) {
         Write-Host "Harbour Git : $rev"
      }
   }
   catch {
      Write-Host 'Harbour Git : indisponivel'
   }
}

Write-Host ''
Write-Host 'Perfis:'

$rows = foreach ($profileName in @($Config.profiles.PSObject.Properties.Name)) {
   $profileConfig = $Config.profiles.$profileName
   $subdir = if ($profileConfig.installSubdir) { $profileConfig.installSubdir } else { $profileName }
   $installRoot = Join-Path $outputRoot $subdir
   $hbmk2Win = Join-Path (Join-Path $installRoot 'bin') 'hbmk2.exe'
   $hbmk2Unix = Join-Path (Join-Path $installRoot 'bin') 'hbmk2'
   $installed = (Test-Path -LiteralPath $hbmk2Win) -or (Test-Path -LiteralPath $hbmk2Unix)

   [pscustomobject]@{
      Profile = $profileName
      Installed = if ($installed) { 'yes' } else { 'no' }
      Output = Format-ProjectPath $installRoot
      Description = $profileConfig.description
   }
}

$rows | Format-Table -AutoSize
