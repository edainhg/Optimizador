# Optimizador ES

Optimizador de Windows en español, con aviso de riesgo en cada opción. Basado en
[WinUtil](https://github.com/ChrisTitusTech/winutil) de Chris Titus Tech (licencia MIT).

## Uso

Doble clic en `Iniciar-Optimizador.bat` y acepta el aviso de administrador. Ver `LEEME.txt`.

O, sin descargar nada a mano, en PowerShell (siempre abre la última versión publicada en `main`):

```powershell
irm https://raw.githubusercontent.com/edainhg/Optimizador/main/instalar.ps1 | iex
```

## Estructura

| Ruta | Qué es |
| --- | --- |
| `OptimizadorES.ps1` | El optimizador (archivo generado: no editar a mano) |
| `LiberarRAM.ps1` | Herramienta de consola para liberar memoria |
| `instalar.ps1` | Lanzador para `irm ... \| iex`: descarga el optimizador y lo abre como administrador |
| `fuente/` | Fuentes: `template.ps1` (interfaz y motor), `es.py` (traducciones y riesgos), `apps.py`, `extras.py`, `gen.py` |
| `tests/` | Pruebas automáticas (Pester 5) |
| `.github/workflows/pruebas.yml` | Ejecuta las pruebas en Windows en cada cambio |

## Regenerar `OptimizadorES.ps1`

```bash
git clone --depth 1 https://github.com/ChrisTitusTech/winutil.git /tmp/winutil
cd fuente
WINUTIL=/tmp/winutil SALIDA=../OptimizadorES.ps1 python3 gen.py
```

## Pruebas

En cada `push` GitHub Actions ejecuta en Windows:

- sintaxis de los scripts y de todos los scripts incrustados;
- carga completa de la interfaz (sin mostrar la ventana, modo `-Prueba`);
- aplicar y deshacer un ajuste, comprobando que vuelve al valor real que había antes.

En local: `Invoke-Pester tests` desde Windows PowerShell 5.1.
