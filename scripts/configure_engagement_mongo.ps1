param(
  [string]$Username = "knestars_db_user",
  [string]$Cluster = "necxa-cluster.7dgpjye.mongodb.net"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $projectRoot "functions\.env"
$setupScript = Join-Path $PSScriptRoot "setup_engagement_mongo.js"
$securePassword = $null
$plainPassword = $null
$encodedPassword = $null
$directUri = $null

try {
  $securePassword = Read-Host "Enter the MongoDB database password" -AsSecureString
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
  try {
    $plainPassword =
      [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    $encodedPassword = [Uri]::EscapeDataString($plainPassword)
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    $plainPassword = $null
  }

  $encodedUsername = [Uri]::EscapeDataString($Username)
  $srvUri =
    "mongodb+srv://${encodedUsername}:$encodedPassword@$Cluster/?appName=necxa-Cluster"

  $content = if (Test-Path -LiteralPath $envPath) {
    @(Get-Content -LiteralPath $envPath)
  }
  else {
    @()
  }
  $mongoLine = "MONGO_URI=$srvUri"
  $foundMongoUri = $false
  $content = @($content | ForEach-Object {
    if ($_ -match "^\s*MONGO_URI=") {
      $foundMongoUri = $true
      $mongoLine
    }
    else {
      $_
    }
  })
  if (-not $foundMongoUri) {
    $content += $mongoLine
  }
  [IO.File]::WriteAllLines(
    $envPath,
    [string[]]$content,
    (New-Object Text.UTF8Encoding($false))
  )

  $srvRecords = Resolve-DnsName -Type SRV "_mongodb._tcp.$Cluster"
  $hosts = (($srvRecords |
    Where-Object Type -eq "SRV" |
    ForEach-Object {
      "$($_.NameTarget.TrimEnd('.')):$($_.Port)"
    }) -join ",")
  if (-not $hosts) {
    throw "No MongoDB Atlas hosts were returned by DNS."
  }

  $txtRecord = Resolve-DnsName -Type TXT $Cluster |
    Where-Object Type -eq "TXT" |
    Select-Object -First 1
  $txtOptions = ($txtRecord.Strings -join "")
  $directUri =
    "mongodb://${encodedUsername}:$encodedPassword@$hosts/?tls=true&$txtOptions&retryWrites=true&w=majority&appName=necxa-engagement-setup"

  & mongosh $directUri --quiet --file $setupScript
  if ($LASTEXITCODE -ne 0) {
    throw "MongoDB engagement setup failed."
  }

  Write-Host "MongoDB engagement backend configured successfully."
  Write-Host "Local secret updated: functions/.env"
}
finally {
  $env:MONGO_URI = $null
  $securePassword = $null
  $plainPassword = $null
  $encodedPassword = $null
  $directUri = $null
}
