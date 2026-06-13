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
$docker = Get-Command 'docker.exe' -ErrorAction SilentlyContinue
if (-not $docker) {
   $docker = Get-Command 'docker' -ErrorAction SilentlyContinue
}
$dockerStatus = if ($docker) { $docker.Source } else { 'NAO ENCONTRADO' }

Write-Host "win-make    : $makeStatus"
Write-Host "zig         : $zigStatus"
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
   $profile = $Config.profiles.$profileName
   $subdir = if ($profile.installSubdir) { $profile.installSubdir } else { $profileName }
   $installRoot = Join-Path $outputRoot $subdir
   $hbmk2Win = Join-Path (Join-Path $installRoot 'bin') 'hbmk2.exe'
   $hbmk2Unix = Join-Path (Join-Path $installRoot 'bin') 'hbmk2'
   $installed = (Test-Path -LiteralPath $hbmk2Win) -or (Test-Path -LiteralPath $hbmk2Unix)

   [pscustomobject]@{
      Profile = $profileName
      Installed = if ($installed) { 'yes' } else { 'no' }
      Output = Format-ProjectPath $installRoot
      Description = $profile.description
   }
}

$rows | Format-Table -AutoSize
