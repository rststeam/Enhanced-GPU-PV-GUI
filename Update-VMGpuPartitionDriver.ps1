<# 
If you are opening this file in Powershell ISE you should modify the params section like so...
Remember: GPU Name must match the name of the GPU you assigned when creating the VM...

Param (
[string]$VMName = "NameofyourVM",
[string]$GPUName = "NameofyourGPU",
[string]$Hostname = $ENV:Computername
)

powershell -ExecutionPolicy Bypass -File "C:\Users\Caki\Desktop\Enhanced-GPU-PV\Enhanced-GPU-PV-main\Update-VMGpuPartitionDriver.ps1" -VMName "GPUPV" -GPUName "SELECT"

#>

Param (
[string]$VMName,
[string]$GPUName,
[string]$Hostname = $ENV:Computername
)

Import-Module $PSSCriptRoot\Add-VMGpuPartitionAdapterFiles.psm1

Function Get-PartitionableGpuCandidates {
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
                GPUName       = $driver.DeviceName
                Manufacturer  = $driver.Manufacturer
                DriverVersion = $driver.DriverVersion
                DeviceId      = $deviceId
            }
        }
    }

    $candidates | Sort-Object GPUName -Unique
}

Function Select-PartitionableGpuName {
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22000) {
        Write-Host "INFO   : Windows 10 requires GPUName=AUTO. Using AUTO."
        return "AUTO"
    }

    try {
        $candidates = @(Get-PartitionableGpuCandidates)
    }
    catch {
        throw "Failed to enumerate partitionable GPUs. Error: $($_.Exception.Message)"
    }

    if ($candidates.Count -lt 1) {
        throw "No partitionable GPUs detected."
    }

    Write-Host "Detected partitionable GPUs:"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("[{0}] {1}" -f $i, $candidates[$i].GPUName)
    }

    if ($candidates.Count -eq 1) {
        Write-Host ("INFO   : Selected GPU: {0}" -f $candidates[0].GPUName)
        return $candidates[0].GPUName
    }

    $maxIndex = $candidates.Count - 1
    $selectedIndex = $null
    do {
        $inputText = Read-Host -Prompt "Select GPU index (0-$maxIndex)"
        $parsed = 0
        $ok = [int]::TryParse($inputText, [ref]$parsed)
        if ($ok -and $parsed -ge 0 -and $parsed -le $maxIndex) {
            $selectedIndex = $parsed
        }
    } until ($selectedIndex -ne $null)

    Write-Host ("INFO   : Selected GPU: {0}" -f $candidates[$selectedIndex].GPUName)
    return $candidates[$selectedIndex].GPUName
}

if ($GPUName -and ($GPUName.Trim() -match '^(?i)(SELECT|CHOOSE)$')) {
    $GPUName = Select-PartitionableGpuName
}

$VM = Get-VM -VMName $VMName
$VHD = Get-VHD -VMId $VM.VMId

If ($VM.state -eq "Running") {
    [bool]$state_was_running = $true
    }

if ($VM.state -ne "Off"){
    "Attemping to shutdown VM..."
    Stop-VM -Name $VMName -Force
    } 

While ($VM.State -ne "Off") {
    Start-Sleep -s 3
    "Waiting for VM to shutdown - make sure there are no unsaved documents..."
    }

"Mounting Drive..."
$DriveLetter = (Mount-VHD -Path $VHD.Path -PassThru | Get-Disk | Get-Partition | Get-Volume | Where-Object {$_.DriveLetter} | ForEach-Object DriveLetter)

"Copying GPU Files - this could take a while..."
Add-VMGPUPartitionAdapterFiles -hostname $Hostname -DriveLetter $DriveLetter -GPUName $GPUName

"Dismounting Drive..."
Dismount-VHD -Path $VHD.Path

If ($state_was_running){
    "Previous State was running so starting VM..."
    Start-VM $VMName
    }

"Done..."
