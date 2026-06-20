[CmdletBinding()]
param(
   [ValidateSet('All', 'Zig', 'MinGW64', 'Cygwin', 'MSYS')]
   [string[]] $Tool = @('Zig'),
   [string] $Version = 'latest',
   [string] $CygwinSetup = '',
   [string] $CygwinMirror = 'https://mirrors.kernel.org/sourceware/cygwin/',
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

function Format-CommandArgument {
   param([string] $Value)
   if ($Value -match '[\s"]') {
      return '"' + ($Value -replace '"', '\"') + '"'
   }
   return $Value
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
      [Parameter(Mandatory = $true)][ValidateSet('Cygwin', 'MSYS')][string] $Environment
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
   if ($probe.ExitCode -ne 0) {
      return $false
   }

   if ($Environment -eq 'Cygwin') {
      return $probe.StdOut -match 'CYGWIN'
   }

   return $probe.StdOut -match 'MSYS|MINGW'
}

function Find-BashEnvironment {
   param(
      [Parameter(Mandatory = $true)][string] $Root,
      [Parameter(Mandatory = $true)][ValidateSet('Cygwin', 'MSYS')][string] $Environment
   )

   try {
      if (-not (Test-Path -LiteralPath $Root -ErrorAction Stop)) {
         return $null
      }
   }
   catch {
      return $null
   }

   $candidates = @(
      (Join-Path $Root 'bin\bash.exe'),
      (Join-Path $Root 'usr\bin\bash.exe'),
      (Join-Path $Root 'msys64\usr\bin\bash.exe')
   )
   foreach ($candidate in $candidates) {
      if (Test-BashEnvironment -Path $candidate -Environment $Environment) {
         return (Get-Item -LiteralPath $candidate)
      }
   }

   return Get-ChildItem -LiteralPath $Root -Filter 'bash.exe' -Recurse -ErrorAction SilentlyContinue |
      Where-Object { Test-BashEnvironment -Path $_.FullName -Environment $Environment } |
      Sort-Object -Property FullName |
      Select-Object -First 1
}

function Test-BashBuildTools {
   param([Parameter(Mandatory = $true)][string] $BashPath)

   $probe = Invoke-BashProbe -Path $BashPath -Script 'command -v make >/dev/null && command -v gcc >/dev/null && command -v git >/dev/null'
   return $probe.ExitCode -eq 0
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

function Install-Cygwin {
   param(
      [Parameter(Mandatory = $true)][string] $ToolsRoot,
      [string] $SetupPath = '',
      [Parameter(Mandatory = $true)][string] $Mirror,
      [switch] $ForceInstall
   )

   $cygwinRoot = Join-Path $ToolsRoot 'cygwin'
   $localBash = Find-BashEnvironment -Root $cygwinRoot -Environment Cygwin
   if ($localBash -and -not $ForceInstall -and (Test-BashBuildTools -BashPath $localBash.FullName)) {
      Write-Host "Cygwin local ja existe: $($localBash.FullName)"
      return
   }

   $downloads = Join-Path $ToolsRoot 'downloads'
   New-Item -ItemType Directory -Force -Path $downloads | Out-Null
   if ([string]::IsNullOrWhiteSpace($SetupPath)) {
      $setupExe = Join-Path $downloads 'setup-x86_64.exe'
      if ($ForceInstall -or -not (Test-Path -LiteralPath $setupExe)) {
         Write-Host 'Baixando instalador oficial do Cygwin...'
         Invoke-WebRequest -Uri 'https://cygwin.com/setup-x86_64.exe' -OutFile $setupExe
      }
   }
   else {
      $setupExe = Resolve-ProjectPath $SetupPath
   }

   if (-not (Test-Path -LiteralPath $setupExe)) {
      throw "setup-x86_64.exe nao encontrado: $setupExe"
   }

   New-Item -ItemType Directory -Force -Path $cygwinRoot | Out-Null
   $packages = 'gcc-core,make,binutils,git,pkg-config'
   $setupArgs = @(
      '--quiet-mode',
      '--wait',
      '--no-admin',
      '--no-desktop',
      '--no-startmenu',
      '--no-shortcuts',
      '--root', $cygwinRoot,
      '--site', $Mirror,
      '--local-package-dir', $downloads,
      '--packages', $packages
   )

   Write-Host "Preparando Cygwin local em: $cygwinRoot"
   $setupProcess = Start-Process `
      -FilePath $setupExe `
      -ArgumentList $setupArgs `
      -Wait `
      -PassThru
   if ($setupProcess.ExitCode -ne 0) {
      throw "Instalacao do Cygwin falhou com codigo $($setupProcess.ExitCode)."
   }

   $localBash = Find-BashEnvironment -Root $cygwinRoot -Environment Cygwin
   if (-not $localBash -or -not (Test-BashBuildTools -BashPath $localBash.FullName)) {
      throw "Cygwin foi instalado, mas bash/make/gcc/git nao foram validados em: $cygwinRoot"
   }

   Write-Host "Cygwin pronto: $($localBash.FullName)"
}

function Install-Msys {
   param(
      [Parameter(Mandatory = $true)][string] $ToolsRoot,
      [Parameter(Mandatory = $true)][string] $RequestedVersion,
      [switch] $ForceInstall
   )

   $msysRoot = Join-Path $ToolsRoot 'msys'
   $localBash = Find-BashEnvironment -Root $msysRoot -Environment MSYS
   if ($localBash -and -not $ForceInstall -and (Test-BashBuildTools -BashPath $localBash.FullName)) {
      Write-Host "MSYS2 local ja existe: $($localBash.FullName)"
      return
   }

   if ($ForceInstall) {
      Remove-SafeDirectory -Path $msysRoot -Root $ToolsRoot
   }

   if (-not $localBash) {
      $headers = @{ 'User-Agent' = 'hb_compile-bootstrap' }
      if ($RequestedVersion -eq 'latest') {
         Write-Host 'Consultando release mais recente do instalador MSYS2...'
         $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/msys2/msys2-installer/releases/latest' -Headers $headers
      }
      else {
         Write-Host "Consultando release do instalador MSYS2: $RequestedVersion"
         $release = Invoke-RestMethod -Uri "https://api.github.com/repos/msys2/msys2-installer/releases/tags/$RequestedVersion" -Headers $headers
      }

      $asset = @($release.assets) |
         Where-Object { $_.name -match '^msys2-base-x86_64-.*\.sfx\.exe$' } |
         Sort-Object -Property name -Descending |
         Select-Object -First 1
      if (-not $asset) {
         throw "Pacote base x86_64 do MSYS2 nao foi encontrado na release '$($release.tag_name)'."
      }

      $downloads = Join-Path $ToolsRoot 'downloads'
      New-Item -ItemType Directory -Force -Path $downloads | Out-Null
      $archive = Join-Path $downloads ([string] $asset.name)
      Write-Host "Baixando MSYS2 $($release.tag_name): $($asset.browser_download_url)"
      Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive

      New-Item -ItemType Directory -Force -Path $msysRoot | Out-Null
      Write-Host "Extraindo MSYS2 para: $msysRoot"
      & $archive '-y' "-o$msysRoot"
      if ($LASTEXITCODE -ne 0) {
         throw "Extracao do MSYS2 falhou com codigo $LASTEXITCODE."
      }

      $localBash = Find-BashEnvironment -Root $msysRoot -Environment MSYS
      if (-not $localBash) {
         throw "bash.exe do MSYS2 nao foi encontrado apos extracao em: $msysRoot"
      }
   }

   Write-Host 'Instalando ferramentas base no MSYS2 local...'
   & $localBash.FullName -lc 'pacman -Sy --needed --noconfirm base-devel make binutils gcc git pkgconf'
   if ($LASTEXITCODE -ne 0) {
      throw "Instalacao de pacotes MSYS2 falhou com codigo $LASTEXITCODE."
   }

   if (-not (Test-BashBuildTools -BashPath $localBash.FullName)) {
      throw "MSYS2 foi instalado, mas make/gcc/git nao foram validados em: $msysRoot"
   }

   Write-Host "MSYS2 pronto: $($localBash.FullName)"
}

$ToolsRoot = Resolve-ProjectPath $Config.toolsRoot
New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null

$toolsToInstall = if ($Tool -contains 'All') { @('Zig', 'MinGW64', 'Cygwin', 'MSYS') } else { $Tool }

foreach ($toolName in $toolsToInstall) {
   switch ($toolName) {
      'Zig' { Install-Zig -ToolsRoot $ToolsRoot -RequestedVersion $Version -ForceInstall:$Force }
      'MinGW64' { Install-MinGw64 -ToolsRoot $ToolsRoot -RequestedVersion $Version -ForceInstall:$Force }
      'Cygwin' { Install-Cygwin -ToolsRoot $ToolsRoot -SetupPath $CygwinSetup -Mirror $CygwinMirror -ForceInstall:$Force }
      'MSYS' { Install-Msys -ToolsRoot $ToolsRoot -RequestedVersion $Version -ForceInstall:$Force }
   }
}
