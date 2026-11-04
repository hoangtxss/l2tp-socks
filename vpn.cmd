@echo off
rem Wrapper so vpn.ps1 runs without changing the PowerShell execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn.ps1" %*
if "%~1"=="" pause
