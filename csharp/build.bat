@echo off
setlocal

set "CSHARP_DIR=%~dp0"
set "PROJECT=%CSHARP_DIR%AiModelGlobalizer.csproj"
set "OUTPUT=%CSHARP_DIR%bin\Release\net9.0\win-x64\publish"

echo ==================================================
echo   AI Model Globalizer - Native AOT Build
echo ==================================================
echo.
echo Project : %PROJECT%
echo Output  : %OUTPUT%
echo.

where dotnet >nul 2>nul
if errorlevel 1 (
    echo ERROR: dotnet was not found in PATH.
    echo Install .NET 9 SDK or run this from a terminal where dotnet is available.
    exit /b 1
)

if exist "%OUTPUT%" (
    echo Cleaning old output...
    rmdir /s /q "%OUTPUT%"
)

dotnet publish "%PROJECT%" ^
    -c Release ^
    -f net9.0 ^
    -r win-x64 ^
    --self-contained true ^
    -p:PublishAot=true ^
    -p:StripSymbols=true ^
    -o "%OUTPUT%"

if errorlevel 1 (
    echo.
    echo Build failed.
    exit /b 1
)

echo.
echo Build finished successfully.
echo EXE: %OUTPUT%\AiModelGlobalizer.exe
echo.

for %%F in ("%OUTPUT%\AiModelGlobalizer.exe") do echo Size: %%~zF bytes

endlocal
