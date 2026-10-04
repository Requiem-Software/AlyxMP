# Builds the launcher, then the installer (which embeds the launcher and the mod's Lua files),
# and drops the result in dist\AlyxMP-Setup.exe. Needs the .NET SDK (any version that can target net48).
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

dotnet build "$root\src\Launcher\Launcher.csproj" -c Release -o "$root\build\launcher" -nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "launcher build failed" }

dotnet build "$root\src\Installer\Installer.csproj" -c Release -o "$root\build\installer" -nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "installer build failed" }

New-Item -ItemType Directory -Force "$root\dist" | Out-Null
Copy-Item "$root\build\installer\AlyxMP-Setup.exe" "$root\dist\AlyxMP-Setup.exe" -Force
Get-Item "$root\dist\AlyxMP-Setup.exe" | Select-Object Name, Length, LastWriteTime
