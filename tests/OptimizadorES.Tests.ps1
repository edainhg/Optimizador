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
                       "fixImpresion", "fixTienda", "fixWinget", "fixIconos", "fixHora", "codigoInforme", "codigoBateria", "MotorCodigo") {
            $c = Get-Variable -Name $v -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            if (-not $c) { $malos += "$v (no existe)" } elseif ((Test-Sintaxis $c).Count) { $malos += $v }
        }
        $malos | Should -BeNullOrEmpty
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
