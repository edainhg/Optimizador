# Abre la ultima version del Optimizador de Windows directamente desde GitHub.
# Uso, en PowerShell:
#     irm https://raw.githubusercontent.com/edainhg/Optimizador/main/instalar.ps1 | iex
#
# Descarga OptimizadorES.ps1 a %LOCALAPPDATA%\OptimizadorES y lo abre como administrador.
# (Este archivo va sin tildes a proposito: asi funciona igual en cualquier consola.)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"

$carpetaOpt = Join-Path $env:LOCALAPPDATA "OptimizadorES"
$destinoOpt = Join-Path $carpetaOpt "OptimizadorES.ps1"
$temporalOpt = "$destinoOpt.descarga"
$urlOpt = "https://raw.githubusercontent.com/edainhg/Optimizador/main/OptimizadorES.ps1"

New-Item -ItemType Directory -Force -Path $carpetaOpt | Out-Null
Write-Host "Descargando el Optimizador de Windows desde GitHub..."
Invoke-WebRequest -Uri $urlOpt -OutFile $temporalOpt -UseBasicParsing

# Comprobacion basica de que se bajo el optimizador y no una pagina de error
$cabecera = [IO.File]::ReadAllText($temporalOpt)
if ($cabecera -notmatch "OptimizadorES" -or $cabecera.Length -lt 100000) {
    Remove-Item -LiteralPath $temporalOpt -Force -ErrorAction SilentlyContinue
    throw "La descarga no parece el optimizador. Prueba de nuevo en unos minutos."
}
Move-Item -LiteralPath $temporalOpt -Destination $destinoOpt -Force
Unblock-File -LiteralPath $destinoOpt -ErrorAction SilentlyContinue

Write-Host "Abriendo el optimizador (acepta el aviso de permisos de Windows)..."
Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$destinoOpt`""
)
