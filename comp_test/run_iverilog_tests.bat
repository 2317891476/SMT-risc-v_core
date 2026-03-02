@echo off
setlocal
powershell -ExecutionPolicy Bypass -File "%~dp0run_iverilog_tests.ps1" %*
endlocal
