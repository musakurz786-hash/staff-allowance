# One-time cleanup: deletes specific Supabase Auth accounts stuck in a broken half-created state
# (from the old magic-link flow — confirmed-but-no-password, or unconfirmed-and-abandoned), so
# those people can cleanly self-register via the email + PIN signup screen instead.
#
# RUN THIS YOURSELF in your own PowerShell terminal — never paste your service_role key into a
# chat or commit it anywhere.
#
# Where to find it: Supabase dashboard -> Project Settings -> API -> "service_role" key
# (NOT the "anon"/"publishable" key already in config.js.)
#
# Usage:
#   .\cleanup-stray-accounts.ps1 -Emails musa@freedomofmovement.co.za,kyle@freedomofmovement.co.za

param(
  [Parameter(Mandatory=$true)]
  [string[]]$Emails
)

$SB_URL = 'https://kzkjquteqeyqwdckgarr.supabase.co'
$serviceKeySecure = Read-Host -Prompt "Paste your Supabase service_role key" -AsSecureString
$serviceKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($serviceKeySecure))
$headers = @{ apikey = $serviceKey; Authorization = "Bearer $serviceKey" }

$targets = $Emails | ForEach-Object { $_.Trim().ToLower() }

Write-Output "Fetching existing accounts..."
$existingUsers = @()
$page = 1
while($true){
  $resp = Invoke-RestMethod -Uri "$SB_URL/auth/v1/admin/users?page=$page&per_page=200" -Headers $headers
  $existingUsers += $resp.users
  if($resp.users.Count -lt 200){ break }
  $page++
}

foreach($email in $targets){
  $user = $existingUsers | Where-Object { $_.email.ToLower() -eq $email }
  if(-not $user){ Write-Output "$email - no account found, nothing to clean up."; continue }
  Invoke-RestMethod -Method Delete -Uri "$SB_URL/auth/v1/admin/users/$($user.id)" -Headers $headers | Out-Null
  Write-Output "$email - deleted stray account. They can now self-register with a fresh PIN."
}
