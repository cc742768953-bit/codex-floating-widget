# Shared configuration and narrowly scoped desktop process discovery.
function Get-WidgetConfiguration {
    param([string]$ConfigPath, [string]$StateDirectory)
    if (-not $StateDirectory) { $StateDirectory = Join-Path $env:LOCALAPPDATA 'CodexFloatingWidget' }
    $StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
    if (-not $ConfigPath) { $ConfigPath = Join-Path $StateDirectory 'config.json' }
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $values = @{ ApiPort=3210; SwitcherExecutable=''; CodexExecutable=''; CodexAppId=''; StartupTaskName='Codex Floating Widget Public' }
    if (Test-Path -LiteralPath $ConfigPath) {
        $custom = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $custom -or $custom.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') { throw 'Configuration must be a JSON object.' }
        foreach ($property in $custom.PSObject.Properties) {
            if (-not $values.ContainsKey($property.Name)) { throw ('Unknown configuration option: ' + $property.Name) }
            $values[$property.Name] = $property.Value
        }
    }
    $port=0
    if (-not [int]::TryParse([string]$values.ApiPort,[ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'ApiPort must be an integer between 1 and 65535.' }
    $values.ApiPort=$port
    foreach ($key in @('SwitcherExecutable','CodexExecutable','CodexAppId','StartupTaskName')) {
        if ($null -eq $values[$key] -or $values[$key] -isnot [string]) { throw ($key + ' must be a string.') }
        if ($values[$key] -match '[\r\n\x00"]') { throw ($key + ' contains unsupported characters.') }
    }
    if ($values.StartupTaskName -notmatch '^Codex Floating Widget Public(?: [a-zA-Z0-9_-]+)?$') { throw 'StartupTaskName must start with Codex Floating Widget Public, optionally followed by a simple suffix.' }
    foreach($key in @('SwitcherExecutable','CodexExecutable')) {
        if ($values[$key]) {
            $values[$key]=[Environment]::ExpandEnvironmentVariables($values[$key])
            if (-not [IO.Path]::IsPathRooted($values[$key])) { throw ($key + ' must be an absolute executable path.') }
            if ([IO.Path]::GetExtension($values[$key]) -ine '.exe') { throw ($key + ' must name an .exe file.') }
        }
    }
    if (-not $values.SwitcherExecutable) {
        $candidates=@()
        if ($env:ProgramFiles) { $candidates+=Join-Path $env:ProgramFiles 'Codex Switcher\codex-web.exe' }
        if ($env:LOCALAPPDATA) { $candidates+=Join-Path $env:LOCALAPPDATA 'Programs\Codex Switcher\codex-web.exe' }
        foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { $values.SwitcherExecutable=$candidate;break } }
    }
    if (-not $values.CodexAppId) {
        try {
            $package=Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Select-Object -First 1
            if ($package) { $values.CodexAppId=$package.PackageFamilyName+'!App' }
        } catch {}
    }
    if ($values.CodexAppId -and $values.CodexAppId -notmatch '^[A-Za-z0-9._-]+![A-Za-z0-9._-]+$') { throw 'CodexAppId is not a valid application ID.' }
    $values.StateDirectory=$StateDirectory
    $values.ConfigPath=$ConfigPath
    return [pscustomobject]$values
}

function Get-WidgetCodexProcesses {
    param($Configuration=$script:WidgetConfig)
    $all=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $roots=@($all | Where-Object {
        $path=[string]$_.ExecutablePath
        ($path -match '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\(?:ChatGPT|Codex)\.exe$') -or
        ($Configuration -and $Configuration.CodexExecutable -and $path -and $path -ieq $Configuration.CodexExecutable)
    })
    # Descendants of an identified desktop executable include its bundled services.
    # Unrelated Codex CLI sessions and the separate ChatGPT app are never roots.
    $ids=New-Object 'System.Collections.Generic.HashSet[int]'
    foreach($root in $roots) { [void]$ids.Add([int]$root.ProcessId) }
    do {
        $added=$false
        foreach($process in $all) {
            if ($ids.Contains([int]$process.ParentProcessId) -and $ids.Add([int]$process.ProcessId)) { $added=$true }
        }
    } while($added)
    return @($all | Where-Object { $ids.Contains([int]$_.ProcessId) })
}

function Test-WidgetCodexVisible {
    param($Configuration=$script:WidgetConfig)
    foreach($process in @(Get-WidgetCodexProcesses -Configuration $Configuration)) {
        $native=Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        if ($native -and $native.MainWindowHandle -ne 0) { return $true }
    }
    return $false
}
