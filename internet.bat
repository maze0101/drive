@echo off
rem Интернэтээр хаанаас ч нэвтрэх холбоос гаргана (Cloudflare Tunnel)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -Tunnel %*
pause
