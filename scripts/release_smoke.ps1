Write-Host "Running release smoke checks..."

flutter pub get
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

flutter analyze
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

flutter test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

flutter build apk --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Release smoke checks completed successfully."
