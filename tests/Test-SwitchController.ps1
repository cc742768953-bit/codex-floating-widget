# All external effects are replaced before executing the controller scenarios.
$ErrorActionPreference = 'Stop'
$releaseRoot = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $releaseRoot 'Switch-CodexAccount.ps1'))
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Controller parse failed.' }
$script:FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('widget-controller-test-' + [guid]::NewGuid().ToString('N'))
$script:FixtureReleaseRoot = Join-Path $script:FixtureRoot 'release [sample]'
$script:FixtureState = Join-Path $script:FixtureRoot 'state'
[IO.Directory]::CreateDirectory($script:FixtureReleaseRoot) | Out-Null
[IO.Directory]::CreateDirectory($script:FixtureState) | Out-Null
$replacements = @{
    'Write-Log' = 'function Write-Log { param($Message) $script:Messages.Add($Message) }'
    'Ensure-SwitcherApi' = 'function Ensure-SwitcherApi { $script:ObservedPort=$ApiPort; if($script:FailHealth){throw ''sensitive-response-value''} }'
    'Stop-Codex' = 'function Stop-Codex { $script:CodexStopAttempted=$true; $script:Stops++; $script:CodexAlive=$false; if($script:SimulateWidgetLoss){$script:WidgetAlive=$false}; $script:Events.Add(''stop'') }'
    'Start-Codex' = 'function Start-Codex { $script:Starts++; if($script:FailStart){throw ''simulated start failure''}; $script:CodexAlive=$true; $script:Events.Add(''start'') }'
    'Invoke-SwitcherApi' = @'
function Invoke-SwitcherApi { param($Command,$Body=@{})
    switch($Command) {
        'list_accounts' { return $script:FixtureAccounts }
        'get_active_account_info' { return $script:FixtureActive }
        'switch_account' {
            $script:Events.Add('switch')
            if($script:FailSwitch){throw 'sensitive-response-value'}
            $script:SwitchedTo=$Body.accountId
            if(-not $script:FailVerification){$script:FixtureActive=@($script:FixtureAccounts | Where-Object id -eq $Body.accountId)[0]}
        }
    }
}
'@
}
$functions = $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $replacements.ContainsKey($node.Name)}, $true) | Sort-Object {$_.Extent.StartOffset} -Descending
foreach ($function in $functions) {
    $source = $source.Substring(0, $function.Extent.StartOffset) + $replacements[$function.Name] + $source.Substring($function.Extent.EndOffset)
}
$source = $source.Replace(". (Join-Path `$PSScriptRoot 'Common.ps1')", '')
$source = $source.Replace('$PSScriptRoot', '$script:FixtureReleaseRoot').Replace('exit 0', "return 'OK'").Replace('exit 1', "return 'FAIL'")
Invoke-Expression ('function Invoke-TestController {' + $source + '}')

function Get-WidgetConfiguration {
    param($ConfigPath)
    $script:ObservedConfigPath = $ConfigPath
    [pscustomobject]@{ ApiPort=4321; StateDirectory=$script:FixtureState; StartupTaskName='Codex Floating Widget Public'; SwitcherExecutable=''; CodexExecutable=''; CodexAppId=$script:FixtureAppId }
}
function Get-ScheduledTask {
    param($TaskName,$ErrorAction)
    if($script:MissingTask){throw 'Missing test task'}
    $taskRoot = if($script:ForeignTask){Join-Path $script:FixtureRoot 'other'}else{$script:FixtureReleaseRoot}
    [pscustomobject]@{TaskName=$TaskName;Actions=@([pscustomobject]@{Arguments=('-File "' + (Join-Path $taskRoot 'CodexFloatingWidget.ps1') + '"')})}
}
function Start-ScheduledTask {
    param($TaskName)
    if($TaskName -ne 'Codex Floating Widget Public'){throw 'Wrong task'}
    $script:ScheduledStarts++; $script:WidgetAlive=$true; $script:Events.Add('restore')
}
function Start-Sleep {param($Milliseconds)}
function Get-CimInstance {
    param($ClassName,$Filter)
    if($script:WidgetAlive) {
        $path = if($script:ForeignWidget){Join-Path $script:FixtureRoot 'other\CodexFloatingWidget.ps1'}else{Join-Path $script:FixtureReleaseRoot 'CodexFloatingWidget.ps1'}
        [pscustomobject]@{CommandLine=('powershell.exe -File "' + $path + '"')}
        $script:ForeignWidget = $false
    }
}
function Test-WidgetCodexVisible {return $script:CodexAlive}
function Setup {
    $script:FixtureAccounts=@([pscustomobject]@{id='test-a';name='duplicate'},[pscustomobject]@{id='test-b';name='duplicate'},[pscustomobject]@{id='test-c';name='sensitive-account-name'})
    $script:FixtureActive=$script:FixtureAccounts[0]
    $script:Messages=[Collections.Generic.List[string]]::new(); $script:Events=[Collections.Generic.List[string]]::new()
    $script:SwitchedTo=''; $script:Stops=0; $script:Starts=0; $script:ScheduledStarts=0
    $script:CodexAlive=$true; $script:WidgetAlive=$true; $script:SimulateWidgetLoss=$true
    $script:FailSwitch=$false; $script:FailHealth=$false; $script:FailVerification=$false; $script:FailStart=$false
    $script:MissingTask=$false; $script:ForeignTask=$false; $script:ForeignWidget=$false; $script:FixtureAppId='Fixture.Codex!App'
    $script:ObservedPort=0; $script:ObservedConfigPath=''
}
$script:Assertions = 0
function Assert($Value,$Message) {if(-not $Value){throw "FAIL: $Message"}; $script:Assertions++}
try {
    Setup; $result=Invoke-TestController -AccountId 'test-b' -NoLaunch
    Assert ($result -eq 'OK' -and $script:SwitchedTo -eq 'test-b' -and $script:Stops -eq 1) 'ID chooses the intended duplicate-name account'
    Assert ($script:ObservedPort -eq 4321) 'configured API port is used'
    Setup; $result=Invoke-TestController -AccountName 'sensitive-account-name' -NoLaunch -ConfigPath 'fixture-config.json' -ApiPort 5432
    Assert ($result -eq 'OK' -and $script:SwitchedTo -eq 'test-c') 'unique name compatibility'
    Assert ($script:ObservedConfigPath -eq 'fixture-config.json' -and $script:ObservedPort -eq 5432) 'explicit configuration and API port propagate'
    Assert (($script:Messages -join ' ') -notmatch 'sensitive-account-name|test-c') 'logs omit account names and identifiers'
    Setup; $result=Invoke-TestController -AccountName 'duplicate' -NoLaunch
    Assert ($result -eq 'FAIL' -and $script:Stops -eq 0) 'ambiguous name rejected before stopping Codex'
    Setup; $result=Invoke-TestController -AccountId 'missing' -NoLaunch
    Assert ($result -eq 'FAIL' -and $script:Stops -eq 0) 'unknown identifier rejected before stopping Codex'
    Setup; $result=Invoke-TestController -NoLaunch
    Assert ($result -eq 'FAIL' -and $script:Stops -eq 0) 'missing selection rejected before stopping Codex'
    Setup; $result=Invoke-TestController -AccountId 'test-a' -NoLaunch
    Assert ($result -eq 'OK' -and $script:Stops -eq 0) 'already-active account completes without restart'
    Setup; $result=Invoke-TestController -AccountId 'test-b' -RestoreWidget
    Assert ($result -eq 'OK' -and ($script:Events -join ',') -eq 'stop,switch,start,restore') 'successful switch restores lost widget in order'
    Setup; $script:SimulateWidgetLoss=$false; $result=Invoke-TestController -AccountId 'test-b' -RestoreWidget
    Assert ($result -eq 'OK' -and $script:ScheduledStarts -eq 0) 'surviving widget is not duplicated'
    Setup; $script:WidgetAlive=$false; $result=Invoke-TestController -AccountId 'test-a' -RestoreWidget
    Assert ($result -eq 'OK' -and $script:Stops -eq 0 -and $script:ScheduledStarts -eq 1) 'already-active account restores missing widget'
    Setup; $result=Invoke-TestController -AccountId 'test-b' -RestoreWidget -NoLaunch
    Assert ($result -eq 'OK' -and $script:Starts -eq 0 -and -not $script:CodexAlive -and $script:WidgetAlive) 'NoLaunch respected during widget restoration'
    Setup; $script:FailSwitch=$true; $result=Invoke-TestController -AccountId 'test-b' -RestoreWidget
    Assert ($result -eq 'FAIL' -and $script:Starts -eq 1 -and $script:WidgetAlive) 'failed switch recovers both apps'
    Assert (($script:Messages -join ' ') -notmatch 'sensitive-response-value') 'raw API failure details never reach logs'
    Setup; $script:FailSwitch=$true; $result=Invoke-TestController -AccountId 'test-b'
    Assert ($result -eq 'FAIL' -and $script:Starts -eq 1) 'failed switch recovers Codex without RestoreWidget'
    Setup; $script:FailVerification=$true; $result=Invoke-TestController -AccountId 'test-b'
    Assert ($result -eq 'FAIL' -and $script:Starts -eq 1) 'verification mismatch fails and recovers Codex'
    Setup; $script:MissingTask=$true; $result=Invoke-TestController -AccountId 'test-b' -RestoreWidget
    Assert ($result -eq 'FAIL' -and $script:Stops -eq 0) 'missing task fails before stopping Codex'
    Setup; $script:ForeignTask=$true; $script:WidgetAlive=$false; $result=Invoke-TestController -AccountId 'test-b' -RestoreWidget
    Assert ($result -eq 'FAIL' -and $script:Stops -eq 0 -and $script:ScheduledStarts -eq 0) 'foreign task is never launched during failure recovery'
    Setup; $script:FixtureAppId=''; $result=Invoke-TestController -AccountId 'test-b'
    Assert ($result -eq 'FAIL' -and $script:Stops -eq 0) 'missing Codex launch configuration fails before stopping Codex'
    Setup; $script:SimulateWidgetLoss=$false; $script:ForeignWidget=$true; $result=Invoke-TestController -AccountId 'test-a' -RestoreWidget
    Assert ($result -eq 'OK' -and $script:ScheduledStarts -eq 1) 'another release process does not count as this widget'
    Setup; $resultPath=Join-Path $script:FixtureState 'result.json'; $requestId='a' * 32
    $result=Invoke-TestController -AccountId 'test-b' -NoLaunch -ResultPath $resultPath -RequestId $requestId
    $completion=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json
    Assert ($result -eq 'OK' -and $completion.request_id -eq $requestId -and $completion.target_id -eq 'test-b' -and $completion.success -eq $true) 'completion handshake carries the requested account and request ID'
    Assert (@(Get-ChildItem -LiteralPath $script:FixtureState -Filter '*.tmp').Count -eq 0) 'atomic completion leaves no temporary file'
    Setup; $script:FailSwitch=$true; $result=Invoke-TestController -AccountId 'test-b' -NoLaunch -ResultPath $resultPath -RequestId $requestId
    $completion=[IO.File]::ReadAllText($resultPath)|ConvertFrom-Json
    Assert ($result -eq 'FAIL' -and $completion.success -eq $false -and $script:Starts -eq 0) 'failure result and NoLaunch remain consistent'
    Setup; $result=Invoke-TestController -AccountId 'test-b' -NoLaunch -ResultPath $resultPath -RequestId '../invalid'
    Assert ($result -eq 'FAIL' -and $script:Stops -eq 0) 'malformed request rejected before stopping Codex'
    "PASS: $script:Assertions controller assertions; all API, process, task, and launch effects mocked."
} finally {
    $fullFixture=[IO.Path]::GetFullPath($script:FixtureRoot)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if($fullFixture.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $fullFixture) -like 'widget-controller-test-*') {
        Remove-Item -LiteralPath $fullFixture -Recurse -Force
    }
}
