[CmdletBinding()]
param(
   [ValidateSet('All', 'Zig', 'MinGW64')]
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

function Install-MinGw64 {
   param(
      [Parameter(Mandatory = $true)][string] $ToolsRoot,
      [Parameter(Mandatory = $true)][string] $RequestedVersion,
      [switch] $ForceInstall
   )

   if (-not $ForceInstall) {
      $pathGcc = Get-Command 'gcc.exe' -ErrorAction SilentlyContinue
      if ($pathGcc -and (Test-MinGwGcc -Path $pathGcc.Source)) {
         $dumpMachine = (& $pathGcc.Source -dumpmachine 2>$null | Select-Object -First 1)
         Write-Host "MinGW-w64 ja esta no PATH: $($pathGcc.Source) ($dumpMachine)"
         return
      }
   }

   $mingwRoot = Join-Path $ToolsRoot 'mingw64'
   New-Item -ItemType Directory -Force -Path $mingwRoot | Out-Null

   if (-not $ForceInstall) {
      $localGcc = Find-MinGwGcc -Root $mingwRoot
      if ($localGcc) {
         $dumpMachine = (& $localGcc.FullName -dumpmachine 2>$null | Select-Object -First 1)
         Write-Host "MinGW-w64 local ja existe: $($localGcc.FullName) ($dumpMachine)"
         return
      }
   }

   $headers = @{ 'User-Agent' = 'hb_compile-bootstrap' }
   if ($RequestedVersion -eq 'latest') {
      Write-Host 'Consultando release mais recente do xPack MinGW-w64 GCC...'
      $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/xpack-dev-tools/mingw-w64-gcc-xpack/releases/latest' -Headers $headers
   }
   else {
      $tag = if ($RequestedVersion.StartsWith('v')) { $RequestedVersion } else { "v$RequestedVersion" }
      Write-Host "Consultando release do xPack MinGW-w64 GCC: $tag"
      $release = Invoke-RestMethod -Uri "https://api.github.com/repos/xpack-dev-tools/mingw-w64-gcc-xpack/releases/tags/$tag" -Headers $headers
   }

   $versionTag = [string] $release.tag_name
   if ([string]::IsNullOrWhiteSpace($versionTag)) {
      throw 'Nao foi possivel identificar a versao do xPack MinGW-w64 GCC.'
   }

   $asset = @($release.assets) |
      Where-Object { $_.name -match 'win32-x64\.zip$' -and $_.name -notmatch '\.sha$' } |
      Sort-Object -Property name |
      Select-Object -First 1

   if (-not $asset) {
      throw "Asset win32-x64.zip nao encontrado para xPack MinGW-w64 GCC $versionTag."
   }

   $downloads = Join-Path $ToolsRoot 'downloads'
   New-Item -ItemType Directory -Force -Path $downloads | Out-Null
   $archive = Join-Path $downloads ([string] $asset.name)
   $extractRoot = Join-Path $mingwRoot $versionTag

   Remove-SafeDirectory -Path $extractRoot -Root $mingwRoot
   New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

   Write-Host "Baixando xPack MinGW-w64 GCC ${versionTag}: $($asset.browser_download_url)"
   Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive

   Write-Host "Extraindo para: $extractRoot"
   Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot -Force

   $gccExe = Find-MinGwGcc -Root $extractRoot
   if (-not $gccExe) {
      throw "gcc.exe MinGW-w64 nao foi encontrado apos extracao em: $extractRoot"
   }

   $dump = (& $gccExe.FullName -dumpmachine 2>$null | Select-Object -First 1)
   Write-Host "MinGW-w64 pronto: $($gccExe.FullName) ($dump)"
}

$ToolsRoot = Resolve-ProjectPath $Config.toolsRoot
New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null

$toolsToInstall = if ($Tool -contains 'All') { @('Zig', 'MinGW64') } else { $Tool }

foreach ($toolName in $toolsToInstall) {
   switch ($toolName) {
      'Zig' { Install-Zig -ToolsRoot $ToolsRoot -RequestedVersion $Version -ForceInstall:$Force }
      'MinGW64' { Install-MinGw64 -ToolsRoot $ToolsRoot -RequestedVersion $Version -ForceInstall:$Force }
   }
}
