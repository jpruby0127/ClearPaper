@echo off
chcp 65001 >nul
setlocal
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "ROOT=%~dp0"

if "%~1"=="" (
  echo.
  echo   ClearPaper / ScanClean  -  exam paper clarifier
  echo.
  echo   Drag one or more PDF files onto this .bat file.
  echo   Or run from a terminal:
  echo       ScanClean.bat your-paper.pdf
  echo.
  pause
  exit /b 1
)

"%ROOT%python\python.exe" "%ROOT%app\scanpdf.py" %*
echo.
pause
