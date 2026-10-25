param(
  [string]$ProjectRef = $env:SUPABASE_PROJECT_REF,
  [string]$CronSecret = $env:CRON_SECRET,
  [string]$UserId = $env:TEST_PUSH_USER_ID,
  [ValidateSet('challenge_start','challenge_ending','both')]
  [string]$ForceKind = 'both',
  [switch]$DryRun
)

if ([string]::IsNullOrWhiteSpace($ProjectRef)) {
  $ProjectRef = Read-Host "Supabase project ref (z.B. cuvmtajkzgxroedmvfwu)"
}
if ([string]::IsNullOrWhiteSpace($CronSecret)) {
  $CronSecret = Read-Host "CRON_SECRET (das, was du in supabase secrets set gesetzt hast)"
}
if ([string]::IsNullOrWhiteSpace($UserId)) {
  $UserId = Read-Host "Empfänger User UUID (auth.users id)"
}

$uri = "https://$ProjectRef.supabase.co/functions/v1/daily-scheduler"

$payload = @{
  force_kind = $ForceKind
  recipient_user_ids = @($UserId)
  dry_run = [bool]$DryRun
}

Write-Host "POST $uri" -ForegroundColor Cyan
Write-Host ("force_kind={0} dry_run={1}" -f $ForceKind, ([bool]$DryRun)) -ForegroundColor DarkGray

try {
  $res = Invoke-RestMethod -Method Post -Uri $uri -Headers @{ "x-cron-secret" = $CronSecret } -ContentType "application/json" -Body ($payload | ConvertTo-Json -Depth 6)
  $res | ConvertTo-Json -Depth 12
} catch {
  Write-Host "Request failed:" -ForegroundColor Red
  Write-Host $_
  if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream) {
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    Write-Host ($reader.ReadToEnd())
  }
  exit 1
}
