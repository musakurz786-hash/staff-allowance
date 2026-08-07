# Admin tool for the Staff Allowance Portal's login accounts (list / reset PIN / delete).
#
# RUN THIS YOURSELF in your own PowerShell terminal — never paste your service_role key into a
# chat or commit it anywhere. This script only asks for it locally and uses it in-memory.
#
# Where to find it: Supabase dashboard -> Project Settings -> API -> "service_role" key
# (NOT the "anon"/"publishable" key already in config.js — this one bypasses every security rule
# in the app, so guard it like a password. Never put it in index.html or config.js.)
#
# Usage:
#
#   List everyone's login status (cross-referenced against the staff table):
#     .\admin-tool.ps1 -Action List
#
#   Reset (or create) a PIN for one or more people — generates a random 6-digit PIN unless you
#   pass -Pins explicitly. Use this if someone forgot their PIN, or you want to set one up for
#   them yourself instead of them self-registering:
#     .\admin-tool.ps1 -Action ResetPin -Emails kyle@freedomofmovement.co.za
#     .\admin-tool.ps1 -Action ResetPin -Emails a@freedomofmovement.co.za,b@freedomofmovement.co.za
#
#   Delete a login account entirely (e.g. someone left the company, or an account got stuck in a
#   broken half-created state and needs to self-register fresh):
#     .\admin-tool.ps1 -Action Delete -Emails musa@freedomofmovement.co.za

param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('List','ResetPin','Delete')]
  [string]$Action,

  [string[]]$Emails = @(),
  [string[]]$Pins = @()
)

$SB_URL = 'https://kzkjquteqeyqwdckgarr.supabase.co'

if($Action -ne 'List' -and $Emails.Count -eq 0){
  Write-Output "Pass -Emails for this action, e.g. -Emails a@freedomofmovement.co.za,b@freedomofmovement.co.za"
  exit
}

$serviceKeySecure = Read-Host -Prompt "Paste your Supabase service_role key" -AsSecureString
$serviceKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($serviceKeySecure))
$headers = @{ apikey = $serviceKey; Authorization = "Bearer $serviceKey"; 'Content-Type' = 'application/json' }

function Get-AllAuthUsers {
  $all = @(); $page = 1
  while($true){
    $resp = Invoke-RestMethod -Uri "$SB_URL/auth/v1/admin/users?page=$page&per_page=200" -Headers $headers
    $all += $resp.users
    if($resp.users.Count -lt 200){ break }
    $page++
  }
  return $all
}

function New-Pin { -join ((1..6) | ForEach-Object { Get-Random -Minimum 0 -Maximum 10 }) }

if($Action -eq 'List'){
  Write-Output "Fetching staff and login accounts..."
  $staff = Invoke-RestMethod -Uri "$SB_URL/rest/v1/staff?select=name,email&order=name.asc" -Headers $headers
  $authUsers = Get-AllAuthUsers
  $authByEmail = @{}
  foreach($u in $authUsers){ $authByEmail[$u.email.ToLower()] = $u }

  Write-Output "`n--- Staff (from the staff table) ---"
  foreach($s in $staff){
    if(-not $s.email){ Write-Output ($s.name + " | (no email on file)"); continue }
    $email = $s.email.Trim().ToLower()
    $u = $authByEmail[$email]
    if(-not $u){ Write-Output ($s.name + " | " + $email + " | NO LOGIN ACCOUNT YET") }
    else {
      $confirmed = if($u.email_confirmed_at){ "confirmed" } else { "UNCONFIRMED (stuck - needs Delete then self-register)" }
      $lastLogin = if($u.last_sign_in_at){ $u.last_sign_in_at } else { "never logged in" }
      Write-Output ($s.name + " | " + $email + " | " + $confirmed + " | last login: " + $lastLogin)
    }
  }

  $staffEmails = $staff | Where-Object { $_.email } | ForEach-Object { $_.email.Trim().ToLower() }
  $orphans = $authUsers | Where-Object { $staffEmails -notcontains $_.email.ToLower() }
  if($orphans.Count -gt 0){
    Write-Output "`n--- Login accounts with no matching staff record (orphans) ---"
    foreach($o in $orphans){ Write-Output ($o.email + " | created " + $o.created_at) }
  }
  exit
}

$authUsers = Get-AllAuthUsers
$authByEmail = @{}
foreach($u in $authUsers){ $authByEmail[$u.email.ToLower()] = $u }

if($Action -eq 'Delete'){
  foreach($email in ($Emails | ForEach-Object { $_.Trim().ToLower() })){
    $u = $authByEmail[$email]
    if(-not $u){ Write-Output "$email - no account found, nothing to delete."; continue }
    Invoke-RestMethod -Method Delete -Uri "$SB_URL/auth/v1/admin/users/$($u.id)" -Headers $headers | Out-Null
    Write-Output "$email - deleted. They can self-register a fresh PIN, or you can ResetPin to set one for them."
  }
  exit
}

if($Action -eq 'ResetPin'){
  $emailList = $Emails | ForEach-Object { $_.Trim().ToLower() }
  $results = @()
  for($i=0; $i -lt $emailList.Count; $i++){
    $email = $emailList[$i]
    $pin = if($i -lt $Pins.Count){ $Pins[$i] } else { New-Pin }
    try{
      $u = $authByEmail[$email]
      if($u){
        $body = @{ password = $pin; email_confirm = $true } | ConvertTo-Json
        Invoke-RestMethod -Method Put -Uri "$SB_URL/auth/v1/admin/users/$($u.id)" -Headers $headers -Body $body | Out-Null
        $action = "reset"
      } else {
        $body = @{ email = $email; password = $pin; email_confirm = $true } | ConvertTo-Json
        Invoke-RestMethod -Method Post -Uri "$SB_URL/auth/v1/admin/users" -Headers $headers -Body $body | Out-Null
        $action = "created"
      }
      $results += [PSCustomObject]@{ Email = $email; PIN = $pin; Action = $action }
      Write-Output ("$email -> PIN $pin [$action]")
    } catch {
      Write-Output ("FAILED for $email - " + $_.Exception.Message)
    }
  }
  if($results.Count -gt 0){
    $outFile = ".\pin-reset-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
    $results | Export-Csv -Path $outFile -NoTypeInformation
    Write-Output "`nSaved to $outFile - share the PIN with that person privately, then delete the file."
  }
}
