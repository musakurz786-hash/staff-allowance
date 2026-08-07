# Sets login PINs for staff in the Staff Allowance Portal.
#
# RUN THIS YOURSELF in your own PowerShell terminal — never paste your service_role key into
# a chat or commit it anywhere. This script only asks for it locally and uses it in-memory.
#
# Where to find it: Supabase dashboard -> Project Settings -> API -> "service_role" key
# (NOT the "anon"/"publishable" key already in config.js — this one bypasses all security
# rules, so guard it like a password. Never put it in index.html or config.js.)
#
# Usage:
#   .\set-staff-pins.ps1                                   # assigns a fresh PIN to EVERY staff
#                                                           # member with an email on file
#   .\set-staff-pins.ps1 -OnlyEmails kyle@freedomofmovement.co.za
#                                                           # only (re)sets PINs for the emails
#                                                           # listed — use this for one-off resets
#                                                           # or a single new hire, so you don't
#                                                           # invalidate everyone else's PIN
#
# Output: a CSV in this folder listing name/email/PIN for everyone that was just set. Distribute
# those PINs privately (WhatsApp, in person, etc.) and delete the file once you're done with it.

param(
  [string[]]$OnlyEmails = @()
)

$SB_URL = 'https://kzkjquteqeyqwdckgarr.supabase.co'

if($OnlyEmails.Count -eq 0){
  Write-Output "No -OnlyEmails given — this will assign a FRESH PIN to EVERY staff member with an"
  Write-Output "email on file, invalidating any PINs already handed out."
  $confirm = Read-Host "Type YES to continue"
  if($confirm -ne 'YES'){ Write-Output "Cancelled."; exit }
}

$serviceKeySecure = Read-Host -Prompt "Paste your Supabase service_role key" -AsSecureString
$serviceKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($serviceKeySecure))
$headers = @{ apikey = $serviceKey; Authorization = "Bearer $serviceKey"; 'Content-Type' = 'application/json' }

$targetSet = $OnlyEmails | ForEach-Object { $_.Trim().ToLower() }

Write-Output "`nFetching staff list..."
$staff = Invoke-RestMethod -Uri "$SB_URL/rest/v1/staff?select=name,email&email=not.is.null" -Headers $headers
if($targetSet.Count -gt 0){
  $staff = $staff | Where-Object { $targetSet -contains $_.email.Trim().ToLower() }
}
Write-Output ("Staff to process: " + $staff.Count)
if($staff.Count -eq 0){ Write-Output "Nothing to do — check the email(s) you passed are on file."; exit }

Write-Output "Fetching existing login accounts..."
$existingUsers = @()
$page = 1
while($true){
  $resp = Invoke-RestMethod -Uri "$SB_URL/auth/v1/admin/users?page=$page&per_page=200" -Headers $headers
  $existingUsers += $resp.users
  if($resp.users.Count -lt 200){ break }
  $page++
}
$existingByEmail = @{}
foreach($u in $existingUsers){ $existingByEmail[$u.email.ToLower()] = $u }

function New-Pin { -join ((1..6) | ForEach-Object { Get-Random -Minimum 0 -Maximum 10 }) }

$results = @()
foreach($s in $staff){
  $email = $s.email.Trim().ToLower()
  if(-not $email){ continue }
  $pin = New-Pin
  try{
    if($existingByEmail.ContainsKey($email)){
      $id = $existingByEmail[$email].id
      $body = @{ password = $pin; email_confirm = $true } | ConvertTo-Json
      Invoke-RestMethod -Method Put -Uri "$SB_URL/auth/v1/admin/users/$id" -Headers $headers -Body $body | Out-Null
      $action = "reset"
    } else {
      $body = @{ email = $email; password = $pin; email_confirm = $true } | ConvertTo-Json
      Invoke-RestMethod -Method Post -Uri "$SB_URL/auth/v1/admin/users" -Headers $headers -Body $body | Out-Null
      $action = "created"
    }
    $results += [PSCustomObject]@{ Name = $s.name; Email = $email; PIN = $pin; Action = $action }
    Write-Output ($s.name + " (" + $email + ") -> PIN " + $pin + " [" + $action + "]")
  } catch {
    Write-Output ("FAILED for " + $email + ": " + $_.Exception.Message)
  }
}

if($results.Count -gt 0){
  $outFile = ".\staff-pins-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
  $results | Export-Csv -Path $outFile -NoTypeInformation
  Write-Output "`nSaved to $outFile — distribute these privately, then delete the file."
} else {
  Write-Output "`nNo PINs were set."
}
