# Updates staff balances/allowances in Supabase from the "Summary" sheet of a Staff Allowance
# Tracker .xlsx file.
#
# RUN THIS YOURSELF in your own PowerShell terminal — never paste your service_role key into a
# chat or commit it anywhere.
#
# Where to find it: Supabase dashboard -> Project Settings -> API -> "service_role" key
# (NOT the "anon"/"publishable" key already in config.js.)
#
# SAFE BY DEFAULT: without -Apply, this only PRINTS what would change (a diff against the current
# live balances) and writes nothing. Review the diff, then re-run with -Apply to actually save it.
#
# Usage:
#   .\update-balances.ps1 -Path "C:\Users\Musa FOM\Downloads\Staff Allowance Tracker 2026 (4).xlsx"
#   .\update-balances.ps1 -Path "...same file..." -Apply

param(
  [Parameter(Mandatory=$true)]
  [string]$Path,
  [switch]$Apply
)

$SB_URL = 'https://kzkjquteqeyqwdckgarr.supabase.co'

# Known spelling differences between this tracker and the database — same people, confirmed.
$nameAliases = @{
  'petronel van der walt' = 'Petronel van der Watt'
  'shane van tonder'      = 'Shane van Tonder'
}

function Normalize-Name([string]$n){
  $n = $n.Trim() -replace '\s+', ' '
  $key = $n.ToLower()
  if($nameAliases.ContainsKey($key)){ return $nameAliases[$key] }
  return $n
}

Write-Output "Reading $Path ..."
$target = @{}
$skippedBlank = @()
$duplicates = @()
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$wb = $null
# try/finally so a missing file or "Summary" sheet doesn't leave a hidden Excel.exe running
try {
  $wb = $excel.Workbooks.Open($Path)
  $ws = $wb.Worksheets.Item("Summary")
  $vals = $ws.UsedRange.Value2
  $rowCount = $vals.GetLength(0)
  for($r=1; $r -le $rowCount; $r++){
    $name = $vals[$r,1]
    $allowance = $vals[$r,2]
    $balance = $vals[$r,3]
    if(-not $name){ continue }
    if($name -eq 'Staff Member'){ continue } # header row
    if(-not ($allowance -is [double] -or $allowance -is [int])){ continue } # skip title/blank rows
    $normalized = Normalize-Name $name
    # an empty Balance cell used to become 0 ([double]$null) and zero that person's live balance
    if(-not ($balance -is [double] -or $balance -is [int])){ $skippedBlank += $normalized; continue }
    if($target.ContainsKey($normalized)){ $duplicates += $normalized }
    $target[$normalized] = [PSCustomObject]@{ Allowance = [double]$allowance; Balance = [double]$balance }
  }
} finally {
  if($wb){ $wb.Close($false) }
  $excel.Quit()
  [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null
}
Write-Output ("Parsed " + $target.Count + " staff rows from the spreadsheet.")
if($skippedBlank.Count -gt 0){ Write-Output ("SKIPPED (Balance cell empty or not a number): " + ($skippedBlank -join ', ')) }
if($duplicates.Count -gt 0){
  Write-Output ("STOPPING: these names appear more than once in the sheet, fix that first: " + ($duplicates -join ', '))
  exit 1
}

$serviceKeySecure = Read-Host -Prompt "`nPaste your Supabase service_role key" -AsSecureString
$serviceKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($serviceKeySecure))
$headers = @{ apikey = $serviceKey; Authorization = "Bearer $serviceKey"; 'Content-Type' = 'application/json' }

Write-Output "Fetching current live staff balances..."
$staff = Invoke-RestMethod -Uri "$SB_URL/rest/v1/staff?select=name,allowance,balance&order=name.asc" -Headers $headers
$staffByName = @{}
foreach($s in $staff){ $staffByName[$s.name] = $s }

$changes = @()
$notFound = @()
foreach($name in $target.Keys){
  $t = $target[$name]
  if(-not $staffByName.ContainsKey($name)){ $notFound += $name; continue }
  $cur = $staffByName[$name]
  $balDiff = [math]::Round($t.Balance - [double]$cur.balance, 2)
  $allowDiff = [math]::Round($t.Allowance - [double]$cur.allowance, 2)
  if($balDiff -ne 0 -or $allowDiff -ne 0){
    $changes += [PSCustomObject]@{
      Name = $name
      CurrentAllowance = $cur.allowance; NewAllowance = $t.Allowance
      CurrentBalance = $cur.balance; NewBalance = $t.Balance
      BalanceDiff = $balDiff
    }
  }
}

Write-Output "`n--- Staff in spreadsheet but not found in database (check spelling) ---"
if($notFound.Count -eq 0){ Write-Output "(none)" } else { $notFound | ForEach-Object { Write-Output $_ } }

Write-Output "`n--- Changes ($($changes.Count) staff differ) ---"
if($changes.Count -eq 0){
  Write-Output "Everything already matches — nothing to update."
  exit
}
$changes | Format-Table Name, CurrentBalance, NewBalance, BalanceDiff, CurrentAllowance, NewAllowance -AutoSize | Out-String -Width 200 | Write-Output

if(-not $Apply){
  Write-Output "`nDRY RUN ONLY — nothing was changed. Review the diff above, then re-run with -Apply to save it."
  exit
}

Write-Output "`nApplying $($changes.Count) update(s)..."
foreach($c in $changes){
  $nameQ = [uri]::EscapeDataString($c.Name)
  # Only write if the live balance is still what the diff above was computed from — if an order
  # was placed in the app since then, skip that person instead of silently erasing the order.
  $guard = "name=eq.$nameQ&balance=eq.$($c.CurrentBalance)&allowance=eq.$($c.CurrentAllowance)"
  $body = @{ allowance = $c.NewAllowance; balance = $c.NewBalance } | ConvertTo-Json
  $h = $headers.Clone(); $h['Prefer'] = 'return=representation'
  $updated = Invoke-RestMethod -Method Patch -Uri "$SB_URL/rest/v1/staff?$guard" -Headers $h -Body $body
  if(@($updated).Count -eq 0){
    Write-Output ($c.Name + " -> SKIPPED: balance changed since the diff was taken (re-run the script)")
    continue
  }
  # same audit trail the admin panel writes for manual edits
  $audit = @(
    @{ staff_name = $c.Name; field = 'balance'; old_value = "$($c.CurrentBalance)"; new_value = "$($c.NewBalance)"; changed_by = 'update-balances.ps1'; source = 'spreadsheet_import' },
    @{ staff_name = $c.Name; field = 'allowance'; old_value = "$($c.CurrentAllowance)"; new_value = "$($c.NewAllowance)"; changed_by = 'update-balances.ps1'; source = 'spreadsheet_import' }
  ) | ConvertTo-Json
  Invoke-RestMethod -Method Post -Uri "$SB_URL/rest/v1/staff_audit" -Headers $headers -Body $audit | Out-Null
  Write-Output ($c.Name + " -> balance " + $c.NewBalance + " (was " + $c.CurrentBalance + ")")
}
Write-Output "`nDone."
