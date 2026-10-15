$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')
$script:Checks=0
function Assert($value,$message){if(-not $value){throw "FAIL: $message"};$script:Checks++}
function Get-AppxPackage {param($Name,$ErrorAction) [pscustomobject]@{PackageFamilyName='OpenAI.Codex_test'}}
$temp=Join-Path $env:TEMP ('codex-widget-tests-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
try {
    $path=Join-Path $temp 'config.json'
    $c=Get-WidgetConfiguration -StateDirectory $temp
    Assert ($c.ApiPort -eq 3210 -and $c.CodexAppId -eq 'OpenAI.Codex_test!App') 'portable defaults and installed app discovery'
    Assert ($c.ConfigPath -eq $path -and $c.StateDirectory -eq $temp) 'isolated per-user state'
    '{"ApiPort":43210,"StartupTaskName":"Codex Floating Widget Public Demo"}'|Set-Content -LiteralPath $path
    $c=Get-WidgetConfiguration -StateDirectory $temp
    Assert ($c.ApiPort -eq 43210 -and $c.StartupTaskName.EndsWith('Demo')) 'configured local port and task'
    foreach($invalid in @('{"ApiPort":0}','{"ApiPort":65536}','{"ApiPort":3.5}','{"SwitcherExecutable":"relative.exe"}','{"CodexExecutable":"C:\\Apps\\app.cmd"}','{"StartupTaskName":"Codex Floating Widget Auto Start"}','{"Unknown":true}','null','[]','"string"','true','123','{bad json}')) {
        $invalid|Set-Content -LiteralPath $path
        $failed=$false;try{Get-WidgetConfiguration -StateDirectory $temp|Out-Null}catch{$failed=$true}
        Assert $failed ('invalid configuration rejected before side effects: '+$invalid)
    }
    function Get-CimInstance {
        param($ClassName,$ErrorAction)
        @(
          [pscustomobject]@{ProcessId=10;ParentProcessId=1;ExecutablePath='C:\Program Files\WindowsApps\OpenAI.Codex_1_x64__test\app\ChatGPT.exe'},
          [pscustomobject]@{ProcessId=11;ParentProcessId=10;ExecutablePath='C:\Apps\Codex\codex.exe'},
          [pscustomobject]@{ProcessId=12;ParentProcessId=11;ExecutablePath='C:\Apps\Codex\service.exe'},
          [pscustomobject]@{ProcessId=20;ParentProcessId=1;ExecutablePath='C:\Apps\Codex\codex.exe'},
          [pscustomobject]@{ProcessId=21;ParentProcessId=1;ExecutablePath='C:\Apps\ChatGPT\ChatGPT.exe'},
          [pscustomobject]@{ProcessId=30;ParentProcessId=1;ExecutablePath='D:\Custom\Codex.exe'}
        )
    }
    $ids=@(Get-WidgetCodexProcesses -Configuration ([pscustomobject]@{CodexExecutable=''})|ForEach-Object ProcessId)
    Assert (($ids -join ',') -eq '10,11,12') 'only Codex desktop and its descendants selected'
    $ids=@(Get-WidgetCodexProcesses -Configuration ([pscustomobject]@{CodexExecutable='D:\Custom\Codex.exe'})|ForEach-Object ProcessId)
    Assert ($ids -contains 30 -and $ids -notcontains 20 -and $ids -notcontains 21) 'configured executable supported without matching unrelated CLI or ChatGPT'
    function Get-Process {param($Id,$ErrorAction) [pscustomobject]@{MainWindowHandle=$(if($Id -eq 10){123}else{0})}}
    Assert (Test-WidgetCodexVisible -Configuration ([pscustomobject]@{CodexExecutable=''})) 'visible desktop handle recognized'
    "PASS $script:Checks configuration and process-scope checks (all process inputs mocked)"
} finally {
    # Only remove explicitly named files made in this unique test directory.
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
    Remove-Item -LiteralPath $temp
}
