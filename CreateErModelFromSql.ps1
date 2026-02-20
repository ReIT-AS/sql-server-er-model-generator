<#
.SYNOPSIS
  Genererer ER-modell fra SQL Server (MSSQL) som:
   - Mermaid full (alle kolonner + datatype + PK/FK)
   - Mermaid simple (kun tabeller + relasjoner)
   - DBML (for dbdiagram.io)

.DESCRIPTION
  Dette scriptet kobler til en SQL Server database og genererer ER-modeller i tre formater:
  - Mermaid full modell med alle detaljer
  - Mermaid forenklet modell med bare tabeller og relasjoner
  - DBML format for dbdiagram.io
  
  Scriptet støtter både Windows autentisering og SQL autentisering via .env fil.

.PARAMETER ServerInstance
  SQL Server instans (f.eks. "localhost\SQLEXPRESS" eller "myserver.database.windows.net")

.PARAMETER Database
  Database navn

.PARAMETER SqlCredential
  PSCredential for SQL autentisering (valgfritt). Hvis ikke satt brukes Windows/Azure AD autentisering.

.PARAMETER OutputDir
  Mappe hvor ER-modellene skal lagres (standard: .\erd)

.PARAMETER SchemaFilter
  Array av schema-navn å inkludere (tom = alle schema)

.PARAMETER LogLevel
  Logging nivå: DEBUG, INFO, WARNING, ERROR (standard: INFO)

.PARAMETER UseEnvFile
  Bruk .env fil for konfigurasjon (overstyrer kommandolinje-parametere)

.EXAMPLE
  .\CreateErModelFromSql.ps1 -ServerInstance "localhost\SQLEXPRESS" -Database "MyDB"
  
.EXAMPLE
  .\CreateErModelFromSql.ps1 -UseEnvFile

.NOTES
  - Bruker sys.* metadata (robust)
  - Kardinalitet på FK-siden settes til:
      o{ hvis FK-kolonne(r) er nullable (valgfri relasjon)
      |{ hvis FK-kolonne(r) er NOT NULL (påkrevd relasjon)
  - Krever SqlServer PowerShell modul
  
.LINK
  https://mermaid.js.org/syntax/entityRelationshipDiagram.html
  
.LINK
  https://dbdiagram.io/docs
#>

param(
  [Parameter(Mandatory=$false)]
  [string]$ServerInstance,

  [Parameter(Mandatory=$false)]
  [string]$Database,

  [Parameter(Mandatory=$false)]
  [pscredential]$SqlCredential,

  [Parameter(Mandatory=$false)]
  [string]$OutputDir = ".\erd",

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
$script:LogFilePath = Join-Path $PSScriptRoot "er-model-generator.log"
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
    
    # Skriv til konsoll med farge
    switch ($Level) {
      "DEBUG"   { Write-Host $logMessage -ForegroundColor Gray }
      "INFO"    { Write-Host $logMessage -ForegroundColor White }
      "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
      "ERROR"   { Write-Host $logMessage -ForegroundColor Red }
    }
    
    # Skriv til loggfil
    Add-Content -Path $script:LogFilePath -Value $logMessage -ErrorAction SilentlyContinue
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
    Write-Log "Kopiér .env.template til .env og fyll inn verdier" -Level INFO
    return @{}
  }
  
  $envVars = @{}
  
  try {
    Get-Content $Path | ForEach-Object {
      $line = $_.Trim()
      # Skip kommentarer og tomme linjer
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
    $config.SqlCredential = $null
    if ($EnvVars['DB_USERNAME'] -and $EnvVars['DB_PASSWORD']) {
      try {
        $sec = ConvertTo-SecureString -String $EnvVars['DB_PASSWORD'] -AsPlainText -Force
        $config.SqlCredential = New-Object System.Management.Automation.PSCredential ($EnvVars['DB_USERNAME'], $sec)
      } catch { throw "Kunne ikke lage PSCredential fra .env: $($_.Exception.Message)" }
    }
    $config.OutputDir = if ($EnvVars['OUTPUT_DIR']) { $EnvVars['OUTPUT_DIR'] } else { $OutputDir }
    $config.SchemaFilter = if ($EnvVars['SCHEMA_FILTER']) { 
      @($EnvVars['SCHEMA_FILTER'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } else { 
      @() 
    }
    $config.LogLevel = if ($EnvVars['LOG_LEVEL']) { $EnvVars['LOG_LEVEL'] } else { $LogLevel }
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
    $config.OutputDir = $OutputDir
    $config.SchemaFilter = $SchemaFilter
    $config.LogLevel = $LogLevel
  }
  
  return $config
}

# ========== VALIDATION FUNCTIONS ==========
function Test-SqlcmdTool {
  Write-Log "Sjekker sqlcmd CLI tool..." -Level DEBUG
  
  $sqlcmdPath = Get-Command sqlcmd -ErrorAction SilentlyContinue
  if (-not $sqlcmdPath) {
    Write-Log "sqlcmd ikke funnet i PATH" -Level ERROR
    throw "sqlcmd CLI verktøy er ikke installert. Installer med: brew install mssql-tools@17"
  }
  
  Write-Log "sqlcmd funnet: $($sqlcmdPath.Source)" -Level INFO
}

function Get-Count {
  param($obj)
  if ($null -eq $obj) { return 0 }
  if ($obj -is [array]) { return $obj.Count }
  return 1  # Single object
}

function Resolve-ScriptPath {
  param(
    [Parameter(Mandatory=$true)]
    [string]$PathValue
  )

  $normalized = $PathValue -replace '\\', '/'
  if (-not [System.IO.Path]::IsPathRooted($normalized)) {
    if ($normalized.StartsWith('./')) {
      $normalized = $normalized.Substring(2)
    }
    $normalized = Join-Path $PSScriptRoot $normalized
  }
  return $normalized
}

function Invoke-SqlcmdQuery {
  param(
    [string]$ServerInstance,
    [string]$Database,
    [string]$Query,
    [pscredential]$Credential
  )
  
  Write-Log "Utfører spørring mot $ServerInstance.$Database..." -Level DEBUG

  $tempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
  $tempQueryFile = Join-Path $tempDir "query_$(Get-Random).sql"


  try {
    # Legg til RAW OUTPUT formatering
    $fullQuery = "SET NOCOUNT ON`nSET ANSI_WARNINGS OFF`n" + $Query
    Set-Content -Path $tempQueryFile -Value $fullQuery -Encoding UTF8 -ErrorAction Stop
    
    $sqlcmdArgs = @(
      "-S", $ServerInstance
      "-d", $Database
      "-i", $tempQueryFile
      "-W"  # Trim trailing spaces
      "-s", "|"  # Column separator
      "-w", "256"  # Wide output
      "-C" # I SAID ....ACCEPT
    )
    
    # Legg til autentisering
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
    
    # Kjør sqlcmd og samle output
    $output = & sqlcmd @sqlcmdArgs 2>&1
    
    if ($LASTEXITCODE -ne 0) {
      Write-Log "sqlcmd feilet med exit code $LASTEXITCODE" -Level ERROR
      Write-Log "Output: $output" -Level DEBUG
      throw "sqlcmd feilet: $output"
    }
    
    # Filtrér bort tomme linjer og message-linjer fra sql server
    # Behold første linje (header) og alle data-linjer
    $result = @()
    foreach ($line in $output) {
      # Skip helt tomme linjer
      if (-not $line -or -not $line.Trim()) { continue }
      # Skip message-linjer som slutter med "rows affected"
      if ($line -match "^\(\d+\s+rows? affected\)") { continue }
      # Skip sqlcmd separator-linje (linje med bare bindestreker og pipes)
      if ($line -match "^[\|\-\s]+$") { continue }
      # Legg til gyldig linje
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

function Test-DatabaseConnection {
  param(
    [string]$ServerInstance,
    [string]$Database,
    [pscredential]$Credential
  )
  
  Write-Log "Tester database-tilkobling til $ServerInstance.$Database..." -Level INFO
  
  try {
    $null = Invoke-SqlcmdQuery -ServerInstance $ServerInstance -Database $Database -Credential $Credential -Query "SELECT @@VERSION AS Version"
    Write-Log "Tilkobling vellykket" -Level INFO
    return $true
  }
  catch {
    Write-Log "Tilkobling feilet: $($_.Exception.Message)" -Level ERROR
    throw "Kan ikke koble til database: $($_.Exception.Message)"
  }
}

# ========== MAIN SCRIPT ==========
try {
  Write-Log "========== ER-MODELL GENERATOR STARTER ==========" -Level INFO
  Write-Log "Script kjøres fra: $PSScriptRoot" -Level DEBUG
  
  # Les miljøvariabler hvis .env fil finnes
  $envVars = Read-EnvFile
  
  # Hent konfigurasjon
  $config = Get-Configuration -EnvVars $envVars

  # Normaliser output-sti (relativt til script-mappe)
  $config.OutputDir = Resolve-ScriptPath -PathValue $config.OutputDir
  
  # Oppdater logg-nivå fra konfigurasjon
  $LogLevel = $config.LogLevel
  
  Write-Log "Konfigurasjon:" -Level INFO
  Write-Log "  Server: $($config.ServerInstance)" -Level INFO
  Write-Log "  Database: $($config.Database)" -Level INFO
  Write-Log "  Output: $($config.OutputDir)" -Level INFO
  Write-Log "  Schema filter: $($config.SchemaFilter -join ', ')" -Level INFO
  
  # Valider sqlcmd tool
  Test-SqlcmdTool
  
  # Test database-tilkobling
  Test-DatabaseConnection -ServerInstance $config.ServerInstance -Database $config.Database -Credential $config.SqlCredential
  
  # Opprett output-mappe
  Write-Log "Oppretter output-mappe: $($config.OutputDir)" -Level DEBUG
  New-Item -ItemType Directory -Force -Path $config.OutputDir | Out-Null

  # ========== HENT METADATA FRA DATABASE ==========
  Write-Log "Henter tabeller fra database..." -Level INFO
  
  # ---------- Hent tabeller ----------
  $tablesQuery = @"
SELECT
  s.name  AS SchemaName,
  t.name  AS TableName,
  t.object_id AS ObjectId
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name;
"@

  try {
    $tablesOutput = Invoke-SqlcmdQuery -ServerInstance $config.ServerInstance -Database $config.Database -Query $tablesQuery -Credential $config.SqlCredential
    Write-Log "Raw sqlcmd output: $($tablesOutput.GetType())" -Level DEBUG
    
    $tables = @($tablesOutput | ConvertFrom-Csv -Delimiter '|')
    Write-Log "Hentet $(Get-Count $tables) tabeller" -Level INFO
    
    $filterCount = if ($config.SchemaFilter) { (Get-Count $config.SchemaFilter) } else { 0 }
    if ($filterCount -gt 0) {
      $tables = @($tables | Where-Object { $config.SchemaFilter -contains $_.SchemaName })
      Write-Log "Filtrert basert på schema-filter" -Level INFO
    }
    
    if ((Get-Count $tables) -eq 0) {
      throw "Ingen tabeller funnet i databasen"
    }
  }
  catch {
    Write-Log "Feil ved henting av tabeller: $($_.Exception.Message)" -Level ERROR
    throw
  }

  # ---------- Hent kolonner + datatype ----------
  Write-Log "Henter kolonner og datatyper..." -Level INFO
  
  $columnsQuery = @"
SELECT
  s.name AS SchemaName,
  t.name AS TableName,
  c.name AS ColumnName,
  ty.name AS DataType,
  c.max_length AS MaxLength,
  c.precision AS [Precision],
  c.scale AS [Scale],
  c.is_nullable AS IsNullable,
  c.column_id AS ColumnId,
  t.object_id AS ObjectId
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name, c.column_id;
"@

  try {
    $columnsOutput = Invoke-SqlcmdQuery -ServerInstance $config.ServerInstance -Database $config.Database -Query $columnsQuery -Credential $config.SqlCredential
    $columns = @($columnsOutput | ConvertFrom-Csv -Delimiter '|')
    Write-Log "Hentet $(Get-Count $columns) kolonner" -Level INFO
    
    if ($filterCount -gt 0) {
      $columns = @($columns | Where-Object { $config.SchemaFilter -contains $_.SchemaName })
      Write-Log "Filtrert kolonner basert på schema" -Level DEBUG
    }
  }
  catch {
    Write-Log "Feil ved henting av kolonner: $($_.Exception.Message)" -Level ERROR
    throw
  }

  # ---------- Hent PK-kolonner ----------
  Write-Log "Henter primærnøkler..." -Level INFO
  
  $pkQuery = @"
SELECT
  s.name AS SchemaName,
  t.name AS TableName,
  c.name AS ColumnName
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
JOIN sys.tables t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE i.is_primary_key = 1
  AND t.is_ms_shipped = 0
ORDER BY s.name, t.name, ic.key_ordinal;
"@

  try {
    $pkOutput = Invoke-SqlcmdQuery -ServerInstance $config.ServerInstance -Database $config.Database -Query $pkQuery -Credential $config.SqlCredential
    $pkCols = @($pkOutput | ConvertFrom-Csv -Delimiter '|')
    Write-Log "Hentet $(Get-Count $pkCols) primærnøkkel-kolonner" -Level INFO
    
    if ($filterCount -gt 0) {
      $pkCols = @($pkCols | Where-Object { $config.SchemaFilter -contains $_.SchemaName })
    }
    
    $pkSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($r in $pkCols) {
      $null = $pkSet.Add("$($r.SchemaName).$($r.TableName).$($r.ColumnName)")
    }
    Write-Log "Opprettet PK-sett med $($pkSet.Count) nøkler" -Level DEBUG
  }
  catch {
    Write-Log "Feil ved henting av primærnøkler: $($_.Exception.Message)" -Level ERROR
    throw
  }

  # ---------- Hent FK-relasjoner ----------
  Write-Log "Henter fremmednøkler og relasjoner..." -Level INFO
  
  $fkQuery = @"
SELECT
  fk.name AS ForeignKeyName,
  sFrom.name AS FromSchema,
  tFrom.name AS FromTable,
  sTo.name AS ToSchema,
  tTo.name AS ToTable,
  cFrom.name AS FromColumn,
  cTo.name AS ToColumn,
  cFrom.is_nullable AS FromIsNullable,
  fkc.constraint_column_id AS Ordinal
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.tables tFrom ON tFrom.object_id = fkc.parent_object_id
JOIN sys.schemas sFrom ON sFrom.schema_id = tFrom.schema_id
JOIN sys.columns cFrom ON cFrom.object_id = fkc.parent_object_id AND cFrom.column_id = fkc.parent_column_id

JOIN sys.tables tTo ON tTo.object_id = fkc.referenced_object_id
JOIN sys.schemas sTo ON sTo.schema_id = tTo.schema_id
JOIN sys.columns cTo ON cTo.object_id = fkc.referenced_object_id AND cTo.column_id = fkc.referenced_column_id

WHERE tFrom.is_ms_shipped = 0 AND tTo.is_ms_shipped = 0
ORDER BY fk.name, fkc.constraint_column_id;
"@

  try {
    $fkOutput = Invoke-SqlcmdQuery -ServerInstance $config.ServerInstance -Database $config.Database -Query $fkQuery -Credential $config.SqlCredential
    $fks = @($fkOutput | ConvertFrom-Csv -Delimiter '|')
    Write-Log "Hentet $(Get-Count $fks) fremmednøkkel-kolonner" -Level INFO
    
    if ($filterCount -gt 0) {
      $fks = @($fks | Where-Object { ($config.SchemaFilter -contains $_.FromSchema) -and ($config.SchemaFilter -contains $_.ToSchema) })
      Write-Log "Filtrert fremmednøkler basert på schema" -Level DEBUG
    }
  }
  catch {
    Write-Log "Feil ved henting av fremmednøkler: $($_.Exception.Message)" -Level ERROR
    throw
  }

  # ========== HELPER FUNCTIONS ==========
  Write-Log "Forbereder datastrukturer..." -Level DEBUG
  
  function Format-SqlType {
    param($row)
    $t = $row.DataType

    # Lengde/precision/scale i lesbar form (enkelt og "godt nok" for dokumentasjon)
    switch -Regex ($t) {
      '^(n?varchar|n?char|varbinary|binary)$' {
        if ($row.MaxLength -eq -1) { return "$t(max)" }
        if ($t -like "n*") { return "$t($([int]($row.MaxLength/2)))" } # nvarchar/nchar er 2 byte per tegn
        return "$t($($row.MaxLength))"
      }
      '^(decimal|numeric)$' {
        return "$t($($row.Precision),$($row.Scale))"
      }
      default { return $t }
    }
  }

  function ConvertTo-SafeName {
    param(
      $schema,
      $table
    )
    # Mermaid liker ikke punktum i entity-navn → bruk underscore
    return ($schema + "_" + $table)
  }

  # Group columns per table
  Write-Log "Grupperer kolonner per tabell..." -Level DEBUG
  $colsByTable = @($columns | Group-Object SchemaName,TableName)
  Write-Log "Opprettet $(Get-Count $colsByTable) tabellgrupper" -Level DEBUG

  # Group FK rows per FK-name (for sammensatte nøkler)
  Write-Log "Grupperer fremmednøkler..." -Level DEBUG
  $fkByName = @($fks | Group-Object ForeignKeyName)
  Write-Log "Opprettet $(Get-Count $fkByName) FK-grupper" -Level DEBUG

  # ========== GENERERER MERMAID FULL ==========
  Write-Log "Genererer Mermaid full modell..." -Level INFO
  
  $mermaidFull = New-Object System.Text.StringBuilder
  $null = $mermaidFull.AppendLine("erDiagram")

  foreach ($grp in $colsByTable) {
    $schema = $grp.Group[0].SchemaName
    $table  = $grp.Group[0].TableName
    $entity = ConvertTo-SafeName $schema $table
    $null = $mermaidFull.AppendLine("  $entity {")
    foreach ($col in $grp.Group) {
      $type = Format-SqlType $col
      $pkTag = ""
      if ($pkSet.Contains("$schema.$table.$($col.ColumnName)")) { $pkTag = " PK" }

      # Valgfritt å merke FK-kolonner i full-visning: vi lar det stå rent og bruker relasjonslinjene under.
      $null = $mermaidFull.AppendLine(("    {0} {1}{2}" -f $type, $col.ColumnName, $pkTag))
    }
    $null = $mermaidFull.AppendLine("  }")
    $null = $mermaidFull.AppendLine("")
  }

  # Relasjoner med enkel kardinalitet (1 til mange, optional hvis nullable)
  foreach ($fkGroup in $fkByName) {
    $rows = $fkGroup.Group
    $fromSchema = $rows[0].FromSchema
    $fromTable  = $rows[0].FromTable
    $toSchema   = $rows[0].ToSchema
    $toTable    = $rows[0].ToTable
    $fkName     = $rows[0].ForeignKeyName

    $fromEntity = ConvertTo-SafeName $fromSchema $fromTable
    $toEntity   = ConvertTo-SafeName $toSchema $toTable

    $nullableAny = ($rows | Where-Object { $_.FromIsNullable -eq 1 } | Measure-Object).Count -gt 0
    $manyMark = if ($nullableAny) { "o{" } else { "|{" }  # optional many vs mandatory many

    # Referenced side antas "exactly one" (||)
    $null = $mermaidFull.AppendLine(("  {0} ||--{1} {2} : ""{3}""" -f $toEntity, $manyMark, $fromEntity, $fkName))
  }
  
  Write-Log "Mermaid full modell generert med $(Get-Count $colsByTable) tabeller" -Level INFO

  # ========== GENERERER MERMAID SIMPLE ==========
  Write-Log "Genererer Mermaid forenklet modell..." -Level INFO
  
  $mermaidSimple = New-Object System.Text.StringBuilder
  $null = $mermaidSimple.AppendLine("erDiagram")
  $null = $mermaidSimple.AppendLine("")

  foreach ($t in $tables) {
    if ($filterCount -gt 0 -and ($config.SchemaFilter -notcontains $t.SchemaName)) { continue }
    $entity = ConvertTo-SafeName $t.SchemaName $t.TableName
    $null = $mermaidSimple.AppendLine("  $entity")
  }
  $null = $mermaidSimple.AppendLine("")

  foreach ($fkGroup in $fkByName) {
    $rows = $fkGroup.Group
    $fromEntity = ConvertTo-SafeName $rows[0].FromSchema $rows[0].FromTable
    $toEntity   = ConvertTo-SafeName $rows[0].ToSchema $rows[0].ToTable
    $fkName     = $rows[0].ForeignKeyName

    $nullableAny = ($rows | Where-Object { $_.FromIsNullable -eq 1 } | Measure-Object).Count -gt 0
    $manyMark = if ($nullableAny) { "o{" } else { "|{" }

    $null = $mermaidSimple.AppendLine(("  {0} ||--{1} {2} : ""{3}""" -f $toEntity, $manyMark, $fromEntity, $fkName))
  }
  
  Write-Log "Mermaid forenklet modell generert" -Level INFO

  # ========== GENERERER DBML ==========
  Write-Log "Genererer DBML modell..." -Level INFO
  
  $dbml = New-Object System.Text.StringBuilder

  # Tables + columns
  foreach ($grp in $colsByTable) {
    $schema = $grp.Group[0].SchemaName
    $table  = $grp.Group[0].TableName
    $fullName = "$schema.$table"

    $null = $dbml.AppendLine("Table $fullName {")
    foreach ($col in $grp.Group) {
      $type = Format-SqlType $col
      $attrs = @()
      if ($pkSet.Contains("$schema.$table.$($col.ColumnName)")) { $attrs += "pk" }
      if ($col.IsNullable -eq 0) { $attrs += "not null" }

      if ($attrs.Count -gt 0) {
        $null = $dbml.AppendLine(("  {0} {1} [{2}]" -f $col.ColumnName, $type, ($attrs -join ", ")))
      } else {
        $null = $dbml.AppendLine(("  {0} {1}" -f $col.ColumnName, $type))
      }
    }
    $null = $dbml.AppendLine("}")
    $null = $dbml.AppendLine("")
  }

  # Refs (bruker første kolonnepar for navn, men skriver én Ref per FK – dbdiagram tåler dette fint)
  foreach ($fkGroup in $fkByName) {
    $rows = @($fkGroup.Group | Sort-Object Ordinal)
    $fkName = $rows[0].ForeignKeyName

    # For kompositt-FK: DBML støtter også (a,b) - (x,y), men vi holder det enkelt:
    if ($rows.Count -eq 1) {
      $from = "$($rows[0].FromSchema).$($rows[0].FromTable).$($rows[0].FromColumn)"
      $to   = "$($rows[0].ToSchema).$($rows[0].ToTable).$($rows[0].ToColumn)"
      $null = $dbml.AppendLine(("Ref: {0} > {1} // {2}" -f $from, $to, $fkName))
    } else {
      $fromCols = $rows | ForEach-Object { "$($_.FromSchema).$($_.FromTable).$($_.FromColumn)" }
      $toCols   = $rows | ForEach-Object { "$($_.ToSchema).$($_.ToTable).$($_.ToColumn)" }
      $null = $dbml.AppendLine(("Ref: ({0}) > ({1}) // {2}" -f ($fromCols -join ", "), ($toCols -join ", "), $fkName))
    }
  }
  
  Write-Log "DBML modell generert" -Level INFO

  # ========== SKRIV FILER ==========
  Write-Log "Skriver ER-modeller til filer..." -Level INFO
  
  try {
    $fullPath   = Join-Path $config.OutputDir "schema.full.mmd"
    $simplePath = Join-Path $config.OutputDir "schema.simple.mmd"
    $dbmlPath   = Join-Path $config.OutputDir "schema.dbml"

    [System.IO.File]::WriteAllText($fullPath,   $mermaidFull.ToString(),   [System.Text.Encoding]::UTF8)
    Write-Log "Skrevet: $fullPath" -Level DEBUG
    
    [System.IO.File]::WriteAllText($simplePath, $mermaidSimple.ToString(), [System.Text.Encoding]::UTF8)
    Write-Log "Skrevet: $simplePath" -Level DEBUG
    
    [System.IO.File]::WriteAllText($dbmlPath,   $dbml.ToString(),          [System.Text.Encoding]::UTF8)
    Write-Log "Skrevet: $dbmlPath" -Level DEBUG

    Write-Log "========== ER-MODELLER GENERERT VELLYKKET ==========" -Level INFO
    Write-Host "`n Ferdig!" -ForegroundColor Green
    Write-Host "  - Mermaid full:   $fullPath" -ForegroundColor Cyan
    Write-Host "  - Mermaid simple: $simplePath" -ForegroundColor Cyan
    Write-Host "  - DBML:           $dbmlPath" -ForegroundColor Cyan
    Write-Host "  - Tabeller:       $(Get-Count $colsByTable)" -ForegroundColor Cyan
    Write-Host "  - Relasjoner:     $(Get-Count $fkByName)" -ForegroundColor Cyan
    Write-Host "`nLoggfil: $script:LogFilePath" -ForegroundColor Gray
  }
  catch {
    Write-Log "Feil ved skriving av filer: $($_.Exception.Message)" -Level ERROR
    throw
  }
}
catch {
  Write-Log "========== KRITISK FEIL ==========" -Level ERROR
  Write-Log "Feilmelding: $($_.Exception.Message)" -Level ERROR
  Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level DEBUG
  
  Write-Host "`n Feil oppstod under generering av ER-modeller" -ForegroundColor Red
  Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "`nSjekk loggfil for detaljer: $script:LogFilePath" -ForegroundColor Yellow
  
  exit 1
}
finally {
  Write-Log "========== SCRIPT AVSLUTTET ==========" -Level DEBUG
}
