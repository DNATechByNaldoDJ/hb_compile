[CmdletBinding()]
param(
   [ValidateSet('All', 'Zig')]
   [string[]] $Tool = @('Zig'),
   [string] $Version = 'latest',
   [switch] $Force
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

function Remove-SafeDirectory {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][string] $Root
   )

   $fullPath = [System.IO.Path]::GetFullPath($Path)
   $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
   if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Recusando remover fora de '$fullRoot': $fullPath"
   }

   if (Test-Path -LiteralPath $fullPath) {
      Remove-Item -LiteralPath $fullPath -Recurse -Force
   }
}

function Get-ZigPlatformKey {
   $arch = $env:PROCESSOR_ARCHITECTURE
   if ($arch -eq 'ARM64') {
      return 'aarch64-windows'
   }

   return 'x86_64-windows'
}

function Install-Zig {
   param(
      [Parameter(Mandatory = $true)][string] $ToolsRoot,
      [Parameter(Mandatory = $true)][string] $RequestedVersion,
      [switch] $ForceInstall
   )

   if (-not $ForceInstall) {
      $pathZig = Get-Command 'zig.exe' -ErrorAction SilentlyContinue
      if ($pathZig) {
         $detectedVersion = (& $pathZig.Source version).Trim()
         Write-Host "Zig ja esta no PATH: $($pathZig.Source) ($detectedVersion)"
         return
      }
   }

   $zigRoot = Join-Path $ToolsRoot 'zig'
   New-Item -ItemType Directory -Force -Path $zigRoot | Out-Null

   if (-not $ForceInstall) {
      $localZig = Get-ChildItem -LiteralPath $zigRoot -Filter 'zig.exe' -Recurse -ErrorAction SilentlyContinue |
         Sort-Object -Property FullName |
         Select-Object -First 1
      if ($localZig) {
         $detectedVersion = (& $localZig.FullName version).Trim()
         Write-Host "Zig local ja existe: $($localZig.FullName) ($detectedVersion)"
         return
      }
   }

   Write-Host 'Consultando indice oficial do Zig...'
   $index = Invoke-RestMethod -Uri 'https://ziglang.org/download/index.json'
   $platformKey = Get-ZigPlatformKey

   if ($RequestedVersion -eq 'latest') {
      $stableVersions = @($index.PSObject.Properties.Name) |
         Where-Object { $_ -match '^\d+\.\d+\.\d+$' } |
         Sort-Object { [version] $_ } -Descending
      $RequestedVersion = $stableVersions | Select-Object -First 1
   }

   if ([string]::IsNullOrWhiteSpace($RequestedVersion)) {
      throw 'Nao foi possivel identificar uma versao estavel do Zig.'
   }

   $versionNode = $index.$RequestedVersion
   if (-not $versionNode) {
      throw "Versao do Zig nao encontrada no indice: $RequestedVersion"
   }

   $asset = $versionNode.$platformKey
   if (-not $asset) {
      throw "Asset do Zig nao encontrado para plataforma '$platformKey' na versao $RequestedVersion."
   }

   $url = $asset.tarball
   if ([string]::IsNullOrWhiteSpace($url)) {
      throw "URL de download vazia para Zig $RequestedVersion/$platformKey."
   }

   $downloads = Join-Path $ToolsRoot 'downloads'
   New-Item -ItemType Directory -Force -Path $downloads | Out-Null
   $archive = Join-Path $downloads (Split-Path $url -Leaf)
   $extractRoot = Join-Path $zigRoot $RequestedVersion

   Remove-SafeDirectory -Path $extractRoot -Root $zigRoot
   New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

   Write-Host "Baixando Zig ${RequestedVersion}: $url"
   Invoke-WebRequest -Uri $url -OutFile $archive

   if ($archive -notmatch '\.zip$') {
      throw "Formato de arquivo nao suportado por este bootstrap: $archive"
   }

   Write-Host "Extraindo para: $extractRoot"
   Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot -Force

   $zigExe = Get-ChildItem -LiteralPath $extractRoot -Filter 'zig.exe' -Recurse |
      Sort-Object -Property FullName |
      Select-Object -First 1

   if (-not $zigExe) {
      throw "zig.exe nao foi encontrado apos extracao em: $extractRoot"
   }

   $installedVersion = (& $zigExe.FullName version).Trim()
   Write-Host "Zig pronto: $($zigExe.FullName) ($installedVersion)"
}

$ToolsRoot = Resolve-ProjectPath $Config.toolsRoot
New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null

$toolsToInstall = if ($Tool -contains 'All') { @('Zig') } else { $Tool }

foreach ($toolName in $toolsToInstall) {
   switch ($toolName) {
      'Zig' { Install-Zig -ToolsRoot $ToolsRoot -RequestedVersion $Version -ForceInstall:$Force }
   }
}
