$buildArgs = @{
   Profile = 'auto'
   Full = $true
}

& (Join-Path $PSScriptRoot 'scripts\Invoke-HarbourBuild.ps1') @buildArgs @args
