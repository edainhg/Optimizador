# Pruebas automáticas del Optimizador ES (Pester 5, Windows PowerShell 5.1).
# Se ejecutan en GitHub Actions en un equipo Windows limpio (.github/workflows/pruebas.yml).

BeforeAll {
    $script:Raiz = Split-Path -Parent $PSScriptRoot
    $script:Archivo = Join-Path $script:Raiz "OptimizadorES.ps1"
    $script:ArchivoRam = Join-Path $script:Raiz "LiberarRAM.ps1"

    function Test-Sintaxis([string]$Codigo) {
        $tokens = $null; $errores = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($Codigo, [ref]$tokens, [ref]$errores)
        return @($errores)
    }
}

Describe "Sintaxis de los scripts" {
    It "OptimizadorES.ps1 no tiene errores de sintaxis" {
        $errores = Test-Sintaxis (Get-Content -LiteralPath $script:Archivo -Raw -Encoding UTF8)
        ($errores | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) | Should -BeNullOrEmpty
    }
    It "LiberarRAM.ps1 no tiene errores de sintaxis" {
        if (-not (Test-Path $script:ArchivoRam)) { Set-ItResult -Skipped -Because "no está en el repositorio" ; return }
        $errores = Test-Sintaxis (Get-Content -LiteralPath $script:ArchivoRam -Raw -Encoding UTF8)
        ($errores | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) | Should -BeNullOrEmpty
    }
    It "Ninguna variable pisa a las globales compartidas (PowerShell no distingue mayúsculas)" {
        # Con -File el script corre en el ámbito global: '$estado = ...' sustituía a $global:Estado
        # y la ventana se quedaba sin registro, sin barra y sin resumen.
        $codigo = Get-Content -LiteralPath $script:Archivo -Raw -Encoding UTF8
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($codigo, [ref]$null, [ref]$null)
        $globales = "Estado", "ArchivoLog", "Trabajo", "Ajustes", "Ventana", "MotorCodigo"
        $choques = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.Left.VariablePath.IsUnqualified -and
            $globales -contains $n.Left.VariablePath.UserPath
        }, $true) | ForEach-Object { "Línea $($_.Extent.StartLineNumber): $($_.Extent.Text)" }
        $choques | Should -BeNullOrEmpty
    }
    It "Los archivos se guardan con BOM UTF-8 (si no, Windows PowerShell rompe las tildes)" {
        $bytes = [System.IO.File]::ReadAllBytes($script:Archivo)[0..2]
        ($bytes -join ",") | Should -Be "239,187,191"
    }
}

Describe "Carga completa en modo prueba" {
    BeforeAll {
        # Carga datos, motor e interfaz (XAML y todas las pestañas) sin mostrar la ventana
        . $script:Archivo -Prueba
    }

    It "Carga los ajustes y las apps" {
        @($script:Ajustes).Count | Should -BeGreaterThan 50
        @($script:Apps).Count | Should -BeGreaterThan 50
    }

    It "Crea la ventana y sus pestañas" {
        $script:Ventana | Should -Not -BeNullOrEmpty
        $script:UI.Pestanas.Items.Count | Should -BeGreaterOrEqual 8
    }

    It "Cada ajuste tiene nombre, descripción y un nivel de riesgo válido" {
        foreach ($a in $script:Ajustes) {
            $a.Nombre | Should -Not -BeNullOrEmpty
            $a.Descripcion | Should -Not -BeNullOrEmpty
            $a.Riesgo | Should -BeIn @("Bajo", "Medio", "Alto")
        }
    }

    It "Todos los scripts incrustados tienen sintaxis válida" {
        $malos = @()
        foreach ($a in $script:Ajustes) {
            foreach ($c in @($a.InvokeScript) + @($a.UndoScript)) {
                if ($c -and (Test-Sintaxis $c).Count) { $malos += "$($a.Key)" }
            }
        }
        foreach ($f in @($script:Extras.Features)) { if ((Test-Sintaxis $f.Script).Count) { $malos += "FEAT:$($f.Key)" } }
        foreach ($u in "default", "security", "disable") { if ((Test-Sintaxis $script:Extras.Updates.$u).Count) { $malos += "Updates:$u" } }
        foreach ($v in "codigoDefender", "codigoSafetyScanner", "codigoReparar", "codigoArranque", "fixRed", "fixDns", "fixUpdate",
                       "fixImpresion", "fixTienda", "fixWinget", "fixIconos", "fixHora", "codigoInforme", "codigoBateria", "MotorCodigo",
                       "codigoLiberarRam", "codigoPaginacion", "codigoAnalisis",
                       "codigoBuscarDrivers", "codigoCopiaDrivers", "codigoListaDrivers", "codigoRevision") {
            $c = Get-Variable -Name $v -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            if (-not $c) { $malos += "$v (no existe)" } elseif ((Test-Sintaxis $c).Count) { $malos += $v }
        }
        $malos | Should -BeNullOrEmpty
    }

    It "Tiene las pestañas Inicio y RAM y disco" {
        $script:Ventana.FindName("TabInicio") | Should -Not -BeNullOrEmpty
        $script:Ventana.FindName("TabRendimiento") | Should -Not -BeNullOrEmpty
    }

    It "El análisis del equipo encuentra cosas y las muestra en tarjetas" {
        $global:Estado.Analisis = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        $global:Estado.Metricas = [hashtable]::Synchronized(@{})
        & ([scriptblock]::Create($script:codigoAnalisis)) | Out-Null
        @($global:Estado.Analisis).Count | Should -BeGreaterThan 0
        $global:Estado.Metricas.DiscoTxt | Should -Not -BeNullOrEmpty
        { Show-Analisis } | Should -Not -Throw
        $script:PanelHallazgos.Children.Count | Should -BeGreaterThan 0
        $script:IndSalud.Valor.Text | Should -Match "/ 100"
    }

    It "Muestra la RAM en uso y la lista de programas" {
        { Update-IndicadorRam } | Should -Not -Throw
        $script:TxtRamGrande.Text | Should -Match "GB en uso"
        { Update-ListaProcesos } | Should -Not -Throw
    }

    It "Cada ajuste explica en detalle qué cambia" {
        foreach ($a in $script:Ajustes) {
            $d = Get-DetalleTecnico $a
            $d | Should -Not -BeNullOrEmpty -Because $a.Key
        }
    }

    It "Tiene la pestaña Controladores y revisa los dispositivos" {
        $script:Ventana.FindName("TabControladores") | Should -Not -BeNullOrEmpty
        { Update-ListaDispositivos } | Should -Not -Throw
        $script:PanelDispositivos.Children.Count | Should -BeGreaterThan 0
    }

    It "El script para instalar controladores tiene sintaxis válida" {
        (Test-Sintaxis (Get-CodigoInstalarDrivers -Ids @("abc-123", "def-456"))).Count | Should -Be 0
    }

    It "Muestra la lista de controladores encontrados con su botón" {
        $global:Estado.Drivers = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        [void]$global:Estado.Drivers.Add(@{ Id = "x1"; Titulo = "Intel - Display - 31.0"; Clase = "Display"; Fabricante = "Intel"; Fecha = "2026-01-01"; MB = 300 })
        { Show-Drivers } | Should -Not -Throw
        @($script:CasillasDrivers).Count | Should -Be 1
    }

    It "La revisión propia (sin antivirus) se ejecuta y muestra el resultado" {
        $global:Estado.Revision = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        { & ([scriptblock]::Create($script:codigoRevision)) | Out-Null } | Should -Not -Throw
        { Show-Revision } | Should -Not -Throw
        $script:PanelRevision.Children.Count | Should -BeGreaterThan 0
        # Debe ser la primera sección de la pestaña Seguridad
        $primera = @($script:UI.PanelSeguridad.Children | Where-Object { $_.Uid -eq "Seccion" })[0]
        $primera.Tag | Should -Be "Revisión propia (sin antivirus)"
        $primera.IsExpanded | Should -BeTrue
    }

    It "La revisión detecta un comando de minado" {
        $global:Estado.Revision = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        $falso = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-Command", "Start-Sleep 60 # stratum+tcp://pool.supportxmr.com:3333 --donate-level 1" -PassThru -WindowStyle Hidden
        try {
            Start-Sleep -Seconds 2
            & ([scriptblock]::Create($script:codigoRevision)) | Out-Null
            @($global:Estado.Revision | Where-Object { $_.Nivel -eq "Alto" -and $_.Pid -eq $falso.Id }).Count | Should -BeGreaterThan 0
        } finally { Stop-Process -Id $falso.Id -Force -ErrorAction SilentlyContinue }
    }

    It "La revisión muestra la ruta del script oculto para poder abrirlo" {
        $global:Estado.Revision = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        $archivo = Join-Path $TestDrive "Sin título1.ps1"
        Set-Content -LiteralPath $archivo -Value "Start-Sleep 60" -Encoding UTF8
        $oculto = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$archivo`"" -PassThru
        try {
            Start-Sleep -Seconds 2
            & ([scriptblock]::Create($script:codigoRevision)) | Out-Null
            $h = @($global:Estado.Revision | Where-Object { $_.Pid -eq $oculto.Id })[0]
            $h | Should -Not -BeNullOrEmpty
            $h.Ruta | Should -Be $archivo
            { Show-Revision } | Should -Not -Throw
        } finally { Stop-Process -Id $oculto.Id -Force -ErrorAction SilentlyContinue }
    }

    It "Las pestañas largas están en secciones plegables y solo las principales abiertas" {
        $secciones = @($script:UI.PanelAjustes.Children | Where-Object { $_.Uid -eq "Seccion" })
        $secciones.Count | Should -BeGreaterOrEqual 2
        @($secciones | Where-Object { $_.IsExpanded }).Count | Should -Be 1
        @($script:UI.PanelRendimiento.Children | Where-Object { $_.Uid -eq "Seccion" }).Count | Should -BeGreaterOrEqual 3
    }

    It "El menú lateral está agrupado y los grupos no se pueden seleccionar" {
        $grupos = @($script:UI.Pestanas.Items | Where-Object { -not $_.Name })
        $grupos.Count | Should -BeGreaterOrEqual 3
        foreach ($g in $grupos) { $g.IsEnabled | Should -BeFalse }
        $script:UI.Pestanas.SelectedItem.Name | Should -Be "TabInicio"
    }

    It "El buscador de Ajustes filtra las opciones" {
        $script:TxtBuscarAjuste.Text = "zzzz-no-existe"
        @($script:CasillasAjustes | Where-Object { $script:InfoAjuste[$_.Tag.Key].Borde.Visibility -eq "Visible" }).Count | Should -Be 0
        $script:TxtBuscarAjuste.Text = ""
        @($script:CasillasAjustes | Where-Object { $script:InfoAjuste[$_.Tag.Key].Borde.Visibility -eq "Visible" }).Count | Should -BeGreaterThan 0
    }

    It "Los IDs de apps no se repiten" {
        $dup = $script:Apps | Group-Object Id | Where-Object Count -gt 1
        $dup | Should -BeNullOrEmpty
    }
}

Describe "Aplicar y deshacer restaura el valor real" {
    BeforeAll {
        . $script:Archivo -Prueba
        $script:Item = $script:Ajustes | Where-Object Key -eq "WPFTweaksEndTaskOnTaskbar"
        $script:Reg = @($script:Item.registry)[0]
        # Respaldo aislado para no tocar el del usuario
        $env:LOCALAPPDATA = Join-Path $TestDrive "LocalAppData"
        New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA | Out-Null
    }

    It "Vuelve al valor personalizado que había antes (no al de fábrica)" {
        if (-not (Test-Path $script:Reg.Path)) { New-Item -Path $script:Reg.Path -Force | Out-Null }
        # Valor previo inventado, distinto del de fábrica, para comprobar que se restaura exacto
        Set-ItemProperty -Path $script:Reg.Path -Name $script:Reg.Name -Type DWord -Value 7

        Invoke-Ajuste -Item $script:Item -Deshacer $false | Should -BeTrue
        (Get-ItemProperty -Path $script:Reg.Path).($script:Reg.Name) | Should -Be ([int]$script:Reg.Value)

        Invoke-Ajuste -Item $script:Item -Deshacer $true | Should -BeTrue
        (Get-ItemProperty -Path $script:Reg.Path).($script:Reg.Name) | Should -Be 7
    }

    It "Si el valor no existía, al deshacer lo vuelve a quitar" {
        Remove-ItemProperty -Path $script:Reg.Path -Name $script:Reg.Name -ErrorAction SilentlyContinue
        Invoke-Ajuste -Item $script:Item -Deshacer $false | Should -BeTrue
        Invoke-Ajuste -Item $script:Item -Deshacer $true | Should -BeTrue
        (Get-ItemProperty -Path $script:Reg.Path -ErrorAction SilentlyContinue).($script:Reg.Name) | Should -BeNullOrEmpty
    }

    It "El respaldo se borra después de deshacer" {
        (Read-Respaldo).ContainsKey("WPFTweaksEndTaskOnTaskbar") | Should -BeFalse
    }

    It "Detecta el ajuste como aplicado y luego como no aplicado" {
        Invoke-Ajuste -Item $script:Item -Deshacer $false | Out-Null
        Test-AjusteAplicado $script:Item | Should -BeTrue
        Invoke-Ajuste -Item $script:Item -Deshacer $true | Out-Null
        Test-AjusteAplicado $script:Item | Should -BeFalse
    }
}

Describe "Mejoras: perfiles, privacidad, arranque, programas, limpieza, prioridad, discos, historial y tema" {
    BeforeAll {
        # Datos aislados (historial, respaldos, preferencias) para no tocar los del equipo
        $env:LOCALAPPDATA = Join-Path $TestDrive "LocalAppDataMejoras"
        New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA | Out-Null
        . $script:Archivo -Prueba
        $script:PatronGuid = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    }

    It "Tiene las pestañas nuevas" {
        foreach ($t in "TabPerfiles", "TabPrivacidad", "TabArranque", "TabProgramas", "TabHistorial") {
            $script:Ventana.FindName($t) | Should -Not -BeNullOrEmpty -Because $t
        }
    }

    It "Los scripts nuevos y el lanzador tienen sintaxis válida" {
        $malos = @()
        foreach ($v in "codigoEnergiaAlta", "codigoEnergiaVolver", "codigoVigilancia", "codigoVigilanciaDeshacer", "codigoListaArranque",
                       "codigoBuscarActualizaciones", "codigoDesinstalar", "codigoBorrarRestos", "codigoLimpieza", "codigoDiscos") {
            $c = Get-Variable -Name $v -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            if (-not $c) { $malos += "$v (no existe)" } elseif ((Test-Sintaxis $c).Count) { $malos += $v }
        }
        $malos | Should -BeNullOrEmpty
        (Test-Sintaxis (Get-Content -LiteralPath (Join-Path $script:Raiz "instalar.ps1") -Raw)).Count | Should -Be 0
    }

    It "Cada perfil usa ajustes que existen" {
        foreach ($p in $script:PerfilesDef) {
            foreach ($k in @(& $p.Claves)) { Get-ItemPorClave $k | Should -Not -BeNullOrEmpty -Because "$($p.Clave): $k" }
        }
        { Invoke-ComprobacionExtra "TabPerfiles" } | Should -Not -Throw
        $script:TarjetasPerfil["Vigilancia"].Estado.Text | Should -Not -BeNullOrEmpty
    }

    It "El plan de energía Alto rendimiento se aplica y se deshace" {
        $it = Get-ItemPorClave "OPT_ENERGIA_ALTA"
        $antes = [regex]::Match((powercfg /getactivescheme | Out-String), $script:PatronGuid).Value
        Invoke-Ajuste -Item $it -Deshacer $false | Should -BeTrue
        Test-ItemAplicado $it | Should -BeTrue
        Invoke-Ajuste -Item $it -Deshacer $true | Should -BeTrue
        Test-ItemAplicado $it | Should -BeFalse
        [regex]::Match((powercfg /getactivescheme | Out-String), $script:PatronGuid).Value | Should -Be $antes
    }

    It "El perfil de videovigilancia se aplica y se deshace" {
        $it = Get-ItemVigilancia
        (Test-Sintaxis (@($it.InvokeScript) -join "`n")).Count | Should -Be 0
        Invoke-Ajuste -Item $it -Deshacer $false | Should -BeTrue
        Test-ItemAplicado $it | Should -BeTrue
        Invoke-Ajuste -Item $it -Deshacer $true | Should -BeTrue
        Test-ItemAplicado $it | Should -BeFalse
        Test-Path (Join-Path $env:LOCALAPPDATA "OptimizadorES\respaldo-vigilancia.json") | Should -BeFalse
    }

    It "Privacidad: aplica y deshace exacto" {
        @($script:CasillasPriv).Count | Should -Be @($script:ItemsPrivacidad).Count
        $it = Get-ItemPorClave "PRIV_IDIOMAS"
        Invoke-Ajuste -Item $it -Deshacer $false | Should -BeTrue
        Test-AjusteAplicado $it | Should -BeTrue
        Invoke-Ajuste -Item $it -Deshacer $true | Should -BeTrue
        Test-AjusteAplicado $it | Should -BeFalse
        { Update-VistaPrivacidad } | Should -Not -Throw
    }

    It "Arranque: lista los programas y los desactiva/activa como el Administrador de tareas" {
        $run = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        $aprob = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
        New-ItemProperty -Path $run -Name "OptESPrueba" -Value "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile" -PropertyType String -Force | Out-Null
        try {
            $global:Estado.Arranque = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
            & ([scriptblock]::Create($script:codigoListaArranque)) | Out-Null
            $e = @($global:Estado.Arranque | Where-Object { $_.Nombre -eq "OptESPrueba" })[0]
            $e | Should -Not -BeNullOrEmpty
            $e.Activo | Should -BeTrue
            $e.Firma | Should -BeIn @("Valida", "SinFirma", "NoValida")
            { Show-Arranque } | Should -Not -Throw
            Set-EntradaArranque $e $false | Should -BeTrue
            (Get-ItemProperty -Path $aprob -Name OptESPrueba).OptESPrueba[0] | Should -Be 3
            Set-EntradaArranque $e $true | Should -BeTrue
            (Get-ItemProperty -Path $aprob -Name OptESPrueba).OptESPrueba[0] | Should -Be 2
            @(Read-Historial | Where-Object { $_.Tipo -eq "Arranque" }).Count | Should -Be 2
        } finally {
            Remove-ItemProperty -Path $run -Name OptESPrueba -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $aprob -Name OptESPrueba -ErrorAction SilentlyContinue
        }
    }

    It "Lee la tabla de winget en español y en inglés" {
        $f = "{0,-23}{1,-25}{2,-13}{3,-13}{4}"
        $es = @(
            ($f -f "Nombre", "Id", "Versión", "Disponible", "Origen"),
            ("-" * 80),
            ($f -f "Google Chrome", "Google.Chrome", "120.0.1", "121.0.2", "winget"),
            ($f -f "7-Zip 23.01 (x64)", "7zip.7zip", "23.01", "24.08", "winget"),
            ($f -f "Programa muy largo…", "Vendor.Muy.Larg…", "1.0", "2.0", "winget"),
            "2 actualizaciones disponibles."
        ) -join "`r`n"
        $r = ConvertFrom-TablaWinget -Texto $es
        $r.Count | Should -Be 2
        $r[0].Id | Should -Be "Google.Chrome"
        $r[1].Disponible | Should -Be "24.08"
        $en = "`r   -`r   \`r" + (@(
            ($f -f "Name", "Id", "Version", "Available", "Source"),
            ("-" * 80),
            ($f -f "Notepad++", "Notepad++.Notepad++", "8.5", "8.6.2", "winget")
        ) -join "`n")
        $r2 = ConvertFrom-TablaWinget -Texto $en
        $r2.Count | Should -Be 1
        $r2[0].Id | Should -Be "Notepad++.Notepad++"
        (ConvertFrom-TablaWinget -Texto "No se encontró ninguna actualización disponible.").Count | Should -Be 0
    }

    It "Muestra los programas con actualización con su casilla" {
        $global:Estado.Actualizables = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        [void]$global:Estado.Actualizables.Add(@{ Id = "Google.Chrome"; Nombre = "Google Chrome"; Version = "1"; Disponible = "2"; Origen = "winget" })
        { Show-Actualizables } | Should -Not -Throw
        @($script:CasillasActualizables).Count | Should -Be 1
    }

    It "Encuentra restos de un programa y no confunde carpetas del sistema" {
        $carpeta = Join-Path $env:LOCALAPPDATA "OptES Prueba App"
        New-Item -ItemType Directory -Force -Path $carpeta | Out-Null
        Set-Content -LiteralPath (Join-Path $carpeta "a.txt") -Value "x"
        New-Item -Path "HKCU:\Software\OptES Prueba App" -Force | Out-Null
        try {
            $r = Find-Restos -Nombre "OptES Prueba App 1.2.3 (x64)" -Editor "OptES Corp, Inc."
            @($r | Where-Object { $_.Ruta -eq $carpeta }).Count | Should -Be 1
            @($r | Where-Object { $_.Tipo -eq "Registro" }).Count | Should -Be 1
            (Find-Restos -Nombre "Microsoft").Count | Should -Be 0
            (Find-Restos -Nombre "Intel 1.0").Count | Should -Be 0
        } finally { Remove-Item -Path "HKCU:\Software\OptES Prueba App" -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "Lista los programas instalados" {
        @(Get-ProgramasInstalados).Count | Should -BeGreaterThan 0
        { Show-Instalados } | Should -Not -Throw
        $script:PanelInstalados.Children.Count | Should -BeGreaterThan 1
    }

    It "Mide el espacio que se puede limpiar" {
        $global:Estado.Limpieza = [hashtable]::Synchronized(@{})
        $codigo = "`$Modo = 'Medir'`n`$Claves = @('TempUsuario', 'Registros', 'Papelera', 'Componentes')`n" + $script:codigoLimpieza
        & ([scriptblock]::Create($codigo)) | Out-Null
        $global:Estado.Limpieza.ContainsKey("TempUsuario") | Should -BeTrue
        $global:Estado.Limpieza["Componentes"] | Should -Be -1
        { Show-Limpieza } | Should -Not -Throw
        $script:TxtTotalLimpieza.Text | Should -Match "GB"
    }

    It "Revisa la salud de los discos" {
        $global:Estado.Discos = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        $global:Estado.Bateria = $null
        $global:Estado.AvisoSmart = $false
        & ([scriptblock]::Create($script:codigoDiscos)) | Out-Null
        { Show-SaludDiscos } | Should -Not -Throw
        $script:PanelDiscos.Children.Count | Should -BeGreaterThan 0
    }

    It "Añade y quita una regla de prioridad" {
        Set-ReglaPrioridad "optesprueba.exe" 6
        (Get-ReglasPrioridad | Where-Object Exe -eq "optesprueba.exe").Valor | Should -Be 6
        { Show-ReglasPrioridad } | Should -Not -Throw
        Remove-ReglaPrioridad "optesprueba.exe"
        @(Get-ReglasPrioridad | Where-Object Exe -eq "optesprueba.exe").Count | Should -Be 0
        Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\optesprueba.exe" | Should -BeFalse
        { Set-ReglaPrioridad "mal\nombre" 3 } | Should -Throw
    }

    It "El historial muestra los cambios" {
        @(Read-Historial).Count | Should -BeGreaterThan 0
        { Show-Historial } | Should -Not -Throw
        $script:PanelHistorial.Children.Count | Should -BeGreaterThan 1
    }

    It "El modo oscuro cambia los colores y la ventana carga igual" {
        $oscuro = Convert-ColoresOscuro $xaml
        $oscuro | Should -Not -Match '"#FFFFFF"'
        $oscuro | Should -Match '#1E293B'
        $v = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$oscuro)))
        $v | Should -Not -BeNullOrEmpty
        $v.Close()
    }
}
