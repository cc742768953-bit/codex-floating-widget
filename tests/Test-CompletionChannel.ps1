# Offline completion checks; account switching is mocked.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\CodexFloatingWidget.ps1') -TestMode
$script:Accounts=@([pscustomobject]@{id='a';name='A'},[pscustomobject]@{id='b';name='B'})
$script:ActiveId='a';$script:Expanded=$true;$window.Left=80;$window.Top=80;$window.Show();Update-View
[IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'artifacts'))|Out-Null;$path=Join-Path $PSScriptRoot 'artifacts\completion-test.json';$request=[guid]::NewGuid().ToString('N');$started=[datetime]::Now
function Write-Result($requestValue,$target,$success){@{request_id=$requestValue;target_id=$target;success=$success;completed_at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}|ConvertTo-Json|Set-Content -LiteralPath $path}
# Scheduler calls throw: successful polling cannot depend on task State becoming Ready.
$worker=[scriptblock]::Create("param(`$name,`$started,`$target,`$resultPath,`$requestId)`nfunction Get-ScheduledTask {throw 'Scheduler is still Running'};function Get-ScheduledTaskInfo {throw 'Must not query scheduler'};function Invoke-RestMethod {param(`$Method,`$Uri,`$ContentType,`$Body,`$TimeoutSec) [pscustomobject]@{id='b'}}`n"+($script:SwitchWorker.ToString() -replace '^param\([^\r\n]+\)\s*',''))
Write-Result 'old-request' 'b' $true
if((& $worker 'running-task' $started 'b' $path $request) -ne 'pending'){throw 'Stale request accepted'}
Write-Result $request 'wrong-target' $true
if((& $worker 'running-task' $started 'b' $path $request) -ne 'pending'){throw 'Wrong target accepted'}
Write-Result $request 'b' $false
if((& $worker 'running-task' $started 'b' $path $request) -ne 'failed'){throw 'Failure not signaled'}
Write-Result $request 'b' $true
$target='b'
$script:SwitchState=[pscustomobject]@{TargetId=$target;TaskName='running-task';Started=$started;RequestId=$request;ResultPath=$path;Polling=$true}
$watch=[Diagnostics.Stopwatch]::StartNew();Begin-Worker 'switch' '' $worker @('running-task',$started,$target,$path,$request)
$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(100)
$script:TestError=''
$timer.Add_Tick({try{Poll-Workers;if(-not $script:SwitchState){$watch.Stop();if($script:Expanded -or $script:ActiveId -ne $target){throw 'Success did not collapse'};if($window.Left -ne 80 -or $window.Top -ne 80){throw 'Position moved'};if($watch.ElapsedMilliseconds -ge 3000){throw 'Completion too slow'};$timer.Stop();$script:AllowClose=$true;$window.Close();$application.Shutdown()}elseif($watch.ElapsedMilliseconds -gt 5000){throw 'Timeout'}}catch{$script:TestError=$_.Exception.Message;$timer.Stop();$script:AllowClose=$true;$window.Close();$application.Shutdown()}})
$timer.Start();[void]$application.Run();Remove-Item -LiteralPath $path
if($script:TestError){throw $script:TestError}
"PASS stale/target/failure and asynchronous result->Poll->Finish collapse in $($watch.ElapsedMilliseconds) ms despite scheduler Running; coordinates unchanged"
