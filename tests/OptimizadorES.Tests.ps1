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
        # Debe verse al principio de la pestaña Seguridad
        $script:UI.PanelSeguridad.Children.IndexOf($script:PanelRevision) | Should -BeLessThan 6
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
