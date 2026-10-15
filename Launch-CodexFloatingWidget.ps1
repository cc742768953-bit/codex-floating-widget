$widget = Join-Path $PSScriptRoot 'CodexFloatingWidget.ps1'
Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -ArgumentList @('-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $widget + '"')) `
    -WindowStyle Hidden
