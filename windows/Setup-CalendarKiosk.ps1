#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Turns a Windows mini PC (e.g. Intel Compute Stick STK2M3W64CC) into a plug-and-play
    family calendar display: power on -> auto-login -> calendar full screen in Edge.

.DESCRIPTION
    - Creates a local standard account (default "Calendar") that logs in automatically
    - Launches Edge in full-screen kiosk mode at logon and relaunches it if it ever closes
    - Never sleeps / never turns the screen off; quiets Edge first-run, promos and notifications
    - Reboots weekly (Sunday 4 AM) to keep things fresh
    Run it again any time to change the URL. Use -Uninstall to undo.

.EXAMPLE
    .\Setup-CalendarKiosk.ps1 -Url 'https://family-calendar.you.workers.dev/?key=abc123' -TimeZone 'Pacific Standard Time'

.EXAMPLE
    .\Setup-CalendarKiosk.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Install')][string]$Url,
    [Parameter(ParameterSetName = 'Install')][string]$KioskUser = 'Calendar',
    [Parameter(ParameterSetName = 'Install')][string]$TimeZone = '',
    [Parameter(ParameterSetName = 'Install')][int]$RebootHour = 4,   # weekly reboot hour (Sunday); -1 to skip
    [Parameter(Mandatory, ParameterSetName = 'Uninstall')][switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$Root      = 'C:\FamilyCalendar'
$Winlogon  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$TaskKiosk = 'FamilyCalendarKiosk'
$TaskBoot  = 'FamilyCalendarWeeklyReboot'

function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    Write-Host '==> Removing calendar kiosk setup' -ForegroundColor Cyan
    Unregister-ScheduledTask -TaskName $TaskKiosk -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskBoot  -Confirm:$false -ErrorAction SilentlyContinue
    Set-Reg $Winlogon 'AutoAdminLogon' '0' 'String'
    Remove-ItemProperty -Path $Winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    Write-Host 'Auto-login and kiosk tasks removed. The local account and C:\FamilyCalendar were left in place;'
    Write-Host 'delete them with:  Remove-LocalUser Calendar; Remove-Item C:\FamilyCalendar -Recurse'
    return
}

if ($Url -notmatch '^https?://') { throw "Url must start with https:// (got '$Url')" }

$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found. Install or update Edge first, then run this again.' }

New-Item -ItemType Directory -Path $Root -Force | Out-Null

# ---------------------------------------------------------------- time zone
if ($TimeZone) {
    Write-Host "==> Setting time zone to $TimeZone" -ForegroundColor Cyan
    Set-TimeZone -Id $TimeZone
}

# ---------------------------------------------------------------- kiosk account + auto-login
Write-Host "==> Setting up auto-login account '$KioskUser'" -ForegroundColor Cyan
$chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
$plain = -join (1..20 | ForEach-Object { $chars | Get-Random })
$secure = ConvertTo-SecureString $plain -AsPlainText -Force

if (Get-LocalUser -Name $KioskUser -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $KioskUser -Password $secure -PasswordNeverExpires $true
} else {
    New-LocalUser -Name $KioskUser -Password $secure -FullName 'Family Calendar' `
        -Description 'Calendar display (auto-login)' -PasswordNeverExpires -AccountNeverExpires | Out-Null
}
$usersGroup = (Get-LocalGroup -SID 'S-1-5-32-545').Name   # "Users", in any language
if (-not (Get-LocalGroupMember -Group $usersGroup -Member $KioskUser -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group $usersGroup -Member $KioskUser
}

Set-Reg $Winlogon 'AutoAdminLogon'    '1'                  'String'
Set-Reg $Winlogon 'DefaultUserName'   $KioskUser           'String'
Set-Reg $Winlogon 'DefaultDomainName' $env:COMPUTERNAME    'String'
Set-Reg $Winlogon 'DefaultPassword'   $plain               'String'
Remove-ItemProperty -Path $Winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
# Allow password auto-login even if "Windows Hello sign-in only" was turned on
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' 'DevicePasswordLessBuildVersion' 0

# ---------------------------------------------------------------- kiosk launcher
Write-Host '==> Writing kiosk launcher' -ForegroundColor Cyan
$launcher = @'
# Family Calendar kiosk launcher - started at logon by the FamilyCalendarKiosk task.
$Url  = '__URL__'
$Edge = '__EDGE__'
$ProfileDir = Join-Path $env:LOCALAPPDATA 'FamilyCalendarEdge'

# Wait up to ~2 minutes for the network after boot
for ($i = 0; $i -lt 60; $i++) {
    try { if ((Invoke-WebRequest -Uri 'https://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 3).StatusCode -eq 200) { break } } catch { }
    Start-Sleep -Seconds 2
}

# Relaunch Edge if it ever closes or crashes
while ($true) {
    $edgeArgs = @('--kiosk', "`"$Url`"", '--edge-kiosk-type=fullscreen', '--no-first-run',
              '--disable-features=Translate', "--user-data-dir=`"$ProfileDir`"")
    $p = Start-Process -FilePath $Edge -ArgumentList $edgeArgs -PassThru
    $p.WaitForExit()
    Start-Sleep -Seconds 5
}
'@
$launcher = $launcher.Replace('__URL__', $Url.Replace("'", "''")).Replace('__EDGE__', $edge.Replace("'", "''"))
Set-Content -Path "$Root\kiosk.ps1" -Value $launcher -Encoding UTF8

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Root\kiosk.ps1`""
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$KioskUser"
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$KioskUser" -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskKiosk -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'Opens the family calendar full screen' -Force | Out-Null

# ---------------------------------------------------------------- power
Write-Host '==> Never sleep, never turn off the screen' -ForegroundColor Cyan
powercfg /change monitor-timeout-ac 0   | Out-Null
powercfg /change standby-timeout-ac 0   | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
powercfg /hibernate off                 | Out-Null

# ---------------------------------------------------------------- quiet Edge + Windows
Write-Host '==> Quieting Edge popups and Windows notifications' -ForegroundColor Cyan
$edgePol = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
@{
    HideFirstRunExperience = 1; StartupBoostEnabled = 0; BackgroundModeEnabled = 0
    TranslateEnabled = 0; BrowserSignin = 0; SyncDisabled = 1; PasswordManagerEnabled = 0
    ShowRecommendationsEnabled = 0; PromotionalTabsEnabled = 0; EdgeShoppingAssistantEnabled = 0
    SpotlightExperiencesAndRecommendationsEnabled = 0; DefaultNotificationsSetting = 2
    HubsSidebarEnabled = 0; AutoImportAtFirstRun = 4
}.GetEnumerator() | ForEach-Object { Set-Reg $edgePol $_.Key $_.Value }

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'     'DisableNotificationCenter' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
Set-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursStart' 5
Set-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'ActiveHoursEnd'   23

# ---------------------------------------------------------------- weekly reboot
if ($RebootHour -ge 0) {
    Write-Host "==> Weekly reboot: Sundays at ${RebootHour}:00" -ForegroundColor Cyan
    $a = New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '/r /t 60 /c "Weekly calendar refresh"'
    $t = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At ([datetime]::Today.AddHours($RebootHour))
    Register-ScheduledTask -TaskName $TaskBoot -Action $a -Trigger $t -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
} else {
    Unregister-ScheduledTask -TaskName $TaskBoot -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Done!' -ForegroundColor Green
Write-Host " Kiosk account : $KioskUser   (password: $plain - you won't normally need it)"
Write-Host " Calendar URL  : $Url"
Write-Host ''
Write-Host 'Reboot now with:  Restart-Computer'
Write-Host 'To get back to your admin account: Ctrl+Alt+Del -> Sign out, and HOLD SHIFT while it signs out.'
