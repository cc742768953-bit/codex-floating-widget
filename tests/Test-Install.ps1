# Both install scripts run against fake task, process, and shortcut operations.
$ErrorActionPreference = 'Stop'
$releaseRoot = Split-Path -Parent $PSScriptRoot
$script:FixtureReleaseRoot = Join-Path ([IO.Path]::GetTempPath()) 'widget-install-test [release]'
$script:FixtureState = Join-Path $env:LOCALAPPDATA 'CodexFloatingWidget'
foreach($scriptName in @('Install','Uninstall')) {
    $source=[IO.File]::ReadAllText((Join-Path $releaseRoot ($scriptName + '.ps1')))
    $tokens=$null; $parseErrors=$null
    [Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors) | Out-Null
    if($parseErrors.Count){throw "$scriptName parse failed."}
    $source=$source.Replace(". (Join-Path `$PSScriptRoot 'Common.ps1')",'').Replace('$PSScriptRoot','$script:FixtureReleaseRoot')
    Invoke-Expression ('function Invoke-Test' + $scriptName + ' {' + $source + '}')
}
function Get-WidgetConfiguration {
    param($ConfigPath)
    [pscustomobject]@{StartupTaskName='Codex Floating Widget Public';StateDirectory=$script:FixtureState}
}
function Test-Path {
    param($LiteralPath,$PathType)
    if($LiteralPath -like '*.lnk'){return $script:ShortcutExists}
    if($script:MissingReleaseFile -and (Split-Path -Leaf $LiteralPath) -eq 'Common.ps1'){return $false}
    return $true
}
function Get-ScheduledTask {param($TaskName,$ErrorAction) return $script:ExistingTask}
function New-ScheduledTaskAction {param($Execute,$Argument,$WorkingDirectory) [pscustomobject]@{Execute=$Execute;Arguments=$Argument;WorkingDirectory=$WorkingDirectory}}
function New-ScheduledTaskPrincipal {param($UserId,$LogonType,$RunLevel) [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}}
function New-ScheduledTaskSettingsSet {param($MultipleInstances,$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries) [pscustomobject]@{MultipleInstances=$MultipleInstances;ExecutionTimeLimit=$ExecutionTimeLimit}}
function New-ScheduledTaskTrigger {param([switch]$AtLogOn,$User) $script:Triggers++; [pscustomobject]@{AtLogOn=$AtLogOn;User=$User}}
function Register-ScheduledTask {
    param($TaskName,$Action,$Principal,$Settings,$Description,[switch]$Force,$Trigger)
    $script:Registered++; $script:RegisteredTask=[pscustomobject]@{TaskName=$TaskName;Action=$Action;Principal=$Principal;Settings=$Settings;Trigger=$Trigger}
}
function Start-ScheduledTask {param($TaskName) $script:Started++; $script:StartedName=$TaskName}
function Unregister-ScheduledTask {param($TaskName,[switch]$Confirm) $script:RemovedTasks++; $script:RemovedTaskName=$TaskName}
function Remove-Item {param($LiteralPath,[switch]$Recurse,[switch]$Force) $script:RemovedPaths.Add($LiteralPath)}
function New-Object {
    param($ComObject)
    if($ComObject -ne 'WScript.Shell'){throw 'Unexpected object creation'}
    $shell=[pscustomobject]@{}
    $shell | Add-Member ScriptMethod CreateShortcut {param($Path) return $script:FixtureShortcut}
    return $shell
}
function Setup {
    $script:Registered=0; $script:Triggers=0; $script:Started=0; $script:SavedShortcuts=0; $script:RemovedTasks=0
    $script:RemovedPaths=[Collections.Generic.List[string]]::new()
    $script:RegisteredTask=$null; $script:ExistingTask=$null; $script:ShortcutExists=$false; $script:MissingReleaseFile=$false
    $script:FixtureState=Join-Path $env:LOCALAPPDATA 'CodexFloatingWidget'
    $script:FixtureShortcut=[pscustomobject]@{TargetPath='';Arguments='';WorkingDirectory='';WindowStyle=0;Description=''}
    $script:FixtureShortcut | Add-Member ScriptMethod Save {$script:SavedShortcuts++}
}
function Set-OwnedTask {
    $script:ExistingTask=[pscustomobject]@{Actions=@([pscustomobject]@{Arguments=('-NoProfile -File "' + (Join-Path $script:FixtureReleaseRoot 'CodexFloatingWidget.ps1') + '"')})}
}
function Set-OwnedShortcut {
    $script:ShortcutExists=$true
    $script:FixtureShortcut.TargetPath=Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $script:FixtureShortcut.Arguments='/Run /TN "Codex Floating Widget Public"'
}
$script:Assertions=0
function Assert($Value,$Message){if(-not $Value){throw "FAIL: $Message"};$script:Assertions++}
function Assert-Throws($Action,$Message){$didThrow=$false;try{& $Action}catch{$didThrow=$true};Assert $didThrow $Message}

Setup; Invoke-TestInstall
Assert ($script:Registered -eq 1 -and $script:Triggers -eq 0 -and $script:Started -eq 0 -and $script:SavedShortcuts -eq 0) 'default install creates only an on-demand task'
Assert ($script:RegisteredTask.TaskName -eq 'Codex Floating Widget Public') 'public task stays distinct from legacy task'
Assert ($script:RegisteredTask.Principal.LogonType -eq 'Interactive' -and $script:RegisteredTask.Principal.RunLevel -eq 'Limited') 'task uses current-user interactive limited privileges'
Assert ($script:RegisteredTask.Action.WorkingDirectory -eq $script:FixtureReleaseRoot -and $script:RegisteredTask.Action.Arguments.Contains('-Sta') -and $script:RegisteredTask.Action.Arguments.Contains('-WindowStyle Hidden')) 'task owns hidden STA widget launch in release root'
Assert ($script:RegisteredTask.Settings.ExecutionTimeLimit -eq [TimeSpan]::Zero -and $script:RegisteredTask.Settings.MultipleInstances -eq 'IgnoreNew') 'task does not expire or create duplicate launches'
Setup; Invoke-TestInstall -EnableStartup -DesktopShortcut -Start -ConfigPath (Join-Path $script:FixtureReleaseRoot 'configuration.json')
Assert ($script:Registered -eq 1 -and $script:Triggers -eq 1 -and $script:Started -eq 1 -and $script:SavedShortcuts -eq 1) 'startup, desktop shortcut, and launch are opt-in'
Assert ($script:RegisteredTask.Action.Arguments.Contains('-ConfigPath "')) 'custom configuration is carried by task action'
Assert ($script:FixtureShortcut.TargetPath -like '*\schtasks.exe' -and $script:FixtureShortcut.Arguments -eq '/Run /TN "Codex Floating Widget Public"') 'desktop shortcut starts the independent task'
Setup; Invoke-TestInstall -EnableStartup -DesktopShortcut -Start -WhatIf
Assert ($script:Registered -eq 0 -and $script:Triggers -eq 0 -and $script:Started -eq 0 -and $script:SavedShortcuts -eq 0) 'install WhatIf performs no mutations'
Setup; Set-OwnedTask; Invoke-TestInstall
Assert ($script:Registered -eq 1) 'same release can update its own task'
Setup; $script:ExistingTask=[pscustomobject]@{Actions=@([pscustomobject]@{Arguments='-File "Z:\other\widget.ps1"'})}
Assert-Throws {Invoke-TestInstall} 'another installation task is rejected'
Assert ($script:Registered -eq 0) 'conflicting task is never overwritten'
Setup; $script:ShortcutExists=$true; $script:FixtureShortcut.TargetPath='other.exe'; $script:FixtureShortcut.Arguments='/Run /TN "Codex Floating Widget Public"'
Assert-Throws {Invoke-TestInstall -DesktopShortcut} 'unrelated shortcut target is rejected'
Assert ($script:Registered -eq 0 -and $script:SavedShortcuts -eq 0) 'shortcut collision is detected before installing anything'
Setup; $script:MissingReleaseFile=$true
Assert-Throws {Invoke-TestInstall} 'incomplete release is rejected'
Setup; Set-OwnedTask; Set-OwnedShortcut; Invoke-TestUninstall
Assert ($script:RemovedTasks -eq 1 -and $script:RemovedTaskName -eq 'Codex Floating Widget Public') 'uninstall removes only its public task'
Assert ($script:RemovedPaths.Count -eq 1 -and $script:RemovedPaths[0] -like '*.lnk') 'default uninstall keeps settings and removes owned shortcut'
Setup; Set-OwnedTask; Set-OwnedShortcut; Invoke-TestUninstall -RemoveSettings -WhatIf
Assert ($script:RemovedTasks -eq 0 -and $script:RemovedPaths.Count -eq 0) 'uninstall WhatIf performs no mutations'
Setup; Set-OwnedTask; Invoke-TestUninstall -RemoveSettings
Assert ($script:RemovedPaths.Count -eq 1 -and $script:RemovedPaths[0] -eq $script:FixtureState) 'explicit settings removal targets only widget state'
Setup; $script:ShortcutExists=$true; $script:FixtureShortcut.TargetPath='unrelated.exe'; Invoke-TestUninstall
Assert ($script:RemovedPaths.Count -eq 0) 'uninstall preserves unrelated shortcut'
Setup; $script:ExistingTask=[pscustomobject]@{Actions=@([pscustomobject]@{Arguments='-File "Z:\other\widget.ps1"'})}
Assert-Throws {Invoke-TestUninstall} 'uninstall refuses another installation task'
Assert ($script:RemovedTasks -eq 0 -and $script:RemovedPaths.Count -eq 0) 'uninstall task collision causes no mutation'
Setup; $script:FixtureState=[IO.Path]::GetPathRoot($env:LOCALAPPDATA)
Assert-Throws {Invoke-TestUninstall -RemoveSettings} 'unsafe recursive settings target is rejected'
Assert ($script:RemovedPaths.Count -eq 0) 'unsafe target is never removed'
"PASS: $script:Assertions install/uninstall assertions; task, shortcut, and deletion effects mocked."
