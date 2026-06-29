# Resolve-AMDMismatch.ps1
# Detects and resolves AMD display driver mismatches, with Hardware ID blocking.

$ErrorActionPreference = "Stop"

# 1. Privilege Validation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host "--- AMD Driver & Control Panel Diagnostic Tool ---" -ForegroundColor Cyan
if (-not $isAdmin) {
    Write-Host "Mode: Non-Administrator (Detection and Manual Guidance)" -ForegroundColor Yellow
} else {
    Write-Host "Mode: Administrator (Full Automation Available)" -ForegroundColor Green
}

# 2. Hardware and Active Driver Detection
$gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "AMD|Radeon" }
if (-not $gpu) {
    Write-Host "No AMD GPU detected on this system. Exiting." -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    exit
}

$activeDriver = $gpu.DriverVersion
Write-Host "Detected GPU: $($gpu.Name)"
Write-Host "Active Driver Version: $activeDriver"

# Retrieve specific Hardware ID for policy blocking
$pnpDevice = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -eq $gpu.PNPDeviceID }
$hardwareId = $pnpDevice.HardwareID[0]

# 3. Registry Target Detection
$regPath = "HKLM:\SOFTWARE\AMD\CN"
$expectedDriver = "Unknown"

if (Test-Path $regPath) {
    $expectedDriverValue = (Get-ItemProperty -Path $regPath -Name "DriverVersion" -ErrorAction SilentlyContinue).DriverVersion
    if ($expectedDriverValue) {
        $expectedDriver = $expectedDriverValue
    }
}
Write-Host "Control Panel Expects: $expectedDriver"

if ($activeDriver -ne $expectedDriver -and $expectedDriver -ne "Unknown") {
    Write-Host "STATUS: MISMATCH DETECTED`n" -ForegroundColor Red
} else {
    Write-Host "STATUS: NO MISMATCH DETECTED (or Control Panel not installed)`n" -ForegroundColor Green
    Write-Host "System state is normal. No action required."
    Read-Host "Press Enter to exit..."
    exit
}

# 4. Manual Instruction Function
function Show-ManualInstructions {
    param($GpuName, $Active, $Expected)
    
    Write-Host "====================================================================" -ForegroundColor Cyan
    Write-Host " MANUAL RESOLUTION INSTRUCTIONS " -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host "====================================================================" -ForegroundColor Cyan
    
    Write-Host "INFO: " -NoNewline -ForegroundColor Yellow
    Write-Host "The mismatch error typically does not appear if the Control Panel version is newer than the active driver.`n" -ForegroundColor Gray
    
    Write-Host "1. " -NoNewline -ForegroundColor Cyan; Write-Host "Press Win + X and select " -NoNewline; Write-Host "Device Manager" -ForegroundColor Yellow -NoNewline; Write-Host "."
    Write-Host "2. " -NoNewline -ForegroundColor Cyan; Write-Host "Expand the " -NoNewline; Write-Host "Display adapters " -ForegroundColor Yellow -NoNewline; Write-Host "category."
    Write-Host "3. " -NoNewline -ForegroundColor Cyan; Write-Host "Double-click on " -NoNewline; Write-Host "$GpuName " -ForegroundColor Yellow -NoNewline; Write-Host "to open properties."
    Write-Host "4. " -NoNewline -ForegroundColor Cyan; Write-Host "Navigate to the " -NoNewline; Write-Host "Driver " -ForegroundColor Yellow -NoNewline; Write-Host "tab."
    Write-Host "   -> Your currently active driver is: " -NoNewline; Write-Host "$Active" -ForegroundColor Green
    Write-Host "5. " -NoNewline -ForegroundColor Cyan; Write-Host "Click " -NoNewline; Write-Host "Update driver -> Browse my computer for drivers" -ForegroundColor Yellow -NoNewline; Write-Host "."
    Write-Host "6. " -NoNewline -ForegroundColor Cyan; Write-Host "Select " -NoNewline; Write-Host "Let me pick from a list of available drivers..." -ForegroundColor Yellow
    Write-Host "7. " -NoNewline -ForegroundColor Cyan; Write-Host "You will see a list of installed driver versions."
    Write-Host "   -> To fix the mismatch, select the version expected by the control panel: " -NoNewline; Write-Host "$Expected" -ForegroundColor Green
    Write-Host "   -> If that specific version is missing, select any version that is DIFFERENT from $Active."
    Write-Host "8. " -NoNewline -ForegroundColor Cyan; Write-Host "Click " -NoNewline; Write-Host "Next" -ForegroundColor Yellow -NoNewline; Write-Host ". The screen will flash black during the restart."
    Write-Host "9. " -NoNewline -ForegroundColor Cyan; Write-Host "Open AMD Radeon Software. It should now function normally."
    Write-Host "====================================================================`n" -ForegroundColor Cyan
}

# 5. Non-Admin Handling & Self-Escalation
if (-not $isAdmin) {
    Show-ManualInstructions -GpuName $gpu.Name -Active $activeDriver -Expected $expectedDriver
    
    $elevate = Read-Host "Would you like to restart this script as Administrator to enable automated fixes and blocks? [Y/N]"
    if ($elevate -match '^[Yy]') {
        Write-Host "Requesting elevation..." -ForegroundColor Cyan
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    }
    exit 
}

# 6. Driver Store Interrogation
Write-Host "Scanning Windows Driver Store for available AMD Display Drivers..."
$driverStore = Get-WindowsDriver -Online | Where-Object { 
    ($_.ProviderName -match "Advanced Micro Devices" -or $_.ProviderName -match "AMD") -and 
    $_.ClassName -eq "Display" 
}

if ($driverStore) {
    $sortedDrivers = $driverStore | Sort-Object -Property @{Expression={[version]$_.Version}; Descending=$true}
    $newestDriver = $sortedDrivers | Select-Object -First 1
    $oldestDriver = $sortedDrivers | Select-Object -Last 1

    Write-Host "Found $($sortedDrivers.Count) cached AMD driver packages."
    Write-Host " - Newest available: $($newestDriver.Version) ($($newestDriver.Driver))"
    Write-Host " - Oldest available: $($oldestDriver.Version) ($($oldestDriver.Driver))`n"
} else {
    Write-Host "No cached AMD display drivers found in the driver store. Local driver switching is disabled.`n" -ForegroundColor Yellow
}

# 7. Execution Functions
function Install-TargetDriver {
    param([PSCustomObject]$TargetDriverPackage, [string]$Expected)
    
    $infName = $TargetDriverPackage.Driver
    $infVersion = $TargetDriverPackage.Version
    $infPath = Join-Path $env:windir "INF\$infName"

    Write-Host "Target Driver: $infVersion ($infName)" -ForegroundColor Cyan
    Write-Host "WARNING: The screen will flash or go dark temporarily during installation." -ForegroundColor Yellow
    
    for ($i = 5; $i -gt 0; $i--) {
        Write-Host "Installation begins in $i seconds..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
    }
    
    Write-Host "Executing PnP Utility..." -ForegroundColor Cyan
    $process = Start-Process -FilePath "pnputil.exe" -ArgumentList "/add-driver `"$infPath`" /install" -Wait -NoNewWindow -PassThru
    
    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 259) {
        Write-Host "Driver package applied." -ForegroundColor Green
    } else {
        Write-Host "Pnputil returned exit code $($process.ExitCode). Driver update may have failed." -ForegroundColor Red
    }

    Write-Host "`n--- Post-Installation Verification ---" -ForegroundColor Cyan
    Start-Sleep -Seconds 2 
    $newGpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match "AMD|Radeon" }
    $newActive = $newGpu.DriverVersion
    
    Write-Host "Expected Control Panel Version: $Expected"
    Write-Host "New Active Driver Version:    $newActive"
    
    if ($newActive -eq $Expected) {
        Write-Host "Result: SUCCESS (Versions match)" -ForegroundColor Green
    } elseif ($Expected -ne "Unknown" -and [version]$Expected -gt [version]$newActive) {
        Write-Host "Result: OK (Control Panel is newer than active driver)" -ForegroundColor Green
    } else {
        Write-Host "Result: MISMATCH STILL PRESENT" -ForegroundColor Red
    }
}

function Set-HardwareIdBlock {
    param([string]$HwId)
    $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
    $listPath = "$policyPath\DenyDeviceIDs"

    try {
        if (-not (Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
        if (-not (Test-Path $listPath)) { New-Item -Path $listPath -Force | Out-Null }

        Set-ItemProperty -Path $policyPath -Name "DenyDeviceIDs" -Value 1 -Type DWord
        Set-ItemProperty -Path $policyPath -Name "DenyDeviceIDsRetroactive" -Value 0 -Type DWord
        Set-ItemProperty -Path $listPath -Name "1" -Value $HwId -Type String
        
        Write-Host "`n[SUCCESS] Hardware ID Block Applied." -ForegroundColor Green
        Write-Host "Blocked ID: $HwId"
        Write-Host "Windows Update and manual installers are now prevented from updating this device." -ForegroundColor Yellow
    } catch {
        Write-Host "`n[ERROR] Failed to apply registry policies. $_" -ForegroundColor Red
    }
}

function Remove-HardwareIdBlock {
    $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
    
    try {
        if (Test-Path $policyPath) {
            Set-ItemProperty -Path $policyPath -Name "DenyDeviceIDs" -Value 0 -Type DWord
            Remove-Item -Path "$policyPath\DenyDeviceIDs" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "`n[SUCCESS] Hardware ID Block Removed." -ForegroundColor Green
            Write-Host "You can now update the driver normally."
        } else {
            Write-Host "`n[INFO] No active restrictions found." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "`n[ERROR] Failed to remove registry policies. $_" -ForegroundColor Red
    }
}

# 8. Interactive Menu
$menuLoop = $true
while ($menuLoop) {
    Write-Host "`nSelect an action:" -ForegroundColor Cyan
    if ($
