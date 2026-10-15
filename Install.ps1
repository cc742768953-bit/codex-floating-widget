[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath,
    [switch]$EnableStartup,
    [switch]$DesktopShortcut,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
$script:WidgetConfig = Get-WidgetConfiguration -ConfigPath $ConfigPath
$config = $script:WidgetConfig
$widgetPath = Join-Path $PSScriptRoot 'CodexFloatingWidget.ps1'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shortcutName = 'Codex Floating Widget.lnk'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath $shortcutName

foreach ($required in @('CodexFloatingWidget.ps1', 'Common.ps1', 'Switch-CodexAccount.ps1', 'Uninstall.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $required) -PathType Leaf)) {
        throw "The release is incomplete: $required is missing. Extract the complete release archive."
    }
}
if ($ConfigPath) {
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw 'ConfigPath must point to an existing JSON configuration.' }
}
$taskArguments = '-NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $widgetPath + '"'
if ($ConfigPath) { $taskArguments += ' -ConfigPath "' + $ConfigPath + '"' }
$existingTask = Get-ScheduledTask -TaskName $config.StartupTaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    $matchingAction = @($existingTask.Actions | Where-Object {
        [string]$_.Arguments -match ('(?i)-File\s+"?' + [regex]::Escape($widgetPath) + '(?:"|\s|$)')
    })
    if ($matchingAction.Count -eq 0) {
        throw 'A task with this name belongs to another installation. Uninstall that copy first.'
    }
}
if ($DesktopShortcut -and (Test-Path -LiteralPath $shortcutPath)) {
    $shell = New-Object -ComObject WScript.Shell
    $existingShortcut = $shell.CreateShortcut($shortcutPath)
    $expectedShortcutTarget = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $expectedShortcutArguments = '/Run /TN "' + $config.StartupTaskName + '"'
    if ([string]$existingShortcut.TargetPath -ine $expectedShortcutTarget -or [string]$existingShortcut.Arguments -ne $expectedShortcutArguments) {
        throw 'The desktop shortcut name is already used by another application.'
    }
}

if ($PSCmdlet.ShouldProcess($config.StartupTaskName, 'Install per-user widget launch task')) {
    $userName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $powershellPath -Argument $taskArguments -WorkingDirectory $PSScriptRoot
    $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $taskOptions = @{
        TaskName = $config.StartupTaskName
        Action = $action
        Principal = $principal
        Settings = $settings
        Description = 'Per-user Codex Floating Widget launcher. Remove with Uninstall.ps1.'
        Force = $true
    }
    if ($EnableStartup) { $taskOptions.Trigger = New-ScheduledTaskTrigger -AtLogOn -User $userName }
    Register-ScheduledTask @taskOptions | Out-Null
    Write-Host 'Installed the independent widget launch task for the current Windows user.'
}

if ($DesktopShortcut -and $PSCmdlet.ShouldProcess($shortcutPath, 'Create widget desktop shortcut')) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $shortcut.Arguments = '/Run /TN "' + $config.StartupTaskName + '"'
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Open Codex Floating Widget using its independent launch task.'
    $shortcut.Save()
    Write-Host 'Created the desktop shortcut.'
}
if ($Start -and $PSCmdlet.ShouldProcess($config.StartupTaskName, 'Start widget')) {
    Start-ScheduledTask -TaskName $config.StartupTaskName
}
Write-Host 'Keep this release folder in place. Before moving it, uninstall this copy, then install from the new folder.'
if (-not $EnableStartup) { Write-Host 'Automatic launch at sign-in is disabled; the task remains available on demand.' }
