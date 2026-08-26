# Data health check for the Staff Allowance Portal.
#
# This isn't a browser/UI test suite (no Node.js/Playwright available on this machine) — it's a
# periodic scan of the live data for the specific kinds of corruption today's bugs could cause:
# duplicate/malformed staff emails, negative or zero quantities/amounts, and unpriced-but-orderable
# products. Run it after any bulk import (Shopify, Allowance Tracker, stock) or any time something
# looks off. A clean run prints "All checks passed."
#
# RUN THIS YOURSELF in your own PowerShell terminal — never paste your service_role key into a
# chat or commit it anywhere.
#
# Usage:
#   .\data-health-check.ps1

$SB_URL = 'https://kzkjquteqeyqwdckgarr.supabase.co'
$serviceKeySecure = Read-Host -Prompt "Paste your Supabase service_role key" -AsSecureString
$serviceKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($serviceKeySecure))
$headers = @{ apikey = $serviceKey; Authorization = "Bearer $serviceKey" }

$issues = @()

Write-Output "Fetching staff..."
$staff = Invoke-RestMethod -Uri "$SB_URL/rest/v1/staff?select=name,email,allowance,balance" -Headers $headers

Write-Output "Checking for duplicate/malformed staff emails..."
$emailGroups = $staff | Where-Object { $_.email } | Group-Object -Property email
foreach($g in $emailGroups){
  if($g.Count -gt 1){
    $issues += "Duplicate email '$($g.Name)' used by: " + ($g.Group.name -join ', ')
  }
}
foreach($s in $staff){
  if($s.email -and $s.email -ne $s.email.ToLower()){
    $issues += "$($s.name) has a non-lowercase email on file: $($s.email) - logins are case-sensitive, this will lock them out"
  }
  if($s.allowance -lt 0){
    $issues += "$($s.name) has a negative allowance ($($s.allowance)) - likely a data entry error"
  }
}

Write-Output "Fetching products..."
$products = Invoke-RestMethod -Uri "$SB_URL/rest/v1/products?select=sku,product,rsp,available" -Headers $headers
foreach($p in $products){
  if([double]$p.rsp -le 0 -and [double]$p.available -gt 0){
    $issues += "Product '$($p.product)' (SKU $($p.sku)) has stock ($($p.available)) but no price - should be blocked from ordering, check it slipped through the R0 guard"
  }
}

Write-Output "Fetching recent orders..."
$orders = Invoke-RestMethod -Uri "$SB_URL/rest/v1/orders?select=id,staff_name,sku,product,qty,amount,created_at&order=created_at.desc&limit=1000" -Headers $headers
foreach($o in $orders){
  if([double]$o.qty -le 0){
    $issues += "Order #$($o.id) ($($o.staff_name), $($o.product)) has qty <= 0: $($o.qty)"
  }
  if([double]$o.amount -lt 0){
    $issues += "Order #$($o.id) ($($o.staff_name), $($o.product)) has a negative amount: $($o.amount)"
  }
}

Write-Output "`n--- Results ---"
if($issues.Count -eq 0){
  Write-Output "All checks passed - $($staff.Count) staff, $($products.Count) products, $($orders.Count) recent orders scanned, nothing looks wrong."
} else {
  Write-Output ($issues.Count.ToString() + " issue(s) found:")
  $issues | ForEach-Object { Write-Output (" - " + $_) }
}
