$ErrorActionPreference='Stop'
$engine=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$files=@('Test-Common.ps1','Test-SwitchController.ps1','Test-Install.ps1','Test-Redesign.ps1','Test-EmailPlan.ps1','Test-Lifecycle.ps1','Test-RingSeparators.ps1','Test-CompletionChannel.ps1')
foreach($name in $files){
    & $engine -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $name)
    if($LASTEXITCODE -ne 0){throw ('Test failed: '+$name)}
}
'PASS all offline suites; real account switching and installation were not performed.'
