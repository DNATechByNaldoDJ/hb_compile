# Copy this file to config/external-deps.local.ps1 and adjust only what
# exists on your machine. The local file is ignored by git.
#
# Examples:
# $ProjectRoot = Split-Path -Parent $PSScriptRoot
# $env:HB_WITH_OPENSSL = Join-Path $ProjectRoot 'third_party\openssl\include'
# $env:HB_WITH_CURL = Join-Path $ProjectRoot 'third_party\curl\include'
# $env:HB_WITH_MYSQL = Join-Path $ProjectRoot 'third_party\mysql\include'
# $env:HB_WITH_PGSQL = Join-Path $ProjectRoot 'third_party\pgsql\include'
# $env:HB_WITH_FIREBIRD = Join-Path $ProjectRoot 'third_party\firebird\include'
# $env:HB_WITH_ADS = Join-Path $ProjectRoot 'third_party\ads\acesdk'
#
# To force bundled/local third-party sources where Harbour provides them:
# $env:HB_WITH_ZLIB = 'local'
# $env:HB_WITH_PCRE = 'local'
# $env:HB_WITH_SQLITE3 = 'local'
