# Run this script in a PowerShell session with Administrator rights, or let it self-elevate.
[CmdletBinding()]
param(
    # Latest stable version of NefCon installer
    [Parameter(Mandatory=$false)]
    [string]$NefConURL = "https://github.com/nefarius/nefcon/releases/download/v1.14.0/nefcon_v1.14.0.zip",

    # Latest stable version of VDD driver only
    [Parameter(Mandatory=$false)]
    [string]$DriverURL = "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23/VirtualDisplayDriver-x86.Driver.Only.zip"
);


$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    foreach ($key in $PSBoundParameters.Keys) {
        $arguments += "-$key"
        $arguments += "`"$($PSBoundParameters[$key])`""
    }
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    exit $process.ExitCode
}

function Remove-InstallScheduledTask {
    param([string]$TaskName)

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    }
    catch {
    }
}
# Variables
$taskName = "Install VirtualDisplayDriverBeta"
$scriptFolder = (Get-Item -Path $MyInvocation.MyCommand.Definition).DirectoryName
$desktopPath = [System.Environment]::GetFolderPath('Desktop')
$vbScriptPath = "$scriptFolder\SwitchDisplayVDD.vbs"
$iconPath = "$scriptFolder\VirtualDisplayDriver.ico"
$shortcutPath = "$desktopPath\Switch Display to Virtual Display.lnk"
# Create temp directory
$tempDir = Join-Path $env:TEMP "VDDInstall";
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null;

# Download and unzip NefCon
Write-Host "Downloading and extracting NefCon..." -ForegroundColor Cyan;
$NefConZipPath = Join-Path $tempDir "nefcon.zip";
Invoke-WebRequest -Uri $NefConURL -OutFile $NefConZipPath -UseBasicParsing -ErrorAction Stop;
Expand-Archive -Path $NefConZipPath -DestinationPath $tempDir -Force -ErrorAction Stop;
$NefConExe = Join-Path $tempDir "x64\nefconw.exe";

# Download and unzip VDD
Write-Host "Downloading and extracting VDD..." -ForegroundColor Cyan;
$driverZipPath = Join-Path $tempDir 'driver.zip';
Invoke-WebRequest -Uri $DriverURL -OutFile $driverZipPath;
Expand-Archive -Path $driverZipPath -DestinationPath $tempDir -Force;

# Extract the SignPath certificates
Write-Host "Extracting SignPath certificates..." -ForegroundColor Cyan;
$catFile = Join-Path $tempDir 'VirtualDisplayDriver\mttvdd.cat';
$catBytes = [System.IO.File]::ReadAllBytes($catFile);
$certificates = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection;
$certificates.Import($catBytes);

# Create the temp directory for certificates
$certsFolder = Join-Path $tempDir "ExportedCerts";
New-Item -ItemType Directory -Path $certsFolder -Force | Out-Null;

# Write and store the driver certificates on local machine
Write-Host "Installing driver certificates on local machine." -ForegroundColor Cyan;
foreach ($cert in $certificates) {
    $certFilePath = Join-Path -Path $certsFolder -ChildPath "$($cert.Thumbprint).cer";
    $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert) | Set-Content -Path $certFilePath -Encoding Byte;
    Import-Certificate -FilePath $certFilePath -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher";
}

# Install VDD
Write-Host "Installing Virtual Display Driver silently..." -ForegroundColor Cyan;
Push-Location $tempDir;
& $NefConExe install .\VirtualDisplayDriver\MttVDD.inf "Root\MttVDD";
Start-Sleep -Seconds 10;
Pop-Location;

Write-Host "Driver installation completed." -ForegroundColor Green;

# Create the desktop shortcut used to switch to the Virtual Display Driver
Write-Host "Creating Virtual Display Driver desktop shortcut..." -ForegroundColor Cyan;
$WScriptShell = New-Object -ComObject WScript.Shell;
$shortcut = $WScriptShell.CreateShortcut($shortcutPath);
$shortcut.TargetPath = $vbScriptPath;
$shortcut.IconLocation = $iconPath;
$shortcut.Save();

# Remove the scheduled task to prevent further executions
Remove-InstallScheduledTask -TaskName $taskName;

Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue;
