$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\CodexFloatingWidget.ps1') -TestMode
$script:Checks=0
function Assert($v,$m){if(-not $v){throw "FAIL $m"};$script:Checks++}
$script:Accounts=@([pscustomobject]@{id='a';email='demoalpha@example.com';plan_type='plus'},[pscustomobject]@{id='b';email='testbeta@example.org';plan_type='pro'},[pscustomobject]@{id='c';email='workgamma@example.net';plan_type='prolite'})
Assert ((Get-DisplayName $script:Accounts[0]) -eq 'demo…@example.com') 'prefix four and full domain'
Assert ((Get-DisplayName $script:Accounts[1]) -eq 'test…@example.org') 'second email'
Assert ((Get-DisplayName $script:Accounts[2]) -eq 'work…@example.net') 'third email'
Assert ((Get-PlanLabel $script:Accounts[0] $null) -eq 'Plus') 'plus exact'
Assert ((Get-PlanLabel $script:Accounts[1] $null) -eq 'Pro') 'pro exact'
Assert ((Get-PlanLabel $script:Accounts[2] $null) -eq 'Pro Lite') 'prolite exact'
Assert ((Get-PlanLabel ([pscustomobject]@{plan_type='team'}) $null) -eq '未知') 'unknown not guessed'
Assert ((Get-PlanLabel ([pscustomobject]@{}) $null) -eq '未知') 'absent explicit'
Assert ((Get-PlanLabel $script:Accounts[0] ([pscustomobject]@{plan_type='prolite'})) -eq 'Pro Lite') 'fresh usage plan precedence'
$script:Accounts+=([pscustomobject]@{id='d';email='demobeta@example.com'})
Assert ((Get-DisplayName $script:Accounts[0]) -eq 'demo…ha@example.com') 'collision suffix first'
Assert ((Get-DisplayName $script:Accounts[3]) -eq 'demo…ta@example.com') 'collision suffix second'
$script:ActiveId='a';$window.Left=80;$window.Top=80;$window.Show();Update-View
$script:Expanded=$true;Update-View
foreach($panel in @($CurrentHost.Children[0])+@($ExtraHost.Children)){
$canvas=$panel.Children[0];$badge=@($canvas.Children|Where-Object Tag -eq 'PlanBadge')[0];$track=$canvas.Children[0];$text=$panel.Children[1]
Assert ($text.FontSize -ge 12 -and $text.ActualWidth -le 168) 'legible email inside viewport'
Assert ($text.ToolTip -eq (Get-AccountEmail $script:Accounts[(@('a','b','c','d').IndexOf([string](@($canvas.Children|Where-Object {$_ -is [Windows.Controls.Button]})[0].Tag)))])) 'full email tooltip'
Assert ([Windows.Controls.Canvas]::GetLeft($badge)+$badge.ActualWidth -le 168.01) 'badge right edge inside'
Assert ([Windows.Controls.Canvas]::GetLeft($badge) -gt 84) 'badge upper right'
Assert ([Windows.Controls.Canvas]::GetTop($badge)+$badge.ActualHeight -lt [Windows.Controls.Canvas]::GetTop($track)) 'badge strictly above circle bounds no overlap'
Assert ($track.Width -eq 160 -and $track.Height -eq 160) 'circle unchanged'
}
$long=[pscustomobject]@{id='long';email='abcdexample@long-domain.example.com';plan_type='prolite'};$dial=New-Dial $long;$dial.Measure([Windows.Size]::new(178,1000));$dial.Arrange([Windows.Rect]::new(0,0,178,$dial.DesiredSize.Height));$emailText=$dial.Children[1]
Assert ($emailText.ActualHeight -gt 20 -and $emailText.ActualWidth -le 168 -and $emailText.FontSize -eq 12) 'long domain wraps without font shrink or overflow'
Assert ($emailText.Text.EndsWith('@long-domain.example.com')) 'long full domain preserved'
$script:AllowClose=$true;$window.Close();$application.Shutdown();"PASS $script:Checks email/plan layout checks"
