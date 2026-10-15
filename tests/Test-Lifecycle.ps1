$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\CodexFloatingWidget.ps1') -TestMode
$script:LifecycleStep=0;$script:LifecycleFailure=$null;$script:LifecycleChecks=0
function Check($v,$m){if(-not $v){throw $m};$script:LifecycleChecks++}
$probe=[Windows.Threading.DispatcherTimer]::new();$probe.Interval=[TimeSpan]::FromMilliseconds(120)
$probe.Add_Tick({try{
switch($script:LifecycleStep){
0 {Update-Lifecycle $true;Check $window.IsVisible 'Initial Codex show failed'}
1 {Update-Lifecycle $false;Check (-not $window.IsVisible) 'Codex close did not hide'}
2 {Check (-not $window.IsVisible) 'Hidden app did not remain alive across dispatcher ticks';Update-Lifecycle $true;Check $window.IsVisible 'Codex reopen did not restore'}
3 {$HideButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));Update-Lifecycle $true;Check (-not $window.IsVisible) 'Manual hide not respected'}
4 {Update-Lifecycle $false;Update-Lifecycle $true;Check $window.IsVisible 'Reopen did not clear user-hidden state'}
5 {$window.Close();Check (-not $window.IsVisible) 'Close must hide rather than terminate'}
6 {Update-Lifecycle $false;Update-Lifecycle $true;Check $window.IsVisible 'Closed-to-tray app did not restore';Check ($application.ShutdownMode -eq 'OnExplicitShutdown') 'Application lifecycle must be explicit';$probe.Stop();$script:AllowClose=$true;$window.Close();$application.Shutdown()}
};$script:LifecycleStep++
}catch{$script:LifecycleFailure=$_.Exception.Message;$probe.Stop();$script:AllowClose=$true;$window.Close();$application.Shutdown()}})
$probe.Start();[void]$application.Run()
if($script:LifecycleFailure){throw $script:LifecycleFailure}
"PASS $script:LifecycleChecks real dispatcher lifecycle checks (Codex visibility input simulated; Codex process untouched)"
