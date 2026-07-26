# Runs the smoke test without putting secrets in your shell history.
#
#   .\scripts\run-smoke-test.ps1
#
# Prompts for the two secrets, sets them for this process only, and clears them afterwards.
# The URL and anon key are not secret — they are already in the four HTML pages.

$ErrorActionPreference = 'Stop'

$env:SUPABASE_URL = "https://rbcqeuygpevabqwtdgva.supabase.co"
$env:SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJiY3FldXlncGV2YWJxd3RkZ3ZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ5Njk2OTQsImV4cCI6MjEwMDU0NTY5NH0.X9qiG3XjGHzT-O5b8lO0DeJKzzJu_ocMr4LAh3-0WLA"
$env:ADMIN_EMAIL = "info@maidsruscleaning.com.au"

function Read-Secret($prompt) {
  $secure = Read-Host -Prompt $prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

Write-Host ""
Write-Host "Admin passcode for $($env:ADMIN_EMAIL)" -ForegroundColor Cyan
$env:ADMIN_PASSWORD = Read-Secret "  Passcode"

Write-Host ""
Write-Host "Service role key - Settings > API Keys > service_role." -ForegroundColor Cyan
Write-Host "Used only to delete the rows this test creates. Press Enter to skip;" -ForegroundColor DarkGray
Write-Host "the test still runs and prints the two delete statements instead." -ForegroundColor DarkGray
$env:SUPABASE_SERVICE_KEY = Read-Secret "  Service key"

try {
  node "$PSScriptRoot\smoke-test.mjs"
  $code = $LASTEXITCODE
}
finally {
  # Scoped to this PowerShell process, but clear them anyway so a later command in the same
  # window cannot pick up the service role key from the environment.
  Remove-Item Env:ADMIN_PASSWORD -ErrorAction SilentlyContinue
  Remove-Item Env:SUPABASE_SERVICE_KEY -ErrorAction SilentlyContinue
}

exit $code
