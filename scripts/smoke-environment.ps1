[CmdletBinding()]
param(
    [ValidateRange(1, 120)]
    [int]$TimeoutSec = 15,

    [PSCredential]$KanboardApiCredential,

    [string]$ExpectedKanboardVersion = 'v1.2.54'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = [System.Collections.Generic.List[string]]::new()

$repoRoot = Split-Path -Parent $PSScriptRoot
$composeFile = Join-Path $repoRoot 'docker\docker-compose.yml'
$envFile = Join-Path $repoRoot 'docker\.env'

function Invoke-Compose {
    param([string[]]$ComposeArguments)

    $output = & docker compose --env-file $envFile -f $composeFile @ComposeArguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "docker compose $($ComposeArguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }

    return $output
}

function Invoke-Check {
    param(
        [string]$Name,
        [scriptblock]$Test
    )

    try {
        & $Test
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    catch {
        $message = $_.Exception.Message
        $script:Failures.Add("${Name}: $message")
        Write-Host "[FAIL] $Name - $message" -ForegroundColor Red
    }
}

function Get-ContainerId {
    param([string]$Service)

    $containerIds = @(
        Invoke-Compose @('ps', '--all', '--quiet', $Service) |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($containerIds.Count -ne 1) {
        throw "Expected exactly one container for service '$Service', got $($containerIds.Count)."
    }

    return $containerIds[0]
}

function Get-PublishedPort {
    param(
        [string]$Service,
        [int]$ContainerPort
    )

    $mapping = (Invoke-Compose @('port', $Service, "$ContainerPort") | Out-String).Trim()

    if ($mapping -notmatch ':(\d+)$') {
        throw "Unexpected port mapping for ${Service}: $mapping"
    }

    return [int]$Matches[1]
}

if (-not (Test-Path -LiteralPath $composeFile)) {
    throw "Compose file not found: $composeFile"
}

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Environment file not found: $envFile. Copy docker/.env.example to docker/.env first."
}

Invoke-Check 'Docker Engine is reachable' {
    $serverVersionOutput = & docker info --format '{{.ServerVersion}}' 2>&1
    $exitCode = $LASTEXITCODE
    $serverVersion = ($serverVersionOutput | Out-String).Trim()
    if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($serverVersion)) {
        throw "Docker Engine is unavailable: $serverVersion"
    }
}

Invoke-Check 'Docker Compose configuration is valid' {
    Invoke-Compose @('config', '--quiet') | Out-Null
}

foreach ($service in @('postgres', 'kanboard', 'jenkins')) {
    Invoke-Check "$service container is healthy" {
        $containerId = Get-ContainerId $service
        $healthOutput = & docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $containerId 2>&1
        $exitCode = $LASTEXITCODE
        $health = ($healthOutput | Out-String).Trim()
        if ($exitCode -ne 0) {
            throw "Cannot inspect ${service}: $health"
        }
        if ($health -ne 'healthy') {
            throw "Expected 'healthy', got '$health'."
        }
    }
}

$kanboardPort = Get-PublishedPort 'kanboard' 80
$jenkinsPort = Get-PublishedPort 'jenkins' 8080

Invoke-Check 'Kanboard host health endpoint reports a working database' {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$kanboardPort/healthcheck.php" -TimeoutSec $TimeoutSec
    if ([int]$health.status -ne 200) {
        throw "Unexpected Kanboard health status: $($health.status) $($health.message)"
    }
}

Invoke-Check 'Jenkins login page is reachable from the host' {
    $response = Invoke-WebRequest -Uri "http://127.0.0.1:$jenkinsPort/login" -UseBasicParsing -TimeoutSec $TimeoutSec
    if ($response.StatusCode -ne 200) {
        throw "Unexpected Jenkins HTTP status: $($response.StatusCode)"
    }
}

Invoke-Check 'Jenkins can reach Kanboard through the Docker network' {
    $response = (Invoke-Compose @('exec', '-T', 'jenkins', 'curl', '--fail', '--silent', '--max-time', "$TimeoutSec", 'http://kanboard/healthcheck.php') | Out-String).Trim()
    $health = $response | ConvertFrom-Json
    if ([int]$health.status -ne 200) {
        throw "Unexpected internal Kanboard health response: $response"
    }
}

Invoke-Check 'PostgreSQL contains the Kanboard schema' {
    $query = 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ''public'';"'
    $result = (Invoke-Compose @('exec', '-T', 'postgres', 'sh', '-c', $query) | Out-String).Trim()
    $tableCount = 0
    if (-not [int]::TryParse($result, [ref]$tableCount) -or $tableCount -lt 1) {
        throw "Expected Kanboard tables in PostgreSQL, got '$result'."
    }
}

if ($null -eq $KanboardApiCredential) {
    Write-Host '[SKIP] Authenticated JSON-RPC version check (credentials were not supplied).' -ForegroundColor Yellow
}
else {
    Invoke-Check 'Authenticated JSON-RPC getVersion succeeds' {
        $networkCredential = $KanboardApiCredential.GetNetworkCredential()
        $pair = "$($networkCredential.UserName):$($networkCredential.Password)"
        $credentialBytes = [Text.Encoding]::UTF8.GetBytes($pair)
        try {
            $token = [Convert]::ToBase64String($credentialBytes)
            $headers = @{ Authorization = "Basic $token" }
            $body = @{ jsonrpc = '2.0'; method = 'getVersion'; id = 1 } | ConvertTo-Json -Compress
            $response = Invoke-RestMethod -Uri "http://127.0.0.1:$kanboardPort/jsonrpc.php" -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
            if ($response.jsonrpc -ne '2.0' -or [int]$response.id -ne 1) {
                throw 'Kanboard returned an invalid JSON-RPC envelope.'
            }
            if (($response.PSObject.Properties.Name -contains 'error') -and $null -ne $response.error) {
                throw 'Kanboard returned a JSON-RPC error.'
            }
            if ([string]$response.result -ne $ExpectedKanboardVersion) {
                throw "Expected Kanboard $ExpectedKanboardVersion, got '$($response.result)'."
            }
        }
        finally {
            [Array]::Clear($credentialBytes, 0, $credentialBytes.Length)
        }
    }
}

Invoke-Check 'Jenkins inbound-agent port is not published to the host' {
    $containerId = Get-ContainerId 'jenkins'
    $bindingsOutput = & docker inspect --format '{{json .HostConfig.PortBindings}}' $containerId 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Cannot inspect Jenkins port mappings."
    }
    $bindings = ($bindingsOutput | Out-String).Trim() | ConvertFrom-Json
    if ($bindings.PSObject.Properties.Name -contains '50000/tcp') {
        throw 'Port 50000/tcp is unexpectedly published.'
    }
}

if ($script:Failures.Count -gt 0) {
    Write-Host "`nSmoke check failed ($($script:Failures.Count) check(s)):" -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host " - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "`nSmoke check passed." -ForegroundColor Green
exit 0
