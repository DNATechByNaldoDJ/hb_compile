[CmdletBinding()]
param(
   [Parameter(Mandatory = $true)][string] $OpenAdsRoot,
   [Parameter(Mandatory = $true)][string] $CompatibilityRoot,
   [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$OpenAdsRoot = [System.IO.Path]::GetFullPath($OpenAdsRoot)
$CompatibilityRoot = [System.IO.Path]::GetFullPath($CompatibilityRoot)
$sourceInclude = Join-Path $OpenAdsRoot 'include\openads'
$sourceHeader = Join-Path $sourceInclude 'ace.h'
$compatInclude = Join-Path $CompatibilityRoot 'include\openads'
$compatHeader = Join-Path $compatInclude 'ace.h'

function Update-SourceText {
   param(
      [Parameter(Mandatory = $true)][string] $Path,
      [Parameter(Mandatory = $true)][hashtable] $Replacements
   )

   $content = Get-Content -Raw -LiteralPath $Path
   $updated = $content
   foreach ($entry in $Replacements.GetEnumerator()) {
      $updated = $updated -replace $entry.Key, $entry.Value
   }
   if ($updated -ne $content) {
      Set-Content -LiteralPath $Path -Value $updated -Encoding utf8NoBOM
      Write-Host "Patch OpenADS aplicado: $Path"
   }
}

if (-not (Test-Path -LiteralPath $sourceHeader -PathType Leaf)) {
   throw "Header OpenADS nao encontrado: $sourceHeader"
}

if ($DryRun) {
   Write-Host "DryRun: normalizar header-fonte OpenADS e gerar headers Harbour em `"$compatInclude`""
   return
}

# The Harbour compatibility header accepts void buffers for the historical
# WCHAR/UNSIGNED16 mismatch. OpenADS itself must retain its concrete
# UNSIGNED16 signatures so declarations match ace_exports.cpp.
$sourceContent = Get-Content -Raw -LiteralPath $sourceHeader
$normalizedSource = $sourceContent `
   -replace 'void\*\s+pucValueW', 'UNSIGNED16* pucValueW' `
   -replace 'void\*\s+pucBufW', 'UNSIGNED16* pucBufW'
if ($normalizedSource -ne $sourceContent) {
   Set-Content -LiteralPath $sourceHeader -Value $normalizedSource -Encoding ascii
   Write-Host "Header-fonte OpenADS normalizado: $sourceHeader"
}

# Keep the local Linux build warning-clean on current GCC releases. These
# changes are idempotent and preserve the represented values.
Update-SourceText -Path (Join-Path $OpenAdsRoot 'src\abi\ace_exports.cpp') -Replacements @{
   'char buf\[16\]; std::snprintf\(buf,sizeof\(buf\),"%zu",ev\[0\]\.size\(\)\);' =
      'char buf[32]; std::snprintf(buf,sizeof(buf),"%zu",ev[0].size());'
   'char buf\[16\];\s*\r?\n\s*std::snprintf\(buf, sizeof\(buf\), "%zu",' =
      "char buf[32];`n                            std::snprintf(buf, sizeof(buf), `"%zu`","
   'b\[0\]=v&0xFF; b\[1\]=\(v>>8\)&0xFF; b\[2\]=\(v>>16\)&0xFF; b\[3\]=\(v>>24\)&0xFF;' =
      'b[0]=static_cast<unsigned char>(v&0xFF); b[1]=static_cast<unsigned char>((v>>8)&0xFF); b[2]=static_cast<unsigned char>((v>>16)&0xFF); b[3]=static_cast<unsigned char>((v>>24)&0xFF);'
   '(?m)^\s{12}const uint32_t SAP_SENTINEL = 0x80000000u;\r?\n' = ''
}
Update-SourceText -Path (Join-Path $OpenAdsRoot 'src\drivers\dbf_common.cpp') -Replacements @{
   'char tmp\[12\];' = 'char tmp[32];'
   'char tmp\[20\];' = 'char tmp[32];'
}
Update-SourceText -Path (Join-Path $OpenAdsRoot 'src\sql\parser.cpp') -Replacements @{
   'char datebuf\[24\](\s*=\s*\{\})?;' = 'char datebuf[64]$1;'
}

if (Test-Path -LiteralPath $CompatibilityRoot) {
   Remove-Item -LiteralPath $CompatibilityRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $compatInclude | Out-Null
Copy-Item -Path (Join-Path $sourceInclude '*') -Destination $compatInclude -Recurse -Force

$compatContent = Get-Content -Raw -LiteralPath $compatHeader
$legacyTypeBlock = @'

#ifndef OPENADS_HARBOUR_LEGACY_TYPES
#  define OPENADS_HARBOUR_LEGACY_TYPES
typedef double DOUBLE;
typedef uint16_t WCHAR;
typedef void VOID;
#endif
'@
$legacyTypeBlock += [Environment]::NewLine
if ($compatContent -notmatch 'OPENADS_HARBOUR_LEGACY_TYPES') {
   $compatContent = $compatContent -replace (
      '(typedef\s+uint16_t\s+UNSIGNED16;\s*)'
   ), ('$1' + $legacyTypeBlock)
}
if ($compatContent -notmatch '#\s*define\s+ADSFIELD') {
$adsFieldBlock = @'

#ifndef ADSFIELD
#  define ADSFIELD( n ) ( ( UNSIGNED8 * ) ( uintptr_t ) ( n ) )
#endif
'@
   $adsFieldBlock += [Environment]::NewLine
   $compatContent = $compatContent -replace (
      '(typedef\s+uint64_t\s+ADSHANDLE;\s*)'
   ), ('$1' + $adsFieldBlock)
}
$compatContent = $compatContent `
   -replace 'UNSIGNED16\*\s+pucValueW', 'void* pucValueW' `
   -replace 'UNSIGNED16\*\s+pucBufW', 'void* pucBufW'

$requiredDeclarations = @(
   'typedef\s+uint32_t\s+UNSIGNED32\s*;',
   'typedef\s+double\s+DOUBLE\s*;',
   'typedef\s+uint16_t\s+WCHAR\s*;',
   'typedef\s+void\s+VOID\s*;',
   '#\s*define\s+ADSFIELD'
)
foreach ($requiredDeclaration in $requiredDeclarations) {
   if ($compatContent -notmatch $requiredDeclaration) {
      throw "Header OpenADS compativel invalido; declaracao ausente: $requiredDeclaration"
   }
}
if ($compatContent -match '#endif(?:typedef|#)') {
   throw 'Header OpenADS compativel invalido; diretivas concatenadas detectadas.'
}

Set-Content -LiteralPath $compatHeader -Value $compatContent -Encoding ascii

Write-Host "Headers OpenADS para Harbour preparados em: $compatInclude"
