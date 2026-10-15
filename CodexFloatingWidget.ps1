param([switch]$StartHidden,[switch]$TestMode,[string]$ConfigPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
if(-not ('CodexWidgetWindowTools' -as [type])){Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CodexWidgetWindowTools {
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    public static bool KeepTopmost(IntPtr window) {
        if (window == IntPtr.Zero) return false;
        // Move to the topmost group without moving, resizing or taking keyboard focus.
        return SetWindowPos(window, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    }
}
'@}
. (Join-Path $PSScriptRoot 'Common.ps1')
try{
if($TestMode){
$testState=Join-Path ([IO.Path]::GetTempPath()) ('CodexWidgetTest-'+[guid]::NewGuid().ToString('N'))
$script:WidgetConfig=Get-WidgetConfiguration -ConfigPath $ConfigPath -StateDirectory $testState
}else{$script:WidgetConfig=Get-WidgetConfiguration -ConfigPath $ConfigPath}
}catch{
if(-not $TestMode){[void][Windows.Forms.MessageBox]::Show(('配置无法读取，请检查 config.json。'+[Environment]::NewLine+$_.Exception.Message),'Codex 用量悬浮窗')}
throw
}
$script:StateDirectory=$script:WidgetConfig.StateDirectory
if(-not $TestMode){[IO.Directory]::CreateDirectory($script:StateDirectory)|Out-Null}
$script:SettingsPath=Join-Path $script:StateDirectory 'widget-settings.json'
$script:SwitchController=Join-Path $PSScriptRoot 'Switch-CodexAccount.ps1'
$script:Accounts=@();$script:Usage=@{};$script:Aliases=@{};$script:ActiveId='';$script:Expanded=$false;$script:SwitchState=$null
$script:Jobs=[Collections.ArrayList]::new();$script:AllowClose=$false;$script:UserHidden=[bool]$StartHidden;$script:WasCodex=$false
$script:Now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();$script:TestSwitchLaunchCount=0;$script:Status='';$script:NextRefresh=[datetime]::MinValue;$script:Generation=0;$script:SwitchError=''
if(-not $TestMode){$created=$false;$script:Mutex=[Threading.Mutex]::new($true,'Local\CodexFloatingUsageWidget',[ref]$created);if(-not $created){exit 0}}
$application=New-Object Windows.Application
$application.ShutdownMode=[Windows.ShutdownMode]::OnExplicitShutdown
[xml]$xaml=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Codex 用量" Width="200" Height="295" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False" ShowActivated="False" FontFamily="Microsoft YaHei UI" UseLayoutRounding="True">
<Window.Resources><Style TargetType="Button"><Setter Property="Foreground" Value="#EDF0EC"/><Setter Property="Background" Value="#3A4144"/><Setter Property="BorderBrush" Value="#596166"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9" Padding="3,0"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.8"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.65"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style></Window.Resources>
<Border x:Name="RootCard" Background="#252B2D" BorderBrush="#51595C" BorderThickness="1" CornerRadius="10" Padding="10,7,10,9"><Grid>
<Grid.RowDefinitions><RowDefinition Height="28"/><RowDefinition Height="Auto"/><RowDefinition Height="30"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
<Grid x:Name="DragArea" Background="Transparent"><TextBlock Text="Codex" Foreground="#ECEFEC" FontSize="14" VerticalAlignment="Center"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="RefreshButton" Content="↻" Width="24" Height="24" FontSize="19" Background="Transparent" BorderThickness="0" ToolTip="刷新全部账号用量"/><Button x:Name="HideButton" Content="−" Width="24" Height="24" FontSize="19" Background="Transparent" BorderThickness="0" ToolTip="隐藏到托盘"/></StackPanel></Grid>
<StackPanel x:Name="CurrentHost" Grid.Row="1"/><Button x:Name="ToggleButton" Grid.Row="2" Height="28" FontSize="12" Content="展开其他账号  ﹀"/>
<ScrollViewer x:Name="ExtraScroll" Grid.Row="3" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Visibility="Collapsed"><StackPanel x:Name="ExtraHost"/></ScrollViewer>
<TextBlock x:Name="StatusText" Grid.Row="4" Foreground="#E6BB92" FontSize="10" TextWrapping="Wrap" Visibility="Collapsed" Margin="0,4,0,0"/>
</Grid></Border></Window>
"@
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
foreach($name in 'CurrentHost','ExtraHost','ExtraScroll','ToggleButton','RefreshButton','HideButton','DragArea','StatusText','RootCard'){Set-Variable -Name $name -Value $window.FindName($name) -Scope Script}
function Get-ArcGeometry([double]$Remaining,[bool]$Upper){
$p=[Math]::Max(0,[Math]::Min(100,$Remaining));if($p -le 0){return $null}
# Colored arc anchored at RIGHT; gray full ellipse underneath is never broken.
$angle=$p/100*[Math]::PI;if($Upper){$angle=-$angle}
$fig=[Windows.Media.PathFigure]::new();$fig.StartPoint=[Windows.Point]::new(84+76*[Math]::Cos($angle),84+76*[Math]::Sin($angle))
$arc=[Windows.Media.ArcSegment]::new();$arc.Point=[Windows.Point]::new(160,84);$arc.Size=[Windows.Size]::new(76,76);$arc.IsLargeArc=$false
$arc.SweepDirection=if($Upper){'Clockwise'}else{'Counterclockwise'};$fig.Segments.Add($arc);$geo=[Windows.Media.PathGeometry]::new();$geo.Figures.Add($fig);return $geo
}
function Reset-Label($Unix){if($null -eq $Unix){return '重置时间未知'};$s=[long]$Unix-$script:Now;if($s -le 0){return '等待刷新重置'};$t=[TimeSpan]::FromSeconds($s);if($t.TotalDays -ge 1){return ('{0}天{1}时后重置' -f $t.Days,$t.Hours)};if($t.TotalHours -ge 1){return ('{0}时{1:00}分后重置' -f [int][Math]::Floor($t.TotalHours),$t.Minutes)};if($t.TotalMinutes -ge 1){return ('{0}分后重置' -f [int][Math]::Ceiling($t.TotalMinutes))};return '不足1分后重置'}
function Add-CanvasText($Canvas,[string]$Text,[double]$Y,[double]$Size,[string]$Color){$t=[Windows.Controls.TextBlock]::new();$t.Text=$Text;$t.Width=146;$t.TextAlignment='Center';$t.FontSize=$Size;$t.Foreground=$Color;[Windows.Controls.Canvas]::SetLeft($t,11);[Windows.Controls.Canvas]::SetTop($t,$Y);[void]$Canvas.Children.Add($t);return $t}
function Get-AccountEmail($Account){if($Account.email){return [string]$Account.email};if($Account.name -match '@'){return [string]$Account.name};return ''}
function Get-DisplayName($Account){
$email=Get-AccountEmail $Account;if($email -notmatch '^([^@]+)@(.+)$'){if($Account.name){return [string]$Account.name};return '邮箱未知'}
$local=$matches[1];$domain=$matches[2];$prefix=$local.Substring(0,[Math]::Min(4,$local.Length));$peers=@($script:Accounts|Where-Object {[string]$_.id -ne [string]$Account.id}|ForEach-Object {Get-AccountEmail $_}|Where-Object {$_ -match ('^'+[regex]::Escape($prefix)+'.*@'+[regex]::Escape($domain)+'$')})
$suffix='';if($peers.Count){$n=[Math]::Min(2,$local.Length);$suffix=$local.Substring($local.Length-$n);while($n -lt $local.Length -and @($peers|Where-Object {($_ -split '@')[0].EndsWith($suffix)}).Count){$n++;$suffix=$local.Substring($local.Length-$n)}}
if($local.Length -le 4 -and -not $suffix){return $local+'@'+$domain};return $prefix+'…'+$suffix+'@'+$domain
}
function Get-PlanLabel($Account,$Usage){$plan=if($Usage -and $Usage.plan_type){[string]$Usage.plan_type}else{[string]$Account.plan_type};switch($plan.ToLowerInvariant()){'plus'{return 'Plus'};'pro'{return 'Pro'};'prolite'{return 'Pro Lite'};default{return '未知'}}}
function New-Dial($Account){
$id=[string]$Account.id;$current=$id -eq $script:ActiveId;$wrap=[Windows.Controls.StackPanel]::new();$wrap.Margin='0,6,0,3'
$canvas=[Windows.Controls.Canvas]::new();$canvas.Width=168;$canvas.Height=186
$track=[Windows.Shapes.Ellipse]::new();$track.Width=160;$track.Height=160;$track.Stroke='#7D8589';$track.StrokeThickness=8
[Windows.Controls.Canvas]::SetLeft($track,4);[Windows.Controls.Canvas]::SetTop($track,4);[void]$canvas.Children.Add($track)
$record=$script:Usage[$id];$usage=if($record){$record.Data}else{$null}
foreach($primary in @($true,$false)){
$prefix=if($primary){'primary'}else{'secondary'};$color=if($primary){'#9EC5A2'}else{'#DDB783'};$used=if($usage){$usage.($prefix+'_used_percent')}else{$null};$reset=if($usage){$usage.($prefix+'_resets_at')}else{$null}
$remaining=if($null -ne $used){[Math]::Max(0,[Math]::Min(100,100-[double]$used))}else{$null}
if($null -ne $remaining -and $remaining -gt 0){$path=[Windows.Shapes.Path]::new();$path.Data=Get-ArcGeometry $remaining $primary;$path.Stroke=$color;$path.StrokeThickness=8;$path.StrokeStartLineCap='Flat';$path.StrokeEndLineCap='Flat';[void]$canvas.Children.Add($path)}
$label=if($primary){'5h'}else{'周'};$value=if($null -ne $remaining){'{0:0}%' -f $remaining}else{'—'};$y=if($primary){28}else{105};$t=Add-CanvasText $canvas "$label $value" $y 16 $color;$t.FontWeight='SemiBold'
$r=Add-CanvasText $canvas (Reset-Label $reset) ($y+24) 11 '#D2D7D7'
if($reset){$r.ToolTip=[DateTimeOffset]::FromUnixTimeSeconds([long]$reset).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')}
}
# Two short radial strokes separate the upper/lower measures without opening the circular track.
foreach($edge in @(8,160)){$separator=[Windows.Shapes.Line]::new();$separator.Tag='RingSeparator';$separator.X1=$edge-4;$separator.X2=$edge+4;$separator.Y1=84;$separator.Y2=84;$separator.Stroke='#E7EBE9';$separator.StrokeThickness=2;$separator.StrokeStartLineCap='Flat';$separator.StrokeEndLineCap='Flat';$separator.IsHitTestVisible=$false;[void]$canvas.Children.Add($separator)}
$button=[Windows.Controls.Button]::new();$button.Width=65;$button.Height=25;$button.FontSize=11;$button.Tag=$id;$button.Content=if($current){'● 当前'}else{'切换'};$button.Background=if($current){'#495156'}else{'#467953'};$button.BorderThickness=0
$button.IsEnabled=(-not $current -and $null -eq $script:SwitchState -and $script:ActiveId -ne '')
if($script:SwitchState -and $script:SwitchState.TargetId -eq $id){$button.Content='切换中…'}
if(-not $current){$button.ToolTip='切换到此账号（将重启 Codex）';$button.Add_Click({param($sender,$e) Start-AccountSwitch ([string]$sender.Tag)})}
[Windows.Controls.Canvas]::SetLeft($button,51.5);[Windows.Controls.Canvas]::SetTop($button,72);[void]$canvas.Children.Add($button)
# Move the entire circle down, reserving a separate upper-right corner for the plan capsule.
foreach($child in $canvas.Children){$top=[Windows.Controls.Canvas]::GetTop($child);if([double]::IsNaN($top)){$top=0};[Windows.Controls.Canvas]::SetTop($child,$top+18)}
$badge=[Windows.Controls.Border]::new();$badge.Tag='PlanBadge';$badge.Height=17;$badge.CornerRadius=6;$badge.Background='#343C3F';$badge.BorderBrush='#4F595C';$badge.BorderThickness=1;$badge.Padding='5,0,5,0';$badgeText=[Windows.Controls.TextBlock]::new();$badgeText.Text=Get-PlanLabel $Account $usage;$badgeText.Foreground='#D3DCD8';$badgeText.FontSize=10;$badgeText.VerticalAlignment='Center';$badge.Child=$badgeText;$badge.Measure([Windows.Size]::new(168,17));$badge.Width=[Math]::Ceiling($badge.DesiredSize.Width);[Windows.Controls.Canvas]::SetLeft($badge,168-$badge.Width);[Windows.Controls.Canvas]::SetTop($badge,0);[void]$canvas.Children.Add($badge);[void]$wrap.Children.Add($canvas)
$name=[Windows.Controls.TextBlock]::new();$name.Text=Get-DisplayName $Account;$name.Foreground='#F0F1EF';$name.FontSize=12;$name.FontWeight='SemiBold';$name.TextAlignment='Center';$name.Margin='0,1,0,4';$name.Width=168;$name.TextWrapping='Wrap'
# Keep full domain readable; unusually long addresses wrap below the circle rather than shrinking.
$email=Get-AccountEmail $Account;$name.ToolTip=$email;[void]$wrap.Children.Add($name)
if($record -and ($record.Error -or ($script:Now-$record.At) -gt 120)){$warning=[Windows.Controls.TextBlock]::new();$warning.Text=if($record.Data){'旧数据 · '+[DateTimeOffset]::FromUnixTimeSeconds($record.At).ToLocalTime().ToString('HH:mm')}else{'用量暂不可用'};$warning.Foreground='#E6BB92';$warning.FontSize=9;$warning.TextAlignment='Center';$warning.ToolTip=$record.Error;[void]$wrap.Children.Add($warning)}
return $wrap
}
function Get-WorkArea {
$fallback=[Windows.SystemParameters]::WorkArea
try{$source=[Windows.PresentationSource]::FromVisual($window);if(-not $source){return $fallback};$to=$source.CompositionTarget.TransformToDevice;$from=$source.CompositionTarget.TransformFromDevice;$pt=$to.Transform([Windows.Point]::new($window.Left+100,$window.Top+30));$screen=[Windows.Forms.Screen]::FromPoint([Drawing.Point]::new([int]$pt.X,[int]$pt.Y));$a=$screen.WorkingArea;return [Windows.Rect]::new($from.Transform([Windows.Point]::new($a.Left,$a.Top)),$from.Transform([Windows.Point]::new($a.Right,$a.Bottom)))}catch{return $fallback}
}
function Update-View {
$script:Now=if($TestMode){$script:Now}else{[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()};$offset=$ExtraScroll.VerticalOffset;$CurrentHost.Children.Clear();$ExtraHost.Children.Clear()
$active=@($script:Accounts|Where-Object {[string]$_.id -eq $script:ActiveId})
if($active.Count){[void]$CurrentHost.Children.Add((New-Dial $active[0]))}else{$t=[Windows.Controls.TextBlock]::new();$t.Text=if($script:Accounts.Count){'活动账号未知，请刷新'}else{'正在读取账号…'};$t.Foreground='#D2D7D7';$t.Height=201;$t.TextAlignment='Center';[void]$CurrentHost.Children.Add($t)}
foreach($account in $script:Accounts){if([string]$account.id -ne $script:ActiveId){[void]$ExtraHost.Children.Add((New-Dial $account))}}
$ToggleButton.Content=if($script:Expanded){'收起其他账号  ︿'}else{'展开其他账号  ﹀'};$ToggleButton.IsEnabled=$script:Accounts.Count -gt 1
$ExtraScroll.Visibility=if($script:Expanded){'Visible'}else{'Collapsed'};$StatusText.Text=$script:Status;$StatusText.Visibility=if($script:Status){'Visible'}else{'Collapsed'}
$CurrentHost.Measure([Windows.Size]::new(178,1000));$base=28+$CurrentHost.DesiredSize.Height+30+18+$(if($script:Status){32}else{0})
$area=Get-WorkArea;$available=[Math]::Max($base,$area.Bottom-$window.Top);$height=$base
if($script:Expanded){$ExtraHost.Measure([Windows.Size]::new(178,5000));$height=[Math]::Min($available,$base+$ExtraHost.DesiredSize.Height)}
$window.Height=[Math]::Ceiling($height);$window.UpdateLayout();$ExtraScroll.ScrollToVerticalOffset($offset)
}
function Save-Settings {if($TestMode){return};try{@{version=2;width=200;left=$window.Left;top=$window.Top;aliases=$script:Aliases}|ConvertTo-Json -Depth 3|Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8}catch{}}
function Fit-Window {$area=Get-WorkArea;$window.Left=[Math]::Max($area.Left,[Math]::Min($window.Left,$area.Right-$window.Width));$window.Top=[Math]::Max($area.Top,[Math]::Min($window.Top,$area.Bottom-$window.Height))}
function Export-Render([string]$Path){$window.UpdateLayout();$bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Create($Path);try{$encoder.Save($stream)}finally{$stream.Dispose()}}
function Begin-Worker([string]$Kind,[string]$Id,[scriptblock]$Code,[object[]]$Arguments){$ps=[PowerShell]::Create();[void]$ps.AddScript($Code.ToString());foreach($a in $Arguments){[void]$ps.AddArgument($a)};$async=$ps.BeginInvoke();[void]$script:Jobs.Add([pscustomobject]@{PS=$ps;Async=$async;Kind=$Kind;Id=$Id;Generation=$script:Generation})}
$script:ApiWorker={param($command,$id,$port,$switcherExecutable)
$ErrorActionPreference='Stop';$base="http://127.0.0.1:$port"
if($command -eq 'list'){
try{$health=Invoke-RestMethod "$base/api/health" -TimeoutSec 2}catch{$health=$null}
if(-not $health.ok){
if(-not $switcherExecutable -or -not (Test-Path -LiteralPath $switcherExecutable)){throw 'Install Codex Switcher browser-mode service or configure SwitcherExecutable.'}
$env:CODEX_SWITCHER_WEB_HOST='127.0.0.1';$env:CODEX_SWITCHER_WEB_PORT=[string]$port
Start-Process -FilePath $switcherExecutable -WindowStyle Hidden | Out-Null
for($attempt=0;$attempt -lt 20;$attempt++){Start-Sleep -Milliseconds 250;try{$health=Invoke-RestMethod "$base/api/health" -TimeoutSec 1;if($health.ok){break}}catch{}}
if(-not $health.ok){throw 'Codex Switcher local service did not become available.'}
}
$raw=Invoke-RestMethod -Method Post -Uri "$base/api/invoke/list_accounts" -ContentType 'application/json' -Body '{}' -TimeoutSec 12
$accounts=@(foreach($a in $raw){$a})
$active=Invoke-RestMethod -Method Post -Uri "$base/api/invoke/get_active_account_info" -ContentType 'application/json' -Body '{}' -TimeoutSec 12
return [pscustomobject]@{Accounts=$accounts;ActiveId=[string]$active.id}
}
$raw=Invoke-RestMethod -Method Post -Uri "$base/api/invoke/get_usage" -ContentType 'application/json' -Body (@{accountId=$id}|ConvertTo-Json -Compress) -TimeoutSec 35
foreach($item in $raw){if($item.error){throw '账号用量接口返回错误，请在 Switcher 检查登录状态。'};return $item}
}
function Refresh-Widget {if($script:SwitchState -or @($script:Jobs|Where-Object Kind -eq 'list').Count){return};$script:NextRefresh=[datetime]::Now.AddSeconds(60);$RefreshButton.IsEnabled=$false;Begin-Worker 'list' '' $script:ApiWorker @('list','',$script:WidgetConfig.ApiPort,$script:WidgetConfig.SwitcherExecutable)}
function Apply-UsageResult([string]$Id,$Data,[string]$ErrorText){$old=$script:Usage[$Id];if($ErrorText){$script:Usage[$Id]=[pscustomobject]@{Data=$(if($old){$old.Data}else{$null});At=$(if($old){$old.At}else{0});Error=$ErrorText}}else{$script:Usage[$Id]=[pscustomobject]@{Data=$Data;At=$script:Now;Error=''}}}
$script:CleanupWorker={param($name,$resultPath) Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue;if($resultPath -and (Test-Path -LiteralPath $resultPath)){Remove-Item -LiteralPath $resultPath -ErrorAction SilentlyContinue}}
function Finish-Switch([bool]$Success,[string]$Message){$state=$script:SwitchState;if(-not $state){return}
if($Success){$script:ActiveId=$state.TargetId;$script:Expanded=$false;$script:Status=''}else{$script:Expanded=$true;$script:Status=$Message;$script:SwitchError=$Message};$script:SwitchState=$null;Update-View
if(-not $TestMode){Begin-Worker 'cleanup' '' $script:CleanupWorker @($state.TaskName,$state.ResultPath);if($Success){Refresh-Widget}}
}
function Start-AccountSwitch([string]$TargetId){
if($script:SwitchState -or $TargetId -eq $script:ActiveId){return};if(@($script:Accounts|Where-Object {[string]$_.id -eq $TargetId}).Count -ne 1){$script:Status='目标账号已失效，请刷新';Update-View;return}
if(-not $TestMode -and $TargetId -notmatch '^[a-zA-Z0-9_-]+$'){return}
Save-Settings
$requestId=[guid]::NewGuid().ToString('N');$script:Generation++;$script:SwitchError='';$script:SwitchState=[pscustomobject]@{TargetId=$TargetId;TaskName=('Codex-FloatingWidget-Public-Switch-'+$requestId);RequestId=$requestId;ResultPath=(Join-Path $script:StateDirectory ('switch-results\'+$requestId+'.json'));Started=[datetime]::Now;Polling=$false};$script:Status='';Update-View
if($TestMode){$script:TestSwitchLaunchCount++;return}
try{
$arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$script:SwitchController+'" -ConfigPath "'+$script:WidgetConfig.ConfigPath+'" -AccountId "'+$TargetId+'" -RestoreWidget -RequestId "'+$script:SwitchState.RequestId+'" -ResultPath "'+$script:SwitchState.ResultPath+'"'
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $script:SwitchState.TaskName -Action $action -Principal $principal -Settings $settings -Force|Out-Null
Start-ScheduledTask -TaskName $script:SwitchState.TaskName
}catch{Finish-Switch $false '无法启动切换任务，请检查切换脚本'}
}
$script:SwitchWorker={param($name,$started,$target,$resultPath,$requestId,$port=3210)
$ErrorActionPreference='Stop'
# Scheduler may remain Running for launched descendants: controller result is authoritative.
$hasResult=$resultPath -and (Test-Path -LiteralPath $resultPath)
if($hasResult){
try{$result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json}catch{return 'pending'}
if($result.request_id -ne $requestId -or $result.target_id -ne $target -or [long]$result.completed_at -lt ([DateTimeOffset]$started).ToUnixTimeSeconds()-2){return 'pending'}
if($result.success -ne $true){return 'failed'}
}else{
if([datetime]::Now -lt ([datetime]$started).AddMinutes(2)){return 'pending'}
# Only the exceptional missing-result path queries Scheduler, still off the UI thread.
try{$tasks=@(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue);if(-not $tasks.Count){return 'failed'};$task=$tasks[0];$info=Get-ScheduledTaskInfo -TaskName $name -ErrorAction Stop}catch{return 'pending'}
if($task.State -eq 'Running' -or $task.State -eq 'Queued'){return 'pending'}
if($info.LastRunTime -lt ([datetime]$started).AddSeconds(-2) -or $info.LastTaskResult -ne 0){return 'failed'}
}
try{$active=Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/api/invoke/get_active_account_info" -ContentType 'application/json' -Body '{}' -TimeoutSec 2}catch{return 'pending'}
if([string]$active.id -eq $target){return 'success'};return 'pending'
}
function Poll-Workers {
foreach($job in @($script:Jobs.ToArray())){if(-not $job.Async.IsCompleted){continue};$result=$null;$errorText='';try{$result=$job.PS.EndInvoke($job.Async);if($job.PS.HadErrors){$errorText='请求失败，请检查 Switcher 登录或网络'}}catch{$errorText='请求失败，请检查 Switcher 登录或网络'}finally{$job.PS.Dispose();[void]$script:Jobs.Remove($job)}
if($job.Generation -ne $script:Generation -and $job.Kind -in @('list','switch')){if($job.Kind -eq 'list'){$RefreshButton.IsEnabled=$true;$script:NextRefresh=[datetime]::MinValue};continue};if($job.Kind -eq 'list'){$RefreshButton.IsEnabled=$true;if($errorText){$script:Status='账号同步失败，请刷新重试'}else{$data=$result[0];$script:Accounts=@($data.Accounts);if(-not $script:SwitchState){$script:ActiveId=$data.ActiveId;if(@($script:Accounts|Where-Object {[string]$_.id -eq $script:ActiveId}).Count -ne 1){$script:ActiveId=''}};$script:Status=$script:SwitchError;foreach($a in $script:Accounts){$null=Get-DisplayName $a;if(-not @($script:Jobs|Where-Object {$_.Kind -eq 'usage' -and $_.Id -eq [string]$a.id}).Count){Begin-Worker 'usage' ([string]$a.id) $script:ApiWorker @('usage',[string]$a.id,$script:WidgetConfig.ApiPort,$script:WidgetConfig.SwitcherExecutable)}}};Update-View}
elseif($job.Kind -eq 'usage'){Apply-UsageResult $job.Id $(if($result.Count){$result[0]}else{$null}) $errorText;Update-View}
elseif($job.Kind -eq 'switch' -and $script:SwitchState){$script:SwitchState.Polling=$false;if($errorText){continue};switch([string]$result[0]){'success'{Finish-Switch $true ''};'failed'{Finish-Switch $false '切换失败，请检查 Switcher 日志'};'mismatch'{Finish-Switch $false '切换后账号不一致，请刷新确认'}}}
}
}
$DragArea.Add_MouseLeftButtonDown({try{$window.DragMove();Fit-Window;Update-View;Save-Settings}catch{}})
$ToggleButton.Add_Click({if(-not $script:Expanded){$area=Get-WorkArea;if($area.Bottom-$window.Top -lt $window.Height+120){$window.Top=[Math]::Max($area.Top,$area.Bottom-$window.Height-120)}};$script:Expanded=-not $script:Expanded;Update-View;Save-Settings})
$RefreshButton.Add_Click({$script:SwitchError='';$script:Status='';Refresh-Widget})
$HideButton.Add_Click({$script:UserHidden=$true;$window.Hide()})
$window.Add_Closing({param($s,$e)if(-not $script:AllowClose){$e.Cancel=$true;$script:UserHidden=$true;$window.Hide()}})
$window.Left=[Windows.SystemParameters]::WorkArea.Right-222;$window.Top=22
if(-not $TestMode -and (Test-Path $script:SettingsPath)){try{$settings=Get-Content $script:SettingsPath -Raw|ConvertFrom-Json;$window.Left=[double]$settings.left;$window.Top=[double]$settings.top;if($settings.aliases){foreach($p in $settings.aliases.PSObject.Properties){$script:Aliases[$p.Name]=[string]$p.Value}}}catch{}}
function Keep-WindowTopmost {
if(-not $window.IsVisible){return}
$window.Topmost=$true
$handle=[Windows.Interop.WindowInteropHelper]::new($window).Handle
[void][CodexWidgetWindowTools]::KeepTopmost($handle)
}
function Update-Lifecycle([bool]$CodexVisible){
if($CodexVisible -and -not $script:WasCodex){$script:UserHidden=$false}
if($CodexVisible -and -not $script:UserHidden){if(-not $window.IsVisible){$window.Show();Fit-Window};Keep-WindowTopmost}elseif(-not $CodexVisible){$window.Hide()}
$script:WasCodex=$CodexVisible
}
if($TestMode){return}
$tray=[Windows.Forms.NotifyIcon]::new();$tray.Icon=[Drawing.SystemIcons]::Application;$tray.Text='Codex 用量';$tray.Visible=$true
$menu=[Windows.Forms.ContextMenuStrip]::new();$show=$menu.Items.Add('显示悬浮窗');$show.Add_Click({$script:UserHidden=$false;$window.Show();Fit-Window});$exit=$menu.Items.Add('退出');$exit.Add_Click({Save-Settings;$script:AllowClose=$true;$window.Close();$application.Shutdown()});$tray.ContextMenuStrip=$menu;$tray.Add_DoubleClick({$script:UserHidden=$false;$window.Show();Fit-Window})
$timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(300);$script:TickCount=0
$timer.Add_Tick({try{Poll-Workers;$script:TickCount++;if($script:TickCount%3 -eq 0){Update-Lifecycle (Test-WidgetCodexVisible)
if($script:SwitchState){if([datetime]::Now -gt $script:SwitchState.Started.AddMinutes(2) -and $script:Status -ne '切换仍未确认，正在等待结果'){$script:Status='切换仍未确认，正在等待结果';Update-View};if(-not $script:SwitchState.Polling){$script:SwitchState.Polling=$true;Begin-Worker 'switch' '' $script:SwitchWorker @($script:SwitchState.TaskName,$script:SwitchState.Started,$script:SwitchState.TargetId,$script:SwitchState.ResultPath,$script:SwitchState.RequestId,$script:WidgetConfig.ApiPort)}}
if([datetime]::Now -ge $script:NextRefresh){Refresh-Widget}
};if($script:TickCount%100 -eq 0){Update-View;Save-Settings}}catch{$script:Status='暂时无法更新，请刷新重试';Update-View}})
$window.Add_SourceInitialized({Update-View;Fit-Window;Save-Settings})
$window.Add_IsVisibleChanged({if($window.IsVisible){Keep-WindowTopmost}})
try{$window.Show();if($StartHidden -or -not (Test-WidgetCodexVisible)){$window.Hide()};$timer.Start();Refresh-Widget;[void]$application.Run()}finally{$timer.Stop();$tray.Dispose();if($script:SwitchState){try{Unregister-ScheduledTask -TaskName $script:SwitchState.TaskName -Confirm:$false -ErrorAction SilentlyContinue}catch{}};foreach($job in $script:Jobs){$job.PS.Stop();$job.PS.Dispose()};if($script:Mutex){$script:Mutex.ReleaseMutex();$script:Mutex.Dispose()}}
