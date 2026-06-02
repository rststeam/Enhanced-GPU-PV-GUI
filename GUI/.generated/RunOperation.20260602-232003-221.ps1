$ErrorActionPreference = 'Continue'
$operationName = 'PreChecks'
$filePath = 'powershell.exe'
$arguments = '-NoProfile -ExecutionPolicy Bypass -File "C:\Users\Caki\Desktop\Enhanced-GPU-PV\Enhanced-GPU-PV-GUI\GUI\.generated\PreChecks.generated.20260602-232003.ps1"'
$workingDirectory = 'C:\Users\Caki\Desktop\Enhanced-GPU-PV\Enhanced-GPU-PV-GUI'
$logFilePath = 'C:\Users\Caki\Desktop\Enhanced-GPU-PV\Enhanced-GPU-PV-GUI\GUI\.generated\logs\20260602-232003.PreChecks.log'
$script:sawFailureText = $false
$script:preCheckBlockingIssues = $null

function Write-RunLog {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return
    }

    $text = ($Value | Out-String).TrimEnd()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return
    }

    foreach ($line in ($text -split "?
")) {
        if ($line -match '(?i)^Press any key to Exit') {
            continue
        }
        if ($operationName -eq 'PreChecks' -and $line -match 'Blocking issues:\s*(\d+)') {
            $script:preCheckBlockingIssues = [int]$Matches[1]
        }
        if ($line -match '(?i)(^|\s)(ERROR|Failed|Cannot|Invalid|already exists|doesn''t exist|No partitionable)') {
            $script:sawFailureText = $true
        }
        Add-Content -LiteralPath $logFilePath -Value ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $line) -Encoding UTF8
    }
}

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $logFilePath) -Force | Out-Null
    Write-RunLog "$operationName started."
    Write-RunLog "Running the project PowerShell script."

    if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) {
        Set-Location -LiteralPath $workingDirectory
    }

    $argumentList = [System.Management.Automation.PSParser]::Tokenize($arguments, [ref]$null) |
        Where-Object { $_.Type -in 'Command', 'CommandParameter', 'CommandArgument', 'String', 'Number' } |
        ForEach-Object { $_.Content }

    & $filePath @argumentList 2>&1 | ForEach-Object {
        Write-RunLog $_
    }

    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 0
    }
    if ($operationName -eq 'Create VM' -and $script:sawFailureText) {
        $exitCode = 1
    }
    if ($operationName -eq 'PreChecks' -and $null -ne $script:preCheckBlockingIssues) {
        $exitCode = if ($script:preCheckBlockingIssues -gt 0) { 1 } else { 0 }
        $script:sawFailureText = $false
    }
    if ($exitCode -eq 0 -and $script:sawFailureText) {
        $exitCode = 1
    }

    if ($exitCode -eq 0) {
        Write-RunLog "$operationName completed successfully."
    }
    else {
        Write-RunLog "$operationName stopped with errors. Exit code: $exitCode."
    }
    exit $exitCode
}
catch {
    Write-RunLog ("ERROR: " + $_.Exception.Message)
    Write-RunLog ($_ | Out-String)
    exit 1
}
