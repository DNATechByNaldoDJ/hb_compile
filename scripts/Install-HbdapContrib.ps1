[CmdletBinding()]
param(
   [Parameter(Mandatory = $true)][string] $HarbourRoot,
   [Parameter(Mandatory = $true)][string] $HbdapRoot,
   [string] $HbdapRepository = 'https://github.com/DNATechByNaldoDJ/hbdap.git',
   [string] $HbdapRef,
   [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$GitCommand = @('git.exe', 'git') |
   Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
   Select-Object -First 1

function Invoke-Git {
   param([Parameter(Mandatory = $true)][string[]] $Arguments)

   if ([string]::IsNullOrWhiteSpace($GitCommand)) {
      throw 'Git nao foi encontrado no PATH.'
   }
   & $GitCommand @Arguments | Out-Host
   if ($LASTEXITCODE -ne 0) {
      throw "git falhou: git $($Arguments -join ' ')"
   }
}

function Copy-HbdapFile {
   param(
      [Parameter(Mandatory = $true)][string] $Source,
      [Parameter(Mandatory = $true)][string] $Destination
   )

   $destinationParent = Split-Path -Parent $Destination
   New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null

   for ($attempt = 1; $attempt -le 5; ++$attempt) {
      try {
         Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
         return
      }
      catch {
         if ($attempt -eq 5) {
            throw "Falha ao copiar '$Source' para '$Destination' apos $attempt tentativas. Verifique se o volume do workspace continua montado. Erro original: $($_.Exception.Message)"
         }
         Start-Sleep -Milliseconds (250 * $attempt)
      }
   }
}

$HarbourRoot = [System.IO.Path]::GetFullPath($HarbourRoot)
$HbdapRoot = [System.IO.Path]::GetFullPath($HbdapRoot)
$hbplist = Join-Path $HarbourRoot 'contrib\hbplist.txt'
$targetRoot = Join-Path $HarbourRoot 'contrib\hbdap'

if (-not (Test-Path -LiteralPath $HbdapRoot)) {
   if ([string]::IsNullOrWhiteSpace($HbdapRepository)) {
      throw "HbdapRoot nao existe: $HbdapRoot"
   }
   if ($DryRun) {
      Write-Host "DryRun: git clone $HbdapRepository `"$HbdapRoot`""
   }
   else {
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $HbdapRoot) | Out-Null
      Invoke-Git -Arguments @('clone', $HbdapRepository, $HbdapRoot)
   }
}

if (-not [string]::IsNullOrWhiteSpace($HbdapRef)) {
   if ($DryRun) {
      Write-Host "DryRun: git -C `"$HbdapRoot`" checkout $HbdapRef"
   }
   elseif (Test-Path -LiteralPath (Join-Path $HbdapRoot '.git')) {
      Invoke-Git -Arguments @('-C', $HbdapRoot, 'checkout', $HbdapRef)
   }
   else {
      throw "-HbdapRef exige um checkout Git: $HbdapRoot"
   }
}

if ($DryRun) {
   Write-Host "DryRun: instalar hbdap como contrib em `"$targetRoot`""
   return
}

if (-not (Test-Path -LiteralPath (Join-Path $HbdapRoot 'hbdap.hbp'))) {
   throw "Checkout hbdap invalido: $HbdapRoot"
}
if (-not (Test-Path -LiteralPath $hbplist)) {
   throw "Checkout Harbour invalido ou incompleto: $HarbourRoot"
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
   'hb-compile-hbdap-' + [System.Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $stagingRoot | Out-Null

try {
   foreach ($fileName in @('hbdap.hbp', 'hbdap.hbc', 'LICENSE')) {
      $sourceFile = Join-Path $HbdapRoot $fileName
      if (Test-Path -LiteralPath $sourceFile) {
         Copy-HbdapFile `
            -Source $sourceFile `
            -Destination (Join-Path $stagingRoot $fileName)
      }
   }
   foreach ($directoryName in @('include', 'src')) {
      $sourceDirectory = Join-Path $HbdapRoot $directoryName
      if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
         throw "Diretorio obrigatorio ausente no hbdap: $sourceDirectory"
      }
      foreach ($sourceFile in Get-ChildItem -LiteralPath $sourceDirectory -File -Recurse) {
         $relativePath = [System.IO.Path]::GetRelativePath($HbdapRoot, $sourceFile.FullName)
         Copy-HbdapFile `
            -Source $sourceFile.FullName `
            -Destination (Join-Path $stagingRoot $relativePath)
      }
   }

   $revision = ''
   if (Test-Path -LiteralPath (Join-Path $HbdapRoot '.git')) {
      if (-not [string]::IsNullOrWhiteSpace($GitCommand)) {
         $revision = (& $GitCommand -C $HbdapRoot rev-parse HEAD 2>$null).Trim()
      }
   }
   [ordered]@{
      repository = $HbdapRepository
      revision = $revision
      source = $HbdapRoot
   } | ConvertTo-Json | Set-Content -LiteralPath (
      Join-Path $stagingRoot 'HBDAP_BUILD_INFO.json'
   ) -Encoding utf8

   if (Test-Path -LiteralPath $targetRoot) {
      Remove-Item -LiteralPath $targetRoot -Recurse -Force
   }
   Move-Item -LiteralPath $stagingRoot -Destination $targetRoot

   $hbplistContent = Get-Content -Raw -LiteralPath $hbplist
   if ($hbplistContent -notmatch '(?m)^hbdap/hbdap\.hbp\s*$') {
      Add-Content -LiteralPath $hbplist -Value 'hbdap/hbdap.hbp'
   }
}
finally {
   if (Test-Path -LiteralPath $stagingRoot) {
      Remove-Item -LiteralPath $stagingRoot -Recurse -Force
   }
}

Write-Host "hbdap opcional preparado em: $targetRoot"
