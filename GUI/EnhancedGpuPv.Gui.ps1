#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$SkipAdminRelaunch
)

$ErrorActionPreference = "Stop"

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-STA", "-File", "`"$PSCommandPath`"")
    if ($SkipAdminRelaunch) {
        $arguments += "-SkipAdminRelaunch"
    }
    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:GuiRoot = Split-Path -Parent $PSCommandPath
$script:ProjectRoot = (Resolve-Path (Join-Path $script:GuiRoot "..")).Path
$script:SourceCreateScript = Join-Path $script:ProjectRoot "CopyFilesToVM.ps1"
$script:SourcePreChecksScript = Join-Path $script:ProjectRoot "PreChecks.ps1"
$script:SourceUpdateScript = Join-Path $script:ProjectRoot "Update-VMGpuPartitionDriver.ps1"
$script:GeneratedRoot = Join-Path $script:GuiRoot ".generated"
$script:LogRoot = Join-Path $script:GeneratedRoot "logs"
$script:PreCheckResultPath = Join-Path $script:GeneratedRoot "PreChecks.latest.json"
$script:CurrentProcess = $null
$script:RunInProgress = $false
$script:ActiveOperationName = $null
$script:LogFilePath = $null
$script:ProcessEventHandlers = @()
$script:LogPollTimer = $null
$script:RenderedRunLogText = ""

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not $SkipAdminRelaunch -and -not (Test-IsAdministrator)) {
    $answer = [System.Windows.MessageBox]::Show(
        "Enhanced GPU-PV needs Administrator rights to query Hyper-V and run the scripts. Relaunch as Administrator?",
        "Administrator required",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-STA", "-File", "`"$PSCommandPath`"")
        Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden | Out-Null
    }
    exit
}

[xml]$xaml = Get-Content -LiteralPath (Join-Path $script:GuiRoot "MainWindow.xaml") -Raw
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$script:Window = [Windows.Markup.XamlReader]::Load($reader)

$controlNames = @(
    "StatusText",
    "ProgressPanel",
    "ProgressText",
    "OperationProgressBar",
    "ProgressPercentText",
    "RefreshHostDataButton",
    "RunPreChecksButton",
    "CreateVmButton",
    "PreCheckOverallStatusText",
    "PreCheckLastRunText",
    "PreCheckWarningsText",
    "PreCheckBlockingIssuesText",
    "PreCheckComputerTypeStatusText",
    "PreCheckComputerTypeValueText",
    "PreCheckComputerTypeDetailText",
    "PreCheckWindowsStatusText",
    "PreCheckWindowsValueText",
    "PreCheckWindowsDetailText",
    "PreCheckHyperVStatusText",
    "PreCheckHyperVValueText",
    "PreCheckHyperVDetailText",
    "PreCheckWslStatusText",
    "PreCheckWslValueText",
    "PreCheckWslDetailText",
    "PreCheckGpuStatusText",
    "PreCheckGpuValueText",
    "PreCheckGpuDetailText",
    "VmNameText",
    "IsoPathText",
    "BrowseIsoButton",
    "VhdPathText",
    "BrowseVhdButton",
    "NetworkSwitchCombo",
    "EditionText",
    "DiskSizeText",
    "MemoryText",
    "CpuCoresText",
    "GpuAllocationSlider",
    "GpuAllocationValueText",
    "GpuCombo",
    "InstallProfileCombo",
    "InstallProfileDetailText",
    "UsernameText",
    "PasswordBox",
    "AutologonCheck",
    "LanguageText",
    "TimezoneText",
    "TeamIdText",
    "TeamKeyBox",
    "UpdateVmNameText",
    "UpdateGpuCombo",
    "UpdateDriverButton",
    "NestedVmNameText",
    "EnableNestedVirtualizationButton",
    "RefreshMaintenanceVmListButton",
    "LogTextBox",
    "OpenGeneratedFolderButton",
    "ClearLogButton"
)

$script:Ui = @{}
foreach ($name in $controlNames) {
    $script:Ui[$name] = $script:Window.FindName($name)
}

if ([System.Windows.Application]::Current) {
    [System.Windows.Application]::Current.add_DispatcherUnhandledException({
        param($sender, $eventArgs)

        try {
            Append-Log "GUI error: $($eventArgs.Exception.Message)"
            Add-RunLogLine "GUI error: $($eventArgs.Exception.ToString())"
        }
        catch {
        }

        $eventArgs.Handled = $true
    })
}

function Append-Log {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $Message"
    $script:Ui.LogTextBox.AppendText("$line`r`n")
    $script:Ui.LogTextBox.ScrollToEnd()
}

function Set-Status {
    param([string]$Message)
    $script:Ui.StatusText.Text = $Message
}

function Set-Busy {
    param([bool]$Busy)

    $script:RunInProgress = $Busy

    $controlsToLock = @(
        "RefreshHostDataButton",
        "RunPreChecksButton",
        "CreateVmButton",
        "VmNameText",
        "IsoPathText",
        "BrowseIsoButton",
        "VhdPathText",
        "BrowseVhdButton",
        "NetworkSwitchCombo",
        "EditionText",
        "DiskSizeText",
        "MemoryText",
        "CpuCoresText",
        "GpuAllocationSlider",
        "GpuCombo",
        "InstallProfileCombo",
        "UsernameText",
        "PasswordBox",
        "AutologonCheck",
        "LanguageText",
        "TimezoneText",
        "TeamIdText",
        "TeamKeyBox",
        "UpdateVmNameText",
        "UpdateGpuCombo",
        "UpdateDriverButton",
        "NestedVmNameText",
        "EnableNestedVirtualizationButton",
        "RefreshMaintenanceVmListButton",
        "OpenGeneratedFolderButton",
        "ClearLogButton"
    )

    foreach ($name in $controlsToLock) {
        if ($script:Ui[$name]) {
            $script:Ui[$name].IsEnabled = -not $Busy
        }
    }

    if ($script:Window) {
        $script:Window.Cursor = if ($Busy) { [System.Windows.Input.Cursors]::Wait } else { $null }
    }

    if ($Busy) {
        Set-Status "Running: $script:ActiveOperationName"
    }
    else {
        $script:ActiveOperationName = $null
        Set-Status "Ready"
    }
}

function Set-PreCheckText {
    param(
        [string]$ControlName,
        [AllowNull()][string]$Text,
        [string]$Status
    )

    if (-not $script:Ui[$ControlName]) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        $Text = "-"
    }

    $script:Ui[$ControlName].Text = $Text

    if ($Status) {
        switch -Regex ($Status) {
            '^OK$|^Pass' { $script:Ui[$ControlName].Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(31, 122, 91)); break }
            '^WARN' { $script:Ui[$ControlName].Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(161, 98, 7)); break }
            '^ERROR|^FAIL|^Blocked' { $script:Ui[$ControlName].Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(185, 28, 28)); break }
            default { $script:Ui[$ControlName].Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(101, 115, 110)) }
        }
    }
    else {
        $script:Ui[$ControlName].Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(101, 115, 110))
    }
}

function Set-PreCheckRow {
    param(
        [string]$Prefix,
        [AllowNull()]$Result
    )

    if ($null -eq $Result) {
        Set-PreCheckText "${Prefix}StatusText" "-" $null
        Set-PreCheckText "${Prefix}ValueText" "-" $null
        Set-PreCheckText "${Prefix}DetailText" "-" $null
        return
    }

    Set-PreCheckText "${Prefix}StatusText" ([string]$Result.Status) ([string]$Result.Status)
    Set-PreCheckText "${Prefix}ValueText" ([string]$Result.Value) $null
    Set-PreCheckText "${Prefix}DetailText" ([string]$Result.Detail) $null
}

function Reset-PreCheckResults {
    Set-PreCheckText "PreCheckOverallStatusText" "Pending" $null
    Set-PreCheckText "PreCheckLastRunText" "-" $null
    Set-PreCheckText "PreCheckWarningsText" "-" $null
    Set-PreCheckText "PreCheckBlockingIssuesText" "-" $null
    Set-PreCheckRow "PreCheckComputerType" $null
    Set-PreCheckRow "PreCheckWindows" $null
    Set-PreCheckRow "PreCheckHyperV" $null
    Set-PreCheckRow "PreCheckWsl" $null
    Set-PreCheckRow "PreCheckGpu" $null
}

function Update-PreCheckResultsPanel {
    if (-not (Test-Path -LiteralPath $script:PreCheckResultPath)) {
        Append-Log "PreCheck result file was not found: $script:PreCheckResultPath"
        return
    }

    try {
        $result = Get-Content -LiteralPath $script:PreCheckResultPath -Raw | ConvertFrom-Json
        Set-PreCheckText "PreCheckOverallStatusText" ([string]$result.OverallStatus) ([string]$result.OverallStatus)
        Set-PreCheckText "PreCheckLastRunText" ([string]$result.LastRun) $null
        Set-PreCheckText "PreCheckWarningsText" ([string]$result.Warnings) $(if ([int]$result.Warnings -gt 0) { "WARN" } else { "OK" })
        Set-PreCheckText "PreCheckBlockingIssuesText" ([string]$result.BlockingIssues) $(if ([int]$result.BlockingIssues -gt 0) { "ERROR" } else { "OK" })
        Set-PreCheckRow "PreCheckComputerType" $result.ComputerType
        Set-PreCheckRow "PreCheckWindows" $result.Windows
        Set-PreCheckRow "PreCheckHyperV" $result.HyperV
        Set-PreCheckRow "PreCheckWsl" $result.WSL
        Set-PreCheckRow "PreCheckGpu" $result.GPU
    }
    catch {
        Append-Log "Failed to load PreCheck result panel: $($_.Exception.Message)"
    }
}

function Set-ComboItems {
    param(
        [System.Windows.Controls.ComboBox]$ComboBox,
        [string[]]$Items,
        [string]$SelectedItem,
        [bool]$AllowCustomText = $true
    )

    $ComboBox.Items.Clear()
    foreach ($item in $Items) {
        [void]$ComboBox.Items.Add($item)
    }

    if ($Items -contains $SelectedItem) {
        $ComboBox.SelectedItem = $SelectedItem
    }
    elseif ($AllowCustomText -and -not [string]::IsNullOrWhiteSpace($SelectedItem)) {
        $ComboBox.SelectedIndex = -1
        $ComboBox.Text = $SelectedItem
    }
    elseif ($Items.Count -gt 0) {
        $ComboBox.SelectedIndex = 0
    }
    else {
        $ComboBox.SelectedIndex = -1
        $ComboBox.Text = ""
    }
}

function Get-ComboText {
    param([System.Windows.Controls.ComboBox]$ComboBox)

    if ($null -ne $ComboBox.SelectedItem) {
        return [string]$ComboBox.SelectedItem
    }

    return [string]$ComboBox.Text
}

function Get-HostWindowsInfo {
    $output = @(systeminfo 2>$null)
    $osName = $null
    $osVersion = $null

    foreach ($line in $output) {
        if ($line -match '^\s*OS Name\s*:\s*(.+)$') {
            $osName = $Matches[1].Trim()
        }
        elseif ($line -match '^\s*OS Version\s*:\s*(.+)$') {
            $osVersion = $Matches[1].Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($osName) -or [string]::IsNullOrWhiteSpace($osVersion)) {
        throw "Could not parse OS Name and OS Version from systeminfo."
    }

    $buildNumber = $null
    if ($osVersion -match '(?i)\bBuild\s+(\d+)') {
        $buildNumber = [int]$Matches[1]
    }
    elseif ($osVersion -match '\d+\.\d+\.(\d+)') {
        $buildNumber = [int]$Matches[1]
    }

    if ($null -eq $buildNumber) {
        throw "Could not parse Windows build number from systeminfo OS Version: $osVersion"
    }

    return [pscustomobject]@{
        Name = $osName
        Version = $osVersion
        BuildNumber = $buildNumber
    }
}

function Get-HostWindowsBuildNumber {
    try {
        return (Get-HostWindowsInfo).BuildNumber
    }
    catch {
        Append-Log "Could not read Windows build from systeminfo: $($_.Exception.Message)"
    }

    return [Environment]::OSVersion.Version.Build
}

function Get-PartitionableGpuCandidates {
    $partitionableGpuList = @(Get-WmiObject -Class "Msvm_PartitionableGpu" -ComputerName $env:COMPUTERNAME -Namespace "ROOT\virtualization\v2" -ErrorAction Stop)
    $displayDrivers = @(Get-WmiObject Win32_PNPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceClass -eq "DISPLAY" -and -not [string]::IsNullOrWhiteSpace($_.DeviceName) })

    $candidates = @()
    foreach ($driver in $displayDrivers) {
        $hardwareId = @($driver.HardwareID | Where-Object { $_ -match '^PCI\\' } | Select-Object -First 1)
        if ($hardwareId.Count -eq 0) {
            $hardwareId = @($driver.HardwareID | Select-Object -First 1)
        }

        if ([string]::IsNullOrWhiteSpace($hardwareId[0])) {
            continue
        }

        $split = $hardwareId[0].Split('\')
        if ($split.Count -lt 2) {
            continue
        }

        $deviceId = $split[1]
        if ([string]::IsNullOrWhiteSpace($deviceId)) {
            continue
        }

        if ($partitionableGpuList | Where-Object { $_.Name -like "*$deviceId*" }) {
            $candidates += [pscustomobject]@{
                GPUName = $driver.DeviceName
                DriverVersion = $driver.DriverVersion
            }
        }
    }

    $candidates | Sort-Object GPUName -Unique
}

function Refresh-HostData {
    Append-Log "Refreshing Hyper-V switches, VMs, and partitionable GPUs."

    $switches = @()
    try {
        $switches = @(Get-VMSwitch -ErrorAction Stop | Select-Object -ExpandProperty Name)
    }
    catch {
        Append-Log "Could not query Hyper-V switches: $($_.Exception.Message)"
    }

    if ($switches.Count -eq 0) {
        $switches = @("Default Switch")
    }
    elseif ($switches -notcontains "Default Switch") {
        $switches = @("Default Switch") + $switches
    }

    Set-ComboItems -ComboBox $script:Ui.NetworkSwitchCombo -Items $switches -SelectedItem "Default Switch" -AllowCustomText $false

    $currentUpdateVmName = (Get-ComboText $script:Ui.UpdateVmNameText).Trim()
    $currentNestedVmName = (Get-ComboText $script:Ui.NestedVmNameText).Trim()
    if ([string]::IsNullOrWhiteSpace($currentUpdateVmName)) {
        $currentUpdateVmName = "GPUPV"
    }
    if ([string]::IsNullOrWhiteSpace($currentNestedVmName)) {
        $currentNestedVmName = $currentUpdateVmName
    }

    $vmItems = @()
    try {
        $vmItems = @(Get-VM -ErrorAction Stop | Sort-Object Name | Select-Object -ExpandProperty Name)
    }
    catch {
        Append-Log "Could not query Hyper-V VMs: $($_.Exception.Message)"
    }

    $vmItems = @($vmItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    Set-ComboItems -ComboBox $script:Ui.UpdateVmNameText -Items $vmItems -SelectedItem $currentUpdateVmName -AllowCustomText $false
    Set-ComboItems -ComboBox $script:Ui.NestedVmNameText -Items $vmItems -SelectedItem $currentNestedVmName -AllowCustomText $false

    $gpuItems = @("AUTO")
    try {
        if ((Get-HostWindowsBuildNumber) -ge 22000) {
            $gpuItems += @(Get-PartitionableGpuCandidates | Select-Object -ExpandProperty GPUName)
        }
    }
    catch {
        Append-Log "Could not query partitionable GPUs: $($_.Exception.Message)"
    }

    $gpuItems = @($gpuItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    Set-ComboItems -ComboBox $script:Ui.GpuCombo -Items $gpuItems -SelectedItem "AUTO" -AllowCustomText $false
    Set-ComboItems -ComboBox $script:Ui.UpdateGpuCombo -Items $gpuItems -SelectedItem "AUTO" -AllowCustomText $false
}

function ConvertTo-PowerShellStringLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }

    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-BooleanLiteral {
    param([bool]$Value)

    if ($Value) {
        return '$true'
    }

    return '$false'
}

function ConvertTo-ParamsBlock {
    param([hashtable]$Config)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('$params = @{')
    $lines.Add("    VMName = $(ConvertTo-PowerShellStringLiteral $Config.VMName)")
    $lines.Add("    SourcePath = $(ConvertTo-PowerShellStringLiteral $Config.SourcePath)")
    $lines.Add("    Edition = $($Config.Edition)")
    $lines.Add("    VhdFormat = 'VHDX'")
    $lines.Add("    DiskLayout = 'UEFI'")
    $lines.Add("    SizeBytes = $($Config.SizeBytes)")
    $lines.Add("    MemoryAmount = $($Config.MemoryAmount)")
    $lines.Add("    CPUCores = $($Config.CPUCores)")
    $lines.Add("    NetworkSwitch = $(ConvertTo-PowerShellStringLiteral $Config.NetworkSwitch)")
    $lines.Add("    VHDPath = $(ConvertTo-PowerShellStringLiteral $Config.VHDPath)")
    $lines.Add("    UnattendPath = $(ConvertTo-PowerShellStringLiteral $Config.UnattendPath)")
    $lines.Add("    GPUName = $(ConvertTo-PowerShellStringLiteral $Config.GPUName)")
    $lines.Add("    GPUResourceAllocationPercentage = $($Config.GPUResourceAllocationPercentage)")
    $lines.Add("    Parsec = $(ConvertTo-BooleanLiteral $Config.Parsec)")
    $lines.Add("    ParsecVDA = $(ConvertTo-BooleanLiteral $Config.ParsecVDA)")
    $lines.Add("    Sunshine = $(ConvertTo-BooleanLiteral $Config.Sunshine)")
    $lines.Add("    VirtualDisplayDriver = $(ConvertTo-BooleanLiteral $Config.VirtualDisplayDriver)")
    $lines.Add("    Team_ID = $(ConvertTo-PowerShellStringLiteral $Config.Team_ID)")
    $lines.Add("    Key = $(ConvertTo-PowerShellStringLiteral $Config.Key)")
    $lines.Add("    Username = $(ConvertTo-PowerShellStringLiteral $Config.Username)")
    $lines.Add("    Password = $(ConvertTo-PowerShellStringLiteral $Config.Password)")
    $lines.Add("    Autologon = $(ConvertTo-PowerShellStringLiteral $Config.Autologon)")
    $lines.Add("    Language = $(ConvertTo-PowerShellStringLiteral $Config.Language)")
    $lines.Add("    Timezone = $(ConvertTo-PowerShellStringLiteral $Config.Timezone)")
    $lines.Add('}')

    return ($lines -join [Environment]::NewLine)
}

function Get-PositiveIntFromText {
    param(
        [string]$Value,
        [string]$Name
    )

    $parsed = 0
    if (-not [int]::TryParse($Value, [ref]$parsed) -or $parsed -lt 1) {
        throw "$Name must be a positive whole number."
    }

    return $parsed
}

function Get-CreateConfig {
    $vmName = $script:Ui.VmNameText.Text.Trim()
    $sourcePath = $script:Ui.IsoPathText.Text.Trim()
    $vhdPath = $script:Ui.VhdPathText.Text.Trim()
    $networkSwitch = (Get-ComboText $script:Ui.NetworkSwitchCombo).Trim()
    $gpuName = (Get-ComboText $script:Ui.GpuCombo).Trim()
    $username = $script:Ui.UsernameText.Text.Trim()
    $password = $script:Ui.PasswordBox.Password
    $edition = Get-PositiveIntFromText -Value $script:Ui.EditionText.Text.Trim() -Name "Edition index"
    $diskGb = Get-PositiveIntFromText -Value $script:Ui.DiskSizeText.Text.Trim() -Name "Disk size"
    $memoryGb = Get-PositiveIntFromText -Value $script:Ui.MemoryText.Text.Trim() -Name "Memory"
    $cpuCores = Get-PositiveIntFromText -Value $script:Ui.CpuCoresText.Text.Trim() -Name "CPU cores"

    $errors = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($vmName)) { $errors.Add("VM name is required.") }
    if ($vmName -notmatch '^[a-zA-Z0-9]+$' -or $vmName.Length -gt 15) { $errors.Add("VM name must be alphanumeric and 15 characters or less.") }
    if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path -LiteralPath $sourcePath)) { $errors.Add("Windows ISO path is invalid.") }
    if ([string]::IsNullOrWhiteSpace($vhdPath) -or -not (Test-Path -LiteralPath $vhdPath)) { $errors.Add("VHD folder does not exist.") }
    if ([string]::IsNullOrWhiteSpace($networkSwitch)) { $errors.Add("Network switch is required.") }
    if ([string]::IsNullOrWhiteSpace($gpuName)) { $errors.Add("GPU is required. Use AUTO if unsure.") }
    if ([string]::IsNullOrWhiteSpace($username)) { $errors.Add("Username is required.") }
    if ($username -notmatch '^[a-zA-Z0-9]+$') { $errors.Add("Username must be alphanumeric.") }
    if ($username -eq $vmName) { $errors.Add("Username cannot be the same as VM name.") }
    if ([string]::IsNullOrEmpty($password)) { $errors.Add("Password cannot be blank.") }
    if ((Get-HostWindowsBuildNumber) -lt 22000 -and $gpuName -ne "AUTO") { $errors.Add("Windows 10 hosts must use GPU AUTO.") }

    $installProfile = Get-ComboText $script:Ui.InstallProfileCombo

    $parsec = $false
    $sunshine = $false
    $parsecVda = $false
    $virtualDisplayDriver = $false

    switch ($installProfile) {
        "GPU-PV only" {
        }
        "Parsec + ParsecVDA" {
            $parsec = $true
            $parsecVda = $true
        }
        "Parsec + Virtual Display Driver" {
            $parsec = $true
            $virtualDisplayDriver = $true
        }
        "Sunshine + Virtual Display Driver" {
            $sunshine = $true
            $virtualDisplayDriver = $true
        }
        "Sunshine + ParsecVDA" {
            $sunshine = $true
            $parsecVda = $true
        }
        default {
            $errors.Add("Choose a valid install profile.")
        }
    }

    $countTrue = @($parsec, $sunshine, $parsecVda, $virtualDisplayDriver | Where-Object { $_ }).Count
    if ($countTrue -ne 0 -and $countTrue -ne 2) {
        $errors.Add("Choose either GPU-PV only, or one streamer with one display driver.")
    }
    if ($parsec -and $sunshine) {
        $errors.Add("Choose only one streamer.")
    }
    if ($parsecVda -and $virtualDisplayDriver) {
        $errors.Add("Choose only one display driver.")
    }

    if ($errors.Count -gt 0) {
        throw ($errors -join [Environment]::NewLine)
    }

    return @{
        VMName = $vmName
        SourcePath = $sourcePath
        Edition = $edition
        SizeBytes = [int64]$diskGb * 1GB
        MemoryAmount = [int64]$memoryGb * 1GB
        CPUCores = $cpuCores
        NetworkSwitch = $networkSwitch
        VHDPath = $vhdPath
        UnattendPath = Join-Path $script:ProjectRoot "autounattend.xml"
        GPUName = $gpuName
        GPUResourceAllocationPercentage = [int][Math]::Round($script:Ui.GpuAllocationSlider.Value)
        Parsec = $parsec
        ParsecVDA = $parsecVda
        Sunshine = $sunshine
        VirtualDisplayDriver = $virtualDisplayDriver
        Team_ID = $script:Ui.TeamIdText.Text.Trim()
        Key = $script:Ui.TeamKeyBox.Password
        Username = $username
        Password = $password
        Autologon = if ($script:Ui.AutologonCheck.IsChecked) { "true" } else { "false" }
        Language = $script:Ui.LanguageText.Text.Trim()
        Timezone = $script:Ui.TimezoneText.Text.Trim()
    }
}

function Test-CreateVmAssetFiles {
    $relativePaths = @(
        "Add-VMGpuPartitionAdapterFiles.psm1",
        "autounattend.xml",
        "gpt.ini",
        "User\psscripts.ini",
        "User\Installation with Parsec + ParsecVDA.ps1",
        "User\Installation with Parsec + VirtualDisplayDriverHDR.ps1",
        "User\Installation with Parsec + VirtualDisplayDriver.ps1",
        "User\Installation with Sunshine + ParsecVDA.ps1",
        "User\Installation with Sunshine + VirtualDisplayDriverHDR.ps1",
        "User\Installation with Sunshine + VirtualDisplayDriver.ps1",
        "User\Installation just GPU-PV.ps1",
        "VMScripts\VBCableInstall.ps1",
        "VMScripts\ParsecVDAInstall.ps1",
        "VMScripts\VirtualDisplayDriverInstall.ps1",
        "VMScripts\VirtualDisplayDriverHDRInstall.ps1",
        "VMScripts\Switch Display to ParsecVDA.bat",
        "VMScripts\Switch Display to Virtual Display.bat",
        "VMScripts\ParsecVDA.ico",
        "VMScripts\VirtualDisplayDriver.ico",
        "VMScripts\SwitchDisplayParsecVDA.vbs",
        "VMScripts\SwitchDisplayVDD.vbs",
        "VMScripts\Parsec.lnk",
        "VMScripts\DisableOneDriveAutostart.ps1"
    )

    $missing = @()
    foreach ($relativePath in $relativePaths) {
        $fullPath = Join-Path $script:ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath)) {
            $missing += $relativePath
        }
    }

    if ($missing.Count -gt 0) {
        throw "Create VM cannot start because required project files are missing:`r`n`r`n$($missing -join "`r`n")"
    }
}

function New-GeneratedGpuModule {
    $sourceModule = Join-Path $script:ProjectRoot "Add-VMGpuPartitionAdapterFiles.psm1"
    if (-not (Test-Path -LiteralPath $sourceModule)) {
        throw "Could not find Add-VMGpuPartitionAdapterFiles.psm1 at $sourceModule"
    }

    New-Item -ItemType Directory -Path $script:GeneratedRoot -Force | Out-Null

    $source = Get-Content -LiteralPath $sourceModule -Raw
    $helper = @'
function Get-PnpSignedDriverCimDataFileReliable {
    param([int]$Retries = 4)

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            return @(Get-WmiObject Win32_PNPSignedDriverCIMDataFile -ErrorAction Stop)
        }
        catch {
            if ($_.Exception.Message -match 'Shutting down' -and $attempt -lt $Retries) {
                Write-Host ("WARN   : WMI returned 'Shutting down' while reading driver file associations. Retrying ({0}/{1})..." -f $attempt, $Retries)
                Start-Sleep -Seconds 2
                continue
            }

            throw
        }
    }
}

'@

    $patched = $helper + ($source -replace 'Get-WmiObject\s+Win32_PNPSignedDriverCIMDataFile', 'Get-PnpSignedDriverCimDataFileReliable')
    $target = Join-Path $script:GeneratedRoot ("Add-VMGpuPartitionAdapterFiles.generated.{0}.psm1" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Set-Content -LiteralPath $target -Value $patched -Encoding UTF8
    return $target
}

function New-GeneratedCreateScript {
    param([hashtable]$Config)

    if (-not (Test-Path -LiteralPath $script:SourceCreateScript)) {
        throw "Could not find CopyFilesToVM.ps1 at $script:SourceCreateScript"
    }

    New-Item -ItemType Directory -Path $script:GeneratedRoot -Force | Out-Null

    $source = Get-Content -LiteralPath $script:SourceCreateScript -Raw
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "CopyFilesToVM.ps1 could not be parsed: $($parseErrors[0].Message)"
    }

    $paramsAssignment = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$params'
    }, $true)

    if ($null -eq $paramsAssignment) {
        throw "Could not find the `$params block in CopyFilesToVM.ps1."
    }

    $generatedModule = New-GeneratedGpuModule
    $moduleImportLine = "Import-Module -Name $(ConvertTo-PowerShellStringLiteral $generatedModule)"
    $source = $source -replace '(?m)^\s*Import-Module\s+\$PSSCriptRoot\\Add-VMGpuPartitionAdapterFiles\.psm1\s*$', $moduleImportLine
    $source = $source -replace '(?m)^\s*Import-Module\s+\$PSScriptRoot\\Add-VMGpuPartitionAdapterFiles\.psm1\s*$', $moduleImportLine

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "CopyFilesToVM.ps1 could not be parsed after module import patch: $($parseErrors[0].Message)"
    }

    $paramsAssignment = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$params'
    }, $true)

    if ($null -eq $paramsAssignment) {
        throw "Could not find the `$params block in CopyFilesToVM.ps1."
    }

    $paramsBlock = ConvertTo-ParamsBlock -Config $Config
    $start = $paramsAssignment.Extent.StartOffset
    $length = $paramsAssignment.Extent.EndOffset - $paramsAssignment.Extent.StartOffset
    $generated = $source.Remove($start, $length).Insert($start, $paramsBlock)
    $generated = [regex]::Replace(
        $generated,
        '(?i)\$psscriptroot|\$psscriptroot',
        [System.Text.RegularExpressions.MatchEvaluator]{ param($match) '${script:OriginalProjectRoot}' }
    )
    $generated = $generated -replace '(?i)Read-Host\s+-Prompt\s+"Press any key to Exit\.\.\."', 'Write-Host "Press any key to Exit..."'
    $generated = $generated -replace '(?m)^\s*vmconnect\s+localhost\s+\$VMName\s*$', '        Start-Process -FilePath "vmconnect.exe" -ArgumentList "localhost", $VMName | Out-Null'
    $header = @(
        "# Generated by EnhancedGpuPv.Gui.ps1.",
        "# Edit GUI settings instead of editing this generated file.",
        "`$script:OriginalProjectRoot = $(ConvertTo-PowerShellStringLiteral $script:ProjectRoot)",
        ""
    ) -join [Environment]::NewLine

    $target = Join-Path $script:GeneratedRoot ("CopyFilesToVM.generated.{0}.ps1" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Set-Content -LiteralPath $target -Value ($header + $generated) -Encoding UTF8
    return $target
}

function New-GeneratedUpdateScript {
    if (-not (Test-Path -LiteralPath $script:SourceUpdateScript)) {
        throw "Could not find Update-VMGpuPartitionDriver.ps1 at $script:SourceUpdateScript"
    }

    New-Item -ItemType Directory -Path $script:GeneratedRoot -Force | Out-Null

    $source = Get-Content -LiteralPath $script:SourceUpdateScript -Raw
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Update-VMGpuPartitionDriver.ps1 could not be parsed: $($parseErrors[0].Message)"
    }

    $generatedModule = New-GeneratedGpuModule
    $moduleImportLine = "Import-Module -Name $(ConvertTo-PowerShellStringLiteral $generatedModule)"
    $generated = $source -replace '(?m)^\s*Import-Module\s+\$PSSCriptRoot\\Add-VMGpuPartitionAdapterFiles\.psm1\s*$', $moduleImportLine
    $generated = $generated -replace '(?m)^\s*Import-Module\s+\$PSScriptRoot\\Add-VMGpuPartitionAdapterFiles\.psm1\s*$', $moduleImportLine
    $header = @(
        "# Generated by EnhancedGpuPv.Gui.ps1.",
        "# Edit GUI settings instead of editing this generated file.",
        ""
    ) -join [Environment]::NewLine

    $target = Join-Path $script:GeneratedRoot ("Update-VMGpuPartitionDriver.generated.{0}.ps1" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Set-Content -LiteralPath $target -Value ($header + $generated) -Encoding UTF8
    return $target
}

function New-GeneratedNestedVirtualizationScript {
    New-Item -ItemType Directory -Path $script:GeneratedRoot -Force | Out-Null

    $scriptText = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName
)

$ErrorActionPreference = "Stop"

Write-Host "Checking Hyper-V VM '$VMName'."
$vm = Get-VM -Name $VMName -ErrorAction Stop

if ($vm.State -ne "Off") {
    Write-Host "Turning off VM '$VMName' before enabling nested virtualization."
    Stop-VM -Name $VMName -Force -ErrorAction Stop

    $deadline = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 2
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        Write-Host "Current VM state: $($vm.State)."
    } while ($vm.State -ne "Off" -and (Get-Date) -lt $deadline)

    if ($vm.State -ne "Off") {
        throw "VM '$VMName' did not turn off within 3 minutes."
    }
}
else {
    Write-Host "VM '$VMName' is already off."
}

Write-Host "Enabling nested virtualization for VM '$VMName'."
Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true -ErrorAction Stop

$processor = Get-VMProcessor -VMName $VMName -ErrorAction Stop
if (-not $processor.ExposeVirtualizationExtensions) {
    throw "Nested virtualization did not report as enabled after Set-VMProcessor."
}

Write-Host "Nested virtualization is enabled for VM '$VMName'."
Write-Host "VM '$VMName' is left powered off."
'@

    $target = Join-Path $script:GeneratedRoot ("Enable-NestedVirtualization.generated.{0}.ps1" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Set-Content -LiteralPath $target -Value $scriptText -Encoding UTF8
    return $target
}

function New-GeneratedPreChecksScript {
    New-Item -ItemType Directory -Path $script:GeneratedRoot -Force | Out-Null

    $scriptText = @'
$ErrorActionPreference = "Continue"
$blockers = 0
$warnings = 0
$results = [ordered]@{
    LastRun = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    OverallStatus = "Running"
    Warnings = 0
    BlockingIssues = 0
    ComputerType = [ordered]@{ Status = "Pending"; Value = "-"; Detail = "-" }
    Windows = [ordered]@{ Status = "Pending"; Value = "-"; Detail = "-" }
    HyperV = [ordered]@{ Status = "Pending"; Value = "-"; Detail = "-" }
    WSL = [ordered]@{ Status = "Pending"; Value = "-"; Detail = "-" }
    GPU = [ordered]@{ Status = "Pending"; Value = "-"; Detail = "-" }
}

function Write-Check {
    param(
        [string]$Level,
        [string]$Message
    )

    Write-Host ("{0}: {1}" -f $Level, $Message)
}

Write-Check "INFO" "Running Enhanced GPU-PV prechecks. All checks will run even if warnings are found."

try {
    $isLaptop = $false
    $enclosure = @(Get-WmiObject -Class Win32_SystemEnclosure -ErrorAction Stop)
    if ($enclosure | Where-Object { $_.ChassisTypes -contains 9 -or $_.ChassisTypes -contains 10 -or $_.ChassisTypes -contains 14 }) {
        $isLaptop = $true
    }
    if (Get-WmiObject -Class Win32_Battery -ErrorAction SilentlyContinue) {
        $isLaptop = $true
    }

    if ($isLaptop) {
        $warnings++
        $results.ComputerType.Status = "WARN"
        $results.ComputerType.Value = "Laptop"
        $results.ComputerType.Detail = "Laptop dedicated GPUs may not work with Parsec. Thunderbolt 3 or 4 dock based GPUs may work."
        Write-Check "WARN" "Computer is a laptop. Laptop dedicated GPUs that are partitioned and assigned to a VM may not work with Parsec."
        Write-Check "WARN" "Thunderbolt 3 or 4 dock based GPUs may work."
    }
    else {
        $results.ComputerType.Status = "OK"
        $results.ComputerType.Value = "Desktop"
        $results.ComputerType.Detail = "Computer appears to be a desktop."
        Write-Check "OK" "Computer appears to be a desktop."
    }
}
catch {
    $warnings++
    $results.ComputerType.Status = "WARN"
    $results.ComputerType.Value = "Unknown"
    $results.ComputerType.Detail = "Could not determine laptop/desktop chassis type: $($_.Exception.Message)"
    Write-Check "WARN" "Could not determine laptop/desktop chassis type: $($_.Exception.Message)"
}

try {
    $systemInfoOutput = @(systeminfo 2>$null)
    $osName = $null
    $osVersion = $null

    foreach ($line in $systemInfoOutput) {
        if ($line -match '^\s*OS Name\s*:\s*(.+)$') {
            $osName = $Matches[1].Trim()
        }
        elseif ($line -match '^\s*OS Version\s*:\s*(.+)$') {
            $osVersion = $Matches[1].Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($osName) -or [string]::IsNullOrWhiteSpace($osVersion)) {
        throw "Could not parse OS Name and OS Version from systeminfo."
    }

    $buildNumber = $null
    if ($osVersion -match '(?i)\bBuild\s+(\d+)') {
        $buildNumber = [int]$Matches[1]
    }
    elseif ($osVersion -match '\d+\.\d+\.(\d+)') {
        $buildNumber = [int]$Matches[1]
    }

    if ($null -eq $buildNumber) {
        throw "Could not parse Windows build number from systeminfo OS Version: $osVersion"
    }

    $editionOk = ($osName -match '(?i)\bPro(fessional)?\b') -or ($osName -match '(?i)\bEnterprise\b') -or ($osName -match '(?i)\bEducation\b')

    if ($buildNumber -ge 19041 -and $editionOk) {
        $results.Windows.Status = "OK"
        $results.Windows.Value = $osName
        $results.Windows.Detail = "Version $osVersion."
        Write-Check "OK" "Windows edition/build is compatible: $osName, version $osVersion."
    }
    else {
        $blockers++
        $results.Windows.Status = "ERROR"
        $results.Windows.Value = $osName
        $results.Windows.Detail = "Windows 10 20H1+ or Windows 11 Pro, Enterprise, or Education is required. Current version $osVersion."
        Write-Check "ERROR" "Windows 10 20H1+ or Windows 11 Pro, Enterprise, or Education is required. Current: $osName, version $osVersion."
    }
}
catch {
    $blockers++
    $results.Windows.Status = "ERROR"
    $results.Windows.Value = "Unknown"
    $results.Windows.Detail = "Could not read Windows version information from systeminfo: $($_.Exception.Message)"
    Write-Check "ERROR" "Could not read Windows version information from systeminfo: $($_.Exception.Message)"
}

try {
    $hyperV = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
    if ($hyperV.State -eq "Enabled") {
        $results.HyperV.Status = "OK"
        $results.HyperV.Value = "Yes"
        $results.HyperV.Detail = "Hyper-V Windows feature is enabled."
        Write-Check "OK" "Hyper-V Windows feature is enabled."
    }
    else {
        $blockers++
        $results.HyperV.Status = "ERROR"
        $results.HyperV.Value = "No"
        $results.HyperV.Detail = "Hyper-V Windows feature state: $($hyperV.State)."
        Write-Check "ERROR" "Hyper-V Windows feature is not enabled. Current state: $($hyperV.State)."
    }
}
catch {
    $blockers++
    $results.HyperV.Status = "ERROR"
    $results.HyperV.Value = "Unknown"
    $results.HyperV.Detail = "Could not query Hyper-V Windows feature: $($_.Exception.Message)"
    Write-Check "ERROR" "Could not query Hyper-V Windows feature: $($_.Exception.Message)"
}

try {
    $wslOutput = @(wsl.exe -l -v 2>$null)
    if ($LASTEXITCODE -eq 0 -and $wslOutput.Count -gt 1) {
        $warnings++
        $results.WSL.Status = "WARN"
        $results.WSL.Value = "Yes"
        $results.WSL.Detail = "WSL appears to be enabled and may interfere with GPU-PV and can produce error 43 in the VM."
        Write-Check "WARN" "WSL appears to be enabled. This may interfere with GPU-PV and can produce error 43 in the VM."
    }
    else {
        $results.WSL.Status = "OK"
        $results.WSL.Value = "No"
        $results.WSL.Detail = "No active WSL distributions were detected."
        Write-Check "OK" "No active WSL distributions were detected."
    }
}
catch {
    $results.WSL.Status = "OK"
    $results.WSL.Value = "No"
    $results.WSL.Detail = "WSL was not detected."
    Write-Check "OK" "WSL was not detected."
}

try {
    $partitionableGpuNames = @((Get-WmiObject -Class "Msvm_PartitionableGpu" -ComputerName $env:COMPUTERNAME -Namespace "ROOT\virtualization\v2" -ErrorAction Stop).Name)
    if ($partitionableGpuNames.Count -lt 1) {
        $blockers++
        $results.GPU.Status = "ERROR"
        $results.GPU.Value = "No"
        $results.GPU.Detail = "No partitionable GPUs were detected by Hyper-V."
        Write-Check "ERROR" "No partitionable GPUs were detected by Hyper-V."
    }
    else {
        $friendlyNames = @()
        Write-Check "OK" "Hyper-V detected $($partitionableGpuNames.Count) partitionable GPU device path(s)."
        Write-Check "INFO" "Compatible GPU friendly names:"
        foreach ($gpu in $partitionableGpuNames) {
            $gpuParse = $gpu.Split('#')[1]
            $friendlyName = Get-WmiObject Win32_PNPSignedDriver -ErrorAction SilentlyContinue |
                Where-Object { $_.HardwareID -eq "PCI\$gpuParse" } |
                Select-Object -ExpandProperty DeviceName -First 1

            if ([string]::IsNullOrWhiteSpace($friendlyName)) {
                $friendlyNames += $gpu
                Write-Check "INFO" "  $gpu"
            }
            else {
                $friendlyNames += $friendlyName
                Write-Check "INFO" "  $friendlyName"
            }
        }
        $results.GPU.Status = "OK"
        $results.GPU.Value = "Yes ($($partitionableGpuNames.Count))"
        $results.GPU.Detail = ($friendlyNames -join "; ")
    }
}
catch {
    $blockers++
    $results.GPU.Status = "ERROR"
    $results.GPU.Value = "Unknown"
    $results.GPU.Detail = "Could not query partitionable GPUs: $($_.Exception.Message)"
    Write-Check "ERROR" "Could not query partitionable GPUs: $($_.Exception.Message)"
}

$results.Warnings = $warnings
$results.BlockingIssues = $blockers
$results.OverallStatus = if ($blockers -gt 0) { "ERROR" } elseif ($warnings -gt 0) { "WARN" } else { "OK" }
try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $preCheckResultPath) -Force | Out-Null
    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $preCheckResultPath -Encoding UTF8
}
catch {
    Write-Check "WARN" "Could not write structured precheck results: $($_.Exception.Message)"
}

Write-Check "INFO" "Prechecks complete. Warnings: $warnings. Blocking issues: $blockers."
if ($blockers -gt 0) {
    exit 1
}

exit 0
'@

    $header = "`$preCheckResultPath = $(ConvertTo-PowerShellStringLiteral $script:PreCheckResultPath)`r`n"
    $target = Join-Path $script:GeneratedRoot ("PreChecks.generated.{0}.ps1" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    Set-Content -LiteralPath $target -Value ($header + $scriptText) -Encoding UTF8
    return $target
}

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Add-RunLogLine {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($script:LogFilePath)) {
        return
    }

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8
            return
        }
        catch {
            Start-Sleep -Milliseconds 80
        }
    }
}

function Read-FullRunLogText {
    if ([string]::IsNullOrWhiteSpace($script:LogFilePath) -or -not (Test-Path -LiteralPath $script:LogFilePath)) {
        return ""
    }

    try {
        $stream = [System.IO.FileStream]::new(
            $script:LogFilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )

        try {
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
            try {
                return $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return ""
    }
}

function Set-RawLogText {
    param([string]$Text)

    if ($null -eq $Text) {
        return
    }

    if ($Text -eq $script:RenderedRunLogText) {
        return
    }

    $script:RenderedRunLogText = $Text
    $script:Ui.LogTextBox.Text = $Text
    $script:Ui.LogTextBox.ScrollToEnd()
}

function Set-OperationProgress {
    param(
        [int]$Percent,
        [string]$Text,
        [bool]$Indeterminate = $false
    )

    if (-not $script:Ui.ProgressPanel -or -not $script:Ui.OperationProgressBar) {
        return
    }

    if ($Percent -lt 0) {
        $Percent = 0
    }
    elseif ($Percent -gt 100) {
        $Percent = 100
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        $Text = "Working..."
    }

    $script:Ui.ProgressPanel.Visibility = [System.Windows.Visibility]::Visible
    $script:Ui.ProgressText.Text = $Text
    $script:Ui.OperationProgressBar.IsIndeterminate = $Indeterminate
    $script:Ui.OperationProgressBar.Value = $Percent
    $script:Ui.ProgressPercentText.Text = if ($Indeterminate) { "~$Percent%" } else { "$Percent%" }
}

function Reset-OperationProgress {
    if (-not $script:Ui.ProgressPanel -or -not $script:Ui.OperationProgressBar) {
        return
    }

    $script:Ui.OperationProgressBar.IsIndeterminate = $false
    $script:Ui.OperationProgressBar.Value = 0
    $script:Ui.ProgressText.Text = "Ready"
    $script:Ui.ProgressPercentText.Text = "0%"
    $script:Ui.ProgressPanel.Visibility = [System.Windows.Visibility]::Collapsed
}

function Get-ProgressStageFromLog {
    param(
        [string]$OperationName,
        [string]$LogText
    )

    $stage = [pscustomobject]@{
        Percent = 5
        Text = "Preparing $OperationName"
        Indeterminate = $true
    }

    switch ($OperationName) {
        "Create VM" {
            $stages = @(
                [pscustomobject]@{ Pattern = '(?i)Running the project PowerShell script'; Percent = 5; Text = 'Preparing VM creation'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Selected GPU|Windows 10 requires GPUName'; Percent = 8; Text = 'Selecting GPU'; Indeterminate = $false },
                [pscustomobject]@{ Pattern = '(?i)Creating sparse disk|Attaching VHD|Mounting VHD'; Percent = 18; Text = 'Creating virtual disk'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Creating .*partition|EFI system partition|MSR partition|windows partition|system partition'; Percent = 28; Text = 'Partitioning virtual disk'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Applying image to|Applying image:'; Percent = 45; Text = 'Applying Windows image'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Applying unattend file'; Percent = 58; Text = 'Applying unattended setup'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Finding and copying driver files|Copying driver files'; Percent = 72; Text = 'Copying GPU driver files'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Setting up programs to install at boot'; Percent = 80; Text = 'Staging guest installers'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Dismounting VHD|Closing VHD|Generating name for|Renaming VHD'; Percent = 88; Text = 'Finalizing virtual disk'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Starting and connecting to VM|Your Virtual Machine now has access'; Percent = 95; Text = 'Starting VM'; Indeterminate = $true }
            )
        }
        "Update GPU driver" {
            $stages = @(
                [pscustomobject]@{ Pattern = '(?i)Running the project PowerShell script'; Percent = 5; Text = 'Preparing driver update'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Selected GPU'; Percent = 10; Text = 'Selecting GPU'; Indeterminate = $false },
                [pscustomobject]@{ Pattern = '(?i)Attemping to shutdown VM|Attempting to shutdown VM|Waiting for VM to shutdown|Stop-VM'; Percent = 22; Text = 'Stopping VM'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Mounting Drive'; Percent = 35; Text = 'Mounting VM disk'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Copying GPU Files|Finding and copying driver files'; Percent = 65; Text = 'Copying GPU driver files'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Dismounting Drive'; Percent = 85; Text = 'Dismounting VM disk'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Previous State was running|starting VM'; Percent = 92; Text = 'Restarting VM'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Done\.\.\.|Done\.'; Percent = 96; Text = 'Finalizing driver update'; Indeterminate = $true }
            )
        }
        "PreChecks" {
            $stages = @(
                [pscustomobject]@{ Pattern = '(?i)Running Enhanced GPU-PV prechecks'; Percent = 15; Text = 'Running prechecks'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Windows'; Percent = 35; Text = 'Checking Windows'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Hyper-V'; Percent = 55; Text = 'Checking Hyper-V'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)WSL'; Percent = 70; Text = 'Checking WSL'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)partitionable GPU|Compatible GPU'; Percent = 85; Text = 'Checking GPUs'; Indeterminate = $true }
            )
        }
        "Enable nested virtualization" {
            $stages = @(
                [pscustomobject]@{ Pattern = '(?i)Checking Hyper-V VM'; Percent = 20; Text = 'Checking VM'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Turning off VM|Current VM state'; Percent = 45; Text = 'Stopping VM'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)already off'; Percent = 55; Text = 'VM is powered off'; Indeterminate = $false },
                [pscustomobject]@{ Pattern = '(?i)Enabling nested virtualization'; Percent = 75; Text = 'Updating VM processor'; Indeterminate = $true },
                [pscustomobject]@{ Pattern = '(?i)Nested virtualization is enabled'; Percent = 95; Text = 'Verifying nested virtualization'; Indeterminate = $true }
            )
        }
        default {
            $stages = @()
        }
    }

    foreach ($candidate in $stages) {
        if ($LogText -match $candidate.Pattern) {
            $stage = [pscustomobject]@{
                Percent = $candidate.Percent
                Text = $candidate.Text
                Indeterminate = $candidate.Indeterminate
            }
        }
    }

    if ($LogText -match '(?i)completed successfully') {
        return [pscustomobject]@{ Percent = 100; Text = "$OperationName complete"; Indeterminate = $false }
    }

    if ($LogText -match '(?i)stopped with errors|ERROR:') {
        return [pscustomobject]@{ Percent = $stage.Percent; Text = "$OperationName stopped with errors"; Indeterminate = $false }
    }

    return $stage
}

function Update-OperationProgressFromLog {
    param([string]$LogText)

    if (-not $script:RunInProgress -and -not ($script:CurrentProcess -and $script:CurrentProcess.HasExited)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:ActiveOperationName)) {
        return
    }

    $stage = Get-ProgressStageFromLog -OperationName $script:ActiveOperationName -LogText $LogText
    Set-OperationProgress -Percent $stage.Percent -Text $stage.Text -Indeterminate $stage.Indeterminate
}

function Get-ErrorSummaryFromLog {
    param([string]$LogText)

    if ([string]::IsNullOrWhiteSpace($LogText)) {
        return "No error details were written to the log."
    }

    $patterns = @(
        '(?i)\bERROR\b',
        '(?i)\bFailed\b',
        '(?i)\bCannot\b',
        '(?i)\bInvalid\b',
        '(?i)already exists',
        '(?i)doesn''t exist',
        '(?i)No partitionable'
    )

    $lines = $LogText -split "`r?`n"
    $errorLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        foreach ($pattern in $patterns) {
            if ($line -match $pattern) {
                [void]$errorLines.Add($line)
                break
            }
        }
    }

    if ($errorLines.Count -eq 0) {
        return "The operation exited with an error code, but no specific error line was detected. Review the full log below."
    }

    return (($errorLines | Select-Object -First 8) -join [Environment]::NewLine)
}

function Show-OperationErrorDialog {
    param(
        [string]$OperationName,
        [int]$ExitCode,
        [string]$LogText,
        [string]$LogFilePath
    )

    $summaryText = Get-ErrorSummaryFromLog $LogText
    [System.Windows.MessageBox]::Show(
        "$OperationName stopped with errors.`r`n`r`nExit code: $ExitCode`r`n`r`n$summaryText`r`n`r`nFull log:`r`n$LogFilePath",
        "$OperationName failed",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
    return

    $dialog = [System.Windows.Window]::new()
    $dialog.Title = "$OperationName failed"
    $dialog.Width = 760
    $dialog.Height = 520
    $dialog.MinWidth = 620
    $dialog.MinHeight = 420
    $dialog.WindowStartupLocation = "CenterOwner"
    $dialog.Owner = $script:Window
    $dialog.Background = [System.Windows.Media.Brushes]::White

    $root = [System.Windows.Controls.Grid]::new()
    $root.Margin = [System.Windows.Thickness]::new(16)
    $rowTitle = [System.Windows.Controls.RowDefinition]::new()
    $rowTitle.Height = [System.Windows.GridLength]::Auto
    $rowSummary = [System.Windows.Controls.RowDefinition]::new()
    $rowSummary.Height = [System.Windows.GridLength]::Auto
    $rowLog = [System.Windows.Controls.RowDefinition]::new()
    $rowButtons = [System.Windows.Controls.RowDefinition]::new()
    $rowButtons.Height = [System.Windows.GridLength]::Auto
    [void]$root.RowDefinitions.Add($rowTitle)
    [void]$root.RowDefinitions.Add($rowSummary)
    [void]$root.RowDefinitions.Add($rowLog)
    [void]$root.RowDefinitions.Add($rowButtons)

    $title = [System.Windows.Controls.TextBlock]::new()
    $title.Text = "$OperationName stopped with errors"
    $title.FontSize = 20
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    $title.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(124, 45, 18))
    [System.Windows.Controls.Grid]::SetRow($title, 0)
    $root.Children.Add($title) | Out-Null

    $summary = [System.Windows.Controls.TextBlock]::new()
    $summary.Text = "Exit code $ExitCode`r`n`r`n$(Get-ErrorSummaryFromLog $LogText)`r`n`r`nLog file: $LogFilePath"
    $summary.TextWrapping = "Wrap"
    $summary.Margin = [System.Windows.Thickness]::new(0, 10, 0, 12)
    [System.Windows.Controls.Grid]::SetRow($summary, 1)
    $root.Children.Add($summary) | Out-Null

    $logBox = [System.Windows.Controls.TextBox]::new()
    $logBox.Text = $LogText
    $logBox.IsReadOnly = $true
    $logBox.AcceptsReturn = $true
    $logBox.AcceptsTab = $true
    $logBox.TextWrapping = "NoWrap"
    $logBox.VerticalScrollBarVisibility = "Auto"
    $logBox.HorizontalScrollBarVisibility = "Auto"
    $logBox.FontFamily = [System.Windows.Media.FontFamily]::new("Consolas")
    $logBox.FontSize = 12
    $logBox.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(16, 22, 20))
    $logBox.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(217, 229, 223))
    [System.Windows.Controls.Grid]::SetRow($logBox, 2)
    $root.Children.Add($logBox) | Out-Null

    $buttons = [System.Windows.Controls.StackPanel]::new()
    $buttons.Orientation = "Horizontal"
    $buttons.HorizontalAlignment = "Right"
    $buttons.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)

    $openLogButton = [System.Windows.Controls.Button]::new()
    $openLogButton.Content = "Open Log Folder"
    $openLogButton.MinWidth = 120
    $openLogButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $openLogButton.Add_Click({
        if ($script:LogFilePath) {
            Start-Process -FilePath "explorer.exe" -ArgumentList (Quote-ProcessArgument (Split-Path -Parent $script:LogFilePath)) | Out-Null
        }
    })
    $buttons.Children.Add($openLogButton) | Out-Null

    $okButton = [System.Windows.Controls.Button]::new()
    $okButton.Content = "OK"
    $okButton.MinWidth = 86
    $okButton.IsDefault = $true
    $okButton.Add_Click({ $dialog.Close() })
    $buttons.Children.Add($okButton) | Out-Null

    [System.Windows.Controls.Grid]::SetRow($buttons, 3)
    $root.Children.Add($buttons) | Out-Null

    $dialog.Content = $root
    [void]$dialog.ShowDialog()
}

function Update-RunLogView {
    $logText = Read-FullRunLogText
    Set-RawLogText $logText
    Update-OperationProgressFromLog -LogText $logText

    if ($script:CurrentProcess -and $script:CurrentProcess.HasExited) {
        $exitCode = $script:CurrentProcess.ExitCode
        $operationName = $script:ActiveOperationName

        if ($operationName -eq "PreChecks" -and (Test-Path -LiteralPath $script:PreCheckResultPath)) {
            try {
                $preCheckResult = Get-Content -LiteralPath $script:PreCheckResultPath -Raw | ConvertFrom-Json
                if ([int]$preCheckResult.BlockingIssues -eq 0) {
                    $exitCode = 0
                }
            }
            catch {
                Append-Log "Could not read PreChecks result status: $($_.Exception.Message)"
            }
        }

        if ($script:LogPollTimer) {
            $script:LogPollTimer.Stop()
        }

        $finalLogText = Read-FullRunLogText
        Set-RawLogText $finalLogText
        if ($exitCode -eq 0) {
            Set-OperationProgress -Percent 100 -Text "$operationName complete" -Indeterminate $false
        }
        else {
            $stage = Get-ProgressStageFromLog -OperationName $operationName -LogText $finalLogText
            Set-OperationProgress -Percent $stage.Percent -Text "$operationName stopped with errors" -Indeterminate $false
        }
        Set-Busy $false

        if ($operationName -eq "PreChecks") {
            Update-PreCheckResultsPanel
        }

        if ($exitCode -ne 0) {
            try {
                Show-OperationErrorDialog -OperationName $operationName -ExitCode $exitCode -LogText (Read-FullRunLogText) -LogFilePath $script:LogFilePath
            }
            catch {
                Append-Log "Could not show error popup: $($_.Exception.Message)"
                [System.Windows.MessageBox]::Show(
                    "The operation failed, but the error popup could not be shown.`r`n`r`n$($_.Exception.Message)`r`n`r`nLog file: $script:LogFilePath",
                    "$operationName failed",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Error
                ) | Out-Null
            }
        }
    }
}

function Start-LogPollTimer {
    if (-not $script:LogPollTimer) {
        $script:LogPollTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:LogPollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:LogPollTimer.Add_Tick({
            try {
                Update-RunLogView
            }
            catch {
                Append-Log "Log refresh failed: $($_.Exception.Message)"
            }
        })
    }

    $script:RenderedRunLogText = ""
    $script:LogPollTimer.Start()
}

function New-ProcessRunnerScript {
    param(
        [string]$OperationName,
        [string]$FilePath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$LogFilePath
    )

    New-Item -ItemType Directory -Path $script:GeneratedRoot -Force | Out-Null

    $runnerPath = Join-Path $script:GeneratedRoot ("RunOperation.{0}.ps1" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"))
    $runner = @"
`$ErrorActionPreference = 'Continue'
`$operationName = $(ConvertTo-PowerShellStringLiteral $OperationName)
`$filePath = $(ConvertTo-PowerShellStringLiteral $FilePath)
`$arguments = $(ConvertTo-PowerShellStringLiteral $Arguments)
`$workingDirectory = $(ConvertTo-PowerShellStringLiteral $WorkingDirectory)
`$logFilePath = $(ConvertTo-PowerShellStringLiteral $LogFilePath)
`$script:sawFailureText = `$false
`$script:preCheckBlockingIssues = `$null

function Write-RunLog {
    param([AllowNull()][object]`$Value)

    if (`$null -eq `$Value) {
        return
    }

    `$text = (`$Value | Out-String).TrimEnd()
    if ([string]::IsNullOrWhiteSpace(`$text)) {
        return
    }

    foreach (`$line in (`$text -split "`r?`n")) {
        if (`$line -match '(?i)^Press any key to Exit') {
            continue
        }
        if (`$operationName -eq 'PreChecks' -and `$line -match 'Blocking issues:\s*(\d+)') {
            `$script:preCheckBlockingIssues = [int]`$Matches[1]
        }
        if (`$line -match '(?i)(^|\s)(ERROR|Failed|Cannot|Invalid|already exists|doesn''t exist|No partitionable)') {
            `$script:sawFailureText = `$true
        }
        Add-Content -LiteralPath `$logFilePath -Value ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), `$line) -Encoding UTF8
    }
}

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent `$logFilePath) -Force | Out-Null
    Write-RunLog "`$operationName started."
    Write-RunLog "Running the project PowerShell script."

    if (-not [string]::IsNullOrWhiteSpace(`$workingDirectory)) {
        Set-Location -LiteralPath `$workingDirectory
    }

    `$argumentList = [System.Management.Automation.PSParser]::Tokenize(`$arguments, [ref]`$null) |
        Where-Object { `$_.Type -in 'Command', 'CommandParameter', 'CommandArgument', 'String', 'Number' } |
        ForEach-Object { `$_.Content }

    & `$filePath @argumentList 2>&1 | ForEach-Object {
        Write-RunLog `$_
    }

    `$exitCode = `$LASTEXITCODE
    if (`$null -eq `$exitCode) {
        `$exitCode = 0
    }
    if (`$operationName -eq 'Create VM' -and `$script:sawFailureText) {
        `$exitCode = 1
    }
    if (`$operationName -eq 'PreChecks' -and `$null -ne `$script:preCheckBlockingIssues) {
        `$exitCode = if (`$script:preCheckBlockingIssues -gt 0) { 1 } else { 0 }
        `$script:sawFailureText = `$false
    }
    if (`$exitCode -eq 0 -and `$script:sawFailureText) {
        `$exitCode = 1
    }

    if (`$exitCode -eq 0) {
        Write-RunLog "`$operationName completed successfully."
    }
    else {
        Write-RunLog "`$operationName stopped with errors. Exit code: `$exitCode."
    }
    exit `$exitCode
}
catch {
    Write-RunLog ("ERROR: " + `$_.Exception.Message)
    Write-RunLog (`$_ | Out-String)
    exit 1
}
"@

    Set-Content -LiteralPath $runnerPath -Value $runner -Encoding UTF8
    return $runnerPath
}

function Start-LoggedProcess {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$OperationName
    )

    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        [System.Windows.MessageBox]::Show("Another operation is already running.", "Enhanced GPU-PV", "OK", "Information") | Out-Null
        return
    }

    New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
    $safeOperationName = ($OperationName -replace '[^a-zA-Z0-9_-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeOperationName)) {
        $safeOperationName = "operation"
    }
    $script:LogFilePath = Join-Path $script:LogRoot ("{0}.{1}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $safeOperationName)
    $script:ActiveOperationName = $OperationName
    $script:RenderedRunLogText = ""
    $script:Ui.LogTextBox.Clear()

    Append-Log "$OperationName started."
    Append-Log "Log file: $script:LogFilePath"
    Add-RunLogLine "Log file: $script:LogFilePath"
    Set-Busy $true
    Set-OperationProgress -Percent 3 -Text "Starting $OperationName" -Indeterminate $true

    $runnerScript = New-ProcessRunnerScript -OperationName $OperationName -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory -LogFilePath $script:LogFilePath
    Add-RunLogLine "Runner script: $runnerScript"

    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-ProcessArgument $runnerScript)"
        $psi.WorkingDirectory = $WorkingDirectory
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false
        $psi.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        $script:CurrentProcess = $process

        [void]$process.Start()
        Start-LogPollTimer
    }
    catch {
        Append-Log "Failed to start $OperationName`: $($_.Exception.Message)"
        Add-RunLogLine "Failed to start $OperationName`: $($_.Exception.Message)"
        Set-OperationProgress -Percent 0 -Text "$OperationName failed to start" -Indeterminate $false
        Set-Busy $false
        throw
    }
}

function Update-InstallProfileDetail {
    $profile = Get-ComboText $script:Ui.InstallProfileCombo
    switch ($profile) {
        "GPU-PV only" {
            $script:Ui.InstallProfileDetailText.Text = "Creates a VM with GPU-PV support only. No Parsec, Sunshine, ParsecVDA, or Virtual Display Driver will be installed."
        }
        "Parsec + ParsecVDA" {
            $script:Ui.InstallProfileDetailText.Text = "Installs Parsec for remote access and ParsecVDA as the always-connected virtual display solution."
        }
        "Parsec + Virtual Display Driver" {
            $script:Ui.InstallProfileDetailText.Text = "Installs Parsec for remote access and Virtual Display Driver as the display solution. HDR support depends on the Windows ISO/build used."
        }
        "Sunshine + Virtual Display Driver" {
            $script:Ui.InstallProfileDetailText.Text = "Installs Sunshine for Moonlight streaming and Virtual Display Driver as the display solution. HDR support depends on the Windows ISO/build used."
        }
        "Sunshine + ParsecVDA" {
            $script:Ui.InstallProfileDetailText.Text = "Installs Sunshine for Moonlight streaming and ParsecVDA as the always-connected virtual display solution."
        }
        default {
            $script:Ui.InstallProfileDetailText.Text = "Choose one of the supported install profiles."
        }
    }
}

$script:Ui.InstallProfileCombo.Items.Clear()
@(
    "GPU-PV only",
    "Parsec + ParsecVDA",
    "Parsec + Virtual Display Driver",
    "Sunshine + Virtual Display Driver",
    "Sunshine + ParsecVDA"
) | ForEach-Object { [void]$script:Ui.InstallProfileCombo.Items.Add($_) }
$script:Ui.InstallProfileCombo.SelectedItem = "Sunshine + Virtual Display Driver"
$script:Ui.InstallProfileCombo.Add_SelectionChanged({ Update-InstallProfileDetail })
Update-InstallProfileDetail

$script:Ui.GpuAllocationSlider.Add_ValueChanged({
    $script:Ui.GpuAllocationValueText.Text = ("{0}%" -f [int][Math]::Round($script:Ui.GpuAllocationSlider.Value))
})

$script:Ui.BrowseIsoButton.Add_Click({
    $dialog = [System.Windows.Forms.OpenFileDialog]::new()
    $dialog.Filter = "Windows ISO (*.iso)|*.iso|All files (*.*)|*.*"
    $dialog.Title = "Select Windows ISO"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Ui.IsoPathText.Text = $dialog.FileName
    }
})

$script:Ui.BrowseVhdButton.Add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = "Select VHD folder"
    $dialog.SelectedPath = $script:Ui.VhdPathText.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:Ui.VhdPathText.Text = $dialog.SelectedPath
    }
})

$script:Ui.RefreshHostDataButton.Add_Click({
    try {
        Refresh-HostData
    }
    catch {
        Append-Log $_.Exception.Message
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Refresh failed", "OK", "Error") | Out-Null
    }
})

$script:Ui.RefreshMaintenanceVmListButton.Add_Click({
    try {
        Refresh-HostData
    }
    catch {
        Append-Log $_.Exception.Message
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Refresh failed", "OK", "Error") | Out-Null
    }
})

$script:Ui.RunPreChecksButton.Add_Click({
    try {
        Reset-PreCheckResults
        if (Test-Path -LiteralPath $script:PreCheckResultPath) {
            Remove-Item -LiteralPath $script:PreCheckResultPath -Force
        }

        $generatedPreChecksScript = New-GeneratedPreChecksScript
        Append-Log "Generated precheck script: $generatedPreChecksScript"

        $arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-ProcessArgument $generatedPreChecksScript)"
        Start-LoggedProcess -FilePath "powershell.exe" -Arguments $arguments -WorkingDirectory $script:ProjectRoot -OperationName "PreChecks"
    }
    catch {
        Append-Log $_.Exception.Message
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Cannot run prechecks", "OK", "Error") | Out-Null
    }
})

$script:Ui.CreateVmButton.Add_Click({
    try {
        $config = Get-CreateConfig
        Test-CreateVmAssetFiles
        $generatedScript = New-GeneratedCreateScript -Config $config
        Append-Log "Generated create script: $generatedScript"
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-ProcessArgument $generatedScript)"
        Start-LoggedProcess -FilePath "powershell.exe" -Arguments $arguments -WorkingDirectory $script:ProjectRoot -OperationName "Create VM"
    }
    catch {
        Append-Log $_.Exception.Message
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Cannot create VM", "OK", "Error") | Out-Null
    }
})

$script:Ui.UpdateDriverButton.Add_Click({
    try {
        $vmName = (Get-ComboText $script:Ui.UpdateVmNameText).Trim()
        $gpuName = (Get-ComboText $script:Ui.UpdateGpuCombo).Trim()

        if ([string]::IsNullOrWhiteSpace($vmName)) {
            throw "VM name is required."
        }
        if ([string]::IsNullOrWhiteSpace($gpuName)) {
            throw "GPU is required. Use AUTO if unsure."
        }

        try {
            $null = Get-VM -Name $vmName -ErrorAction Stop
        }
        catch {
            throw "VM '$vmName' was not found in Hyper-V. Select an existing VM name before updating GPU drivers."
        }

        $generatedUpdateScript = New-GeneratedUpdateScript
        Append-Log "Generated update script: $generatedUpdateScript"

        $arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-ProcessArgument $generatedUpdateScript) -VMName $(Quote-ProcessArgument $vmName) -GPUName $(Quote-ProcessArgument $gpuName)"
        Start-LoggedProcess -FilePath "powershell.exe" -Arguments $arguments -WorkingDirectory $script:ProjectRoot -OperationName "Update GPU driver"
    }
    catch {
        Append-Log $_.Exception.Message
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Cannot update driver", "OK", "Error") | Out-Null
    }
})

$script:Ui.EnableNestedVirtualizationButton.Add_Click({
    try {
        $vmName = (Get-ComboText $script:Ui.NestedVmNameText).Trim()

        if ([string]::IsNullOrWhiteSpace($vmName)) {
            throw "VM name is required."
        }

        try {
            $null = Get-VM -Name $vmName -ErrorAction Stop
        }
        catch {
            throw "VM '$vmName' was not found in Hyper-V. Select an existing VM name before enabling nested virtualization."
        }

        $answer = [System.Windows.MessageBox]::Show(
            "This will turn off VM '$vmName' if it is running, then enable nested virtualization. The VM will stay powered off when the task finishes.`r`n`r`nContinue?",
            "Enable nested virtualization",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )

        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            Append-Log "Enable nested virtualization cancelled."
            return
        }

        $generatedNestedScript = New-GeneratedNestedVirtualizationScript
        Append-Log "Generated nested virtualization script: $generatedNestedScript"

        $arguments = "-NoProfile -ExecutionPolicy Bypass -File $(Quote-ProcessArgument $generatedNestedScript) -VMName $(Quote-ProcessArgument $vmName)"
        Start-LoggedProcess -FilePath "powershell.exe" -Arguments $arguments -WorkingDirectory $script:ProjectRoot -OperationName "Enable nested virtualization"
    }
    catch {
        Append-Log $_.Exception.Message
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Cannot enable nested virtualization", "OK", "Error") | Out-Null
    }
})

$script:Ui.OpenGeneratedFolderButton.Add_Click({
    New-Item -ItemType Directory -Path $script:GeneratedRoot -Force | Out-Null
    Start-Process -FilePath "explorer.exe" -ArgumentList (Quote-ProcessArgument $script:GeneratedRoot) | Out-Null
})

$script:Ui.ClearLogButton.Add_Click({
    $script:Ui.LogTextBox.Clear()
})

$script:Window.Add_Closing({
    param($sender, $eventArgs)

    if ($script:RunInProgress -or ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited)) {
        $eventArgs.Cancel = $true
        Append-Log "Close request ignored because $script:ActiveOperationName is still running."
        [System.Windows.MessageBox]::Show(
            "An operation is still running. Please wait until it finishes before closing the GUI.",
            "Operation in progress",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
})

$script:Window.Add_Closed({
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        $script:CurrentProcess.Kill()
    }
})

Reset-OperationProgress
Reset-PreCheckResults
if (Test-Path -LiteralPath $script:PreCheckResultPath) {
    Update-PreCheckResultsPanel
}

Append-Log "GUI loaded from $script:GuiRoot"
Append-Log "Project root: $script:ProjectRoot"
try {
    Refresh-HostData
}
catch {
    Append-Log $_.Exception.Message
}

[void]$script:Window.ShowDialog()
