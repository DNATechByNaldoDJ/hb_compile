[CmdletBinding()]
param(
   [Parameter(Mandatory)] [string] $InstallRoot,
   [Parameter(Mandatory)] [string] $HbdapRoot,
   [Parameter(Mandatory)] [string] $HarbourRoot,
   [Parameter(Mandatory)] [string] $BuildProfile,
   [ValidateSet('windows', 'wsl', 'docker')] [string] $Runner = 'windows',
   [string] $WslDistro = '',
   [string] $WslUser = '',
   [string] $DockerImage = 'hb-compile/linux:base',
   [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$HbdapRoot = [System.IO.Path]::GetFullPath($HbdapRoot)
$HarbourRoot = [System.IO.Path]::GetFullPath($HarbourRoot)
$binRoot = Join-Path $InstallRoot 'bin'
$hbmk2Name = if ($Runner -eq 'windows') { 'hbmk2.exe' } else { 'hbmk2' }
$hbmk2 = Join-Path $binRoot $hbmk2Name

function Get-GitRevision {
   param([string] $Root)
   $git = $null
   foreach ($candidate in @('C:\Program Files\Git\cmd\git.exe', 'git.exe', 'git')) {
      if ((Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) -or
         (Get-Command $candidate -ErrorAction SilentlyContinue)) {
         $git = $candidate
         break
      }
   }
   if (-not $git -or -not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { return '' }
   $revision = (& $git -c "safe.directory=$($Root.Replace('\', '/'))" -C $Root rev-parse HEAD 2>$null | Select-Object -First 1)
   if ($LASTEXITCODE -ne 0) { return '' }
   return ([string] $revision).Trim()
}

function Convert-ToWslPath {
   param([string] $Path)
   $arguments = @()
   if ($WslUser) { $arguments += @('--user', $WslUser) }
   if ($WslDistro) { $arguments += @('-d', $WslDistro) }
   $converted = & wsl.exe @arguments --exec wslpath -a -u $Path
   if ($LASTEXITCODE -ne 0) { throw "Falha ao converter caminho para WSL: $Path" }
   return ([string] $converted).Trim()
}

if (-not $DryRun) {
   foreach ($required in @($hbmk2, (Join-Path $HbdapRoot 'tools\adapter\hbdap_adapter.hbp'), (Join-Path $HbdapRoot 'tools\cli\hbdap_cli.hbp'))) {
      if (-not (Test-Path -LiteralPath $required)) { throw "Arquivo obrigatorio nao encontrado: $required" }
   }
   New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
}

$projects = @(
   @{ Name = 'hbdap_adapter'; Path = Join-Path $HbdapRoot 'tools\adapter\hbdap_adapter.hbp' },
   @{ Name = 'hbdap_cli'; Path = Join-Path $HbdapRoot 'tools\cli\hbdap_cli.hbp' }
)

foreach ($project in $projects) {
   $output = Join-Path $binRoot $project.Name
   if ($DryRun) {
      Write-Host "DryRun: compilar $($project.Name) para $binRoot no runner $Runner"
      continue
   }
   if ($Runner -eq 'windows') {
      & $hbmk2 $project.Path "-o$output"
   }
   elseif ($Runner -eq 'wsl') {
      $arguments = @()
      if ($WslUser) { $arguments += @('--user', $WslUser) }
      if ($WslDistro) { $arguments += @('-d', $WslDistro) }
      $linuxHbmk2 = Convert-ToWslPath $hbmk2
      $linuxProject = Convert-ToWslPath $project.Path
      $linuxOutput = Convert-ToWslPath $output
      & wsl.exe @arguments --exec $linuxHbmk2 $linuxProject "-o$linuxOutput"
   }
   else {
      $relativeInstall = [System.IO.Path]::GetRelativePath($ProjectRoot, $InstallRoot).Replace('\', '/')
      $containerHbmk2 = "/workspace/$relativeInstall/bin/hbmk2"
      $containerOutput = "/workspace/$relativeInstall/bin/$($project.Name)"
      $relativeProject = [System.IO.Path]::GetRelativePath($HbdapRoot, $project.Path).Replace('\', '/')
      & docker run --rm -v "${ProjectRoot}:/workspace" -v "${HbdapRoot}:/hbdap:ro" -w /workspace $DockerImage $containerHbmk2 "/hbdap/$relativeProject" "-o$containerOutput"
   }
   if ($LASTEXITCODE -ne 0) { throw "Falha ao compilar $($project.Name) no runner $Runner." }
}

if ($DryRun) { return }

$suffix = if ($Runner -eq 'windows') { '.exe' } else { '' }
$files = @($projects | ForEach-Object {
   $path = Join-Path $binRoot ($_.Name + $suffix)
   if (-not (Test-Path -LiteralPath $path)) { throw "Ferramenta HBDAP nao instalada: $path" }
   [ordered]@{ path = "bin/$($_.Name)$suffix"; sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant(); size = (Get-Item $path).Length }
})

$manifest = [ordered]@{
   schemaVersion = 1
   buildProfile = $BuildProfile
   runner = $Runner
   platform = if ($Runner -eq 'windows') { 'windows' } else { 'linux' }
   harbour = [ordered]@{ repository = 'https://github.com/harbour/core.git'; revision = Get-GitRevision $HarbourRoot }
   hbdap = [ordered]@{ repository = 'https://github.com/DNATechByNaldoDJ/hbdap.git'; revision = Get-GitRevision $HbdapRoot }
   files = $files
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $InstallRoot 'HBDAP_MANIFEST.json') -Encoding utf8
Write-Host "Ferramentas HBDAP instaladas em: $binRoot"
Write-Host "Manifesto conjunto: $(Join-Path $InstallRoot 'HBDAP_MANIFEST.json')"
