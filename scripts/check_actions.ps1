$owner='chen2023yi'
$repo='PyAppRelease'
$sha=(git rev-parse HEAD).Trim()
Write-Host "HEAD: $sha"
try {
    $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/actions/runs?per_page=20" -ErrorAction Stop
} catch {
    Write-Host "API_ERROR: $($_.Exception.Message)"
    exit 0
}
$match = $runs.workflow_runs | Where-Object { $_.head_sha -eq $sha } | Sort-Object created_at -Descending | Select-Object -First 1
if (-not $match) { $match = $runs.workflow_runs | Select-Object -First 1 }
if (-not $match) { Write-Host 'NO_RUNS_FOUND'; exit 0 }
$obj = [pscustomobject]@{
    id = $match.id
    name = $match.name
    status = $match.status
    conclusion = $match.conclusion
    head_sha = $match.head_sha
    html_url = $match.html_url
    logs_url = $match.logs_url
    created_at = $match.created_at
}
$obj | Format-List
if ($obj.status -eq 'completed') {
    try {
        $zip = Join-Path $PSScriptRoot "run-$($obj.id)-logs.zip"
        Invoke-WebRequest -Uri $obj.logs_url -OutFile $zip -ErrorAction Stop
        Write-Host "LOGS_DOWNLOADED: $zip"
    } catch {
        Write-Host "LOGS_DOWNLOAD_FAILED: $($_.Exception.Message)"
    }
} else {
    Write-Host "RUN_NOT_COMPLETED $($obj.status)"
}
