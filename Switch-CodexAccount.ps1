[CmdletBinding()]
param(
    [string]$AccountName,
    [string]$AccountId,
    [ValidateRange(1, 65535)][int]$ApiPort,
    [string]$ConfigPath,
    [switch]$NoLaunch,
    [switch]$RestoreWidget,
    [string]$ResultPath,
    [string]$RequestId
)

$ErrorActionPreference = 'Stop'
$script:CodexStopAttempted = $false
$script:WidgetTaskVerified = $false
$script:SwitchStage = 'configuration'
$target = $null
$logFile = $null

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    if ($logFile) {
        try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch {}
    }
    Write-Host $line
}

function Invoke-SwitcherApi {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [hashtable]$Body = @{}
    )
    try {
        Invoke-RestMethod -Method Post -Uri "$apiBase/api/invoke/$Command" `
            -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Compress) -TimeoutSec 15
    } catch {
        # API error bodies can contain account names, email addresses, or tokens.
        throw "The local Switcher API could not complete '$Command'. Check Codex Switcher."
    }
}

function Ensure-SwitcherApi {
    try {
        $health = Invoke-RestMethod -Uri "$apiBase/api/health" -TimeoutSec 2
        if ($health.ok -eq $true) { return }
    } catch {}
    if (-not $config.SwitcherExecutable -or -not (Test-Path -LiteralPath $config.SwitcherExecutable -PathType Leaf)) {
        throw 'Install Codex Switcher or set SwitcherExecutable in the widget configuration.'
    }
    Write-Log 'Starting the Codex Switcher local API on the loopback interface.'
    $env:CODEX_SWITCHER_WEB_HOST = '127.0.0.1'
    $env:CODEX_SWITCHER_WEB_PORT = [string]$ApiPort
    Start-Process -FilePath $config.SwitcherExecutable -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $health = Invoke-RestMethod -Uri "$apiBase/api/health" -TimeoutSec 2
            if ($health.ok -eq $true) { return }
        } catch {}
    }
    throw 'The local Switcher API did not become ready. Check Codex Switcher and ApiPort.'
}

function Stop-Codex {
    $processes = @(Get-WidgetCodexProcesses)
    if ($processes.Count -eq 0) { Write-Log 'Codex is not running.'; return }
    $script:CodexStopAttempted = $true
    Write-Log ('Closing {0} Codex desktop processes.' -f $processes.Count)
    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $remaining = @(Get-WidgetCodexProcesses)
        if ($remaining.Count -eq 0) { Write-Log 'Codex has exited.'; return }
        foreach ($process in $remaining) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    throw 'Codex could not fully exit.'
}

function Start-Codex {
    Write-Log 'Starting Codex.'
    if ($config.CodexExecutable) {
        if (-not (Test-Path -LiteralPath $config.CodexExecutable -PathType Leaf)) {
            throw 'The configured CodexExecutable does not exist.'
        }
        Start-Process -FilePath $config.CodexExecutable -WindowStyle Normal | Out-Null
    } elseif ($config.CodexAppId) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $config.CodexAppId) -WindowStyle Normal | Out-Null
    } else {
        throw 'Codex was not found. Install Codex or configure CodexExecutable.'
    }
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-WidgetCodexVisible) { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'Codex did not become visible within the restart timeout.'
}

function Write-SwitchResult([bool]$Success) {
    if (-not $ResultPath) { return }
    if ($RequestId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid switch request ID.' }
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $payload = @{
        request_id = $RequestId
        target_id = $(if ($target) { [string]$target.id } else { $AccountId })
        success = $Success
        completed_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress
    $temp = $ResultPath + '.' + $RequestId + '.tmp'
    [IO.File]::WriteAllText($temp, $payload, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $ResultPath -Force
}

function Restore-CodexWidget {
    if (-not $RestoreWidget) { return }
    function Find-WidgetProcess {
        $widgetPath = Join-Path $PSScriptRoot 'CodexFloatingWidget.ps1'
        $pattern = '(?i)-File\s+"?' + [regex]::Escape($widgetPath) + '(?:"|\s|$)'
        @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Where-Object {
            [string]$_.CommandLine -match $pattern
        })
    }
    if (@(Find-WidgetProcess).Count -gt 0) { Write-Log 'The floating widget is still running.'; return }
    if (-not $script:WidgetTaskVerified) { throw 'The widget task was not verified; run Install.ps1 again.' }
    # Task Scheduler owns this launch so it survives the Codex process lifetime.
    Start-ScheduledTask -TaskName $config.StartupTaskName
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 400
        if (@(Find-WidgetProcess).Count -gt 0) { Write-Log 'The floating widget was restored.'; return }
    }
    throw 'The widget launch task did not create its process. Run Install.ps1 again.'
}

try {
    . (Join-Path $PSScriptRoot 'Common.ps1')
    $script:WidgetConfig = Get-WidgetConfiguration -ConfigPath $ConfigPath
    $config = $script:WidgetConfig
    if (-not $PSBoundParameters.ContainsKey('ApiPort')) { $ApiPort = $config.ApiPort }
    $apiBase = "http://127.0.0.1:$ApiPort"
    $logDir = Join-Path $config.StateDirectory 'logs'
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    $logFile = Join-Path $logDir 'Switch-CodexAccount.log'
    if (-not $AccountId -and -not $AccountName) { throw 'Specify AccountId or AccountName.' }
    if ($ResultPath -and $RequestId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid switch request ID.' }
    if (-not $NoLaunch) {
        if ($config.CodexExecutable) {
            if (-not (Test-Path -LiteralPath $config.CodexExecutable -PathType Leaf)) { throw 'The configured CodexExecutable does not exist.' }
        } elseif (-not $config.CodexAppId) {
            throw 'Codex was not found. Install Codex or configure CodexExecutable before switching.'
        }
    }
    Write-Log 'Preparing an account switch.'
    $script:SwitchStage = 'local API startup'
    Ensure-SwitcherApi
    if ($RestoreWidget) {
        $widgetTask = Get-ScheduledTask -TaskName $config.StartupTaskName -ErrorAction Stop
        $expectedWidget = Join-Path $PSScriptRoot 'CodexFloatingWidget.ps1'
        $ownedActions = @($widgetTask.Actions | Where-Object {
            [string]$_.Arguments -match ('(?i)-File\s+"?' + [regex]::Escape($expectedWidget) + '(?:"|\s|$)')
        })
        if ($ownedActions.Count -eq 0) { throw 'The widget task points to another release folder. Run Install.ps1 from this folder.' }
        $script:WidgetTaskVerified = $true
    }
    $script:SwitchStage = 'account selection'
    $accounts = @(Invoke-SwitcherApi -Command 'list_accounts')
    $matches = @($accounts | Where-Object {
        if ($AccountId) { [string]$_.id -eq $AccountId } else { [string]$_.name -eq $AccountName }
    })
    if ($matches.Count -ne 1) { throw 'Target must match exactly one account. Use AccountId for duplicate names.' }
    $target = $matches[0]
    if (-not [string]$target.id) { throw 'The selected account has no identifier.' }
    $active = Invoke-SwitcherApi -Command 'get_active_account_info'
    if ([string]$active.id -eq [string]$target.id) {
        Write-Log 'The selected account is already active.'
        if (-not $NoLaunch -and -not (Test-WidgetCodexVisible)) { Start-Codex }
    } else {
        $script:SwitchStage = 'closing Codex'
        Stop-Codex
        $script:SwitchStage = 'switching account'
        Invoke-SwitcherApi -Command 'switch_account' -Body @{ accountId = $target.id } | Out-Null
        $script:SwitchStage = 'verifying the selected account'
        $newActive = Invoke-SwitcherApi -Command 'get_active_account_info'
        if ([string]$newActive.id -ne [string]$target.id) { throw 'The account switch could not be verified.' }
        Write-Log 'The selected account is now active.'
        $script:SwitchStage = 'restarting Codex'
        if (-not $NoLaunch) { Start-Codex }
    }
    $script:SwitchStage = 'restoring the widget'
    Restore-CodexWidget
    Write-SwitchResult $true
    Write-Log 'Switch flow completed.'
    exit 0
} catch {
    # Keep API responses and personal account identifiers out of diagnostics.
    Write-Log ("Switch failed during {0}. Check the widget configuration and Codex Switcher." -f $script:SwitchStage)
    try { Write-SwitchResult $false } catch { Write-Log 'Could not write the switch completion result.' }
    if ($script:CodexStopAttempted -and -not $NoLaunch) {
        try {
            if (-not (Test-WidgetCodexVisible)) { Start-Codex }
        } catch { Write-Log 'Codex recovery did not complete. Open Codex manually.' }
    }
    if ($RestoreWidget) {
        try { Restore-CodexWidget } catch { Write-Log 'Widget recovery did not complete. Run the installed launch shortcut.' }
    }
    exit 1
}
