$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (-not (Test-Path $python)) {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3.12 -m venv .venv
    } else {
        & python -m venv .venv
    }
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.12 x64 is required; install from python.org with the launcher.' }
}
& $python -c "import sys,struct; assert sys.version_info >= (3,12) and struct.calcsize('P') == 8, 'Requires Python 3.12+ x64'"
if ($LASTEXITCODE -ne 0) { throw 'Invalid Python installation' }
$requirements = Join-Path $PSScriptRoot 'requirements.txt'
$stamp = Join-Path $PSScriptRoot '.venv\requirements.sha256'
$hash = (Get-FileHash $requirements -Algorithm SHA256).Hash
if (-not (Test-Path $stamp) -or (Get-Content $stamp -Raw).Trim() -ne $hash) {
    & $python -m pip install --only-binary=:all: -r $requirements
    if ($LASTEXITCODE -ne 0) { throw 'Dependency install failed; check Internet access / Python x64 version.' }
    Set-Content $stamp $hash
}
& $python app.py
exit $LASTEXITCODE
