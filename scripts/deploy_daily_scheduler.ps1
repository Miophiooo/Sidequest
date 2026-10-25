param(
  [string]$ProjectRef = $env:SUPABASE_PROJECT_REF,
  [string]$SupabaseUrl = $env:SB_URL,
  [string]$ServiceRoleKey = $env:SERVICE_ROLE_KEY,
  [string]$CronSecret = $env:CRON_SECRET,
  [string]$PushSecret = $env:PUSH_SECRET,
  [switch]$SetSecrets
)

if ([string]::IsNullOrWhiteSpace($ProjectRef)) {
  $ProjectRef = Read-Host "Supabase project ref (z.B. cuvmtajkzgxroedmvfwu)"
}

$supabaseCli = Get-Command supabase -ErrorAction SilentlyContinue
if (-not $supabaseCli) {
  Write-Host "Supabase CLI nicht gefunden. Installiere zuerst die CLI und logge dich mit 'supabase login' ein." -ForegroundColor Red
  exit 1
}

if ($SetSecrets) {
  if ([string]::IsNullOrWhiteSpace($SupabaseUrl)) {
    $SupabaseUrl = Read-Host "SB_URL (z.B. https://<project-ref>.supabase.co)"
  }
  if ([string]::IsNullOrWhiteSpace($ServiceRoleKey)) {
    $ServiceRoleKey = Read-Host "SERVICE_ROLE_KEY"
  }
  if ([string]::IsNullOrWhiteSpace($CronSecret)) {
    $CronSecret = Read-Host "CRON_SECRET"
  }
  if ([string]::IsNullOrWhiteSpace($PushSecret)) {
    $PushSecret = Read-Host "PUSH_SECRET"
  }

  Write-Host "Setze Secrets fuer daily-scheduler..." -ForegroundColor Cyan
  & $supabaseCli.Source secrets set `
    "SB_URL=$SupabaseUrl" `
    "SERVICE_ROLE_KEY=$ServiceRoleKey" `
    "CRON_SECRET=$CronSecret" `
    "PUSH_SECRET=$PushSecret" `
    --project-ref $ProjectRef

  if ($LASTEXITCODE -ne 0) {
    Write-Host "Secrets konnten nicht gesetzt werden." -ForegroundColor Red
    exit $LASTEXITCODE
  }
}

Write-Host "Deploye daily-scheduler nach $ProjectRef..." -ForegroundColor Cyan
& $supabaseCli.Source functions deploy daily-scheduler --project-ref $ProjectRef

if ($LASTEXITCODE -ne 0) {
  Write-Host "Deploy fehlgeschlagen." -ForegroundColor Red
  exit $LASTEXITCODE
}

Write-Host "daily-scheduler erfolgreich deployed." -ForegroundColor Green
