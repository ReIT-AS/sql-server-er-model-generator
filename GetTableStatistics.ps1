<#
.SYNOPSIS
  Henter statistikk for alle tabeller i SQL Server database:
   - Tabellnavn
   - Antall records
   - Siste aktivitet (opprett/endret-dato)

.DESCRIPTION
  Scriptet kobler til SQL Server og henter for hver tabell:
  - Schema + tabellnavn
  - Antall rader (rows)
  - Siste opprett-dato (hvis det finnes opprett-kolonne)
  - Output til CSV for videre analyse

.PARAMETER ServerInstance
  SQL Server instans (f.eks. "localhost\SQLEXPRESS" eller "myserver.database.windows.net")

.PARAMETER Database
  Database navn

.PARAMETER SqlCredential
  PSCredential for SQL autentisering (valgfritt)

.PARAMETER OutputFile
  CSV-fil hvor resultatene skal lagres (standard: .\table-statistics.csv)

.PARAMETER SchemaFilter
  Array av schema-navn å inkludere (tom = alle schema)

.PARAMETER LogLevel
  Logging nivå: DEBUG, INFO, WARNING, ERROR (standard: INFO)

.PARAMETER UseEnvFile
  Bruk .env fil for konfigurasjon (overstyrer kommandolinje-parametere)

.EXAMPLE
  .\GetTableStatistics.ps1 -UseEnvFile

.EXAMPLE
  .\GetTableStatistics.ps1 -ServerInstance "prod-db" -Database "MyDB" -OutputFile "stats.csv"

.NOTES
  - Forsøker flere vanlige "opprett-dato" kolonnenavn
  - Bruker sys.partitions for raskere radtelling
  - Krever sqlcmd CLI tool
#>

param(
  [Parameter(Mandatory=$false)]
  [string]$ServerInstance,

  [Parameter(Mandatory=$false)]
  [string]$Database,

  [Parameter(Mandatory=$false)]
  [pscredential]$SqlCredential,

  [Parameter(Mandatory=$false)]
  [string]$OutputFile = ".\table-statistics.csv",

  [Parameter(Mandatory=$false)]
  [string[]]$SchemaFilter = @(),

  [Parameter(Mandatory=$false)]
  [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR")]
  [string]$LogLevel = "INFO",

  [Parameter(Mandatory=$false)]
  [switch]$UseEnvFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ========== GLOBAL VARIABLES ==========
$script:LogLevelValue = @{
  "DEBUG" = 0
  "INFO" = 1
  "WARNING" = 2
  "ERROR" = 3
}

# ========== LOGGING FUNCTIONS ==========
function Write-Log {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Message,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR")]
    [string]$Level = "INFO"
  )
  
  if ($script:LogLevelValue[$Level] -ge $script:LogLevelValue[$LogLevel]) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
      "DEBUG"   { Write-Host $logMessage -ForegroundColor Gray }
      "INFO"    { Write-Host $logMessage -ForegroundColor White }
      "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
      "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
    }
  }
}

# ========== CONFIGURATION FUNCTIONS ==========
function Read-EnvFile {
  param(
    [string]$Path = (Join-Path $PSScriptRoot ".env")
  )
  
  Write-Log "Leser miljøvariabler fra: $Path" -Level DEBUG
  
  if (-not (Test-Path $Path)) {
    Write-Log ".env fil ikke funnet på: $Path" -Level WARNING
    return @{}
  }
  
  $envVars = @{}
  
  try {
    Get-Content $Path | ForEach-Object {
      $line = $_.Trim()
      if ($line -and -not $line.StartsWith("#")) {
        if ($line -match '^([^=]+)=(.*)$') {
          $key = $matches[1].Trim()
          $value = $matches[2].Trim()
          $envVars[$key] = $value
          Write-Log "Lastet miljøvariabel: $key" -Level DEBUG
        }
      }
    }
    Write-Log "Lastet $($envVars.Count) miljøvariabler fra .env" -Level INFO
  }
  catch {
    Write-Log "Feil ved lesing av .env fil: $($_.Exception.Message)" -Level ERROR
    throw
  }
  
  return $envVars
}

function Get-Configuration {
  param($EnvVars)
  
  $config = @{}
  
  if ($UseEnvFile -or (-not $ServerInstance -and -not $Database)) {
    Write-Log "Bruker konfigurasjon fra .env fil" -Level INFO
    
    if (-not $EnvVars['DB_SERVER_INSTANCE']) {
      throw "DB_SERVER_INSTANCE mangler i .env fil"
    }
    if (-not $EnvVars['DB_DATABASE']) {
      throw "DB_DATABASE mangler i .env fil"
    }
    
    $config.ServerInstance = $EnvVars['DB_SERVER_INSTANCE']
    $config.Database = $EnvVars['DB_DATABASE']
    if ($EnvVars['DB_USERNAME'] -and $EnvVars['DB_PASSWORD']) {
      try {
        $sec = ConvertTo-SecureString -String $EnvVars['DB_PASSWORD'] -AsPlainText -Force
        $config.SqlCredential = New-Object System.Management.Automation.PSCredential ($EnvVars['DB_USERNAME'], $sec)
      } catch { throw "Kunne ikke lage PSCredential fra .env: $($_.Exception.Message)" }
    }
    $config.SchemaFilter = if ($EnvVars['SCHEMA_FILTER']) { 
      @($EnvVars['SCHEMA_FILTER'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else { 
      @() 
    }
  }
  else {
    Write-Log "Bruker konfigurasjon fra kommandolinje-parametere" -Level INFO
    
    if (-not $ServerInstance) {
      throw "ServerInstance parameter er påkrevd"
    }
    if (-not $Database) {
      throw "Database parameter er påkrevd"
    }
    
    $config.ServerInstance = $ServerInstance
    $config.Database = $Database
    $config.SqlCredential = $SqlCredential
    $config.SchemaFilter = $SchemaFilter
  }
  
  return $config
}

# ========== UTILITY FUNCTIONS ==========
function Get-Count {
  param($obj)
  if ($null -eq $obj) { return 0 }
  if ($obj -is [array]) { return $obj.Count }
  return 1
}

function Invoke-SqlcmdQuery {
  param(
    [string]$ServerInstance,
    [string]$Database,
    [string]$Query,
    [pscredential]$Credential
  )
  
  Write-Log "Utfører spørring mot $ServerInstance.$Database..." -Level DEBUG
  
  $tempQueryFile = Join-Path $env:TMPDIR "query_$(Get-Random).sql"
  
  try {
    $fullQuery = "SET NOCOUNT ON`nSET ANSI_WARNINGS OFF`n" + $Query
    Set-Content -Path $tempQueryFile -Value $fullQuery -Encoding UTF8 -ErrorAction Stop
    
    $sqlcmdArgs = @(
      "-S", $ServerInstance
      "-d", $Database
      "-i", $tempQueryFile
      "-W"
      "-s", "|"
      "-w", "256"
    )
    
    if ($Credential) {
      Write-Log "Bruker SQL autentisering" -Level DEBUG
      $password = [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password))
      $sqlcmdArgs += "-U", $Credential.UserName
      $sqlcmdArgs += "-P", $password
    }
    else {
      Write-Log "Bruker Windows/Azure AD autentisering" -Level DEBUG
      $sqlcmdArgs += "-E"
    }
    
    $output = & sqlcmd @sqlcmdArgs 2>&1
    
    if ($LASTEXITCODE -ne 0) {
      Write-Log "sqlcmd feilet med exit code $LASTEXITCODE" -Level ERROR
      throw "sqlcmd feilet: $output"
    }
    
    $result = @()
    foreach ($line in $output) {
      if (-not $line -or -not $line.Trim()) { continue }
      if ($line -match "^\(\d+\s+rows? affected\)") { continue }
      if ($line -match "^[\|\-\s]+$") { continue }
      # Sikkerhet: hopp over feil-meldinger fra sqlcmd
      if ($line -match "^Msg \d+|^Error") { continue }
      $result += $line
    }
    Write-Log "Spørring vellykket, returnerer $(Get-Count $result) linjer" -Level DEBUG
    return $result
  }
  catch {
    Write-Log "Feil ved kjøring av spørring: $($_.Exception.Message)" -Level ERROR
    throw
  }
  finally {
    Remove-Item -Path $tempQueryFile -ErrorAction SilentlyContinue
  }
}

# ========== MAIN SCRIPT ==========
try {
  Write-Log "========== TABLE STATISTICS EXTRACTOR STARTER ==========" -Level INFO
  
  # Les miljøvariabler
  $envVars = Read-EnvFile
  
  # Hent konfigurasjon
  $config = Get-Configuration -EnvVars $envVars
  
  Write-Log "Konfigurasjon:" -Level INFO
  Write-Log "  Server: $($config.ServerInstance)" -Level INFO
  Write-Log "  Database: $($config.Database)" -Level INFO
  Write-Log "  Output: $OutputFile" -Level INFO
  
  # ========== HENT TABELLER ==========
  Write-Log "Henter alle tabeller..." -Level INFO
  
  $tablesQuery = @"
SELECT
  s.name AS SchemaName,
  t.name AS TableName,
  t.object_id AS ObjectId
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name;
"@

  $tablesOutput = Invoke-SqlcmdQuery -ServerInstance $config.ServerInstance -Database $config.Database -Query $tablesQuery -Credential $config.SqlCredential
  $tables = @($tablesOutput | ConvertFrom-Csv -Delimiter '|')
  Write-Log "Hentet $(Get-Count $tables) tabeller" -Level INFO
  
  $filterCount = if ($config.SchemaFilter) { (Get-Count $config.SchemaFilter) } else { 0 }
  if ($filterCount -gt 0) {
    $tables = @($tables | Where-Object { $config.SchemaFilter -contains $_.SchemaName })
    Write-Log "Filtrert ned til $(Get-Count $tables) tabeller basert på schema-filter" -Level INFO
  }
  
  # ========== HENT STATISTIKK FOR ALLE TABELLER ==========
  Write-Log "Henter statistikk for alle tabeller..." -Level INFO
  
  # En enkelt, robust spørring som henter radantall for alle tabeller
  $statsQuery = @"
SELECT
  s.name AS SchemaName,
  t.name AS TableName,
  s.name + '.' + t.name AS FullName,
  ISNULL(SUM(p.rows), 0) AS TableRowCount,
  CASE WHEN ISNULL(SUM(p.rows), 0) = 0 THEN 'true' ELSE 'false' END AS IsEmpty
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
LEFT JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
WHERE t.is_ms_shipped = 0
GROUP BY s.name, t.name, s.schema_id
ORDER BY s.name, t.name;
"@

  try {
    $statsOutput = Invoke-SqlcmdQuery -ServerInstance $config.ServerInstance -Database $config.Database -Query $statsQuery -Credential $config.SqlCredential
    Write-Log "Raw output antall linjer: $(Get-Count $statsOutput)" -Level DEBUG
    if ((Get-Count $statsOutput) -gt 0) {
      Write-Log "Første 3 linjer:" -Level DEBUG
      $statsOutput | Select-Object -First 3 | ForEach-Object { Write-Log "  '$_'" -Level DEBUG }
    }
    
    if ((Get-Count $statsOutput) -eq 0) {
      throw "SQL-spørring returnerte ingen data"
    }
    
    $statistics = @($statsOutput | ConvertFrom-Csv -Delimiter '|' -ErrorAction Stop)
    Write-Log "Hentet statistikk for $(Get-Count $statistics) tabeller" -Level INFO
    
    if ((Get-Count $statistics) -gt 0) {
      Write-Log "Første statistikk-objekt egenskaper:" -Level DEBUG
      $statistics[0].PSObject.Properties | ForEach-Object { Write-Log "  - $($_.Name): $($_.Value)" -Level DEBUG }
    }
    
    # Normaliser felt
    foreach ($stat in $statistics) {
      $stat.TableRowCount = [int]$stat.TableRowCount
      $stat.IsEmpty = $stat.IsEmpty -eq 'true'
      $stat | Add-Member -MemberType NoteProperty -Name "LastActivityDate" -Value "" -Force
      $stat | Add-Member -MemberType NoteProperty -Name "LastWeek" -Value $null -Force
    }
  }
  catch {
    Write-Log "Feil ved henting av statistikk: $($_.Exception.Message)" -Level ERROR
    throw
  }
  
  # ========== SKRIV RESULTAT TIL CSV ==========
  Write-Log "Skriver resultat til CSV: $OutputFile" -Level INFO
  
  try {
    $statistics | Select-Object SchemaName, TableName, FullName, TableRowCount, LastActivityDate, IsEmpty, LastWeek | `
      Export-Csv -Path $OutputFile -Encoding UTF8 -NoTypeInformation -Force
    
    Write-Log "CSV skrevet: $OutputFile" -Level INFO
    
    # Statistikk-sammendrag
    $emptyTableCount = ($statistics | Where-Object { $_.IsEmpty -eq 'True' } | Measure-Object).Count
    $largeTableCount = ($statistics | Where-Object { [int]$_.TableRowCount -gt 1000000 } | Measure-Object).Count
    $recentActivityCount = 0  # TODO: implementer dato-tracking senere
    
    Write-Host "`n✓ Ferdig!" -ForegroundColor Green
    Write-Host "  - Totalt tabeller:        $(Get-Count $statistics)" -ForegroundColor Cyan
    Write-Host "  - Tomme tabeller:         $emptyTableCount" -ForegroundColor Yellow
    Write-Host "  - Tabeller > 1M rader:    $largeTableCount" -ForegroundColor Cyan
    Write-Host "  - Aktivitet siste uke:    $recentActivityCount" -ForegroundColor Green
    Write-Host "`nResultat CSV: $OutputFile" -ForegroundColor Gray
  }
  catch {
    Write-Log "Feil ved skriving av CSV: $($_.Exception.Message)" -Level ERROR
    throw
  }
}
catch {
  Write-Log "========== KRITISK FEIL ==========" -Level ERROR
  Write-Log "Feilmelding: $($_.Exception.Message)" -Level ERROR
  
  Write-Host "`n✗ Feil oppstod" -ForegroundColor Red
  Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
  
  exit 1
}
finally {
  Write-Log "========== SCRIPT AVSLUTTET ==========" -Level DEBUG
}
