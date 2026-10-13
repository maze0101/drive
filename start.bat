@echo off
rem Сонголтууд: start.bat -Lan  (сүлжээнээс хандах),  start.bat -Lan -Https  (HTTPS, Администратор эрх хэрэгтэй)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" %*
pause
