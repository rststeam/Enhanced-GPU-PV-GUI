$preCheckResultPath = 'C:\Users\Caki\Desktop\Enhanced-GPU-PV\Enhanced-GPU-PV-GUI\GUI\.generated\PreChecks.latest.json'
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
