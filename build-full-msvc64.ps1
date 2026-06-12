$buildArgs = @{
   Profile = 'msvc64'
   Full = $true
}

$hasDependencyTriplet = @($args | Where-Object { $_ -match '^-DependencyTriplet($|[:=])' }).Count -gt 0

if (-not $hasDependencyTriplet) {
   $buildArgs.DependencyTriplet = 'x64-windows'
}

& (Join-Path $PSScriptRoot 'scripts\Invoke-HarbourBuild.ps1') @buildArgs @args
