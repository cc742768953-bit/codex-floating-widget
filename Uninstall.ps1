[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath,
    [switch]$RemoveSettings
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$script:WidgetConfig = Get-WidgetConfiguration -ConfigPath $ConfigPath
$config = $script:WidgetConfig
$widgetPath = Join-Path $PSScriptRoot 'CodexFloatingWidget.ps1'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Codex Floating Widget.lnk'
$task = Get-ScheduledTask -TaskName $config.StartupTaskName -ErrorAction SilentlyContinue
if ($task) {
    $ownedActions = @($task.Actions | Where-Object {
        [string]$_.Arguments -match ('(?i)-File\s+"?' + [regex]::Escape($widgetPath) + '(?:"|\s|$)')
    })
    if ($ownedActions.Count -eq 0) { throw 'The named task belongs to another release folder; run its Uninstall.ps1.' }
    if ($PSCmdlet.ShouldProcess($config.StartupTaskName, 'Remove widget launch task')) {
        Unregister-ScheduledTask -TaskName $config.StartupTaskName -Confirm:$false
    }
}
if (Test-Path -LiteralPath $shortcutPath) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $expectedTarget = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $expectedArguments = '/Run /TN "' + $config.StartupTaskName + '"'
    if ([string]$shortcut.TargetPath -ieq $expectedTarget -and [string]$shortcut.Arguments -eq $expectedArguments) {
        if ($PSCmdlet.ShouldProcess($shortcutPath, 'Remove widget desktop shortcut')) { Remove-Item -LiteralPath $shortcutPath }
    }
}
if ($RemoveSettings -and (Test-Path -LiteralPath $config.StateDirectory)) {
    # Refuse an unsafe deletion target even if a future configuration source changes.
    $statePath = [IO.Path]::GetFullPath($config.StateDirectory).TrimEnd('\', '/')
    $expectedStatePath = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CodexFloatingWidget')).TrimEnd('\', '/')
    if ($statePath -ine $expectedStatePath) { throw 'Settings removal is limited to the standard per-user widget state folder.' }
    if ($PSCmdlet.ShouldProcess($statePath, 'Delete widget settings, logs, and switch completion files')) {
        Remove-Item -LiteralPath $statePath -Recurse -Force
    }
}
Write-Host 'Uninstall finished. Close the widget from its tray menu if it is still running.'
Write-Host 'The release folder and Codex Switcher remain available.'
