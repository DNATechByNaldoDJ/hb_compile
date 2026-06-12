[CmdletBinding()]
param(
   [string] $Profile = 'zig',
   [string] $InstallRoot
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

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
   $profileConfig = $Config.profiles.$Profile
   if (-not $profileConfig) {
      throw "Perfil '$Profile' nao existe."
   }

   $outputRoot = Resolve-ProjectPath $Config.outputRoot
   $subdir = if ($profileConfig.installSubdir) { $profileConfig.installSubdir } else { $Profile }
   $InstallRoot = Join-Path $outputRoot $subdir
}
else {
   $InstallRoot = Resolve-ProjectPath $InstallRoot
}

Add-LocalToolPaths -ToolsRoot (Resolve-ProjectPath $Config.toolsRoot)

$binDir = Join-Path $InstallRoot 'bin'
$hbmk2 = Join-Path $binDir 'hbmk2.exe'
if (-not (Test-Path -LiteralPath $hbmk2)) {
   $hbmk2 = Join-Path $binDir 'hbmk2'
}
if (-not (Test-Path -LiteralPath $hbmk2)) {
   throw "hbmk2 nao encontrado em: $binDir"
}

$sample = Join-Path $ProjectRoot 'samples\hello.prg'
$scratch = Join-Path (Join-Path $ProjectRoot 'scratch') $Profile
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
   Write-Host "Executando: $outExe"
   & $outExe
}
else {
   Write-Host 'Sample compilado, mas nao foi gerado hello.exe; possivel alvo nao-Windows.'
}
