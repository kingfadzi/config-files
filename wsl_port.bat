@echo off
setlocal enabledelayedexpansion

REM Check for the correct number of parameters
if "%~3"=="" (
    echo Usage: %~nx0 ^<DistroName^> ^<ExportPath.tar^> ^<ImportPath^>
    echo.
    echo Example: %~nx0 Ubuntu-22.04 C:\Backups\wsl_clean.tar C:\WSL\Ubuntu-22.04
    exit /b 1
)

set DISTRO=%1
set EXPORT_PATH=%2
set IMPORT_PATH=%3

echo Exporting %DISTRO% to %EXPORT_PATH%...
wsl.exe --export %DISTRO% %EXPORT_PATH%
if errorlevel 1 (
    echo Error exporting %DISTRO%. Exiting.
    pause
    exit /b 1
)

echo Unregistering %DISTRO%...
wsl.exe --unregister %DISTRO%
if errorlevel 1 (
    echo Error unregistering %DISTRO%. Exiting.
    pause
    exit /b 1
)

echo Importing %DISTRO% from %EXPORT_PATH% to %IMPORT_PATH%...
wsl.exe --import %DISTRO% %IMPORT_PATH% %EXPORT_PATH%
if errorlevel 1 (
    echo Error importing %DISTRO%. Exiting.
    pause
    exit /b 1
)

echo.
echo Operation complete! Your WSL distro has been re-imported.
pause