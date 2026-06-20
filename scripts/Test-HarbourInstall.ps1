[CmdletBinding()]
param(
   [Alias('Profile')]
   [string] $BuildProfile = 'zig',
   [string] $InstallRoot,
   [switch] $CompileOnly
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

function Get-MinGwPrefix {
   param([Parameter(Mandatory = $true)][string] $Path)

   $leafName = [System.IO.Path]::GetFileName($Path)
   if ($leafName -match '^(?<prefix>.+-)gcc(?:-\d[\d.]*)?\.exe$') {
      return [string] $Matches.prefix
   }

   return ''
}

function Set-MinGwBuildEnvironment {
   param([Parameter(Mandatory = $true)][string] $ToolsRoot)

   $gcc = $null
   $mingwRoot = Join-Path $ToolsRoot 'mingw64'
   if (Test-Path -LiteralPath $mingwRoot) {
      $gcc = Find-MinGwGcc -Root $mingwRoot
   }

   if (-not $gcc) {
      foreach ($commandName in @('x86_64-w64-mingw32-gcc.exe', 'gcc.exe', 'x86_64-w64-mingw32-gcc', 'gcc')) {
         $command = Get-Command $commandName -ErrorAction SilentlyContinue
         if ($command -and (Test-MinGwGcc -Path $command.Source)) {
            $gcc = Get-Item -LiteralPath $command.Source
            break
         }
      }
   }

   if (-not $gcc) {
      return
   }

   Add-PathPrefix -Directory $gcc.Directory.FullName
   $compilerPath = $gcc.Directory.FullName
   if (-not $compilerPath.EndsWith('\')) {
      $compilerPath = "$compilerPath\"
   }

   $env:HB_CCPATH = $compilerPath
   $prefix = Get-MinGwPrefix -Path $gcc.FullName
   if (-not [string]::IsNullOrWhiteSpace($prefix)) {
      $env:HB_CCPREFIX = $prefix
   }

   Write-Host "Usando MinGW-w64 para o teste: $($gcc.FullName)"
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

$profileConfig = $Config.profiles.$BuildProfile
if (-not $profileConfig) {
   throw "Perfil '$BuildProfile' nao existe."
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
   $outputRoot = Resolve-ProjectPath $Config.outputRoot
   $subdir = if ($profileConfig.installSubdir) { $profileConfig.installSubdir } else { $BuildProfile }
   $InstallRoot = Join-Path $outputRoot $subdir
}
else {
   $InstallRoot = Resolve-ProjectPath $InstallRoot
}

$toolsRoot = Resolve-ProjectPath $Config.toolsRoot
Add-LocalToolPaths -ToolsRoot $toolsRoot

foreach ($item in @($profileConfig.env.PSObject.Properties)) {
   [System.Environment]::SetEnvironmentVariable($item.Name, [string] $item.Value, 'Process')
}

if ($BuildProfile -like 'mingw*') {
   Set-MinGwBuildEnvironment -ToolsRoot $toolsRoot
}

$binDir = Join-Path $InstallRoot 'bin'
$hbmk2 = Join-Path $binDir 'hbmk2.exe'
if (-not (Test-Path -LiteralPath $hbmk2)) {
   $hbmk2 = Join-Path $binDir 'hbmk2'
}
if (-not (Test-Path -LiteralPath $hbmk2)) {
   throw "hbmk2 nao encontrado em: $binDir"
}

$sample = Join-Path $ProjectRoot 'samples\hello.prg'
$scratch = Join-Path (Join-Path $ProjectRoot 'scratch') $BuildProfile
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

$outBase = Join-Path $scratch 'hello'
$outExe = "$outBase.exe"
if (Test-Path -LiteralPath $outExe) {
   Remove-Item -LiteralPath $outExe -Force
}

$env:PATH = "$binDir;$env:PATH"

Write-Host "Compilando sample com: $hbmk2"
& $hbmk2 $sample "-o$outBase"
if ($LASTEXITCODE -ne 0) {
   throw "hbmk2 falhou com codigo $LASTEXITCODE."
}

if (Test-Path -LiteralPath $outExe) {
   if ($CompileOnly) {
      Write-Host "Sample compilado: $outExe"
   }
   else {
      Write-Host "Executando: $outExe"
      & $outExe
   }
}
else {
   Write-Host 'Sample compilado, mas nao foi gerado hello.exe; possivel alvo nao-Windows.'
}
