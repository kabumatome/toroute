[CmdletBinding()]
param(
    [switch]$Quick,
    [switch]$SkipArm64,
    [switch]$KeepContainers,
    [switch]$PreflightOnly,
    [switch]$NoCache,
    [int]$LiveTimeoutSeconds = 420,
    [string]$OutputRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
Set-Location $RepoRoot

$Version = "0.4.0-rc.12"
$Stamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepoRoot "validation-results"
}
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$OutputDir = Join-Path $OutputRoot "ToRoute-Docker-Validation-$Stamp"
$ArchivePath = Join-Path $OutputRoot "ToRoute-Docker-Validation-$Stamp.zip"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$CommandLog = Join-Path $OutputDir "commands.log"
$Checks = New-Object System.Collections.ArrayList
$Project = ("toroute-validation-" + $Stamp.ToLowerInvariant())
$ComposeFile = Join-Path $RepoRoot "tests\docker-validation.yml"
$Amd64Image = "toroute:validation-amd64"
$Arm64Image = "toroute:validation-arm64"
$NetprobeImage = "toroute-netprobe:validation"
$ProxycheckImage = "toroute-proxycheck:validation"
$ComposeStarted = $false
$FatalMessage = ""
$BootstrapMilliseconds = 0
$TranscriptStarted = $false
$TranscriptPath = Join-Path $OutputDir "powershell-transcript.txt"
try {
    Start-Transcript -LiteralPath $TranscriptPath -Force | Out-Null
    $TranscriptStarted = $true
}
catch {
    Set-Content -LiteralPath (Join-Path $OutputDir "transcript-start-error.txt") -Value $_.Exception.ToString() -Encoding UTF8
}
Write-Host "ToRoute Docker validation $Version started." -ForegroundColor Cyan
Write-Host "Repository: $RepoRoot"
Write-Host "Evidence directory: $OutputDir"

function Format-Argument([string]$Value) {
    if ($null -eq $Value) { return '""' }
    if ($Value -match '[\s"`$]') {
        return '"' + ($Value -replace '"', '""') + '"'
    }
    return $Value
}

function Read-TextFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    return [System.IO.File]::ReadAllText($Path)
}

function Convert-ToNativeCommandLineArgument([string]$Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    # Quote according to the Windows CommandLineToArgvW rules used by Go,
    # Docker CLI, and most native Windows programs. Backslashes immediately
    # before a quote or the closing quote must be doubled.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            for ($index = 0; $index -lt (($backslashes * 2) + 1); $index++) {
                [void]$builder.Append([char]92)
            }
            [void]$builder.Append([char]34)
            $backslashes = 0
            continue
        }
        for ($index = 0; $index -lt $backslashes; $index++) {
            [void]$builder.Append([char]92)
        }
        $backslashes = 0
        [void]$builder.Append($character)
    }
    for ($index = 0; $index -lt ($backslashes * 2); $index++) {
        [void]$builder.Append([char]92)
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$LogFile = "",
        [switch]$AllowFailure,
        [switch]$Quiet
    )
    foreach ($argument in $Arguments) {
        if ($null -ne $argument -and ($argument.IndexOf("`r") -ge 0 -or $argument.IndexOf("`n") -ge 0)) {
            throw "Native command arguments must not contain CR or LF. Use direct file reads or separate arguments."
        }
        if ($null -ne $argument -and $argument.IndexOf([char]0) -ge 0) {
            throw "Native command arguments must not contain NUL."
        }
    }
    $display = $FilePath + " " + (($Arguments | ForEach-Object { Format-Argument $_ }) -join " ")
    if (-not $Quiet) {
        Write-Host "`n> $display" -ForegroundColor DarkCyan
    }
    Add-Content -LiteralPath $CommandLog -Value ("`n> " + $display) -Encoding UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $FilePath
    $process.StartInfo.Arguments = (($Arguments | ForEach-Object { Convert-ToNativeCommandLineArgument $_ }) -join " ")
    $process.StartInfo.WorkingDirectory = $RepoRoot
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $process.StartInfo.StandardOutputEncoding = $utf8NoBom
    $process.StartInfo.StandardErrorEncoding = $utf8NoBom

    $exitCode = 127
    $stdout = ""
    $stderr = ""
    try {
        if (-not $process.Start()) {
            throw "Failed to start native process: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $process.ExitCode
    }
    catch {
        $stderr = $_.Exception.ToString()
        $exitCode = 127
    }
    finally {
        $process.Dispose()
    }

    $combinedParts = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { [void]$combinedParts.Add($stdout.TrimEnd()) }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { [void]$combinedParts.Add($stderr.TrimEnd()) }
    $combined = ($combinedParts -join "`n")
    if (-not $Quiet -and $combined.Length -gt 0) { Write-Host $combined }
    if ($combined.Length -gt 0) { Add-Content -LiteralPath $CommandLog -Value $combined -Encoding UTF8 }
    Add-Content -LiteralPath $CommandLog -Value ("[exit=" + $exitCode + "]") -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Set-Content -LiteralPath $LogFile -Value $combined -Encoding UTF8
    }
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $display. See $CommandLog"
    }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = $stdout.TrimEnd()
        StdOut = $stdout.TrimEnd()
        StdErr = $stderr.TrimEnd()
        Combined = $combined
        Command = $display
    }
}


function Resolve-DockerHealthAction {
    param(
        [Parameter(Mandatory = $true)][string]$ContainerStatus,
        [AllowEmptyString()][string]$HealthStatus
    )
    if ($ContainerStatus -ne "running") { return "fail-container" }
    switch ($HealthStatus) {
        "healthy" { return "ready" }
        "starting" { return "wait" }
        "unhealthy" { return "fail-health" }
        default { return "fail-health-missing" }
    }
}

function Wait-DockerHealthSynchronization {
    param(
        [Parameter(Mandatory = $true)][string]$ContainerId,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$EvidencePath
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastContainerStatus = "unknown"
    $lastHealthStatus = "unknown"
    while ([DateTime]::UtcNow -lt $deadline) {
        $inspectResult = Invoke-Native -FilePath "docker" -Arguments @(
            "inspect", "--format", "{{json .State}}", $ContainerId
        ) -AllowFailure -Quiet
        if ($inspectResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($inspectResult.StdOut)) {
            throw "Docker state inspect failed while synchronizing health."
        }
        try {
            $state = $inspectResult.StdOut | ConvertFrom-Json
        }
        catch {
            throw "Docker state JSON was invalid while synchronizing health: $($_.Exception.Message)"
        }
        $lastContainerStatus = [string]$state.Status
        $lastHealthStatus = ""
        $failingStreak = 0
        $healthLogCount = 0
        if ($null -ne $state.Health) {
            $lastHealthStatus = [string]$state.Health.Status
            $failingStreak = [int]$state.Health.FailingStreak
            $healthLogCount = @($state.Health.Log).Count
        }
        $action = Resolve-DockerHealthAction -ContainerStatus $lastContainerStatus -HealthStatus $lastHealthStatus
        $record = [ordered]@{
            observed_at_utc = [DateTime]::UtcNow.ToString("o")
            container_status = $lastContainerStatus
            health_status = $lastHealthStatus
            failing_streak = $failingStreak
            health_log_count = $healthLogCount
            action = $action
        }
        Add-Content -LiteralPath $EvidencePath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
        switch ($action) {
            "ready" { return }
            "wait" {
                Write-Host "Tor is ready; waiting for Docker health state to become healthy..."
                Start-Sleep -Seconds 2
            }
            "fail-container" { throw "ToRoute container stopped before Docker health synchronization: $lastContainerStatus" }
            "fail-health" { throw "Docker marked ToRoute unhealthy after Tor reported ready." }
            default { throw "Docker health state is missing or unsupported after Tor reported ready: $lastHealthStatus" }
        }
    }
    throw "Docker health synchronization timed out after ${TimeoutSeconds}s: container=$lastContainerStatus health=$lastHealthStatus"
}

function Wait-ToRouteReadiness {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)][string]$ComposePath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$EvidencePath
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastProgress = -1
    $lastTag = "unknown"
    $lastSummary = "No bootstrap status received"
    $torouteId = ""
    while ([DateTime]::UtcNow -lt $deadline) {
        if ([string]::IsNullOrWhiteSpace($torouteId)) {
            $idResult = Invoke-Native -FilePath "docker" -Arguments @(
                "compose", "-p", $ProjectName, "-f", $ComposePath, "ps", "-q", "toroute"
            ) -AllowFailure -Quiet
            if ($idResult.ExitCode -eq 0) { $torouteId = $idResult.StdOut.Trim() }
        }
        if (-not [string]::IsNullOrWhiteSpace($torouteId)) {
            $inspectResult = Invoke-Native -FilePath "docker" -Arguments @(
                "inspect", "--format", "{{.State.Status}}", $torouteId
            ) -AllowFailure -Quiet
            if ($inspectResult.ExitCode -ne 0) {
                throw "ToRoute container inspect failed during bootstrap."
            }
            $state = $inspectResult.StdOut.Trim()
            if ($state -ne "running") {
                throw "ToRoute container stopped during bootstrap: $state"
            }

            $healthResult = Invoke-Native -FilePath "docker" -Arguments @(
                "exec", $torouteId, "/usr/local/bin/toroute", "healthcheck", "--json"
            ) -AllowFailure -Quiet
            $status = $null
            if (-not [string]::IsNullOrWhiteSpace($healthResult.StdOut)) {
                try { $status = $healthResult.StdOut | ConvertFrom-Json } catch { $status = $null }
            }
            if ($null -ne $status) {
                $lastProgress = [int]$status.bootstrap_progress
                $lastTag = [string]$status.bootstrap_tag
                $lastSummary = [string]$status.bootstrap_summary
                $record = [ordered]@{
                    observed_at_utc = [DateTime]::UtcNow.ToString("o")
                    exit_code = [int]$healthResult.ExitCode
                    ready = [bool]$status.ready
                    bootstrap_progress = $lastProgress
                    bootstrap_tag = $lastTag
                    bootstrap_summary = $lastSummary
                }
                Add-Content -LiteralPath $EvidencePath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
                Write-Host ("Bootstrap {0}% ({1}): {2}" -f $lastProgress, $lastTag, $lastSummary)
                if ($healthResult.ExitCode -eq 0 -and $status.ready -eq $true -and $lastProgress -eq 100) {
                    return $torouteId
                }
            }
            else {
                $record = [ordered]@{
                    observed_at_utc = [DateTime]::UtcNow.ToString("o")
                    exit_code = [int]$healthResult.ExitCode
                    parse_error = $true
                    stdout = $healthResult.StdOut
                    stderr = $healthResult.StdErr
                }
                Add-Content -LiteralPath $EvidencePath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
            }
        }
        Start-Sleep -Seconds 5
    }
    throw "Tor bootstrap timed out after ${TimeoutSeconds}s at ${lastProgress}% (${lastTag}): $lastSummary"
}

function Resolve-SourceCommit {
    $gitDirectory = Join-Path $RepoRoot ".git"
    if ((Test-Path -LiteralPath $gitDirectory) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $gitResult = Invoke-Native -FilePath "git" -Arguments @("rev-parse", "HEAD") -AllowFailure -Quiet
        if ($gitResult.ExitCode -eq 0 -and $gitResult.Output -match '^[0-9a-fA-F]{7,64}$') {
            return $gitResult.Output.Trim().ToLowerInvariant()
        }
    }

    $metadataPath = Join-Path $RepoRoot "SOURCE_METADATA.json"
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            $value = [string]$metadata.source_commit
            if ($value -match '^[0-9a-fA-F]{7,64}$') { return $value.ToLowerInvariant() }
        }
        catch {
            throw "SOURCE_METADATA.json is invalid: $($_.Exception.Message)"
        }
    }
    throw "Source identity unavailable. Use a Git checkout or an official source package containing a valid SOURCE_METADATA.json."
}

function Test-PowerShellRuntime {
    $selfTestDirectory = Join-Path $OutputDir "native runner self test"
    New-Item -ItemType Directory -Force -Path $selfTestDirectory | Out-Null
    $selfTest = Join-Path $selfTestDirectory "native-runner-self-test.ps1"
    $selfTestBody = @'
param([string]$Value)
[Console]::Out.WriteLine("toroute-selftest-stdout:" + $Value)
[Console]::Error.WriteLine("toroute-selftest-stderr:" + $Value)
exit 7
'@
    [System.IO.File]::WriteAllText($selfTest, $selfTestBody, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $currentPowerShell = (Get-Process -Id $PID).Path
        $argumentValue = 'value with spaces "quotes" $dollar'
        $result = Invoke-Native -FilePath $currentPowerShell -Arguments @(
            "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", $selfTest, "-Value", $argumentValue
        ) -AllowFailure -Quiet
        Assert-True ($result.ExitCode -eq 7) "Native runner did not preserve exit code 7."
        Assert-True ($result.StdOut -match 'toroute-selftest-stdout:value with spaces "quotes" \$dollar') "Native runner did not preserve a spaced stdout argument."
        Assert-True ($result.StdErr -match 'toroute-selftest-stderr:value with spaces "quotes" \$dollar') "Native runner did not preserve a spaced stderr argument."

        $newlineRejected = $false
        try {
            $null = Invoke-Native -FilePath $currentPowerShell -Arguments @("line1`nline2") -AllowFailure -Quiet
        }
        catch {
            $newlineRejected = $_.Exception.Message -match 'must not contain CR or LF'
        }
        Assert-True $newlineRejected "Native runner accepted a multiline command argument."

        $v2Sample = Convert-CgroupValues -MemoryText "123456" -PidsText "17" -CpuText "usage_usec 7890`nuser_usec 4000" -CpuPath "/sys/fs/cgroup/cpu.stat"
        Assert-True ($v2Sample.memory_bytes -eq 123456 -and $v2Sample.pids -eq 17 -and $v2Sample.cpu_usage_usec -eq 7890 -and $v2Sample.cgroup_version -eq 2) "cgroup v2 parser self-test failed."
        $v1Sample = Convert-CgroupValues -MemoryText "654321" -PidsText "9" -CpuText "12345000" -CpuPath "/sys/fs/cgroup/cpuacct/cpuacct.usage"
        Assert-True ($v1Sample.memory_bytes -eq 654321 -and $v1Sample.pids -eq 9 -and $v1Sample.cpu_usage_usec -eq 12345 -and $v1Sample.cgroup_version -eq 1) "cgroup v1 parser self-test failed."

        Assert-True ((Resolve-DockerHealthAction -ContainerStatus "running" -HealthStatus "starting") -eq "wait") "Docker health starting transition self-test failed."
        Assert-True ((Resolve-DockerHealthAction -ContainerStatus "running" -HealthStatus "healthy") -eq "ready") "Docker health healthy transition self-test failed."
        Assert-True ((Resolve-DockerHealthAction -ContainerStatus "running" -HealthStatus "unhealthy") -eq "fail-health") "Docker health unhealthy transition self-test failed."
        Assert-True ((Resolve-DockerHealthAction -ContainerStatus "exited" -HealthStatus "healthy") -eq "fail-container") "Docker container stop transition self-test failed."
        Assert-True ((Resolve-DockerHealthAction -ContainerStatus "running" -HealthStatus "") -eq "fail-health-missing") "Docker missing health transition self-test failed."

        $probeChecks = New-Object System.Collections.ArrayList
        [void]$probeChecks.Add([pscustomobject]@{ name = "self-test"; status = "passed" })
        $probe = [ordered]@{ checks = @($probeChecks | ForEach-Object { $_ }) }
        $json = $probe | ConvertTo-Json -Depth 5
        Assert-True ($json -match 'self-test') "PowerShell 5.1 failed to serialize evidence collections."

        $identity = Resolve-SourceCommit
        Assert-True (-not [string]::IsNullOrWhiteSpace($identity)) "Source identity resolution returned an empty value."
        Set-Content -LiteralPath (Join-Path $OutputDir "source-identity.txt") -Value $identity -Encoding UTF8
    }
    finally {
        Remove-Item -LiteralPath $selfTestDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Add-Check([string]$Name, [string]$Status, [double]$Seconds, [string]$Detail) {
    [void]$Checks.Add([pscustomobject]@{
        name = $Name
        status = $Status
        elapsed_seconds = [Math]::Round($Seconds, 3)
        detail = $Detail
    })
}

function Invoke-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [switch]$ContinueOnFailure
    )
    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $watch.Stop()
        Add-Check $Name "passed" $watch.Elapsed.TotalSeconds ""
        Write-Host "PASS: $Name" -ForegroundColor Green
        return
    }
    catch {
        $watch.Stop()
        $message = $_.Exception.Message
        Add-Check $Name "failed" $watch.Elapsed.TotalSeconds $message
        Write-Host "FAIL: $Name`n$message" -ForegroundColor Red
        if (-not $ContinueOnFailure) {
            throw
        }
        return
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-ExpectedFailure([string]$Description, [string[]]$Arguments) {
    $result = Invoke-Native -FilePath "docker" -Arguments $Arguments -AllowFailure
    if ($result.ExitCode -eq 0) {
        throw "Expected failure was accepted: $Description"
    }
}

function Parse-Version([string]$Text) {
    $match = [regex]::Match($Text, '(\d+)\.(\d+)\.(\d+)')
    if (-not $match.Success) { throw "Unable to parse version: $Text" }
    return [Version]("{0}.{1}.{2}" -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value)
}

function Convert-LittleEndianGateway([string]$Hex) {
    if ($Hex -notmatch '^[0-9A-Fa-f]{8}$') { throw "Invalid route gateway value: $Hex" }
    $bytes = @(0, 2, 4, 6) | ForEach-Object { [Convert]::ToInt32($Hex.Substring($_, 2), 16) }
    [Array]::Reverse($bytes)
    return ($bytes -join '.')
}

function Read-ContainerFile {
    param(
        [Parameter(Mandatory = $true)][string]$ContainerId,
        [Parameter(Mandatory = $true)][string[]]$CandidatePaths,
        [Parameter(Mandatory = $true)][string]$MetricName
    )
    foreach ($candidatePath in $CandidatePaths) {
        $result = Invoke-Native -FilePath "docker" -Arguments @(
            "exec", $ContainerId, "/bin/cat", $candidatePath
        ) -AllowFailure -Quiet
        if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.StdOut)) {
            return [pscustomobject]@{
                Path = $candidatePath
                Text = $result.StdOut.Trim()
            }
        }
    }
    throw "Unable to read $MetricName from container cgroup files: $($CandidatePaths -join ', ')"
}

function Convert-ToNonNegativeInt64 {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$MetricName
    )
    $trimmed = $Text.Trim()
    if ($trimmed -notmatch '^[0-9]+$') {
        throw "Invalid non-negative integer for ${MetricName}: $trimmed"
    }
    try {
        return [int64]::Parse($trimmed, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw "Out-of-range integer for ${MetricName}: $trimmed"
    }
}

function Convert-CgroupValues {
    param(
        [Parameter(Mandatory = $true)][string]$MemoryText,
        [Parameter(Mandatory = $true)][string]$PidsText,
        [Parameter(Mandatory = $true)][string]$CpuText,
        [Parameter(Mandatory = $true)][string]$CpuPath
    )
    $memory = Convert-ToNonNegativeInt64 -Text $MemoryText -MetricName "memory_bytes"
    $pids = Convert-ToNonNegativeInt64 -Text $PidsText -MetricName "pids"
    if ($CpuPath -eq "/sys/fs/cgroup/cpu.stat") {
        $usageMatch = [regex]::Match($CpuText, '(?m)^usage_usec\s+([0-9]+)\s*$')
        if (-not $usageMatch.Success) {
            throw "cpu.stat does not contain usage_usec"
        }
        $cpuUsageUsec = Convert-ToNonNegativeInt64 -Text $usageMatch.Groups[1].Value -MetricName "cpu_usage_usec"
        $cgroupVersion = 2
    }
    else {
        $cpuUsageNanoseconds = Convert-ToNonNegativeInt64 -Text $CpuText -MetricName "cpuacct.usage"
        $cpuUsageUsec = [int64][Math]::Floor($cpuUsageNanoseconds / 1000.0)
        $cgroupVersion = 1
    }
    return [pscustomobject]@{
        memory_bytes = $memory
        pids = $pids
        cpu_usage_usec = $cpuUsageUsec
        cgroup_version = $cgroupVersion
    }
}

function Get-CgroupSample([string]$ContainerId) {
    $memoryFile = Read-ContainerFile -ContainerId $ContainerId -CandidatePaths @(
        "/sys/fs/cgroup/memory.current",
        "/sys/fs/cgroup/memory/memory.usage_in_bytes"
    ) -MetricName "memory"
    $pidsFile = Read-ContainerFile -ContainerId $ContainerId -CandidatePaths @(
        "/sys/fs/cgroup/pids.current",
        "/sys/fs/cgroup/pids/pids.current"
    ) -MetricName "pids"
    $cpuFile = Read-ContainerFile -ContainerId $ContainerId -CandidatePaths @(
        "/sys/fs/cgroup/cpu.stat",
        "/sys/fs/cgroup/cpuacct/cpuacct.usage"
    ) -MetricName "cpu"
    $sample = Convert-CgroupValues -MemoryText $memoryFile.Text -PidsText $pidsFile.Text -CpuText $cpuFile.Text -CpuPath $cpuFile.Path
    return [pscustomobject]@{
        memory_bytes = $sample.memory_bytes
        pids = $sample.pids
        cpu_usage_usec = $sample.cpu_usage_usec
        cgroup_version = $sample.cgroup_version
        memory_source = $memoryFile.Path
        pids_source = $pidsFile.Path
        cpu_source = $cpuFile.Path
    }
}

function Write-FinalReports([bool]$Succeeded) {
    $failed = @($Checks | Where-Object { $_.status -eq "failed" })
    $result = [ordered]@{
        schema_version = 1
        toroute_version = $Version
        generated_at_utc = [DateTime]::UtcNow.ToString("o")
        succeeded = $Succeeded
        quick_mode = [bool]$Quick
        arm64_requested = -not [bool]$SkipArm64
        project = $Project
        bootstrap_milliseconds = $BootstrapMilliseconds
        fatal_message = $FatalMessage
        checks = @($Checks | ForEach-Object { $_ })
    }
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $OutputDir "result.json") -Encoding UTF8

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# ToRoute Docker検証結果")
    [void]$lines.Add("")
    [void]$lines.Add("- 実行日時（UTC）: $($result.generated_at_utc)")
    [void]$lines.Add("- ToRoute: $Version")
    [void]$lines.Add("- 総合結果: " + ($(if ($Succeeded) { "**成功**" } else { "**失敗**" })))
    [void]$lines.Add("- Bootstrap: $BootstrapMilliseconds ms")
    [void]$lines.Add("")
    [void]$lines.Add("| 検証 | 結果 | 秒 | 詳細 |")
    [void]$lines.Add("|---|---:|---:|---|")
    foreach ($check in $Checks) {
        $detail = ($check.detail -replace '\|', '\|' -replace "`r?`n", ' ')
        [void]$lines.Add("| $($check.name) | $($check.status) | $($check.elapsed_seconds) | $detail |")
    }
    if ($failed.Count -gt 0) {
        [void]$lines.Add("")
        [void]$lines.Add("## 失敗項目")
        foreach ($check in $failed) { [void]$lines.Add("- **$($check.name)**: $($check.detail)") }
    }
    [void]$lines.Add("")
    [void]$lines.Add("このディレクトリと生成ZIPは非公開で保管し、公開先にはsanitized summaryだけを共有してください。")
    $lines | Set-Content -LiteralPath (Join-Path $OutputDir "SUMMARY.md") -Encoding UTF8
}

try {
    Invoke-Check -Name "Windows PowerShell runtime self-test" -Action {
        Test-PowerShellRuntime
    }

    $commit = Resolve-SourceCommit
    $buildDate = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $cacheArgs = @()
    if ($NoCache) { $cacheArgs = @("--no-cache") }

    if ($PreflightOnly) {
        Write-Host "Preflight-only runtime validation completed successfully." -ForegroundColor Green
    }
    else {
        Invoke-Check -Name "Docker Desktop / Compose / Buildx前提確認" -Action {
            $null = Get-Command docker -ErrorAction Stop
            $versionResult = Invoke-Native -FilePath "docker" -Arguments @("version", "--format", "{{json .}}") -LogFile (Join-Path $OutputDir "docker-version.json")
            $versionObject = $versionResult.Output | ConvertFrom-Json
            Assert-True ($null -ne $versionObject.Server) "Docker daemonへ接続できません。Docker Desktopを起動してください。"
            $engineVersion = Parse-Version ([string]$versionObject.Server.Version)
            Assert-True ($engineVersion -ge [Version]"25.0.0") "Docker Engine 25.0以降が必要です。現在: $engineVersion"
            $info = Invoke-Native -FilePath "docker" -Arguments @("info", "--format", "{{json .}}") -LogFile (Join-Path $OutputDir "docker-info.json")
            $infoObject = $info.Output | ConvertFrom-Json
            Assert-True ($infoObject.OSType -eq "linux") "Docker DesktopをLinux containersモードへ切り替えてください。"
            $compose = Invoke-Native -FilePath "docker" -Arguments @("compose", "version", "--short")
            $composeVersion = Parse-Version $compose.Output
            Assert-True ($composeVersion -ge [Version]"2.33.1") "Docker Compose 2.33.1以降が必要です。現在: $composeVersion"
            $null = Invoke-Native -FilePath "docker" -Arguments @("buildx", "version") -LogFile (Join-Path $OutputDir "buildx-version.txt")
            $null = Invoke-Native -FilePath "docker" -Arguments @("compose", "-f", $ComposeFile, "config", "--quiet")
        }

    Invoke-Check -Name "amd64 runtime / netprobe / proxycheckビルド" -Action {
        $runtimeArgs = @("buildx", "build", "--pull", "--load", "--platform", "linux/amd64", "--target", "runtime") + $cacheArgs + @(
            "--build-arg", "VERSION=$Version", "--build-arg", "COMMIT=$commit", "--build-arg", "BUILD_DATE=$buildDate",
            "--tag", $Amd64Image, "."
        )
        $null = Invoke-Native -FilePath "docker" -Arguments $runtimeArgs -LogFile (Join-Path $OutputDir "build-amd64.log")
        $null = Invoke-Native -FilePath "docker" -Arguments (@("buildx", "build", "--pull", "--load", "--platform", "linux/amd64", "--target", "netprobe") + $cacheArgs + @("--tag", $NetprobeImage, ".")) -LogFile (Join-Path $OutputDir "build-netprobe.log")
        $null = Invoke-Native -FilePath "docker" -Arguments (@("buildx", "build", "--pull", "--load", "--platform", "linux/amd64", "--target", "proxycheck") + $cacheArgs + @("--tag", $ProxycheckImage, ".")) -LogFile (Join-Path $OutputDir "build-proxycheck.log")
    }

    Invoke-Check -Name "イメージmetadata・non-root・設定境界" -Action {
        $inspectResult = Invoke-Native -FilePath "docker" -Arguments @("image", "inspect", $Amd64Image) -LogFile (Join-Path $OutputDir "image-inspect.json")
        $image = @($inspectResult.Output | ConvertFrom-Json)[0]
        Assert-True ($image.Config.User -eq "65532:65532") "Image USERが65532:65532ではありません。"
        Assert-True ($image.Config.Labels.'org.opencontainers.image.title' -eq "ToRoute") "OCI title labelが不正です。"
        $ports = @($image.Config.ExposedPorts.PSObject.Properties.Name)
        Assert-True ($ports.Count -eq 1 -and $ports[0] -eq "9050/tcp") "Imageは9050/tcpだけをEXPOSEする必要があります。"
        Assert-True ($image.Config.Healthcheck.Test -contains "/usr/local/bin/toroute") "HealthcheckがToRoute CLIを使用していません。"

        $base = @("run", "--rm", "--platform", "linux/amd64", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges", "--pids-limit", "128", "--tmpfs", "/run/toroute:uid=65532,gid=65532,mode=0700", "--tmpfs", "/var/lib/toroute:uid=65532,gid=65532,mode=0700")
        $null = Invoke-Native -FilePath "docker" -Arguments ($base + @($Amd64Image, "check-config"))
        $jsonResult = Invoke-Native -FilePath "docker" -Arguments ($base + @($Amd64Image, "print-config", "--format", "json"))
        $cfg = $jsonResult.Output | ConvertFrom-Json
        Assert-True ($cfg.socks_address -eq "0.0.0.0:9050" -and $cfg.http_enabled -eq $false) "既定設定が不正です。"
        $uidResult = Invoke-Native -FilePath "docker" -Arguments ($base + @("--entrypoint", "/usr/bin/id", $Amd64Image, "-u"))
        Assert-True ($uidResult.Output.Trim() -eq "65532") "実行UIDが65532ではありません。"

        Assert-ExpectedFailure "未知TOROUTE変数" ($base + @("-e", "TOROUTE_UNKNOWN=1", $Amd64Image, "check-config"))
        Assert-ExpectedFailure "実行binary上書き" ($base + @("-e", "TOROUTE_TOR_BINARY=/tmp/tor", $Amd64Image, "check-config"))
        Assert-ExpectedFailure "任意TOR_注入" ($base + @("-e", "TOR_SocksPort=", $Amd64Image, "check-config"))
        Assert-ExpectedFailure "空Boolean" ($base + @("-e", "TOROUTE_HTTP_ENABLED=", $Amd64Image, "check-config"))
        Assert-ExpectedFailure "relay role設定" ($base + @("-e", "EXITNODE=1", $Amd64Image, "check-config"))
        Assert-ExpectedFailure "共有system directory" ($base + @("-e", "TOROUTE_DATA_DIR=/tmp", $Amd64Image, "check-config"))
    }

    $env:TOROUTE_TEST_IMAGE = $Amd64Image
    $env:TOROUTE_NETPROBE_IMAGE = $NetprobeImage
    $env:TOROUTE_PROXYCHECK_IMAGE = $ProxycheckImage

    Invoke-Check -Name "hardened Compose起動・readiness" -Action {
        $started = [DateTime]::UtcNow
        $script:ComposeStarted = $true
        $null = Invoke-Native -FilePath "docker" -Arguments @("compose", "-p", $Project, "-f", $ComposeFile, "up", "-d", "toroute", "egress-target") -LogFile (Join-Path $OutputDir "compose-up.log")
        $progressPath = Join-Path $OutputDir "bootstrap-progress.jsonl"
        $torouteId = Wait-ToRouteReadiness -ProjectName $Project -ComposePath $ComposeFile -TimeoutSeconds $LiveTimeoutSeconds -EvidencePath $progressPath
        $script:BootstrapMilliseconds = [int64]([DateTime]::UtcNow - $started).TotalMilliseconds
        $healthSyncPath = Join-Path $OutputDir "docker-health-sync.jsonl"
        Wait-DockerHealthSynchronization -ContainerId $torouteId -TimeoutSeconds 45 -EvidencePath $healthSyncPath

        Assert-True (-not [string]::IsNullOrWhiteSpace($torouteId)) "ToRoute container IDを取得できません。"
        Set-Content -LiteralPath (Join-Path $OutputDir "toroute-container-id.txt") -Value $torouteId -Encoding UTF8
        $containerInspectResult = Invoke-Native -FilePath "docker" -Arguments @("inspect", $torouteId) -LogFile (Join-Path $OutputDir "container-inspect.json")
        $container = @($containerInspectResult.Output | ConvertFrom-Json)[0]
        Assert-True ($container.State.Status -eq "running") "ToRoute containerがrunningではありません。"
        Assert-True ($container.State.Health.Status -eq "healthy") "ToRoute containerがhealthyではありません。"
        Assert-True ($container.HostConfig.ReadonlyRootfs -eq $true) "read-only root filesystemが無効です。"
        Assert-True (@($container.HostConfig.CapDrop) -contains "ALL") "cap_drop ALLがありません。"
        Assert-True (@($container.HostConfig.SecurityOpt) -contains "no-new-privileges:true") "no-new-privilegesがありません。"
        Assert-True ([int64]$container.HostConfig.PidsLimit -eq 128) "pids_limitが128ではありません。"
        Assert-True ($container.Config.User -eq "65532:65532") "Container USERが不正です。"
        foreach ($property in $container.NetworkSettings.Ports.PSObject.Properties) {
            Assert-True ($null -eq $property.Value) "Host portが公開されています: $($property.Name)"
        }

        $statusResult = Invoke-Native -FilePath "docker" -Arguments @("exec", $torouteId, "/usr/local/bin/toroute", "status", "--json") -LogFile (Join-Path $OutputDir "status.json")
        $status = $statusResult.Output | ConvertFrom-Json
        Assert-True ($status.ready -eq $true -and [int]$status.bootstrap_progress -eq 100) "Tor statusがreadyではありません。"
        $procResult = Invoke-Native -FilePath "docker" -Arguments @("exec", $torouteId, "/bin/cat", "/proc/1/status")
        $securityLines = @($procResult.StdOut -split "`r?`n" | Where-Object { $_ -match '^(Uid|Gid|CapEff|NoNewPrivs):' })
        $securityText = $securityLines -join "`n"
        Set-Content -LiteralPath (Join-Path $OutputDir "pid1-security.txt") -Value $securityText -Encoding UTF8
        Assert-True ($securityText -match 'CapEff:\s+0{16}') "PID 1にeffective capabilityが残っています。"
        Assert-True ($securityText -match 'NoNewPrivs:\s+1') "PID 1のNoNewPrivsが1ではありません。"

        $clientNetwork = "${Project}_client"
        $egressNetwork = "${Project}_egress"
        $egressProperty = @($container.NetworkSettings.Networks.PSObject.Properties | Where-Object { $_.Name -eq $egressNetwork })
        Assert-True ($egressProperty.Count -eq 1) "egress network endpointを特定できません。"
        $egressGateway = $egressProperty[0].Value.Gateway
        $routeResult = Invoke-Native -FilePath "docker" -Arguments @("exec", $torouteId, "/bin/cat", "/proc/net/route") -LogFile (Join-Path $OutputDir "proc-net-route.txt")
        $defaultRoute = @($routeResult.StdOut -split "`r?`n" | ForEach-Object {
            $columns = @($_ -split '\s+' | Where-Object { $_ -ne '' })
            if ($columns.Count -ge 3 -and $columns[1] -eq "00000000") { $columns[2] }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-True ($defaultRoute.Count -eq 1) "default routeを一意に特定できません。"
        $actualGateway = Convert-LittleEndianGateway $defaultRoute[0]
        Assert-True ($actualGateway -eq $egressGateway) "default gatewayがegress networkではありません: $actualGateway != $egressGateway"
    }

    Invoke-Check -Name "client network直通防止・proxy到達" -Action {
        $clientNetwork = "${Project}_client"
        $egressNetwork = "${Project}_egress"
        $targetId = (Invoke-Native -FilePath "docker" -Arguments @("compose", "-p", $Project, "-f", $ComposeFile, "ps", "-q", "egress-target")).Output.Trim()
        $targetInspect = @((Invoke-Native -FilePath "docker" -Arguments @("inspect", $targetId)).Output | ConvertFrom-Json)[0]
        $targetProperty = @($targetInspect.NetworkSettings.Networks.PSObject.Properties | Where-Object { $_.Name -eq $egressNetwork })
        Assert-True ($targetProperty.Count -eq 1) "egress target network endpointを特定できません。"
        $targetIP = $targetProperty[0].Value.IPAddress
        Assert-True ($targetIP -match '^\d+\.\d+\.\d+\.\d+$') "egress target IPを取得できません。"
        $null = Invoke-Native -FilePath "docker" -Arguments @("run", "--rm", "--network", $clientNetwork, $NetprobeImage, "--timeout", "3s", "--expect", "success", "toroute:9050")
        $null = Invoke-Native -FilePath "docker" -Arguments @("run", "--rm", "--network", $clientNetwork, $NetprobeImage, "--timeout", "3s", "--expect", "failure", "${targetIP}:8080")
        $null = Invoke-Native -FilePath "docker" -Arguments @("run", "--rm", "--network", $egressNetwork, $NetprobeImage, "--timeout", "3s", "--expect", "success", "${targetIP}:8080")
    }

    if (-not $Quick) {
        Invoke-Check -Name "SOCKS5 remote DNS・Tor実通信" -Action {
            $clientNetwork = "${Project}_client"
            $torResult = Invoke-Native -FilePath "docker" -Arguments @("run", "--rm", "--network", $clientNetwork, $ProxycheckImage, "--proxy", "socks5", "--proxy-address", "toroute:9050", "--timeout", "90s") -LogFile (Join-Path $OutputDir "proxycheck-socks-tor.json")
            $tor = $torResult.Output | ConvertFrom-Json
            Assert-True ($tor.is_tor -eq $true -and $tor.remote_dns -eq $true) "SOCKS5 Tor判定またはremote DNS判定に失敗しました。"
            $null = Invoke-Native -FilePath "docker" -Arguments @("run", "--rm", "--network", $clientNetwork, $ProxycheckImage, "--proxy", "socks5", "--proxy-address", "toroute:9050", "--url", "https://example.com/", "--expect-tor=false", "--timeout", "90s") -LogFile (Join-Path $OutputDir "proxycheck-socks-example.json")
        }

        Invoke-Check -Name "HTTP CONNECT・Tor実通信" -Action {
            $clientNetwork = "${Project}_client"
            $torResult = Invoke-Native -FilePath "docker" -Arguments @("run", "--rm", "--network", $clientNetwork, $ProxycheckImage, "--proxy", "http", "--proxy-address", "toroute:8118", "--timeout", "90s") -LogFile (Join-Path $OutputDir "proxycheck-http-tor.json")
            $tor = $torResult.Output | ConvertFrom-Json
            Assert-True ($tor.is_tor -eq $true) "HTTP proxy Tor判定に失敗しました。"
            $null = Invoke-Native -FilePath "docker" -Arguments @("run", "--rm", "--network", $clientNetwork, $ProxycheckImage, "--proxy", "http", "--proxy-address", "toroute:8118", "--url", "https://example.com/", "--expect-tor=false", "--timeout", "90s") -LogFile (Join-Path $OutputDir "proxycheck-http-example.json")
        }

        Invoke-Check -Name "NEWNYM・Control往復" -Action {
            $torouteId = Get-Content -LiteralPath (Join-Path $OutputDir "toroute-container-id.txt") -Raw
            $torouteId = $torouteId.Trim()
            $null = Invoke-Native -FilePath "docker" -Arguments @("exec", $torouteId, "/usr/local/bin/toroute", "newnym") -LogFile (Join-Path $OutputDir "newnym.txt")
            Start-Sleep -Seconds 2
            $null = Invoke-Native -FilePath "docker" -Arguments @("exec", $torouteId, "/usr/local/bin/toroute", "healthcheck", "--json") -LogFile (Join-Path $OutputDir "health-after-newnym.json")
        }

        Invoke-Check -Name "runtime metrics・package inventory" -ContinueOnFailure -Action {
            $torouteId = (Get-Content -LiteralPath (Join-Path $OutputDir "toroute-container-id.txt") -Raw).Trim()
            $imageInspect = @((Invoke-Native -FilePath "docker" -Arguments @("image", "inspect", $Amd64Image)).Output | ConvertFrom-Json)[0]
            $packageResult = Invoke-Native -FilePath "docker" -Arguments @("run", "--rm", "--entrypoint", "/usr/bin/dpkg-query", $Amd64Image, "-W", '-f=${binary:Package}\t${Version}\t${Installed-Size}\n') -LogFile (Join-Path $OutputDir "packages.tsv")
            $packageLines = @($packageResult.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $samples = New-Object System.Collections.ArrayList
            for ($index = 0; $index -lt 6; $index++) {
                [void]$samples.Add((Get-CgroupSample $torouteId))
                if ($index -lt 5) { Start-Sleep -Seconds 2 }
            }
            $memValues = @($samples | ForEach-Object { [int64]$_.memory_bytes } | Sort-Object)
            $cpuDelta = [int64]$samples[$samples.Count - 1].cpu_usage_usec - [int64]$samples[0].cpu_usage_usec
            Assert-True ($cpuDelta -ge 0) "cgroup CPU counterが逆行しました。"
            $metrics = [ordered]@{
                schema_version = 1
                profile = "full-http"
                image_reference = $Amd64Image
                image_id = $imageInspect.Id
                image_size_bytes = [int64]$imageInspect.Size
                package_count = $packageLines.Count
                bootstrap_milliseconds = $BootstrapMilliseconds
                sample_duration_seconds = 10
                steady_memory_min_bytes = $memValues[0]
                steady_memory_median_bytes = $memValues[[int][Math]::Floor($memValues.Count / 2)]
                steady_memory_max_bytes = $memValues[$memValues.Count - 1]
                pids_max = (@($samples | ForEach-Object { [int64]$_.pids } | Measure-Object -Maximum).Maximum)
                idle_cpu_usage_delta_usec = $cpuDelta
                idle_cpu_usec_per_second = [int64][Math]::Round($cpuDelta / 10.0)
                samples = @($samples | ForEach-Object { $_ })
            }
            $metrics | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDir "runtime-metrics.json") -Encoding UTF8
        }
    }

    Invoke-Check -Name "ログ秘密情報・異常文字列監査" -Action {
        $torouteId = (Get-Content -LiteralPath (Join-Path $OutputDir "toroute-container-id.txt") -Raw).Trim()
        $logs = Invoke-Native -FilePath "docker" -Arguments @("logs", $torouteId) -LogFile (Join-Path $OutputDir "toroute.log")
        $forbidden = @(
            '(?i)BEGIN [A-Z ]*PRIVATE KEY',
            '(?i)password\s*=',
            '(?i)Bridge\s+obfs4\s+\S+',
            '(?i)cert=[A-Za-z0-9+/]+',
            '(?i)AUTHENTICATE\s+[0-9A-F]{32,}'
        )
        foreach ($pattern in $forbidden) {
            Assert-True (-not [regex]::IsMatch($logs.Output, $pattern)) "ログに禁止patternが見つかりました: $pattern"
        }
    }

    if (-not $SkipArm64) {
        Invoke-Check -Name "arm64 QEMU build・config validation" -ContinueOnFailure -Action {
            $runtimeArgs = @("buildx", "build", "--pull", "--load", "--platform", "linux/arm64", "--target", "runtime") + $cacheArgs + @(
                "--build-arg", "VERSION=$Version", "--build-arg", "COMMIT=$commit", "--build-arg", "BUILD_DATE=$buildDate",
                "--tag", $Arm64Image, "."
            )
            $null = Invoke-Native -FilePath "docker" -Arguments $runtimeArgs -LogFile (Join-Path $OutputDir "build-arm64.log")
            $base = @("run", "--rm", "--platform", "linux/arm64", "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges", "--pids-limit", "128", "--tmpfs", "/run/toroute:uid=65532,gid=65532,mode=0700", "--tmpfs", "/var/lib/toroute:uid=65532,gid=65532,mode=0700")
            $null = Invoke-Native -FilePath "docker" -Arguments ($base + @($Arm64Image, "check-config"))
            $arch = Invoke-Native -FilePath "docker" -Arguments ($base + @("--entrypoint", "/bin/uname", $Arm64Image, "-m"))
            Assert-True ($arch.Output.Trim() -eq "aarch64") "arm64 imageがaarch64として実行されていません。"
        }
    }
    }
}
catch {
    $FatalMessage = $_.Exception.Message
    Write-Host "`nFATAL: $FatalMessage" -ForegroundColor Red
}
finally {
    if ($ComposeStarted) {
        try {
            $null = Invoke-Native -FilePath "docker" -Arguments @("compose", "-p", $Project, "-f", $ComposeFile, "ps", "--all") -LogFile (Join-Path $OutputDir "compose-ps-final.txt") -AllowFailure
            $null = Invoke-Native -FilePath "docker" -Arguments @("compose", "-p", $Project, "-f", $ComposeFile, "logs", "--no-color", "--timestamps") -LogFile (Join-Path $OutputDir "compose-logs-final.txt") -AllowFailure
            $idsResult = Invoke-Native -FilePath "docker" -Arguments @("compose", "-p", $Project, "-f", $ComposeFile, "ps", "-q", "--all") -AllowFailure
            $ids = @($idsResult.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($ids.Count -gt 0) {
                $null = Invoke-Native -FilePath "docker" -Arguments (@("inspect") + $ids) -LogFile (Join-Path $OutputDir "compose-containers-final.json") -AllowFailure
            }
        }
        catch { }
        if (-not $KeepContainers) {
            try {
                $null = Invoke-Native -FilePath "docker" -Arguments @("compose", "-p", $Project, "-f", $ComposeFile, "down", "-v", "--remove-orphans") -AllowFailure
            }
            catch { }
        }
    }
    Remove-Item Env:TOROUTE_TEST_IMAGE -ErrorAction SilentlyContinue
    Remove-Item Env:TOROUTE_NETPROBE_IMAGE -ErrorAction SilentlyContinue
    Remove-Item Env:TOROUTE_PROXYCHECK_IMAGE -ErrorAction SilentlyContinue
}

$FailedChecks = @($Checks | Where-Object { $_.status -eq "failed" })
$Succeeded = [string]::IsNullOrWhiteSpace($FatalMessage) -and $FailedChecks.Count -eq 0
Write-FinalReports $Succeeded
if ($TranscriptStarted) {
    try { Stop-Transcript | Out-Null } catch { }
    $TranscriptStarted = $false
}

if (Test-Path -LiteralPath $ArchivePath) { Remove-Item -LiteralPath $ArchivePath -Force }
Compress-Archive -Path (Join-Path $OutputDir "*") -DestinationPath $ArchivePath -CompressionLevel Optimal
Write-Host "`n結果ディレクトリ: $OutputDir" -ForegroundColor Yellow
Write-Host "結果ZIP: $ArchivePath" -ForegroundColor Yellow
if (-not $Succeeded) {
    Write-Host "検証は失敗しました。生の結果ZIPは非公開で保管し、公開先にはsanitized summaryだけを共有してください。" -ForegroundColor Red
    exit 1
}
Write-Host "全検証が成功しました。生の結果ZIPは非公開で保管し、公開先にはsanitized summaryだけを共有してください。" -ForegroundColor Green
exit 0
