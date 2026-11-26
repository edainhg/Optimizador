#Requires -Version 5.1
<#
    OptimizadorES - Optimizador de Windows en español con avisos de riesgo

    Basado en WinUtil de Chris Titus Tech (https://github.com/ChrisTitusTech/winutil),
    publicado bajo licencia MIT:

        MIT License
        Copyright (c) 2022 CT Tech Group LLC

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.

    Los ajustes (claves de registro, servicios y scripts) provienen de config/tweaks.json
    de WinUtil. Los textos en español, los niveles de riesgo y la interfaz son propios.

    Uso: clic derecho > "Ejecutar con PowerShell", o bien:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\OptimizadorES.ps1
#>

# -Prueba: carga todo (datos, motor e interfaz) sin pedir permisos ni mostrar la ventana.
# Lo usan las pruebas automáticas (tests/OptimizadorES.Tests.ps1).
param([switch]$Prueba)

# ---------------------------------------------------------------- Permisos de administrador
$identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identidad)
if (-not $Prueba -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Pidiendo permisos de administrador..."
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$PSCommandPath`""
    )
    exit
}

if (-not $Prueba -and $PSVersionTable.PSVersion.Major -ge 6) {
    # Checkpoint-Computer y WPF necesitan Windows PowerShell 5.1
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$PSCommandPath`""
    )
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:RutaScript = $PSCommandPath
$script:IconoPng = '__ICONO_PNG__'
$script:IconoIco = '__ICONO_ICO__'

function New-ImagenB64 {
    param([string]$Base64)
    if (-not $Base64) { return $null }
    try {
        $ms = New-Object System.IO.MemoryStream (, [Convert]::FromBase64String($Base64))
        $img = [Windows.Media.Imaging.BitmapFrame]::Create($ms, [Windows.Media.Imaging.BitmapCreateOptions]::None, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $img.Freeze()
        return $img
    } catch { return $null }
}

# ---------------------------------------------------------------- Datos
$DatosB64 = '__DATOS_B64__'
$script:Ajustes = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($DatosB64)) | ConvertFrom-Json

$CarpetaLog = Join-Path $env:LOCALAPPDATA "OptimizadorES"
New-Item -ItemType Directory -Force -Path $CarpetaLog | Out-Null
$global:ArchivoLog = Join-Path $CarpetaLog ("registro_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$global:Estado = [hashtable]::Synchronized(@{
    Cola     = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    Progreso = 0
    Texto    = ""
    Apps     = [hashtable]::Synchronized(@{})
})

# ---------------------------------------------------------------- Motor
# Se carga en la ventana principal y también en el hilo de trabajo.
$script:MotorCodigo = @'
$global:sync = @{}

function Escribir-Log {
    param([string]$Mensaje, [string]$Nivel = "INFO")
    $linea = "{0:HH:mm:ss} [{1}] {2}" -f (Get-Date), $Nivel, $Mensaje
    if ($global:Estado) { $global:Estado.Cola.Enqueue($linea) }
    if ($global:ArchivoLog) {
        try { Add-Content -Path $global:ArchivoLog -Value $linea -Encoding UTF8 } catch { }
    }
}

# Funciones con el nombre de WinUtil, porque algunos scripts de ajustes las llaman
function Write-WinUtilLog {
    param($Level = "INFO", $Component = "", $Message = "")
    Escribir-Log -Mensaje "$Component $Message" -Nivel $Level
}
function Invoke-WinutilThemeChange { param($theme) }
function Invoke-WinUtilExplorerUpdate {
    param([string]$action = "refresh")
    if ($action -eq "restart") {
        taskkill.exe /F /IM explorer.exe | Out-Null
        Start-Process explorer.exe
        return
    }
    if (-not ("OptES.Win32" -as [type])) {
        Add-Type -Namespace OptES -Name Win32 -MemberDefinition @"
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
"@
    }
    $resultado = [IntPtr]::Zero
    [void][OptES.Win32]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, "ImmersiveColorSet", 2, 100, [ref]$resultado)
}

function Initialize-HKU {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
    }
}

function Set-Registro {
    param($Ruta, $Nombre, $Tipo, $Valor)
    try {
        Initialize-HKU
        if ($Valor -eq "<RemoveEntry>") {
            $existe = $false
            if (Test-Path $Ruta) {
                $existe = $null -ne (Get-ItemProperty -Path $Ruta -Name $Nombre -ErrorAction SilentlyContinue)
            }
            if (-not $existe) { return $true }
            Remove-ItemProperty -Path $Ruta -Name $Nombre -Force -ErrorAction Stop
            Escribir-Log "Registro: eliminado $Ruta\$Nombre"
            return $true
        }
        if (-not (Test-Path $Ruta)) {
            New-Item -Path $Ruta -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $Ruta -Name $Nombre -Type $Tipo -Value $Valor -Force -ErrorAction Stop
        Escribir-Log "Registro: $Ruta\$Nombre = $Valor"
        return $true
    } catch {
        Escribir-Log "No se pudo cambiar $Ruta\$Nombre ($($_.Exception.Message))" "ERROR"
        return $false
    }
}

function Set-Servicio {
    param($Nombre, $Inicio, $Esperado)
    try {
        $servicio = Get-Service -Name $Nombre -ErrorAction Stop
    } catch {
        Escribir-Log "Servicio $Nombre no existe en este equipo; se omite." "AVISO"
        return $true
    }
    # Igual que WinUtil: si alguien ya cambió el servicio a mano, se respeta
    if ($Esperado -and ([string]$servicio.StartType -ne [string]$Esperado)) {
        Escribir-Log "Servicio ${Nombre}: está en $($servicio.StartType) (no en $Esperado); se deja como está." "AVISO"
        return $true
    }
    if ([string]$servicio.StartType -eq [string]$Inicio) { return $true }
    try {
        if ($Inicio -eq "AutomaticDelayedStart") {
            sc.exe config $Nombre start= delayed-auto | Out-Null
        } else {
            $servicio | Set-Service -StartupType $Inicio -ErrorAction Stop
        }
        Escribir-Log "Servicio ${Nombre}: inicio $Inicio"
        return $true
    } catch {
        Escribir-Log "No se pudo cambiar el servicio ${Nombre}: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# ----- Respaldo del estado real antes de cada ajuste (para "Deshacer" exacto)
function Get-RutaRespaldo { return (Join-Path $env:LOCALAPPDATA "OptimizadorES\respaldo-ajustes.json") }

function Read-Respaldo {
    $ruta = Get-RutaRespaldo
    $h = @{}
    if (Test-Path -LiteralPath $ruta) {
        try {
            $o = Get-Content -LiteralPath $ruta -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch {
            Escribir-Log "El archivo de respaldo está dañado; se ignora ($ruta)." "AVISO"
        }
    }
    return $h
}

function Save-Respaldo {
    param([hashtable]$Datos)
    $ruta = Get-RutaRespaldo
    New-Item -ItemType Directory -Force -Path (Split-Path $ruta) | Out-Null
    $temporal = "$ruta.tmp"
    ConvertTo-Json -InputObject $Datos -Depth 8 | Set-Content -LiteralPath $temporal -Encoding UTF8
    Move-Item -LiteralPath $temporal -Destination $ruta -Force
}

function Get-EstadoActual {
    param($Item)
    Initialize-HKU
    $regs = foreach ($r in @($Item.registry)) {
        if (-not $r) { continue }
        $existe = $false; $valor = $null; $tipo = $null
        try {
            if (Test-Path -LiteralPath $r.Path) {
                $clave = Get-Item -LiteralPath $r.Path -ErrorAction Stop
                if ($clave.GetValueNames() -contains $r.Name) {
                    $existe = $true
                    $valor = $clave.GetValue($r.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $tipo = [string]$clave.GetValueKind($r.Name)
                    if ($valor -is [byte[]]) { $valor = [Convert]::ToBase64String($valor) }
                }
            }
        } catch { }
        [pscustomobject]@{ Path = $r.Path; Name = $r.Name; Existe = $existe; Valor = $valor; Tipo = $tipo }
    }
    $svcs = foreach ($s in @($Item.service)) {
        if (-not $s) { continue }
        $sv = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if ($sv) { [pscustomobject]@{ Name = $s.Name; StartType = [string]$sv.StartType } }
    }
    return [pscustomobject]@{ Fecha = (Get-Date).ToString("s"); Nombre = $Item.Nombre; Registro = @($regs); Servicios = @($svcs) }
}

function Restore-EstadoGuardado {
    param($Guardado)
    $ok = $true
    foreach ($r in @($Guardado.Registro)) {
        if (-not $r) { continue }
        if ($r.Existe) {
            $v = $r.Valor
            if ($r.Tipo -eq "Binary") { $v = [Convert]::FromBase64String([string]$r.Valor) }
            elseif ($r.Tipo -eq "MultiString") { $v = [string[]]@($r.Valor) }
            if (-not (Set-Registro -Ruta $r.Path -Nombre $r.Name -Tipo $r.Tipo -Valor $v)) { $ok = $false }
        } else {
            if (-not (Set-Registro -Ruta $r.Path -Nombre $r.Name -Tipo "String" -Valor "<RemoveEntry>")) { $ok = $false }
        }
    }
    foreach ($s in @($Guardado.Servicios)) {
        if (-not $s) { continue }
        if (-not (Set-Servicio -Nombre $s.Name -Inicio $s.StartType)) { $ok = $false }
    }
    return $ok
}

function Invoke-Ajuste {
    param($Item, [bool]$Deshacer = $false)
    $accion = if ($Deshacer) { "Deshaciendo" } else { "Aplicando" }
    Escribir-Log "----- ${accion}: $($Item.Nombre)"
    $ok = $true
    $global:avisos = 0

    # Respaldo: al aplicar se guarda cómo estaba el equipo; al deshacer se restaura exacto
    $guardado = $null
    $respaldo = $null
    $tieneDatos = (@($Item.registry | Where-Object { $_ }).Count + @($Item.service | Where-Object { $_ }).Count) -gt 0
    if ($Item.Grupo -and $tieneDatos) {
        $respaldo = Read-Respaldo
        if ($Deshacer) {
            $guardado = $respaldo[[string]$Item.Key]
            if (-not $guardado) {
                Escribir-Log "No hay respaldo de este ajuste (se aplicó antes o con otra herramienta): se vuelve a los valores de fábrica de Windows."
            }
        } elseif (-not $respaldo.ContainsKey([string]$Item.Key)) {
            try {
                $respaldo[[string]$Item.Key] = Get-EstadoActual -Item $Item
                Save-Respaldo -Datos $respaldo
                Escribir-Log "Respaldo guardado de cómo estaba el equipo."
            } catch {
                Escribir-Log "No se pudo guardar el respaldo: $($_.Exception.Message). Por seguridad no se aplica este ajuste." "ERROR"
                return $false
            }
        }
    }

    foreach ($s in @($Item.service)) {
        if ($guardado) { break }
        if (-not $s) { continue }
        if ($Deshacer) {
            if (-not (Set-Servicio -Nombre $s.Name -Inicio $s.OriginalType -Esperado $s.StartupType)) { $ok = $false }
        } else {
            if (-not (Set-Servicio -Nombre $s.Name -Inicio $s.StartupType -Esperado $s.OriginalType)) { $ok = $false }
        }
    }

    foreach ($r in @($Item.registry)) {
        if ($guardado) { break }
        if (-not $r) { continue }
        $valor = if ($Deshacer) { $r.OriginalValue } else { $r.Value }
        if (-not (Set-Registro -Ruta $r.Path -Nombre $r.Name -Tipo $r.Type -Valor $valor)) { $ok = $false }
    }

    $scripts = if ($Deshacer) { @($Item.UndoScript) } else { @($Item.InvokeScript) }
    foreach ($codigo in $scripts) {
        if (-not $codigo) { continue }
        try {
            $bloque = [scriptblock]::Create($codigo)
            & $bloque 3>&1 6>&1 2>&1 | ForEach-Object {
                # Solo se anotan mensajes; los objetos que devuelven los comandos se omiten
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    $global:avisos++
                    Escribir-Log ($_.Exception.Message.Trim()) "AVISO"
                } elseif ($_ -is [System.Management.Automation.WarningRecord]) {
                    $global:avisos++
                    Escribir-Log ($_.Message.Trim()) "AVISO"
                } elseif ($_ -is [string] -or $_ -is [System.Management.Automation.InformationRecord]) {
                    $texto = ([string]$_).Trim()
                    if ($texto) { Escribir-Log $texto }
                }
            }
        } catch {
            Escribir-Log "Error en el script: $($_.Exception.Message)" "ERROR"
            $ok = $false
        }
    }

    if ($guardado) {
        # Después del script de deshacer, se dejan los valores exactos que había antes
        if (Restore-EstadoGuardado -Guardado $guardado) {
            $respaldo.Remove([string]$Item.Key)
            Save-Respaldo -Datos $respaldo
            Escribir-Log "Restaurado el valor exacto que tenía el equipo antes ($($guardado.Fecha))."
        } else {
            $ok = $false
        }
    }

    if ($ok -and $Item.Grupo -and $Item.Key -ne "WPFTweaksRestorePoint") {
        Add-Historial -Tipo "Ajuste" -Clave ([string]$Item.Key) -Nombre ([string]$Item.Nombre) -Accion $(if ($Deshacer) { "Deshecho" } else { "Aplicado" })
    }
    if ($ok -and $global:avisos) { Escribir-Log "Listo con avisos: $($Item.Nombre) (revisa las líneas AVISO de arriba)" "AVISO" }
    elseif ($ok) { Escribir-Log "Listo: $($Item.Nombre)" } else { Escribir-Log "Terminado con errores: $($Item.Nombre)" "ERROR" }
    return $ok
}

function Set-EstadoApp {
    param([string]$Id, [string]$Texto, [string]$Tipo = "info", [int]$Progreso = -1)
    if (-not $Id -or -not $global:Estado.Apps) { return }
    $global:Estado.Apps[$Id] = @{ Texto = $Texto; Tipo = $Tipo; Progreso = $Progreso }
}

function Get-RutaWinget {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Invoke-WingetEnVivo {
    # Ejecuta winget leyendo su salida carácter a carácter para ver el progreso de descarga
    param([string[]]$Argumentos, [string]$Id = "", [string]$Fase = "")
    $ruta = Get-RutaWinget
    if (-not $ruta) { throw "winget no está disponible. Usa Reparaciones > Reparar winget." }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ruta
    $psi.Arguments = ($Argumentos | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join " "
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $proceso = [Diagnostics.Process]::Start($psi)
    $tareaError = $proceso.StandardError.ReadToEndAsync()
    $buffer = New-Object System.Text.StringBuilder
    $ultima = ""
    $descargando = $false
    while ($true) {
        $n = $proceso.StandardOutput.Read()
        $fin = ($n -lt 0)
        $c = if ($fin) { [char]10 } else { [char]$n }
        if ($c -eq [char]13 -or $c -eq [char]10) {
            $t = $buffer.ToString().Trim()
            [void]$buffer.Clear()
            if ($t) {
                $m = [regex]::Match($t, '([\d.,]+)\s*(KB|MB|GB)\s*/\s*([\d.,]+)\s*(KB|MB|GB)')
                $p = [regex]::Match($t, '(\d{1,3})\s*%')
                if ($m.Success) {
                    $mult = @{ KB = 1KB; MB = 1MB; GB = 1GB }
                    $hecho = [double]($m.Groups[1].Value -replace ',', '.') * $mult[$m.Groups[2].Value]
                    $total = [double]($m.Groups[3].Value -replace ',', '.') * $mult[$m.Groups[4].Value]
                    $pct = if ($total -gt 0) { [int](100 * $hecho / $total) } else { 0 }
                    $descargando = $true
                    Set-EstadoApp -Id $Id -Texto ("Descargando {0} {1} de {2} {3}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value) -Tipo "trabajo" -Progreso $pct
                } elseif ($p.Success -and $t -match '[▀-▟]') {
                    Set-EstadoApp -Id $Id -Texto "$Fase $($p.Groups[1].Value)%" -Tipo "trabajo" -Progreso ([int]$p.Groups[1].Value)
                } elseif ($t -notmatch '[▀-▟]' -and $t -notmatch '^[-\\|/\s]+$') {
                    if ($descargando -and $Fase -ne "Desinstalando") {
                        $descargando = $false
                        Set-EstadoApp -Id $Id -Texto "Instalando..." -Tipo "trabajo" -Progreso 100
                    }
                    if ($t -ne $ultima) { Escribir-Log "   $t"; $ultima = $t }
                }
            }
        } else {
            [void]$buffer.Append($c)
        }
        if ($fin) { break }
    }
    $proceso.WaitForExit()
    $err = $tareaError.Result
    if ($err -and $err.Trim()) { Escribir-Log ("   " + $err.Trim()) "AVISO" }
    return $proceso.ExitCode
}

function Invoke-AppWinget {
    param([string]$Accion, [string]$Id = "", [string]$Fuente = "winget")
    $comunes = @("--accept-source-agreements", "--disable-interactivity")
    switch ($Accion) {
        "install"    { $argumentos = @("install", "--id", $Id, "--exact", "--source", $Fuente, "--accept-package-agreements", "--silent") + $comunes; $fase = "Instalando" }
        "upgrade"    { $argumentos = @("upgrade", "--id", $Id, "--exact", "--source", $Fuente, "--accept-package-agreements", "--silent") + $comunes; $fase = "Actualizando" }
        "uninstall"  { $argumentos = @("uninstall", "--id", $Id, "--exact", "--silent") + $comunes; $fase = "Desinstalando" }
        "upgradeall" { $argumentos = @("upgrade", "--all", "--accept-package-agreements", "--silent") + $comunes; $fase = "Actualizando" }
    }
    Set-EstadoApp -Id $Id -Texto "$fase..." -Tipo "trabajo" -Progreso 0
    try {
        $codigo = Invoke-WingetEnVivo -Argumentos $argumentos -Id $Id -Fase $fase
    } catch {
        Set-EstadoApp -Id $Id -Texto "Error: $($_.Exception.Message)" -Tipo "error"
        throw
    }
    $hecho = if ($Accion -eq "uninstall") { "No instalada" } else { "Instalada $([char]0x2714)" }
    $tipoHecho = if ($Accion -eq "uninstall") { "info" } else { "ok" }
    switch ($codigo) {
        0           { Escribir-Log "Hecho."; Set-EstadoApp -Id $Id -Texto $hecho -Tipo $tipoHecho }
        -1978335189 { Escribir-Log "Ya está en la última versión."; Set-EstadoApp -Id $Id -Texto "Instalada $([char]0x2714) (al día)" -Tipo "ok" }
        -1978335135 { Escribir-Log "Ya estaba instalada."; Set-EstadoApp -Id $Id -Texto "Instalada $([char]0x2714)" -Tipo "ok" }
        -1978334967 { Escribir-Log "Hecho. Necesita reiniciar el equipo para terminar." "AVISO"; Set-EstadoApp -Id $Id -Texto "$hecho (reinicia el equipo)" -Tipo "ok" }
        -1978335212 {
            Set-EstadoApp -Id $Id -Texto "No encontrada" -Tipo "error"
            throw "winget no encontró esta app (o no está instalada, si era para actualizar o desinstalar)."
        }
        default {
            Set-EstadoApp -Id $Id -Texto ("Error 0x{0:X8} (ver registro)" -f $codigo) -Tipo "error"
            throw ("winget terminó con el código 0x{0:X8}." -f $codigo)
        }
    }
}

function Get-EstadoApps {
    # Marca qué apps de la lista están instaladas y cuáles tienen actualización
    param([string[]]$Ids)
    if (-not (Get-RutaWinget)) { Escribir-Log "winget no está disponible; no se puede comprobar qué apps hay instaladas." "AVISO"; return }
    foreach ($i in $Ids) { Set-EstadoApp -Id $i -Texto "Comprobando..." -Tipo "trabajo" }
    Write-Output "Comprobando qué apps están instaladas (puede tardar un minuto)..."
    $archivo = Join-Path $env:TEMP ("winget_export_{0}.json" -f [guid]::NewGuid())
    $instaladas = @{}
    try {
        $null = Invoke-WingetEnVivo -Argumentos @("export", "-o", $archivo, "--accept-source-agreements", "--disable-interactivity")
        if (Test-Path $archivo) {
            $datos = Get-Content -Path $archivo -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($origen in @($datos.Sources)) {
                foreach ($pkg in @($origen.Packages)) { $instaladas[[string]$pkg.PackageIdentifier] = $true }
            }
        }
    } finally {
        Remove-Item -Path $archivo -Force -ErrorAction SilentlyContinue
    }
    $ruta = Get-RutaWinget
    $textoUpgrade = (& $ruta upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
    $cuenta = 0
    $conUpdate = 0
    foreach ($i in $Ids) {
        $tieneUpdate = $textoUpgrade -match ("(?<![\w.+-])" + [regex]::Escape($i) + "(?![\w.+-])")
        if ($instaladas.ContainsKey($i) -or $tieneUpdate) {
            $cuenta++
            if ($tieneUpdate) {
                $conUpdate++
                Set-EstadoApp -Id $i -Texto "Instalada - hay actualización" -Tipo "update"
            } else {
                Set-EstadoApp -Id $i -Texto "Instalada $([char]0x2714)" -Tipo "ok"
            }
        } else {
            Set-EstadoApp -Id $i -Texto "" -Tipo "info"
        }
    }
    Write-Output "De esta lista tienes $cuenta app(s) instalada(s); $conUpdate con actualización disponible."
}

function Get-EstadoToggle {
    param($Item)
    Initialize-HKU
    foreach ($r in @($Item.registry)) {
        if (-not $r) { continue }
        $actual = $null
        if (Test-Path $r.Path) {
            $actual = (Get-ItemProperty -Path $r.Path -ErrorAction SilentlyContinue).($r.Name)
        }
        if ($null -eq $actual) {
            switch ([string]$r.DefaultState) {
                "true"  { $actual = $r.Value }
                "false" { $actual = $r.OriginalValue }
            }
        }
        if ([string]$actual -ne [string]$r.Value) { return $false }
    }
    return $true
}

# ----- Historial de cambios (una línea JSON por cambio, en %LOCALAPPDATA%\OptimizadorES\historial.jsonl)
function Get-RutaHistorial { return (Join-Path $env:LOCALAPPDATA "OptimizadorES\historial.jsonl") }

function Add-Historial {
    param([string]$Tipo, [string]$Clave, [string]$Nombre, [string]$Accion, $Datos = $null)
    try {
        $ruta = Get-RutaHistorial
        New-Item -ItemType Directory -Force -Path (Split-Path $ruta) | Out-Null
        $linea = [ordered]@{ Fecha = (Get-Date).ToString("s"); Tipo = $Tipo; Clave = $Clave; Nombre = $Nombre; Accion = $Accion; Datos = $Datos } | ConvertTo-Json -Compress -Depth 6
        Add-Content -LiteralPath $ruta -Value $linea -Encoding UTF8
    } catch { }
}

# ----- Lee la tabla que escribe 'winget upgrade' (en español o en inglés)
function ConvertFrom-TablaWinget {
    param([string]$Texto)
    $resultado = New-Object System.Collections.ArrayList
    # winget dibuja una ruedita con retornos de carro: se queda lo que hay después del último
    $lineas = @(($Texto -replace "`r`n", "`n") -split "`n" | ForEach-Object {
        $l = $_; $i = $l.LastIndexOf([char]13)
        if ($i -ge 0) { $l = $l.Substring($i + 1) }
        $l.TrimEnd()
    })
    $sep = -1
    for ($i = 1; $i -lt $lineas.Count; $i++) { if ($lineas[$i] -match '^-{10,}$') { $sep = $i; break } }
    if ($sep -lt 1) { return ,$resultado }
    $cab = $lineas[$sep - 1]
    $cols = @([regex]::Matches($cab, '\S+') | ForEach-Object { $_.Index })
    if ($cols.Count -lt 4) { return ,$resultado }
    for ($i = $sep + 1; $i -lt $lineas.Count; $i++) {
        $l = $lineas[$i]
        if (-not $l.Trim()) { break }
        if ($l.Length -le $cols[3]) { continue }
        $campos = for ($n = 0; $n -lt $cols.Count; $n++) {
            $ini = $cols[$n]
            $fin = if ($n + 1 -lt $cols.Count) { [Math]::Min($cols[$n + 1], $l.Length) } else { $l.Length }
            if ($ini -ge $l.Length -or $fin -le $ini) { "" } else { $l.Substring($ini, $fin - $ini).Trim() }
        }
        $campos = @($campos)
        $id = $campos[1]
        $origen = if ($campos.Count -ge 5) { $campos[4] } else { "winget" }
        # Se descartan el pie ("3 actualizaciones disponibles") y los Id recortados con "…"
        if ($id -notmatch '^[\w.+-]+$' -or $campos[3] -notmatch '\d' -or $origen -notmatch '^(winget|msstore)$') { continue }
        [void]$resultado.Add(@{ Id = $id; Nombre = $campos[0]; Version = $campos[2]; Disponible = $campos[3]; Origen = $origen })
    }
    return ,$resultado
}

# ----- Busca restos de un programa desinstalado (carpetas, accesos directos y claves del registro)
function Find-Restos {
    param([string]$Nombre, [string]$Editor = "", [string]$Ubicacion = "")
    $hallados = New-Object System.Collections.ArrayList
    $vistos = @{}
    $prohibidos = '^(Microsoft|Windows|Microsoft Corporation|Common Files|Intel|AMD|NVIDIA|Google|Mozilla|Adobe|Programs|Packages|Temp|WindowsApps|Realtek|Package Cache|Installer|Java|Oracle|Apple|Classes|Policies|Wow6432Node|Software|System|Program Files|ProgramData|AppData|Users|Default|Public|Drivers|Hewlett-Packard|HP|Dell|Lenovo|ASUS|Acer|Steam|Epic Games|Origin|Ubisoft|Program|Data|Tools|Update|Updater|Setup|Uninstall|Client|Server|Service|Services|Application|Applications|Launcher)$'
    $base = $Nombre -replace '\s*\([^)]*\)', ' ' -replace '(?i)\s+(x64|x86|64-bit|32-bit|64 bits|32 bits)\b', ' ' -replace '\s+v?\d+([.,]\d+)+.*$', '' -replace '\s+', ' '
    $base = $base.Trim(" -_.".ToCharArray())
    $candidatos = @(@($base, $Nombre.Trim()) | Where-Object { $_ -and $_.Length -ge 4 -and $_ -notmatch $prohibidos -and $_ -notmatch '[\\/:*?"<>|]' } | Select-Object -Unique)
    $editores = @()
    if ($Editor) {
        $ed = ($Editor -replace '(?i)[,.]?\s+(Inc|LLC|Ltd|Limited|GmbH|Corporation|Corp|Co|S\.?A|S\.?L|Software|Technologies|Technology)\.?$', '').Trim(" ,.".ToCharArray())
        $editores = @(@($Editor.Trim(), $ed) | Where-Object { $_ -and $_.Length -ge 3 -and $_ -notmatch '[\\/:*?"<>|]' } | Select-Object -Unique)
    }
    if (-not $candidatos.Count) { return ,$hallados }

    function Add-Resto([string]$Tipo, [string]$Ruta) {
        if ($vistos.ContainsKey($Ruta)) { return }
        $vistos[$Ruta] = $true
        $mb = 0
        if ($Tipo -eq "Carpeta") {
            try { $mb = [math]::Round((Get-ChildItem -LiteralPath $Ruta -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB, 1) } catch { }
        }
        [void]$hallados.Add(@{ Tipo = $Tipo; Ruta = $Ruta; MB = $mb })
    }

    $raices = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA, (Join-Path $env:LOCALAPPDATA "Programs")) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    foreach ($r in $raices) {
        foreach ($c in $candidatos) {
            $p = Join-Path $r $c
            if (Test-Path -LiteralPath $p -PathType Container) { Add-Resto "Carpeta" $p }
            foreach ($e in $editores) {
                $p2 = Join-Path (Join-Path $r $e) $c
                if (Test-Path -LiteralPath $p2 -PathType Container) { Add-Resto "Carpeta" $p2 }
            }
        }
    }
    # Carpeta de instalación, solo si está dentro de una carpeta de programas y no es la raíz
    if ($Ubicacion) {
        $u = $Ubicacion.Trim().Trim('"').TrimEnd('\')
        $dentro = @($raices | Where-Object { $u -like "$_\*" }).Count -gt 0
        if ($dentro -and ($raices -notcontains $u) -and (Split-Path $u -Leaf) -notmatch $prohibidos -and (Test-Path -LiteralPath $u -PathType Container)) { Add-Resto "Carpeta" $u }
    }
    # Accesos directos del menú Inicio y del Escritorio
    $menus = @([Environment]::GetFolderPath("Programs"), [Environment]::GetFolderPath("CommonPrograms"))
    $escritorios = @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("CommonDesktopDirectory"))
    foreach ($c in $candidatos) {
        foreach ($m in $menus) {
            if (-not $m) { continue }
            $p = Join-Path $m $c
            if (Test-Path -LiteralPath $p -PathType Container) { Add-Resto "Carpeta" $p }
            if (Test-Path -LiteralPath "$p.lnk") { Add-Resto "Acceso" "$p.lnk" }
        }
        foreach ($d in $escritorios) {
            if ($d -and (Test-Path -LiteralPath (Join-Path $d "$c.lnk"))) { Add-Resto "Acceso" (Join-Path $d "$c.lnk") }
        }
    }
    # Claves del registro
    $raicesReg = "HKCU:\Software", "HKLM:\SOFTWARE", "HKLM:\SOFTWARE\WOW6432Node"
    foreach ($rr in $raicesReg) {
        foreach ($c in $candidatos) {
            $k = "$rr\$c"
            if (Test-Path -LiteralPath $k) { Add-Resto "Registro" $k }
            foreach ($e in $editores) {
                $k2 = "$rr\$e\$c"
                if (Test-Path -LiteralPath $k2) { Add-Resto "Registro" $k2 }
            }
        }
    }
    return ,$hallados
}
'@

. ([scriptblock]::Create($script:MotorCodigo))

# ---------------------------------------------------------------- Interfaz
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Optimizador de Windows (en español)" Width="1180" Height="800"
        MinWidth="900" MinHeight="580" WindowStartupLocation="CenterScreen"
        Background="#EEF1F5" Foreground="#1F2937" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#1F2937"/>
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="BorderBrush" Value="#2563EB"/>
                <Setter TargetName="B" Property="Opacity" Value="0.92"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="B" Property="Opacity" Value="0.75"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="B" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primario" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#1D4ED8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="BorderBrush" Value="#D1D5DB"/>
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#1F2937"/>
      <Setter Property="Padding" Value="6,4"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#1F2937"/>
    </Style>
    <Style TargetType="Expander">
      <Setter Property="Foreground" Value="#1F2937"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="Black"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Fondo" Background="Transparent" CornerRadius="6" Margin="0,1" Padding="12,9">
              <Grid>
                <Border x:Name="Marca" Width="3" HorizontalAlignment="Left" Margin="-12,0,0,0" CornerRadius="2"
                        Background="#2563EB" Visibility="Collapsed"/>
                <StackPanel Orientation="Horizontal">
                  <TextBlock x:Name="Icono" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"
                             FontFamily="Segoe MDL2 Assets" FontSize="15" Width="28" VerticalAlignment="Center" Foreground="#6B7280"/>
                  <TextBlock x:Name="Texto" Text="{Binding Header, RelativeSource={RelativeSource TemplatedParent}}"
                             VerticalAlignment="Center" Foreground="#374151" FontSize="13.5"/>
                </StackPanel>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Fondo" Property="Background" Value="#EEF2F7"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Fondo" Property="Background" Value="#E3ECFD"/>
                <Setter TargetName="Marca" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Texto" Property="Foreground" Value="#1D4ED8"/>
                <Setter TargetName="Texto" Property="FontWeight" Value="SemiBold"/>
                <Setter TargetName="Icono" Property="Foreground" Value="#2563EB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Grupo" TargetType="TabItem">
      <Setter Property="IsEnabled" Value="False"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <TextBlock Text="{Binding Header, RelativeSource={RelativeSource TemplatedParent}}" Margin="12,14,0,4"
                       FontSize="11" FontWeight="SemiBold" Foreground="#9CA3AF"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Foreground" Value="#1F2937"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <Border Background="#F7F8FA" BorderBrush="#E2E6EC" BorderThickness="1" CornerRadius="10">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="200"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border Background="#FFFFFF" BorderBrush="#E2E6EC" BorderThickness="0,0,1,0" CornerRadius="10,0,0,10">
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel IsItemsHost="True" Margin="8,4,8,12"/>
                  </ScrollViewer>
                </Border>
                <ContentPresenter Grid.Column="1" ContentSource="SelectedContent" Margin="4"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="120"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" CornerRadius="10" Padding="18,14" Margin="0,0,0,12">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#1E3A8A" Offset="0"/>
          <GradientStop Color="#2563EB" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <DockPanel>
        <Image x:Name="ImgLogo" DockPanel.Dock="Left" Width="44" Height="44" Margin="0,0,14,0" VerticalAlignment="Center"/>
        <Button x:Name="BtnTema" DockPanel.Dock="Right" Content="Modo oscuro" Margin="14,0,0,0" Padding="10,5" VerticalAlignment="Center"
                Background="#22FFFFFF" Foreground="White" BorderBrush="#66FFFFFF" ToolTip="Cambia entre modo claro y oscuro (el optimizador se vuelve a abrir)"/>
        <TextBlock x:Name="TxtEquipo" DockPanel.Dock="Right" Foreground="#DCEBFE" FontSize="12" TextAlignment="Right"
                   VerticalAlignment="Center" Margin="16,0,0,0"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Optimizador de Windows" FontSize="22" FontWeight="SemiBold" Foreground="White"/>
          <TextBlock TextWrapping="Wrap" Foreground="#DCEBFE" Margin="0,2,0,0"
                     Text="Analiza, limpia y ajusta Windows. Cada opción indica su nivel de riesgo y antes de cambiar nada se crea un punto de restauración."/>
        </StackPanel>
      </DockPanel>
    </Border>

    <TabControl Grid.Row="1" x:Name="Pestanas">
      <TabItem x:Name="TabInicio" Header="Inicio" Tag="&#xE80F;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelInicio" Margin="14"/>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="OPTIMIZAR" Style="{StaticResource Grupo}"/>
      <TabItem x:Name="TabPerfiles" Header="Perfiles de un clic" Tag="&#xE734;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelPerfiles" Margin="14"/>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabAjustes" Header="Ajustes" Tag="&#xE713;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelAjustes" Margin="12"/>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabPreferencias" Header="Preferencias" Tag="&#xE771;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="12">
            <TextBlock TextWrapping="Wrap" Foreground="#4B5563" Margin="0,0,0,10"
                       Text="Las casillas muestran cómo está tu Windows ahora. Cambia las que quieras y pulsa 'Aplicar preferencias'. Solo se tocan las que cambies."/>
            <StackPanel x:Name="PanelPreferencias"/>
          </StackPanel>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabRendimiento" Header="Rendimiento y disco" Tag="&#xE9D9;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelRendimiento" Margin="14"/>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabPrivacidad" Header="Privacidad" Tag="&#xE72E;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelPrivacidad" Margin="14"/>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabArranque" Header="Arranque de Windows" Tag="&#xE7E8;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelArranque" Margin="14"/>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="PROGRAMAS Y CONTROLADORES" Style="{StaticResource Grupo}"/>
      <TabItem x:Name="TabApps" Header="Apps" Tag="&#xE71D;">
        <DockPanel>
          <WrapPanel DockPanel.Dock="Top" Margin="12,10,12,4">
            <TextBlock Text="Buscar:" VerticalAlignment="Center" Margin="0,0,6,4"/>
            <TextBox x:Name="TxtBuscarApp" Width="200" Padding="4,3" Margin="0,0,12,4"/>
            <Button x:Name="BtnAppsInstalar" Content="Instalar seleccionadas" Padding="12,5" Margin="0,0,6,4" Style="{StaticResource Primario}"/>
            <Button x:Name="BtnAppsActualizar" Content="Actualizar seleccionadas" Padding="12,5" Margin="0,0,6,4"/>
            <Button x:Name="BtnAppsDesinstalar" Content="Desinstalar seleccionadas" Padding="12,5" Margin="0,0,6,4"/>
            <Button x:Name="BtnAppsTodo" Content="Actualizar TODAS las apps del equipo" Padding="12,5" Margin="0,0,6,4"/>
            <Button x:Name="BtnAppsLimpiar" Content="Quitar selección" Padding="12,5" Margin="0,0,6,4"/>
            <Button x:Name="BtnAppsComprobar" Content="Comprobar instaladas" Padding="12,5" Margin="0,0,6,4"/>
            <Button x:Name="BtnAppsActualizables" Content="Marcar las que tienen actualización" Padding="12,5" Margin="0,0,6,4"/>
            <Button x:Name="BtnAppsPanel" Content="Otros programas instalados" Padding="12,5" Margin="0,0,6,4"/>
          </WrapPanel>
          <TextBlock x:Name="TxtWinget" DockPanel.Dock="Top" Margin="12,0,12,6" TextWrapping="Wrap" Foreground="#4B5563"/>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="PanelApps" Margin="12,0,12,12"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>
      <TabItem x:Name="TabProgramas" Header="Mis programas" Tag="&#xE8F1;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelProgramas" Margin="14"/>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabControladores" Header="Controladores" Tag="&#xE950;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelControladores" Margin="14"/>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="PROTEGER Y REPARAR" Style="{StaticResource Grupo}"/>
      <TabItem x:Name="TabSeguridad" Header="Seguridad" Tag="&#xEA18;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelSeguridad" Margin="12"/>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabReparaciones" Header="Reparaciones" Tag="&#xE90F;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelReparaciones" Margin="12"/>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabInforme" Header="Informe del equipo" Tag="&#xE9F9;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelInforme" Margin="12"/>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="SISTEMA" Style="{StaticResource Grupo}"/>
      <TabItem x:Name="TabConfig" Header="Configuración" Tag="&#xE912;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelConfig" Margin="12"/>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabHistorial" Header="Historial de cambios" Tag="&#xE81C;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelHistorial" Margin="14"/>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabAyuda" Header="Riesgos y ayuda" Tag="&#xE897;">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelAyuda" Margin="16"/>
        </ScrollViewer>
      </TabItem>
    </TabControl>

    <Grid Grid.Row="2" Margin="0,12,0,8">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <WrapPanel Grid.Column="0" x:Name="BotonesAjustes" VerticalAlignment="Center">
        <Button x:Name="BtnRecomendados" Content="Seleccionar recomendados (riesgo bajo)" Padding="12,6" Margin="0,0,8,4"/>
        <Button x:Name="BtnPresetEstandar" Content="Preset Estándar" Padding="12,6" Margin="0,0,8,4" ToolTip="Mismo preset 'Standard' de WinUtil"/>
        <Button x:Name="BtnPresetMinimo" Content="Preset Mínimo" Padding="12,6" Margin="0,0,8,4" ToolTip="Mismo preset 'Minimal' de WinUtil"/>
        <Button x:Name="BtnLimpiar" Content="Quitar selección" Padding="12,6" Margin="0,0,8,4"/>
        <Button x:Name="BtnDeshacer" Content="Deshacer seleccionados" Padding="12,6" Margin="0,0,8,4"/>
        <Button x:Name="BtnRestaurar" Content="Abrir Restaurar sistema" Padding="12,6" Margin="0,0,8,4"/>
        <Button x:Name="BtnExportar" Content="Exportar configuración" Padding="12,6" Margin="0,0,8,4"/>
        <Button x:Name="BtnImportar" Content="Importar configuración" Padding="12,6" Margin="0,0,8,4"/>
      </WrapPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="BtnPreferencias" Content="Aplicar preferencias" Padding="14,6" Margin="0,0,8,4" Style="{StaticResource Primario}"/>
        <Button x:Name="BtnAplicar" Content="Aplicar seleccionados" Padding="18,6" Margin="0,0,0,4" Style="{StaticResource Primario}"/>
      </StackPanel>
    </Grid>

    <Grid Grid.Row="3">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <DockPanel Grid.Row="0" Margin="0,0,0,4">
        <TextBlock x:Name="TxtEstado" DockPanel.Dock="Left" Foreground="#374151" Text="Listo."/>
        <ProgressBar x:Name="Barra" Height="8" Margin="12,0,0,0" Minimum="0" Maximum="100" Value="0"/>
      </DockPanel>
      <Border Grid.Row="1" CornerRadius="8" Background="#0B1120" Padding="2">
        <TextBox x:Name="TxtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                 Background="#0B1120" Foreground="#E5E7EC" BorderThickness="0" Padding="8"/>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

# ---------------------------------------------------------------- Preferencias del optimizador (tema y pestaña al abrir)
$script:RutaPrefs = Join-Path $env:LOCALAPPDATA "OptimizadorES\preferencias.json"
$script:Prefs = @{ Tema = "Claro"; RecordarPestana = $false; UltimaPestana = ""; AbrirEn = "" }
if (-not $Prueba -and (Test-Path -LiteralPath $script:RutaPrefs)) {
    try {
        $prefsLeidas = Get-Content -LiteralPath $script:RutaPrefs -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($pr in $prefsLeidas.PSObject.Properties) { $script:Prefs[$pr.Name] = $pr.Value }
    } catch { }
}
function Save-Prefs {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $script:RutaPrefs) | Out-Null
        $script:Prefs | ConvertTo-Json | Set-Content -LiteralPath $script:RutaPrefs -Encoding UTF8
    } catch { }
}
$script:Oscuro = ([string]$script:Prefs.Tema -eq "Oscuro")
# Modo oscuro: cada color claro de la interfaz se cambia por su equivalente oscuro
$script:MapaOscuro = @{
    "#FFFFFF" = "#1E293B"; "#F7F8FA" = "#0F172A"; "#EEF1F5" = "#0B1220"; "#E2E6EC" = "#334155"; "#E5E7EB" = "#334155"
    "#D1D5DB" = "#475569"; "#F3F4F6" = "#0F172A"; "#EEF2F7" = "#24324A"; "#E3ECFD" = "#1E3A8A"
    "#111827" = "#F1F5F9"; "#1F2937" = "#E2E8F0"; "#374151" = "#CBD5E1"; "#4B5563" = "#B6C2D1"; "#6B7280" = "#94A3B8"; "#9CA3AF" = "#64748B"
    "#2563EB" = "#3B82F6"; "#1D4ED8" = "#93C5FD"; "#DBEAFE" = "#1E3A8A"
    "#E7F6EC" = "#14532D"; "#1E7B3A" = "#86EFAC"; "#FFF4E0" = "#4A3410"; "#A85F00" = "#FBBF24"; "#FDE8E8" = "#4C1D1D"; "#B42318" = "#FCA5A5"
    "#FFFBEB" = "#3A2A0A"; "#FEF2F2" = "#3B1414"; "#16A34A" = "#22C55E"; "#DC2626" = "#EF4444"; "#D97706" = "#F59E0B"
    "#86EFAC" = "#166534"; "#93C5FD" = "#1E40AF"; "#FCA5A5" = "#7F1D1D"
}
function Convert-ColoresOscuro([string]$Texto) {
    return [regex]::Replace($Texto, '#[0-9A-Fa-f]{6}\b', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $c = $script:MapaOscuro[$m.Value]
        if ($c) { return $c } else { return $m.Value }
    })
}
if ($script:Oscuro) { $xaml = Convert-ColoresOscuro $xaml }

$lector = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$script:Ventana = [Windows.Markup.XamlReader]::Load($lector)
$ui = @{}
foreach ($n in "PanelAjustes","PanelPreferencias","PanelAyuda","PanelSeguridad","PanelApps","TxtBuscarApp","BtnAppsInstalar","BtnAppsActualizar","BtnAppsDesinstalar","BtnAppsTodo","BtnAppsLimpiar","BtnAppsComprobar","BtnAppsActualizables","BtnAppsPanel","TxtWinget","PanelReparaciones","PanelInforme","PanelConfig","BtnPresetEstandar","BtnPresetMinimo","BtnExportar","BtnImportar","BtnRecomendados","BtnLimpiar","BtnDeshacer","BtnRestaurar","BtnPreferencias","BtnAplicar","TxtEstado","Barra","TxtLog","Pestanas","ImgLogo","PanelInicio","PanelRendimiento","TxtEquipo","PanelControladores","PanelPerfiles","PanelPrivacidad","PanelArranque","PanelProgramas","PanelHistorial","BtnTema") {
    $ui[$n] = $script:Ventana.FindName($n)
}
$script:UI = $ui
$logo = New-ImagenB64 $script:IconoPng
if ($logo) { $script:Ventana.Icon = $logo; $ui.ImgLogo.Source = $logo }

$script:TarjetaPorId = @{}
$script:HechosSesion = @{}
$script:InfoAjuste = @{}
$script:Colores = @{
    Bajo  = @{ Fondo = "#E7F6EC"; Texto = "#1E7B3A"; Etiqueta = "Riesgo bajo" }
    Medio = @{ Fondo = "#FFF4E0"; Texto = "#A85F00"; Etiqueta = "Riesgo medio" }
    Alto  = @{ Fondo = "#FDE8E8"; Texto = "#B42318"; Etiqueta = "Riesgo ALTO" }
}
$conversor = New-Object System.Windows.Media.BrushConverter
function Get-Pincel([string]$hex) {
    if ($script:Oscuro) { $hexOscuro = $script:MapaOscuro[$hex]; if ($hexOscuro) { $hex = $hexOscuro } }
    return $conversor.ConvertFromString($hex)
}

# ---------------------------------------------------------------- Detalles: qué hace cada opción
# Resumen corto siempre visible; el detalle completo se abre con "Ver detalles".
$script:NombresInicio = @{ Automatic = "automático"; AutomaticDelayedStart = "automático (retrasado)"; Manual = "manual"; Disabled = "desactivado"; Boot = "arranque"; System = "sistema" }

function Get-DetalleTecnico($Item) {
    $l = New-Object System.Collections.Generic.List[string]
    if ($Item.Detalle) { $l.Add([string]$Item.Detalle) }

    $regs = @($Item.registry | Where-Object { $_ })
    if ($regs.Count) {
        if ($l.Count) { $l.Add("") }
        $l.Add("Cambios en el registro de Windows:")
        foreach ($r in $regs) {
            $ruta = "$($r.Path)\$($r.Name)"
            if ($r.Value -eq "<RemoveEntry>") { $l.Add("  • Borra $ruta") }
            else {
                $orig = if ($r.OriginalValue -eq "<RemoveEntry>") { "normalmente no existe" } else { "normal: $($r.OriginalValue)" }
                $l.Add("  • $ruta = $($r.Value)   ($orig)")
            }
        }
    }
    $svcs = @($Item.service | Where-Object { $_ })
    if ($svcs.Count) {
        if ($l.Count) { $l.Add("") }
        $l.Add("Servicios de Windows:")
        foreach ($s in $svcs) {
            $a = $script:NombresInicio[[string]$s.StartupType]; if (-not $a) { $a = $s.StartupType }
            $o = $script:NombresInicio[[string]$s.OriginalType]; if (-not $o) { $o = $s.OriginalType }
            $l.Add("  • $($s.Name): inicio $a   (normal: $o)")
        }
    }
    $scripts = @($Item.InvokeScript | Where-Object { $_ })
    if ($scripts.Count) {
        $lineas = @(($scripts -join "`n") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") })
        if ($lineas.Count) {
            if ($l.Count) { $l.Add("") }
            $l.Add("Comandos que ejecuta ($($lineas.Count) línea(s)):")
            foreach ($ln in ($lineas | Select-Object -First 8)) {
                $l.Add("  " + $(if ($ln.Length -gt 120) { $ln.Substring(0, 117) + "..." } else { $ln }))
            }
            if ($lineas.Count -gt 8) { $l.Add("  ... y $($lineas.Count - 8) línea(s) más.") }
        }
    }
    if ($Item.Grupo -eq "Preferencias") {
        if ($l.Count) { $l.Add("") }
        $l.Add("Cómo deshacerlo: cambia la casilla y pulsa 'Aplicar preferencias'.")
    } elseif ($Item.Grupo) {
        if ($l.Count) { $l.Add("") }
        if ($regs.Count -or $svcs.Count) { $l.Add("Cómo deshacerlo: márcalo y pulsa 'Deshacer seleccionados'. Vuelve exactamente a como estaba (se guarda una copia antes de aplicar).") }
        elseif (@($Item.UndoScript | Where-Object { $_ }).Count) { $l.Add("Cómo deshacerlo: márcalo y pulsa 'Deshacer seleccionados' (ejecuta el script inverso).") }
        else { $l.Add("No tiene deshacer automático: si algo falla, usa el punto de restauración.") }
    }
    return ($l -join "`n")
}

function Add-Detalles($Pila, $Item) {
    $hay = $Item.Detalle -or @($Item.registry | Where-Object { $_ }).Count -or @($Item.service | Where-Object { $_ }).Count -or @($Item.InvokeScript | Where-Object { $_ }).Count
    if (-not $hay) { return }
    $exp = New-Object System.Windows.Controls.Expander
    $exp.Header = "Ver detalles: qué hace exactamente"
    $exp.Foreground = Get-Pincel "#2563EB"
    $exp.FontSize = 12
    $exp.Margin = "16,4,0,0"
    $exp.Tag = $Item
    # El texto se arma al abrirlo, así la ventana carga igual de rápido
    $exp.Add_Expanded({
        param($origen, $e)
        if ($origen.Content) { return }
        $txt = New-Object System.Windows.Controls.TextBox
        $txt.Text = Get-DetalleTecnico $origen.Tag
        $txt.IsReadOnly = $true
        $txt.TextWrapping = "Wrap"
        $txt.BorderThickness = 0
        $txt.Background = Get-Pincel "#F3F4F6"
        $txt.Foreground = Get-Pincel "#374151"
        $txt.FontFamily = "Segoe UI"
        $txt.FontSize = 12
        $txt.Padding = "10,8"
        $txt.Margin = "0,4,0,2"
        $origen.Content = $txt
    })
    [void]$Pila.Children.Add($exp)
}

$script:DetallesAcciones = @{
    "Análisis rápido con Microsoft Defender" = "1. Actualiza las firmas de Defender desde Microsoft.`n2. Analiza memoria, arranque y carpetas donde suele esconderse el malware (5 a 15 minutos).`n3. Escribe en el registro de abajo las amenazas encontradas en este análisis.`nDefender pone en cuarentena lo que detecta; no borra tus archivos."
    "Análisis completo con Microsoft Defender" = "1. Actualiza las firmas de Defender.`n2. Revisa TODOS los archivos de todos los discos (1 hora o más; el equipo irá más lento mientras tanto).`n3. Muestra las amenazas encontradas.`nSi otro antivirus (ESET, etc.) está activo, Defender está en modo pasivo y este análisis puede no estar disponible."
    "Segunda opinión: Microsoft Safety Scanner" = "1. Descarga msert.exe (unos 200 MB) directamente de Microsoft.`n2. Comprueba que esté firmado por Microsoft; si no, lo borra.`n3. Abre el asistente para que elijas análisis rápido o completo.`nNo se instala ni choca con tu antivirus. El informe queda en C:\Windows\debug\msert.log."
    "Abrir mi antivirus" = "Abre la ventana de Seguridad de Windows, donde se ve el antivirus activo y su estado. No cambia nada."
    "Reparar archivos de Windows (DISM + SFC)" = "1. DISM /RestoreHealth: compara la imagen de Windows con la de Microsoft y descarga lo dañado (10 a 30 min).`n2. SFC /scannow: revisa los archivos del sistema y repone los que estén corruptos (10 a 20 min).`n3. Muestra el resultado de cada paso. El detalle completo queda en C:\Windows\Logs\CBS\CBS.log.`nNo toca tus documentos ni programas. Reinicia al terminar."
    "Ver programas que arrancan con Windows" = "Lista en el registro de abajo los programas que se abren al encender (nombre y comando). Solo lee, no cambia nada."
    "Limpiar caché DNS" = "Ejecuta 'ipconfig /flushdns': borra la lista de direcciones de páginas guardada en el equipo para que se vuelvan a consultar. Es inmediato y no afecta a nada más."
    "Restablecer la red" = "1. Limpia la caché DNS.`n2. 'netsh winsock reset': devuelve Winsock a su estado de fábrica (arregla programas que rompen la conexión).`n3. 'netsh int ip reset' para IPv4 e IPv6: borra la configuración TCP/IP.`nHay que reiniciar. Si tenías IP fija puesta a mano, hay que volver a escribirla."
    "Reparar Windows Update" = "1. Detiene los servicios wuauserv, bits, cryptsvc y msiserver.`n2. Renombra las carpetas SoftwareDistribution y catroot2 a .old (Windows crea unas nuevas y limpias).`n3. Vuelve a arrancar los servicios.`nLas actualizaciones pendientes se vuelven a descargar. Reinicia y busca actualizaciones."
    "Desatascar la impresora" = "1. Detiene el servicio de cola de impresión (Spooler).`n2. Borra los trabajos pendientes de C:\Windows\System32\spool\PRINTERS.`n3. Vuelve a arrancar el servicio.`nNo borra impresoras ni controladores; solo los documentos en cola."
    "Reparar Microsoft Store" = "Ejecuta wsreset.exe, la herramienta oficial que borra la caché de la Tienda. No desinstala apps ni cierra tu sesión. La Tienda se abre sola al terminar."
    "Reparar winget" = "1. Vuelve a registrar el 'Instalador de aplicación' de Microsoft (que incluye winget).`n2. Restablece y actualiza sus orígenes de descarga.`n3. Si winget no existe, abre la Tienda en la página del Instalador de aplicación para que lo instales."
    "Reconstruir iconos y miniaturas" = "1. Cierra el Explorador (la barra y el escritorio desaparecen unos segundos).`n2. Borra IconCache.db, iconcache_*.db y thumbcache_*.db de tu perfil.`n3. Vuelve a abrir el Explorador, que crea las cachés de nuevo."
    "Sincronizar la hora" = "1. Pone el servicio de hora de Windows (w32time) en manual y lo arranca.`n2. Ejecuta 'w32tm /resync /force' para pedir la hora al servidor de Internet.`n3. Muestra la hora resultante."
    "Generar informe del equipo" = "Recopila: fabricante, modelo y número de serie, BIOS, Windows y activación, procesador, RAM y ranuras, gráficos, discos y su salud, batería, red e IP, antivirus, BitLocker, dispositivos con errores, errores críticos de los últimos 7 días y programas de arranque.`nLo guarda en un .txt en %LOCALAPPDATA%\OptimizadorES\Informes y lo abre. Solo lee, no cambia nada."
    "Informe de batería (portátiles)" = "Ejecuta 'powercfg /batteryreport', el informe oficial de Windows: capacidad original frente a la actual (desgaste), ciclos de carga e historial de uso. Se guarda como .html y se abre en el navegador."
    "Abrir carpeta de informes" = "Abre en el Explorador la carpeta donde se guardan los informes generados."
    "Liberar RAM ahora" = "1. Recorta la memoria de trabajo de todos los procesos (los programas devuelven a Windows la RAM reservada que no usan).`n2. Escribe a disco la lista de memoria modificada.`n3. Vacía la caché en espera (archivos que Windows guardó en RAM por si los volvías a abrir).`n4. Muestra la RAM libre antes y después.`nNo cierra ningún programa. Es temporal: la memoria se vuelve a ocupar al usar los programas."
    "Programas abiertos que más RAM usan" = "Muestra los programas de tu sesión que ocupan más de 50 MB, sumando todos sus procesos (por ejemplo, todas las pestañas de Chrome).`nAl pulsar 'Cerrar' se pide primero que se cierren normalmente (como pulsar la X) y, si no responden en un segundo, se fuerzan. Los procesos del sistema y el antivirus no aparecen."
    "Programas que arrancan con Windows" = "'Abrir' lleva a Configuración > Aplicaciones > Inicio, donde activas o desactivas cada programa con un interruptor (es reversible).`n'Ver lista' escribe en el registro de abajo los programas y su comando, sin cambiar nada."
    "Memoria virtual en automático" = "Si el archivo de paginación (pagefile.sys) está en manual o desactivado, lo pone 'administrado por el sistema' (Win32_ComputerSystem.AutomaticManagedPagefile = true). Si ya está en automático, no cambia nada. Se aplica al reiniciar."
    "Liberador de espacio de Windows" = "Abre cleanmgr.exe para la unidad C:. Tú marcas qué borrar (papelera, miniaturas, archivos de programa descargados...). Con 'Limpiar archivos del sistema' también ofrece restos de actualizaciones."
    "Ver qué ocupa espacio" = "Abre Configuración > Sistema > Almacenamiento: muestra cuánto ocupan apps, archivos temporales, documentos, etc., y deja activar el Sensor de almacenamiento para que Windows limpie solo."
    "Crear acceso directo en el Escritorio" = "1. Copia el optimizador a %LOCALAPPDATA%\OptimizadorES.`n2. Crea un acceso directo con su icono en el Escritorio y en el menú Inicio, que lo abre (al abrirse pide permisos de administrador).`nNo cambia nada de Windows."
    "Predeterminado de Windows" = "Quita las directivas que limitan Windows Update y deja las actualizaciones como vienen de fábrica (mismo script que WinUtil)."
    "Recomendado: solo seguridad" = "Aplica las directivas de WinUtil: las actualizaciones de calidad se retrasan 4 días y las de características 365 días, y no se instalan controladores por Windows Update. Las de seguridad siguen llegando."
    "Desactivar actualizaciones" = "Desactiva los servicios y tareas de Windows Update y bloquea las actualizaciones automáticas (script de WinUtil). El equipo deja de recibir parches de seguridad hasta que elijas 'Predeterminado'."
}

function New-Tarjeta {
    param($Item, [bool]$Marcado)
    $color = $script:Colores[$Item.Riesgo]

    $borde = New-Object System.Windows.Controls.Border
    $borde.Background = Get-Pincel "#FFFFFF"
    $borde.BorderBrush = Get-Pincel "#E2E6EC"
    $borde.BorderThickness = 1
    $borde.CornerRadius = 8
    $borde.Padding = "14,10"
    $borde.Margin = "0,0,0,8"

    $pila = New-Object System.Windows.Controls.StackPanel

    $fila = New-Object System.Windows.Controls.DockPanel
    $etiqueta = New-Object System.Windows.Controls.Border
    $etiqueta.Background = Get-Pincel $color.Fondo
    $etiqueta.CornerRadius = 10
    $etiqueta.Padding = "8,1"
    $etiqueta.Margin = "8,0,0,0"
    $etiqueta.VerticalAlignment = "Center"
    $txtEtiqueta = New-Object System.Windows.Controls.TextBlock
    $txtEtiqueta.Text = $color.Etiqueta
    $txtEtiqueta.Foreground = Get-Pincel $color.Texto
    $txtEtiqueta.FontSize = 11
    $txtEtiqueta.FontWeight = "SemiBold"
    $etiqueta.Child = $txtEtiqueta
    [System.Windows.Controls.DockPanel]::SetDock($etiqueta, "Right")
    [void]$fila.Children.Add($etiqueta)

    $casilla = New-Object System.Windows.Controls.CheckBox
    $casilla.Content = $Item.Nombre
    $casilla.FontWeight = "SemiBold"
    $casilla.VerticalContentAlignment = "Center"
    $casilla.IsChecked = $Marcado
    $casilla.Tag = $Item
    [void]$fila.Children.Add($casilla)
    [void]$pila.Children.Add($fila)

    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text = $Item.Descripcion
    $desc.TextWrapping = "Wrap"
    $desc.Foreground = Get-Pincel "#4B5563"
    $desc.Margin = "20,2,0,0"
    [void]$pila.Children.Add($desc)

    if ($Item.Aviso) {
        $aviso = New-Object System.Windows.Controls.TextBlock
        $aviso.Text = "$([char]0x26A0) $($Item.Aviso)"
        $aviso.TextWrapping = "Wrap"
        $aviso.Foreground = Get-Pincel $color.Texto
        $aviso.Margin = "20,3,0,0"
        [void]$pila.Children.Add($aviso)
    }

    Add-Detalles $pila $Item

    $estadoTxt = New-Object System.Windows.Controls.TextBlock
    $estadoTxt.FontWeight = "SemiBold"
    $estadoTxt.Margin = "20,4,0,0"
    $estadoTxt.Visibility = "Collapsed"
    [void]$pila.Children.Add($estadoTxt)
    $barraT = New-Object System.Windows.Controls.ProgressBar
    $barraT.Height = 5
    $barraT.Minimum = 0
    $barraT.Maximum = 100
    $barraT.Margin = "20,3,0,2"
    $barraT.Visibility = "Collapsed"
    [void]$pila.Children.Add($barraT)
    $borde.Child = $pila
    return @{ Borde = $borde; Casilla = $casilla; Estado = $estadoTxt; Barra = $barraT }
}

function New-Titulo {
    param([string]$Texto, [string]$Subtitulo)
    $p = New-Object System.Windows.Controls.StackPanel
    $p.Margin = "0,8,0,8"
    $p.Uid = "Titulo"
    $p.Tag = $Texto
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Texto
    $t.FontSize = 17
    $t.FontWeight = "SemiBold"
    $t.Foreground = Get-Pincel "#111827"
    [void]$p.Children.Add($t)
    if ($Subtitulo) {
        $s = New-Object System.Windows.Controls.TextBlock
        $s.Text = $Subtitulo
        $s.TextWrapping = "Wrap"
        $s.Foreground = Get-Pincel "#6B7280"
        [void]$p.Children.Add($s)
    }
    return $p
}

# Pestaña Ajustes
$script:CasillasAjustes = @()
$grupos = @(
    @{ Nombre = "Esenciales"; Titulo = "Ajustes esenciales"; Sub = "Seguros para la mayoría de los equipos. Lee igualmente los avisos de riesgo medio." },
    @{ Nombre = "Avanzados";  Titulo = "$([char]0x26A0) Ajustes avanzados (úsalos con precaución)"; Sub = "Pueden romper funciones, programas o la seguridad del equipo. Márcalos solo si entiendes el aviso." }
)
foreach ($g in $grupos) {
    [void]$ui.PanelAjustes.Children.Add((New-Titulo $g.Titulo $g.Sub))
    foreach ($item in ($script:Ajustes | Where-Object { $_.Grupo -eq $g.Nombre })) {
        $marcado = ($item.Key -eq "WPFTweaksRestorePoint")
        $t = New-Tarjeta -Item $item -Marcado $marcado
        [void]$ui.PanelAjustes.Children.Add($t.Borde)
        $script:CasillasAjustes += $t.Casilla
        $script:InfoAjuste[$item.Key] = $t
    }
}

# Pestaña Preferencias
$script:CasillasPref = @()
function Update-Preferencias {
    foreach ($c in $script:CasillasPref) {
        $activo = $false
        try { $activo = Get-EstadoToggle -Item $c.Tag } catch { }
        $c.IsChecked = $activo
        $c.Uid = [string]$activo   # estado inicial, para saber qué cambió
    }
}
foreach ($item in ($script:Ajustes | Where-Object { $_.Grupo -eq "Preferencias" })) {
    $t = New-Tarjeta -Item $item -Marcado $false
    [void]$ui.PanelPreferencias.Children.Add($t.Borde)
    $script:CasillasPref += $t.Casilla
}
Update-Preferencias

# Pestaña Ayuda
$textosAyuda = @(
    @("Qué significa cada nivel de riesgo", ""),
    @("Riesgo bajo", "Cambios de privacidad, limpieza o apariencia. Fáciles de deshacer y no rompen nada importante."),
    @("Riesgo medio", "Pueden desactivar alguna función que quizá uses (ubicación, notificaciones, búsqueda rápida, Xbox, compartir Internet...). Lee el aviso."),
    @("Riesgo ALTO", "Desinstalan componentes, quitan protección (cifrado, avisos de seguridad) o pueden romper la red o programas. Algunos no se pueden deshacer del todo."),
    @("Cómo volver atrás", "1) Marca el ajuste y pulsa 'Deshacer seleccionados'. 2) Si algo va mal, usa 'Abrir Restaurar sistema' y elige el punto 'OptimizadorES'. Las desinstalaciones (Edge, OneDrive, IA) no se revierten con 'Deshacer': hay que reinstalar."),
    @("Registro", "Todo lo que hace la herramienta se guarda en: " + $global:ArchivoLog + ". La lista de cambios con su botón de deshacer está en la pestaña Historial de cambios."),
    @("Abrir siempre la última versión", "En PowerShell escribe: irm https://raw.githubusercontent.com/edainhg/Optimizador/main/instalar.ps1 | iex  (descarga el optimizador de GitHub y lo abre como administrador)."),
    @("Créditos", "Ajustes técnicos basados en WinUtil de Chris Titus Tech (github.com/ChrisTitusTech/winutil), licencia MIT. Traducción, niveles de riesgo e interfaz: OptimizadorES. Se usa bajo tu responsabilidad, sin garantía.")
)
foreach ($par in $textosAyuda) {
    if (-not $par[1]) { [void]$ui.PanelAyuda.Children.Add((New-Titulo $par[0] "")); continue }
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.TextWrapping = "Wrap"
    $tb.Margin = "0,0,0,10"
    $negrita = New-Object System.Windows.Documents.Run ($par[0] + ": ")
    $negrita.FontWeight = "SemiBold"
    switch ($par[0]) {
        "Riesgo bajo"  { $negrita.Foreground = Get-Pincel $script:Colores.Bajo.Texto }
        "Riesgo medio" { $negrita.Foreground = Get-Pincel $script:Colores.Medio.Texto }
        "Riesgo ALTO"  { $negrita.Foreground = Get-Pincel $script:Colores.Alto.Texto }
    }
    [void]$tb.Inlines.Add($negrita)
    [void]$tb.Inlines.Add((New-Object System.Windows.Documents.Run $par[1]))
    [void]$ui.PanelAyuda.Children.Add($tb)
}

# ---------------------------------------------------------------- Pestaña Seguridad
$script:BotonesSeguridad = @()

function Get-InfoAntivirus {
    $productos = @()
    try { $productos = @(Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction Stop) } catch { }
    foreach ($p in $productos) {
        $hex = "{0:X6}" -f [int]$p.productState
        [pscustomobject]@{
            Nombre = $p.displayName
            Activo = @("10", "11") -contains $hex.Substring(2, 2)
            AlDia  = ($hex.Substring(4, 2) -eq "00")
        }
    }
}

function Get-ModoDefender {
    try { return [string](Get-MpComputerStatus -ErrorAction Stop).AMRunningMode } catch { return "No disponible" }
}

$script:codigoDefender = @'
param($Tipo)
Write-Output "Actualizando las firmas de Defender..."
try { Update-MpSignature -ErrorAction Stop } catch { Write-Warning "No se pudieron actualizar las firmas: $($_.Exception.Message)" }
Write-Output "Analizando ($Tipo). No cierres la ventana; puede tardar bastante..."
$inicio = Get-Date
Start-MpScan -ScanType $Tipo -ErrorAction Stop
$nuevas = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -ge $inicio })
if ($nuevas.Count -eq 0) {
    Write-Output "Análisis terminado: no se encontraron amenazas."
} else {
    foreach ($d in $nuevas) {
        $nombre = (Get-MpThreat -ThreatID $d.ThreatID -ErrorAction SilentlyContinue).ThreatName
        Write-Warning "Amenaza encontrada: $nombre en $(@($d.Resources) -join ', ')"
    }
    Write-Warning "Revisa y elimina las amenazas en Seguridad de Windows > Protección contra virus y amenazas > Historial de protección."
}
'@

$script:codigoSafetyScanner = @'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"
$url = if ([Environment]::Is64BitOperatingSystem) { "https://go.microsoft.com/fwlink/?LinkId=212732" } else { "https://go.microsoft.com/fwlink/?LinkId=212733" }
$destino = Join-Path $env:LOCALAPPDATA "OptimizadorES\msert.exe"
Write-Output "Descargando Microsoft Safety Scanner desde Microsoft (unos 200 MB, puede tardar)..."
Invoke-WebRequest -Uri $url -OutFile $destino -UseBasicParsing -ErrorAction Stop
$firma = Get-AuthenticodeSignature -FilePath $destino
if ($firma.Status -ne "Valid" -or $firma.SignerCertificate.Subject -notmatch "O=Microsoft Corporation") {
    Remove-Item -Path $destino -Force -ErrorAction SilentlyContinue
    throw "El archivo descargado no tiene una firma válida de Microsoft; se borró por seguridad."
}
Write-Output "Descarga verificada (firmada por Microsoft). Se abre el asistente: elige 'Análisis rápido' o 'Análisis completo'."
Start-Process -FilePath $destino
Write-Output "Cuando termine, el informe queda en C:\Windows\debug\msert.log"
'@

$script:codigoReparar = @'
Write-Output "Paso 1 de 2: DISM revisa la imagen de Windows (10 a 30 minutos)..."
$dism = & dism.exe /Online /Cleanup-Image /RestoreHealth
$codigo = $LASTEXITCODE
@($dism) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $_ -notmatch "%" } | Select-Object -Last 3 | ForEach-Object { Write-Output $_ }
if ($codigo -ne 0) { Write-Warning "DISM terminó con el código $codigo." }
Write-Output "Paso 2 de 2: SFC revisa los archivos del sistema (10 a 20 minutos)..."
$sfc = (@(& sfc.exe /scannow) -join "`n") -replace "`0", ""
($sfc -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch "%" } | Select-Object -Last 3 | ForEach-Object { Write-Output $_ }
Write-Output "Detalle completo en C:\Windows\Logs\CBS\CBS.log. Reinicia el equipo al terminar."
'@

$script:codigoArranque = @'
$lista = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue | Sort-Object Name)
Write-Output "Programas que arrancan con Windows: $($lista.Count)"
foreach ($p in $lista) { Write-Output (" - {0}   ({1})" -f $p.Name, $p.Command) }
Write-Output "Si ves algo que no reconoces, búscalo en Internet antes de borrarlo. Para desactivar uno: Administrador de tareas > Aplicaciones de arranque."
'@

function New-TarjetaAccion {
    param([string]$Titulo, [string]$Descripcion, [string]$Riesgo, [string]$Aviso, [string]$TextoBoton, [scriptblock]$Accion, [bool]$Permitido = $true, [string]$Motivo = "", $Panel = $null, [string]$Clave = "", [string]$TextoBoton2 = "", [scriptblock]$Accion2 = $null, [string]$Detalle = "", $Origen = $null)
    if (-not $Detalle) { $Detalle = $script:DetallesAcciones[$Titulo] }
    $item = [pscustomobject]@{ Nombre = $Titulo; Descripcion = $Descripcion; Riesgo = $Riesgo; Aviso = $Aviso; Detalle = $Detalle
        registry = @($Origen.registry); service = @($Origen.service); InvokeScript = @($Origen.InvokeScript) }
    $t = New-Tarjeta -Item $item -Marcado $false
    # La tarjeta usa una casilla; aquí se cambia por un botón
    $fila = $t.Casilla.Parent
    $fila.Children.Remove($t.Casilla)
    # Ojo: PowerShell no distingue mayúsculas; $titulo pisaría el parámetro $Titulo
    $txtTitulo = New-Object System.Windows.Controls.TextBlock
    $txtTitulo.Text = $Titulo
    $txtTitulo.FontWeight = "SemiBold"
    $txtTitulo.VerticalAlignment = "Center"
    $boton = New-Object System.Windows.Controls.Button
    $boton.Content = $TextoBoton
    $boton.Padding = "12,4"
    $boton.Margin = "8,0,0,0"
    $boton.Tag = $Permitido
    $boton.IsEnabled = $Permitido
    $boton.Add_Click($Accion)
    [System.Windows.Controls.DockPanel]::SetDock($boton, "Right")
    $fila.Children.Insert(0, $boton)
    if ($TextoBoton2 -and $Accion2) {
        $boton2 = New-Object System.Windows.Controls.Button
        $boton2.Content = $TextoBoton2
        $boton2.Padding = "12,4"
        $boton2.Margin = "8,0,0,0"
        $boton2.Tag = $Permitido
        $boton2.IsEnabled = $Permitido
        $boton2.Add_Click($Accion2)
        [System.Windows.Controls.DockPanel]::SetDock($boton2, "Right")
        $fila.Children.Insert(1, $boton2)
        $script:BotonesSeguridad += $boton2
    }
    [void]$fila.Children.Add($txtTitulo)
    if (-not $Permitido -and $Motivo) {
        $nota = New-Object System.Windows.Controls.TextBlock
        $nota.Text = $Motivo
        $nota.TextWrapping = "Wrap"
        $nota.FontStyle = "Italic"
        $nota.Foreground = Get-Pincel "#6B7280"
        $nota.Margin = "20,3,0,0"
        [void]$t.Borde.Child.Children.Add($nota)
    }
    $script:BotonesSeguridad += $boton
    if (-not $Panel) { $Panel = $script:UI.PanelSeguridad }
    [void]$Panel.Children.Add($t.Borde)
    if ($Clave) {
        # Permite mostrar estado y progreso en la tarjeta (como en las apps)
        $script:TarjetaPorId[$Clave] = [pscustomobject]@{ Borde = $t.Borde; Estado = $t.Estado; Barra = $t.Barra; Firma = ""; Boton = $boton }
    }
}

function New-PasoScript {
    param([string]$Nombre, [string]$Codigo)
    return [pscustomobject]@{ Item = [pscustomobject]@{ Key = "SEG"; Nombre = $Nombre; InvokeScript = @($Codigo) }; Deshacer = $false }
}

# Estado del antivirus
$script:Antivirus = @(Get-InfoAntivirus)
$script:ModoDefender = Get-ModoDefender
$defenderActivo = ($script:ModoDefender -eq "Normal")
$otrosActivos = @($script:Antivirus | Where-Object { $_.Activo -and $_.Nombre -notmatch "Defender" })

$resumen = New-Object System.Windows.Controls.TextBlock
$resumen.TextWrapping = "Wrap"
$resumen.Margin = "0,0,0,10"
if ($script:Antivirus.Count -eq 0) {
    $resumen.Text = "No se pudo detectar qué antivirus tienes."
} else {
    $partes = foreach ($a in $script:Antivirus) {
        # Ojo: no llamar a esta variable $estado; pisaría $global:Estado (sin él no hay registro ni avisos)
        $estadoAv = if ($a.Activo) { "activo" } else { "desactivado" }
        $firmas = if ($a.AlDia) { "firmas al día" } else { "firmas DESACTUALIZADAS" }
        "$($a.Nombre) ($estadoAv, $firmas)"
    }
    $resumen.Text = "Antivirus detectado: " + ($partes -join "; ") + ". Microsoft Defender está en modo: $($script:ModoDefender)."
}
[void]$script:UI.PanelSeguridad.Children.Add((New-Titulo "Buscar virus y revisar el sistema" "Ninguna de estas acciones cambia ajustes de Windows. Los análisis largos pueden tardar más de una hora."))
[void]$script:UI.PanelSeguridad.Children.Add($resumen)

$motivoDefender = "Defender no es tu antivirus principal (modo: $($script:ModoDefender)). Usa 'Abrir mi antivirus' o la segunda opinión."
if (-not $defenderActivo -and $otrosActivos.Count -eq 0) {
    $motivoDefender = "Este equipo NO tiene ningún antivirus activo. Pulsa 'Abrir mi antivirus' y activa la protección en tiempo real de Seguridad de Windows; luego vuelve a abrir el optimizador."
    $resumen.Text += " $([char]0x26A0) ATENCIÓN: no hay ningún antivirus activo en este equipo."
    $resumen.Foreground = Get-Pincel $script:Colores.Alto.Texto
    $resumen.FontWeight = "SemiBold"
}
if ($otrosActivos.Count) {
    $motivoDefender = "Defender está desactivado porque usas $($otrosActivos[0].Nombre). Usa 'Abrir mi antivirus' o la segunda opinión."
}

New-TarjetaAccion -Titulo "Abrir mi antivirus" -TextoBoton "Abrir" -Riesgo "Bajo" `
    -Descripcion "Abre tu antivirus para lanzar un análisis completo desde él (por ejemplo, en ESET: Análisis del ordenador > Analizar el ordenador)." `
    -Aviso "" -Accion {
        $exe = $null
        if (@($script:Antivirus | Where-Object { $_.Activo -and $_.Nombre -match "ESET" }).Count) {
            $exe = Get-ChildItem -Path "$env:ProgramFiles\ESET" -Filter "egui.exe" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        }
        if ($exe) { Start-Process -FilePath $exe } else { Start-Process "windowsdefender:" }
    }

New-TarjetaAccion -Titulo "Análisis rápido con Microsoft Defender" -TextoBoton "Analizar" -Riesgo "Bajo" `
    -Descripcion "Actualiza las firmas y revisa las zonas donde suele esconderse el malware. Unos 5-15 minutos." `
    -Aviso "" -Permitido $defenderActivo -Motivo $motivoDefender -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Análisis rápido con Defender" -Codigo ('$Tipo = "QuickScan"' + "`n" + $script:codigoDefender.Substring($script:codigoDefender.IndexOf("`n") + 1)))
    }

New-TarjetaAccion -Titulo "Análisis completo con Microsoft Defender" -TextoBoton "Analizar" -Riesgo "Bajo" `
    -Descripcion "Revisa todos los archivos del disco." `
    -Aviso "Puede tardar 1 hora o más y hace el equipo más lento mientras dura." -Permitido $defenderActivo -Motivo $motivoDefender -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Análisis completo con Defender" -Codigo ('$Tipo = "FullScan"' + "`n" + $script:codigoDefender.Substring($script:codigoDefender.IndexOf("`n") + 1)))
    }

New-TarjetaAccion -Titulo "Segunda opinión: Microsoft Safety Scanner" -TextoBoton "Descargar y abrir" -Riesgo "Bajo" `
    -Descripcion "Descarga el escáner gratuito de Microsoft, comprueba su firma y lo abre. Funciona junto a ESET u otro antivirus sin conflictos." `
    -Aviso "Descarga unos 200 MB. La copia caduca a los 10 días, por eso se descarga de nuevo cada vez. Si elige eliminar algo, revisa la lista antes de aceptar." -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Microsoft Safety Scanner" -Codigo $script:codigoSafetyScanner)
    }

New-TarjetaAccion -Titulo "Reparar archivos de Windows (DISM + SFC)" -TextoBoton "Reparar" -Riesgo "Bajo" `
    -Descripcion "Comprueba y repara archivos dañados del sistema. Útil si Windows da errores raros o tras quitar un virus." `
    -Aviso "Tarda entre 20 y 50 minutos y necesita Internet para DISM. No apagues el equipo mientras dura." -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Reparar archivos de Windows" -Codigo $script:codigoReparar)
    }

New-TarjetaAccion -Titulo "Ver programas que arrancan con Windows" -TextoBoton "Ver lista" -Riesgo "Bajo" `
    -Descripcion "Muestra en el registro de abajo qué programas se inician solos. Es donde suele colarse el software no deseado." `
    -Aviso "" -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Programas de arranque" -Codigo $script:codigoArranque)
    }

# ---------------------------------------------------------------- Pestaña Apps
$AppsB64 = '__APPS_B64__'
$script:Apps = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($AppsB64)) | ConvertFrom-Json
$script:TarjetasApps = @()
$script:SeccionesApps = @()
$script:AppsComprobadas = $false

function Update-EstadosApps {
    $colores = @{ ok = "#1E7B3A"; update = "#2563EB"; error = "#B42318"; trabajo = "#A85F00"; info = "#6B7280" }
    foreach ($id in @($global:Estado.Apps.Keys)) {
        $t = $script:TarjetaPorId[$id]
        if (-not $t) { continue }
        $e = $global:Estado.Apps[$id]
        $firma = "$($e.Texto)|$($e.Tipo)|$($e.Progreso)"
        if ($firma -eq $t.Firma) { continue }
        $t.Firma = $firma
        $t.Estado.Text = $e.Texto
        $t.Estado.Visibility = if ($e.Texto) { "Visible" } else { "Collapsed" }
        $t.Estado.Foreground = Get-Pincel $colores[[string]$e.Tipo]
        if ($e.Tipo -eq "trabajo") {
            $t.Barra.Visibility = "Visible"
            if ($e.Progreso -ge 0) { $t.Barra.IsIndeterminate = $false; $t.Barra.Value = $e.Progreso } else { $t.Barra.IsIndeterminate = $true }
            $t.Borde.BorderBrush = Get-Pincel "#F59E0B"
        } else {
            $t.Barra.Visibility = "Collapsed"
            $t.Barra.IsIndeterminate = $false
            $t.Borde.BorderBrush = Get-Pincel $(if ($e.Tipo -eq "ok") { "#86EFAC" } elseif ($e.Tipo -eq "update") { "#93C5FD" } elseif ($e.Tipo -eq "error") { "#FCA5A5" } else { "#E5E7EB" })
        }
    }
}

function Start-ComprobarApps {
    if ($script:Trabajo -or -not $script:WingetOk) { return }
    $script:AppsComprobadas = $true
    $lista = ($script:Apps | ForEach-Object { "'" + $_.Id + "'" }) -join ","
    Start-Pasos -Pasos @(New-PasoScript -Nombre "Comprobar apps instaladas" -Codigo "Get-EstadoApps -Ids @($lista)") -Silencioso
}

$script:WingetOk = [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
if ($script:WingetOk) {
    $script:UI.TxtWinget.Text = "Las apps se descargan de su fuente oficial con winget, el instalador de Microsoft. Se instalan en silencio, una tras otra. Si una app ya está instalada, se indica y se pasa a la siguiente."
} else {
    $script:UI.TxtWinget.Text = "$([char]0x26A0) winget no está instalado en este equipo. Ve a la pestaña Reparaciones y pulsa 'Reparar winget' antes de instalar apps."
    $script:UI.TxtWinget.Foreground = Get-Pincel $script:Colores.Alto.Texto
}

foreach ($cat in ($script:Apps | Select-Object -ExpandProperty Categoria -Unique)) {
    $seccion = New-Object System.Windows.Controls.StackPanel
    $tit = New-Titulo $cat ""
    [void]$seccion.Children.Add($tit)
    $rejilla = New-Object System.Windows.Controls.WrapPanel
    foreach ($app in ($script:Apps | Where-Object { $_.Categoria -eq $cat })) {
        $borde = New-Object System.Windows.Controls.Border
        $borde.Width = 300
        $borde.Background = Get-Pincel "#FFFFFF"
        $borde.BorderBrush = Get-Pincel "#E5E7EB"
        $borde.BorderThickness = 1
        $borde.CornerRadius = 6
        $borde.Padding = "10,6"
        $borde.Margin = "0,0,6,6"
        $pila = New-Object System.Windows.Controls.StackPanel
        $filaApp = New-Object System.Windows.Controls.DockPanel
        $icono = New-ImagenB64 $app.Icono
        if ($icono) {
            $imagen = New-Object System.Windows.Controls.Image
            $imagen.Source = $icono
            $imagen.Width = 24
            $imagen.Height = 24
            $imagen.Margin = "0,0,8,0"
            [System.Windows.Controls.DockPanel]::SetDock($imagen, "Left")
            [void]$filaApp.Children.Add($imagen)
        } else {
            # Sin icono: círculo con la inicial
            $circulo = New-Object System.Windows.Controls.Border
            $circulo.Width = 24
            $circulo.Height = 24
            $circulo.CornerRadius = 12
            $circulo.Background = Get-Pincel "#DBEAFE"
            $circulo.Margin = "0,0,8,0"
            $inicial = New-Object System.Windows.Controls.TextBlock
            $inicial.Text = $app.Nombre.Substring(0, 1)
            $inicial.FontWeight = "Bold"
            $inicial.Foreground = Get-Pincel "#1D4ED8"
            $inicial.HorizontalAlignment = "Center"
            $inicial.VerticalAlignment = "Center"
            $circulo.Child = $inicial
            [System.Windows.Controls.DockPanel]::SetDock($circulo, "Left")
            [void]$filaApp.Children.Add($circulo)
        }
        $casilla = New-Object System.Windows.Controls.CheckBox
        $casilla.Content = $app.Nombre
        $casilla.FontWeight = "SemiBold"
        $casilla.VerticalAlignment = "Center"
        $casilla.Tag = $app
        [void]$filaApp.Children.Add($casilla)
        [void]$pila.Children.Add($filaApp)
        $d = New-Object System.Windows.Controls.TextBlock
        $d.Text = $app.Descripcion
        $d.TextWrapping = "Wrap"
        $d.FontSize = 12
        $d.Foreground = Get-Pincel "#4B5563"
        $d.Margin = "32,1,0,0"
        [void]$pila.Children.Add($d)
        if ($app.Aviso) {
            $a = New-Object System.Windows.Controls.TextBlock
            $a.Text = "$([char]0x26A0) $($app.Aviso)"
            $a.TextWrapping = "Wrap"
            $a.FontSize = 12
            $a.Foreground = Get-Pincel $script:Colores.Medio.Texto
            $a.Margin = "32,2,0,0"
            [void]$pila.Children.Add($a)
        }
        $estadoTxt = New-Object System.Windows.Controls.TextBlock
        $estadoTxt.FontSize = 12
        $estadoTxt.FontWeight = "SemiBold"
        $estadoTxt.Margin = "32,3,0,0"
        $estadoTxt.Visibility = "Collapsed"
        [void]$pila.Children.Add($estadoTxt)
        $barraApp = New-Object System.Windows.Controls.ProgressBar
        $barraApp.Height = 5
        $barraApp.Minimum = 0
        $barraApp.Maximum = 100
        $barraApp.Margin = "32,3,0,2"
        $barraApp.Visibility = "Collapsed"
        [void]$pila.Children.Add($barraApp)
        $borde.Child = $pila
        [void]$rejilla.Children.Add($borde)
        $tarjeta = [pscustomobject]@{ Borde = $borde; Casilla = $casilla; App = $app; Seccion = $seccion; Estado = $estadoTxt; Barra = $barraApp; Firma = "" }
        $script:TarjetasApps += $tarjeta
        $script:TarjetaPorId[$app.Id] = $tarjeta
    }
    [void]$seccion.Children.Add($rejilla)
    [void]$script:UI.PanelApps.Children.Add($seccion)
    $script:SeccionesApps += $seccion
}

$script:UI.TxtBuscarApp.Add_TextChanged({
    $texto = $script:UI.TxtBuscarApp.Text.Trim()
    foreach ($t in $script:TarjetasApps) {
        $coincide = (-not $texto) -or ($t.App.Nombre -like "*$texto*") -or ($t.App.Descripcion -like "*$texto*") -or ($t.App.Categoria -like "*$texto*")
        $t.Borde.Visibility = if ($coincide) { "Visible" } else { "Collapsed" }
    }
    foreach ($s in $script:SeccionesApps) {
        $visibles = @($script:TarjetasApps | Where-Object { $_.Seccion -eq $s -and $_.Borde.Visibility -eq "Visible" }).Count
        $s.Visibility = if ($visibles) { "Visible" } else { "Collapsed" }
    }
})

function Get-AppsMarcadas { return @($script:TarjetasApps | Where-Object { $_.Casilla.IsChecked } | ForEach-Object { $_.App }) }

function Start-AccionApps {
    param([string]$Accion, [string]$Verbo)
    if (-not $script:WingetOk) {
        [void][System.Windows.MessageBox]::Show("winget no está instalado. Ve a Reparaciones > 'Reparar winget'.", "Apps", "OK", "Warning")
        return
    }
    $sel = Get-AppsMarcadas
    if ($sel.Count -eq 0) {
        [void][System.Windows.MessageBox]::Show("Marca al menos una app.", "Apps", "OK", "Information")
        return
    }
    $msg = "Vas a $Verbo $($sel.Count) app(s):`r`n" + (($sel | ForEach-Object { " - $($_.Nombre)" }) -join "`r`n")
    $conAviso = @($sel | Where-Object { $_.Aviso })
    if ($conAviso.Count -and $Accion -eq "install") {
        $msg += "`r`n`r`nTen en cuenta:`r`n" + (($conAviso | ForEach-Object { " - $($_.Nombre): $($_.Aviso)" }) -join "`r`n")
    }
    if ($Accion -eq "uninstall") { $msg += "`r`n`r`nSe borrarán estas apps del equipo. Sus datos de usuario normalmente se conservan." }
    $msg += "`r`n`r`n¿Continuar?"
    $icono = if ($Accion -eq "uninstall" -or $conAviso.Count) { "Warning" } else { "Question" }
    if ([System.Windows.MessageBox]::Show($msg, "Apps", "YesNo", $icono) -ne "Yes") { return }
    foreach ($a in $sel) { $global:Estado.Apps[$a.Id] = @{ Texto = "En espera..."; Tipo = "trabajo"; Progreso = -1 } }
    $pasos = foreach ($a in $sel) {
        New-PasoScript -Nombre "$Verbo $($a.Nombre)" -Codigo ("Invoke-AppWinget -Accion '{0}' -Id '{1}' -Fuente '{2}'" -f $Accion, $a.Id, $a.Fuente)
    }
    Start-Pasos -Pasos @($pasos) -Titulo "$($Verbo.Substring(0,1).ToUpper())$($Verbo.Substring(1)) apps"
}

$script:UI.BtnAppsInstalar.Add_Click({ Start-AccionApps -Accion "install" -Verbo "instalar" })
$script:UI.BtnAppsActualizar.Add_Click({ Start-AccionApps -Accion "upgrade" -Verbo "actualizar" })
$script:UI.BtnAppsDesinstalar.Add_Click({ Start-AccionApps -Accion "uninstall" -Verbo "desinstalar" })
$script:UI.BtnAppsLimpiar.Add_Click({ foreach ($t in $script:TarjetasApps) { $t.Casilla.IsChecked = $false } })
$script:UI.BtnAppsComprobar.Add_Click({ Start-ComprobarApps })
$script:UI.BtnAppsPanel.Add_Click({ Start-Process "appwiz.cpl" })
$script:UI.BtnAppsActualizables.Add_Click({
    $n = 0
    foreach ($t in $script:TarjetasApps) {
        $e = $global:Estado.Apps[$t.App.Id]
        $t.Casilla.IsChecked = [bool]($e -and $e.Tipo -eq "update")
        if ($t.Casilla.IsChecked) { $n++ }
    }
    if ($n -eq 0) { [void][System.Windows.MessageBox]::Show("No hay apps de esta lista con actualización (pulsa antes 'Comprobar instaladas').", "Apps", "OK", "Information") }
})
$script:UI.BtnAppsTodo.Add_Click({
    if (-not $script:WingetOk) {
        [void][System.Windows.MessageBox]::Show("winget no está instalado. Ve a Reparaciones > 'Reparar winget'.", "Apps", "OK", "Warning")
        return
    }
    $msg = "Se actualizarán TODAS las apps del equipo que winget reconozca (no solo las de esta lista).`r`n`r`nCierra tus programas antes: algunos se cerrarán solos al actualizarse. Puede tardar bastante.`r`n`r`n¿Continuar?"
    if ([System.Windows.MessageBox]::Show($msg, "Actualizar todo", "YesNo", "Question") -ne "Yes") { return }
    Start-Pasos -Pasos @(New-PasoScript -Nombre "Actualizar todas las apps" -Codigo "Invoke-AppWinget -Accion 'upgradeall'")
})

# ---------------------------------------------------------------- Pestaña Reparaciones
$script:fixRed = @'
Write-Output "Limpiando la caché DNS..."
ipconfig /flushdns | Out-Null
Write-Output "Restableciendo Winsock..."
netsh winsock reset | Out-Null
Write-Output "Restableciendo TCP/IP (IPv4 e IPv6)..."
netsh int ip reset | Out-Null
netsh int ipv6 reset | Out-Null
Write-Output "Red restablecida. REINICIA el equipo para terminar."
'@

$script:fixDns = @'
ipconfig /flushdns | Out-Null
Clear-DnsClientCache -ErrorAction SilentlyContinue
Write-Output "Caché DNS limpiada."
'@

$script:fixUpdate = @'
$servicios = "wuauserv", "bits", "cryptsvc", "msiserver"
try {
    foreach ($s in $servicios) {
        Write-Output "Deteniendo el servicio $s..."
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
    }
    foreach ($c in @("$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2")) {
        if (Test-Path "$c.old") { Remove-Item -Path "$c.old" -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $c) {
            try {
                Rename-Item -Path $c -NewName ((Split-Path $c -Leaf) + ".old") -ErrorAction Stop
                Write-Output "Carpeta $c reiniciada."
            } catch {
                Write-Warning "No se pudo renombrar $c (está en uso). Reinicia el equipo y vuelve a intentarlo."
            }
        }
    }
} finally {
    foreach ($s in $servicios) { Start-Service -Name $s -ErrorAction SilentlyContinue }
}
Write-Output "Windows Update restablecido. Reinicia y vuelve a buscar actualizaciones."
'@

$script:fixImpresion = @'
Write-Output "Deteniendo la cola de impresión..."
Stop-Service -Name Spooler -Force -ErrorAction Stop
Remove-Item -Path "$env:SystemRoot\System32\spool\PRINTERS\*" -Force -Recurse -ErrorAction SilentlyContinue
Start-Service -Name Spooler -ErrorAction Stop
Write-Output "Cola de impresión vaciada y servicio reiniciado. Vuelve a imprimir."
'@

$script:fixTienda = @'
Start-Process -FilePath "wsreset.exe"
Write-Output "Se está limpiando la caché de la Tienda. Se abrirá sola al terminar (puede tardar un minuto)."
'@

$script:fixWinget = @'
Write-Output "Volviendo a registrar el Instalador de aplicaciones..."
try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { }
if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
    Write-Output "Restableciendo los orígenes de winget..."
    winget.exe source reset --force 2>&1 | Out-Null
    winget.exe source update 2>&1 | Out-Null
    Write-Output ("winget funciona. Versión: " + (winget.exe --version))
    Write-Output "Cierra y vuelve a abrir el optimizador para usar la pestaña Apps."
} else {
    Write-Warning "winget no está instalado. Se abre la Tienda en 'Instalador de aplicación': pulsa Obtener o Actualizar y luego vuelve a abrir el optimizador."
    Start-Process "ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1"
}
'@

$script:fixIconos = @'
Write-Output "Cerrando el Explorador..."
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Remove-Item -Path "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db" -Force -ErrorAction SilentlyContinue
if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
Write-Output "Caché de iconos y miniaturas borrada. Si algún icono sigue mal, reinicia el equipo."
'@

$script:fixHora = @'
Set-Service -Name w32time -StartupType Manual -ErrorAction SilentlyContinue
Start-Service -Name w32time -ErrorAction SilentlyContinue
w32tm /resync /force 2>&1 | ForEach-Object { $t = ([string]$_).Trim(); if ($t) { Write-Output $t } }
Write-Output ("Hora actual: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
'@

$pR = $script:UI.PanelReparaciones
[void]$pR.Children.Add((New-Titulo "Reparaciones rápidas" "Soluciones a los problemas más comunes. Cada una indica su riesgo y si necesita reiniciar."))

New-TarjetaAccion -Panel $pR -Titulo "Limpiar caché DNS" -TextoBoton "Limpiar" -Riesgo "Bajo" `
    -Descripcion "Útil cuando una página no carga o carga la versión vieja." -Aviso "" -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Limpiar caché DNS" -Codigo $script:fixDns)
    }

New-TarjetaAccion -Panel $pR -Titulo "Restablecer la red" -TextoBoton "Restablecer" -Riesgo "Medio" `
    -Descripcion "Limpia DNS y restablece Winsock y TCP/IP. Para cuando hay Wi-Fi o cable conectado pero no hay Internet." `
    -Aviso "Si el equipo tiene una IP fija puesta a mano, se borra y hay que volver a configurarla. Algunas VPN pueden necesitar reinstalarse. Requiere reiniciar." -Accion {
        if ([System.Windows.MessageBox]::Show("Si este equipo tiene IP fija configurada a mano, anótala antes: se borrará.`r`n`r`n¿Continuar?", "Restablecer red", "YesNo", "Warning") -eq "Yes") {
            Start-Pasos -Pasos @(New-PasoScript -Nombre "Restablecer la red" -Codigo $script:fixRed)
        }
    }

New-TarjetaAccion -Panel $pR -Titulo "Reparar Windows Update" -TextoBoton "Reparar" -Riesgo "Medio" `
    -Descripcion "Reinicia los servicios y la caché de Windows Update. Para cuando las actualizaciones fallan o se quedan atascadas." `
    -Aviso "Se borra el historial de actualizaciones que se ve en Configuración y vuelven a descargarse las pendientes. No lo uses mientras se instala una actualización." -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Reparar Windows Update" -Codigo $script:fixUpdate)
    }

New-TarjetaAccion -Panel $pR -Titulo "Desatascar la impresora" -TextoBoton "Limpiar cola" -Riesgo "Bajo" `
    -Descripcion "Vacía la cola de impresión y reinicia el servicio. Para cuando un documento se queda 'en cola' y nada imprime." `
    -Aviso "Se cancelan todos los trabajos pendientes de todas las impresoras." -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Desatascar la impresora" -Codigo $script:fixImpresion)
    }

New-TarjetaAccion -Panel $pR -Titulo "Reparar Microsoft Store" -TextoBoton "Reparar" -Riesgo "Bajo" `
    -Descripcion "Limpia la caché de la Tienda (WSReset). Para cuando no descarga o no abre." -Aviso "" -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Reparar Microsoft Store" -Codigo $script:fixTienda)
    }

New-TarjetaAccion -Panel $pR -Titulo "Reparar winget" -TextoBoton "Reparar" -Riesgo "Bajo" `
    -Descripcion "Vuelve a registrar winget y sus orígenes, o abre la Tienda para instalarlo. Necesario para la pestaña Apps." -Aviso "" -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Reparar winget" -Codigo $script:fixWinget)
    }

New-TarjetaAccion -Panel $pR -Titulo "Reconstruir iconos y miniaturas" -TextoBoton "Reconstruir" -Riesgo "Bajo" `
    -Descripcion "Para iconos en blanco, equivocados o miniaturas que no se ven." `
    -Aviso "La barra de tareas y el escritorio desaparecen unos segundos." -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Reconstruir iconos" -Codigo $script:fixIconos)
    }

New-TarjetaAccion -Panel $pR -Titulo "Sincronizar la hora" -TextoBoton "Sincronizar" -Riesgo "Bajo" `
    -Descripcion "Ajusta el reloj con el servidor de hora de Internet. Una hora mal puesta rompe páginas seguras y licencias." -Aviso "" -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Sincronizar la hora" -Codigo $script:fixHora)
    }

# ---------------------------------------------------------------- Pestaña Informe
$script:CarpetaInformes = Join-Path $env:LOCALAPPDATA "OptimizadorES\Informes"

$script:codigoInforme = @'
$ErrorActionPreference = "SilentlyContinue"
Write-Output "Recopilando información del equipo (20 a 60 segundos)..."
$r = New-Object System.Collections.Generic.List[string]
function Sec($t) { $r.Add(""); $r.Add("=== $t ===") }
function L($k, $v) { $r.Add(("{0,-30} {1}" -f ($k + ":"), $v)) }

$cs   = Get-CimInstance Win32_ComputerSystem
$os   = Get-CimInstance Win32_OperatingSystem
$bios = Get-CimInstance Win32_BIOS
$cpu  = @(Get-CimInstance Win32_Processor)[0]
$cv   = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

$r.Add("INFORME DEL EQUIPO - OptimizadorES")
L "Fecha del informe" (Get-Date -Format "yyyy-MM-dd HH:mm")

Sec "Equipo"
L "Nombre del equipo" $env:COMPUTERNAME
L "Usuario" $env:USERNAME
L "Fabricante y modelo" "$($cs.Manufacturer) $($cs.Model)"
L "Número de serie" $bios.SerialNumber
L "BIOS" "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"

Sec "Windows"
L "Sistema" "$($os.Caption) $($cv.DisplayVersion) (compilación $($cv.CurrentBuild).$($cv.UBR))"
L "Instalado el" $os.InstallDate
$enc = (Get-Date) - $os.LastBootUpTime
L "Encendido desde" ("{0} (hace {1} días y {2} h)" -f $os.LastBootUpTime, $enc.Days, $enc.Hours)
$lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" | Select-Object -First 1
$estadosLic = @{ 0 = "Sin licencia"; 1 = "Activado"; 2 = "Periodo de gracia"; 3 = "Gracia adicional"; 4 = "Gracia no genuina"; 5 = "NO activado (notificación)"; 6 = "Gracia extendida" }
L "Activación de Windows" $(if ($lic) { $estadosLic[[int]$lic.LicenseStatus] } else { "No se pudo leer" })
$hf = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
L "Última actualización" $(if ($hf) { "$($hf.HotFixID) el $($hf.InstalledOn.ToString('yyyy-MM-dd'))" } else { "Desconocida" })

Sec "Procesador, memoria y gráficos"
L "Procesador" "$($cpu.Name.Trim()) ($($cpu.NumberOfCores) núcleos / $($cpu.NumberOfLogicalProcessors) hilos)"
$usoRam = [math]::Round(100 - 100 * $os.FreePhysicalMemory / $os.TotalVisibleMemorySize)
L "RAM" ("{0} GB en total, {1} GB libres ({2}% en uso)" -f [math]::Round($os.TotalVisibleMemorySize / 1MB, 1), [math]::Round($os.FreePhysicalMemory / 1MB, 1), $usoRam)
foreach ($m in Get-CimInstance Win32_PhysicalMemory) {
    L "  Módulo $($m.DeviceLocator)" ("{0} GB a {1} MHz ({2})" -f ($m.Capacity / 1GB), $m.ConfiguredClockSpeed, $m.Manufacturer)
}
foreach ($g in Get-CimInstance Win32_VideoController) { L "Tarjeta gráfica" "$($g.Name) (driver $($g.DriverVersion))" }

Sec "Discos"
foreach ($d in Get-PhysicalDisk) {
    $rel = $d | Get-StorageReliabilityCounter
    $extra = @()
    if ($rel.Temperature) { $extra += "$($rel.Temperature) °C" }
    if ($null -ne $rel.Wear) { $extra += "desgaste $($rel.Wear)%" }
    $salud = switch ([string]$d.HealthStatus) { "Healthy" { "buena" } "Warning" { "ADVERTENCIA" } "Unhealthy" { "MALA - haz copia de seguridad ya" } default { [string]$d.HealthStatus } }
    L $d.FriendlyName ("{0}, {1} GB, salud {2} {3}" -f $d.MediaType, [math]::Round($d.Size / 1GB), $salud, ($extra -join ", "))
}
foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 } | Sort-Object DriveLetter)) {
    $pct = [math]::Round(100 * $v.SizeRemaining / $v.Size)
    $alerta = if ($pct -lt 10) { "  <-- POCO ESPACIO" } else { "" }
    L "  Unidad $($v.DriveLetter):" ("{0} GB libres de {1} GB ({2}%){3}" -f [math]::Round($v.SizeRemaining / 1GB, 1), [math]::Round($v.Size / 1GB, 1), $pct, $alerta)
}

Sec "Batería"
$bat = Get-CimInstance Win32_Battery | Select-Object -First 1
if ($bat) {
    $diseno = (Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData | Select-Object -First 1).DesignedCapacity
    $llena  = (Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity | Select-Object -First 1).FullChargedCapacity
    L "Carga actual" "$($bat.EstimatedChargeRemaining)%"
    if ($diseno -and $llena) {
        $saludBat = [math]::Round(100 * $llena / $diseno)
        $nota = if ($saludBat -lt 60) { "  <-- conviene cambiarla" } else { "" }
        L "Salud de la batería" ("{0}% de su capacidad original ({1} de {2} mWh){3}" -f $saludBat, $llena, $diseno, $nota)
    }
} else {
    L "Batería" "No tiene (equipo de escritorio)"
}

Sec "Red"
foreach ($a in (Get-NetAdapter | Where-Object { $_.Status -eq "Up" })) {
    $ip  = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 | Select-Object -First 1).IPAddress
    $dns = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses -join ", "
    L $a.Name "$($a.InterfaceDescription), $($a.LinkSpeed), IP $ip, DNS $dns"
}

Sec "Seguridad"
foreach ($p in Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct) {
    $hex = "{0:X6}" -f [int]$p.productState
    $act = if (@("10", "11") -contains $hex.Substring(2, 2)) { "activo" } else { "desactivado" }
    $fir = if ($hex.Substring(4, 2) -eq "00") { "firmas al día" } else { "firmas DESACTUALIZADAS" }
    L "Antivirus" "$($p.displayName) ($act, $fir)"
}
$bl = Get-BitLockerVolume -MountPoint $env:SystemDrive
if ($bl) { L "BitLocker en $($env:SystemDrive)" $(if ([string]$bl.ProtectionStatus -eq "On") { "activado" } else { "desactivado" }) }

Sec "Dispositivos con problemas"
$malos = @(Get-PnpDevice -PresentOnly -Status ERROR, DEGRADED)
if ($malos.Count) {
    foreach ($m in $malos) { L "  $($m.Class)" "$($m.FriendlyName) ($($m.Status))" }
} else {
    $r.Add("Ninguno: todos los dispositivos funcionan.")
}

Sec "Errores del sistema (últimos 7 días)"
$ev = @(Get-WinEvent -FilterHashtable @{ LogName = "System"; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 500)
$crit = @($ev | Where-Object { $_.Level -eq 1 })
L "Errores críticos" $crit.Count
L "Errores" (@($ev | Where-Object { $_.Level -eq 2 }).Count)
$apagones = @($crit | Where-Object { $_.Id -eq 41 }).Count
if ($apagones) { $r.Add("  $apagones apagado(s) inesperado(s) (Kernel-Power 41): corte de luz, cuelgue o fallo de la fuente.") }
$ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { L "  $($_.Name)" "$($_.Count) veces" }

Sec "Programas que arrancan con Windows"
foreach ($p in (Get-CimInstance Win32_StartupCommand | Sort-Object Name)) { $r.Add("  - $($p.Name)") }

$carpeta = Join-Path $env:LOCALAPPDATA "OptimizadorES\Informes"
New-Item -ItemType Directory -Force -Path $carpeta | Out-Null
$archivo = Join-Path $carpeta ("Informe_{0}_{1:yyyyMMdd_HHmm}.txt" -f $env:COMPUTERNAME, (Get-Date))
$r | Set-Content -Path $archivo -Encoding UTF8
Copy-Item -Path $archivo -Destination ([Environment]::GetFolderPath("Desktop")) -ErrorAction SilentlyContinue
Write-Output "Informe guardado en $archivo (y una copia en el Escritorio)."
Start-Process -FilePath "notepad.exe" -ArgumentList "`"$archivo`""
'@

$script:codigoBateria = @'
$carpeta = Join-Path $env:LOCALAPPDATA "OptimizadorES\Informes"
New-Item -ItemType Directory -Force -Path $carpeta | Out-Null
$archivo = Join-Path $carpeta ("Bateria_{0}_{1:yyyyMMdd_HHmm}.html" -f $env:COMPUTERNAME, (Get-Date))
powercfg /batteryreport /output "$archivo" 2>&1 | Out-Null
if (Test-Path $archivo) {
    Start-Process -FilePath $archivo
    Write-Output "Informe de batería abierto en el navegador: $archivo"
} else {
    Write-Warning "Este equipo no tiene batería o no se pudo generar el informe."
}
'@

$pI = $script:UI.PanelInforme
[void]$pI.Children.Add((New-Titulo "Informe del equipo" "Crea un resumen en texto para guardar en el ticket de soporte o comparar el antes y el después. No cambia nada en el equipo."))

New-TarjetaAccion -Panel $pI -Titulo "Generar informe del equipo" -TextoBoton "Generar" -Riesgo "Bajo" `
    -Descripcion "Equipo y número de serie, Windows y activación, procesador, RAM, gráficos, salud y espacio de discos, batería, red, antivirus, BitLocker, dispositivos con errores, errores críticos de la última semana y programas de arranque." `
    -Aviso "Incluye el número de serie, el usuario y las IP: compártelo solo con quien da soporte." -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Informe del equipo" -Codigo $script:codigoInforme)
    }

New-TarjetaAccion -Panel $pI -Titulo "Informe de batería (portátiles)" -TextoBoton "Generar" -Riesgo "Bajo" `
    -Descripcion "Informe oficial de Windows con el historial de uso y el desgaste de la batería." -Aviso "" -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Informe de batería" -Codigo $script:codigoBateria)
    }

New-TarjetaAccion -Panel $pI -Titulo "Abrir carpeta de informes" -TextoBoton "Abrir" -Riesgo "Bajo" `
    -Descripcion "Todos los informes generados en este equipo." -Aviso "" -Accion {
        New-Item -ItemType Directory -Force -Path $script:CarpetaInformes | Out-Null
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$($script:CarpetaInformes)`""
    }

# Botones de abajo: solo se muestran los que sirven en la pestaña abierta
function Update-BotonesPestana {
    $sel = [string]$script:UI.Pestanas.SelectedItem.Name
    $enAjustes = if ($sel -eq "TabAjustes") { "Visible" } else { "Collapsed" }
    foreach ($b in "BtnRecomendados", "BtnPresetEstandar", "BtnPresetMinimo", "BtnLimpiar", "BtnDeshacer", "BtnAplicar", "BtnExportar", "BtnImportar") { $script:UI[$b].Visibility = $enAjustes }
    $script:UI.BtnPreferencias.Visibility = if ($sel -eq "TabPreferencias") { "Visible" } else { "Collapsed" }
}
# Comprobaciones que se lanzan al abrir algunas pestañas (si hay otro trabajo, se hacen al terminar)
function Invoke-ComprobacionPestana {
    $sel = [string]$script:UI.Pestanas.SelectedItem.Name
    if ($sel -eq "TabApps" -and -not $script:AppsComprobadas) { Start-ComprobarApps }
    if ($sel -eq "TabConfig" -and -not $script:FeaturesComprobadas) { Start-ComprobarFeatures }
    if ($sel -eq "TabInicio" -or $sel -eq "TabRendimiento") { Update-IndicadorRam }
    if (Get-Command Invoke-ComprobacionExtra -ErrorAction SilentlyContinue) { Invoke-ComprobacionExtra $sel }
}
$script:UI.Pestanas.Add_SelectionChanged({
    param($origen, $evento)
    if ($evento.OriginalSource -ne $script:UI.Pestanas) { return }
    Update-BotonesPestana
    Invoke-ComprobacionPestana
})
Update-BotonesPestana

# ---------------------------------------------------------------- Acceso directo
New-TarjetaAccion -Panel $script:UI.PanelAyuda -Titulo "Crear acceso directo en el Escritorio" -TextoBoton "Crear" -Riesgo "Bajo" `
    -Descripcion "Copia el optimizador a tu perfil y crea un acceso directo con su icono en el Escritorio y en el menú Inicio, para abrirlo como una app." `
    -Aviso "Si más adelante descargas una versión nueva, ábrela una vez y vuelve a pulsar este botón para actualizar la copia." -Accion {
        try {
            $carpeta = Join-Path $env:LOCALAPPDATA "OptimizadorES"
            New-Item -ItemType Directory -Force -Path $carpeta | Out-Null
            $copia = Join-Path $carpeta "OptimizadorES.ps1"
            if ($script:RutaScript -ne $copia) { Copy-Item -LiteralPath $script:RutaScript -Destination $copia -Force }
            $ico = Join-Path $carpeta "OptimizadorES.ico"
            [IO.File]::WriteAllBytes($ico, [Convert]::FromBase64String($script:IconoIco))
            $shell = New-Object -ComObject WScript.Shell
            foreach ($dir in @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("Programs"))) {
                $lnk = $shell.CreateShortcut((Join-Path $dir "Optimizador de Windows.lnk"))
                $lnk.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
                $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$copia`""
                $lnk.IconLocation = "$ico,0"
                $lnk.WorkingDirectory = $carpeta
                $lnk.Description = "Optimizador de Windows en español"
                $lnk.Save()
            }
            Escribir-Log "Acceso directo creado en el Escritorio y en el menú Inicio."
            [void][System.Windows.MessageBox]::Show("Listo: ya tienes 'Optimizador de Windows' en el Escritorio y en el menú Inicio.", "Acceso directo", "OK", "Information")
        } catch {
            Escribir-Log "No se pudo crear el acceso directo: $($_.Exception.Message)" "ERROR"
        }
    }

# ---------------------------------------------------------------- Resumen al terminar
function Show-ResumenTrabajo {
    $o = $script:OpcionesTrabajo
    $r = $global:Estado.Resumen
    if (-not $o -or -not $r -or $o.Silencioso) { return }
    if ($r.Cancelado) {
        [void][System.Windows.MessageBox]::Show("Proceso cancelado: no se pudo crear el punto de restauración, así que no se cambió nada. Revisa el registro de abajo.", $o.Titulo, "OK", "Error")
        return
    }
    $msg = "$($o.Titulo): terminado.`r`n`r`n"
    $msg += "$([char]0x2714) Correctos: $($r.Ok)`r`n"
    if ($r.Avisos) { $msg += "$([char]0x26A0) Con avisos: $($r.Avisos)`r`n" }
    if ($r.Errores) { $msg += "$([char]0x2716) Con errores: $($r.Errores)`r`n" }
    if ($r.Avisos -or $r.Errores) { $msg += "`r`nLos detalles están en el registro de abajo.`r`n" }
    $icono = if ($r.Errores) { "Warning" } else { "Information" }
    if ($o.Reinicio -and ($r.Ok + $r.Avisos) -gt 0) {
        $msg += "`r`nAlgunos cambios necesitan reiniciar el equipo. ¿Reiniciar ahora?`r`n(Guarda tu trabajo antes de pulsar Sí.)"
        if ([System.Windows.MessageBox]::Show($msg, $o.Titulo, "YesNo", $icono) -eq "Yes") {
            Escribir-Log "Reiniciando el equipo..."
            Restart-Computer -Force
        }
    } else {
        [void][System.Windows.MessageBox]::Show($msg, $o.Titulo, "OK", $icono)
    }
}

# ---------------------------------------------------------------- Ajustes ya aplicados
function Test-AjusteAplicado {
    param($Item)
    $regs = @($Item.registry | Where-Object { $_ })
    $svcs = @($Item.service | Where-Object { $_ })
    if ($regs.Count -eq 0 -and $svcs.Count -eq 0) { return $false }
    Initialize-HKU
    foreach ($r in $regs) {
        $actual = $null
        try {
            if (Test-Path $r.Path) { $actual = (Get-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue).($r.Name) }
        } catch { }
        if ($r.Value -eq "<RemoveEntry>") {
            if ($null -ne $actual) { return $false }
            continue
        }
        if ($null -eq $actual -or [string]$actual -ne [string]$r.Value) { return $false }
    }
    foreach ($sv in $svcs) {
        $servicio = Get-Service -Name $sv.Name -ErrorAction SilentlyContinue
        if ($servicio -and [string]$servicio.StartType -ne [string]$sv.StartupType) { return $false }
    }
    return $true
}

$script:ChkOcultar = New-Object System.Windows.Controls.CheckBox
$script:ChkOcultar.Content = "Ocultar los ajustes que ya están aplicados en este equipo"
$script:ChkOcultar.IsChecked = $true
$script:ChkOcultar.Margin = "0,0,0,4"
$script:TxtOcultos = New-Object System.Windows.Controls.TextBlock
$script:TxtOcultos.Foreground = Get-Pincel "#6B7280"
$script:TxtOcultos.TextWrapping = "Wrap"
$script:TxtOcultos.Margin = "0,0,0,6"
$ui.PanelAjustes.Children.Insert(0, $script:TxtOcultos)
$ui.PanelAjustes.Children.Insert(0, $script:ChkOcultar)

function Update-VistaAjustes {
    $ocultar = [bool]$script:ChkOcultar.IsChecked
    $ocultos = 0
    foreach ($c in $script:CasillasAjustes) {
        $it = $c.Tag
        if ($it.Key -eq "WPFTweaksRestorePoint") { continue }
        $info = $script:InfoAjuste[$it.Key]
        $aplicado = Test-AjusteAplicado $it
        $hecho = $script:HechosSesion.ContainsKey($it.Key)
        if ($aplicado -or $hecho) {
            $info.Estado.Text = if ($aplicado) { "$([char]0x2714) Ya aplicado en este equipo" } else { "$([char]0x2714) Aplicado en esta sesión" }
            $info.Estado.Foreground = Get-Pincel "#1E7B3A"
            $info.Estado.Visibility = "Visible"
            $info.Borde.BorderBrush = Get-Pincel "#86EFAC"
            if ($ocultar) {
                $c.IsChecked = $false
                $info.Oculto = $true
                $ocultos++
            } else {
                $info.Oculto = $false
            }
        } else {
            $info.Estado.Visibility = "Collapsed"
            $info.Borde.BorderBrush = Get-Pincel "#E5E7EB"
            $info.Oculto = $false
        }
    }
    if (Get-Command Update-FiltroAjustes -ErrorAction SilentlyContinue) { Update-FiltroAjustes }
    else { foreach ($c in $script:CasillasAjustes) { $i2 = $script:InfoAjuste[$c.Tag.Key]; if ($i2) { $i2.Borde.Visibility = if ($i2.Oculto) { "Collapsed" } else { "Visible" } } } }
    $script:TxtOcultos.Text = if ($ocultos) { "$ocultos ajuste(s) ya aplicados están ocultos. Quita la marca de arriba para verlos o deshacerlos." } else { "" }
    $script:TxtOcultos.Visibility = if ($ocultos) { "Visible" } else { "Collapsed" }
}
$script:ChkOcultar.Add_Click({ Update-VistaAjustes })

function Test-AjusteVisible($c) { return ($script:InfoAjuste[$c.Tag.Key].Borde.Visibility -eq "Visible") }

# ---------------------------------------------------------------- Presets de WinUtil
$ExtrasB64 = '__EXTRAS_B64__'
$script:Extras = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ExtrasB64)) | ConvertFrom-Json

function Select-Preset {
    param([string[]]$Claves)
    foreach ($c in $script:CasillasAjustes) {
        $c.IsChecked = ((($Claves -contains $c.Tag.Key) -or $c.Tag.Key -eq "WPFTweaksRestorePoint") -and (Test-AjusteVisible $c))
    }
    $n = @($script:CasillasAjustes | Where-Object { $_.IsChecked }).Count
    $script:UI.TxtEstado.Text = "Preset seleccionado: $n ajuste(s) marcados (los ya aplicados se omiten)."
}
$ui.BtnPresetEstandar.Add_Click({ Select-Preset -Claves @($script:Extras.Presets.Standard) })
$ui.BtnPresetMinimo.Add_Click({ Select-Preset -Claves @($script:Extras.Presets.Minimal) })

# ---------------------------------------------------------------- Exportar / importar selección
$ui.BtnExportar.Add_Click({
    $datos = [ordered]@{
        Ajustes      = @($script:CasillasAjustes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag.Key })
        Preferencias = @{}
        Apps         = @($script:TarjetasApps | Where-Object { $_.Casilla.IsChecked } | ForEach-Object { $_.App.Id })
        Privacidad   = @($script:CasillasPriv | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag.Key })
        Prioridades  = @(Get-ReglasPrioridad | ForEach-Object { @{ Exe = $_.Exe; Valor = $_.Valor } })
        Tema         = [string]$script:Prefs.Tema
    }
    foreach ($c in $script:CasillasPref) { $datos.Preferencias[$c.Tag.Key] = [bool]$c.IsChecked }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = "Selección del optimizador (*.json)|*.json"
    $dlg.FileName = "configuracion-optimizador.json"
    if ($dlg.ShowDialog()) {
        $datos | ConvertTo-Json -Depth 4 | Set-Content -Path $dlg.FileName -Encoding UTF8
        Escribir-Log "Selección guardada en $($dlg.FileName)"
        [void][System.Windows.MessageBox]::Show("Configuración guardada. Usa 'Importar' en otro equipo para marcar lo mismo y copiar tus reglas de prioridad.", "Exportar", "OK", "Information")
    }
})

$ui.BtnImportar.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = "Selección del optimizador (*.json)|*.json"
    if (-not $dlg.ShowDialog()) { return }
    try {
        $datos = Get-Content -Path $dlg.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($c in $script:CasillasAjustes) { $c.IsChecked = (@($datos.Ajustes) -contains $c.Tag.Key) -and (Test-AjusteVisible $c) }
        foreach ($t in $script:TarjetasApps) { $t.Casilla.IsChecked = (@($datos.Apps) -contains $t.App.Id) }
        foreach ($c in $script:CasillasPref) {
            $v = $datos.Preferencias.($c.Tag.Key)
            if ($null -ne $v) { $c.IsChecked = [bool]$v }
        }
        foreach ($c in $script:CasillasPriv) { $c.IsChecked = (@($datos.Privacidad) -contains $c.Tag.Key) -and -not $script:InfoPriv[$c.Tag.Key].Hecho }
        $reglas = @($datos.Prioridades | Where-Object { $_ -and $_.Exe })
        if ($reglas.Count -and [System.Windows.MessageBox]::Show("El archivo trae $($reglas.Count) regla(s) de prioridad:`r`n" + (($reglas | ForEach-Object { " - $($_.Exe): $($script:Prioridades[[int]$_.Valor])" }) -join "`r`n") + "`r`n`r`n¿Añadirlas ahora a este equipo?", "Importar", "YesNo", "Question") -eq "Yes") {
            foreach ($rg in $reglas) { try { Set-ReglaPrioridad ([string]$rg.Exe) ([int]$rg.Valor) } catch { Escribir-Log "No se pudo añadir la prioridad de $($rg.Exe): $($_.Exception.Message)" "AVISO" } }
            Show-ReglasPrioridad
        }
        Escribir-Log "Selección importada de $($dlg.FileName). Revisa las pestañas y pulsa Aplicar / Instalar."
        [void][System.Windows.MessageBox]::Show("Configuración importada. Aún no se aplicó nada: revisa Ajustes, Preferencias, Privacidad y Apps y pulsa sus botones.", "Importar", "OK", "Information")
    } catch {
        [void][System.Windows.MessageBox]::Show("No se pudo leer el archivo: $($_.Exception.Message)", "Importar", "OK", "Error")
    }
})

# ---------------------------------------------------------------- Pestaña Configuración
$pC = $script:UI.PanelConfig

# Características de Windows
[void]$pC.Children.Add((New-Titulo "Características de Windows" "Componentes opcionales de Windows. Al abrir esta pestaña se comprueba cuáles ya están activadas."))
$script:FeaturesComprobadas = $false
foreach ($f in @($script:Extras.Features)) {
    New-TarjetaAccion -Panel $pC -Clave "FEAT:$($f.Key)" -Titulo $f.Nombre -TextoBoton "Activar" -Riesgo $f.Riesgo `
        -Detalle ("Activa estos componentes opcionales de Windows: " + (@($f.Features) -join ", ") + ". Si ya están activados, no cambia nada. Para quitarlos: Panel de control > Programas > Activar o desactivar las características de Windows.") `
        -Origen ([pscustomobject]@{ InvokeScript = @($f.Script) }) `
        -Descripcion $f.Descripcion -Aviso $f.Aviso -Accion ({
            $uid = [string]$this.Uid
            $feat = @($script:Extras.Features | Where-Object { "FEAT:$($_.Key)" -eq $uid })[0]
            if (-not $feat) { return }
            if ($feat.Riesgo -ne "Bajo") {
                if ([System.Windows.MessageBox]::Show("$($feat.Nombre)`r`n`r`n$($feat.Aviso)`r`n`r`n¿Continuar?", "Características", "YesNo", "Warning") -ne "Yes") { return }
            }
            Start-Pasos -Pasos @(New-PasoScript -Nombre $feat.Nombre -Codigo $feat.Script) -OfrecerReinicio
        })
    $script:TarjetaPorId["FEAT:$($f.Key)"].Boton.Uid = "FEAT:$($f.Key)"
}

function Start-ComprobarFeatures {
    if ($script:Trabajo) { return }
    $script:FeaturesComprobadas = $true
    $lineas = foreach ($f in @($script:Extras.Features)) {
        if (@($f.Features).Count) { "@{ K = 'FEAT:$($f.Key)'; F = @(" + ((@($f.Features) | ForEach-Object { "'$_'" }) -join ",") + ") }" }
    }
    $codigo = @"
`$lista = @($($lineas -join ", "))
foreach (`$x in `$lista) { Set-EstadoApp -Id `$x.K -Texto 'Comprobando...' -Tipo 'trabajo' }
Write-Output 'Comprobando las características de Windows...'
`$featEstado = @{}
Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | ForEach-Object { `$featEstado[`$_.FeatureName] = [string]`$_.State }
foreach (`$x in `$lista) {
    `$faltan = @(`$x.F | Where-Object { -not `$featEstado.ContainsKey(`$_) })
    `$apagadas = @(`$x.F | Where-Object { `$featEstado.ContainsKey(`$_) -and `$featEstado[`$_] -ne 'Enabled' })
    if (`$faltan.Count -eq `$x.F.Count) { Set-EstadoApp -Id `$x.K -Texto 'No disponible en esta edición de Windows' -Tipo 'info' }
    elseif (`$apagadas.Count -eq 0) { Set-EstadoApp -Id `$x.K -Texto 'Ya activada $([char]0x2714)' -Tipo 'ok' }
    else { Set-EstadoApp -Id `$x.K -Texto '' -Tipo 'info' }
}
"@
    Start-Pasos -Pasos @(New-PasoScript -Nombre "Comprobar características" -Codigo $codigo) -Silencioso
}

# Actualizaciones de Windows
function Get-ModoUpdates {
    $wu = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $au = Get-ItemProperty -Path "$wu\AU" -ErrorAction SilentlyContinue
    $p  = Get-ItemProperty -Path $wu -ErrorAction SilentlyContinue
    if ($au -and $au.NoAutoUpdate -eq 1) { return "Desactivadas" }
    if ($p -and $p.DeferFeatureUpdatesPeriodInDays -eq 365) { return "Recomendado (solo seguridad)" }
    return "Predeterminado de Windows"
}
[void]$pC.Children.Add((New-Titulo "Actualizaciones de Windows" ""))
$script:TxtModoUpdates = New-Object System.Windows.Controls.TextBlock
$script:TxtModoUpdates.FontWeight = "SemiBold"
$script:TxtModoUpdates.Margin = "0,0,0,8"
$script:TxtModoUpdates.Text = "Modo actual: " + (Get-ModoUpdates)
[void]$pC.Children.Add($script:TxtModoUpdates)

New-TarjetaAccion -Panel $pC -Titulo "Predeterminado de Windows" -TextoBoton "Aplicar" -Riesgo "Bajo" `
    -Descripcion "Deja Windows Update como viene de fábrica. Úsalo también para deshacer los otros dos modos." -Aviso "" -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Actualizaciones: predeterminado" -Codigo $script:Extras.Updates.default) -OfrecerReinicio
    }
New-TarjetaAccion -Panel $pC -Titulo "Recomendado: solo seguridad" -TextoBoton "Aplicar" -Riesgo "Medio" `
    -Descripcion "Recibe parches de seguridad (con 4 días de espera) y retrasa 1 año las actualizaciones grandes de versión. No instala drivers desde Windows Update." `
    -Aviso "Tardarás en recibir funciones nuevas de Windows. Los drivers tendrás que actualizarlos tú (fabricante o apps)." -Accion {
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Actualizaciones: solo seguridad" -Codigo $script:Extras.Updates.security) -OfrecerReinicio
    }
New-TarjetaAccion -Panel $pC -Titulo "Desactivar actualizaciones" -TextoBoton "Desactivar" -Riesgo "Alto" `
    -Descripcion "Detiene y desactiva los servicios y tareas de Windows Update." `
    -Aviso "PELIGROSO: el equipo deja de recibir parches de seguridad y queda expuesto a virus y ataques. Solo para equipos aislados o casos muy concretos." -Accion {
        $m = "Vas a DESACTIVAR Windows Update. El equipo dejará de recibir parches de seguridad hasta que elijas 'Predeterminado de Windows'.`r`n`r`n¿Seguro?"
        if ([System.Windows.MessageBox]::Show($m, "Desactivar actualizaciones", "YesNo", "Warning") -eq "Yes") {
            Start-Pasos -Pasos @(New-PasoScript -Nombre "Actualizaciones: desactivar" -Codigo $script:Extras.Updates.disable) -OfrecerReinicio
        }
    }

# DNS
[void]$pC.Children.Add((New-Titulo "Servidores DNS" "Cambia el DNS de las conexiones activas (Wi-Fi y cable)."))
$filaDns = New-Object System.Windows.Controls.WrapPanel
$filaDns.Margin = "0,0,0,6"
$script:CmbDns = New-Object System.Windows.Controls.ComboBox
$script:CmbDns.Width = 330
$script:CmbDns.Margin = "0,0,8,4"
[void]$script:CmbDns.Items.Add("Automático (el de tu router o proveedor)")
foreach ($d in @($script:Extras.Dns)) { [void]$script:CmbDns.Items.Add($d.Nombre) }
$script:CmbDns.SelectedIndex = 0
$script:BtnDns = New-Object System.Windows.Controls.Button
$script:BtnDns.Content = "Aplicar DNS"
$script:BtnDns.Padding = "12,4"
$script:BtnDns.Margin = "0,0,0,4"
$script:BtnDns.Tag = $true
[void]$filaDns.Children.Add($script:CmbDns)
[void]$filaDns.Children.Add($script:BtnDns)
[void]$pC.Children.Add($filaDns)
$script:BotonesSeguridad += $script:BtnDns
$txtDns = New-Object System.Windows.Controls.TextBlock
$txtDns.TextWrapping = "Wrap"
$txtDns.Foreground = Get-Pincel $script:Colores.Medio.Texto
$txtDns.Margin = "0,0,0,10"
$actualDns = ""
try { $actualDns = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses } | Select-Object -First 1).ServerAddresses -join ", " } catch { }
$txtDns.Text = "DNS actual: $(if ($actualDns) { $actualDns } else { 'desconocido' }).  $([char]0x26A0) En oficinas con servidor o dominio propio NO lo cambies: dejarías de ver equipos y carpetas de la red."
[void]$pC.Children.Add($txtDns)
$script:BtnDns.Add_Click({
    $i = $script:CmbDns.SelectedIndex
    if ($i -le 0) {
        $codigo = @'
foreach ($a in (Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.HardwareInterface })) {
    Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
    Write-Output "DNS de '$($a.Name)': automático."
}
Clear-DnsClientCache -ErrorAction SilentlyContinue
'@
        $nombre = "Automático"
    } else {
        $d = @($script:Extras.Dns)[$i - 1]
        $nombre = $d.Nombre
        $codigo = @"
foreach (`$a in (Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' -and `$_.HardwareInterface })) {
    Set-DnsClientServerAddress -InterfaceIndex `$a.ifIndex -ServerAddresses @('$($d.P)', '$($d.S)', '$($d.P6)', '$($d.S6)') -ErrorAction Stop
    Write-Output "DNS de '`$(`$a.Name)': $($d.P), $($d.S)"
}
Clear-DnsClientCache -ErrorAction SilentlyContinue
"@
    }
    Start-Pasos -Pasos @(New-PasoScript -Nombre "Cambiar DNS a $nombre" -Codigo $codigo)
})

# Paneles clásicos
[void]$pC.Children.Add((New-Titulo "Paneles clásicos de Windows" "Accesos directos a las herramientas de siempre."))
$panelBotones = New-Object System.Windows.Controls.WrapPanel
$paneles = @(
    @("Panel de control", "control"), @("Programas y características", "appwiz.cpl"), @("Administrador de dispositivos", "devmgmt.msc"),
    @("Administración de discos", "diskmgmt.msc"), @("Administración de equipos", "compmgmt.msc"), @("Servicios", "services.msc"),
    @("Conexiones de red", "ncpa.cpl"), @("Opciones de energía", "powercfg.cpl"), @("Impresoras", "shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}"),
    @("Sonido", "mmsys.cpl"), @("Ratón", "main.cpl"), @("Región", "intl.cpl"), @("Fecha y hora", "timedate.cpl"),
    @("Propiedades del sistema", "sysdm.cpl"), @("Seguridad y mantenimiento", "wscui.cpl"), @("Firewall", "firewall.cpl"),
    @("Visor de eventos", "eventvwr.msc"), @("Programador de tareas", "taskschd.msc"), @("Restaurar sistema", "rstrui.exe")
)
foreach ($pn in $paneles) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $pn[0]
    $b.Tag = $pn[1]
    $b.Padding = "10,4"
    $b.Margin = "0,0,6,6"
    $b.Add_Click({
        $cmd = [string]$this.Tag
        try {
            if ($cmd -like "shell:*") { Start-Process -FilePath "explorer.exe" -ArgumentList $cmd } else { Start-Process -FilePath $cmd }
        } catch { Escribir-Log "No se pudo abrir ${cmd}: $($_.Exception.Message)" "ERROR" }
    })
    [void]$panelBotones.Children.Add($b)
}
[void]$pC.Children.Add($panelBotones)

Update-VistaAjustes

# ---------------------------------------------------------------- Utilidades de pestañas
function Select-Pestana([string]$NombrePestana) {
    $tab = $script:Ventana.FindName($NombrePestana)
    if ($tab) { $script:UI.Pestanas.SelectedItem = $tab }
}

function Get-ColorUso([int]$Porcentaje) {
    if ($Porcentaje -ge 85) { return "#DC2626" }
    if ($Porcentaje -ge 70) { return "#D97706" }
    return "#16A34A"
}

function New-Indicador([string]$Nombre, [string]$Glifo) {
    $marco = New-Object System.Windows.Controls.Border
    $marco.Background = Get-Pincel "#FFFFFF"
    $marco.BorderBrush = Get-Pincel "#E2E6EC"
    $marco.BorderThickness = 1
    $marco.CornerRadius = 10
    $marco.Padding = "14,12"
    $marco.Margin = "0,0,10,10"
    $marco.Width = 205
    $pila = New-Object System.Windows.Controls.StackPanel
    $cab = New-Object System.Windows.Controls.StackPanel
    $cab.Orientation = "Horizontal"
    $ico = New-Object System.Windows.Controls.TextBlock
    $ico.Text = $Glifo
    $ico.FontFamily = "Segoe MDL2 Assets"
    $ico.Foreground = Get-Pincel "#2563EB"
    $ico.Margin = "0,1,8,0"
    $ico.VerticalAlignment = "Center"
    [void]$cab.Children.Add($ico)
    $txtNombre = New-Object System.Windows.Controls.TextBlock
    $txtNombre.Text = $Nombre
    $txtNombre.Foreground = Get-Pincel "#6B7280"
    $txtNombre.FontSize = 12
    [void]$cab.Children.Add($txtNombre)
    [void]$pila.Children.Add($cab)
    $valor = New-Object System.Windows.Controls.TextBlock
    $valor.Text = "..."
    $valor.FontSize = 22
    $valor.FontWeight = "SemiBold"
    $valor.Foreground = Get-Pincel "#111827"
    $valor.Margin = "0,4,0,4"
    [void]$pila.Children.Add($valor)
    $barraInd = New-Object System.Windows.Controls.ProgressBar
    $barraInd.Height = 6
    $barraInd.Minimum = 0
    $barraInd.Maximum = 100
    $barraInd.BorderThickness = 0
    $barraInd.Background = Get-Pincel "#E5E7EB"
    [void]$pila.Children.Add($barraInd)
    $detalle = New-Object System.Windows.Controls.TextBlock
    $detalle.Foreground = Get-Pincel "#6B7280"
    $detalle.FontSize = 12
    $detalle.TextWrapping = "Wrap"
    $detalle.Margin = "0,6,0,0"
    [void]$pila.Children.Add($detalle)
    $marco.Child = $pila
    return @{ Borde = $marco; Valor = $valor; Barra = $barraInd; Detalle = $detalle }
}

function Set-Indicador($Ind, [string]$Valor, [int]$Porcentaje, [string]$Detalle, [string]$Color = "") {
    $Ind.Valor.Text = $Valor
    $Ind.Detalle.Text = $Detalle
    if ($Porcentaje -ge 0) {
        $Ind.Barra.Visibility = "Visible"
        $Ind.Barra.Value = $Porcentaje
        $c = if ($Color) { $Color } else { Get-ColorUso $Porcentaje }
        $Ind.Barra.Foreground = Get-Pincel $c
    } else {
        $Ind.Barra.Visibility = "Collapsed"
    }
}

# Datos del equipo en el encabezado
try {
    $osEnc = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $ramEnc = [math]::Round($osEnc.TotalVisibleMemorySize / 1MB)
    $script:UI.TxtEquipo.Text = "$env:COMPUTERNAME`n$($osEnc.Caption -replace '^Microsoft ', '')`n$ramEnc GB de RAM"
} catch { }

# ---------------------------------------------------------------- RAM y disco: ajustes propios
# Mismo formato que los ajustes de WinUtil, así se guardan con respaldo y se deshacen exacto
function New-EntradaRegistro([string]$Ruta, [string]$Nombre, [string]$Valor) {
    return [pscustomobject]@{ Path = $Ruta; Name = $Nombre; Type = "DWord"; Value = $Valor; OriginalValue = "<RemoveEntry>" }
}
$script:ItemFondo = [pscustomobject]@{
    Key = "OPT_FONDO"; Nombre = "Evitar apps en segundo plano"; Grupo = "Rendimiento"; Riesgo = "Bajo"
    Descripcion = ""; Aviso = ""; InvokeScript = @(); UndoScript = @(); service = @()
    registry = @(
        (New-EntradaRegistro "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy" "LetAppsRunInBackground" "2"),
        (New-EntradaRegistro "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "StartupBoostEnabled" "0"),
        (New-EntradaRegistro "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "BackgroundModeEnabled" "0"),
        (New-EntradaRegistro "HKLM:\SOFTWARE\Policies\Google\Chrome" "BackgroundModeEnabled" "0"),
        (New-EntradaRegistro "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" "AllowNewsAndInterests" "0")
    )
}
$script:ItemServiciosRam = [pscustomobject]@{
    Key = "OPT_SERVICIOS_RAM"; Nombre = "Servicios que no hacen falta siempre"; Grupo = "Rendimiento"; Riesgo = "Bajo"
    Descripcion = ""; Aviso = ""; InvokeScript = @(); UndoScript = @(); registry = @()
    service = @(foreach ($n in "DiagTrack", "dmwappushservice", "MapsBroker", "RetailDemo", "Fax", "WerSvc", "PcaSvc") {
        [pscustomobject]@{ Name = $n; StartupType = "Manual"; OriginalType = "Automatic" }
    })
}
$script:ItemTemporales = @($script:Ajustes | Where-Object { $_.Key -eq "WPFTweaksDeleteTempFiles" })[0]

$script:codigoLiberarRam = @'
if (-not ("OptESRam.Nativo" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace OptESRam {
public static class Nativo {
    [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int clase, ref int info, int largo);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint acceso, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool LookupPrivilegeValue(string sistema, string nombre, out long luid);
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct TP { public int Cuenta; public long Luid; public int Atributos; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr t, bool desactivarTodo, ref TP nuevo, int largo, IntPtr previo, IntPtr devuelto);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static bool Privilegio(string nombre) {
        IntPtr t;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out t)) return false;
        try {
            TP tp; tp.Cuenta = 1; tp.Atributos = 2;
            if (!LookupPrivilegeValue(null, nombre, out tp.Luid)) return false;
            bool ok = AdjustTokenPrivileges(t, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            return ok && Marshal.GetLastWin32Error() == 0;
        } finally { CloseHandle(t); }
    }
    // SystemMemoryListInformation = 80: 2 vaciar working sets, 3 escribir lista modificada, 4 purgar en espera, 5 purgar en espera de baja prioridad
    public static int Lista(int comando) { return NtSetSystemInformation(80, ref comando, 4); }
}
}
"@
}
$libreAntes = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2)
[void][OptESRam.Nativo]::Privilegio("SeProfileSingleProcessPrivilege")
[void][OptESRam.Nativo]::Privilegio("SeIncreaseQuotaPrivilege")
if ([OptESRam.Nativo]::Lista(2) -ne 0) {
    $n = 0
    foreach ($p in Get-Process) { try { if ([OptESRam.Nativo]::EmptyWorkingSet($p.Handle)) { $n++ } } catch { } }
    Write-Output "Memoria de trabajo recortada en $n procesos."
} else {
    Write-Output "Memoria de trabajo de los procesos recortada."
}
[void][OptESRam.Nativo]::Lista(3)
[void][OptESRam.Nativo]::Lista(5)
if ([OptESRam.Nativo]::Lista(4) -eq 0) { Write-Output "Caché en espera vaciada." }
else { Write-Warning "No se pudo vaciar la caché en espera." }
Start-Sleep -Seconds 1
$libreDespues = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2)
Write-Output ("RAM libre antes: {0} GB. Después: {1} GB (+{2} GB)." -f $libreAntes, $libreDespues, [math]::Max(0, [math]::Round($libreDespues - $libreAntes, 2)))
Write-Output "Es normal que los programas vuelvan a tomar parte de esa memoria cuando los uses."
'@

$script:codigoPaginacion = @'
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.AutomaticManagedPagefile) {
    Write-Output "La memoria virtual ya está en automático (lo recomendado). No hace falta cambiar nada."
    return
}
Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
Write-Output "Memoria virtual en automático (administrada por Windows). Se aplica al reiniciar."
'@

# ---------------------------------------------------------------- Análisis del equipo
$script:codigoAnalisis = @'
function Add-Hallazgo([string]$Nivel, [string]$Titulo, [string]$Detalle, [string]$Accion = "") {
    [void]$global:Estado.Analisis.Add(@{ Nivel = $Nivel; Titulo = $Titulo; Detalle = $Detalle; Accion = $Accion })
}
$met = $global:Estado.Metricas
Write-Output "Analizando el equipo..."

# Memoria RAM
$os = Get-CimInstance Win32_OperatingSystem
$totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$libreGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$pctRam = [int][math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize))
$top = Get-Process | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{ Proc = $_.Name; GB = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1GB, 1) }
} | Sort-Object GB -Descending | Select-Object -First 3
$topTxt = ($top | ForEach-Object { "$($_.Proc) ($($_.GB) GB)" }) -join ", "
if ($pctRam -ge 85) {
    Add-Hallazgo "Problema" "La memoria RAM está casi llena ($pctRam %)" "Quedan $libreGB GB libres y los programas irán lentos. Lo que más usa: $topTxt." "LiberarRAM"
} elseif ($pctRam -ge 70) {
    Add-Hallazgo "Atencion" "La memoria RAM va bastante ocupada ($pctRam %)" "Lo que más usa: $topTxt. Cierra lo que no uses o libera RAM." "LiberarRAM"
} else {
    Add-Hallazgo "Bien" "Memoria RAM con espacio ($pctRam % en uso)" "Lo que más usa: $topTxt."
}
if ($totalGB -le 8.5) {
    Add-Hallazgo "Atencion" "El equipo tiene $([math]::Round($totalGB)) GB de RAM" "Con Windows 11, navegador y Office se recomiendan 16 GB. Si la placa lo permite, ampliar la RAM es la mejora que más se nota."
}

# Tiempo encendido y reinicio pendiente
$horas = ((Get-Date) - $os.LastBootUpTime).TotalHours
$met.Encendido = if ($horas -ge 48) { "{0} días" -f [math]::Floor($horas / 24) } else { "{0} h" -f [math]::Floor($horas) }
$pendiente = (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") -or
             (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending")
if ($pendiente) {
    Add-Hallazgo "Atencion" "Windows espera un reinicio" "Hay actualizaciones o cambios a medio instalar. Reinicia cuando puedas." "Reiniciar"
} elseif ($horas -ge 24 * 7) {
    Add-Hallazgo "Atencion" "El equipo lleva $([math]::Floor($horas / 24)) días sin reiniciar" "Reiniciar libera memoria y termina instalaciones. Ojo: 'Apagar' no cuenta si el inicio rápido está activo; usa 'Reiniciar'." "Reiniciar"
}

# Disco C:
$d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
if ($d -and $d.Size) {
    $libreDisco = [math]::Round($d.FreeSpace / 1GB, 1)
    $pctLibre = [int](100 * $d.FreeSpace / $d.Size)
    $met.DiscoPct = 100 - $pctLibre
    $met.DiscoTxt = "$libreDisco GB libres de $([math]::Round($d.Size / 1GB)) GB"
    if ($pctLibre -lt 10) {
        Add-Hallazgo "Problema" "El disco C: está casi lleno" "Solo quedan $libreDisco GB. Windows necesita espacio para actualizarse y para la memoria virtual. Borra temporales y desinstala lo que no uses." "Temporales"
    } elseif ($pctLibre -lt 20) {
        Add-Hallazgo "Atencion" "Queda poco espacio en C: ($libreDisco GB)" "Conviene dejar al menos un 20 % libre. Empieza por los archivos temporales." "Temporales"
    } else {
        Add-Hallazgo "Bien" "Espacio en disco suficiente" "$libreDisco GB libres en C:."
    }
}

# Archivos temporales
$bytesTemp = 0
foreach ($carpeta in @($env:TEMP, "$env:SystemRoot\Temp")) {
    try { $bytesTemp += [double](Get-ChildItem -LiteralPath $carpeta -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch { }
}
$gbTemp = [math]::Round($bytesTemp / 1GB, 1)
if ($gbTemp -ge 1) {
    Add-Hallazgo "Atencion" "Hay $gbTemp GB de archivos temporales" "Son restos de instalaciones y programas. Se pueden borrar sin perder nada tuyo." "Temporales"
}

# Salud y tipo de disco
try {
    $fisicos = @(Get-PhysicalDisk -ErrorAction Stop)
    foreach ($f in $fisicos | Where-Object { $_.HealthStatus -and [string]$_.HealthStatus -ne "Healthy" }) {
        Add-Hallazgo "Problema" "El disco '$($f.FriendlyName)' reporta problemas de salud" "Estado: $($f.HealthStatus). Haz una copia de seguridad de tus archivos cuanto antes." "Informe"
    }
    $numDisco = (Get-Partition -DriveLetter C -ErrorAction Stop).DiskNumber
    $sistema = $fisicos | Where-Object { [string]$_.DeviceId -eq [string]$numDisco } | Select-Object -First 1
    if ($sistema -and [string]$sistema.MediaType -eq "HDD") {
        Add-Hallazgo "Atencion" "Windows está en un disco mecánico (HDD)" "Cambiarlo por un SSD es la mejora de velocidad más grande que se le puede hacer a este equipo."
    }
} catch { }

# Programas de arranque
$arranque = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
$met.Arranque = $arranque.Count
if ($arranque.Count -ge 12) {
    Add-Hallazgo "Atencion" "Hay $($arranque.Count) programas configurados para arrancar con Windows" "Cada uno consume RAM y retrasa el encendido. Desactiva los que no necesites nada más encender." "Arranque"
}

# Memoria virtual
if (@(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue).Count -eq 0) {
    Add-Hallazgo "Problema" "La memoria virtual (archivo de paginación) está desactivada" "Sin ella, los programas se cierran de golpe cuando se llena la RAM. Lo recomendado es dejarla en automático." "Paginacion"
}

# Controladores con problemas (22 = desactivado a propósito)
$malos = @(Get-CimInstance Win32_PnPEntity -Filter "ConfigManagerErrorCode <> 0 AND ConfigManagerErrorCode <> 22" -ErrorAction SilentlyContinue)
if ($malos.Count) {
    $nombres = ($malos | Select-Object -First 3 | ForEach-Object { if ($_.Name) { $_.Name } else { $_.DeviceID } }) -join "; "
    Add-Hallazgo "Atencion" "$($malos.Count) dispositivo(s) con problemas de controlador" "Por ejemplo: $nombres. Instala el controlador del fabricante o revisa el Administrador de dispositivos." "Dispositivos"
}

# Actualizaciones de Windows
try {
    $ultima = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($ultima) {
        $dias = [int]((Get-Date) - $ultima.InstalledOn).TotalDays
        if ($dias -gt 45) {
            Add-Hallazgo "Atencion" "Windows lleva $dias días sin instalar actualizaciones" "Las actualizaciones corrigen fallos de seguridad. Revisa Windows Update." "Updates"
        }
    }
} catch { }

# Batería (portátiles)
try {
    $llena = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
    $diseno = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
    if ($llena -and $diseno) {
        $salud = [int](100 * $llena / $diseno)
        if ($salud -lt 60) {
            Add-Hallazgo "Problema" "La batería solo conserva el $salud % de su capacidad" "Durará mucho menos que nueva. Conviene cambiarla." "Bateria"
        } elseif ($salud -lt 80) {
            Add-Hallazgo "Atencion" "La batería conserva el $salud % de su capacidad" "Es desgaste normal con el uso; si dura poco, plantéate cambiarla." "Bateria"
        }
    }
} catch { }

# Salud de los discos (SMART)
try {
    foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
        if ([string]$d.HealthStatus -eq "Unhealthy") { Add-Hallazgo "Problema" "El disco $($d.FriendlyName) está fallando" "Windows lo marca como dañado. Haz copia de tus archivos y cámbialo cuanto antes. Más detalles en Rendimiento y disco > Salud de discos." "Discos" }
        elseif ([string]$d.HealthStatus -eq "Warning") { Add-Hallazgo "Atencion" "El disco $($d.FriendlyName) da avisos de salud" "Puede empezar a fallar. Ten copia de lo importante y revisa los detalles en Rendimiento y disco > Salud de discos." "Discos" }
    }
} catch { }

Write-Output "Análisis terminado."
'@

# ---------------------------------------------------------------- Pestaña Inicio
$pIni = $script:UI.PanelInicio
[void]$pIni.Children.Add((New-Titulo "Estado de tu equipo" "Un vistazo rápido y lo que conviene arreglar. El análisis no cambia nada; cada recomendación tiene su botón."))
$filaInd = New-Object System.Windows.Controls.WrapPanel
$script:IndSalud = New-Indicador "Salud general" ([string][char]0xE95E)
$script:IndRam = New-Indicador "Memoria RAM" ([string][char]0xE9D9)
$script:IndDisco = New-Indicador "Disco C:" ([string][char]0xEDA2)
$script:IndEncendido = New-Indicador "Encendido desde hace" ([string][char]0xE823)
foreach ($ind in $script:IndSalud, $script:IndRam, $script:IndDisco, $script:IndEncendido) { [void]$filaInd.Children.Add($ind.Borde) }
[void]$pIni.Children.Add($filaInd)

$filaBotonesIni = New-Object System.Windows.Controls.WrapPanel
$filaBotonesIni.Margin = "0,2,0,10"
$script:BtnAnalizar = New-Object System.Windows.Controls.Button
$script:BtnAnalizar.Content = "Analizar de nuevo"
$script:BtnAnalizar.Style = $script:Ventana.FindResource("Primario")
$script:BtnAnalizar.Padding = "16,6"
$script:BtnAnalizar.Margin = "0,0,8,0"
$script:BtnAnalizar.Tag = $true
$script:BtnAnalizar.Add_Click({ Start-Analisis })
$script:BotonesSeguridad += $script:BtnAnalizar
[void]$filaBotonesIni.Children.Add($script:BtnAnalizar)
$btnIrRam = New-Object System.Windows.Controls.Button
$btnIrRam.Content = "Liberar RAM ahora"
$btnIrRam.Padding = "14,6"
$btnIrRam.Tag = $true
$btnIrRam.Add_Click({ Invoke-AccionAnalisis "LiberarRAM" })
$script:BotonesSeguridad += $btnIrRam
[void]$filaBotonesIni.Children.Add($btnIrRam)
$btnMineros = New-Object System.Windows.Controls.Button
$btnMineros.Content = "Buscar mineros y virus (sin antivirus)"
$btnMineros.Padding = "14,6"
$btnMineros.Margin = "8,0,0,0"
$btnMineros.Tag = $true
$btnMineros.Add_Click({ Select-Pestana "TabSeguridad"; Start-Revision })
$script:BotonesSeguridad += $btnMineros
[void]$filaBotonesIni.Children.Add($btnMineros)
[void]$pIni.Children.Add($filaBotonesIni)

$script:TxtResumenAnalisis = New-Object System.Windows.Controls.TextBlock
$script:TxtResumenAnalisis.FontSize = 15
$script:TxtResumenAnalisis.FontWeight = "SemiBold"
$script:TxtResumenAnalisis.Foreground = Get-Pincel "#111827"
$script:TxtResumenAnalisis.Margin = "0,4,0,8"
$script:TxtResumenAnalisis.Text = "Analizando el equipo..."
[void]$pIni.Children.Add($script:TxtResumenAnalisis)
$script:PanelHallazgos = New-Object System.Windows.Controls.StackPanel
[void]$pIni.Children.Add($script:PanelHallazgos)

# Qué hace el botón de cada recomendación
$script:AccionesAnalisis = @{
    LiberarRAM   = @{ Texto = "Liberar RAM";   Hacer = { Start-Pasos -Pasos @(New-PasoScript -Nombre "Liberar RAM" -Codigo $script:codigoLiberarRam) } }
    Temporales   = @{ Texto = "Limpiar";       Hacer = { if ($script:ItemTemporales) { Start-Pasos -Pasos @([pscustomobject]@{ Item = $script:ItemTemporales; Deshacer = $false }) -Titulo "Borrar archivos temporales" } } }
    Arranque     = @{ Texto = "Revisar";       Hacer = { Select-Pestana "TabArranque" } }
    Discos       = @{ Texto = "Ver";           Hacer = { Select-Pestana "TabRendimiento" } }
    Paginacion   = @{ Texto = "Arreglar";      Hacer = { Start-Pasos -Pasos @(New-PasoScript -Nombre "Memoria virtual en automático" -Codigo $script:codigoPaginacion) -OfrecerReinicio } }
    Fondo        = @{ Texto = "Aplicar";       Hacer = { Start-Pasos -Pasos @([pscustomobject]@{ Item = $script:ItemFondo; Deshacer = $false }) -Titulo "Evitar apps en segundo plano" } }
    Recomendados = @{ Texto = "Ver y marcar";  Hacer = { Select-Pestana "TabAjustes"; $script:UI.BtnRecomendados.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent))) } }
    Seguridad    = @{ Texto = "Ver";           Hacer = { Select-Pestana "TabSeguridad" } }
    Informe      = @{ Texto = "Ver";           Hacer = { Select-Pestana "TabInforme" } }
    Bateria      = @{ Texto = "Ver informe";   Hacer = { Start-Pasos -Pasos @(New-PasoScript -Nombre "Informe de batería" -Codigo $script:codigoBateria) } }
    Updates      = @{ Texto = "Abrir";         Hacer = { Start-Process "ms-settings:windowsupdate" } }
    Dispositivos = @{ Texto = "Ver";           Hacer = { Select-Pestana "TabControladores"; Update-ListaDispositivos } }
    Reiniciar    = @{ Texto = "Reiniciar";     Hacer = {
        if ([System.Windows.MessageBox]::Show("¿Reiniciar el equipo ahora? Guarda tu trabajo antes.", "Optimizador", "YesNo", "Question") -eq "Yes") { Restart-Computer -Force }
    } }
}

function Invoke-AccionAnalisis([string]$Clave) {
    $acc = $script:AccionesAnalisis[$Clave]
    if (-not $acc) { return }
    & $acc.Hacer
    # Si lanzó un trabajo, al terminar se vuelve a analizar para ver el cambio
    if ($script:Trabajo) { $script:AlTerminar = { Start-Analisis } }
}

function Start-Analisis {
    # Si hay otro trabajo en marcha, el análisis se hace al terminar
    if ($script:Trabajo) { $script:AnalisisPendiente = $true; return }
    $script:AnalisisPendiente = $false
    $global:Estado.Analisis = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $global:Estado.Metricas = [hashtable]::Synchronized(@{})
    $script:TxtResumenAnalisis.Text = "Analizando el equipo..."
    Start-Pasos -Pasos @(New-PasoScript -Nombre "Analizar el equipo" -Codigo $script:codigoAnalisis) -Silencioso
    if ($script:Trabajo) { $script:AlTerminar = { Show-Analisis } }
}

function New-TarjetaHallazgo($Hallazgo) {
    $colores = @{
        Problema = @{ Borde = "#DC2626"; Fondo = "#FEF2F2"; Icono = [string][char]0x2716 }
        Atencion = @{ Borde = "#D97706"; Fondo = "#FFFBEB"; Icono = [string][char]0x26A0 }
        Bien     = @{ Borde = "#16A34A"; Fondo = "#FFFFFF"; Icono = [string][char]0x2714 }
    }
    $col = $colores[$Hallazgo.Nivel]
    $marco = New-Object System.Windows.Controls.Border
    $marco.Background = Get-Pincel $col.Fondo
    $marco.BorderBrush = Get-Pincel $col.Borde
    $marco.BorderThickness = "4,0,0,0"
    $marco.CornerRadius = 8
    $marco.Padding = "14,10"
    $marco.Margin = "0,0,0,8"
    $fila = New-Object System.Windows.Controls.DockPanel
    $acc = if ($Hallazgo.Accion) { $script:AccionesAnalisis[$Hallazgo.Accion] } else { $null }
    if ($acc -and $Hallazgo.Nivel -ne "Bien") {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $acc.Texto
        $btn.Padding = "14,5"
        $btn.Margin = "12,0,0,0"
        $btn.VerticalAlignment = "Center"
        $btn.Uid = $Hallazgo.Accion
        $btn.Tag = $true
        $btn.IsEnabled = -not $script:Trabajo
        $btn.Add_Click({ param($origen, $e) Invoke-AccionAnalisis $origen.Uid })
        $script:BotonesSeguridad += $btn
        [System.Windows.Controls.DockPanel]::SetDock($btn, "Right")
        [void]$fila.Children.Add($btn)
    }
    $ico = New-Object System.Windows.Controls.TextBlock
    $ico.Text = $col.Icono
    $ico.Foreground = Get-Pincel $col.Borde
    $ico.FontSize = 16
    $ico.Margin = "0,0,10,0"
    $ico.VerticalAlignment = "Top"
    [System.Windows.Controls.DockPanel]::SetDock($ico, "Left")
    [void]$fila.Children.Add($ico)
    $pila = New-Object System.Windows.Controls.StackPanel
    $tit = New-Object System.Windows.Controls.TextBlock
    $tit.Text = $Hallazgo.Titulo
    $tit.FontWeight = "SemiBold"
    $tit.TextWrapping = "Wrap"
    [void]$pila.Children.Add($tit)
    if ($Hallazgo.Detalle) {
        $det = New-Object System.Windows.Controls.TextBlock
        $det.Text = $Hallazgo.Detalle
        $det.TextWrapping = "Wrap"
        $det.Foreground = Get-Pincel "#4B5563"
        $det.Margin = "0,2,0,0"
        [void]$pila.Children.Add($det)
    }
    [void]$fila.Children.Add($pila)
    $marco.Child = $fila
    return $marco
}

function Show-Analisis {
    $lista = New-Object System.Collections.ArrayList
    foreach ($h in @($global:Estado.Analisis)) { [void]$lista.Add($h) }

    # Comprobaciones rápidas que se hacen aquí mismo
    $avActivos = @($script:Antivirus | Where-Object { $_.Activo })
    if ($script:Antivirus.Count -and $avActivos.Count -eq 0) {
        [void]$lista.Add(@{ Nivel = "Problema"; Titulo = "No hay ningún antivirus activo"; Detalle = "Activa Microsoft Defender o tu antivirus."; Accion = "Seguridad" })
    } elseif (@($avActivos | Where-Object { -not $_.AlDia }).Count) {
        [void]$lista.Add(@{ Nivel = "Atencion"; Titulo = "Las firmas del antivirus no están al día"; Detalle = "Actualízalo para que detecte las amenazas nuevas."; Accion = "Seguridad" })
    } elseif ($avActivos.Count) {
        [void]$lista.Add(@{ Nivel = "Bien"; Titulo = "Antivirus activo y al día"; Detalle = (($avActivos | ForEach-Object { $_.Nombre }) -join ", "); Accion = "" })
    }
    $sinAplicar = @($script:Ajustes | Where-Object {
        $_.Grupo -eq "Esenciales" -and $_.Riesgo -eq "Bajo" -and $_.Key -ne "WPFTweaksRestorePoint" -and
        (@($_.registry | Where-Object { $_ }).Count + @($_.service | Where-Object { $_ }).Count) -gt 0 -and
        -not $script:HechosSesion[$_.Key] -and -not (Test-AjusteAplicado $_)
    })
    if ($sinAplicar.Count) {
        [void]$lista.Add(@{ Nivel = "Atencion"; Titulo = "Hay $($sinAplicar.Count) ajuste(s) recomendados sin aplicar"; Detalle = "Son de riesgo bajo: telemetría, servicios y otros que restan rendimiento. Revísalos antes de aplicar."; Accion = "Recomendados" })
    }
    if (-not (Test-AjusteAplicado $script:ItemFondo)) {
        [void]$lista.Add(@{ Nivel = "Atencion"; Titulo = "Algunas apps pueden quedarse abiertas en segundo plano"; Detalle = "Edge, Chrome, Widgets y apps de la Tienda siguen gastando RAM aunque cierres la ventana."; Accion = "Fondo" })
    }

    $problemas = @($lista | Where-Object { $_.Nivel -eq "Problema" }).Count
    $atencion = @($lista | Where-Object { $_.Nivel -eq "Atencion" }).Count
    $puntos = [math]::Max(5, 100 - 20 * $problemas - 7 * $atencion)
    $colorPuntos = if ($puntos -ge 80) { "#16A34A" } elseif ($puntos -ge 55) { "#D97706" } else { "#DC2626" }
    $textoPuntos = if ($puntos -ge 80) { "Bien" } elseif ($puntos -ge 55) { "Mejorable" } else { "Necesita atención" }
    Set-Indicador $script:IndSalud "$puntos / 100" $puntos $textoPuntos $colorPuntos

    $met = $global:Estado.Metricas
    if ($met.DiscoTxt) { Set-Indicador $script:IndDisco "$($met.DiscoPct) % usado" ([int]$met.DiscoPct) $met.DiscoTxt }
    if ($met.Encendido) { Set-Indicador $script:IndEncendido $met.Encendido -1 "$($met.Arranque) programa(s) al iniciar" }
    Update-IndicadorRam

    $script:TxtResumenAnalisis.Text = if ($problemas -eq 0 -and $atencion -eq 0) { "Todo en orden: no hay nada importante que arreglar." }
        else { "Recomendaciones: $problemas problema(s) y $atencion aviso(s)" }
    $script:PanelHallazgos.Children.Clear()
    foreach ($nivel in "Problema", "Atencion", "Bien") {
        foreach ($h in @($lista | Where-Object { $_.Nivel -eq $nivel })) {
            [void]$script:PanelHallazgos.Children.Add((New-TarjetaHallazgo $h))
        }
    }
}

# ---------------------------------------------------------------- Pestaña RAM y disco
$pR = $script:UI.PanelRendimiento
[void]$pR.Children.Add((New-Titulo "Memoria RAM" "Windows usa la RAM libre como caché, así que verla ocupada no siempre es malo. Lo que de verdad ayuda es que haya menos programas abiertos y arrancando solos."))

$marcoRam = New-Object System.Windows.Controls.Border
$marcoRam.Background = Get-Pincel "#FFFFFF"
$marcoRam.BorderBrush = Get-Pincel "#E2E6EC"
$marcoRam.BorderThickness = 1
$marcoRam.CornerRadius = 10
$marcoRam.Padding = "16,12"
$marcoRam.Margin = "0,0,0,10"
$pilaRam = New-Object System.Windows.Controls.StackPanel
$script:TxtRamGrande = New-Object System.Windows.Controls.TextBlock
$script:TxtRamGrande.FontSize = 20
$script:TxtRamGrande.FontWeight = "SemiBold"
[void]$pilaRam.Children.Add($script:TxtRamGrande)
$script:BarraRam = New-Object System.Windows.Controls.ProgressBar
$script:BarraRam.Height = 10
$script:BarraRam.Margin = "0,8,0,6"
$script:BarraRam.BorderThickness = 0
$script:BarraRam.Background = Get-Pincel "#E5E7EB"
[void]$pilaRam.Children.Add($script:BarraRam)
$script:TxtRamDetalle = New-Object System.Windows.Controls.TextBlock
$script:TxtRamDetalle.Foreground = Get-Pincel "#6B7280"
[void]$pilaRam.Children.Add($script:TxtRamDetalle)
$marcoRam.Child = $pilaRam
[void]$pR.Children.Add($marcoRam)

function Update-IndicadorRam {
    try {
        $osRam = Get-CimInstance Win32_OperatingSystem -Property TotalVisibleMemorySize, FreePhysicalMemory -ErrorAction Stop
    } catch { return }
    $totalRam = [math]::Round($osRam.TotalVisibleMemorySize / 1MB, 1)
    $libreRam = [math]::Round($osRam.FreePhysicalMemory / 1MB, 1)
    $usoRam = [math]::Round($totalRam - $libreRam, 1)
    $pctUso = [int][math]::Round(100 * $usoRam / [math]::Max($totalRam, 0.1))
    Set-Indicador $script:IndRam "$pctUso %" $pctUso "$usoRam de $totalRam GB en uso"
    $script:TxtRamGrande.Text = "$usoRam GB en uso de $totalRam GB ($pctUso %)"
    $script:BarraRam.Value = $pctUso
    $script:BarraRam.Foreground = Get-Pincel (Get-ColorUso $pctUso)
    $script:TxtRamDetalle.Text = "Disponible: $libreRam GB. Se actualiza solo cada pocos segundos."
}

New-TarjetaAccion -Panel $pR -Titulo "Liberar RAM ahora" -TextoBoton "Liberar" -Riesgo "Bajo" `
    -Descripcion "Vacía la caché en espera y recorta la memoria que los programas tienen reservada sin usar. No cierra nada." `
    -Aviso "El efecto es temporal: los programas vuelven a tomar memoria cuando los usas." -Accion { Invoke-AccionAnalisis "LiberarRAM" }

New-TarjetaAccion -Panel $pR -Titulo "Programas abiertos que más RAM usan" -TextoBoton "Ver lista" -Riesgo "Bajo" `
    -Descripcion "Muestra los programas que más memoria ocupan, qué es cada uno, qué pasa si lo cierras y un botón para cerrarlo." `
    -Aviso "Al cerrar un programa se pierde lo que no esté guardado en él." -Accion { Update-ListaProcesos }
$script:PanelProcesos = New-Object System.Windows.Controls.StackPanel
$script:PanelProcesos.Margin = "0,0,0,8"
[void]$pR.Children.Add($script:PanelProcesos)

New-TarjetaAccion -Panel $pR -Clave "OPT_FONDO" -Titulo "Evitar apps en segundo plano" -TextoBoton "Aplicar" -TextoBoton2 "Deshacer" -Riesgo "Bajo" `
    -Origen $script:ItemFondo -Detalle "Se aplican directivas (las mismas que usan las empresas) para que estas apps no sigan en memoria al cerrarlas. Antes de aplicar se guarda cómo estaba cada valor; 'Deshacer' lo deja exactamente igual que antes. Se nota del todo tras reiniciar." `
    -Descripcion "Edge y Chrome dejan de quedarse abiertos al cerrar la ventana y Edge no se precarga al encender. También se apagan los Widgets y las apps de la Tienda en segundo plano." `
    -Aviso "Edge y Chrome dirán 'Administrado por tu organización': es por estas políticas. Las apps de la Tienda no avisarán hasta que las abras." `
    -Accion { Invoke-AccionAnalisis "Fondo" } `
    -Accion2 { Start-Pasos -Pasos @([pscustomobject]@{ Item = $script:ItemFondo; Deshacer = $true }) -Titulo "Deshacer: apps en segundo plano" }

New-TarjetaAccion -Panel $pR -Clave "OPT_SERVICIOS_RAM" -Titulo "Servicios que no hacen falta siempre" -TextoBoton "Poner en manual" -TextoBoton2 "Deshacer" -Riesgo "Bajo" `
    -Origen $script:ItemServiciosRam -Detalle "DiagTrack y dmwappushservice: telemetría. MapsBroker: mapas sin conexión. RetailDemo: modo tienda. Fax. WerSvc: informe de errores. PcaSvc: asistente de compatibilidad. En 'manual' no se borran ni se desactivan: Windows los arranca si algo los pide. Se guarda cómo estaban y 'Deshacer' los deja igual." `
    -Descripcion "Telemetría, mapas sin conexión, fax, modo tienda, informe de errores y asistente de compatibilidad pasan a manual: solo arrancan si algo los necesita." `
    -Aviso "Ninguno para el uso normal. Se guarda cómo estaban para poder deshacerlo exacto." `
    -Accion { Start-Pasos -Pasos @([pscustomobject]@{ Item = $script:ItemServiciosRam; Deshacer = $false }) -Titulo "Servicios en manual" } `
    -Accion2 { Start-Pasos -Pasos @([pscustomobject]@{ Item = $script:ItemServiciosRam; Deshacer = $true }) -Titulo "Deshacer: servicios en manual" }

New-TarjetaAccion -Panel $pR -Titulo "Memoria virtual en automático" -TextoBoton "Arreglar" -Riesgo "Bajo" `
    -Descripcion "Deja el archivo de paginación administrado por Windows. Quitarlo no da más RAM: hace que los programas se cierren solos cuando se llena." `
    -Aviso "" -Accion { Invoke-AccionAnalisis "Paginacion" }

[void]$pR.Children.Add((New-Titulo "Espacio en disco" "Para cuando el disco C: se queda sin espacio."))
New-TarjetaAccion -Panel $pR -Titulo "Borrar archivos temporales" -TextoBoton "Limpiar" -Riesgo "Bajo" `
    -Descripcion "Vacía las carpetas TEMP de tu usuario y de Windows." `
    -Aviso "Cierra tus programas antes: un instalador o documento abierto que use TEMP podría fallar." -Accion { Invoke-AccionAnalisis "Temporales" }
New-TarjetaAccion -Panel $pR -Titulo "Liberador de espacio de Windows" -TextoBoton "Abrir" -Riesgo "Bajo" `
    -Descripcion "La herramienta de Windows para borrar la papelera, miniaturas y restos de actualizaciones. Tú eliges qué borrar." `
    -Aviso "" -Accion { Start-Process "cleanmgr.exe" -ArgumentList "/d C:" }
New-TarjetaAccion -Panel $pR -Titulo "Ver qué ocupa espacio" -TextoBoton "Abrir" -Riesgo "Bajo" `
    -Descripcion "Abre Configuración > Almacenamiento, con el espacio por categorías y el Sensor de almacenamiento." `
    -Aviso "" -Accion { Start-Process "ms-settings:storagesense" }

[void]$pR.Children.Add((New-Titulo "Arranque" "Menos programas al encender = arranque más rápido y más RAM libre."))
New-TarjetaAccion -Panel $pR -Titulo "Programas que arrancan con Windows" -TextoBoton "Abrir" -TextoBoton2 "Ver lista" -Riesgo "Bajo" `
    -Descripcion "Abre la pestaña 'Arranque de Windows', con todo lo que se inicia solo, su firma y un botón para desactivarlo. 'Ver lista' los escribe en el registro de abajo." `
    -Aviso "No desactives el antivirus ni los controladores de audio, touchpad o gráficos." `
    -Accion { Select-Pestana "TabArranque" } `
    -Accion2 { Start-Pasos -Pasos @(New-PasoScript -Nombre "Programas de arranque" -Codigo $script:codigoArranque) }

$script:Protegidos = @(
    "System", "Idle", "Registry", "smss", "csrss", "wininit", "winlogon", "services", "lsass", "svchost", "dwm",
    "explorer", "fontdrvhost", "Memory Compression", "sihost", "ctfmon", "taskhostw", "RuntimeBroker", "SearchHost",
    "StartMenuExperienceHost", "ShellExperienceHost", "TextInputHost", "audiodg", "conhost", "powershell", "pwsh",
    "WindowsTerminal", "OpenConsole", "MsMpEng", "NisSrv", "SecurityHealthService", "SecurityHealthSystray",
    "ekrn", "egui", "eguiProxy", "spoolsv", "WmiPrvSE", "dllhost", "LsaIso", "SgrmBroker", "MpDefenderCoreService",
    "Claude", "claude", "LockApp", "SearchApp", "SearchIndexer", "smartscreen", "PhoneExperienceHost"
)

# Qué es cada programa conocido y qué pasa si lo cierras.
# Consejo: "Cerrar" (se puede cerrar sin problema), "Cuidado" (se puede, pero algo deja de funcionar), "No" (mejor no cerrarlo)
$script:ProgramasConocidos = @{
    "msedgewebview2"        = @{ Nombre = "Microsoft Edge WebView2"; Que = "Motor de Edge que usan por dentro otras apps: Widgets, Teams, Outlook nuevo, WhatsApp, Logitech Options+ y muchas más. Cada app abre el suyo, por eso ocupa tanto."; Consejo = "Cuidado"; Efecto = "Las apps que lo usan pueden quedarse en blanco o cerrarse. Mejor cierra esas apps." }
    "WhatsApp.Root"         = @{ Nombre = "WhatsApp"; Que = "WhatsApp de escritorio, que sigue abierto en segundo plano para avisarte de mensajes."; Consejo = "Cerrar"; Efecto = "Dejarás de recibir avisos de WhatsApp en la PC hasta que lo abras." }
    "WhatsApp"              = @{ Nombre = "WhatsApp"; Que = "WhatsApp de escritorio."; Consejo = "Cerrar"; Efecto = "Dejarás de recibir avisos de WhatsApp en la PC hasta que lo abras." }
    "logioptionsplus_agent" = @{ Nombre = "Logitech Options+"; Que = "Programa de Logitech que da funciones a los botones extra del mouse o teclado."; Consejo = "Cuidado"; Efecto = "Los botones personalizados y gestos del mouse/teclado Logitech dejan de funcionar hasta reiniciar." }
    "ShellHost"             = @{ Nombre = "Shell de Windows"; Que = "Parte de Windows 11: dibuja la barra de tareas, Acciones rápidas y el área de notificaciones."; Consejo = "No"; Efecto = "La barra de tareas y el panel de Wi-Fi/volumen pueden dejar de responder." }
    "CrossDeviceResume"     = @{ Nombre = "Continuar desde el móvil (Windows)"; Que = "Función de Windows 11 para seguir en la PC lo que hacías en el teléfono."; Consejo = "Cerrar"; Efecto = "Ninguno si no usas 'Vincular móvil'. Windows lo vuelve a abrir si hace falta." }
    "RustDesk"              = @{ Nombre = "RustDesk"; Que = "Programa de escritorio remoto (para que alguien se conecte a esta PC o tú a otra)."; Consejo = "Cuidado"; Efecto = "Nadie podrá conectarse a esta PC por RustDesk hasta que lo abras de nuevo." }
    "chrome"                = @{ Nombre = "Google Chrome"; Que = "Navegador. Cada pestaña y extensión es un proceso aparte; aquí se suman todos."; Consejo = "Cerrar"; Efecto = "Se cierran todas las ventanas de Chrome. Al abrirlo puedes recuperar las pestañas." }
    "msedge"                = @{ Nombre = "Microsoft Edge"; Que = "Navegador. Cada pestaña y extensión es un proceso aparte."; Consejo = "Cerrar"; Efecto = "Se cierran todas las ventanas de Edge." }
    "firefox"               = @{ Nombre = "Firefox"; Que = "Navegador."; Consejo = "Cerrar"; Efecto = "Se cierran todas las ventanas de Firefox." }
    "opera"                 = @{ Nombre = "Opera"; Que = "Navegador."; Consejo = "Cerrar"; Efecto = "Se cierran todas las ventanas de Opera." }
    "Teams"                 = @{ Nombre = "Microsoft Teams"; Que = "Chat y reuniones de Microsoft."; Consejo = "Cerrar"; Efecto = "No recibirás mensajes ni llamadas de Teams hasta abrirlo." }
    "ms-teams"              = @{ Nombre = "Microsoft Teams"; Que = "Chat y reuniones de Microsoft."; Consejo = "Cerrar"; Efecto = "No recibirás mensajes ni llamadas de Teams hasta abrirlo." }
    "OneDrive"              = @{ Nombre = "OneDrive"; Que = "Sincroniza tus archivos con la nube de Microsoft."; Consejo = "Cuidado"; Efecto = "Los archivos dejan de subirse a la nube hasta que lo abras." }
    "Spotify"               = @{ Nombre = "Spotify"; Que = "Música."; Consejo = "Cerrar"; Efecto = "Se para la música." }
    "Discord"               = @{ Nombre = "Discord"; Que = "Chat y voz."; Consejo = "Cerrar"; Efecto = "Sales de las llamadas y no recibes mensajes." }
    "Code"                  = @{ Nombre = "Visual Studio Code"; Que = "Editor de código."; Consejo = "Cuidado"; Efecto = "Guarda tus archivos antes de cerrarlo." }
    "Photoshop"             = @{ Nombre = "Adobe Photoshop"; Que = "Editor de imágenes."; Consejo = "Cuidado"; Efecto = "Guarda tu trabajo antes: lo no guardado se pierde." }
    "Illustrator"           = @{ Nombre = "Adobe Illustrator"; Que = "Editor de diseño."; Consejo = "Cuidado"; Efecto = "Guarda tu trabajo antes: lo no guardado se pierde." }
    "AdobeCollabSync"       = @{ Nombre = "Adobe Acrobat (sincronización)"; Que = "Sincroniza documentos de Acrobat en segundo plano."; Consejo = "Cerrar"; Efecto = "Ninguno importante." }
    "Creative Cloud"        = @{ Nombre = "Adobe Creative Cloud"; Que = "Gestor de apps y fuentes de Adobe."; Consejo = "Cuidado"; Efecto = "Las fuentes de Adobe sincronizadas pueden dejar de verse en tus programas." }
    "PhoneExperienceHost"   = @{ Nombre = "Vincular móvil"; Que = "Conecta tu teléfono con Windows (mensajes, llamadas, fotos)."; Consejo = "Cerrar"; Efecto = "No verás notificaciones del teléfono en la PC hasta abrirlo." }
    "Widgets"               = @{ Nombre = "Widgets de Windows"; Que = "Panel de noticias y tiempo."; Consejo = "Cerrar"; Efecto = "Ninguno; se vuelve a abrir si pulsas el botón de Widgets." }
    "WidgetService"         = @{ Nombre = "Widgets de Windows"; Que = "Servicio del panel de noticias y tiempo."; Consejo = "Cerrar"; Efecto = "Ninguno; se vuelve a abrir si pulsas el botón de Widgets." }
    "steam"                 = @{ Nombre = "Steam"; Que = "Tienda de juegos."; Consejo = "Cerrar"; Efecto = "No se descargan actualizaciones de juegos mientras esté cerrado." }
    "EpicGamesLauncher"     = @{ Nombre = "Epic Games"; Que = "Tienda de juegos."; Consejo = "Cerrar"; Efecto = "Ninguno importante." }
    "AnyDesk"               = @{ Nombre = "AnyDesk"; Que = "Escritorio remoto."; Consejo = "Cuidado"; Efecto = "Nadie podrá conectarse a esta PC por AnyDesk." }
    "TeamViewer"            = @{ Nombre = "TeamViewer"; Que = "Escritorio remoto."; Consejo = "Cuidado"; Efecto = "Nadie podrá conectarse a esta PC por TeamViewer." }
    "Zoom"                  = @{ Nombre = "Zoom"; Que = "Videollamadas."; Consejo = "Cerrar"; Efecto = "Sales de la reunión si estás en una." }
    "OUTLOOK"               = @{ Nombre = "Outlook"; Que = "Correo."; Consejo = "Cuidado"; Efecto = "Dejas de recibir correos hasta abrirlo. Guarda los borradores." }
    "olk"                   = @{ Nombre = "Outlook (nuevo)"; Que = "Correo."; Consejo = "Cuidado"; Efecto = "Dejas de recibir avisos de correo hasta abrirlo." }
    "WINWORD"               = @{ Nombre = "Word"; Que = "Documentos."; Consejo = "Cuidado"; Efecto = "Guarda antes: lo no guardado se pierde." }
    "EXCEL"                 = @{ Nombre = "Excel"; Que = "Hojas de cálculo."; Consejo = "Cuidado"; Efecto = "Guarda antes: lo no guardado se pierde." }
    "POWERPNT"              = @{ Nombre = "PowerPoint"; Que = "Presentaciones."; Consejo = "Cuidado"; Efecto = "Guarda antes: lo no guardado se pierde." }
    "Docker Desktop"        = @{ Nombre = "Docker Desktop"; Que = "Contenedores para desarrollo."; Consejo = "Cuidado"; Efecto = "Se detienen los contenedores que tengas corriendo." }
    "vmmem"                 = @{ Nombre = "Máquina virtual (WSL / Docker)"; Que = "Memoria de WSL o Docker."; Consejo = "Cuidado"; Efecto = "Se apagan WSL y Docker. Mejor ciérralos desde su programa." }
    "mysqld"                = @{ Nombre = "Servidor MySQL"; Que = "Base de datos."; Consejo = "Cuidado"; Efecto = "Las apps que usan esa base de datos dejan de funcionar." }
    "sqlservr"              = @{ Nombre = "SQL Server"; Que = "Base de datos."; Consejo = "Cuidado"; Efecto = "Las apps que usan esa base de datos dejan de funcionar." }
    "node"                  = @{ Nombre = "Node.js"; Que = "Programa o servidor de desarrollo en JavaScript."; Consejo = "Cuidado"; Efecto = "Se detiene ese servidor o herramienta." }
    "php"                   = @{ Nombre = "PHP"; Que = "Servidor o script de PHP (por ejemplo, un proyecto Laravel)."; Consejo = "Cuidado"; Efecto = "Se detiene ese servidor." }
}

function Get-InfoPrograma($Grupo) {
    $conocido = $script:ProgramasConocidos[[string]$Grupo.Proc]
    $ruta = ""; $desc = ""; $empresa = ""
    foreach ($p in $Grupo.Procesos) {
        try {
            if ($p.Path) {
                $ruta = $p.Path
                $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ruta)
                $desc = ([string]$vi.FileDescription).Trim()
                $empresa = ([string]$vi.CompanyName).Trim()
                break
            }
        } catch { }
    }
    $deWindows = $ruta -and $ruta.StartsWith($env:SystemRoot, [System.StringComparison]::OrdinalIgnoreCase)
    if ($conocido) {
        return [pscustomobject]@{ Nombre = $conocido.Nombre; Que = $conocido.Que; Consejo = $conocido.Consejo; Efecto = $conocido.Efecto; Empresa = $empresa; Ruta = $ruta; DeWindows = $deWindows }
    }
    $nombreBonito = if ($desc) { $desc } else { $Grupo.Proc }
    if ($deWindows) {
        return [pscustomobject]@{ Nombre = $nombreBonito; Que = "Componente de Windows."; Consejo = "No"; Efecto = "Puede fallar alguna función de Windows; se vuelve a abrir solo."; Empresa = $empresa; Ruta = $ruta; DeWindows = $true }
    }
    $de = if ($empresa) { "Programa de $empresa." } else { "Programa sin descripción del fabricante." }
    $efecto = if ($Grupo.Abierta) { "Se cierra su ventana; guarda antes lo que tengas abierto." } else { "Si es de un programa que no usas ahora, cerrarlo no causa problemas. Si no lo reconoces, búscalo en Internet." }
    return [pscustomobject]@{ Nombre = $nombreBonito; Que = $de; Consejo = "Cuidado"; Efecto = $efecto; Empresa = $empresa; Ruta = $ruta; DeWindows = $false }
}

function Update-ListaProcesos {
    $script:PanelProcesos.Children.Clear()
    $sesion = (Get-Process -Id $PID).SessionId
    $grupos = @(Get-Process | Where-Object { $_.SessionId -eq $sesion -and $script:Protegidos -notcontains $_.ProcessName } |
        Group-Object ProcessName | ForEach-Object {
            $ventanaAbierta = @($_.Group | Where-Object { $_.MainWindowTitle } | Select-Object -First 1)
            [pscustomobject]@{
                Proc = $_.Name
                MB = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB)
                Ids = @($_.Group | ForEach-Object { $_.Id })
                Procesos = @($_.Group)
                Abierta = if ($ventanaAbierta.Count) { $ventanaAbierta[0].MainWindowTitle } else { "" }
            }
        } | Where-Object { $_.MB -ge 50 } | Sort-Object MB -Descending | Select-Object -First 15)
    $leyenda = New-Object System.Windows.Controls.TextBlock
    $leyenda.TextWrapping = "Wrap"
    $leyenda.Foreground = Get-Pincel "#6B7280"
    $leyenda.Margin = "16,0,0,6"
    $leyenda.Text = "Verde: se puede cerrar sin problema.  Naranja: se puede, pero algo deja de funcionar (lee el aviso).  Rojo: parte de Windows, mejor no cerrarlo. Lo que cierres se vuelve a abrir al reiniciar si está en el arranque."
    [void]$script:PanelProcesos.Children.Add($leyenda)
    if ($grupos.Count -eq 0) {
        $vacio = New-Object System.Windows.Controls.TextBlock
        $vacio.Text = "No hay programas grandes abiertos."
        $vacio.Margin = "16,0,0,6"
        [void]$script:PanelProcesos.Children.Add($vacio)
        return
    }
    $colores = @{
        Cerrar  = @{ Color = "#16A34A"; Texto = "Se puede cerrar" }
        Cuidado = @{ Color = "#D97706"; Texto = "Cerrar con cuidado" }
        No      = @{ Color = "#DC2626"; Texto = "Mejor no cerrarlo" }
    }
    foreach ($g in $grupos) {
        $info = Get-InfoPrograma $g
        $col = $colores[$info.Consejo]
        $marco = New-Object System.Windows.Controls.Border
        $marco.Background = Get-Pincel "#FFFFFF"
        $marco.BorderBrush = Get-Pincel $col.Color
        $marco.BorderThickness = "4,1,1,1"
        $marco.CornerRadius = 6
        $marco.Padding = "12,8"
        $marco.Margin = "16,0,0,6"
        $fila = New-Object System.Windows.Controls.DockPanel
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = "Cerrar"
        $btn.Padding = "12,3"
        $btn.Margin = "10,0,0,0"
        $btn.VerticalAlignment = "Center"
        $btn.Tag = [pscustomobject]@{ Grupo = $g; Info = $info }
        $btn.Add_Click({
            param($origen, $e)
            $p = $origen.Tag.Grupo
            $inf = $origen.Tag.Info
            $icono = if ($inf.Consejo -eq "Cerrar") { "Question" } else { "Warning" }
            $msg = "¿Cerrar $($inf.Nombre) ($($p.Proc))?`r`n`r`nQué pasa: $($inf.Efecto)`r`n`r`nLo que no esté guardado en ese programa se pierde."
            if ($inf.Consejo -eq "No") { $msg = "$([char]0x26A0) Es parte de Windows. Cerrarlo no ahorra RAM de verdad: Windows lo vuelve a abrir.`r`n`r`n" + $msg }
            if ([System.Windows.MessageBox]::Show($msg, "Cerrar programa", "YesNo", $icono) -ne "Yes") { return }
            foreach ($id in $p.Ids) { try { [void](Get-Process -Id $id -ErrorAction Stop).CloseMainWindow() } catch { } }
            Start-Sleep -Milliseconds 1200
            foreach ($id in $p.Ids) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch { } }
            Escribir-Log "Cerrado: $($inf.Nombre) ($($p.Proc), $($p.MB) MB)"
            Update-ListaProcesos
            Update-IndicadorRam
        })
        [System.Windows.Controls.DockPanel]::SetDock($btn, "Right")
        [void]$fila.Children.Add($btn)
        $pila = New-Object System.Windows.Controls.StackPanel
        $cab = New-Object System.Windows.Controls.TextBlock
        $cab.TextWrapping = "Wrap"
        $mbTxt = if ($g.MB -ge 1024) { "{0:N1} GB" -f ($g.MB / 1024) } else { "$($g.MB) MB" }
        $run1 = New-Object System.Windows.Documents.Run ($info.Nombre)
        $run1.FontWeight = "SemiBold"
        [void]$cab.Inlines.Add($run1)
        $run2 = New-Object System.Windows.Documents.Run ("   $mbTxt   ·   " + $(if ($g.Abierta) { "ventana abierta: $($g.Abierta)" } else { "en segundo plano" }))
        $run2.Foreground = Get-Pincel "#6B7280"
        [void]$cab.Inlines.Add($run2)
        [void]$pila.Children.Add($cab)
        $que = New-Object System.Windows.Controls.TextBlock
        $que.TextWrapping = "Wrap"
        $que.Foreground = Get-Pincel "#374151"
        $que.Margin = "0,2,0,0"
        $que.Text = $info.Que
        [void]$pila.Children.Add($que)
        $consejo = New-Object System.Windows.Controls.TextBlock
        $consejo.TextWrapping = "Wrap"
        $consejo.Foreground = Get-Pincel $col.Color
        $consejo.Margin = "0,2,0,0"
        $consejo.Text = "$($col.Texto): $($info.Efecto)"
        [void]$pila.Children.Add($consejo)
        $tec = New-Object System.Windows.Controls.TextBlock
        $tec.TextWrapping = "Wrap"
        $tec.Foreground = Get-Pincel "#9CA3AF"
        $tec.FontSize = 11
        $tec.Margin = "0,2,0,0"
        $tec.Text = "Proceso: $($g.Proc).exe ($($g.Ids.Count) proceso(s))" + $(if ($info.Ruta) { "   ·   $($info.Ruta)" } else { "" })
        [void]$pila.Children.Add($tec)
        [void]$fila.Children.Add($pila)
        $marco.Child = $fila
        [void]$script:PanelProcesos.Children.Add($marco)
    }
}

function Update-EstadoRendimiento {
    foreach ($par in @(@($script:ItemFondo, "Aplicado en este equipo"), @($script:ItemServiciosRam, "Ya están en manual"))) {
        $t = $script:TarjetaPorId[$par[0].Key]
        if (-not $t) { continue }
        if (Test-AjusteAplicado $par[0]) {
            $t.Estado.Text = "$([char]0x2714) $($par[1])"
            $t.Estado.Foreground = Get-Pincel "#16A34A"
            $t.Estado.Visibility = "Visible"
        } else {
            $t.Estado.Visibility = "Collapsed"
        }
    }
}
Update-EstadoRendimiento
Update-IndicadorRam

# ---------------------------------------------------------------- Pestaña Controladores
$script:codigoBuscarDrivers = @'
Write-Output "Buscando controladores nuevos en Windows Update (1 a 3 minutos)..."
$sesionWU = New-Object -ComObject Microsoft.Update.Session
$sesionWU.ClientApplicationID = "OptimizadorES"
$buscador = $sesionWU.CreateUpdateSearcher()
$buscador.ServerSelection = 2
$resultado = $buscador.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
foreach ($u in $resultado.Updates) {
    $fecha = try { ([datetime]$u.DriverVerDate).ToString("yyyy-MM-dd") } catch { "" }
    [void]$global:Estado.Drivers.Add(@{
        Id = [string]$u.Identity.UpdateID; Titulo = [string]$u.Title; Clase = [string]$u.DriverClass
        Fabricante = [string]$u.DriverManufacturer; Modelo = [string]$u.DriverModel; Fecha = $fecha
        MB = [math]::Round([double]$u.MaxDownloadSize / 1MB, 1)
    })
    Write-Output " - $($u.Title)"
}
if ($resultado.Updates.Count -eq 0) { Write-Output "Windows Update no tiene controladores nuevos para este equipo." }
else { Write-Output "Encontrados: $($resultado.Updates.Count). Marca los que quieras en la pestaña Controladores y pulsa 'Instalar seleccionados'." }
'@

function Get-CodigoInstalarDrivers([string[]]$Ids) {
    $lista = ($Ids | ForEach-Object { "'$_'" }) -join ","
    return @"
`$ids = @($lista)
Write-Output "Creando punto de restauración antes de instalar controladores..."
try {
    Enable-ComputerRestore -Drive "`$env:SystemDrive\" -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description "OptimizadorES - controladores" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    Write-Output "Punto de restauración creado."
} catch { Write-Warning "No se pudo crear el punto de restauración (Windows solo permite uno cada 24 h): `$(`$_.Exception.Message)" }
`$sesionWU = New-Object -ComObject Microsoft.Update.Session
`$sesionWU.ClientApplicationID = "OptimizadorES"
`$buscador = `$sesionWU.CreateUpdateSearcher()
`$buscador.ServerSelection = 2
`$resultado = `$buscador.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
`$elegidos = @(foreach (`$u in `$resultado.Updates) { if (`$ids -contains [string]`$u.Identity.UpdateID) { `$u } })
if (`$elegidos.Count -eq 0) { Write-Warning "Los controladores elegidos ya no aparecen como pendientes (quizá ya se instalaron)."; return }
`$reiniciar = `$false
`$n = 0
foreach (`$u in `$elegidos) {
    `$n++
    `$global:Estado.Texto = "Controlador `$n de `$(`$elegidos.Count): `$(`$u.Title)"
    `$global:Estado.Progreso = [int](100 * (`$n - 1) / `$elegidos.Count)
    if (-not `$u.EulaAccepted) { `$u.AcceptEula() }
    `$uno = New-Object -ComObject Microsoft.Update.UpdateColl
    [void]`$uno.Add(`$u)
    Write-Output "Descargando (`$n/`$(`$elegidos.Count)): `$(`$u.Title)"
    `$descarga = `$sesionWU.CreateUpdateDownloader()
    `$descarga.Updates = `$uno
    `$rd = `$descarga.Download()
    if (`$rd.ResultCode -ne 2) { Write-Warning "No se pudo descargar (código `$(`$rd.ResultCode))."; continue }
    Write-Output "Instalando..."
    `$instalador = `$sesionWU.CreateUpdateInstaller()
    `$instalador.Updates = `$uno
    `$ri = `$instalador.Install()
    if (`$ri.ResultCode -eq 2) {
        Write-Output "Instalado: `$(`$u.Title)"
        if (`$ri.RebootRequired) { `$reiniciar = `$true }
    } else {
        Write-Warning "Falló la instalación de `$(`$u.Title) (código `$(`$ri.ResultCode))."
    }
}
if (`$reiniciar) { Write-Output "Hay que REINICIAR el equipo para terminar de instalar." }
"@
}

$script:codigoCopiaDrivers = @'
$destino = Join-Path $env:LOCALAPPDATA ("OptimizadorES\Controladores_{0:yyyyMMdd_HHmm}" -f (Get-Date))
New-Item -ItemType Directory -Force -Path $destino | Out-Null
Write-Output "Copiando los controladores que no son de Microsoft a $destino (1 a 5 minutos)..."
$copiados = @(Export-WindowsDriver -Online -Destination $destino -ErrorAction Stop)
Write-Output "Copiados $($copiados.Count) controladores."
Write-Output "Para reinstalar uno: Administrador de dispositivos > clic derecho > Actualizar controlador > Buscar en mi equipo > esta carpeta."
Start-Process explorer.exe -ArgumentList "`"$destino`""
'@

$script:codigoListaDrivers = @'
$lista = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DriverProviderName -and $_.DriverProviderName -notmatch "^Microsoft" -and $_.DeviceName } |
    Sort-Object DriverDate)
Write-Output "Controladores de otros fabricantes instalados: $($lista.Count) (los más antiguos primero)"
foreach ($d in $lista) {
    $fecha = if ($d.DriverDate) { ([datetime]$d.DriverDate).ToString("yyyy-MM-dd") } else { "sin fecha" }
    Write-Output ("{0}  {1}  v{2}  ({3})" -f $fecha, $d.DeviceName, $d.DriverVersion, $d.DriverProviderName)
}
'@

$script:ErroresDispositivo = @{
    1 = "no está bien configurado"; 3 = "el controlador está dañado o falta memoria"; 10 = "no puede iniciarse"
    12 = "no encuentra recursos libres"; 14 = "necesita reiniciar"; 18 = "hay que reinstalar el controlador"
    19 = "el registro de su configuración está dañado"; 21 = "Windows lo está quitando"; 24 = "no está presente o falta el controlador"
    28 = "no tiene controlador instalado"; 31 = "el controlador no se carga"; 39 = "el controlador está dañado o falta"
    43 = "Windows lo detuvo porque informó problemas"; 45 = "no está conectado"; 52 = "la firma del controlador no es válida"
}

$script:DetallesAcciones["Dispositivos con problemas"] = "'Revisar' consulta a Windows (Win32_PnPEntity) qué dispositivos tienen un código de error y explica cada uno en palabras normales. Los que desactivaste a propósito no salen. 'Administrador de dispositivos' abre la herramienta de Windows. No cambia nada."
$script:DetallesAcciones["Buscar controladores nuevos (Windows Update)"] = "1. 'Buscar' pregunta a Windows Update (los mismos servidores que usa Configuración) por controladores no instalados para tus dispositivos. Solo busca, no instala.`n2. Aparece la lista con tipo, fabricante, fecha y tamaño. Desmarca los que no quieras.`n3. 'Instalar seleccionados': intenta crear un punto de restauración, descarga e instala uno por uno y avisa si hay que reiniciar.`nSi un controlador nuevo da problemas: Administrador de dispositivos > el dispositivo > Propiedades > Controlador > Revertir al controlador anterior."
$script:DetallesAcciones["Copia de seguridad de controladores"] = "Ejecuta 'Export-WindowsDriver -Online': copia todos los controladores de otros fabricantes (no los de Microsoft) a %LOCALAPPDATA%\OptimizadorES\Controladores_fecha y abre la carpeta. Cópiala a una USB si vas a formatear. No cambia nada del equipo."
$script:DetallesAcciones["Ver controladores instalados"] = "Lee la lista de controladores firmados (Win32_PnPSignedDriver), quita los de Microsoft y escribe en el registro fecha, dispositivo, versión y fabricante, empezando por los más antiguos. Solo lee."
$pD = $script:UI.PanelControladores
[void]$pD.Children.Add((New-Titulo "Controladores" "Los controladores (drivers) hacen que Windows se entienda con cada pieza: gráficos, Wi-Fi, audio, touchpad... Aquí puedes ver si alguno falla, actualizarlos y guardar una copia."))

New-TarjetaAccion -Panel $pD -Titulo "Dispositivos con problemas" -TextoBoton "Revisar" -TextoBoton2 "Administrador de dispositivos" -Riesgo "Bajo" `
    -Descripcion "Muestra los dispositivos que Windows marca con error y qué les pasa." -Aviso "" `
    -Accion { Update-ListaDispositivos } -Accion2 { Start-Process "devmgmt.msc" }
$script:PanelDispositivos = New-Object System.Windows.Controls.StackPanel
$script:PanelDispositivos.Margin = "0,0,0,8"
[void]$pD.Children.Add($script:PanelDispositivos)

New-TarjetaAccion -Panel $pD -Titulo "Buscar controladores nuevos (Windows Update)" -TextoBoton "Buscar" -Riesgo "Medio" `
    -Descripcion "Pregunta a Windows Update si hay controladores más nuevos para tus dispositivos. Luego eliges cuáles instalar." `
    -Aviso "Un controlador nuevo puede dar problemas con algún equipo. Antes de instalar se intenta crear un punto de restauración, y puedes volver atrás desde el Administrador de dispositivos (Revertir controlador)." `
    -Accion {
        $global:Estado.Drivers = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        $script:PanelDrivers.Children.Clear()
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Buscar controladores" -Codigo $script:codigoBuscarDrivers) -Silencioso
        if ($script:Trabajo) { $script:AlTerminar = { Show-Drivers } }
    }
$script:PanelDrivers = New-Object System.Windows.Controls.StackPanel
$script:PanelDrivers.Margin = "0,0,0,8"
[void]$pD.Children.Add($script:PanelDrivers)

New-TarjetaAccion -Panel $pD -Titulo "Copia de seguridad de controladores" -TextoBoton "Copiar" -Riesgo "Bajo" `
    -Descripcion "Guarda una copia de todos los controladores que no son de Microsoft. Útil antes de actualizar o formatear." `
    -Aviso "" -Accion { Start-Pasos -Pasos @(New-PasoScript -Nombre "Copia de controladores" -Codigo $script:codigoCopiaDrivers) }

New-TarjetaAccion -Panel $pD -Titulo "Ver controladores instalados" -TextoBoton "Ver lista" -Riesgo "Bajo" `
    -Descripcion "Escribe en el registro de abajo los controladores de otros fabricantes con su fecha y versión, los más viejos primero." `
    -Aviso "" -Accion { Start-Pasos -Pasos @(New-PasoScript -Nombre "Lista de controladores" -Codigo $script:codigoListaDrivers) }

# Programa oficial del fabricante y de la tarjeta gráfica
$script:WebsFabricante = @(
    @{ Patron = "Dell";            Nombre = "Dell (SupportAssist / Dell Command Update)"; Url = "https://www.dell.com/support/home" },
    @{ Patron = "HP|Hewlett";      Nombre = "HP (HP Support Assistant)";                   Url = "https://support.hp.com/drivers" },
    @{ Patron = "Lenovo";          Nombre = "Lenovo (Lenovo Vantage / System Update)";     Url = "https://pcsupport.lenovo.com" },
    @{ Patron = "ASUS";            Nombre = "ASUS (MyASUS)";                               Url = "https://www.asus.com/support/download-center/" },
    @{ Patron = "Acer";            Nombre = "Acer (Acer Care Center)";                     Url = "https://www.acer.com/support" },
    @{ Patron = "Micro-Star|MSI";  Nombre = "MSI (MSI Center)";                            Url = "https://www.msi.com/support/download" },
    @{ Patron = "Microsoft";       Nombre = "Microsoft Surface";                           Url = "https://support.microsoft.com/surface" },
    @{ Patron = "Samsung";         Nombre = "Samsung (Samsung Update)";                    Url = "https://www.samsung.com/support/" },
    @{ Patron = "Toshiba|Dynabook";Nombre = "Dynabook / Toshiba";                          Url = "https://support.dynabook.com" }
)
$script:WebsGraficos = @(
    @{ Patron = "NVIDIA"; Nombre = "NVIDIA";  Url = "https://www.nvidia.com/Download/index.aspx" },
    @{ Patron = "AMD|Radeon"; Nombre = "AMD"; Url = "https://www.amd.com/en/support/download/drivers.html" },
    @{ Patron = "Intel";  Nombre = "Intel (Driver & Support Assistant)"; Url = "https://www.intel.com/content/www/us/en/support/detect.html" }
)
$fabricante = ""; $modelo = ""; $graficas = @()
try {
    $csD = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $fabricante = [string]$csD.Manufacturer; $modelo = [string]$csD.Model
    $graficas = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name })
} catch { }
$webFab = @($script:WebsFabricante | Where-Object { $fabricante -match $_.Patron })[0]
if ($webFab) {
    $script:UrlFabricante = $webFab.Url
    New-TarjetaAccion -Panel $pD -Titulo "Programa oficial de $($webFab.Nombre)" -TextoBoton "Abrir web" -Riesgo "Bajo" `
        -Descripcion "Tu equipo es $fabricante $modelo. La web del fabricante tiene los controladores exactos para tu modelo (BIOS, chipset, touchpad, teclas especiales...)." `
        -Aviso "" -Accion { Start-Process $script:UrlFabricante }
}
foreach ($w in $script:WebsGraficos) {
    $tarjetaGpu = @($graficas | Where-Object { $_ -match $w.Patron })[0]
    if (-not $tarjetaGpu) { continue }
    New-TarjetaAccion -Panel $pD -Titulo "Controlador de gráficos $($w.Nombre)" -TextoBoton "Abrir web" -Riesgo "Bajo" `
        -Descripcion "Tienes: $tarjetaGpu. El controlador del fabricante suele ser más nuevo que el de Windows Update (mejor para juegos y edición de vídeo)." `
        -Aviso "" -Accion ([scriptblock]::Create("Start-Process '$($w.Url)'"))
}

function Update-ListaDispositivos {
    $script:PanelDispositivos.Children.Clear()
    $malos = @(Get-CimInstance Win32_PnPEntity -Filter "ConfigManagerErrorCode <> 0 AND ConfigManagerErrorCode <> 22" -ErrorAction SilentlyContinue)
    $txt = New-Object System.Windows.Controls.TextBlock
    $txt.TextWrapping = "Wrap"
    $txt.Margin = "16,0,0,6"
    if ($malos.Count -eq 0) {
        $txt.Text = "$([char]0x2714) Todos los dispositivos funcionan bien."
        $txt.Foreground = Get-Pincel "#16A34A"
    } else {
        $lineas = foreach ($m in $malos) {
            $motivo = $script:ErroresDispositivo[[int]$m.ConfigManagerErrorCode]
            if (-not $motivo) { $motivo = "error $($m.ConfigManagerErrorCode)" }
            $nombreDisp = if ($m.Name) { $m.Name } else { $m.DeviceID }
            "$([char]0x26A0) ${nombreDisp}: $motivo"
        }
        $txt.Text = ($lineas -join "`n") + "`n`nPrueba primero 'Buscar controladores nuevos'. Si sigue igual, descarga el controlador de la web del fabricante."
        $txt.Foreground = Get-Pincel "#A85F00"
    }
    [void]$script:PanelDispositivos.Children.Add($txt)
}

function Show-Drivers {
    $script:PanelDrivers.Children.Clear()
    $script:CasillasDrivers = @()
    $lista = @($global:Estado.Drivers)
    if ($lista.Count -eq 0) {
        $txt = New-Object System.Windows.Controls.TextBlock
        $txt.Text = "$([char]0x2714) Windows Update no tiene controladores nuevos para este equipo."
        $txt.Foreground = Get-Pincel "#16A34A"
        $txt.Margin = "16,0,0,6"
        [void]$script:PanelDrivers.Children.Add($txt)
        return
    }
    foreach ($d in $lista) {
        $marco = New-Object System.Windows.Controls.Border
        $marco.Background = Get-Pincel "#FFFFFF"
        $marco.BorderBrush = Get-Pincel "#E2E6EC"
        $marco.BorderThickness = 1
        $marco.CornerRadius = 6
        $marco.Padding = "12,6"
        $marco.Margin = "16,0,0,4"
        $pila = New-Object System.Windows.Controls.StackPanel
        $chk = New-Object System.Windows.Controls.CheckBox
        $chk.Content = $d.Titulo
        $chk.FontWeight = "SemiBold"
        $chk.IsChecked = $true
        $chk.Tag = $d.Id
        [void]$pila.Children.Add($chk)
        $info = New-Object System.Windows.Controls.TextBlock
        $info.Foreground = Get-Pincel "#6B7280"
        $info.Margin = "20,2,0,0"
        $info.TextWrapping = "Wrap"
        $info.Text = (@("Tipo: $($d.Clase)", "Fabricante: $($d.Fabricante)", "Fecha: $($d.Fecha)", "Descarga: $($d.MB) MB") | Where-Object { $_ -notmatch ": $" }) -join "   ·   "
        [void]$pila.Children.Add($info)
        $marco.Child = $pila
        [void]$script:PanelDrivers.Children.Add($marco)
        $script:CasillasDrivers += $chk
    }
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = "Instalar seleccionados"
    $btn.Style = $script:Ventana.FindResource("Primario")
    $btn.Padding = "16,6"
    $btn.Margin = "16,6,0,6"
    $btn.HorizontalAlignment = "Left"
    $btn.Tag = $true
    $btn.Add_Click({
        $ids = @($script:CasillasDrivers | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
        if ($ids.Count -eq 0) { return }
        $msg = "Se instalarán $($ids.Count) controlador(es) de Windows Update.`r`n`r`nAntes se intenta crear un punto de restauración. Puede que la pantalla parpadee o se corte el Wi-Fi unos segundos mientras se instalan.`r`n`r`n¿Continuar?"
        if ([System.Windows.MessageBox]::Show($msg, "Instalar controladores", "YesNo", "Question") -ne "Yes") { return }
        Start-Pasos -Pasos @(New-PasoScript -Nombre "Instalar controladores" -Codigo (Get-CodigoInstalarDrivers -Ids $ids)) -Titulo "Instalar controladores" -OfrecerReinicio
    })
    $script:BotonesSeguridad += $btn
    [void]$script:PanelDrivers.Children.Add($btn)
}

# ---------------------------------------------------------------- Revisión propia (sin antivirus)
# Busca señales típicas de mineros de criptomonedas y malware sin depender del antivirus instalado.
# Solo lee: no borra ni cambia nada. Cada hallazgo trae qué es y qué hacer.
$script:codigoRevision = @'
$lista = $global:Estado.Revision
function Add-Sospecha([string]$Nivel, [string]$Tipo, [string]$Titulo, [string]$Detalle, [string]$Ruta = "", [int]$IdProceso = 0) {
    [void]$lista.Add(@{ Nivel = $Nivel; Tipo = $Tipo; Titulo = $Titulo; Detalle = $Detalle; Ruta = $Ruta; Pid = $IdProceso })
}
$firmas = @{}
function Get-Firma([string]$Archivo) {
    if (-not $Archivo -or -not (Test-Path -LiteralPath $Archivo -PathType Leaf)) { return $null }
    if ($firmas.ContainsKey($Archivo)) { return $firmas[$Archivo] }
    $f = $null
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Archivo -ErrorAction Stop
        $quien = ""
        if ($s.SignerCertificate) { $quien = ($s.SignerCertificate.Subject -split ",")[0] -replace '^CN=', '' -replace '"', '' }
        $f = [pscustomobject]@{ Valida = ($s.Status -eq "Valid"); Firmante = $quien }
    } catch { }
    $firmas[$Archivo] = $f
    return $f
}
function Get-RutaExe([string]$Comando) {
    if (-not $Comando) { return "" }
    $c = [Environment]::ExpandEnvironmentVariables($Comando.Trim())
    if ($c.StartsWith('"')) { $c = $c.Substring(1); $i = $c.IndexOf('"'); if ($i -gt 0) { return $c.Substring(0, $i) } }
    if ($c -match '^(.+?\.(exe|com|bat|cmd|ps1|vbs|js|scr|dll))(\s|,|$)') { return $Matches[1] }
    return ($c -split '\s')[0]
}
$rutaRara = '\\AppData\\Local\\Temp\\|\\Windows\\Temp\\|\\Users\\Public\\|\\\$Recycle\.Bin\\|^[A-Za-z]:\\ProgramData\\[^\\]+\.(exe|scr|com)$|\\AppData\\Roaming\\[^\\]+\.(exe|scr|com)$|\\AppData\\Local\\[^\\]+\.(exe|scr|com)$|\\Fonts\\.+\.exe$'
$comandoRaro = '(?i)(-enc(odedcommand)?\s|-e\s+[A-Za-z0-9+/=]{40,}|FromBase64String|DownloadString|DownloadFile|Invoke-Expression|\bIEX\b|-w(indowstyle)?\s+hid|mshta\s+(http|vbscript|javascript)|regsvr32\s+/s\s+/n\s+/u\s+/i:http|certutil.+-urlcache|bitsadmin\s+/transfer)'
$nombresMineros = 'xmrig|xmr-stak|nicehash|nheqminer|ethminer|phoenixminer|t-rex|lolminer|nbminer|gminer|teamredminer|cpuminer|ccminer|minerd|cgminer|bfgminer|srbminer|wildrig|claymore|excavator|kawpowminer|xmrminer|minergate|cryptonight'
$comandoMinero = '(?i)(stratum\+(tcp|ssl)|--donate-level|--coin[ =]|--algo[ =]|-a\s+(rx/0|cn/|kawpow|ethash)|nanopool|minexmr|supportxmr|hashvault|2miners|f2pool|moneroocean|unmineable|herominers)'

# 1. Procesos: nombres y comandos de mineros
Write-Output "1/9 Revisando los procesos en ejecución..."
$procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
foreach ($p in $procs) {
    $nom = [string]$p.Name; $cmd = [string]$p.CommandLine
    if ($nom -match "(?i)($nombresMineros)" -or $cmd -match $comandoMinero) {
        Add-Sospecha "Alto" "Proceso" "Posible minero de criptomonedas en ejecución: $nom" "Su nombre o sus parámetros son los típicos de un programa de minado (usa tu procesador o tarjeta gráfica para ganar criptomonedas para otro). Comando: $($cmd.Substring(0, [Math]::Min(200, $cmd.Length)))" ([string]$p.ExecutablePath) ([int]$p.ProcessId)
    } elseif ($cmd -match $comandoRaro -and $nom -match '(?i)^(powershell|pwsh|cmd|mshta|wscript|cscript|rundll32|regsvr32)\.exe$') {
        $archivoScript = ""
        if ($cmd -match '(?i)"([^"]+\.(ps1|vbs|vbe|js|jse|hta|bat|cmd|wsf))"') { $archivoScript = $Matches[1] }
        elseif ($cmd -match '(?i)(\S+\.(ps1|vbs|vbe|js|jse|hta|bat|cmd|wsf))(\s|$)') { $archivoScript = $Matches[1] }
        $cual = if ($archivoScript) { "'$(Split-Path $archivoScript -Leaf)'" } else { "un comando" }
        Add-Sospecha "Medio" "Proceso" "Script oculto o codificado en ejecución: $cual ($nom)" "Hay un $nom con parámetros que suelen usar los programas maliciosos para esconderse (texto codificado, ventana oculta o descarga desde Internet). Algunos programas legítimos de empresa también lo hacen. Comando: $($cmd.Substring(0, [Math]::Min(200, $cmd.Length)))" $archivoScript ([int]$p.ProcessId)
    }
}

# 2. Procesos que gastan mucho procesador (muestra de 5 segundos)
Write-Output "2/9 Midiendo qué procesos usan el procesador (5 segundos; no toques nada si puedes)..."
$nucleos = [Environment]::ProcessorCount
$antes = @{}
foreach ($pr in Get-Process) { try { $antes[$pr.Id] = $pr.TotalProcessorTime.TotalMilliseconds } catch { } }
Start-Sleep -Seconds 5
foreach ($pr in Get-Process) {
    if ($pr.Id -eq $PID -or -not $antes.ContainsKey($pr.Id)) { continue }
    try { $uso = ($pr.TotalProcessorTime.TotalMilliseconds - $antes[$pr.Id]) / (5000 * $nucleos) * 100 } catch { continue }
    if ($uso -lt 25) { continue }
    $ruta = ""; try { $ruta = $pr.Path } catch { }
    $f = Get-Firma $ruta
    $desdeWindows = $ruta -and $ruta.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase) -and $f -and $f.Valida
    if ($desdeWindows) { continue }
    $usoTxt = [math]::Round($uso)
    if (-not $f -or -not $f.Valida -or $ruta -match $rutaRara) {
        Add-Sospecha "Alto" "Proceso" "$($pr.ProcessName) usa el $usoTxt % del procesador y no está firmado" "Un programa sin firma digital, o en una carpeta poco habitual, gastando tanto procesador es la señal más típica de un minero. Si no lo reconoces, termínalo y busca su nombre en Internet." $ruta $pr.Id
    } else {
        Add-Sospecha "Info" "Proceso" "$($pr.ProcessName) usa el $usoTxt % del procesador" "Está firmado por $($f.Firmante). Es normal si lo estás usando (juego, editor de vídeo, navegador con muchas pestañas). Si no lo estás usando y sigue alto, revísalo." $ruta $pr.Id
    }
}

# 3. Programas ejecutándose desde carpetas raras y sin firma
Write-Output "3/9 Revisando desde dónde se ejecuta cada programa..."
$vistos = @{}
foreach ($p in $procs) {
    $ruta = [string]$p.ExecutablePath
    if (-not $ruta -or $vistos.ContainsKey($ruta) -or $ruta -notmatch $rutaRara) { continue }
    $vistos[$ruta] = $true
    $f = Get-Firma $ruta
    if ($f -and $f.Valida) { continue }
    Add-Sospecha "Medio" "Proceso" "Programa sin firma ejecutándose desde una carpeta temporal o poco habitual: $($p.Name)" "Los programas normales se instalan en 'Archivos de programa'. Los que corren desde Temp, Public o la raíz de AppData/ProgramData y no tienen firma merecen una revisión." $ruta ([int]$p.ProcessId)
}

# 4. Conexiones a puertos típicos de grupos de minado
Write-Output "4/9 Revisando las conexiones a Internet..."
$puertosMinado = @(3333, 4444, 5555, 7777, 14433, 14444, 45560, 45700)
try {
    $con = @(Get-NetTCPConnection -State Established -ErrorAction Stop | Where-Object { $puertosMinado -contains [int]$_.RemotePort })
    foreach ($c in $con) {
        $pr = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        $ruta = ""; try { $ruta = $pr.Path } catch { }
        Add-Sospecha "Medio" "Red" "$($pr.ProcessName) está conectado al puerto $($c.RemotePort) de $($c.RemoteAddress)" "Ese puerto es el que usan muchos grupos de minado (stratum). Algunos programas legítimos también lo usan; si no reconoces el programa, revísalo." $ruta ([int]$c.OwningProcess)
    }
} catch { Write-Warning "No se pudieron leer las conexiones de red." }

# 5. Programas de arranque
Write-Output "5/9 Revisando los programas que arrancan con Windows..."
$claves = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
          "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
          "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
foreach ($k in $claves) {
    $props = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
    if (-not $props) { continue }
    foreach ($pp in $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) {
        $cmd = [string]$pp.Value
        $ruta = Get-RutaExe $cmd
        if ($cmd -match $comandoRaro -or $cmd -match $comandoMinero) {
            Add-Sospecha "Alto" "Arranque" "Entrada de arranque sospechosa: $($pp.Name)" "Al encender, ejecuta un comando oculto, codificado o que descarga algo de Internet: $cmd" $ruta
        } elseif ($ruta -match $rutaRara) {
            $f = Get-Firma $ruta
            if (-not $f -or -not $f.Valida) {
                Add-Sospecha "Medio" "Arranque" "Arranca con Windows un programa sin firma de una carpeta poco habitual: $($pp.Name)" "Comando: $cmd" $ruta
            }
        }
    }
}

# 6. Tareas programadas
Write-Output "6/9 Revisando las tareas programadas..."
foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike "\Microsoft\*" })) {
    foreach ($a in @($t.Actions)) {
        if (-not $a.Execute) { continue }
        $cmd = "$($a.Execute) $($a.Arguments)".Trim()
        $ruta = Get-RutaExe $a.Execute
        if ($cmd -match $comandoRaro -or $cmd -match $comandoMinero -or $ruta -match "(?i)($nombresMineros)") {
            Add-Sospecha "Alto" "Tarea" "Tarea programada sospechosa: $($t.TaskPath)$($t.TaskName)" "Ejecuta un comando oculto, codificado, que descarga de Internet o de minado. Así es como muchos mineros vuelven aunque los borres. Comando: $($cmd.Substring(0, [Math]::Min(250, $cmd.Length)))" $ruta
        } elseif ($ruta -match $rutaRara) {
            $f = Get-Firma ([Environment]::ExpandEnvironmentVariables($ruta))
            if (-not $f -or -not $f.Valida) {
                Add-Sospecha "Medio" "Tarea" "Tarea programada que abre un programa sin firma: $($t.TaskName)" "Comando: $cmd" $ruta
            }
        }
    }
}

# 7. Servicios
Write-Output "7/9 Revisando los servicios..."
foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
    $ruta = Get-RutaExe ([string]$s.PathName)
    if (-not $ruta -or $ruta -match '(?i)\\Windows\\(System32|SysWOW64)\\') { continue }
    if ($ruta -match "(?i)($nombresMineros)" -or [string]$s.PathName -match $comandoMinero) {
        Add-Sospecha "Alto" "Servicio" "Servicio de minado: $($s.DisplayName)" "El servicio '$($s.Name)' ejecuta: $($s.PathName)" $ruta
    } elseif ($ruta -match $rutaRara) {
        $f = Get-Firma $ruta
        if (-not $f -or -not $f.Valida) {
            Add-Sospecha "Alto" "Servicio" "Servicio sin firma en una carpeta temporal o poco habitual: $($s.DisplayName)" "Los servicios se ejecutan con todos los permisos. Uno sin firma fuera de 'Archivos de programa' es muy sospechoso. Ejecuta: $($s.PathName)" $ruta
        }
    }
}

# 8. Exclusiones del antivirus y persistencia WMI
Write-Output "8/9 Revisando exclusiones de Defender y tareas ocultas de WMI..."
try {
    $mp = Get-MpPreference -ErrorAction Stop
    $exc = @(@($mp.ExclusionPath) + @($mp.ExclusionProcess) + @($mp.ExclusionExtension) | Where-Object { $_ })
    if ($exc.Count) {
        $niv = if (@($exc | Where-Object { $_ -match '(?i)^[A-Z]:\\?$|\\Users\\?$|\\AppData|\\Temp|\\ProgramData\\?$|^\.?exe$' }).Count) { "Alto" } else { "Medio" }
        Add-Sospecha $niv "Exclusion" "Microsoft Defender tiene $($exc.Count) exclusión(es)" "Lo que está excluido no se analiza. Los mineros suelen añadir exclusiones para esconderse. Si no las pusiste tú (o tu antivirus o un programa que conoces), quítalas: $($exc -join '; ')"
    }
} catch { }
foreach ($clase in "CommandLineEventConsumer", "ActiveScriptEventConsumer") {
    foreach ($w in @(Get-CimInstance -Namespace root\subscription -ClassName $clase -ErrorAction SilentlyContinue)) {
        $txt = if ($w.CommandLineTemplate) { $w.CommandLineTemplate } else { [string]$w.ScriptText }
        Add-Sospecha "Alto" "WMI" "Tarea oculta de WMI: $($w.Name)" "WMI puede ejecutar comandos solos sin aparecer en el Programador de tareas; casi ningún programa normal lo usa así. Ejecuta: $($txt.Substring(0, [Math]::Min(250, $txt.Length)))"
    }
}

# 9. Archivo hosts
Write-Output "9/9 Revisando el archivo hosts..."
$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
$lineas = @(Get-Content -LiteralPath $hosts -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") })
$bloqueos = @($lineas | Where-Object { $_ -match '(?i)(microsoft|windowsupdate|update\.microsoft|eset|kaspersky|avast|avg|bitdefender|norton|mcafee|malwarebytes|virustotal|sophos|trendmicro)' })
if ($bloqueos.Count) {
    Add-Sospecha "Alto" "Hosts" "El archivo hosts bloquea webs de seguridad o de Windows Update" "Así algunos malware impiden que el antivirus se actualice. Líneas: $($bloqueos -join ' | ')" $hosts
} elseif ($lineas.Count) {
    Add-Sospecha "Info" "Hosts" "El archivo hosts tiene $($lineas.Count) línea(s) propias" "Suele ser de programas de desarrollo o bloqueo de anuncios. Revísalo si no sabes de dónde salen." $hosts
}

$altos = @($lista | Where-Object { $_.Nivel -eq "Alto" }).Count
$medios = @($lista | Where-Object { $_.Nivel -eq "Medio" }).Count
Write-Output "Revisión terminada: $altos señal(es) importantes y $medios a revisar."
'@

$script:DetallesAcciones["Buscar mineros y programas sospechosos"] = "Es una revisión propia que NO usa el antivirus: busca las huellas que dejan los mineros y el malware común. Solo lee, no borra ni cambia nada. Tarda de 20 segundos a 2 minutos.`n`n1. Procesos con nombres o parámetros de minado (xmrig, nicehash, stratum+tcp, grupos de minado conocidos...).`n2. Qué procesos gastan mucho procesador durante 5 segundos y si están firmados.`n3. Programas sin firma ejecutándose desde Temp, Public o la raíz de AppData/ProgramData.`n4. Conexiones a los puertos que usan los grupos de minado.`n5. Programas de arranque con comandos ocultos, codificados o que descargan de Internet.`n6. Tareas programadas (fuera de las de Microsoft) con esos mismos trucos.`n7. Servicios sin firma fuera de 'Archivos de programa'.`n8. Exclusiones de Microsoft Defender y tareas ocultas de WMI.`n9. Archivo hosts que bloquee webs de antivirus o de Windows Update.`n`nCada resultado dice qué es, por qué es sospechoso y trae botones para abrir su carpeta, buscarlo en Internet o terminar el proceso. Que algo salga aquí no significa que sea un virus: es una pista para revisar."

function Start-Revision {
    if ($script:Trabajo) { return }
    $global:Estado.Revision = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $script:PanelRevision.Children.Clear()
    Start-Pasos -Pasos @(New-PasoScript -Nombre "Buscar mineros y programas sospechosos" -Codigo $script:codigoRevision) -Silencioso
    if ($script:Trabajo) { $script:AlTerminar = { Show-Revision } }
}
$pS = $script:UI.PanelSeguridad
$inicioRevision = $pS.Children.Count
[void]$pS.Children.Add((New-Titulo "Revisión propia (sin antivirus)" "Busca mineros de criptomonedas y señales de malware por su cuenta, sin depender del antivirus instalado. No borra nada: te muestra lo sospechoso y tú decides."))
New-TarjetaAccion -Panel $pS -Titulo "Buscar mineros y programas sospechosos" -TextoBoton "Revisar" -Riesgo "Bajo" `
    -Descripcion "Procesos que gastan mucho procesador sin firma, nombres y conexiones de minado, arranque, tareas programadas, servicios, exclusiones del antivirus y archivo hosts." `
    -Aviso "Puede tardar hasta 2 minutos. Mejor con los programas pesados cerrados, para que la medición del procesador sea fiable." `
    -Accion { Start-Revision }
$script:PanelRevision = New-Object System.Windows.Controls.StackPanel
$script:PanelRevision.Margin = "0,0,0,8"
[void]$pS.Children.Add($script:PanelRevision)
# Se muestra al principio de Seguridad, justo después del estado del antivirus
$elementosRevision = @(for ($i = $inicioRevision; $i -lt $pS.Children.Count; $i++) { $pS.Children[$i] })
foreach ($el in $elementosRevision) { $pS.Children.Remove($el) }
$posRevision = 0
foreach ($el in $elementosRevision) { $pS.Children.Insert($posRevision, $el); $posRevision++ }

$script:QueHacerRevision = @{
    Proceso   = "Qué hacer: si no lo reconoces, pulsa 'Terminar proceso', abre su carpeta y busca el nombre en Internet. Después haz un análisis con Safety Scanner (arriba)."
    Red       = "Qué hacer: mira qué programa es. Si no lo reconoces, termínalo y analiza el equipo."
    Arranque  = "Qué hacer: desactívalo en Configuración > Aplicaciones > Inicio, o en el Administrador de tareas > Aplicaciones de arranque."
    Tarea     = "Qué hacer: abre el Programador de tareas, búscala por su nombre, desactívala y luego elimínala si no la reconoces."
    Servicio  = "Qué hacer: abre Servicios, búscalo, detenlo y ponlo en Deshabilitado si no lo reconoces. Luego analiza el equipo."
    Exclusion = "Qué hacer: Seguridad de Windows > Protección antivirus > Administrar la configuración > Exclusiones, y quita las que no reconozcas."
    WMI       = "Qué hacer: no es fácil de quitar a mano. Pasa Microsoft Safety Scanner (arriba) o pide ayuda técnica."
    Hosts     = "Qué hacer: abre el archivo hosts con el Bloc de notas como administrador y borra las líneas que no reconozcas."
}

function Show-Revision {
    $script:PanelRevision.Children.Clear()
    $lista = @($global:Estado.Revision)
    $altos = @($lista | Where-Object { $_.Nivel -eq "Alto" }).Count
    $medios = @($lista | Where-Object { $_.Nivel -eq "Medio" }).Count
    $res = New-Object System.Windows.Controls.TextBlock
    $res.TextWrapping = "Wrap"
    $res.FontWeight = "SemiBold"
    $res.Margin = "16,0,0,8"
    if ($lista.Count -eq 0 -or ($altos -eq 0 -and $medios -eq 0)) {
        $res.Text = "$([char]0x2714) No se encontraron señales de mineros ni de programas sospechosos."
        $res.Foreground = Get-Pincel "#16A34A"
    } elseif ($altos) {
        $res.Text = "$([char]0x2716) $altos señal(es) importantes y $medios a revisar. Revisa primero las rojas."
        $res.Foreground = Get-Pincel "#DC2626"
    } else {
        $res.Text = "$([char]0x26A0) $medios cosa(s) a revisar. Probablemente sean programas legítimos, pero compruébalo."
        $res.Foreground = Get-Pincel "#D97706"
    }
    [void]$script:PanelRevision.Children.Add($res)
    $colores = @{ Alto = "#DC2626"; Medio = "#D97706"; Info = "#6B7280" }
    foreach ($nivel in "Alto", "Medio", "Info") {
        foreach ($h in @($lista | Where-Object { $_.Nivel -eq $nivel })) {
            $marco = New-Object System.Windows.Controls.Border
            $marco.Background = Get-Pincel "#FFFFFF"
            $marco.BorderBrush = Get-Pincel $colores[$nivel]
            $marco.BorderThickness = "4,1,1,1"
            $marco.CornerRadius = 6
            $marco.Padding = "12,8"
            $marco.Margin = "16,0,0,6"
            $pila = New-Object System.Windows.Controls.StackPanel
            $tit = New-Object System.Windows.Controls.TextBlock
            $tit.Text = $h.Titulo
            $tit.FontWeight = "SemiBold"
            $tit.TextWrapping = "Wrap"
            [void]$pila.Children.Add($tit)
            $det = New-Object System.Windows.Controls.TextBlock
            $det.Text = $h.Detalle
            $det.TextWrapping = "Wrap"
            $det.Foreground = Get-Pincel "#4B5563"
            $det.Margin = "0,2,0,0"
            [void]$pila.Children.Add($det)
            if ($nivel -ne "Info" -and $script:QueHacerRevision[$h.Tipo]) {
                $que = New-Object System.Windows.Controls.TextBlock
                $que.Text = $script:QueHacerRevision[$h.Tipo]
                $que.TextWrapping = "Wrap"
                $que.Foreground = Get-Pincel $colores[$nivel]
                $que.Margin = "0,3,0,0"
                [void]$pila.Children.Add($que)
            }
            if ($h.Ruta) {
                $r = New-Object System.Windows.Controls.TextBlock
                $r.Text = $h.Ruta
                $r.TextWrapping = "Wrap"
                $r.FontSize = 11
                $r.Foreground = Get-Pincel "#9CA3AF"
                $r.Margin = "0,2,0,0"
                [void]$pila.Children.Add($r)
            }
            $botones = New-Object System.Windows.Controls.WrapPanel
            $botones.Margin = "0,6,0,0"
            $acciones = New-Object System.Collections.ArrayList
            if ($h.Ruta -and (Test-Path -LiteralPath $h.Ruta)) {
                [void]$acciones.Add(@("Abrir ubicación", [scriptblock]::Create("Start-Process explorer.exe -ArgumentList '/select,`"$($h.Ruta -replace "'", "''")`"'")))
            }
            if ($h.Ruta -match '(?i)\.(ps1|vbs|vbe|js|jse|hta|bat|cmd|wsf)$' -and (Test-Path -LiteralPath $h.Ruta)) {
                [void]$acciones.Add(@("Ver el script (Bloc de notas)", [scriptblock]::Create("Start-Process notepad.exe -ArgumentList '`"$($h.Ruta -replace "'", "''")`"'")))
            }
            $buscar = if ($h.Ruta) { Split-Path $h.Ruta -Leaf } else { $h.Titulo }
            [void]$acciones.Add(@("Buscar en Internet", [scriptblock]::Create("Start-Process ('https://www.bing.com/search?q=' + [uri]::EscapeDataString('$($buscar -replace "'", "''")' + ' qué es'))")))
            $abrir = @{ Tarea = "taskschd.msc"; Servicio = "services.msc"; Arranque = "ms-settings:startupapps"; Exclusion = "windowsdefender://threatsettings"; Hosts = "notepad.exe" }
            if ($abrir[$h.Tipo]) {
                $obj = $abrir[$h.Tipo]
                $sb = if ($h.Tipo -eq "Hosts") { { Start-Process notepad.exe -ArgumentList "$env:SystemRoot\System32\drivers\etc\hosts" } } else { [scriptblock]::Create("Start-Process '$obj'") }
                [void]$acciones.Add(@("Abrir donde se quita", $sb))
            }
            if ($h.Pid -and $nivel -ne "Info") {
                [void]$acciones.Add(@("Terminar proceso", [scriptblock]::Create(@"
if ([System.Windows.MessageBox]::Show("¿Terminar el proceso $($h.Pid)?``r``n``r``nSi es un programa legítimo, lo que no esté guardado se pierde. Si vuelve a aparecer, algo lo está relanzando (mira arranque, tareas y servicios).", "Terminar proceso", "YesNo", "Warning") -eq "Yes") {
    try { Stop-Process -Id $($h.Pid) -Force -ErrorAction Stop; Escribir-Log "Proceso $($h.Pid) terminado." } catch { Escribir-Log "No se pudo terminar el proceso $($h.Pid): `$(`$_.Exception.Message)" "AVISO" }
}
"@)))
            }
            foreach ($a in $acciones) {
                $b = New-Object System.Windows.Controls.Button
                $b.Content = $a[0]
                $b.Padding = "10,3"
                $b.Margin = "0,0,6,0"
                $b.Add_Click($a[1])
                [void]$botones.Children.Add($b)
            }
            [void]$pila.Children.Add($botones)
            $marco.Child = $pila
            [void]$script:PanelRevision.Children.Add($marco)
        }
    }
}

$script:TemporizadorRam = New-Object System.Windows.Threading.DispatcherTimer
$script:TemporizadorRam.Interval = [TimeSpan]::FromSeconds(3)
$script:TemporizadorRam.Add_Tick({
    $sel = [string]$script:UI.Pestanas.SelectedItem.Name
    if ($sel -eq "TabInicio" -or $sel -eq "TabRendimiento") { Update-IndicadorRam }
})
$script:TemporizadorRam.Start()

# ---------------------------------------------------------------- Trabajo en segundo plano
$script:Trabajo = $null
$script:AlTerminar = $null

function Set-Ocupado([bool]$ocupado) {
    foreach ($b in "BtnRecomendados","BtnLimpiar","BtnDeshacer","BtnPreferencias","BtnAplicar","BtnAppsInstalar","BtnAppsActualizar","BtnAppsDesinstalar","BtnAppsTodo","BtnAppsComprobar") {
        $script:UI[$b].IsEnabled = -not $ocupado
    }
    foreach ($b in $script:BotonesSeguridad) {
        $b.IsEnabled = (-not $ocupado) -and [bool]$b.Tag
    }
}

function Start-Pasos {
    param([object[]]$Pasos, [string]$Titulo = "", [switch]$Silencioso, [switch]$OfrecerReinicio)
    if ($script:Trabajo) {
        [void][System.Windows.MessageBox]::Show("Ya hay un proceso en marcha. Espera a que termine.", "Optimizador", "OK", "Information")
        return
    }
    Set-Ocupado $true
    $global:Estado.Progreso = 0
    $global:Estado.Resumen = [hashtable]::Synchronized(@{ Ok = 0; Avisos = 0; Errores = 0; Total = @($Pasos).Count; Cancelado = $false })
    $global:Estado.Hechos = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $script:OpcionesTrabajo = @{ Titulo = $(if ($Titulo) { $Titulo } elseif (@($Pasos).Count -eq 1) { @($Pasos)[0].Item.Nombre } else { "Proceso" }); Silencioso = [bool]$Silencioso; Reinicio = [bool]$OfrecerReinicio }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable("Estado", $global:Estado)
    $rs.SessionStateProxy.SetVariable("ArchivoLog", $global:ArchivoLog)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:MotorCodigo).Invoke()
    $ps.Commands.Clear()

    [void]$ps.AddScript({
        param($Pasos)
        $total = @($Pasos).Count
        $i = 0
        foreach ($p in $Pasos) {
            $i++
            $Estado.Progreso = [int](100 * ($i - 1) / [Math]::Max($total, 1))
            $Estado.Texto = "($i/$total) $($p.Item.Nombre)"
            $ok = Invoke-Ajuste -Item $p.Item -Deshacer $p.Deshacer
            if ($ok) {
                if ($global:avisos) { $Estado.Resumen.Avisos++ } else { $Estado.Resumen.Ok++ }
                [void]$Estado.Hechos.Add("$($p.Item.Key)|$($p.Deshacer)")
            } else {
                $Estado.Resumen.Errores++
            }
            if (-not $ok -and $p.Item.Key -eq "WPFTweaksRestorePoint" -and -not $p.Deshacer) {
                $Estado.Resumen.Cancelado = $true
                Escribir-Log "No se pudo crear el punto de restauración. Por seguridad NO se aplicó nada más. Activa 'Protección del sistema' en C: e inténtalo otra vez." "ERROR"
                $Estado.Texto = "Cancelado: no se pudo crear el punto de restauración."
                $Estado.Progreso = 0
                return
            }
        }
        $Estado.Progreso = 100
        $r = $Estado.Resumen
        $Estado.Texto = "Terminado: $($r.Ok) correcto(s), $($r.Avisos) con avisos, $($r.Errores) con errores."
        Escribir-Log "===== TERMINADO: $($r.Ok) correcto(s), $($r.Avisos) con avisos, $($r.Errores) con errores ====="
    }).AddArgument($Pasos)

    $script:Trabajo = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

$temporizador = New-Object System.Windows.Threading.DispatcherTimer
$temporizador.Interval = [TimeSpan]::FromMilliseconds(250)
$temporizador.Add_Tick({
    $linea = $null
    $hubo = $false
    while ($global:Estado.Cola.TryDequeue([ref]$linea)) {
        $script:UI.TxtLog.AppendText($linea + "`r`n")
        $hubo = $true
    }
    if ($hubo) { $script:UI.TxtLog.ScrollToEnd() }
    if ($global:Estado.Texto) { $script:UI.TxtEstado.Text = $global:Estado.Texto }
    $script:UI.Barra.Value = $global:Estado.Progreso
    if ($global:Estado.Apps.Count) { Update-EstadosApps }

    if ($script:Trabajo -and $script:Trabajo.Handle.IsCompleted) {
        try { [void]$script:Trabajo.PS.EndInvoke($script:Trabajo.Handle) }
        catch { Escribir-Log "Error inesperado: $($_.Exception.Message)" "ERROR" }
        $script:Trabajo.PS.Dispose()
        $script:Trabajo.RS.Close()
        $script:Trabajo = $null
        Set-Ocupado $false
        Update-Preferencias
        foreach ($h in @($global:Estado.Hechos)) {
            $partes = $h -split "\|"
            if ($partes[1] -eq "True") { $script:HechosSesion.Remove($partes[0]) } else { $script:HechosSesion[$partes[0]] = $true }
        }
        Update-VistaAjustes
        if ($script:TxtModoUpdates) { $script:TxtModoUpdates.Text = "Modo actual: " + (Get-ModoUpdates) }
        Update-EstadoRendimiento
        if (Get-Command Update-VistasExtra -ErrorAction SilentlyContinue) { Update-VistasExtra }
        Show-ResumenTrabajo
        if ($script:AlTerminar) {
            $siguiente = $script:AlTerminar
            $script:AlTerminar = $null
            & $siguiente
        }
        if (-not $script:Trabajo) { Invoke-ComprobacionPestana }
    }
})
$temporizador.Start()

# ---------------------------------------------------------------- Botones
function Get-Seleccionados {
    return @($script:CasillasAjustes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
}

$ui.BtnRecomendados.Add_Click({
    foreach ($c in $script:CasillasAjustes) {
        $c.IsChecked = ($c.Tag.Grupo -eq "Esenciales" -and $c.Tag.Riesgo -eq "Bajo" -and (Test-AjusteVisible $c))
    }
})

$ui.BtnLimpiar.Add_Click({
    foreach ($c in $script:CasillasAjustes) { $c.IsChecked = $false }
})

$ui.BtnRestaurar.Add_Click({ Start-Process "rstrui.exe" })

$ui.BtnAplicar.Add_Click({
    $sel = Get-Seleccionados
    $sinPunto = @($sel | Where-Object { $_.Key -ne "WPFTweaksRestorePoint" })
    if ($sinPunto.Count -eq 0) {
        [void][System.Windows.MessageBox]::Show("Marca al menos un ajuste además del punto de restauración.", "Optimizador", "OK", "Information")
        return
    }
    $tienePunto = @($sel | Where-Object { $_.Key -eq "WPFTweaksRestorePoint" }).Count -gt 0
    $altos  = @($sinPunto | Where-Object { $_.Riesgo -eq "Alto" })
    $medios = @($sinPunto | Where-Object { $_.Riesgo -eq "Medio" })

    $msg = "Vas a aplicar $($sinPunto.Count) ajuste(s).`r`n"
    if (-not $tienePunto) {
        $msg += "`r`n$([char]0x26A0) NO has marcado 'Crear punto de restauración'. Si algo sale mal será más difícil volver atrás.`r`n"
    }
    if ($altos.Count) {
        $msg += "`r`nRIESGO ALTO:`r`n"
        foreach ($a in $altos) { $msg += " - $($a.Nombre): $($a.Aviso)`r`n" }
    }
    if ($medios.Count) {
        $msg += "`r`nRiesgo medio:`r`n"
        foreach ($m in $medios) { $msg += " - $($m.Nombre)`r`n" }
    }
    $msg += "`r`n¿Continuar?"
    $icono = if ($altos.Count -or -not $tienePunto) { "Warning" } else { "Question" }
    $r = [System.Windows.MessageBox]::Show($msg, "Confirmar cambios", "YesNo", $icono)
    if ($r -ne "Yes") { return }

    $pasos = @()
    if ($tienePunto) {
        $pasos += [pscustomobject]@{ Item = ($sel | Where-Object { $_.Key -eq "WPFTweaksRestorePoint" } | Select-Object -First 1); Deshacer = $false }
    }
    foreach ($s in $sinPunto) { $pasos += [pscustomobject]@{ Item = $s; Deshacer = $false } }
    Start-Pasos -Pasos $pasos -Titulo "Aplicar ajustes" -OfrecerReinicio
})

$ui.BtnDeshacer.Add_Click({
    $sel = @(Get-Seleccionados | Where-Object { $_.Key -ne "WPFTweaksRestorePoint" })
    if ($sel.Count -eq 0) {
        [void][System.Windows.MessageBox]::Show("Marca los ajustes que quieres deshacer.", "Optimizador", "OK", "Information")
        return
    }
    $sinUndo = @($sel | Where-Object { -not $_.UndoScript -and -not $_.registry -and -not $_.service })
    $msg = "Se intentará devolver a su valor original $($sel.Count) ajuste(s)."
    if ($sinUndo.Count) {
        $msg += "`r`n`r`nEstos no se pueden deshacer desde aquí (usa Restaurar sistema o reinstala):`r`n"
        foreach ($s in $sinUndo) { $msg += " - $($s.Nombre)`r`n" }
    }
    $msg += "`r`n¿Continuar?"
    if ([System.Windows.MessageBox]::Show($msg, "Deshacer", "YesNo", "Question") -ne "Yes") { return }
    Start-Pasos -Pasos @($sel | ForEach-Object { [pscustomobject]@{ Item = $_; Deshacer = $true } }) -Titulo "Deshacer ajustes" -OfrecerReinicio
})

$ui.BtnPreferencias.Add_Click({
    $pasos = @()
    $altos = @()
    foreach ($c in $script:CasillasPref) {
        $ahora = [bool]$c.IsChecked
        if ([string]$ahora -ne $c.Uid) {
            # Activar = aplicar el valor del ajuste; desactivar = volver al original
            $pasos += [pscustomobject]@{ Item = $c.Tag; Deshacer = (-not $ahora) }
            if ($c.Tag.Riesgo -eq "Alto") { $altos += $c.Tag }
        }
    }
    if ($pasos.Count -eq 0) {
        [void][System.Windows.MessageBox]::Show("No has cambiado ninguna preferencia.", "Optimizador", "OK", "Information")
        return
    }
    if ($altos.Count) {
        $msg = "Has cambiado preferencias de RIESGO ALTO:`r`n"
        foreach ($a in $altos) { $msg += " - $($a.Nombre): $($a.Aviso)`r`n" }
        $msg += "`r`n¿Continuar?"
        if ([System.Windows.MessageBox]::Show($msg, "Confirmar", "YesNo", "Warning") -ne "Yes") { return }
    }
    Start-Pasos -Pasos $pasos -Titulo "Aplicar preferencias"
})

$script:Ventana.Add_Closing({
    param($origen, $evento)
    if ($script:Trabajo) {
        [void][System.Windows.MessageBox]::Show("Espera a que termine el trabajo en curso antes de cerrar.", "Optimizador", "OK", "Warning")
        $evento.Cancel = $true
    }
})


# ================================================================ Mejoras: utilidades comunes
function New-Texto {
    param([string]$Texto, [string]$Color = "#4B5563", [double]$Tam = 13, [string]$Peso = "Normal", [string]$Margen = "0,0,0,0")
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Texto
    $t.TextWrapping = "Wrap"
    $t.Foreground = Get-Pincel $Color
    $t.FontSize = $Tam
    $t.FontWeight = $Peso
    $t.Margin = $Margen
    return $t
}

function New-Boton {
    # -Libre: no se desactiva mientras hay un trabajo en marcha (para filas de listas largas)
    param([string]$Texto, [scriptblock]$Clic, [switch]$Primario, [string]$Margen = "0,0,6,6", [switch]$Libre)
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Texto
    $b.Padding = "12,4"
    $b.Margin = $Margen
    $b.Tag = $true
    if ($Primario) { $b.Style = $script:Ventana.FindResource("Primario") }
    $b.Add_Click($Clic)
    if (-not $Libre) {
        $b.IsEnabled = -not $script:Trabajo
        $script:BotonesSeguridad += $b
    }
    return $b
}

function New-Marco {
    param([string]$Margen = "0,0,0,8", [string]$Borde = "#E2E6EC", [string]$Relleno = "14,10")
    $m = New-Object System.Windows.Controls.Border
    $m.Background = Get-Pincel "#FFFFFF"
    $m.BorderBrush = Get-Pincel $Borde
    $m.BorderThickness = 1
    $m.CornerRadius = 8
    $m.Padding = $Relleno
    $m.Margin = $Margen
    return $m
}

function New-Reg {
    param([string]$Ruta, [string]$Nombre, $Valor, [string]$Tipo = "DWord", $Original = "<RemoveEntry>")
    return [pscustomobject]@{ Path = $Ruta; Name = $Nombre; Type = $Tipo; Value = [string]$Valor; OriginalValue = [string]$Original }
}

function New-ItemPropio {
    param([string]$Clave, [string]$Nombre, [string]$Grupo, [string]$Riesgo, [string]$Descripcion, [string]$Aviso = "", [object[]]$Registro = @(), [string]$Detalle = "", [string[]]$Script = @(), [string[]]$Deshacer = @())
    return [pscustomobject]@{ Key = $Clave; Nombre = $Nombre; Grupo = $Grupo; Riesgo = $Riesgo; Descripcion = $Descripcion; Aviso = $Aviso
        Detalle = $Detalle; registry = @($Registro); service = @(); InvokeScript = @($Script); UndoScript = @($Deshacer) }
}

function Test-ItemAplicado($Item) {
    if (-not $Item) { return $false }
    $carpetaDatos = Join-Path $env:LOCALAPPDATA "OptimizadorES"
    if ($Item.Key -eq "OPT_ENERGIA_ALTA") { return (Test-Path -LiteralPath (Join-Path $carpetaDatos "respaldo-energia.json")) }
    if ($Item.Key -eq "OPT_VIGILANCIA") { return ((Test-Path -LiteralPath (Join-Path $carpetaDatos "respaldo-vigilancia.json")) -and (Test-AjusteAplicado $Item)) }
    return (Test-AjusteAplicado $Item)
}

# Ajustes propios (mismo formato que los de WinUtil: se guardan con respaldo y se deshacen exacto)
$script:ItemsExtra = @{}
foreach ($it in @($script:ItemFondo, $script:ItemServiciosRam)) { if ($it) { $script:ItemsExtra[$it.Key] = $it } }

# ---------------------------------------------------------------- Pestaña Perfiles
$script:codigoEnergiaAlta = @'
$respaldo = Join-Path $env:LOCALAPPDATA "OptimizadorES\respaldo-energia.json"
$patronGuid = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
$planAlto = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
$planActivo = [regex]::Match((powercfg /getactivescheme | Out-String), $patronGuid).Value
if (-not (Test-Path -LiteralPath $respaldo)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $respaldo) | Out-Null
    @{ Plan = $planActivo } | ConvertTo-Json | Set-Content -LiteralPath $respaldo -Encoding UTF8
    Write-Output "Guardado tu plan de energía actual ($planActivo) para poder volver a él."
}
if ((powercfg /list | Out-String) -notmatch $planAlto) {
    # Algunos portátiles no traen el plan: se crea una copia
    $nuevo = [regex]::Match((powercfg /duplicatescheme $planAlto | Out-String), $patronGuid).Value
    if (-not $nuevo) { throw "Este equipo no tiene el plan Alto rendimiento y no se pudo crear." }
    $planAlto = $nuevo
}
powercfg /setactive $planAlto
if ($LASTEXITCODE -ne 0) { throw "powercfg no pudo activar el plan (código $LASTEXITCODE)." }
Write-Output "Plan de energía activo: Alto rendimiento."
'@

$script:codigoEnergiaVolver = @'
$respaldo = Join-Path $env:LOCALAPPDATA "OptimizadorES\respaldo-energia.json"
$plan = "381b4222-f694-41f0-9685-ff5bb260df2e"
if (Test-Path -LiteralPath $respaldo) {
    try { $g = (Get-Content -LiteralPath $respaldo -Raw -Encoding UTF8 | ConvertFrom-Json).Plan; if ($g) { $plan = $g } } catch { }
}
powercfg /setactive $plan
if ($LASTEXITCODE -ne 0) { powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e }
Remove-Item -LiteralPath $respaldo -Force -ErrorAction SilentlyContinue
Write-Output "Vuelve a estar activo tu plan de energía anterior."
'@

$script:ItemsExtra["OPT_ENERGIA_ALTA"] = New-ItemPropio -Clave "OPT_ENERGIA_ALTA" -Nombre "Plan de energía Alto rendimiento" -Grupo "Perfiles" -Riesgo "Bajo" `
    -Descripcion "El procesador deja de bajar su velocidad para ahorrar energía." -Aviso "Gasta algo más de luz; en portátiles dura menos la batería." `
    -Detalle "Guarda cuál es tu plan de energía y activa 'Alto rendimiento' (si el equipo no lo trae, lo crea). Deshacer vuelve a tu plan anterior." `
    -Script @($script:codigoEnergiaAlta) -Deshacer @($script:codigoEnergiaVolver)

$script:ItemsExtra["OPT_JUEGOS"] = New-ItemPropio -Clave "OPT_JUEGOS" -Nombre "Ajustes para juegos" -Grupo "Perfiles" -Riesgo "Medio" `
    -Descripcion "Modo de juego activado, sin grabación de fondo de Xbox Game Bar y con la programación de GPU acelerada por hardware." `
    -Aviso "La grabación de clips de Xbox Game Bar deja de funcionar. La programación de GPU necesita reiniciar y una tarjeta compatible: si notas tirones, deshazlo." `
    -Registro @(
        (New-Reg "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0 "DWord" 1),
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0),
        (New-Reg "HKCU:\Software\Microsoft\GameBar" "AutoGameModeEnabled" 1),
        (New-Reg "HKCU:\Software\Microsoft\GameBar" "AllowAutoGameMode" 1),
        (New-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode" 2)
    )

# Programas de cámaras de seguridad (Hikvision iVMS, Dahua SmartPSS y otros)
$script:PatronCamaras = 'iVMS|SmartPSS|HikCentral|NVMS|Guarding ?Vision|XProtect|Blue ?Iris|KBiVMS|CMS ?Client'
$script:ProgramaCamaras = $null

function Find-ProgramaCamaras {
    $exes = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { if ($p.Path -and $p.Path -match $script:PatronCamaras -and -not $exes.Contains($p.Path)) { $exes.Add($p.Path) } } catch { }
    }
    $carpetas = @()
    foreach ($raiz in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique) {
        $carpetas += @(Get-ChildItem -LiteralPath $raiz -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $script:PatronCamaras })
    }
    foreach ($c in $carpetas) {
        Get-ChildItem -LiteralPath $c.FullName -Recurse -Depth 3 -Filter "*.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "$($script:PatronCamaras)|Framework" -and $_.Name -notmatch '(?i)unins|setup|update|upgrade|crash|report|install|helper' } |
            ForEach-Object { if (-not $exes.Contains($_.FullName)) { $exes.Add($_.FullName) } }
    }
    $acceso = $null
    foreach ($menu in @([Environment]::GetFolderPath("CommonPrograms"), [Environment]::GetFolderPath("Programs"))) {
        if (-not $menu) { continue }
        $acceso = Get-ChildItem -LiteralPath $menu -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match $script:PatronCamaras -and $_.BaseName -notmatch '(?i)unins|desinst|player|tool|help|ayuda|manual|readme' } | Select-Object -First 1
        if ($acceso) { break }
    }
    $nombreCam = if ($carpetas.Count) { $carpetas[0].Name } elseif ($exes.Count) { [IO.Path]::GetFileNameWithoutExtension($exes[0]) } else { "" }
    $graficas = @()
    try { $graficas = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name }) } catch { }
    return [pscustomobject]@{
        Nombre = $nombreCam; Exes = @($exes | Select-Object -First 12); Acceso = $(if ($acceso) { $acceso.FullName } else { "" })
        UsarIntel = (@($graficas | Where-Object { $_ -match "Intel" }).Count -gt 0 -and $graficas.Count -gt 1)
    }
}

$script:codigoVigilancia = @'
$respaldo = Join-Path $env:LOCALAPPDATA "OptimizadorES\respaldo-vigilancia.json"
$acceso = '__ACCESO__'
function Get-ValorEnergia([string]$Sub, [string]$Opcion) {
    $txt = (powercfg /q SCHEME_CURRENT $Sub $Opcion 2>$null | Out-String)
    $h = [regex]::Matches($txt, '0x[0-9a-fA-F]{8}')
    if ($h.Count -ge 2) { return [Convert]::ToInt64($h[$h.Count - 2].Value, 16) }
    return $null
}
$energia = @(
    @{ Sub = "SUB_SLEEP"; Opcion = "STANDBYIDLE"; Nombre = "Suspender" },
    @{ Sub = "SUB_SLEEP"; Opcion = "HIBERNATEIDLE"; Nombre = "Hibernar" },
    @{ Sub = "SUB_DISK"; Opcion = "DISKIDLE"; Nombre = "Apagar los discos" },
    @{ Sub = "SUB_VIDEO"; Opcion = "VIDEOIDLE"; Nombre = "Apagar la pantalla" },
    @{ Sub = "2a737441-1930-4402-8d77-b2bebba308a3"; Opcion = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"; Nombre = "Suspensión selectiva de USB" },
    @{ Sub = "SUB_PCIEXPRESS"; Opcion = "ASPM"; Nombre = "Ahorro de energía de PCI Express" }
)
if (-not (Test-Path -LiteralPath $respaldo)) {
    $antes = @{ Energia = @(); Red = @(); Acceso = "" }
    foreach ($x in $energia) {
        $v = Get-ValorEnergia $x.Sub $x.Opcion
        if ($null -ne $v) { $antes.Energia += @{ Sub = $x.Sub; Opcion = $x.Opcion; Valor = $v } }
    }
    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        try {
            $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction Stop
            $antes.Red += @{ Nombre = $a.Name; Valor = [string]$pm.AllowComputerToTurnOffDevice }
        } catch { }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $respaldo) | Out-Null
    $antes | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $respaldo -Encoding UTF8
    Write-Output "Guardada la configuración de energía y red actual, para poder deshacer."
}
foreach ($x in $energia) {
    powercfg /setacvalueindex SCHEME_CURRENT $x.Sub $x.Opcion 0 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Output "$($x.Nombre): nunca (con el equipo enchufado)." }
}
powercfg /setactive SCHEME_CURRENT | Out-Null
foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
    try {
        Set-NetAdapterPowerManagement -Name $a.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
        Write-Output "Red '$($a.Name)': Windows ya no la apaga para ahorrar energía."
    } catch { }
}
if ($acceso -and (Test-Path -LiteralPath $acceso)) {
    $destino = Join-Path ([Environment]::GetFolderPath("Startup")) (Split-Path $acceso -Leaf)
    $yaArranca = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Where-Object { "$($_.Command) $($_.Name)" -match '__PATRON__' }).Count
    if ($yaArranca -eq 0 -and -not (Test-Path -LiteralPath $destino)) {
        Copy-Item -LiteralPath $acceso -Destination $destino -Force
        $datos = Get-Content -LiteralPath $respaldo -Raw -Encoding UTF8 | ConvertFrom-Json
        $datos.Acceso = $destino
        $datos | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $respaldo -Encoding UTF8
        Write-Output "El programa de cámaras se abrirá solo al iniciar sesión."
    } else {
        Write-Output "El programa de cámaras ya se abre solo al iniciar Windows."
    }
} else {
    Write-Output "No se encontró el acceso directo del programa de cámaras; si quieres que se abra solo, añádelo al arranque."
}
'@

$script:codigoVigilanciaDeshacer = @'
$respaldo = Join-Path $env:LOCALAPPDATA "OptimizadorES\respaldo-vigilancia.json"
if (-not (Test-Path -LiteralPath $respaldo)) {
    Write-Output "No hay configuración de energía guardada; se deja como está."
    return
}
$datos = Get-Content -LiteralPath $respaldo -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($x in @($datos.Energia)) { powercfg /setacvalueindex SCHEME_CURRENT $x.Sub $x.Opcion $x.Valor 2>$null | Out-Null }
powercfg /setactive SCHEME_CURRENT | Out-Null
foreach ($r in @($datos.Red)) {
    if (@("Enabled", "Disabled") -contains [string]$r.Valor) {
        try { Set-NetAdapterPowerManagement -Name $r.Nombre -AllowComputerToTurnOffDevice $r.Valor -ErrorAction Stop } catch { }
    }
}
if ($datos.Acceso -and (Test-Path -LiteralPath $datos.Acceso)) {
    Remove-Item -LiteralPath $datos.Acceso -Force
    Write-Output "Quitado el arranque automático del programa de cámaras."
}
Remove-Item -LiteralPath $respaldo -Force
Write-Output "Energía y red vuelven a estar como antes."
'@

function Get-ItemVigilancia {
    if (-not $script:ProgramaCamaras) { $script:ProgramaCamaras = Find-ProgramaCamaras }
    $cam = $script:ProgramaCamaras
    $regs = @(
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" "NoAutoRebootWithLoggedOnUsers" 1)
    )
    $vistosExe = @{}
    foreach ($e in @($cam.Exes)) {
        if ($cam.UsarIntel) { $regs += New-Reg "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences" $e "GpuPreference=1;" "String" }
        $hoja = Split-Path $e -Leaf
        if ($vistosExe.ContainsKey($hoja)) { continue }
        $vistosExe[$hoja] = $true
        $regs += New-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$hoja\PerfOptions" "CpuPriorityClass" 6
    }
    $codigo = $script:codigoVigilancia.Replace("__ACCESO__", ([string]$cam.Acceso).Replace("'", "''")).Replace("__PATRON__", $script:PatronCamaras)
    $detalleCam = if ($cam.Exes.Count) { "Programa de cámaras encontrado: $($cam.Nombre) ($($cam.Exes.Count) archivo(s)). Se le da prioridad 'por encima de lo normal'" + $(if ($cam.UsarIntel) { " y se le asigna la gráfica Intel, que decodifica H.264/H.265 por hardware." } else { "." }) } else { "No se encontró iVMS ni otro programa de cámaras: solo se aplica la parte de energía, red y Windows Update." }
    return New-ItemPropio -Clave "OPT_VIGILANCIA" -Nombre "Equipo encendido 24/7 para grabar cámaras" -Grupo "Perfiles" -Riesgo "Bajo" `
        -Descripcion "Nunca suspende ni apaga discos, pantalla, USB ni red; Windows Update no reinicia solo con la sesión abierta; el programa de cámaras tiene prioridad y se abre al iniciar." `
        -Aviso "Gasta algo más de luz porque el equipo nunca descansa (es lo normal en un grabador)." `
        -Detalle ($detalleCam + "`nDeshacer devuelve la energía, la red y el arranque a como estaban.") `
        -Registro $regs -Script @($codigo) -Deshacer @($script:codigoVigilanciaDeshacer)
}

function Get-ItemPorClave([string]$Clave) {
    if ($Clave -eq "OPT_VIGILANCIA") { return (Get-ItemVigilancia) }
    if ($script:ItemsExtra.ContainsKey($Clave)) { return $script:ItemsExtra[$Clave] }
    return @($script:Ajustes | Where-Object { $_.Key -eq $Clave })[0]
}

$script:PerfilesDef = @(
    @{ Clave = "Basico"; Nombre = "Básico seguro"; Glifo = [string][char]0xE73E; Riesgo = "Bajo"
       Para = "Para cualquier PC. Quita telemetría, sugerencias y servicios que sobran, y evita que las apps se queden abiertas en segundo plano."
       Claves = { @($script:Ajustes | Where-Object { $_.Grupo -eq "Esenciales" -and $_.Riesgo -eq "Bajo" -and $_.Key -ne "WPFTweaksRestorePoint" } | ForEach-Object { $_.Key }) + @("OPT_FONDO") } }
    @{ Clave = "Oficina"; Nombre = "Oficina"; Glifo = [string][char]0xE821; Riesgo = "Bajo"
       Para = "Para trabajar: lo del perfil Básico más la privacidad verde (sin anuncios, sin seguimiento y sin consejos que interrumpen)."
       Claves = { @($script:Ajustes | Where-Object { $_.Grupo -eq "Esenciales" -and $_.Riesgo -eq "Bajo" -and $_.Key -ne "WPFTweaksRestorePoint" } | ForEach-Object { $_.Key }) + @("OPT_FONDO") + @($script:ItemsPrivacidad | Where-Object { $_.Riesgo -eq "Bajo" } | ForEach-Object { $_.Key }) } }
    @{ Clave = "Juegos"; Nombre = "Juegos"; Glifo = [string][char]0xE7FC; Riesgo = "Medio"
       Para = "Para jugar: lo del perfil Básico, plan de energía Alto rendimiento, modo de juego y sin grabación de fondo."
       Claves = { @($script:Ajustes | Where-Object { $_.Grupo -eq "Esenciales" -and $_.Riesgo -eq "Bajo" -and $_.Key -ne "WPFTweaksRestorePoint" } | ForEach-Object { $_.Key }) + @("OPT_FONDO", "OPT_ENERGIA_ALTA", "OPT_JUEGOS") } }
    @{ Clave = "Vigilancia"; Nombre = "PC de videovigilancia"; Glifo = [string][char]0xE714; Riesgo = "Bajo"
       Para = "Para un equipo que graba cámaras día y noche (iVMS-4200, SmartPSS...). No toca la red, el antivirus ni el programa de cámaras; solo evita que Windows lo interrumpa."
       Claves = { @("OPT_ENERGIA_ALTA", "OPT_VIGILANCIA", "OPT_FONDO", "OPT_SERVICIOS_RAM", "PRIV_CONSEJOS", "PRIV_SUGERENCIAS", "WPFTweaksConsumerFeatures") } }
)
$script:TarjetasPerfil = @{}

function Get-ItemsPerfil($Perfil) {
    return @(& $Perfil.Claves | Select-Object -Unique | ForEach-Object { Get-ItemPorClave $_ } | Where-Object { $_ })
}

function Update-EstadoPerfiles {
    foreach ($p in $script:PerfilesDef) {
        $t = $script:TarjetasPerfil[$p.Clave]
        if (-not $t) { continue }
        $items = Get-ItemsPerfil $p
        $hechos = @($items | Where-Object { Test-ItemAplicado $_ }).Count
        $comprobables = @($items | Where-Object { (@($_.registry | Where-Object { $_ }).Count + @($_.service | Where-Object { $_ }).Count) -gt 0 -or $_.Key -like "OPT_*" }).Count
        if ($comprobables -and $hechos -ge $comprobables) {
            $t.Estado.Text = "$([char]0x2714) Aplicado en este equipo"
            $t.Estado.Foreground = Get-Pincel "#16A34A"
            $t.Marco.BorderBrush = Get-Pincel "#86EFAC"
        } elseif ($hechos) {
            $t.Estado.Text = "Aplicado en parte: $hechos de $comprobables cambios ya están hechos."
            $t.Estado.Foreground = Get-Pincel "#D97706"
            $t.Marco.BorderBrush = Get-Pincel "#E2E6EC"
        } else {
            $t.Estado.Text = "Sin aplicar."
            $t.Estado.Foreground = Get-Pincel "#6B7280"
            $t.Marco.BorderBrush = Get-Pincel "#E2E6EC"
        }
    }
    if ($script:TxtCamaras -and $script:ProgramaCamaras) {
        $cam = $script:ProgramaCamaras
        $script:TxtCamaras.Text = if ($cam.Exes.Count) {
            "$([char]0x2714) Programa de cámaras detectado: $($cam.Nombre). " + $(if ($cam.UsarIntel) { "Se usará la gráfica Intel para el video." } else { "" }) + $(if ($cam.Acceso) { " Se abrirá solo al encender." } else { "" })
        } else { "No se encontró iVMS ni otro programa de cámaras. Si lo tienes abierto ahora, el perfil lo detecta igual al aplicarlo." }
    }
}

function Start-Perfil([string]$Clave, [bool]$Deshacer) {
    $perfil = @($script:PerfilesDef | Where-Object { $_.Clave -eq $Clave })[0]
    if (-not $perfil) { return }
    if ($Clave -eq "Vigilancia") { $script:ProgramaCamaras = Find-ProgramaCamaras }
    $items = Get-ItemsPerfil $perfil
    if (-not $Deshacer) {
        $pendientes = @($items | Where-Object { -not (Test-ItemAplicado $_) })
        if ($pendientes.Count -eq 0) {
            [void][System.Windows.MessageBox]::Show("El perfil '$($perfil.Nombre)' ya está aplicado en este equipo.", "Perfiles", "OK", "Information")
            return
        }
        $msg = "Perfil '$($perfil.Nombre)': se aplicarán $($pendientes.Count) cambio(s):`r`n" + (($pendientes | Select-Object -First 25 | ForEach-Object { " - $($_.Nombre)" }) -join "`r`n")
        if ($pendientes.Count -gt 25) { $msg += "`r`n ... y $($pendientes.Count - 25) más" }
        $medios = @($pendientes | Where-Object { $_.Riesgo -ne "Bajo" })
        if ($medios.Count) { $msg += "`r`n`r`nTen en cuenta:`r`n" + (($medios | ForEach-Object { " - $($_.Nombre): $($_.Aviso)" }) -join "`r`n") }
        $msg += "`r`n`r`nAntes se crea un punto de restauración y se guarda cómo estaba cada cosa, así 'Deshacer perfil' lo deja igual que ahora.`r`n`r`n¿Continuar?"
        if ([System.Windows.MessageBox]::Show($msg, "Aplicar perfil", "YesNo", $(if ($medios.Count) { "Warning" } else { "Question" })) -ne "Yes") { return }
        $pasos = @([pscustomobject]@{ Item = (Get-ItemPorClave "WPFTweaksRestorePoint"); Deshacer = $false })
        $pasos += @($pendientes | ForEach-Object { [pscustomobject]@{ Item = $_; Deshacer = $false } })
        Start-Pasos -Pasos $pasos -Titulo "Perfil $($perfil.Nombre)" -OfrecerReinicio
    } else {
        $hechos = @($items | Where-Object { Test-ItemAplicado $_ })
        if ($hechos.Count -eq 0) {
            [void][System.Windows.MessageBox]::Show("No hay nada de este perfil aplicado que se pueda deshacer.", "Perfiles", "OK", "Information")
            return
        }
        $msg = "Se desharán $($hechos.Count) cambio(s) del perfil '$($perfil.Nombre)' y todo vuelve a como estaba antes de aplicarlo.`r`n`r`nOjo: si alguno de estos ajustes ya lo tenías aplicado por tu cuenta, también se deshace.`r`n`r`n¿Continuar?"
        if ([System.Windows.MessageBox]::Show($msg, "Deshacer perfil", "YesNo", "Question") -ne "Yes") { return }
        [array]::Reverse($hechos)
        Start-Pasos -Pasos @($hechos | ForEach-Object { [pscustomobject]@{ Item = $_; Deshacer = $true } }) -Titulo "Deshacer perfil $($perfil.Nombre)" -OfrecerReinicio
    }
}

$pPerf = $script:UI.PanelPerfiles
[void]$pPerf.Children.Add((New-Titulo "Perfiles de un clic" "Elige para qué usas este equipo y se aplica todo lo que conviene de una vez. Siempre se crea antes un punto de restauración y cada perfil se puede deshacer."))
foreach ($p in $script:PerfilesDef) {
    $marco = New-Marco -Relleno "16,12"
    $pila = New-Object System.Windows.Controls.StackPanel
    $cab = New-Object System.Windows.Controls.DockPanel
    $color = $script:Colores[$p.Riesgo]
    $etq = New-Object System.Windows.Controls.Border
    $etq.Background = Get-Pincel $color.Fondo
    $etq.CornerRadius = 10
    $etq.Padding = "8,1"
    $etq.VerticalAlignment = "Center"
    $etq.Child = New-Texto $color.Etiqueta $color.Texto 11 "SemiBold"
    [System.Windows.Controls.DockPanel]::SetDock($etq, "Right")
    [void]$cab.Children.Add($etq)
    $ico = New-Texto $p.Glifo "#2563EB" 20
    $ico.FontFamily = "Segoe MDL2 Assets"
    $ico.Margin = "0,0,12,0"
    $ico.VerticalAlignment = "Center"
    [System.Windows.Controls.DockPanel]::SetDock($ico, "Left")
    [void]$cab.Children.Add($ico)
    [void]$cab.Children.Add((New-Texto $p.Nombre "#111827" 16 "SemiBold"))
    [void]$pila.Children.Add($cab)
    [void]$pila.Children.Add((New-Texto $p.Para "#4B5563" 13 "Normal" "32,4,0,0"))
    if ($p.Clave -eq "Vigilancia") {
        $script:TxtCamaras = New-Texto "Se buscará el programa de cámaras al abrir esta pestaña." "#1D4ED8" 12.5 "SemiBold" "32,4,0,0"
        [void]$pila.Children.Add($script:TxtCamaras)
        $consejos = "Además, hazlo tú una vez:`n" +
            "  • En iVMS: Configuración del sistema > Imagen > Hardware: D3D11 (decodificación por hardware).`n" +
            "  • En la BIOS: 'Restore on AC Power Loss' = Power On, para que encienda solo tras un corte de luz.`n" +
            "  • Graba en un disco aparte y revisa su salud en Rendimiento > Salud de discos."
        [void]$pila.Children.Add((New-Texto $consejos "#6B7280" 12 "Normal" "32,6,0,0"))
    }
    # Lista de lo que hace (se arma al abrir, para que la ventana cargue rápido)
    $exp = New-Object System.Windows.Controls.Expander
    $exp.Header = "Ver la lista de cambios"
    $exp.Foreground = Get-Pincel "#2563EB"
    $exp.FontSize = 12
    $exp.Margin = "32,6,0,0"
    $exp.Tag = $p.Clave
    $exp.Add_Expanded({
        param($origen, $e)
        $perfil = @($script:PerfilesDef | Where-Object { $_.Clave -eq $origen.Tag })[0]
        $lineas = foreach ($it in (Get-ItemsPerfil $perfil)) {
            $marca = if (Test-ItemAplicado $it) { [char]0x2714 } else { [char]0x2022 }
            "$marca $($it.Nombre) ($($script:Colores[$it.Riesgo].Etiqueta.ToLower()))"
        }
        $txt = New-Object System.Windows.Controls.TextBox
        $txt.Text = (@($lineas) -join "`n") + "`n`n$([char]0x2714) = ya está hecho en este equipo."
        $txt.IsReadOnly = $true
        $txt.TextWrapping = "Wrap"
        $txt.BorderThickness = 0
        $txt.Background = Get-Pincel "#F3F4F6"
        $txt.Foreground = Get-Pincel "#374151"
        $txt.FontSize = 12
        $txt.Padding = "10,8"
        $txt.Margin = "0,4,0,2"
        $origen.Content = $txt
    })
    [void]$pila.Children.Add($exp)
    $estadoP = New-Texto "" "#6B7280" 12.5 "SemiBold" "32,6,0,0"
    [void]$pila.Children.Add($estadoP)
    $fila = New-Object System.Windows.Controls.WrapPanel
    $fila.Margin = "32,8,0,0"
    [void]$fila.Children.Add((New-Boton "Aplicar perfil" ([scriptblock]::Create("Start-Perfil '$($p.Clave)' `$false")) -Primario))
    [void]$fila.Children.Add((New-Boton "Deshacer perfil" ([scriptblock]::Create("Start-Perfil '$($p.Clave)' `$true"))))
    [void]$pila.Children.Add($fila)
    $marco.Child = $pila
    [void]$pPerf.Children.Add($marco)
    $script:TarjetasPerfil[$p.Clave] = @{ Marco = $marco; Estado = $estadoP }
}

# ---------------------------------------------------------------- Pestaña Privacidad (por niveles, como O&O ShutUp10)
$cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
$consent = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore"
$script:ItemsPrivacidad = @(
    (New-ItemPropio "PRIV_PUBLICIDAD" "Sin ID de publicidad" "Privacidad" "Bajo" "Las apps no pueden usar un identificador tuyo para mostrarte anuncios personalizados." "" @(
        (New-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" 0 "DWord" 1),
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" "DisabledByGroupPolicy" 1))),
    (New-ItemPropio "PRIV_SUGERENCIAS" "Sin anuncios ni apps sugeridas en Inicio" "Privacidad" "Bajo" "Windows deja de instalar solo juegos y apps promocionadas (Candy Crush, etc.) y de mostrar sugerencias en el menú Inicio." "" @(
        (New-Reg $cdm "SystemPaneSuggestionsEnabled" 0 "DWord" 1), (New-Reg $cdm "SubscribedContent-338388Enabled" 0 "DWord" 1),
        (New-Reg $cdm "SilentInstalledAppsEnabled" 0 "DWord" 1), (New-Reg $cdm "PreInstalledAppsEnabled" 0 "DWord" 1),
        (New-Reg $cdm "OemPreInstalledAppsEnabled" 0 "DWord" 1))),
    (New-ItemPropio "PRIV_CONSEJOS" "Sin consejos ni avisos de 'termina de configurar'" "Privacidad" "Bajo" "Quita las notificaciones de trucos de Windows, la pantalla de bienvenida tras actualizar y el aviso de 'Terminemos de configurar el dispositivo'." "" @(
        (New-Reg $cdm "SubscribedContent-338389Enabled" 0 "DWord" 1), (New-Reg $cdm "SoftLandingEnabled" 0 "DWord" 1),
        (New-Reg $cdm "SubscribedContent-310093Enabled" 0 "DWord" 1),
        (New-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement" "ScoobeSystemSettingEnabled" 0))),
    (New-ItemPropio "PRIV_CONFIGURACION" "Sin contenido sugerido en Configuración" "Privacidad" "Bajo" "La app Configuración deja de mostrarte sugerencias y promociones de Microsoft." "" @(
        (New-Reg $cdm "SubscribedContent-338393Enabled" 0 "DWord" 1), (New-Reg $cdm "SubscribedContent-353694Enabled" 0 "DWord" 1),
        (New-Reg $cdm "SubscribedContent-353696Enabled" 0 "DWord" 1))),
    (New-ItemPropio "PRIV_IDIOMAS" "Las webs no ven tu lista de idiomas" "Privacidad" "Bajo" "Las páginas web ya no pueden leer qué idiomas tienes instalados (se usa para identificarte)." "" @(
        (New-Reg "HKCU:\Control Panel\International\User Profile" "HttpAcceptLanguageOptOut" 1))),
    (New-ItemPropio "PRIV_APPS_ABIERTAS" "No registrar qué apps abres" "Privacidad" "Bajo" "Windows deja de anotar qué programas abres para ordenar el menú Inicio y la búsqueda." "La lista de 'más usadas' del menú Inicio queda vacía." @(
        (New-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_TrackProgs" 0 "DWord" 1))),
    (New-ItemPropio "PRIV_EXPERIENCIAS" "Sin experiencias personalizadas con tus datos" "Privacidad" "Bajo" "Microsoft no usa tus datos de diagnóstico para mostrarte consejos, anuncios y recomendaciones." "" @(
        (New-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" 0 "DWord" 1),
        (New-Reg "HKCU:\Software\Policies\Microsoft\Windows\CloudContent" "DisableTailoredExperiencesWithDiagnosticData" 1))),
    (New-ItemPropio "PRIV_OPINIONES" "Windows no te pide tu opinión" "Privacidad" "Bajo" "Desactiva las encuestas y ventanas de 'califica tu experiencia'." "" @(
        (New-Reg "HKCU:\Software\Microsoft\Siuf\Rules" "NumberOfSIUFInPeriod" 0),
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DoNotShowFeedbackNotifications" 1))),
    (New-ItemPropio "PRIV_TELEMETRIA" "Telemetría al mínimo" "Privacidad" "Medio" "Windows envía a Microsoft solo los datos de diagnóstico imprescindibles." "El programa Windows Insider deja de funcionar y algunos solucionadores automáticos de problemas tienen menos información." @(
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0),
        (New-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" 0))),
    (New-ItemPropio "PRIV_ACTIVIDAD" "Sin historial de actividad" "Privacidad" "Medio" "Windows deja de guardar y subir a la nube lo que haces (documentos, páginas, apps)." "La 'Línea de tiempo' de Windows 10 y 'seguir donde lo dejaste' en otros equipos dejan de funcionar." @(
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" 0),
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "PublishUserActivities" 0),
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "UploadUserActivities" 0))),
    (New-ItemPropio "PRIV_ESCRITURA" "No enviar lo que escribes ni tu voz" "Privacidad" "Medio" "Windows deja de recopilar lo que tecleas, escribes a mano o dictas para 'mejorar' el reconocimiento." "El dictado por voz en línea (Windows + H) deja de funcionar." @(
        (New-Reg "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitInkCollection" 1 "DWord" 0),
        (New-Reg "HKCU:\Software\Microsoft\InputPersonalization" "RestrictImplicitTextCollection" 1 "DWord" 0),
        (New-Reg "HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore" "HarvestContacts" 0 "DWord" 1),
        (New-Reg "HKCU:\Software\Microsoft\Personalization\Settings" "AcceptedPrivacyPolicy" 0 "DWord" 1),
        (New-Reg "HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" "HasAccepted" 0 "DWord" 1))),
    (New-ItemPropio "PRIV_BUSQUEDA" "Búsqueda solo en el equipo (sin Bing ni Cortana)" "Privacidad" "Medio" "Lo que escribes en la búsqueda de Inicio ya no se envía a Bing, y Cortana queda desactivada." "La búsqueda de Inicio deja de mostrar resultados de Internet." @(
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 0),
        (New-Reg "HKCU:\Software\Policies\Microsoft\Windows\Explorer" "DisableSearchBoxSuggestions" 1),
        (New-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" 0 "DWord" 1))),
    (New-ItemPropio "PRIV_ERRORES" "No enviar informes de errores a Microsoft" "Privacidad" "Medio" "Cuando un programa se cuelga, Windows ya no manda el informe a Microsoft." "Microsoft no podrá ofrecerte soluciones a cuelgues conocidos." @(
        (New-Reg "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled" 1),
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" 1))),
    (New-ItemPropio "PRIV_COPILOT" "Copilot y Recall desactivados" "Privacidad" "Medio" "Apaga el asistente Copilot y que Windows guarde capturas de lo que haces (Recall), donde existan." "Si usas Copilot en Windows, deja de estar disponible." @(
        (New-Reg "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1),
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" 1),
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" 1))),
    (New-ItemPropio "PRIV_UBICACION" "Ubicación apagada en todo el equipo" "Privacidad" "Alto" "Ninguna app ni Windows pueden saber dónde está el equipo." "Dejan de funcionar mapas, el tiempo local, 'Buscar mi dispositivo' y la zona horaria automática." @(
        (New-Reg "$consent\location" "Value" "Deny" "String" "Allow"))),
    (New-ItemPropio "PRIV_CAMARA" "Ninguna app puede usar la cámara web" "Privacidad" "Alto" "Bloquea la cámara web para todas las apps." "Las videollamadas (Zoom, Teams, WhatsApp) dejan de ver la cámara. No afecta a las cámaras IP de vigilancia, que van por la red." @(
        (New-Reg "$consent\webcam" "Value" "Deny" "String" "Allow"))),
    (New-ItemPropio "PRIV_MICROFONO" "Ninguna app puede usar el micrófono" "Privacidad" "Alto" "Bloquea el micrófono para todas las apps." "Las llamadas, el dictado y las grabaciones de audio dejan de oírte." @(
        (New-Reg "$consent\microphone" "Value" "Deny" "String" "Allow"))),
    (New-ItemPropio "PRIV_SINCRONIZAR" "No sincronizar ajustes con tu cuenta Microsoft" "Privacidad" "Alto" "El fondo, el idioma, las contraseñas de Wi-Fi y otros ajustes dejan de copiarse a tu cuenta y a tus otros equipos." "Si cambias de PC, tendrás que volver a configurar todo a mano." @(
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSync" 2),
        (New-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSyncUserOverride" 1)))
)
foreach ($it in $script:ItemsPrivacidad) { $script:ItemsExtra[$it.Key] = $it }

$pPriv = $script:UI.PanelPrivacidad
$script:CasillasPriv = @()
$script:InfoPriv = @{}
$filaPriv = New-Object System.Windows.Controls.WrapPanel
$filaPriv.Margin = "0,0,0,6"
[void]$filaPriv.Children.Add((New-Boton "Marcar los verdes" { foreach ($c in $script:CasillasPriv) { $c.IsChecked = ($c.Tag.Riesgo -eq "Bajo" -and -not $script:InfoPriv[$c.Tag.Key].Hecho) } } -Libre))
[void]$filaPriv.Children.Add((New-Boton "Marcar verdes y amarillos" { foreach ($c in $script:CasillasPriv) { $c.IsChecked = ($c.Tag.Riesgo -ne "Alto" -and -not $script:InfoPriv[$c.Tag.Key].Hecho) } } -Libre))
[void]$filaPriv.Children.Add((New-Boton "Quitar marcas" { foreach ($c in $script:CasillasPriv) { $c.IsChecked = $false } } -Libre))
[void]$filaPriv.Children.Add((New-Boton "Deshacer marcados" { Start-Privacidad -Deshacer $true }))
[void]$filaPriv.Children.Add((New-Boton "Aplicar marcados" { Start-Privacidad -Deshacer $false } -Primario))
[void]$pPriv.Children.Add($filaPriv)
[void]$pPriv.Children.Add((New-Texto "Como O&O ShutUp10: verde se puede aplicar sin miedo, amarillo quita alguna función que quizá uses y rojo solo si sabes lo que haces. Antes de cambiar nada se guarda cómo estaba, y 'Deshacer marcados' lo deja exacto." "#6B7280" 12.5 "Normal" "0,0,0,8"))
$nivelesPriv = @(
    @{ Riesgo = "Bajo";  Titulo = "Verde: recomendado"; Sub = "No rompen nada; solo quitan anuncios, seguimiento y molestias." },
    @{ Riesgo = "Medio"; Titulo = "Amarillo: con cuidado"; Sub = "Mejoran la privacidad, pero apagan alguna función de Windows. Lee el aviso de cada uno." },
    @{ Riesgo = "Alto";  Titulo = "Rojo: solo si sabes lo que haces"; Sub = "Bloquean cosas que muchas apps necesitan (cámara, micrófono, ubicación)." }
)
foreach ($n in $nivelesPriv) {
    [void]$pPriv.Children.Add((New-Titulo $n.Titulo $n.Sub))
    foreach ($it in @($script:ItemsPrivacidad | Where-Object { $_.Riesgo -eq $n.Riesgo })) {
        $t = New-Tarjeta -Item $it -Marcado $false
        [void]$pPriv.Children.Add($t.Borde)
        $script:CasillasPriv += $t.Casilla
        $script:InfoPriv[$it.Key] = @{ Tarjeta = $t; Hecho = $false }
    }
}

function Update-VistaPrivacidad {
    foreach ($c in $script:CasillasPriv) {
        $info = $script:InfoPriv[$c.Tag.Key]
        $info.Hecho = Test-AjusteAplicado $c.Tag
        $t = $info.Tarjeta
        if ($info.Hecho) {
            $t.Estado.Text = "$([char]0x2714) Ya aplicado en este equipo"
            $t.Estado.Foreground = Get-Pincel "#1E7B3A"
            $t.Estado.Visibility = "Visible"
            $t.Borde.BorderBrush = Get-Pincel "#86EFAC"
        } else {
            $t.Estado.Visibility = "Collapsed"
            $t.Borde.BorderBrush = Get-Pincel "#E2E6EC"
        }
    }
}

function Start-Privacidad([bool]$Deshacer) {
    $sel = @($script:CasillasPriv | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    if ($Deshacer) { $sel = @($sel | Where-Object { $script:InfoPriv[$_.Key].Hecho }) } else { $sel = @($sel | Where-Object { -not $script:InfoPriv[$_.Key].Hecho }) }
    if ($sel.Count -eq 0) {
        $txtVacio = if ($Deshacer) { "Marca opciones que ya estén aplicadas (con $([char]0x2714)) para deshacerlas." } else { "Marca al menos una opción que aún no esté aplicada." }
        [void][System.Windows.MessageBox]::Show($txtVacio, "Privacidad", "OK", "Information")
        return
    }
    $verbo = if ($Deshacer) { "deshacer" } else { "aplicar" }
    $msg = "Vas a $verbo $($sel.Count) opción(es) de privacidad:`r`n" + (($sel | ForEach-Object { " - $($_.Nombre)" }) -join "`r`n")
    $rojos = @($sel | Where-Object { $_.Riesgo -eq "Alto" })
    if ($rojos.Count -and -not $Deshacer) { $msg += "`r`n`r`nROJAS (revisa):`r`n" + (($rojos | ForEach-Object { " - $($_.Nombre): $($_.Aviso)" }) -join "`r`n") }
    $msg += "`r`n`r`n¿Continuar?"
    if ([System.Windows.MessageBox]::Show($msg, "Privacidad", "YesNo", $(if ($rojos.Count) { "Warning" } else { "Question" })) -ne "Yes") { return }
    Start-Pasos -Pasos @($sel | ForEach-Object { [pscustomobject]@{ Item = $_; Deshacer = $Deshacer } }) -Titulo "Privacidad"
}
Update-VistaPrivacidad

# ---------------------------------------------------------------- Pestaña Arranque de Windows (como Autoruns)
$script:RutaServiciosArranque = Join-Path $env:LOCALAPPDATA "OptimizadorES\arranque-servicios.json"

$script:codigoListaArranque = @'
$lista = $global:Estado.Arranque
$firmas = @{}
function Get-Firma([string]$Archivo) {
    if (-not $Archivo -or -not (Test-Path -LiteralPath $Archivo -PathType Leaf)) { return $null }
    if ($firmas.ContainsKey($Archivo)) { return $firmas[$Archivo] }
    $f = $null
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Archivo -ErrorAction Stop
        $quien = ""
        if ($s.SignerCertificate) { $quien = ($s.SignerCertificate.Subject -split ",")[0] -replace '^CN=', '' -replace '"', '' }
        $f = [pscustomobject]@{ Valida = ($s.Status -eq "Valid"); Firmante = $quien }
    } catch { }
    $firmas[$Archivo] = $f
    return $f
}
function Get-RutaExe([string]$Comando) {
    if (-not $Comando) { return "" }
    $c = [Environment]::ExpandEnvironmentVariables($Comando.Trim())
    if ($c.StartsWith('"')) { $c = $c.Substring(1); $i = $c.IndexOf('"'); if ($i -gt 0) { return $c.Substring(0, $i) } }
    if ($c -match '^(.+?\.(exe|com|bat|cmd|ps1|vbs|js|scr|dll))(\s|,|$)') { return $Matches[1] }
    return ($c -split '\s')[0]
}
function Test-Aprobado([string]$Clave, [string]$Valor) {
    try {
        $b = (Get-ItemProperty -LiteralPath $Clave -Name $Valor -ErrorAction Stop).$Valor
        if ($b -is [byte[]] -and $b.Length) { return (($b[0] -band 1) -eq 0) }
    } catch { }
    return $true
}
function Add-Entrada([hashtable]$Datos) {
    $ruta = [string]$Datos.Ruta
    $f = Get-Firma $ruta
    $Datos.Firmante = if ($f) { $f.Firmante } else { "" }
    $Datos.Firma = if (-not $ruta -or -not (Test-Path -LiteralPath $ruta)) { "NoExiste" } elseif (-not $f -or -not $f.Firmante) { "SinFirma" } elseif ($f.Valida) { "Valida" } else { "NoValida" }
    [void]$lista.Add($Datos)
}

Write-Output "Leyendo los programas que arrancan con Windows..."
$aprob = "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved"
$fuentes = @(
    @{ Clave = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"; Aprob = "HKCU:\$aprob\Run"; Origen = "Registro, solo tu usuario" },
    @{ Clave = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Aprob = "HKLM:\$aprob\Run"; Origen = "Registro, todos los usuarios" },
    @{ Clave = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"; Aprob = "HKLM:\$aprob\Run32"; Origen = "Registro, todos los usuarios (32 bits)" }
)
foreach ($fu in $fuentes) {
    if (-not (Test-Path -LiteralPath $fu.Clave)) { continue }
    $k = Get-Item -LiteralPath $fu.Clave
    foreach ($n in $k.GetValueNames()) {
        if (-not $n) { continue }
        $cmd = [string]$k.GetValue($n)
        Add-Entrada @{ Id = "R|$($fu.Clave)|$n"; Tipo = "Programa"; Nombre = $n; Comando = $cmd; Ruta = (Get-RutaExe $cmd); Origen = $fu.Origen
            Activo = (Test-Aprobado $fu.Aprob $n); Aprobado = $fu.Aprob; Valor = $n }
    }
}
$carpetas = @(
    @{ Ruta = [Environment]::GetFolderPath("Startup"); Aprob = "HKCU:\$aprob\StartupFolder"; Origen = "Carpeta Inicio, solo tu usuario" },
    @{ Ruta = [Environment]::GetFolderPath("CommonStartup"); Aprob = "HKLM:\$aprob\StartupFolder"; Origen = "Carpeta Inicio, todos los usuarios" }
)
$shell = New-Object -ComObject WScript.Shell
foreach ($ca in $carpetas) {
    if (-not $ca.Ruta -or -not (Test-Path -LiteralPath $ca.Ruta)) { continue }
    foreach ($ar in @(Get-ChildItem -LiteralPath $ca.Ruta -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "desktop.ini" })) {
        $destino = $ar.FullName; $cmd = $ar.FullName
        if ($ar.Extension -eq ".lnk") {
            try { $l = $shell.CreateShortcut($ar.FullName); if ($l.TargetPath) { $destino = $l.TargetPath; $cmd = "$($l.TargetPath) $($l.Arguments)".Trim() } } catch { }
        }
        Add-Entrada @{ Id = "C|$($ar.FullName)"; Tipo = "Programa"; Nombre = $ar.BaseName; Comando = $cmd; Ruta = $destino; Origen = $ca.Origen
            Activo = (Test-Aprobado $ca.Aprob $ar.Name); Aprobado = $ca.Aprob; Valor = $ar.Name; Archivo = $ar.FullName }
    }
}

Write-Output "Leyendo las tareas programadas que se ejecutan al encender o al iniciar sesión..."
foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike "\Microsoft\*" })) {
    $disparos = @($t.Triggers | Where-Object { $_ -and $_.CimClass.CimClassName -match "Logon|Boot" })
    if (-not $disparos.Count) { continue }
    $acc = @($t.Actions | Where-Object { $_.Execute })[0]
    $exe = if ($acc) { [string]$acc.Execute } else { "" }
    $cmd = if ($acc) { "$($acc.Execute) $($acc.Arguments)".Trim() } else { "" }
    $cuando = if (@($disparos | Where-Object { $_.CimClass.CimClassName -match "Boot" }).Count) { "al encender" } else { "al iniciar sesión" }
    Add-Entrada @{ Id = "T|$($t.TaskPath)$($t.TaskName)"; Tipo = "Tarea"; Nombre = $t.TaskName; Comando = $cmd; Ruta = (Get-RutaExe $exe)
        Origen = "Tarea programada ($cuando), carpeta $($t.TaskPath)"; Activo = ([string]$t.State -ne "Disabled"); TareaRuta = $t.TaskPath; TareaNombre = $t.TaskName }
}

Write-Output "Leyendo los servicios de otros fabricantes..."
$cambiados = @{}
$rutaCambiados = Join-Path $env:LOCALAPPDATA "OptimizadorES\arranque-servicios.json"
if (Test-Path -LiteralPath $rutaCambiados) {
    try { $o = Get-Content -LiteralPath $rutaCambiados -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($pr in $o.PSObject.Properties) { $cambiados[$pr.Name] = [string]$pr.Value } } catch { }
}
foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
    if (-not $s.PathName -or $s.PathName -match '(?i)\\Windows\\(System32|SysWOW64|servicing|WinSxS|Microsoft\.NET)\\') { continue }
    $esAuto = ($s.StartMode -eq "Auto")
    if (-not $esAuto -and -not $cambiados.ContainsKey([string]$s.Name)) { continue }
    $inicio = if ($esAuto -and $s.DelayedAutoStart) { "AutomaticDelayedStart" } elseif ($esAuto) { "Automatic" } else { [string]$s.StartMode }
    Add-Entrada @{ Id = "S|$($s.Name)"; Tipo = "Servicio"; Nombre = [string]$s.DisplayName; Comando = [string]$s.PathName; Ruta = (Get-RutaExe ([string]$s.PathName))
        Origen = "Servicio '$($s.Name)' ($(if ($s.State -eq 'Running') { 'funcionando' } else { 'detenido' }))"; Activo = $esAuto; Servicio = [string]$s.Name; Inicio = $inicio }
}
Write-Output "Arranque leído: $($lista.Count) elemento(s)."
'@

$script:PatronCritico = '(?i)SecurityHealth|Defender|ESET|egui|ekrn|Avast|AVG|Kaspersky|Norton|McAfee|Bitdefender|Sophos|Malwarebytes|Realtek|RtkAud|Synaptics|ELAN|NVIDIA|AMD|Radeon|Intel|iVMS|Hik|SmartPSS|Dahua|OneDrive|Audio|Touchpad|Bluetooth'

function Start-ListaArranque {
    if ($script:Trabajo) { return }
    $script:ArranqueCargado = $true
    $global:Estado.Arranque = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $script:PanelListaArranque.Children.Clear()
    [void]$script:PanelListaArranque.Children.Add((New-Texto "Leyendo el arranque (unos segundos)..." "#6B7280"))
    Start-Pasos -Pasos @(New-PasoScript -Nombre "Leer el arranque de Windows" -Codigo $script:codigoListaArranque) -Silencioso
    if ($script:Trabajo) { $script:AlTerminar = { Show-Arranque } }
}

function Set-EntradaArranque($Entrada, [bool]$Activar, [switch]$SinHistorial) {
    try {
        switch ($Entrada.Tipo) {
            "Programa" {
                if (-not (Test-Path -LiteralPath $Entrada.Aprobado)) { New-Item -Path $Entrada.Aprobado -Force | Out-Null }
                # El mismo valor que escribe el Administrador de tareas: 02 = activo, 03 + fecha = desactivado
                $bytes = if ($Activar) { [byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) } else { [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime())) }
                New-ItemProperty -LiteralPath $Entrada.Aprobado -Name $Entrada.Valor -Value $bytes -PropertyType Binary -Force -ErrorAction Stop | Out-Null
            }
            "Tarea" {
                if ($Activar) { Enable-ScheduledTask -TaskPath $Entrada.TareaRuta -TaskName $Entrada.TareaNombre -ErrorAction Stop | Out-Null }
                else { Disable-ScheduledTask -TaskPath $Entrada.TareaRuta -TaskName $Entrada.TareaNombre -ErrorAction Stop | Out-Null }
            }
            "Servicio" {
                $mapa = @{}
                if (Test-Path -LiteralPath $script:RutaServiciosArranque) {
                    try { $o = Get-Content -LiteralPath $script:RutaServiciosArranque -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($pr in $o.PSObject.Properties) { $mapa[$pr.Name] = [string]$pr.Value } } catch { }
                }
                if ($Activar) {
                    $original = $mapa[$Entrada.Servicio]
                    if (-not $original -or $original -eq "Manual") { $original = "Automatic" }
                    if ($original -eq "AutomaticDelayedStart") { sc.exe config $Entrada.Servicio start= delayed-auto | Out-Null; if ($LASTEXITCODE) { throw "sc.exe devolvió $LASTEXITCODE" } }
                    else { Set-Service -Name $Entrada.Servicio -StartupType $original -ErrorAction Stop }
                    $mapa.Remove($Entrada.Servicio)
                } else {
                    if (-not $mapa.ContainsKey($Entrada.Servicio)) { $mapa[$Entrada.Servicio] = [string]$Entrada.Inicio }
                    Set-Service -Name $Entrada.Servicio -StartupType Manual -ErrorAction Stop
                }
                New-Item -ItemType Directory -Force -Path (Split-Path $script:RutaServiciosArranque) | Out-Null
                $mapa | ConvertTo-Json | Set-Content -LiteralPath $script:RutaServiciosArranque -Encoding UTF8
            }
        }
        $Entrada.Activo = $Activar
        $verbo = if ($Activar) { "Activado" } else { "Desactivado" }
        Escribir-Log "Arranque: $($verbo.ToLower()) '$($Entrada.Nombre)' ($($Entrada.Origen))."
        if (-not $SinHistorial) {
            $datosH = @{}
            foreach ($k in "Id", "Tipo", "Nombre", "Origen", "Aprobado", "Valor", "TareaRuta", "TareaNombre", "Servicio", "Inicio") { if ($Entrada[$k]) { $datosH[$k] = $Entrada[$k] } }
            Add-Historial -Tipo "Arranque" -Clave $Entrada.Id -Nombre "Arranque: $($Entrada.Nombre)" -Accion $verbo -Datos $datosH
        }
        return $true
    } catch {
        Escribir-Log "No se pudo cambiar '$($Entrada.Nombre)' en el arranque: $($_.Exception.Message)" "ERROR"
        if (-not $Prueba) { [void][System.Windows.MessageBox]::Show("No se pudo cambiar '$($Entrada.Nombre)':`r`n$($_.Exception.Message)`r`n`r`nAlgunos antivirus protegen sus propios servicios y no dejan cambiarlos.", "Arranque", "OK", "Warning") }
        return $false
    }
}

function Switch-EntradaArranque([string]$Id) {
    $e = @($global:Estado.Arranque | Where-Object { $_.Id -eq $Id })[0]
    if (-not $e) { return }
    $activar = -not $e.Activo
    if (-not $activar) {
        $texto = "$($e.Nombre) $($e.Comando) $($e.Firmante)"
        $aviso = ""
        if ($e.Tipo -eq "Servicio") { $aviso = "Es un servicio: pasará a inicio manual (se aplica al reiniciar). Si es del antivirus, de controladores o del programa de cámaras, NO lo desactives." }
        elseif ($texto -match $script:PatronCritico) { $aviso = "Parece de tu antivirus, de un controlador (audio, touchpad, gráficos) o del programa de cámaras. Si lo desactivas, eso puede dejar de funcionar al reiniciar." }
        if ($aviso -and [System.Windows.MessageBox]::Show("¿Desactivar '$($e.Nombre)' del arranque?`r`n`r`n$aviso`r`n`r`nSe puede volver a activar aquí mismo o desde el Historial.", "Arranque", "YesNo", "Warning") -ne "Yes") { return }
    }
    if (Set-EntradaArranque $e $activar) { Show-Arranque }
}

function Show-Arranque {
    $panel = $script:PanelListaArranque
    $panel.Children.Clear()
    $lista = @($global:Estado.Arranque)
    $activos = @($lista | Where-Object { $_.Activo }).Count
    $sinFirma = @($lista | Where-Object { $_.Activo -and $_.Firma -ne "Valida" }).Count
    $res = "$activos de $($lista.Count) elemento(s) se ejecutan al encender."
    if ($sinFirma) { $res += " $sinFirma activo(s) sin firma digital válida: revísalos (no siempre es malo, pero el malware casi nunca va firmado)." }
    [void]$panel.Children.Add((New-Texto $res "#111827" 13.5 "SemiBold" "0,0,0,8"))
    $secciones = @(
        @{ Tipo = "Programa"; Titulo = "Programas" },
        @{ Tipo = "Tarea"; Titulo = "Tareas programadas" },
        @{ Tipo = "Servicio"; Titulo = "Servicios de otros fabricantes (no de Windows)" }
    )
    foreach ($sec in $secciones) {
        $grupo = @($lista | Where-Object { $_.Tipo -eq $sec.Tipo } | Sort-Object @{ Expression = { -not $_.Activo } }, @{ Expression = { [string]$_.Nombre } })
        [void]$panel.Children.Add((New-Texto "$($sec.Titulo) ($($grupo.Count))" "#374151" 14 "SemiBold" "0,10,0,6"))
        if (-not $grupo.Count) { [void]$panel.Children.Add((New-Texto "Ninguno." "#9CA3AF" 12.5 "Normal" "0,0,0,4")); continue }
        foreach ($e in $grupo) {
            $marco = New-Marco -Margen "0,0,0,5" -Relleno "12,7"
            if (-not $e.Activo) { $marco.Opacity = 0.65 }
            $fila = New-Object System.Windows.Controls.DockPanel
            $botones = New-Object System.Windows.Controls.StackPanel
            $botones.Orientation = "Horizontal"
            $botones.VerticalAlignment = "Center"
            [System.Windows.Controls.DockPanel]::SetDock($botones, "Right")
            $textoBoton = if ($e.Activo) { "Desactivar" } else { "Activar" }
            [void]$botones.Children.Add((New-Boton $textoBoton ([scriptblock]::Create("Switch-EntradaArranque '$($e.Id.Replace("'", "''"))'")) -Margen "6,0,0,0" -Libre))
            if ($e.Ruta -and (Test-Path -LiteralPath $e.Ruta)) {
                [void]$botones.Children.Add((New-Boton "Ubicación" ([scriptblock]::Create("Start-Process explorer.exe -ArgumentList '/select,`"$($e.Ruta.Replace("'", "''"))`"'")) -Margen "6,0,0,0" -Libre))
            }
            [void]$fila.Children.Add($botones)
            $pila = New-Object System.Windows.Controls.StackPanel
            $estadoTxt = if ($e.Activo) { "$([char]0x25CF) Activo" } else { "$([char]0x25CB) Desactivado" }
            $tit = New-Texto "$($e.Nombre)" "#111827" 13 "SemiBold"
            [void]$pila.Children.Add($tit)
            $firmaTxt = switch ($e.Firma) {
                "Valida"   { "$([char]0x2714) Firmado por $($e.Firmante)" }
                "NoValida" { "$([char]0x26A0) Firma NO válida ($($e.Firmante))" }
                "NoExiste" { "$([char]0x26A0) El archivo ya no existe (resto de un programa borrado)" }
                default    { "$([char]0x26A0) Sin firma digital" }
            }
            $colorFirma = if ($e.Firma -eq "Valida") { "#16A34A" } else { "#D97706" }
            $lineaEstado = New-Object System.Windows.Controls.TextBlock
            $lineaEstado.TextWrapping = "Wrap"
            $lineaEstado.FontSize = 12
            $lineaEstado.Margin = "0,1,0,0"
            $r1 = New-Object System.Windows.Documents.Run "$estadoTxt   "
            $r1.Foreground = Get-Pincel $(if ($e.Activo) { "#2563EB" } else { "#6B7280" })
            $r1.FontWeight = "SemiBold"
            $r2 = New-Object System.Windows.Documents.Run "$firmaTxt   "
            $r2.Foreground = Get-Pincel $colorFirma
            $r3 = New-Object System.Windows.Documents.Run $e.Origen
            $r3.Foreground = Get-Pincel "#6B7280"
            [void]$lineaEstado.Inlines.Add($r1); [void]$lineaEstado.Inlines.Add($r2); [void]$lineaEstado.Inlines.Add($r3)
            [void]$pila.Children.Add($lineaEstado)
            if ($e.Comando) {
                $cmdCorto = if ($e.Comando.Length -gt 160) { $e.Comando.Substring(0, 157) + "..." } else { $e.Comando }
                $tc = New-Texto $cmdCorto "#9CA3AF" 11 "Normal" "0,1,0,0"
                $tc.ToolTip = $e.Comando
                [void]$pila.Children.Add($tc)
            }
            [void]$fila.Children.Add($pila)
            $marco.Child = $fila
            [void]$panel.Children.Add($marco)
        }
    }
}

$pArr = $script:UI.PanelArranque
[void]$pArr.Children.Add((New-Titulo "Arranque de Windows" "Todo lo que se abre solo al encender: programas, tareas programadas y servicios de otros fabricantes. Desactivar no borra nada y se puede volver a activar."))
$filaArr = New-Object System.Windows.Controls.WrapPanel
$filaArr.Margin = "0,0,0,6"
[void]$filaArr.Children.Add((New-Boton "Volver a leer" { Start-ListaArranque } -Primario))
[void]$filaArr.Children.Add((New-Boton "Abrir en Configuración de Windows" { Start-Process "ms-settings:startupapps" } -Libre))
[void]$filaArr.Children.Add((New-Boton "Programador de tareas" { Start-Process "taskschd.msc" } -Libre))
[void]$filaArr.Children.Add((New-Boton "Servicios" { Start-Process "services.msc" } -Libre))
[void]$pArr.Children.Add($filaArr)
[void]$pArr.Children.Add((New-Texto "Consejo: desactiva lo que no uses a diario (actualizadores, chats, lanzadores de juegos). No desactives el antivirus, los controladores de audio, touchpad o gráficos, ni el programa de cámaras en una PC de vigilancia." "#6B7280" 12.5 "Normal" "0,0,0,8"))
$script:PanelListaArranque = New-Object System.Windows.Controls.StackPanel
[void]$pArr.Children.Add($script:PanelListaArranque)
[void]$script:PanelListaArranque.Children.Add((New-Texto "La lista se carga al abrir esta pestaña." "#6B7280"))
$script:ArranqueCargado = $false

# ---------------------------------------------------------------- Pestaña Mis programas: actualizaciones (winget) y desinstalar a fondo
$script:codigoBuscarActualizaciones = @'
$ruta = Get-RutaWinget
if (-not $ruta) { Write-Warning "winget no está instalado. Ve a Reparaciones > 'Reparar winget'."; return }
Write-Output "Preguntando a winget qué programas tienen una versión nueva (puede tardar un minuto)..."
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ruta
$psi.Arguments = "upgrade --accept-source-agreements --disable-interactivity"
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8
$proceso = [Diagnostics.Process]::Start($psi)
$tareaError = $proceso.StandardError.ReadToEndAsync()
$salida = $proceso.StandardOutput.ReadToEnd()
$proceso.WaitForExit()
$filas = ConvertFrom-TablaWinget -Texto $salida
foreach ($f in $filas) { [void]$global:Estado.Actualizables.Add($f) }
Write-Output "Programas con actualización: $($filas.Count)."
'@

function Start-BuscarActualizaciones {
    if (-not $script:WingetOk) {
        [void][System.Windows.MessageBox]::Show("winget no está instalado. Ve a Reparaciones > 'Reparar winget'.", "Mis programas", "OK", "Warning")
        return
    }
    $global:Estado.Actualizables = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $script:PanelActualizables.Children.Clear()
    [void]$script:PanelActualizables.Children.Add((New-Texto "Buscando actualizaciones..." "#6B7280"))
    Start-Pasos -Pasos @(New-PasoScript -Nombre "Buscar actualizaciones de programas" -Codigo $script:codigoBuscarActualizaciones) -Silencioso
    if ($script:Trabajo) { $script:AlTerminar = { Show-Actualizables } }
}

function Show-Actualizables {
    $panel = $script:PanelActualizables
    $panel.Children.Clear()
    $script:CasillasActualizables = @()
    $lista = @($global:Estado.Actualizables)
    if ($lista.Count -eq 0) {
        [void]$panel.Children.Add((New-Texto "$([char]0x2714) Todos los programas que reconoce winget están al día." "#16A34A" 13 "SemiBold" "0,0,0,6"))
        return
    }
    [void]$panel.Children.Add((New-Texto "$($lista.Count) programa(s) con versión nueva. Marca los que quieras y pulsa 'Actualizar seleccionados'." "#111827" 13 "SemiBold" "0,0,0,6"))
    foreach ($a in $lista) {
        $marco = New-Marco -Margen "0,0,0,4" -Relleno "12,6"
        $pila = New-Object System.Windows.Controls.StackPanel
        $chk = New-Object System.Windows.Controls.CheckBox
        $chk.Content = $a.Nombre
        $chk.FontWeight = "SemiBold"
        $chk.IsChecked = $true
        $chk.Tag = $a
        [void]$pila.Children.Add($chk)
        [void]$pila.Children.Add((New-Texto "Versión $($a.Version)  $([char]0x2192)  $($a.Disponible)    ·    $($a.Id) ($($a.Origen))" "#6B7280" 12 "Normal" "20,1,0,0"))
        $estadoTxt = New-Texto "" "#6B7280" 12 "SemiBold" "20,3,0,0"
        $estadoTxt.Visibility = "Collapsed"
        [void]$pila.Children.Add($estadoTxt)
        $barraA = New-Object System.Windows.Controls.ProgressBar
        $barraA.Height = 5
        $barraA.Margin = "20,3,0,2"
        $barraA.Visibility = "Collapsed"
        [void]$pila.Children.Add($barraA)
        $marco.Child = $pila
        [void]$panel.Children.Add($marco)
        $script:CasillasActualizables += $chk
        # Así el progreso de winget se ve en esta fila
        $script:TarjetaPorId[$a.Id] = [pscustomobject]@{ Borde = $marco; Estado = $estadoTxt; Barra = $barraA; Firma = "" }
    }
    $fila = New-Object System.Windows.Controls.WrapPanel
    $fila.Margin = "0,6,0,0"
    [void]$fila.Children.Add((New-Boton "Actualizar seleccionados" {
        $sel = @($script:CasillasActualizables | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
        if ($sel.Count -eq 0) { return }
        $msg = "Se actualizarán $($sel.Count) programa(s) en silencio, uno tras otro.`r`n`r`nCierra esos programas antes: algunos se cierran solos al actualizarse.`r`n`r`n¿Continuar?"
        if ([System.Windows.MessageBox]::Show($msg, "Actualizar programas", "YesNo", "Question") -ne "Yes") { return }
        foreach ($a in $sel) { $global:Estado.Apps[$a.Id] = @{ Texto = "En espera..."; Tipo = "trabajo"; Progreso = -1 } }
        $pasos = foreach ($a in $sel) { New-PasoScript -Nombre "Actualizar $($a.Nombre)" -Codigo ("Invoke-AppWinget -Accion 'upgrade' -Id '{0}' -Fuente '{1}'" -f $a.Id, $a.Origen) }
        Start-Pasos -Pasos @($pasos) -Titulo "Actualizar programas"
    } -Primario))
    [void]$fila.Children.Add((New-Boton "Marcar todos" { foreach ($c in $script:CasillasActualizables) { $c.IsChecked = $true } } -Libre))
    [void]$fila.Children.Add((New-Boton "Quitar marcas" { foreach ($c in $script:CasillasActualizables) { $c.IsChecked = $false } } -Libre))
    [void]$panel.Children.Add($fila)
}

# Programas instalados (lectura del registro de desinstalación)
function Get-ProgramasInstalados {
    $claves = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*")
    $vistos = @{}
    $res = foreach ($c in $claves) {
        foreach ($p in @(Get-ItemProperty -Path $c -ErrorAction SilentlyContinue)) {
            if (-not $p.DisplayName -or -not $p.UninstallString -or $p.SystemComponent -eq 1 -or $p.ParentKeyName -or $p.ReleaseType -match 'Update|Hotfix') { continue }
            $clave = "$($p.DisplayName)|$($p.DisplayVersion)"
            if ($vistos.ContainsKey($clave)) { continue }
            $vistos[$clave] = $true
            $fecha = ""
            if ([string]$p.InstallDate -match '^(\d{4})(\d{2})(\d{2})$') { $fecha = "$($Matches[3])/$($Matches[2])/$($Matches[1])" }
            [pscustomobject]@{
                Nombre = [string]$p.DisplayName; Editor = [string]$p.Publisher; Version = [string]$p.DisplayVersion; Fecha = $fecha
                MB = $(if ($p.EstimatedSize) { [math]::Round([double]$p.EstimatedSize / 1024, 0) } else { 0 })
                Desinstalar = [string]$p.UninstallString; Ubicacion = [string]$p.InstallLocation; Clave = [string]$p.PSPath
            }
        }
    }
    return @($res | Sort-Object Nombre)
}

function Show-Instalados {
    $script:ProgramasCargados = $true
    $script:Instalados = Get-ProgramasInstalados
    Update-FiltroInstalados
}

function Update-FiltroInstalados {
    $panel = $script:PanelInstalados
    $panel.Children.Clear()
    $texto = ([string]$script:TxtBuscarPrograma.Text).Trim()
    $lista = @($script:Instalados | Where-Object { -not $texto -or "$($_.Nombre) $($_.Editor)" -like "*$texto*" })
    [void]$panel.Children.Add((New-Texto "$($lista.Count) programa(s)$(if ($texto) { " que coinciden con '$texto'" })." "#6B7280" 12.5 "Normal" "0,0,0,6"))
    $i = 0
    foreach ($p in $lista) {
        $i++
        if ($i -gt 150) { [void]$panel.Children.Add((New-Texto "... escribe en el buscador para ver el resto." "#6B7280")); break }
        $marco = New-Marco -Margen "0,0,0,4" -Relleno "12,6"
        $fila = New-Object System.Windows.Controls.DockPanel
        $btn = New-Boton "Desinstalar a fondo" ([scriptblock]::Create("Start-DesinstalarFondo '$($p.Clave.Replace("'", "''"))'")) -Margen "8,0,0,0" -Libre
        $btn.VerticalAlignment = "Center"
        [System.Windows.Controls.DockPanel]::SetDock($btn, "Right")
        [void]$fila.Children.Add($btn)
        $pila = New-Object System.Windows.Controls.StackPanel
        [void]$pila.Children.Add((New-Texto $p.Nombre "#111827" 13 "SemiBold"))
        $datosP = @($p.Editor, $(if ($p.Version) { "versión $($p.Version)" }), $(if ($p.MB) { "$($p.MB) MB" }), $(if ($p.Fecha) { "instalado el $($p.Fecha)" })) | Where-Object { $_ }
        [void]$pila.Children.Add((New-Texto ($datosP -join "   ·   ") "#6B7280" 12))
        [void]$fila.Children.Add($pila)
        $marco.Child = $fila
        [void]$panel.Children.Add($marco)
    }
}

function Start-DesinstalarFondo([string]$Clave) {
    $p = @($script:Instalados | Where-Object { $_.Clave -eq $Clave })[0]
    if (-not $p) { return }
    if ("$($p.Nombre) $($p.Editor)" -match $script:PatronCritico) {
        if ([System.Windows.MessageBox]::Show("'$($p.Nombre)' parece un antivirus, un controlador o el programa de cámaras. Si lo quitas, eso dejará de funcionar.`r`n`r`n¿Seguro que quieres desinstalarlo?", "Desinstalar a fondo", "YesNo", "Warning") -ne "Yes") { return }
    }
    $msg = "1. Se abre el desinstalador de '$($p.Nombre)': sigue sus pasos.`r`n2. Al terminar, se buscan los restos que deja (carpetas, accesos directos y claves del registro).`r`n3. Tú eliges qué restos borrar. Las carpetas van a la Papelera y del registro se guarda una copia.`r`n`r`n¿Continuar?"
    if ([System.Windows.MessageBox]::Show($msg, "Desinstalar a fondo", "YesNo", "Question") -ne "Yes") { return }
    $script:ProgramaQuitado = $p
    $global:Estado.Restos = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $global:Estado.SigueInstalado = $false
    $codigo = "`$cadena = '" + $p.Desinstalar.Replace("'", "''") + "'`n" +
        "`$nombreProg = '" + $p.Nombre.Replace("'", "''") + "'`n" +
        "`$editorProg = '" + $p.Editor.Replace("'", "''") + "'`n" +
        "`$ubicacionProg = '" + $p.Ubicacion.Replace("'", "''") + "'`n" +
        "`$claveProg = '" + $p.Clave.Replace("'", "''") + "'`n" + $script:codigoDesinstalar
    Start-Pasos -Pasos @(New-PasoScript -Nombre "Desinstalar $($p.Nombre)" -Codigo $codigo) -Titulo "Desinstalar a fondo" -Silencioso
    if ($script:Trabajo) { $script:AlTerminar = { Show-Restos; Show-Instalados } }
}

function Show-Restos {
    $panel = $script:PanelRestos
    $panel.Children.Clear()
    $script:CasillasRestos = @()
    $p = $script:ProgramaQuitado
    $lista = @($global:Estado.Restos)
    if ($global:Estado.SigueInstalado) {
        [void]$panel.Children.Add((New-Texto "$([char]0x26A0) '$($p.Nombre)' sigue instalado. Si cancelaste, no pasa nada. Si el desinstalador sigue abierto, termínalo y pulsa 'Buscar restos otra vez'." "#D97706" 13 "SemiBold" "0,0,0,6"))
    }
    if ($lista.Count -eq 0) {
        [void]$panel.Children.Add((New-Texto "$([char]0x2714) No quedan restos de '$($p.Nombre)'." "#16A34A" 13 "SemiBold" "0,0,0,6"))
    } else {
        [void]$panel.Children.Add((New-Texto "Restos de '$($p.Nombre)': marca los que quieras borrar." "#111827" 13 "SemiBold" "0,0,0,6"))
        foreach ($r in $lista) {
            $chk = New-Object System.Windows.Controls.CheckBox
            $tam = if ($r.MB) { "  ($($r.MB) MB)" } else { "" }
            $tipoTxt = @{ Carpeta = "Carpeta"; Registro = "Clave del registro"; Acceso = "Acceso directo" }[$r.Tipo]
            $chk.Content = "${tipoTxt}: $($r.Ruta)$tam"
            $chk.IsChecked = -not $global:Estado.SigueInstalado
            $chk.Tag = $r
            $chk.Margin = "0,2,0,2"
            [void]$panel.Children.Add($chk)
            $script:CasillasRestos += $chk
        }
    }
    $fila = New-Object System.Windows.Controls.WrapPanel
    $fila.Margin = "0,8,0,0"
    if ($lista.Count) {
        [void]$fila.Children.Add((New-Boton "Borrar restos marcados" {
            $sel = @($script:CasillasRestos | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
            if ($sel.Count -eq 0) { return }
            if ([System.Windows.MessageBox]::Show("Se borrarán $($sel.Count) resto(s). Las carpetas van a la Papelera y las claves del registro se copian antes a un archivo .reg.`r`n`r`n¿Continuar?", "Borrar restos", "YesNo", "Question") -ne "Yes") { return }
            $lineas = foreach ($r in $sel) { "@{ Tipo = '$($r.Tipo)'; Ruta = '$($r.Ruta.Replace("'", "''"))' }" }
            $codigoBorrar = "`$restos = @(" + ($lineas -join ", ") + ")`n`$programa = '" + $script:ProgramaQuitado.Nombre.Replace("'", "''") + "'`n" + $script:codigoBorrarRestos
            Start-Pasos -Pasos @(New-PasoScript -Nombre "Borrar restos" -Codigo $codigoBorrar) -Titulo "Borrar restos"
            if ($script:Trabajo) { $script:AlTerminar = { $script:PanelRestos.Children.Clear(); [void]$script:PanelRestos.Children.Add((New-Texto "$([char]0x2714) Restos borrados. Las carpetas están en la Papelera por si necesitas recuperar algo." "#16A34A" 13 "SemiBold")) } }
        } -Primario))
    }
    [void]$fila.Children.Add((New-Boton "Buscar restos otra vez" {
        $p = $script:ProgramaQuitado
        $global:Estado.Restos = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        $global:Estado.SigueInstalado = [bool](Test-Path -LiteralPath $p.Clave)
        foreach ($r in (Find-Restos -Nombre $p.Nombre -Editor $p.Editor -Ubicacion $p.Ubicacion)) { [void]$global:Estado.Restos.Add($r) }
        Show-Restos
    }))
    [void]$panel.Children.Add($fila)
}

$script:codigoDesinstalar = @'
Write-Output "Abriendo el desinstalador de $nombreProg... Sigue sus pasos en la ventana que aparece."
if ($cadena -match '(?i)msiexec(\.exe)?"?\s+/[IX]\s*(\{[0-9A-F-]+\})') {
    Start-Process -FilePath msiexec.exe -ArgumentList "/x $($Matches[2])" -Wait
} else {
    Start-Process -FilePath cmd.exe -ArgumentList ('/c "' + $cadena + '"') -Wait -WindowStyle Hidden
}
Start-Sleep -Seconds 2
if (Test-Path -LiteralPath $claveProg) {
    $global:Estado.SigueInstalado = $true
    Write-Warning "El programa sigue apareciendo como instalado (quizá cancelaste o el desinstalador sigue abierto)."
} else {
    Add-Historial -Tipo "Desinstalar" -Clave $nombreProg -Nombre "Desinstalado: $nombreProg" -Accion "Desinstalado"
}
Write-Output "Buscando restos..."
foreach ($r in (Find-Restos -Nombre $nombreProg -Editor $editorProg -Ubicacion $ubicacionProg)) { [void]$global:Estado.Restos.Add($r) }
Write-Output "Restos encontrados: $($global:Estado.Restos.Count)."
'@

$script:codigoBorrarRestos = @'
Add-Type -AssemblyName Microsoft.VisualBasic
$carpetaCopia = Join-Path $env:LOCALAPPDATA ("OptimizadorES\Restos\{0:yyyyMMdd_HHmmss}" -f (Get-Date))
New-Item -ItemType Directory -Force -Path $carpetaCopia | Out-Null
$n = 0
$borrados = @()
foreach ($r in $restos) {
    try {
        switch ($r.Tipo) {
            "Carpeta" { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($r.Ruta, "OnlyErrorDialogs", "SendToRecycleBin") }
            "Acceso"  { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($r.Ruta, "OnlyErrorDialogs", "SendToRecycleBin") }
            "Registro" {
                $n++
                $regRuta = $r.Ruta -replace '^HKCU:\\', 'HKCU\' -replace '^HKLM:\\', 'HKLM\'
                reg.exe export "$regRuta" (Join-Path $carpetaCopia "clave$n.reg") /y | Out-Null
                Remove-Item -LiteralPath $r.Ruta -Recurse -Force -ErrorAction Stop
            }
        }
        $borrados += $r.Ruta
        Write-Output "Borrado: $($r.Ruta)"
    } catch {
        Write-Warning "No se pudo borrar $($r.Ruta): $($_.Exception.Message)"
    }
}
if ($n) { Write-Output "Copia de las claves del registro en $carpetaCopia (doble clic en un .reg para recuperarla)." }
Add-Historial -Tipo "Restos" -Clave $programa -Nombre "Restos de $programa borrados" -Accion "Borrados" -Datos @{ Rutas = $borrados; Copia = $carpetaCopia }
'@

$pProg = $script:UI.PanelProgramas
[void]$pProg.Children.Add((New-Titulo "Actualizaciones de programas" "Como UniGetUI: busca versión nueva de TODOS tus programas que reconoce winget, no solo los de la pestaña Apps."))
$filaAct = New-Object System.Windows.Controls.WrapPanel
$filaAct.Margin = "0,0,0,6"
[void]$filaAct.Children.Add((New-Boton "Buscar actualizaciones" { Start-BuscarActualizaciones } -Primario))
[void]$pProg.Children.Add($filaAct)
$script:PanelActualizables = New-Object System.Windows.Controls.StackPanel
$script:PanelActualizables.Margin = "0,0,0,10"
[void]$pProg.Children.Add($script:PanelActualizables)

[void]$pProg.Children.Add((New-Titulo "Desinstalar a fondo" "Como Revo Uninstaller: abre el desinstalador del programa y después busca las carpetas, accesos directos y claves del registro que deja olvidadas."))
$filaBuscarProg = New-Object System.Windows.Controls.DockPanel
$filaBuscarProg.Margin = "0,0,0,8"
$lblProg = New-Texto "Buscar programa:" "#374151"
$lblProg.VerticalAlignment = "Center"
$lblProg.Margin = "0,0,8,0"
[System.Windows.Controls.DockPanel]::SetDock($lblProg, "Left")
[void]$filaBuscarProg.Children.Add($lblProg)
$script:TxtBuscarPrograma = New-Object System.Windows.Controls.TextBox
$script:TxtBuscarPrograma.Add_TextChanged({ if ($script:ProgramasCargados) { Update-FiltroInstalados } })
[void]$filaBuscarProg.Children.Add($script:TxtBuscarPrograma)
[void]$pProg.Children.Add($filaBuscarProg)
$script:PanelRestos = New-Object System.Windows.Controls.StackPanel
$script:PanelRestos.Margin = "0,0,0,8"
[void]$pProg.Children.Add($script:PanelRestos)
$script:PanelInstalados = New-Object System.Windows.Controls.StackPanel
[void]$pProg.Children.Add($script:PanelInstalados)
$script:ProgramasCargados = $false
$script:Instalados = @()

# ---------------------------------------------------------------- Rendimiento: limpieza a fondo (como BleachBit)
$script:CategoriasLimpieza = @(
    @{ Clave = "TempUsuario"; Nombre = "Archivos temporales de tu usuario"; Riesgo = "Bajo"; Defecto = $true; Descripcion = "Restos que dejan instaladores y programas en tu carpeta TEMP."; Aviso = "" }
    @{ Clave = "TempWindows"; Nombre = "Archivos temporales de Windows"; Riesgo = "Bajo"; Defecto = $true; Descripcion = "La carpeta C:\Windows\Temp."; Aviso = "" }
    @{ Clave = "Navegadores"; Nombre = "Caché de los navegadores"; Riesgo = "Bajo"; Defecto = $true; Descripcion = "Imágenes y archivos de páginas guardados por Edge, Chrome, Brave, Opera, Vivaldi y Firefox. No borra contraseñas, cookies, historial ni favoritos."; Aviso = "Cierra los navegadores antes; las páginas tardarán un poco más la primera vez." }
    @{ Clave = "Miniaturas"; Nombre = "Miniaturas de imágenes"; Riesgo = "Bajo"; Defecto = $true; Descripcion = "La caché de vistas previas del Explorador. Se vuelve a crear sola."; Aviso = "" }
    @{ Clave = "Errores"; Nombre = "Informes de errores y volcados de memoria"; Riesgo = "Bajo"; Defecto = $true; Descripcion = "Informes de cuelgues de programas y volcados de pantallas azules ya enviados o viejos."; Aviso = "Si un técnico está investigando pantallas azules, guárdalos antes." }
    @{ Clave = "Registros"; Nombre = "Registros viejos de Windows"; Riesgo = "Bajo"; Defecto = $true; Descripcion = "Registros de instalación y actualizaciones de más de 7 días (CBS, DISM, Windows Update)."; Aviso = "" }
    @{ Clave = "Actualizaciones"; Nombre = "Descargas de Windows Update"; Riesgo = "Bajo"; Defecto = $true; Descripcion = "Archivos de actualizaciones ya instaladas. Se detiene Windows Update un momento para poder borrarlos."; Aviso = "Si hay una actualización a medias, se volverá a descargar." }
    @{ Clave = "Entrega"; Nombre = "Caché de Optimización de distribución"; Riesgo = "Bajo"; Defecto = $true; Descripcion = "Trozos de actualizaciones que Windows guarda para compartir con otros equipos."; Aviso = "" }
    @{ Clave = "Papelera"; Nombre = "Papelera de reciclaje"; Riesgo = "Medio"; Defecto = $false; Descripcion = "Vacía la Papelera de todos los discos."; Aviso = "Lo que esté en la Papelera ya no se podrá recuperar." }
    @{ Clave = "Componentes"; Nombre = "Versiones viejas de componentes de Windows"; Riesgo = "Medio"; Defecto = $false; Descripcion = "DISM /StartComponentCleanup: borra copias viejas que dejan las actualizaciones (suele liberar 1 a 5 GB). Tarda 5 a 20 minutos."; Aviso = "Después ya no se pueden desinstalar las actualizaciones que ya tienes." }
    @{ Clave = "WindowsOld"; Nombre = "Windows.old (instalación anterior)"; Riesgo = "Alto"; Defecto = $false; Descripcion = "La copia de tu Windows anterior que queda tras una actualización grande o una reinstalación."; Aviso = "Ya no podrás volver a la versión anterior de Windows ni recuperar archivos de esa carpeta." }
)

$script:codigoLimpieza = @'
$rutas = @{
    TempUsuario = @("$env:TEMP")
    TempWindows = @("$env:SystemRoot\Temp")
    Navegadores = @(
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Cache", "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\Code Cache", "$env:LOCALAPPDATA\Microsoft\Edge\User Data\*\GPUCache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Cache", "$env:LOCALAPPDATA\Google\Chrome\User Data\*\Code Cache", "$env:LOCALAPPDATA\Google\Chrome\User Data\*\GPUCache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Cache", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\*\Code Cache",
        "$env:LOCALAPPDATA\Vivaldi\User Data\*\Cache", "$env:APPDATA\Opera Software\Opera Stable\Cache", "$env:LOCALAPPDATA\Opera Software\Opera Stable\Cache",
        "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2")
    Miniaturas = @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db", "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db")
    Errores = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive",
        "$env:LOCALAPPDATA\CrashDumps", "$env:SystemRoot\Minidump", "$env:SystemRoot\MEMORY.DMP", "$env:SystemRoot\LiveKernelReports")
    Registros = @("$env:SystemRoot\Logs\CBS", "$env:SystemRoot\Logs\DISM", "$env:SystemRoot\Logs\WindowsUpdate", "$env:SystemRoot\Logs\MoSetup", "$env:SystemRoot\Panther\UnattendGC")
    Actualizaciones = @("$env:SystemRoot\SoftwareDistribution\Download")
    Entrega = @("$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache")
    WindowsOld = @("$env:SystemDrive\Windows.old")
}
$soloViejos = @{ Registros = 7 }

function Get-ArchivosCategoria([string]$Clave) {
    $dias = $soloViejos[$Clave]
    foreach ($patron in @($rutas[$Clave])) {
        foreach ($item in @(Get-Item -Path $patron -Force -ErrorAction SilentlyContinue)) {
            $archivos = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue) } else { @($item) }
            if ($dias) { $archivos = @($archivos | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$dias) -and $_.Name -notmatch '^CBS\.log$|^dism\.log$' }) }
            $archivos
        }
    }
}
function Get-MBCategoria([string]$Clave) {
    if ($Clave -eq "Papelera") {
        $t = 0
        foreach ($u in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $pap = Join-Path $u.Root '$Recycle.Bin'
            if (Test-Path -LiteralPath $pap) { $t += (Get-ChildItem -LiteralPath $pap -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum }
        }
        return [math]::Round($t / 1MB, 1)
    }
    if ($Clave -eq "Componentes") { return -1 }
    $suma = (@(Get-ArchivosCategoria $Clave) | Measure-Object -Property Length -Sum).Sum
    return [math]::Round([double]$suma / 1MB, 1)
}

$total = 0
foreach ($c in $Claves) {
    if ($Modo -eq "Limpiar") {
        $antesMB = Get-MBCategoria $c
        Write-Output "Limpiando: $c..."
        switch ($c) {
            "Papelera" { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
            "Componentes" {
                Write-Output "DISM está limpiando componentes (5 a 20 minutos, no apagues el equipo)..."
                $salidaDism = & dism.exe /Online /Cleanup-Image /StartComponentCleanup
                if ($LASTEXITCODE -ne 0) { Write-Warning "DISM terminó con el código $LASTEXITCODE." } else { Write-Output "Componentes limpiados." }
            }
            "WindowsOld" {
                $wo = "$env:SystemDrive\Windows.old"
                if (Test-Path -LiteralPath $wo) {
                    takeown.exe /F $wo /R /A /D Y 2>&1 | Out-Null
                    icacls.exe $wo /grant "*S-1-5-32-544:F" /T /C /Q 2>&1 | Out-Null
                    cmd.exe /c "rd /s /q `"$wo`"" 2>&1 | Out-Null
                }
            }
            "Entrega" {
                if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue }
                else { Get-ArchivosCategoria $c | Remove-Item -Force -ErrorAction SilentlyContinue }
            }
            "Actualizaciones" {
                Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue
                try { Get-ArchivosCategoria $c | Remove-Item -Force -ErrorAction SilentlyContinue }
                finally { Start-Service -Name wuauserv, bits -ErrorAction SilentlyContinue }
            }
            default { Get-ArchivosCategoria $c | Remove-Item -Force -ErrorAction SilentlyContinue }
        }
        # Carpetas que quedaron vacías dentro de TEMP
        if ($c -like "Temp*") {
            foreach ($raiz in @($rutas[$c])) { Get-ChildItem -LiteralPath $raiz -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Select-Object -First 1) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $despuesMB = Get-MBCategoria $c
        if ($antesMB -ge 0) {
            $liberado = [math]::Max(0, $antesMB - $despuesMB)
            $total += $liberado
            Write-Output ("  {0}: liberados {1} MB" -f $c, $liberado)
        }
        $global:Estado.Limpieza[$c] = $despuesMB
    } else {
        $global:Estado.Limpieza[$c] = Get-MBCategoria $c
    }
}
if ($Modo -eq "Limpiar") {
    Write-Output ("Total liberado: {0:N1} GB. Lo que estaba en uso por algún programa se dejó (es normal)." -f ($total / 1024))
    Add-Historial -Tipo "Limpieza" -Clave "Limpieza" -Nombre ("Limpieza a fondo: {0:N1} GB liberados" -f ($total / 1024)) -Accion "Limpiado" -Datos @{ Categorias = @($Claves) }
} else {
    Write-Output "Análisis del espacio terminado."
}
'@

function Start-Limpieza([string]$Modo) {
    $claves = if ($Modo -eq "Medir") { @($script:CategoriasLimpieza | ForEach-Object { $_.Clave }) } else { @($script:CasillasLimpieza | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag.Clave }) }
    if ($claves.Count -eq 0) { [void][System.Windows.MessageBox]::Show("Marca al menos una categoría.", "Limpieza", "OK", "Information"); return }
    if ($Modo -eq "Limpiar") {
        $sel = @($script:CategoriasLimpieza | Where-Object { $claves -contains $_.Clave })
        $msg = "Se limpiarán $($sel.Count) categoría(s):`r`n" + (($sel | ForEach-Object { " - $($_.Nombre)" }) -join "`r`n")
        $avisos = @($sel | Where-Object { $_.Riesgo -ne "Bajo" })
        if ($avisos.Count) { $msg += "`r`n`r`nOjo:`r`n" + (($avisos | ForEach-Object { " - $($_.Nombre): $($_.Aviso)" }) -join "`r`n") }
        $msg += "`r`n`r`nCierra los navegadores y programas abiertos antes. ¿Continuar?"
        if ([System.Windows.MessageBox]::Show($msg, "Limpieza a fondo", "YesNo", $(if ($avisos.Count) { "Warning" } else { "Question" })) -ne "Yes") { return }
    }
    $global:Estado.Limpieza = [hashtable]::Synchronized(@{})
    $codigo = "`$Modo = '$Modo'`n`$Claves = @(" + (($claves | ForEach-Object { "'$_'" }) -join ",") + ")`n" + $script:codigoLimpieza
    $nombrePaso = if ($Modo -eq "Medir") { "Analizar espacio recuperable" } else { "Limpieza a fondo" }
    if ($Modo -eq "Medir") { Start-Pasos -Pasos @(New-PasoScript -Nombre $nombrePaso -Codigo $codigo) -Silencioso }
    else { Start-Pasos -Pasos @(New-PasoScript -Nombre $nombrePaso -Codigo $codigo) -Titulo $nombrePaso }
    if ($script:Trabajo) { $script:AlTerminar = { Show-Limpieza } }
}

function Show-Limpieza {
    $total = 0
    foreach ($c in $script:CasillasLimpieza) {
        $cat = $c.Tag
        $mb = $global:Estado.Limpieza[$cat.Clave]
        if ($null -eq $mb) { continue }
        $txt = if ($mb -lt 0) { "tamaño variable" } elseif ($mb -ge 1024) { "{0:N1} GB" -f ($mb / 1024) } else { "{0:N0} MB" -f $mb }
        $c.Content = "$($cat.Nombre)   ($txt)"
        if ($mb -gt 0) { $total += $mb }
    }
    $script:TxtTotalLimpieza.Text = "Se pueden recuperar unos {0:N1} GB (sin contar los componentes de Windows)." -f ($total / 1024)
}

$pR = $script:UI.PanelRendimiento
[void]$pR.Children.Add((New-Titulo "Limpieza a fondo" "Como BleachBit: primero mide cuánto ocupa cada cosa y luego limpias solo lo que marques."))
$filaLimp = New-Object System.Windows.Controls.WrapPanel
$filaLimp.Margin = "0,0,0,6"
[void]$filaLimp.Children.Add((New-Boton "Medir espacio" { Start-Limpieza "Medir" }))
[void]$filaLimp.Children.Add((New-Boton "Limpiar marcados" { Start-Limpieza "Limpiar" } -Primario))
[void]$pR.Children.Add($filaLimp)
$script:TxtTotalLimpieza = New-Texto "Pulsa 'Medir espacio' para ver cuánto puedes liberar." "#1D4ED8" 13 "SemiBold" "0,0,0,8"
[void]$pR.Children.Add($script:TxtTotalLimpieza)
$script:CasillasLimpieza = @()
foreach ($cat in $script:CategoriasLimpieza) {
    $it = [pscustomobject]@{ Nombre = $cat.Nombre; Descripcion = $cat.Descripcion; Riesgo = $cat.Riesgo; Aviso = $cat.Aviso }
    $t = New-Tarjeta -Item $it -Marcado $cat.Defecto
    $t.Casilla.Tag = $cat
    [void]$pR.Children.Add($t.Borde)
    $script:CasillasLimpieza += $t.Casilla
}

# ---------------------------------------------------------------- Rendimiento: salud de discos y batería
$script:codigoDiscos = @'
$lista = $global:Estado.Discos
$avisoSmart = $false
try { $avisoSmart = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure }).Count -gt 0 } catch { }
foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId)) {
    $c = $null
    try { $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
    $tipo = switch ([string]$d.MediaType) { "SSD" { "SSD" } "HDD" { "Disco duro (HDD)" } default { "Disco" } }
    if ([string]$d.BusType -eq "NVMe") { $tipo = "SSD NVMe" }
    [void]$lista.Add(@{
        Nombre = [string]$d.FriendlyName; Tipo = $tipo; GB = [math]::Round([double]$d.Size / 1GB, 0)
        Salud = [string]$d.HealthStatus; Estado = [string]($d.OperationalStatus -join ", ")
        Temperatura = $(if ($c -and $c.Temperature) { [int]$c.Temperature } else { $null })
        Desgaste = $(if ($c -and $null -ne $c.Wear) { [int]$c.Wear } else { $null })
        Horas = $(if ($c -and $c.PowerOnHours) { [int]$c.PowerOnHours } else { $null })
        ErroresLectura = $(if ($c) { [int]$c.ReadErrorsUncorrected } else { 0 })
        ErroresEscritura = $(if ($c) { [int]$c.WriteErrorsUncorrected } else { 0 })
    })
}
$global:Estado.AvisoSmart = $avisoSmart
try {
    $llena = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
    $diseno = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
    $ciclos = $null
    try { $ciclos = (Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction Stop | Select-Object -First 1).CycleCount } catch { }
    if ($llena -and $diseno) { $global:Estado.Bateria = @{ Salud = [int](100 * $llena / $diseno); Ciclos = $ciclos } }
} catch { }
Write-Output "Salud de discos revisada: $($lista.Count) disco(s)."
'@

function Start-SaludDiscos {
    if ($script:Trabajo) { return }
    $global:Estado.Discos = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $global:Estado.Bateria = $null
    $global:Estado.AvisoSmart = $false
    $script:PanelDiscos.Children.Clear()
    [void]$script:PanelDiscos.Children.Add((New-Texto "Revisando los discos..." "#6B7280"))
    Start-Pasos -Pasos @(New-PasoScript -Nombre "Revisar la salud de los discos" -Codigo $script:codigoDiscos) -Silencioso
    if ($script:Trabajo) { $script:AlTerminar = { Show-SaludDiscos } }
}

function Show-SaludDiscos {
    $panel = $script:PanelDiscos
    $panel.Children.Clear()
    foreach ($d in @($global:Estado.Discos)) {
        $problemas = @()
        if ($d.Salud -eq "Unhealthy") { $problemas += "Windows lo marca como DAÑADO." }
        elseif ($d.Salud -eq "Warning") { $problemas += "Windows avisa de que empieza a fallar." }
        if ($d.Desgaste -ge 90) { $problemas += "Desgaste del $($d.Desgaste) %: está al final de su vida." } elseif ($d.Desgaste -ge 70) { $problemas += "Desgaste del $($d.Desgaste) %." }
        if ($d.ErroresLectura -gt 0 -or $d.ErroresEscritura -gt 0) { $problemas += "Tiene $($d.ErroresLectura + $d.ErroresEscritura) error(es) de lectura/escritura sin corregir." }
        if ($d.Temperatura -ge 60) { $problemas += "Temperatura alta: $($d.Temperatura) °C." }
        $grave = ($d.Salud -eq "Unhealthy" -or $d.Desgaste -ge 90 -or ($d.ErroresLectura + $d.ErroresEscritura) -gt 0)
        $colorBorde = if ($grave) { "#DC2626" } elseif ($problemas.Count) { "#D97706" } else { "#16A34A" }
        $marco = New-Marco -Borde $colorBorde
        $marco.BorderThickness = "4,1,1,1"
        $pila = New-Object System.Windows.Controls.StackPanel
        $icono = if ($grave) { [char]0x2716 } elseif ($problemas.Count) { [char]0x26A0 } else { [char]0x2714 }
        [void]$pila.Children.Add((New-Texto "$icono $($d.Nombre)   ($($d.Tipo), $($d.GB) GB)" "#111827" 13.5 "SemiBold"))
        $datosD = @()
        $datosD += "Salud: " + $(switch ($d.Salud) { "Healthy" { "bien" } "Warning" { "con avisos" } "Unhealthy" { "MAL" } default { $d.Salud } })
        if ($null -ne $d.Temperatura) { $datosD += "temperatura $($d.Temperatura) °C" }
        if ($null -ne $d.Desgaste) { $datosD += "desgaste $($d.Desgaste) %" }
        if ($null -ne $d.Horas) { $datosD += "encendido $([math]::Round($d.Horas / 24)) días en total" }
        [void]$pila.Children.Add((New-Texto ($datosD -join "   ·   ") "#4B5563" 12.5 "Normal" "20,2,0,0"))
        if ($problemas.Count) {
            $consejo = if ($grave) { "Haz copia de tus archivos YA y cambia este disco. En una PC de cámaras, las grabaciones pueden perderse o cortarse." } else { "Vigílalo y ten copia de lo importante." }
            [void]$pila.Children.Add((New-Texto (($problemas -join " ") + " " + $consejo) $colorBorde 12.5 "SemiBold" "20,3,0,0"))
        }
        $marco.Child = $pila
        [void]$panel.Children.Add($marco)
    }
    if (@($global:Estado.Discos).Count -eq 0) { [void]$panel.Children.Add((New-Texto "Windows no dio información de los discos en este equipo." "#6B7280")) }
    if ($global:Estado.AvisoSmart) { [void]$panel.Children.Add((New-Texto "$([char]0x2716) La autoprueba SMART de un disco avisa de un fallo próximo. Haz copia de seguridad cuanto antes." "#DC2626" 13 "SemiBold" "0,4,0,6")) }
    $bat = $global:Estado.Bateria
    if ($bat) {
        $colorBat = if ($bat.Salud -lt 60) { "#DC2626" } elseif ($bat.Salud -lt 80) { "#D97706" } else { "#16A34A" }
        $textoBat = "Batería: conserva el $($bat.Salud) % de su capacidad original" + $(if ($bat.Ciclos) { " ($($bat.Ciclos) ciclos de carga)" } else { "" }) + "." +
            $(if ($bat.Salud -lt 60) { " Conviene cambiarla." } elseif ($bat.Salud -lt 80) { " Desgaste normal por uso." } else { " Está bien." })
        [void]$panel.Children.Add((New-Texto $textoBat $colorBat 13 "SemiBold" "0,6,0,4"))
    }
}

[void]$pR.Children.Add((New-Titulo "Salud de discos y batería" "Lee el estado que informan los propios discos (SMART): temperatura, desgaste y errores. Avisa antes de que un disco falle."))
$filaDis = New-Object System.Windows.Controls.WrapPanel
$filaDis.Margin = "0,0,0,6"
[void]$filaDis.Children.Add((New-Boton "Revisar discos" { Start-SaludDiscos } -Primario))
[void]$filaDis.Children.Add((New-Boton "Informe de batería" { Start-Pasos -Pasos @(New-PasoScript -Nombre "Informe de batería" -Codigo $script:codigoBateria) }))
[void]$pR.Children.Add($filaDis)
$script:PanelDiscos = New-Object System.Windows.Controls.StackPanel
$script:PanelDiscos.Margin = "0,0,0,8"
[void]$pR.Children.Add($script:PanelDiscos)

# ---------------------------------------------------------------- Rendimiento: prioridad de programas (como Process Lasso)
$script:RutaIFEO = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
# Ojo: con [ordered] y claves numéricas, $d[3] sería la posición 3, no la clave 3; por eso el orden va en una lista aparte
$script:OrdenPrioridades = @(3, 6, 2, 5, 1)
$script:Prioridades = @{ 3 = "Alta"; 6 = "Por encima de lo normal"; 2 = "Normal"; 5 = "Por debajo de lo normal"; 1 = "Baja" }
$script:ClasesPrioridad = @{ 3 = "High"; 6 = "AboveNormal"; 2 = "Normal"; 5 = "BelowNormal"; 1 = "Idle" }

function Get-ReglasPrioridad {
    $reglas = @()
    foreach ($k in @(Get-ChildItem -LiteralPath $script:RutaIFEO -ErrorAction SilentlyContinue)) {
        $po = Join-Path $k.PSPath "PerfOptions"
        if (-not (Test-Path -LiteralPath $po)) { continue }
        $v = (Get-ItemProperty -LiteralPath $po -Name CpuPriorityClass -ErrorAction SilentlyContinue).CpuPriorityClass
        if ($null -ne $v) { $reglas += [pscustomobject]@{ Exe = $k.PSChildName; Valor = [int]$v } }
    }
    return @($reglas | Sort-Object Exe)
}

function Set-ReglaPrioridad([string]$Exe, [int]$Valor, [switch]$SinHistorial) {
    if ($Exe -notmatch '^[^\\/:*?"<>|]+\.exe$') { throw "Escribe el nombre del programa terminado en .exe (por ejemplo: chrome.exe)." }
    $po = Join-Path (Join-Path $script:RutaIFEO $Exe) "PerfOptions"
    $anterior = (Get-ItemProperty -LiteralPath $po -Name CpuPriorityClass -ErrorAction SilentlyContinue).CpuPriorityClass
    if (-not (Test-Path -LiteralPath $po)) { New-Item -Path $po -Force | Out-Null }
    New-ItemProperty -LiteralPath $po -Name CpuPriorityClass -Value $Valor -PropertyType DWord -Force | Out-Null
    # Los que ya están abiertos también se cambian ahora
    $n = 0
    foreach ($pr in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction SilentlyContinue)) {
        try { $pr.PriorityClass = $script:ClasesPrioridad[$Valor]; $n++ } catch { }
    }
    Escribir-Log "Prioridad de ${Exe}: $($script:Prioridades[$Valor]) (aplicada ya a $n proceso(s) abiertos y siempre que se abra)."
    if (-not $SinHistorial) { Add-Historial -Tipo "Prioridad" -Clave $Exe -Nombre "Prioridad $($script:Prioridades[$Valor]) para $Exe" -Accion "Añadida" -Datos @{ Exe = $Exe; Valor = $Valor; Anterior = $anterior } }
}

function Remove-ReglaPrioridad([string]$Exe, [switch]$SinHistorial) {
    $clave = Join-Path $script:RutaIFEO $Exe
    $po = Join-Path $clave "PerfOptions"
    $anterior = (Get-ItemProperty -LiteralPath $po -Name CpuPriorityClass -ErrorAction SilentlyContinue).CpuPriorityClass
    Remove-ItemProperty -LiteralPath $po -Name CpuPriorityClass -ErrorAction SilentlyContinue
    # Solo se borran las claves si quedaron vacías (pueden tener otros ajustes)
    $k = Get-Item -LiteralPath $po -ErrorAction SilentlyContinue
    if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $po -Force -ErrorAction SilentlyContinue }
    $k2 = Get-Item -LiteralPath $clave -ErrorAction SilentlyContinue
    if ($k2 -and $k2.ValueCount -eq 0 -and $k2.SubKeyCount -eq 0) { Remove-Item -LiteralPath $clave -Force -ErrorAction SilentlyContinue }
    foreach ($pr in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction SilentlyContinue)) { try { $pr.PriorityClass = "Normal" } catch { } }
    Escribir-Log "Prioridad de ${Exe}: vuelve a la normal."
    if (-not $SinHistorial -and $null -ne $anterior) { Add-Historial -Tipo "Prioridad" -Clave $Exe -Nombre "Quitada la prioridad fija de $Exe" -Accion "Quitada" -Datos @{ Exe = $Exe; Valor = [int]$anterior } }
}

function Show-ReglasPrioridad {
    $panel = $script:PanelReglas
    $panel.Children.Clear()
    $reglas = Get-ReglasPrioridad
    if (-not $reglas.Count) { [void]$panel.Children.Add((New-Texto "Aún no hay programas con prioridad fija." "#6B7280" 12.5 "Normal" "0,0,0,4")); return }
    foreach ($r in $reglas) {
        $marco = New-Marco -Margen "0,0,0,4" -Relleno "12,6"
        $fila = New-Object System.Windows.Controls.DockPanel
        $b = New-Boton "Quitar" ([scriptblock]::Create("Remove-ReglaPrioridad '$($r.Exe.Replace("'", "''"))'; Show-ReglasPrioridad")) -Margen "8,0,0,0" -Libre
        [System.Windows.Controls.DockPanel]::SetDock($b, "Right")
        [void]$fila.Children.Add($b)
        $nombrePrio = $script:Prioridades[$r.Valor]
        if (-not $nombrePrio) { $nombrePrio = "valor $($r.Valor)" }
        $txt = New-Texto "$($r.Exe)   $([char]0x2192)   $nombrePrio" "#111827" 13 "SemiBold"
        $txt.VerticalAlignment = "Center"
        [void]$fila.Children.Add($txt)
        $marco.Child = $fila
        [void]$panel.Children.Add($marco)
    }
}

[void]$pR.Children.Add((New-Titulo "Prioridad de programas" "Como Process Lasso: elige qué programas reciben más procesador. Windows lo aplica solo cada vez que se abren, sin dejar nada corriendo."))
$filaPrio = New-Object System.Windows.Controls.WrapPanel
$filaPrio.Margin = "0,0,0,6"
$script:CmbExe = New-Object System.Windows.Controls.ComboBox
$script:CmbExe.IsEditable = $true
$script:CmbExe.Width = 260
$script:CmbExe.Margin = "0,0,8,6"
$script:CmbExe.ToolTip = "Elige un programa abierto o escribe su nombre (por ejemplo: iVMS-4200.Framework.C.exe)"
$script:CmbExe.Add_DropDownOpened({
    $actual = $script:CmbExe.Text
    $script:CmbExe.Items.Clear()
    foreach ($n in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -ne 0 -and $_.MainWindowHandle -ne 0 -or $_.ProcessName -match $script:PatronCamaras } | ForEach-Object { "$($_.ProcessName).exe" } | Sort-Object -Unique)) { [void]$script:CmbExe.Items.Add($n) }
    $script:CmbExe.Text = $actual
})
[void]$filaPrio.Children.Add($script:CmbExe)
$script:CmbPrio = New-Object System.Windows.Controls.ComboBox
$script:CmbPrio.Width = 200
$script:CmbPrio.Margin = "0,0,8,6"
foreach ($k in $script:OrdenPrioridades) { [void]$script:CmbPrio.Items.Add($script:Prioridades[$k]) }
$script:CmbPrio.SelectedIndex = 1
[void]$filaPrio.Children.Add($script:CmbPrio)
[void]$filaPrio.Children.Add((New-Boton "Añadir regla" {
    $exe = ([string]$script:CmbExe.Text).Trim()
    if ($exe -and $exe -notmatch '\.exe$') { $exe += ".exe" }
    $valor = $script:OrdenPrioridades[$script:CmbPrio.SelectedIndex]
    if ($valor -eq 3 -and [System.Windows.MessageBox]::Show("Prioridad 'Alta' para $exe.`r`n`r`nSi ese programa usa mucho procesador, el resto de Windows (ratón, sonido) puede ir a tirones. Para la mayoría basta 'Por encima de lo normal'.`r`n`r`n¿Usar 'Alta' igualmente?", "Prioridad", "YesNo", "Warning") -ne "Yes") { return }
    try { Set-ReglaPrioridad $exe $valor; Show-ReglasPrioridad }
    catch { [void][System.Windows.MessageBox]::Show($_.Exception.Message, "Prioridad", "OK", "Warning") }
} -Primario -Libre))
[void]$pR.Children.Add($filaPrio)
[void]$pR.Children.Add((New-Texto "Nunca pongas en 'Baja' el antivirus ni programas del sistema. 'Tiempo real' no se ofrece a propósito: puede congelar el equipo." "#6B7280" 12.5 "Normal" "0,0,0,6"))
$script:PanelReglas = New-Object System.Windows.Controls.StackPanel
$script:PanelReglas.Margin = "0,0,0,8"
[void]$pR.Children.Add($script:PanelReglas)
Show-ReglasPrioridad

# ---------------------------------------------------------------- Pestaña Historial de cambios
$script:TextosAccion = @{
    Aplicado = @{ Color = "#16A34A"; Boton = "Deshacer" }; Deshecho = @{ Color = "#6B7280"; Boton = "Volver a aplicar" }
    Desactivado = @{ Color = "#D97706"; Boton = "Volver a activar" }; Activado = @{ Color = "#16A34A"; Boton = "Desactivar otra vez" }
    "Añadida" = @{ Color = "#2563EB"; Boton = "Quitar" }; Quitada = @{ Color = "#6B7280"; Boton = "Volver a poner" }
    Limpiado = @{ Color = "#2563EB"; Boton = "" }; Borrados = @{ Color = "#2563EB"; Boton = "" }; Desinstalado = @{ Color = "#2563EB"; Boton = "" }
}

function Read-Historial {
    $ruta = Get-RutaHistorial
    if (-not (Test-Path -LiteralPath $ruta)) { return @() }
    $res = foreach ($l in @(Get-Content -LiteralPath $ruta -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($l -and $l.Trim()) { try { $l | ConvertFrom-Json } catch { } }
    }
    return @($res)
}

function Show-Historial {
    $panel = $script:PanelHistorial
    $panel.Children.Clear()
    $todos = Read-Historial
    if ($todos.Count -eq 0) {
        [void]$panel.Children.Add((New-Texto "Todavía no hay cambios anotados. Aquí aparecerá cada ajuste, perfil, cambio del arranque, prioridad y limpieza que hagas con el optimizador." "#6B7280"))
        return
    }
    # Solo la última anotación de cada cosa se puede deshacer (las anteriores ya no reflejan cómo está)
    $ultima = @{}
    for ($i = 0; $i -lt $todos.Count; $i++) { $ultima["$($todos[$i].Tipo)|$($todos[$i].Clave)"] = $i }
    [void]$panel.Children.Add((New-Texto "$($todos.Count) cambio(s) anotados. Los más recientes primero." "#6B7280" 12.5 "Normal" "0,0,0,6"))
    $mostrados = 0
    for ($i = $todos.Count - 1; $i -ge 0 -and $mostrados -lt 250; $i--) {
        $mostrados++
        $h = $todos[$i]
        $marco = New-Marco -Margen "0,0,0,4" -Relleno "12,6"
        $fila = New-Object System.Windows.Controls.DockPanel
        $info = $script:TextosAccion[[string]$h.Accion]
        $puede = ($ultima["$($h.Tipo)|$($h.Clave)"] -eq $i) -and @("Ajuste", "Arranque", "Prioridad") -contains [string]$h.Tipo -and $info -and $info.Boton
        if ($puede) {
            $b = New-Boton $info.Boton ([scriptblock]::Create("Invoke-DeshacerHistorial $i")) -Margen "8,0,0,0" -Libre
            $b.VerticalAlignment = "Center"
            [System.Windows.Controls.DockPanel]::SetDock($b, "Right")
            [void]$fila.Children.Add($b)
        }
        $pila = New-Object System.Windows.Controls.StackPanel
        [void]$pila.Children.Add((New-Texto ([string]$h.Nombre) "#111827" 13 "SemiBold"))
        $fecha = try { ([datetime]$h.Fecha).ToString("dd/MM/yyyy HH:mm") } catch { [string]$h.Fecha }
        $linea = New-Object System.Windows.Controls.TextBlock
        $linea.FontSize = 12
        $r1 = New-Object System.Windows.Documents.Run "$($h.Accion)   "
        $r1.Foreground = Get-Pincel $(if ($info) { $info.Color } else { "#6B7280" })
        $r1.FontWeight = "SemiBold"
        $r2 = New-Object System.Windows.Documents.Run $fecha
        $r2.Foreground = Get-Pincel "#6B7280"
        [void]$linea.Inlines.Add($r1); [void]$linea.Inlines.Add($r2)
        if ([string]$h.Tipo -eq "Restos" -and $h.Datos.Copia) {
            $r3 = New-Object System.Windows.Documents.Run "   ·   carpetas en la Papelera, copia del registro en $($h.Datos.Copia)"
            $r3.Foreground = Get-Pincel "#9CA3AF"
            [void]$linea.Inlines.Add($r3)
        }
        [void]$pila.Children.Add($linea)
        [void]$fila.Children.Add($pila)
        $marco.Child = $fila
        [void]$panel.Children.Add($marco)
    }
}

function Invoke-DeshacerHistorial([int]$Indice) {
    $todos = Read-Historial
    if ($Indice -ge $todos.Count) { return }
    $h = $todos[$Indice]
    switch ([string]$h.Tipo) {
        "Ajuste" {
            $it = Get-ItemPorClave ([string]$h.Clave)
            if (-not $it) { [void][System.Windows.MessageBox]::Show("Este ajuste ya no existe en esta versión del optimizador.", "Historial", "OK", "Information"); return }
            $deshacer = ([string]$h.Accion -eq "Aplicado")
            $verbo = if ($deshacer) { "deshacer" } else { "volver a aplicar" }
            if ([System.Windows.MessageBox]::Show("¿$($verbo.Substring(0,1).ToUpper())$($verbo.Substring(1)) '$($it.Nombre)'?", "Historial", "YesNo", "Question") -ne "Yes") { return }
            Start-Pasos -Pasos @([pscustomobject]@{ Item = $it; Deshacer = $deshacer }) -Titulo "Historial: $verbo" -OfrecerReinicio
        }
        "Arranque" {
            $ent = @{}
            foreach ($pr in $h.Datos.PSObject.Properties) { $ent[$pr.Name] = $pr.Value }
            $activar = ([string]$h.Accion -eq "Desactivado")
            if (Set-EntradaArranque $ent $activar) {
                $enLista = if ($global:Estado.Arranque) { @($global:Estado.Arranque | Where-Object { $_.Id -eq $ent.Id })[0] } else { $null }
                if ($enLista) { $enLista.Activo = $activar; Show-Arranque }
                Show-Historial
            }
        }
        "Prioridad" {
            try {
                $exe = [string]$h.Datos.Exe
                if ([string]$h.Accion -eq "Añadida") {
                    if ($null -ne $h.Datos.Anterior) { Set-ReglaPrioridad $exe ([int]$h.Datos.Anterior) } else { Remove-ReglaPrioridad $exe }
                } else {
                    Set-ReglaPrioridad $exe ([int]$h.Datos.Valor)
                }
                Show-ReglasPrioridad
                Show-Historial
            } catch { [void][System.Windows.MessageBox]::Show($_.Exception.Message, "Historial", "OK", "Warning") }
        }
    }
}

$pHist = $script:UI.PanelHistorial
[void]$pHist.Children.Add((New-Titulo "Historial de cambios" "Todo lo que cambiaste con el optimizador, con fecha. Lo último de cada cosa tiene un botón para deshacerlo."))
$filaHist = New-Object System.Windows.Controls.WrapPanel
$filaHist.Margin = "0,0,0,8"
[void]$filaHist.Children.Add((New-Boton "Actualizar" { Show-Historial } -Libre))
[void]$filaHist.Children.Add((New-Boton "Abrir el archivo" {
    $ruta = Get-RutaHistorial
    if (Test-Path -LiteralPath $ruta) { Start-Process notepad.exe -ArgumentList "`"$ruta`"" }
} -Libre))
[void]$filaHist.Children.Add((New-Boton "Vaciar historial" {
    if ([System.Windows.MessageBox]::Show("Se borra solo esta lista; los cambios hechos en Windows se quedan como están y se pueden seguir deshaciendo desde cada pestaña.`r`n`r`n¿Vaciar el historial?", "Historial", "YesNo", "Question") -ne "Yes") { return }
    Remove-Item -LiteralPath (Get-RutaHistorial) -Force -ErrorAction SilentlyContinue
    Show-Historial
}))
[void]$pHist.Children.Add($filaHist)
$script:PanelHistorial = New-Object System.Windows.Controls.StackPanel
[void]$pHist.Children.Add($script:PanelHistorial)

# ---------------------------------------------------------------- Configuración: apariencia y tu configuración
function Switch-Tema {
    if ($script:Trabajo) {
        [void][System.Windows.MessageBox]::Show("Espera a que termine el trabajo en curso.", "Modo oscuro", "OK", "Information")
        if ($script:ChkOscuro) { $script:ChkOscuro.IsChecked = $script:Oscuro }
        return
    }
    $script:Prefs.Tema = if ($script:Oscuro) { "Claro" } else { "Oscuro" }
    $script:Prefs.AbrirEn = [string]$script:UI.Pestanas.SelectedItem.Name
    Save-Prefs
    if (-not $script:RutaScript -or -not (Test-Path -LiteralPath $script:RutaScript)) {
        [void][System.Windows.MessageBox]::Show("Se verá así la próxima vez que abras el optimizador.", "Modo oscuro", "OK", "Information")
        return
    }
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$($script:RutaScript)`"")
    $script:Ventana.Close()
}
$script:UI.BtnTema.Content = if ($script:Oscuro) { "$([char]0x2600)  Modo claro" } else { "$([char]0x263E)  Modo oscuro" }
$script:UI.BtnTema.Add_Click({ Switch-Tema })

$pC = $script:UI.PanelConfig
[void]$pC.Children.Add((New-Titulo "Apariencia y comodidad" "Cómo se ve y se abre el optimizador."))
$script:ChkOscuro = New-Object System.Windows.Controls.CheckBox
$script:ChkOscuro.Content = "Modo oscuro (el optimizador se vuelve a abrir para aplicarlo)"
$script:ChkOscuro.IsChecked = $script:Oscuro
$script:ChkOscuro.Margin = "0,0,0,6"
$script:ChkOscuro.Add_Click({ Switch-Tema })
[void]$pC.Children.Add($script:ChkOscuro)
$script:ChkRecordar = New-Object System.Windows.Controls.CheckBox
$script:ChkRecordar.Content = "Abrir en la última pestaña que usé (si no, siempre abre en Inicio)"
$script:ChkRecordar.IsChecked = [bool]$script:Prefs.RecordarPestana
$script:ChkRecordar.Margin = "0,0,0,10"
$script:ChkRecordar.Add_Click({
    $script:Prefs.RecordarPestana = [bool]$script:ChkRecordar.IsChecked
    $script:Prefs.UltimaPestana = [string]$script:UI.Pestanas.SelectedItem.Name
    Save-Prefs
})
[void]$pC.Children.Add($script:ChkRecordar)

[void]$pC.Children.Add((New-Titulo "Tu configuración del optimizador" "Guarda en un archivo lo que tienes marcado (ajustes, preferencias, apps y privacidad), tus reglas de prioridad y el tema, para repetirlo en otra PC."))
$filaCfg = New-Object System.Windows.Controls.WrapPanel
[void]$filaCfg.Children.Add((New-Boton "Exportar configuración" { $script:UI.BtnExportar.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent))) } -Libre))
[void]$filaCfg.Children.Add((New-Boton "Importar configuración" { $script:UI.BtnImportar.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Button]::ClickEvent))) } -Libre))
[void]$pC.Children.Add($filaCfg)

# ---------------------------------------------------------------- Enganches con el resto del optimizador
function Update-VistasExtra {
    Update-VistaPrivacidad
    if ($script:PerfilesVistos) { Update-EstadoPerfiles }
    if ([string]$script:UI.Pestanas.SelectedItem.Name -eq "TabHistorial") { Show-Historial }
}

function Invoke-ComprobacionExtra([string]$Sel) {
    if ($script:AnalisisPendiente -and -not $script:Trabajo) { Start-Analisis; return }
    switch ($Sel) {
        "TabPerfiles" {
            if (-not $script:PerfilesVistos) { $script:PerfilesVistos = $true; $script:ProgramaCamaras = Find-ProgramaCamaras }
            Update-EstadoPerfiles
        }
        "TabPrivacidad" { Update-VistaPrivacidad }
        "TabArranque"   { if (-not $script:ArranqueCargado) { Start-ListaArranque } }
        "TabProgramas"  { if (-not $script:ProgramasCargados) { Show-Instalados } }
        "TabHistorial"  { Show-Historial }
    }
}
$script:PerfilesVistos = $false

# ---------------------------------------------------------------- Secciones plegables
# Cada título de sección pasa a ser un desplegable con sus opciones dentro; solo se abren las principales.
function Convert-Plegable($Panel, [string[]]$Abiertas = @()) {
    $hijos = @($Panel.Children)
    $titulos = @($hijos | Where-Object { $_.Uid -eq "Titulo" })
    if ($titulos.Count -lt 2) { return }
    $Panel.Children.Clear()
    $actual = $null
    $primero = $true
    foreach ($h in $hijos) {
        if ($h.Uid -eq "Titulo") {
            $exp = New-Object System.Windows.Controls.Expander
            $exp.Margin = "0,4,0,6"
            $exp.Tag = [string]$h.Tag
            $cab = New-Object System.Windows.Controls.StackPanel
            $cab.Margin = "4,2,0,2"
            $txtCab = New-Object System.Windows.Controls.TextBlock
            $txtCab.Text = [string]$h.Tag
            $txtCab.FontSize = 16
            $txtCab.FontWeight = "SemiBold"
            $txtCab.Foreground = Get-Pincel "#111827"
            [void]$cab.Children.Add($txtCab)
            $sub = @($h.Children)[1]
            $txtSub = New-Object System.Windows.Controls.TextBlock
            $txtSub.TextWrapping = "Wrap"
            $txtSub.Foreground = Get-Pincel "#6B7280"
            $txtSub.Text = if ($sub) { [string]$sub.Text } else { "" }
            [void]$cab.Children.Add($txtSub)
            $exp.Header = $cab
            $contenido = New-Object System.Windows.Controls.StackPanel
            $contenido.Margin = "0,8,0,0"
            $exp.Content = $contenido
            $exp.IsExpanded = if ($Abiertas.Count) { $Abiertas -contains [string]$h.Tag } else { $primero }
            $primero = $false
            $exp.Uid = "Seccion"
            [void]$Panel.Children.Add($exp)
            $actual = $contenido
        } elseif ($actual) {
            [void]$actual.Children.Add($h)
        } else {
            [void]$Panel.Children.Add($h)
        }
    }
    # Cuántas opciones hay dentro de cada sección
    foreach ($exp in @($Panel.Children | Where-Object { $_.Uid -eq "Seccion" })) {
        $n = @($exp.Content.Children | Where-Object { $_ -is [System.Windows.Controls.Border] }).Count
        if ($n) { $exp.Header.Children[0].Text = "$($exp.Tag)   ($n)" }
    }
}

# Buscador de la pestaña Ajustes
$filaBuscar = New-Object System.Windows.Controls.DockPanel
$filaBuscar.Margin = "0,0,0,8"
$lblBuscar = New-Object System.Windows.Controls.TextBlock
$lblBuscar.Text = "Buscar ajuste:"
$lblBuscar.VerticalAlignment = "Center"
$lblBuscar.Margin = "0,0,8,0"
[System.Windows.Controls.DockPanel]::SetDock($lblBuscar, "Left")
[void]$filaBuscar.Children.Add($lblBuscar)
$script:TxtBuscarAjuste = New-Object System.Windows.Controls.TextBox
$script:TxtBuscarAjuste.ToolTip = "Escribe parte del nombre o la descripción (por ejemplo: telemetría, Cortana, ratón)"
$script:TxtBuscarAjuste.Add_TextChanged({ Update-FiltroAjustes })
[void]$filaBuscar.Children.Add($script:TxtBuscarAjuste)
$script:UI.PanelAjustes.Children.Insert(0, $filaBuscar)

function Update-FiltroAjustes {
    $texto = ([string]$script:TxtBuscarAjuste.Text).Trim()
    foreach ($c in $script:CasillasAjustes) {
        $it = $c.Tag
        $info = $script:InfoAjuste[$it.Key]
        if (-not $info) { continue }
        $coincide = (-not $texto) -or ("$($it.Nombre) $($it.Descripcion) $($it.Aviso)" -like "*$texto*")
        $info.Borde.Visibility = if ($coincide -and -not $info.Oculto) { "Visible" } else { "Collapsed" }
    }
    if ($texto) {
        foreach ($exp in @($script:UI.PanelAjustes.Children | Where-Object { $_.Uid -eq "Seccion" })) { $exp.IsExpanded = $true }
    }
}

Convert-Plegable $script:UI.PanelAjustes @("Ajustes esenciales")
Convert-Plegable $script:UI.PanelRendimiento @("Memoria RAM")
Convert-Plegable $script:UI.PanelPrivacidad @("Verde: recomendado", "Amarillo: con cuidado")
Convert-Plegable $script:UI.PanelProgramas @("Actualizaciones de programas", "Desinstalar a fondo")
Convert-Plegable $script:UI.PanelSeguridad @("Revisión propia (sin antivirus)", "Buscar virus y revisar el sistema")
Convert-Plegable $script:UI.PanelConfig
Convert-Plegable $script:UI.PanelAyuda
Update-FiltroAjustes
# Abre siempre en Inicio (sin esto, la primera pestaña solo se elige al mostrarse la ventana)
$script:UI.Pestanas.SelectedItem = $script:Ventana.FindName("TabInicio")
if (-not $Prueba) {
    # Al cambiar de tema se vuelve a la misma pestaña; o a la última usada, si se eligió en Configuración
    $abrirEn = if ($script:Prefs.AbrirEn) { [string]$script:Prefs.AbrirEn } elseif ($script:Prefs.RecordarPestana) { [string]$script:Prefs.UltimaPestana } else { "" }
    if ($script:Prefs.AbrirEn) { $script:Prefs.AbrirEn = ""; Save-Prefs }
    if ($abrirEn) { Select-Pestana $abrirEn }
}
Update-BotonesPestana
$script:UI.Pestanas.Add_SelectionChanged({
    param($origen, $evento)
    if ($evento.OriginalSource -ne $script:UI.Pestanas -or -not $script:Prefs.RecordarPestana) { return }
    $nombreTab = [string]$script:UI.Pestanas.SelectedItem.Name
    if ($nombreTab -and $nombreTab -ne $script:Prefs.UltimaPestana) { $script:Prefs.UltimaPestana = $nombreTab; Save-Prefs }
})

Escribir-Log "Optimizador iniciado. Registro: $global:ArchivoLog"
if ($Prueba) {
    $temporizador.Stop()
    $script:TemporizadorRam.Stop()
    return
}
# Ajusta la ventana a pantallas pequeñas (portátiles de 1366x768)
$zona = [System.Windows.SystemParameters]::WorkArea
if ($script:Ventana.Height -gt $zona.Height - 10) { $script:Ventana.Height = $zona.Height - 10 }
if ($script:Ventana.Width -gt $zona.Width - 10) { $script:Ventana.Width = $zona.Width - 10 }
# Al abrir se analiza el equipo para mostrar las recomendaciones
$script:Ventana.Add_ContentRendered({ Start-Analisis })
[void]$script:Ventana.ShowDialog()
$temporizador.Stop()
$script:TemporizadorRam.Stop()
