# Instalador guiado de uxdeployar para Windows. Se ejecuta en TU PC, nunca en el VPS:
#   irm https://raw.githubusercontent.com/<dueño>/uxdeployar-install/main/instalar.ps1 | iex
# Descarga el programa del PC, comprueba su SHA-256, lo deja en %LOCALAPPDATA%\uxdeployar-pc con el
# lanzador uxdeployar-pc.cmd y abre `uxdeployar-pc instalar`.
# Sin `exit`: dentro de `iex` cerraría la ventana de PowerShell. release/scripts-pc.sh rellena la URL y el hash del paquete de cada versión.
$ErrorActionPreference = 'Stop'
$UrlPaquete = 'https://raw.githubusercontent.com/uxlelmar-eaac/uxdeployar-install/v1.0.54/pc/uxdeployar-pc.tar.gz'
$ShaPaquete = 'b465a0f935958968b71ba96532062399fb1634db396ded0856fb11f0392e2e17'

function Salir([string]$Texto) {
  Write-Host "X  $Texto" -ForegroundColor Red
  throw 'uxdeployar: instalación detenida'
}

function Buscar-Python {
  foreach ($candidato in @(@('py', '-3'), @('python'), @('python3'))) {
    $orden = $candidato[0]
    $extra = @($candidato | Select-Object -Skip 1)
    if (-not (Get-Command $orden -ErrorAction SilentlyContinue)) { continue }
    & $orden @extra -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>$null
    if ($LASTEXITCODE -eq 0) { return , $candidato }
  }
  return $null
}

function Recargar-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

$python = Buscar-Python
if (-not $python) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Salir 'falta Python 3.10 o posterior: instálalo desde https://www.python.org/downloads/ y vuelve a ejecutar esto'
  }
  $r = Read-Host '?  Falta Python 3. ¿Lo instalo con winget? [S/n]'
  if ($r -and $r -notmatch '^[SsYy]') { Salir 'hace falta Python 3.10 o posterior' }
  winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
  Recargar-Path
  $python = Buscar-Python
  if (-not $python) { Salir 'Python instalado: abre una terminal nueva y vuelve a ejecutar esto' }
}
$pyOrden = $python[0]
$pyExtra = @($python | Select-Object -Skip 1)

$carpeta = Join-Path $env:LOCALAPPDATA 'uxdeployar-pc'
$marca = Join-Path $carpeta '.paquete'
$actual = if (Test-Path $marca) { (Get-Content $marca -Raw).Trim() } else { '' }
if ($actual -ne $ShaPaquete) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) "uxdeployar-pc-$PID.tar.gz"
  Write-Host '   descargando el programa del PC…'
  Invoke-WebRequest -UseBasicParsing -Uri $UrlPaquete -OutFile $tmp
  if ((Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower() -ne $ShaPaquete) {
    Remove-Item $tmp -Force
    Salir 'el paquete descargado no coincide con su SHA-256: no lo ejecuto'
  }
  $nuevo = "$carpeta.nuevo"
  if (Test-Path $nuevo) { Remove-Item $nuevo -Recurse -Force }
  New-Item -ItemType Directory -Path $nuevo | Out-Null
  tar -xzf $tmp -C $nuevo --strip-components 1
  if ($LASTEXITCODE -ne 0) { Salir 'no pude descomprimir el paquete (hace falta tar, incluido desde Windows 10)' }
  Remove-Item $tmp -Force
  $venv = Join-Path $carpeta '.venv'
  if (Test-Path $venv) { Move-Item $venv (Join-Path $nuevo '.venv') }
  if (Test-Path $carpeta) { Remove-Item $carpeta -Recurse -Force }
  Move-Item $nuevo $carpeta
  Set-Content -Path $marca -Value $ShaPaquete -Encoding ascii
}

$programa = Join-Path $carpeta 'ux-infra.py'
$lanzador = Join-Path $carpeta 'uxdeployar-pc.cmd'
$pyTexto = (@($pyOrden) + $pyExtra) -join ' '
Set-Content -Path $lanzador -Encoding ascii -Value "@echo off`r`n$pyTexto `"$programa`" %*"
Write-Host "   lanzador: $lanzador"

& $pyOrden @pyExtra $programa instalar @args
