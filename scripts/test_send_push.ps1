param(
  [string]$ProjectRef = $env:SUPABASE_PROJECT_REF,
  [string]$PushSecret = $env:PUSH_SECRET,
  [string]$UserId = $env:TEST_PUSH_USER_ID,
  [string]$Type = "messages",
  [string]$Title = "SideQuest",
  [string]$Body = "Push Test"
)

if ([string]::IsNullOrWhiteSpace($ProjectRef)) {
  $ProjectRef = Read-Host "Supabase project ref (z.B. cuvmtajkzgxroedmvfwu)"
}
if ([string]::IsNullOrWhiteSpace($PushSecret)) {
  $PushSecret = Read-Host "PUSH_SECRET (das, was du in supabase secrets set gesetzt hast)"
}
if ([string]::IsNullOrWhiteSpace($UserId)) {
  $UserId = Read-Host "Empfaenger User UUID (auth.users id)"
}

$uri = "https://$ProjectRef.supabase.co/functions/v1/send-push"

$payload = @{
  type = $Type
  recipient_user_ids = @($UserId)
  title = $Title
  body = $Body
  data = @{
    kind = "test"
    target_tab = "1"
  }
}

Write-Host "POST $uri" -ForegroundColor Cyan

try {
  $res = Invoke-RestMethod -Method Post -Uri $uri -Headers @{ "x-push-secret" = $PushSecret } -ContentType "application/json" -Body ($payload | ConvertTo-Json -Depth 6)
  $res | ConvertTo-Json -Depth 10
} catch {
  Write-Host "Request failed:" -ForegroundColor Red
  Write-Host $_
  if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream) {
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    Write-Host ($reader.ReadToEnd())
  }
  exit 1
}
