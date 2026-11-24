@echo off
rem Abre "Liberar RAM" (pide permisos de administrador)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LiberarRAM.ps1"
