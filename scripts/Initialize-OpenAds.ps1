[CmdletBinding()]
param(
   [Parameter(Mandatory = $true)][string] $OpenAdsRoot,
   [string] $OpenAdsRepository = 'https://github.com/FiveTechSoft/OpenADS.git',
   [string] $OpenAdsRef,
   [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$gitCommand = @('git.exe', 'git') |
   Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
   Select-Object -First 1
$OpenAdsRoot = [System.IO.Path]::GetFullPath($OpenAdsRoot)

function Invoke-Git {
   param([string[]] $Arguments)
   if ([string]::IsNullOrWhiteSpace($gitCommand)) {
      throw 'Git nao foi encontrado no PATH.'
   }
   & $gitCommand @Arguments | Out-Host
   if ($LASTEXITCODE -ne 0) {
      throw "git falhou: git $($Arguments -join ' ')"
   }
}

if (-not (Test-Path -LiteralPath $OpenAdsRoot)) {
   if ($DryRun) {
      Write-Host "DryRun: git clone $OpenAdsRepository `"$OpenAdsRoot`""
   }
   else {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OpenAdsRoot) | Out-Null
      Invoke-Git -Arguments @('clone', $OpenAdsRepository, $OpenAdsRoot)
   }
}

if (-not [string]::IsNullOrWhiteSpace($OpenAdsRef)) {
   if ($DryRun) {
      Write-Host "DryRun: git -C `"$OpenAdsRoot`" checkout $OpenAdsRef"
   }
   else {
      Invoke-Git -Arguments @('-C', $OpenAdsRoot, 'checkout', $OpenAdsRef)
   }
}

if (-not $DryRun -and -not (Test-Path -LiteralPath (Join-Path $OpenAdsRoot 'CMakeLists.txt'))) {
   throw "Checkout OpenADS invalido: $OpenAdsRoot"
}

Write-Host "OpenADS opcional preparado em: $OpenAdsRoot"
