[CmdletBinding()]
param(
   [Parameter(Mandatory)]
   [string] $HarbourRoot,

   [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Update-TextFile {
   param(
      [Parameter(Mandatory)] [string] $Path,
      [Parameter(Mandatory)] [string] $Description,
      [Parameter(Mandatory)] [string] $OldText,
      [Parameter(Mandatory)] [string] $NewText
   )

   if (-not (Test-Path -LiteralPath $Path)) {
      if ($DryRun) {
         Write-Host "DryRun: aplicar $Description quando o checkout existir em `"$Path`""
         return
      }
      throw "Arquivo do Harbour nao encontrado para $Description`: $Path"
   }

   $content = Get-Content -LiteralPath $Path -Raw
   $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
   $expectedText = $OldText -replace "`r?`n", $newline
   $replacementText = $NewText -replace "`r?`n", $newline
   if ($content.Contains($replacementText)) {
      return
   }
   if (-not $content.Contains($expectedText)) {
      throw "Nao foi possivel aplicar $Description; o trecho esperado mudou em: $Path"
   }

   if ($DryRun) {
      Write-Host "DryRun: aplicar $Description em `"$Path`""
      return
   }

   $updated = $content.Replace($expectedText, $replacementText)
   [System.IO.File]::WriteAllText($Path, $updated, [System.Text.UTF8Encoding]::new($false))
   Write-Host "Compatibilidade Harbour aplicada: $Description"
}

$makePath = Join-Path $HarbourRoot 'contrib\make.hb'
$makeOld = @'
   cMakeFlags := GetEnv( "MAKEFLAGS" )
   IF " -j " $ " " + cMakeFlags + " "
      /* GNU Make uses job server to limit number of concurrent operations
         We cannot read it from MAKEFLAGS so I set it to arbitrary value: 8 */
      cOptions += " -jobs=8"
   ENDIF
'@
$makeNew = @'
   cMakeFlags := GetEnv( "MAKEFLAGS" )
   IF ! Empty( GetEnv( "HB_BUILD_JOBS" ) )
      /* Keep contrib/hbmk2 parallelism aligned with the outer build. */
      cOptions += " -jobs=" + GetEnv( "HB_BUILD_JOBS" )
   ELSEIF " -j " $ " " + cMakeFlags + " "
      /* GNU Make uses a job server, but hbmk2 cannot consume its tokens. */
      cOptions += " -jobs=8"
   ENDIF
'@
Update-TextFile -Path $makePath -Description 'controle de jobs das contribs' -OldText $makeOld -NewText $makeNew

$hbsslPath = Join-Path $HarbourRoot 'contrib\hbssl\hbssl.hbc'
$hbsslOld = '{!HB_DYNBIND_OPENSSL&win&(allmingw|clang|zig)}libs=ssl crypto'
$hbsslNew = @'
{!HB_DYNBIND_OPENSSL&win&(allmingw|clang)}libs=ssl crypto
{!HB_DYNBIND_OPENSSL&win&zig}libs=libssl libcrypto
'@
Update-TextFile -Path $hbsslPath -Description 'nomes OpenSSL do vcpkg para Zig' -OldText $hbsslOld -NewText $hbsslNew.TrimEnd()

$hbmagicPath = Join-Path $HarbourRoot 'contrib\hbmagic\hbmagic.hbc'
$hbmagicOld = @'
{unix}libs=magic
{darwin}libpaths=/opt/local/lib
'@
$hbmagicNew = @'
{unix}libs=magic
{win&zig}libs=magic
{darwin}libpaths=/opt/local/lib
'@
Update-TextFile -Path $hbmagicPath -Description 'libmagic do vcpkg para Zig' -OldText $hbmagicOld -NewText $hbmagicNew
