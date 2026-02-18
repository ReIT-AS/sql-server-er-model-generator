<#
.SYNOPSIS
  Kombinerer ER-modell med tabellstatistikk for å identifisere "døde" tabeller.

.DESCRIPTION
  Leser table-statistics.csv og schema.simple.mmd og genererer:
  1. Liste over tomme tabeller
  2. Liste over inaktive tabeller (ingen aktivitet lenge)
  3. Filtrert ER-modell med bare aktive tabeller

.PARAMETER StatisticsFile
  CSV-fil med tabellstatistikk (default: .\table-statistics.csv)

.PARAMETER MermaidFile
  Mermaid ERD-fil å filtrere (default: .\erd\schema.simple.mmd)

.PARAMETER OutputDir
  Output-mappe for filtrert ER-modell (default: .\erd\filtered).
  dead-tables.csv skrives alltid ved siden av StatisticsFile.

.PARAMETER MinRowCount
  Minimalt antall rader for å være "aktiv" (default: 1)

.EXAMPLE
  .\FilterDeadTables.ps1

.NOTES
  - Forutsetter GetTableStatistics.ps1 og CreateErModelFromSql.ps1 er kjørt
#>

param(
  [Parameter(Mandatory=$false)]
  [string]$StatisticsFile = ".\table-statistics.csv",

  [Parameter(Mandatory=$false)]
  [string]$MermaidFile = ".\erd\schema.simple.mmd",

  [Parameter(Mandatory=$false)]
  [string]$OutputDir = ".\erd\filtered",

  [Parameter(Mandatory=$false)]
  [int]$MinRowCount = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
  Write-Host "`n========== DEAD TABLE FILTER STARTER ==========" -ForegroundColor Cyan
  
  # Sjekk at filer finnes
  if (-not (Test-Path $StatisticsFile)) {
    throw "Statistikk-fil ikke funnet: $StatisticsFile`nKjør GetTableStatistics.ps1 først."
  }
  if (-not (Test-Path $MermaidFile)) {
    throw "Mermaid-fil ikke funnet: $MermaidFile`nKjør CreateErModelFromSql.ps1 først."
  }
  
  Write-Host "  Laster statistikk fra: $StatisticsFile" -ForegroundColor Gray
  Write-Host "  Laster Mermaid ERD fra: $MermaidFile" -ForegroundColor Gray
  
  # Opprett output-mappe
  New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
  
  # Les statistikk
  $stats = Import-Csv $StatisticsFile
  Write-Host "  ✓ Lastet $(($stats | Measure-Object).Count) tabeller fra statistikk" -ForegroundColor Green
  
  # Les Mermaid-fil
  $mermaidContent = Get-Content $MermaidFile -Raw
  
  # ===== KATEGORISER TABELLER =====
  $emptyTables = @()
  $activeTables = @()
  
  foreach ($table in $stats) {
    $rowCount = [int]$table.TableRowCount
    $isEmptyFlag = ($table.IsEmpty -eq 'True')
    
    if ($isEmptyFlag -or $rowCount -lt $MinRowCount) {
      $emptyTables += $table
    } else {
      $activeTables += $table
    }
  }
  
  Write-Host "`n  📊 STATISTIKK:" -ForegroundColor Yellow
  Write-Host "    - Totalt tabeller:      $(($stats | Measure-Object).Count)" -ForegroundColor Cyan
  Write-Host "    - Aktive tabeller:      $(($activeTables | Measure-Object).Count)" -ForegroundColor Green
  Write-Host "    - Døde tabeller:        $(($emptyTables | Measure-Object).Count)" -ForegroundColor Red
  
  # ===== EKSPORTER LISTER =====
  $statisticsDir = Split-Path -Parent (Resolve-Path $StatisticsFile)
  $deadTablesFile = Join-Path $statisticsDir "dead-tables.csv"
  $emptyTables | Select-Object SchemaName, TableName, FullName, TableRowCount | `
    Export-Csv -Path $deadTablesFile -Encoding UTF8 -NoTypeInformation
  Write-Host "`n  ✓ Eksportert døde tabeller til: $deadTablesFile" -ForegroundColor Green
  
  $activeTablesList = $activeTables | ForEach-Object { $_.FullName }
  
  # ===== GENERER FILTRERT MERMAID-MODELL =====
  Write-Host "  Genererer filtrert Mermaid-modell..." -ForegroundColor Yellow
  
  $filteredMermaid = New-Object System.Text.StringBuilder
  $null = $filteredMermaid.AppendLine("erDiagram")
  $null = $filteredMermaid.AppendLine("")
  
  # Behold kun entiteter fra aktive tabeller
  foreach ($line in $mermaidContent -split "`n") {
    $line = $line.Trim()
    
    if ($line -eq "" -or $line -eq "erDiagram") { continue }
    
    # Sjekk om linja er en entity-deklarasjon
    if ($line -match '^\s*\w+') {
      $entityName = [regex]::Match($line, '^\s*(\w+)').Groups[1].Value
      
      # Konverter entity-navn tilbake til schema.tabell
      $found = $false
      foreach ($activeTable in $activeTables) {
        $safeName = $activeTable.FullName -replace '\.', '_'
        if ($safeName -eq $entityName) {
          $null = $filteredMermaid.AppendLine("  $entityName")
          $found = $true
          break
        }
      }
    }
    # Behold relationship-linjer der begge entiteter er aktive
    elseif ($line -match '\|\||-|--|') {
      $parts = $line -split '\s+' | Where-Object { $_ }
      if ($parts.Count -ge 3) {
        $fromEntity = $parts[0]
        $toEntity = $parts[-1]
        
        # Sjekk at begge entiteter er aktive
        $fromActive = $activeTables | Where-Object { ($_.FullName -replace '\.', '_') -eq $fromEntity }
        $toActive = $activeTables | Where-Object { ($_.FullName -replace '\.', '_') -eq $toEntity }
        
        if ($fromActive -and $toActive) {
          $null = $filteredMermaid.AppendLine("  $line")
        }
      }
    }
  }
  
  $filteredMermaidFile = Join-Path $OutputDir "schema-active-only.mmd"
  [System.IO.File]::WriteAllText($filteredMermaidFile, $filteredMermaid.ToString(), [System.Text.Encoding]::UTF8)
  Write-Host "  ✓ Filtrert Mermaid-modell skrevet til: $filteredMermaidFile" -ForegroundColor Green
  
  # ===== OPPSUMMERING =====
  Write-Host "`n  💡 ANBEFALINGER:" -ForegroundColor Yellow
  Write-Host "    1. Gjennomgang av døde tabeller:" -ForegroundColor Cyan
  Write-Host "       - Åpne: $deadTablesFile" -ForegroundColor Gray
  Write-Host "       - Bekreft med forretningsteam før sletting" -ForegroundColor Gray
  Write-Host "`n    2. Filtrert ER-modell:" -ForegroundColor Cyan
  Write-Host "       - Åpne: $filteredMermaidFile" -ForegroundColor Gray
  Write-Host "       - Visualiser med dbdiagram.io eller Mermaid Viewer" -ForegroundColor Gray
  Write-Host "`n    3. Slette døde tabeller:" -ForegroundColor Cyan
  Write-Host "       - Bruk 'dead-tables.csv' som referanse" -ForegroundColor Gray
  Write-Host "       - Generer DROP TABLE-script hvis ønskelig" -ForegroundColor Gray
  
  Write-Host "`n✓ Ferdig!" -ForegroundColor Green
}
catch {
  Write-Host "`n✗ Feil oppstod:" -ForegroundColor Red
  Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
finally {
  Write-Host ""
}
