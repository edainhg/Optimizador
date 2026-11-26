#Requires -Version 5.1
<#
    LiberarRAM - Ganar y liberar memoria RAM en Windows (en español)
    Parte del Optimizador ES. Todo lo que cambia se guarda en un respaldo y se
    puede revertir desde el menú (opción 9). Antes de cambiar algo se crea un
    punto de restauración.

    Uso:
        Doble clic en Iniciar-LiberarRAM.bat                       (menú)
        powershell -ExecutionPolicy Bypass -File .\LiberarRAM.ps1 -Liberar   (solo liberar RAM, sin menú)
#>
param([switch]$Liberar)

# ---------------------------------------------------------------- Permisos de administrador
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Pidiendo permisos de administrador..."
    $argumentos = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Liberar) { $argumentos += "-Liberar" }
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argumentos
    exit
}

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$Host.UI.RawUI.WindowTitle = "Liberar RAM - Optimizador ES"

$script:Carpeta = Join-Path $env:LOCALAPPDATA "OptimizadorES\RAM"
New-Item -ItemType Directory -Path $script:Carpeta -Force | Out-Null
$script:ArchivoRespaldo = Join-Path $script:Carpeta "respaldo.json"
$script:ArchivoLog = Join-Path $script:Carpeta ("registro-{0:yyyy-MM-dd}.log" -f (Get-Date))
$script:PuntoCreado = $false

# ---------------------------------------------------------------- Utilidades
function Log([string]$m, [string]$nivel = "INFO") {
    try { Add-Content -Path $script:ArchivoLog -Value ("{0:HH:mm:ss} [{1}] {2}" -f (Get-Date), $nivel, $m) -Encoding UTF8 } catch { }
}
function Ok([string]$m)    { Write-Host "  [OK] $m" -ForegroundColor Green; Log $m }
function Aviso([string]$m) { Write-Host "  [!]  $m" -ForegroundColor Yellow; Log $m "AVISO" }
function Error2([string]$m){ Write-Host "  [X]  $m" -ForegroundColor Red; Log $m "ERROR" }
function Info([string]$m)  { Write-Host "  $m" }
function Titulo([string]$t) {
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
}
function Pausa { Write-Host ""; [void](Read-Host "  Pulsa Enter para volver al menú") }
function Confirmar([string]$pregunta) {
    $r = Read-Host "  $pregunta (S/N)"
    return ($r -match '^\s*[sSyY]')
}
function GB($bytes) { return [math]::Round($bytes / 1GB, 2) }

function Get-Memoria {
    $os = Get-CimInstance Win32_OperatingSystem
    $total = [double]$os.TotalVisibleMemorySize * 1KB
    $libre = [double]$os.FreePhysicalMemory * 1KB
    [pscustomobject]@{
        Total      = $total
        Disponible = $libre
        EnUso      = $total - $libre
        Porcentaje = [math]::Round((($total - $libre) / $total) * 100, 0)
        Confirmada = ([double]$os.TotalVirtualMemorySize - [double]$os.FreeVirtualMemory) * 1KB
        LimiteConf = [double]$os.TotalVirtualMemorySize * 1KB
    }
}

function Leer-Lista([string]$texto, [int]$max) {
    # "1,3,5-7" -> 1 3 5 6 7
    $nums = New-Object System.Collections.Generic.List[int]
    foreach ($parte in ($texto -split '[,; ]+')) {
        if ($parte -match '^(\d+)-(\d+)$') {
            foreach ($n in [int]$Matches[1]..[int]$Matches[2]) { if ($n -ge 1 -and $n -le $max) { $nums.Add($n) } }
        } elseif ($parte -match '^\d+$') {
            $n = [int]$parte; if ($n -ge 1 -and $n -le $max) { $nums.Add($n) }
        }
    }
    return @($nums | Select-Object -Unique)
}

# ---------------------------------------------------------------- Respaldo para revertir
function Get-Respaldo {
    if (Test-Path $script:ArchivoRespaldo) {
        try {
            $j = Get-Content $script:ArchivoRespaldo -Raw -Encoding UTF8 | ConvertFrom-Json
            return @{
                Registro   = [System.Collections.ArrayList]@($j.Registro | Where-Object { $_ })
                Servicios  = [System.Collections.ArrayList]@($j.Servicios | Where-Object { $_ })
                Paginacion = $j.Paginacion
            }
        } catch { Aviso "El respaldo anterior no se pudo leer; se empieza uno nuevo." }
    }
    return @{ Registro = New-Object System.Collections.ArrayList; Servicios = New-Object System.Collections.ArrayList; Paginacion = $null }
}
function Save-Respaldo {
    $script:Respaldo | ConvertTo-Json -Depth 6 | Set-Content -Path $script:ArchivoRespaldo -Encoding UTF8
}
$script:Respaldo = Get-Respaldo

function Respaldar-Registro($ruta, $nombre) {
    # Solo se guarda el valor ORIGINAL (la primera vez que se toca)
    foreach ($r in $script:Respaldo.Registro) { if ($r.Ruta -eq $ruta -and $r.Nombre -eq $nombre) { return } }
    $existia = $false; $valor = $null; $tipo = $null
    if (Test-Path $ruta) {
        $clave = Get-Item -Path $ruta
        if ($clave.GetValueNames() -contains $nombre) {
            $existia = $true
            $valor = $clave.GetValue($nombre, $null, 'DoNotExpandEnvironmentNames')
            $tipo = [string]$clave.GetValueKind($nombre)
            if ($valor -is [byte[]]) { $valor = @($valor | ForEach-Object { [int]$_ }) }
        }
    }
    [void]$script:Respaldo.Registro.Add([pscustomobject]@{ Ruta = $ruta; Nombre = $nombre; Existia = $existia; Valor = $valor; Tipo = $tipo })
    Save-Respaldo
}

function Set-Valor($ruta, $nombre, $tipo, $valor) {
    try {
        Respaldar-Registro $ruta $nombre
        if (-not (Test-Path $ruta)) { New-Item -Path $ruta -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -Path $ruta -Name $nombre -PropertyType $tipo -Value $valor -Force -ErrorAction Stop | Out-Null
        Log "Registro: $ruta\$nombre = $valor"
        return $true
    } catch {
        Error2 "No se pudo cambiar $ruta\$nombre ($($_.Exception.Message))"
        return $false
    }
}

# ---------------------------------------------------------------- Punto de restauración
function Asegurar-PuntoRestauracion {
    if ($script:PuntoCreado) { return $true }
    Info "Creando punto de restauración (puede tardar un minuto)..."
    $claveSR = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"
    $previo = (Get-ItemProperty -Path $claveSR -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        # Windows solo deja crear uno cada 24 h; se quita el límite un momento
        New-ItemProperty -Path $claveSR -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force | Out-Null
        Checkpoint-Computer -Description "Liberar RAM - Optimizador ES" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        $script:PuntoCreado = $true
        Ok "Punto de restauración creado."
    } catch {
        Error2 "No se pudo crear el punto de restauración: $($_.Exception.Message)"
        Aviso "Igual puedes revertir desde la opción 9 (se guarda un respaldo propio)."
        if (Confirmar "¿Continuar sin punto de restauración?") { $script:PuntoCreado = $true }
    } finally {
        if ($null -eq $previo) { Remove-ItemProperty -Path $claveSR -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -Path $claveSR -Name SystemRestorePointCreationFrequency -Value $previo -ErrorAction SilentlyContinue }
    }
    return $script:PuntoCreado
}

# ---------------------------------------------------------------- Funciones nativas
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
    // SystemMemoryListInformation = 80
    // 2 = vaciar working sets, 3 = escribir lista modificada, 4 = purgar lista en espera, 5 = purgar en espera de baja prioridad
    public static int Lista(int comando) { return NtSetSystemInformation(80, ref comando, 4); }
}
}
"@
}

# ---------------------------------------------------------------- 1. Diagnóstico
function Show-Diagnostico {
    Titulo "Estado de la memoria"
    $m = Get-Memoria
    $color = if ($m.Porcentaje -ge 85) { "Red" } elseif ($m.Porcentaje -ge 70) { "Yellow" } else { "Green" }
    Write-Host ("  RAM total:        {0} GB" -f (GB $m.Total))
    Write-Host ("  En uso:           {0} GB ({1}%)" -f (GB $m.EnUso), $m.Porcentaje) -ForegroundColor $color
    Write-Host ("  Disponible:       {0} GB" -f (GB $m.Disponible))
    Write-Host ("  Memoria confirmada: {0} de {1} GB (RAM + archivo de paginación)" -f (GB $m.Confirmada), (GB $m.LimiteConf))

    try {
        $modulos = @(Get-CimInstance Win32_PhysicalMemory)
        $arreglo = Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1
        $desc = ($modulos | ForEach-Object { "{0} GB a {1} MHz" -f [math]::Round($_.Capacity / 1GB), $_.ConfiguredClockSpeed }) -join " + "
        Write-Host ("  Módulos:          {0} ({1} de {2} ranuras ocupadas)" -f $desc, $modulos.Count, $arreglo.MemoryDevices)
        if ($arreglo.MaxCapacityEx) { Write-Host ("  Máximo admitido:  {0} GB (según la placa)" -f [math]::Round($arreglo.MaxCapacityEx / 1MB)) }
    } catch { }

    try {
        $comp = Get-Process -Name "Memory Compression" -ErrorAction Stop
        Write-Host ("  Memoria comprimida: {0} MB (es normal: Windows comprime en vez de usar el disco)" -f [math]::Round($comp.WorkingSet64 / 1MB))
    } catch { }

    $cs = Get-CimInstance Win32_ComputerSystem
    $pag = @(Get-CimInstance Win32_PageFileUsage)
    if ($pag.Count -eq 0) { Write-Host "  Archivo de paginación: DESACTIVADO (no recomendado, ver opción 7)" -ForegroundColor Red }
    else {
        $modo = if ($cs.AutomaticManagedPagefile) { "automático" } else { "manual" }
        foreach ($p in $pag) { Write-Host ("  Archivo de paginación: {0}, {1} MB ({2}), uso pico {3} MB" -f $p.Name, $p.AllocatedBaseSize, $modo, $p.PeakUsage) }
    }

    Write-Host ""
    Write-Host "  Programas que más RAM usan (agrupados):" -ForegroundColor Cyan
    Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Nombre = $_.Name; Procesos = $_.Count; MB = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB) }
    } | Sort-Object MB -Descending | Select-Object -First 15 | ForEach-Object {
        Write-Host ("    {0,-32} {1,7} MB   ({2} proceso(s))" -f $_.Nombre, $_.MB, $_.Procesos)
    }

    $inicio = @(Get-ProgramasInicio | Where-Object { $_.Activo })
    Write-Host ""
    Write-Host ("  Programas que arrancan con Windows: {0} activos (opción 4 para revisarlos)" -f $inicio.Count) -ForegroundColor Cyan

    Write-Host ""
    if ((GB $m.Total) -le 8) {
        Aviso "Tu equipo tiene $([math]::Round((GB $m.Total))) GB. Con Windows 11 y un navegador moderno, la mejora real suele ser ampliar a 16 GB si la laptop lo permite."
    }
    Info "Nota: Windows usa la RAM libre como caché (memoria 'en espera'). Que esté ocupada no siempre es malo;"
    Info "lo que de verdad gana RAM es que arranquen y se queden abiertos menos programas (opciones 3 a 6)."
    Pausa
}

# ---------------------------------------------------------------- 2. Liberar RAM ahora
function Invoke-LiberarRAM([bool]$silencioso = $false) {
    if (-not $silencioso) { Titulo "Liberar RAM ahora" }
    $antes = Get-Memoria
    [void][OptESRam.Nativo]::Privilegio("SeProfileSingleProcessPrivilege")
    [void][OptESRam.Nativo]::Privilegio("SeIncreaseQuotaPrivilege")

    # Working sets: primero el método del sistema; si falla, proceso por proceso
    $r = [OptESRam.Nativo]::Lista(2)
    if ($r -ne 0) {
        $n = 0
        foreach ($p in Get-Process) {
            try { if ([OptESRam.Nativo]::EmptyWorkingSet($p.Handle)) { $n++ } } catch { }
        }
        Ok "Memoria de trabajo recortada en $n procesos."
    } else { Ok "Memoria de trabajo de los procesos recortada." }

    if ([OptESRam.Nativo]::Lista(3) -eq 0) { Ok "Lista modificada escrita a disco." }
    if ([OptESRam.Nativo]::Lista(5) -eq 0) { Ok "Caché en espera de baja prioridad vaciada." }
    if ([OptESRam.Nativo]::Lista(4) -eq 0) { Ok "Caché en espera vaciada." }
    else { Aviso "No se pudo vaciar la caché en espera (hace falta ser administrador)." }

    [System.GC]::Collect()
    Start-Sleep -Seconds 1
    $despues = Get-Memoria
    $ganado = $despues.Disponible - $antes.Disponible
    Write-Host ""
    Write-Host ("  RAM libre antes: {0} GB    después: {1} GB    (+{2} GB)" -f (GB $antes.Disponible), (GB $despues.Disponible), [math]::Max(0, (GB $ganado))) -ForegroundColor Green
    Log ("Liberar RAM: {0} GB a {1} GB" -f (GB $antes.Disponible), (GB $despues.Disponible))
    if (-not $silencioso) {
        Info "Es normal que los programas vuelvan a tomar parte de esa memoria cuando los uses."
        Pausa
    }
}

# ---------------------------------------------------------------- 3. Cerrar programas en segundo plano
$script:Protegidos = @(
    "System", "Idle", "Registry", "smss", "csrss", "wininit", "winlogon", "services", "lsass", "svchost", "dwm",
    "explorer", "fontdrvhost", "Memory Compression", "sihost", "ctfmon", "taskhostw", "RuntimeBroker", "SearchHost",
    "StartMenuExperienceHost", "ShellExperienceHost", "TextInputHost", "audiodg", "conhost", "powershell", "pwsh",
    "WindowsTerminal", "OpenConsole", "MsMpEng", "NisSrv", "SecurityHealthService", "SecurityHealthSystray",
    "ekrn", "egui", "eguiProxy", "spoolsv", "WmiPrvSE", "dllhost", "LsaIso", "SgrmBroker", "MpDefenderCoreService",
    "Claude", "claude"
)
function Close-ProgramasFondo {
    Titulo "Cerrar programas que están abiertos en segundo plano"
    Info "Se listan los programas de tu usuario que más RAM ocupan. Cerrarlos solo dura hasta que"
    Info "los vuelvas a abrir o reinicies; para que no arranquen solos usa la opción 4."
    Aviso "Guarda tu trabajo antes: lo que no esté guardado en esos programas se pierde."
    Write-Host ""
    $sesion = (Get-Process -Id $PID).SessionId
    $lista = @(Get-Process | Where-Object { $_.SessionId -eq $sesion -and $script:Protegidos -notcontains $_.ProcessName } |
        Group-Object ProcessName | ForEach-Object {
            [pscustomobject]@{ Nombre = $_.Name; MB = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB); Procesos = $_.Group
                Ventana = [bool]($_.Group | Where-Object { $_.MainWindowHandle -ne 0 }) }
        } | Where-Object { $_.MB -ge 30 } | Sort-Object MB -Descending | Select-Object -First 25)
    if ($lista.Count -eq 0) { Ok "No hay programas grandes abiertos."; Pausa; return }
    for ($i = 0; $i -lt $lista.Count; $i++) {
        $v = if ($lista[$i].Ventana) { "ventana abierta" } else { "en segundo plano" }
        Write-Host ("   {0,2}. {1,-30} {2,6} MB   {3}" -f ($i + 1), $lista[$i].Nombre, $lista[$i].MB, $v)
    }
    Write-Host ""
    $sel = Leer-Lista (Read-Host "  Números a cerrar (ej. 1,3,5-7) o Enter para cancelar") $lista.Count
    if ($sel.Count -eq 0) { return }
    $nombres = ($sel | ForEach-Object { $lista[$_ - 1].Nombre }) -join ", "
    if (-not (Confirmar "¿Cerrar $nombres?")) { return }
    $antes = Get-Memoria
    foreach ($n in $sel) {
        $item = $lista[$n - 1]
        foreach ($p in $item.Procesos) { try { [void]$p.CloseMainWindow() } catch { } }
        Start-Sleep -Milliseconds 800
        foreach ($p in $item.Procesos) { try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction Stop } } catch { } }
        Ok "Cerrado: $($item.Nombre)"
    }
    Start-Sleep -Seconds 1
    $d = Get-Memoria
    Write-Host ("  RAM libre: {0} GB a {1} GB" -f (GB $antes.Disponible), (GB $d.Disponible)) -ForegroundColor Green
    Pausa
}

# ---------------------------------------------------------------- 4. Programas de inicio
function Get-ProgramasInicio {
    $fuentes = @(
        @{ Run = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run";              Aprob = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";   Donde = "Usuario" },
        @{ Run = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run";              Aprob = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";   Donde = "Equipo" },
        @{ Run = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run";  Aprob = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32"; Donde = "Equipo (32 bits)" }
    )
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($f in $fuentes) {
        if (-not (Test-Path $f.Run)) { continue }
        $clave = Get-Item $f.Run
        foreach ($nombre in $clave.GetValueNames()) {
            if ([string]::IsNullOrEmpty($nombre)) { continue }
            $res.Add([pscustomobject]@{ Nombre = $nombre; Comando = [string]$clave.GetValue($nombre); Aprob = $f.Aprob; Donde = $f.Donde; Activo = (Test-InicioActivo $f.Aprob $nombre) })
        }
    }
    $carpetas = @(
        @{ Ruta = [Environment]::GetFolderPath("Startup");       Aprob = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"; Donde = "Carpeta Inicio" },
        @{ Ruta = [Environment]::GetFolderPath("CommonStartup"); Aprob = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"; Donde = "Carpeta Inicio (todos)" }
    )
    foreach ($c in $carpetas) {
        if (-not $c.Ruta -or -not (Test-Path $c.Ruta)) { continue }
        foreach ($a in Get-ChildItem $c.Ruta -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "desktop.ini" }) {
            $res.Add([pscustomobject]@{ Nombre = $a.Name; Comando = $a.FullName; Aprob = $c.Aprob; Donde = $c.Donde; Activo = (Test-InicioActivo $c.Aprob $a.Name) })
        }
    }
    return $res
}
function Test-InicioActivo($aprob, $nombre) {
    $v = (Get-ItemProperty -Path $aprob -Name $nombre -ErrorAction SilentlyContinue).$nombre
    if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }   # 02/06 = activo, 03/07 = desactivado
    return $true
}
function Set-ProgramasInicio {
    Titulo "Programas que arrancan con Windows"
    Info "Desactivarlos es lo mismo que hacerlo desde el Administrador de tareas > Inicio."
    Info "El programa sigue instalado y lo puedes abrir cuando quieras; solo deja de arrancar solo."
    Aviso "No desactives el antivirus (p. ej. ESET), el driver de audio/touchpad ni la nube que uses a diario."
    Write-Host ""
    $lista = @(Get-ProgramasInicio)
    if ($lista.Count -eq 0) { Ok "No hay programas de inicio."; Pausa; return }
    for ($i = 0; $i -lt $lista.Count; $i++) {
        $e = if ($lista[$i].Activo) { "ACTIVO     " } else { "desactivado" }
        $col = if ($lista[$i].Activo) { "White" } else { "DarkGray" }
        Write-Host ("   {0,2}. [{1}] {2,-34} {3}" -f ($i + 1), $e, $lista[$i].Nombre, $lista[$i].Donde) -ForegroundColor $col
    }
    Write-Host ""
    Info "Escribe los números para CAMBIAR su estado (activo <-> desactivado)."
    $sel = Leer-Lista (Read-Host "  Números (ej. 2,4,6) o Enter para cancelar") $lista.Count
    if ($sel.Count -eq 0) { return }
    if (-not (Asegurar-PuntoRestauracion)) { return }
    foreach ($n in $sel) {
        $p = $lista[$n - 1]
        $bytes = New-Object byte[] 12
        $bytes[0] = if ($p.Activo) { 3 } else { 2 }
        if ($p.Activo) { [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()).CopyTo($bytes, 4) }
        if (Set-Valor $p.Aprob $p.Nombre "Binary" $bytes) {
            if ($p.Activo) { Ok "Ya no arranca solo: $($p.Nombre)" } else { Ok "Vuelve a arrancar solo: $($p.Nombre)" }
        }
    }
    Info "El cambio se nota en el próximo inicio de sesión."
    Pausa
}

# ---------------------------------------------------------------- 5. Servicios
$script:ListaServicios = @(
    [pscustomobject]@{ Nombre = "DiagTrack";        Texto = "Telemetría de Microsoft (envío de datos de uso)";       Riesgo = "Bajo";  Aviso = "Ninguno para el uso normal." },
    [pscustomobject]@{ Nombre = "dmwappushservice"; Texto = "Mensajes push de telemetría";                           Riesgo = "Bajo";  Aviso = "Ninguno para el uso normal." },
    [pscustomobject]@{ Nombre = "MapsBroker";       Texto = "Descarga de mapas sin conexión";                        Riesgo = "Bajo";  Aviso = "La app Mapas no actualiza mapas offline sola." },
    [pscustomobject]@{ Nombre = "RetailDemo";       Texto = "Modo demostración de tienda";                           Riesgo = "Bajo";  Aviso = "Ninguno." },
    [pscustomobject]@{ Nombre = "Fax";              Texto = "Fax";                                                    Riesgo = "Bajo";  Aviso = "No podrás enviar fax desde Windows." },
    [pscustomobject]@{ Nombre = "WerSvc";           Texto = "Informe de errores de Windows";                         Riesgo = "Bajo";  Aviso = "No se envían informes de fallos a Microsoft." },
    [pscustomobject]@{ Nombre = "PcaSvc";           Texto = "Asistente de compatibilidad de programas";              Riesgo = "Bajo";  Aviso = "No avisa de programas viejos incompatibles." },
    [pscustomobject]@{ Nombre = "XblAuthManager";   Texto = "Xbox Live: inicio de sesión";                           Riesgo = "Bajo";  Aviso = "Si juegas con Xbox/Game Pass en la PC, no lo cambies." },
    [pscustomobject]@{ Nombre = "XblGameSave";      Texto = "Xbox Live: partidas guardadas en la nube";              Riesgo = "Bajo";  Aviso = "Si juegas con Xbox/Game Pass en la PC, no lo cambies." },
    [pscustomobject]@{ Nombre = "XboxNetApiSvc";    Texto = "Xbox Live: red";                                        Riesgo = "Bajo";  Aviso = "Si juegas con Xbox/Game Pass en la PC, no lo cambies." },
    [pscustomobject]@{ Nombre = "XboxGipSvc";       Texto = "Accesorios de Xbox";                                    Riesgo = "Bajo";  Aviso = "Mandos de Xbox pueden tardar en reconocerse." },
    [pscustomobject]@{ Nombre = "SysMain";          Texto = "SysMain (Superfetch): precarga programas en RAM";       Riesgo = "Medio"; Aviso = "Con disco SSD casi no se nota; con disco HDD los programas abren más lento." },
    [pscustomobject]@{ Nombre = "WSearch";          Texto = "Windows Search: índice de búsqueda";                    Riesgo = "Medio"; Aviso = "Buscar archivos y correos de Outlook será más lento." }
)
function Get-InicioServicio($nombre) {
    $c = "HKLM:\SYSTEM\CurrentControlSet\Services\$nombre"
    $p = Get-ItemProperty -Path $c -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    return [pscustomobject]@{ Start = $p.Start; Delayed = $p.DelayedAutostart }
}
function Set-ServicioManual($s) {
    $svc = Get-Service -Name $s.Nombre -ErrorAction SilentlyContinue
    if (-not $svc) { Info "  $($s.Nombre): no existe en este equipo, se omite."; return }
    $actual = Get-InicioServicio $s.Nombre
    if ($actual.Start -ge 3) { Info "  $($s.Nombre): ya estaba en manual o desactivado."; return }
    if (-not ($script:Respaldo.Servicios | Where-Object { $_.Nombre -eq $s.Nombre })) {
        [void]$script:Respaldo.Servicios.Add([pscustomobject]@{ Nombre = $s.Nombre; Start = $actual.Start; Delayed = $actual.Delayed })
        Save-Respaldo
    }
    try {
        try { Set-Service -Name $s.Nombre -StartupType Manual -ErrorAction Stop }
        catch { Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Nombre)" -Name Start -Value 3 -ErrorAction Stop }
        if ($svc.Status -eq "Running") { Stop-Service -Name $s.Nombre -Force -ErrorAction SilentlyContinue }
        Ok "$($s.Texto): en manual (arranca solo si algo lo necesita)."
    } catch {
        Error2 "$($s.Nombre): $($_.Exception.Message)"
    }
}
function Set-Servicios([bool]$soloBajo = $false) {
    if (-not $soloBajo) {
        Titulo "Servicios que no necesitas siempre encendidos"
        Info "Se ponen en MANUAL (no desactivados): si algún programa los necesita, Windows los arranca."
        $ssd = $null
        try { $ssd = @(Get-PhysicalDisk | Where-Object { $_.MediaType -eq "SSD" }).Count -gt 0 } catch { }
        if ($ssd -eq $true) { Info "Tu equipo tiene disco SSD, así que poner SysMain en manual casi no se nota." }
        elseif ($ssd -eq $false) { Aviso "No se detectó SSD: mejor deja SysMain como está." }
        Write-Host ""
        for ($i = 0; $i -lt $script:ListaServicios.Count; $i++) {
            $s = $script:ListaServicios[$i]
            $a = Get-InicioServicio $s.Nombre
            $estado = if (-not $a) { "no existe" } elseif ($a.Start -eq 2) { "automático" } elseif ($a.Start -eq 3) { "manual" } elseif ($a.Start -eq 4) { "desactivado" } else { "sistema" }
            $col = if ($s.Riesgo -eq "Medio") { "Yellow" } else { "White" }
            Write-Host ("   {0,2}. [{1,-5}] {2,-50} ({3})" -f ($i + 1), $s.Riesgo, $s.Texto, $estado) -ForegroundColor $col
            Write-Host ("               Puede afectar: {0}" -f $s.Aviso) -ForegroundColor DarkGray
        }
        Write-Host ""
        $t = Read-Host "  Números a poner en manual, 'b' para todos los de riesgo bajo, o Enter para cancelar"
        if ($t -match '^\s*[bB]\s*$') { $elegidos = @($script:ListaServicios | Where-Object { $_.Riesgo -eq "Bajo" }) }
        else { $elegidos = @(Leer-Lista $t $script:ListaServicios.Count | ForEach-Object { $script:ListaServicios[$_ - 1] }) }
        if ($elegidos.Count -eq 0) { return }
        if (@($elegidos | Where-Object { $_.Riesgo -eq "Medio" }).Count -gt 0) {
            if (-not (Confirmar "Elegiste servicios de riesgo medio. ¿Seguro?")) { return }
        }
    } else {
        $elegidos = @($script:ListaServicios | Where-Object { $_.Riesgo -eq "Bajo" })
    }
    if (-not (Asegurar-PuntoRestauracion)) { return }
    foreach ($s in $elegidos) { Set-ServicioManual $s }
    if (-not $soloBajo) { Pausa }
}

# ---------------------------------------------------------------- 6. Apps en segundo plano
$script:AjustesFondo = @(
    [pscustomobject]@{ Texto = "Apps de la Tienda: no ejecutarse en segundo plano (Windows 10)"; Ruta = "HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications"; Nombre = "GlobalUserDisabled"; Valor = 1 },
    [pscustomobject]@{ Texto = "Apps de la Tienda: no ejecutarse en segundo plano (Windows 10 y 11, política)"; Ruta = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"; Nombre = "LetAppsRunInBackground"; Valor = 2 },
    [pscustomobject]@{ Texto = "Microsoft Edge: sin 'Aumento de inicio' (no se precarga al encender)"; Ruta = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"; Nombre = "StartupBoostEnabled"; Valor = 0 },
    [pscustomobject]@{ Texto = "Microsoft Edge: no seguir abierto al cerrar la ventana"; Ruta = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"; Nombre = "BackgroundModeEnabled"; Valor = 0 },
    [pscustomobject]@{ Texto = "Google Chrome: no seguir abierto al cerrar la ventana"; Ruta = "HKLM:\SOFTWARE\Policies\Google\Chrome"; Nombre = "BackgroundModeEnabled"; Valor = 0 },
    [pscustomobject]@{ Texto = "Widgets / Noticias e intereses: desactivados"; Ruta = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"; Nombre = "AllowNewsAndInterests"; Valor = 0 },
    [pscustomobject]@{ Texto = "Copilot de la barra de tareas: desactivado"; Ruta = "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot"; Nombre = "TurnOffWindowsCopilot"; Valor = 1 },
    [pscustomobject]@{ Texto = "Juegos: sin grabación en segundo plano de Game Bar"; Ruta = "HKCU:\System\GameConfigStore"; Nombre = "GameDVR_Enabled"; Valor = 0 }
)
function Set-AppsFondo([bool]$sinPreguntar = $false) {
    if (-not $sinPreguntar) {
        Titulo "Evitar que apps se queden en segundo plano"
        foreach ($a in $script:AjustesFondo) { Info " - $($a.Texto)" }
        Write-Host ""
        Aviso "Edge y Chrome dirán 'Administrado por tu organización': es normal, es por estas políticas."
        Aviso "Las apps de la Tienda (Correo, Teléfono, etc.) no avisarán hasta que las abras."
        if (-not (Confirmar "¿Aplicar todo?")) { return }
    }
    if (-not (Asegurar-PuntoRestauracion)) { return }
    foreach ($a in $script:AjustesFondo) {
        if (Set-Valor $a.Ruta $a.Nombre "DWord" $a.Valor) { Ok $a.Texto }
    }
    Info "Se nota del todo tras reiniciar o cerrar sesión."
    if (-not $sinPreguntar) { Pausa }
}

# ---------------------------------------------------------------- 7. Memoria virtual
function Set-MemoriaVirtual([bool]$sinPreguntar = $false) {
    if (-not $sinPreguntar) {
        Titulo "Memoria virtual (archivo de paginación)"
        Info "El archivo de paginación es RAM 'extra' en el disco. Quitarlo NO da más RAM: hace que los"
        Info "programas se cierren solos cuando la RAM se llena. Lo recomendado es dejarlo en automático."
        Write-Host ""
    }
    $cs = Get-CimInstance Win32_ComputerSystem
    $config = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
    if ($cs.AutomaticManagedPagefile) {
        Ok "Ya está en automático (lo recomendado). No hace falta cambiar nada."
        if (-not $sinPreguntar) { Pausa }
        return
    }
    $desc = if ($config.Count -eq 0) { "desactivado" } else { ($config | ForEach-Object { "$($_.Name) de $($_.InitialSize) a $($_.MaximumSize) MB" }) -join "; " }
    Aviso "Ahora está en manual: $desc"
    if (-not $sinPreguntar -and -not (Confirmar "¿Ponerlo en automático (administrado por Windows)?")) { return }
    if (-not (Asegurar-PuntoRestauracion)) { return }
    if (-not $script:Respaldo.Paginacion) {
        $script:Respaldo.Paginacion = [pscustomobject]@{ Automatico = $false; Archivos = @($config | ForEach-Object { [pscustomobject]@{ Nombre = $_.Name; Inicial = $_.InitialSize; Maximo = $_.MaximumSize } }) }
        Save-Respaldo
    }
    try {
        Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop
        Ok "Archivo de paginación en automático. Se aplica al reiniciar."
    } catch { Error2 "No se pudo cambiar: $($_.Exception.Message)" }
    if (-not $sinPreguntar) { Pausa }
}

# ---------------------------------------------------------------- 8. Recomendado
function Invoke-Recomendado {
    Titulo "Optimización recomendada (riesgo bajo)"
    Info "Hace, en este orden:"
    Info " - Punto de restauración"
    Info " - Evita que Edge, Chrome, Widgets, Copilot y apps de la Tienda se queden en segundo plano"
    Info " - Pone en manual los servicios de riesgo bajo (telemetría, Xbox, fax, mapas...)"
    Info " - Deja la memoria virtual en automático si no lo estaba"
    Info " - Libera la RAM al final"
    Info "No toca los programas de inicio: esos los eliges tú en la opción 4."
    Aviso "Si juegas con Xbox / Game Pass en esta PC, usa mejor la opción 5 y no marques los de Xbox."
    if (-not (Confirmar "¿Continuar?")) { return }
    if (-not (Asegurar-PuntoRestauracion)) { return }
    Set-AppsFondo $true
    Set-Servicios $true
    Set-MemoriaVirtual $true
    Invoke-LiberarRAM $true
    Write-Host ""
    Ok "Listo. Reinicia la laptop para que todo tenga efecto. Luego revisa la opción 4 (programas de inicio)."
    Pausa
}

# ---------------------------------------------------------------- 9. Revertir
function Invoke-Revertir {
    Titulo "Revertir cambios"
    $r = $script:Respaldo
    $total = $r.Registro.Count + $r.Servicios.Count + [int]([bool]$r.Paginacion)
    if ($total -eq 0) { Ok "No hay cambios guardados para revertir."; Pausa; return }
    Info "Hay $($r.Registro.Count) valores de registro, $($r.Servicios.Count) servicios y $([int][bool]$r.Paginacion) ajuste de memoria virtual guardados."
    Info "Se dejarán exactamente como estaban antes de usar este script."
    Info "(También puedes usar Restaurar sistema y elegir el punto 'Liberar RAM - Optimizador ES'.)"
    if (-not (Confirmar "¿Revertir todo?")) { return }

    $fallos = 0
    foreach ($e in @($r.Registro)) {
        try {
            if ($e.Existia) {
                $v = $e.Valor
                if ($e.Tipo -eq "Binary") { $v = [byte[]]@($v) }
                elseif ($e.Tipo -eq "MultiString") { $v = [string[]]@($v) }
                if (-not (Test-Path $e.Ruta)) { New-Item -Path $e.Ruta -Force | Out-Null }
                New-ItemProperty -Path $e.Ruta -Name $e.Nombre -PropertyType $e.Tipo -Value $v -Force -ErrorAction Stop | Out-Null
            } else {
                Remove-ItemProperty -Path $e.Ruta -Name $e.Nombre -ErrorAction SilentlyContinue
            }
            Log "Revertido registro $($e.Ruta)\$($e.Nombre)"
        } catch { $fallos++; Error2 "$($e.Ruta)\$($e.Nombre): $($_.Exception.Message)" }
    }
    if ($r.Registro.Count) { Ok "Registro restaurado ($($r.Registro.Count) valores)." }

    foreach ($s in @($r.Servicios)) {
        try {
            $c = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Nombre)"
            Set-ItemProperty -Path $c -Name Start -Value ([int]$s.Start) -ErrorAction Stop
            if ($null -ne $s.Delayed) { Set-ItemProperty -Path $c -Name DelayedAutostart -Value ([int]$s.Delayed) -ErrorAction SilentlyContinue }
            if ([int]$s.Start -eq 2) { Start-Service -Name $s.Nombre -ErrorAction SilentlyContinue }
            Ok "Servicio $($s.Nombre) restaurado."
        } catch { $fallos++; Error2 "Servicio $($s.Nombre): $($_.Exception.Message)" }
    }

    if ($r.Paginacion) {
        try {
            $cs = Get-CimInstance Win32_ComputerSystem
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
            Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | Remove-CimInstance -ErrorAction SilentlyContinue
            foreach ($a in @($r.Paginacion.Archivos)) {
                New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = $a.Nombre } -ErrorAction Stop | Out-Null
                Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -eq $a.Nombre } |
                    Set-CimInstance -Property @{ InitialSize = [uint32]$a.Inicial; MaximumSize = [uint32]$a.Maximo } -ErrorAction Stop
            }
            Ok "Memoria virtual restaurada (se aplica al reiniciar)."
        } catch { $fallos++; Error2 "Memoria virtual: $($_.Exception.Message)" }
    }

    if ($fallos -eq 0) {
        Move-Item $script:ArchivoRespaldo (Join-Path $script:Carpeta ("respaldo-revertido-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))) -Force
        $script:Respaldo = Get-Respaldo
        Ok "Todo revertido. Reinicia para que se aplique por completo."
    } else {
        Aviso "Hubo $fallos error(es). El respaldo se conserva para volver a intentarlo."
    }
    Pausa
}

# ---------------------------------------------------------------- Programar limpieza
function Set-AccesoDirecto {
    Titulo "Acceso directo 'Liberar RAM' en el escritorio"
    Info "Crea un icono que libera la RAM con un doble clic (sin abrir el menú)."
    if (-not (Confirmar "¿Crearlo?")) { return }
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $ruta = Join-Path ([Environment]::GetFolderPath("Desktop")) "Liberar RAM.lnk"
        $lnk = $wsh.CreateShortcut($ruta)
        $lnk.TargetPath = "powershell.exe"
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Liberar"
        $lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,-5375"
        $lnk.Description = "Liberar RAM - Optimizador ES"
        $lnk.Save()
        Ok "Creado en el escritorio. No muevas este script de su carpeta o el icono dejará de funcionar."
    } catch { Error2 "No se pudo crear: $($_.Exception.Message)" }
    Pausa
}

# ---------------------------------------------------------------- Inicio
Log "===== Inicio (Liberar=$Liberar)"
if ($Liberar) {
    Titulo "Liberar RAM"
    Invoke-LiberarRAM $true
    Start-Sleep -Seconds 4
    exit
}

while ($true) {
    Clear-Host
    $m = Get-Memoria
    $color = if ($m.Porcentaje -ge 85) { "Red" } elseif ($m.Porcentaje -ge 70) { "Yellow" } else { "Green" }
    Titulo "LIBERAR RAM - Optimizador ES"
    Write-Host ("  RAM: {0} de {1} GB en uso ({2}%)   Libre: {3} GB" -f (GB $m.EnUso), (GB $m.Total), $m.Porcentaje, (GB $m.Disponible)) -ForegroundColor $color
    Write-Host ""
    Write-Host "   1. Ver estado de la memoria y qué la está usando"
    Write-Host "   2. Liberar RAM ahora (vaciar caché y memoria de procesos)"
    Write-Host "   3. Cerrar programas abiertos en segundo plano"
    Write-Host "   4. Elegir qué programas arrancan con Windows"
    Write-Host "   5. Poner en manual servicios que no necesitas"
    Write-Host "   6. Evitar que Edge, Chrome, Widgets y apps se queden en segundo plano"
    Write-Host "   7. Revisar memoria virtual (archivo de paginación)"
    Write-Host "   8. Optimización recomendada (todo lo de riesgo bajo de una vez)" -ForegroundColor Cyan
    Write-Host "   9. Revertir los cambios de este script" -ForegroundColor Yellow
    Write-Host "  10. Crear acceso directo 'Liberar RAM' en el escritorio"
    Write-Host "   0. Salir"
    Write-Host ""
    switch ((Read-Host "  Elige una opción").Trim()) {
        "1"  { Show-Diagnostico }
        "2"  { Invoke-LiberarRAM }
        "3"  { Close-ProgramasFondo }
        "4"  { Set-ProgramasInicio }
        "5"  { Set-Servicios }
        "6"  { Set-AppsFondo }
        "7"  { Set-MemoriaVirtual }
        "8"  { Invoke-Recomendado }
        "9"  { Invoke-Revertir }
        "10" { Set-AccesoDirecto }
        "0"  { Log "===== Fin"; exit }
        default { }
    }
}
