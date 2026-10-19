@echo off
rem Double-click to open PC Move (no console window).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0pc-move.ps1"
