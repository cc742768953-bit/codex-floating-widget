$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\CodexFloatingWidget.ps1') -TestMode
$script:Accounts=@([pscustomobject]@{id='a';email='demoaccount@example.com';plan_type='plus'});$script:ActiveId='a'
$window.Left=80;$window.Top=80;$window.Show()
$checks=0;[IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'artifacts'))|Out-Null
foreach($used in @(100,0,70)){
Apply-UsageResult 'a' ([pscustomobject]@{primary_used_percent=$used;secondary_used_percent=$used;primary_resets_at=$script:Now+3600;secondary_resets_at=$script:Now+172800}) '';Update-View
$canvas=$CurrentHost.Children[0].Children[0];$lines=@($canvas.Children|Where-Object Tag -eq 'RingSeparator')
if($lines.Count -ne 2){throw 'Need exactly two separators'};$checks++
foreach($line in $lines){
if($line.StrokeThickness -ne 2 -or $line.X2-$line.X1 -ne 8 -or $line.Y1 -ne 84 -or $line.Y2 -ne 84){throw 'Separator dimensions changed'};$checks++
if([Windows.Controls.Canvas]::GetTop($line) -ne 18){throw 'Badge vertical shift not preserved'};$checks++
if($line.X1 -notin @(4,156)){throw 'Separator is not at 9/3 oclock'};$checks++
}
$paths=@($canvas.Children|Where-Object {$_ -is [Windows.Shapes.Path]});foreach($path in $paths){if($canvas.Children.IndexOf($path) -gt $canvas.Children.IndexOf($lines[0])){throw 'Separator under colored arc'};$checks++}
if($canvas.Children[0] -isnot [Windows.Shapes.Ellipse]){throw 'Full circular track missing'};$checks++
$name=if($used -eq 100){'09-separators-exhausted.png'}elseif($used -eq 0){'10-separators-full.png'}else{'11-separators-thirty.png'}
Export-Render (Join-Path $PSScriptRoot ('artifacts\'+$name))
}
$script:AllowClose=$true;$window.Close();$application.Shutdown();"PASS $checks separator geometry/layering checks"
