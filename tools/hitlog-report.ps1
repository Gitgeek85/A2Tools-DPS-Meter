<#
.SYNOPSIS
  A2Tools fork - per-hit damage report from the hit log.

.DESCRIPTION
  Reads hits_<date>.jsonl written by the meter (combat/hit_log.rs) and prints:
    1. Outgoing damage per skill, split by position (Normal / Front / Back)
       and crit, with average, median, min, max and % vs the skill's own
       Normal non-crit baseline.
    2. Damage taken, by attacker and skill.

  Compares each skill only against itself. "Clean" hits only by default
  (no Double / Perfect / Parry / Block), so those modifiers don't skew the
  position comparison. Use -IncludeSpecial to keep them.

.EXAMPLE
  .\hitlog-report.ps1                      # today's log, all of it
  .\hitlog-report.ps1 -LastMinutes 15      # just the last 15 minutes
  .\hitlog-report.ps1 -Skill "Overhead Slam"
  .\hitlog-report.ps1 -Target boss -Csv    # bosses only, also write CSVs
#>
[CmdletBinding()]
param(
    [string]$Path,
    [int]$LastMinutes = 0,
    [string]$Skill,
    [ValidateSet('all', 'boss', 'mob', 'dummy', 'player', 'unknown')]
    [string]$Target = 'all',
    [int]$MinHits = 5,
    [switch]$IncludeSpecial,
    [switch]$Csv
)

$ErrorActionPreference = 'Stop'
$appData = if ($env:APPDATA) { Join-Path $env:APPDATA 'com.a2tools.dps-meter' } else { Join-Path $HOME '.a2tools-test' }
$logDir = Join-Path $appData 'hitlog'

if (-not $Path) {
    $latest = Get-ChildItem -Path $logDir -Filter 'hits_*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "No hit log found in $logDir. Fight something with the meter running first." }
    $Path = $latest.FullName
}

# Skill / NPC names from the repo's game data (this script lives in <repo>\tools).
$repo = Split-Path $PSScriptRoot -Parent
$skillNames = @{}
$npcNames = @{}
$skillsJson = Join-Path $repo 'src\data\i18n\skills\en.json'
$npcsJson = Join-Path $repo 'src\data\i18n\npcs\en.json'
if (Test-Path $skillsJson) {
    (Get-Content $skillsJson -Raw | ConvertFrom-Json -AsHashtable).GetEnumerator() |
        ForEach-Object { $skillNames[[string]$_.Key] = [string]$_.Value }
}
if (Test-Path $npcsJson) {
    (Get-Content $npcsJson -Raw | ConvertFrom-Json -AsHashtable).GetEnumerator() |
        ForEach-Object { $npcNames[[string]$_.Key] = [string]$_.Value.name }
}
function Get-SkillName([int]$code) {
    $n = $skillNames[[string]$code]
    if ($n) { $n } else { "Skill $code" }
}
function Get-NpcName([int]$code, [string]$kind) {
    if ($code -ne 0 -and $npcNames[[string]$code]) { return $npcNames[[string]$code] }
    if ($kind -eq 'player') { return 'Player' }
    "NPC $code"
}

$hits = Get-Content $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
if ($LastMinutes -gt 0) {
    $cut = [DateTimeOffset]::UtcNow.AddMinutes(-$LastMinutes).ToUnixTimeMilliseconds()
    $hits = $hits | Where-Object { $_.ts -ge $cut }
}
if ($Target -ne 'all') { $hits = $hits | Where-Object { $_.other -eq $Target } }

Write-Host ""
Write-Host "Hit log: $Path" -ForegroundColor Cyan
Write-Host ("{0} hits loaded ({1} out, {2} in)" -f @($hits).Count,
    @($hits | Where-Object dir -eq 'out').Count, @($hits | Where-Object dir -eq 'in').Count)

function Get-Median([double[]]$v) {
    if (-not $v -or $v.Count -eq 0) { return 0 }
    $s = $v | Sort-Object
    $m = [int][math]::Floor($s.Count / 2)
    if ($s.Count % 2) { $s[$m] } else { ($s[$m - 1] + $s[$m]) / 2 }
}

# ---------- 1. Outgoing: position x crit ----------
$out = @($hits | Where-Object { $_.dir -eq 'out' -and -not $_.dot -and $_.dmg -gt 0 -and $_.other -ne 'player' })
if (-not $IncludeSpecial) {
    $out = @($out | Where-Object { -not ($_.double -or $_.perfect -or $_.parry -or $_.block) })
}
foreach ($h in $out) {
    $h | Add-Member -NotePropertyName skillName -NotePropertyValue (Get-SkillName $h.skill) -Force
    $pos = if ($h.back) { 'Back' } elseif ($h.front) { 'Front' } else { 'Normal' }
    $h | Add-Member -NotePropertyName pos -NotePropertyValue $pos -Force
}
if ($Skill) { $out = @($out | Where-Object { $_.skillName -like "*$Skill*" }) }

$posOrder = @{ 'Normal' = 0; 'Front' = 1; 'Back' = 2 }
$rows = foreach ($g in ($out | Group-Object skillName | Where-Object Count -ge $MinHits | Sort-Object { ($_.Group | Measure-Object dmg -Sum).Sum } -Descending)) {
    $base = @($g.Group | Where-Object { $_.pos -eq 'Normal' -and -not $_.crit })
    $baseAvg = if ($base.Count) { ($base | Measure-Object dmg -Average).Average } else { 0 }
    $buckets = $g.Group | Group-Object { "{0}|{1}" -f $_.pos, $_.crit } |
        Sort-Object { $p = $_.Group[0]; $posOrder[$p.pos] * 2 + [int][bool]$p.crit }
    foreach ($b in $buckets) {
        $first = $b.Group[0]
        $d = [double[]]@($b.Group | ForEach-Object { $_.dmg })
        $avg = ($d | Measure-Object -Average).Average
        [pscustomobject]@{
            Skill    = $g.Name
            Position = $first.pos
            Crit     = if ($first.crit) { 'Crit' } else { '-' }
            Hits     = $b.Count
            Avg      = [int][math]::Round($avg)
            Median   = [int][math]::Round((Get-Median $d))
            Min      = [int]($d | Measure-Object -Minimum).Minimum
            Max      = [int]($d | Measure-Object -Maximum).Maximum
            'vsBase' = if ($baseAvg -gt 0) { '{0:+0.0;-0.0;0.0}%' -f (100 * ($avg / $baseAvg - 1)) } else { 'n/a' }
            Note     = if ($b.Count -lt 30) { 'low sample' } else { '' }
        }
    }
}

Write-Host ""
Write-Host "=== OUTGOING DAMAGE by position and crit (main hit, $(if ($IncludeSpecial) {'all'} else {'clean'}) hits) ===" -ForegroundColor Yellow
Write-Host "vsBase = compared with the same skill's Normal, non-crit hits. Under 30 hits = treat as a hint, not proof." -ForegroundColor DarkGray
if ($rows) { $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host }
else { Write-Host "  (no outgoing hits yet)" }

# Overall position summary, all skills, by share of hits
if ($out.Count) {
    Write-Host "Hit share across all skills:" -ForegroundColor Yellow
    $out | Group-Object pos | Sort-Object { $posOrder[$_.Name] } | ForEach-Object {
        $c = @($_.Group | Where-Object crit).Count
        "  {0,-7} {1,6} hits ({2,5:N1}%)   crit rate {3,5:N1}%" -f $_.Name, $_.Count, (100 * $_.Count / $out.Count), (100 * $c / [math]::Max(1, $_.Count))
    } | Write-Host
}

# ---------- 2. Incoming: damage taken ----------
$in = @($hits | Where-Object { $_.dir -eq 'in' -and $_.total -gt 0 -and $_.other -ne 'player' })
Write-Host ""
Write-Host "=== DAMAGE TAKEN (from NPCs) ===" -ForegroundColor Yellow
if ($in.Count) {
    $tot = ($in | Measure-Object total -Sum).Sum
    Write-Host ("  Total {0:N0} from {1} hits, avg {2:N0}, biggest {3:N0}" -f $tot, $in.Count,
        ($in | Measure-Object total -Average).Average, ($in | Measure-Object total -Maximum).Maximum)
    $taken = $in | Group-Object { "{0}|{1}" -f (Get-NpcName $_.other_code $_.other), (Get-SkillName $_.skill) } |
        ForEach-Object {
            $parts = $_.Name -split '\|', 2
            $s = ($_.Group | Measure-Object total -Sum -Average -Maximum)
            [pscustomobject]@{
                Attacker = $parts[0]
                Skill    = $parts[1]
                Hits     = $_.Count
                Total    = [int64]$s.Sum
                Share    = '{0:N1}%' -f (100 * $s.Sum / $tot)
                Avg      = [int][math]::Round($s.Average)
                Max      = [int]$s.Maximum
                Crits    = @($_.Group | Where-Object crit).Count
                Blocked  = @($_.Group | Where-Object { $_.block -or $_.parry }).Count
            }
        } | Sort-Object Total -Descending | Select-Object -First 25
    $taken | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
} else {
    Write-Host "  (no damage taken from NPCs in this log)"
}

# ---------- 3. Player hits (PvP / heals) - just counted for now ----------
$pvp = @($hits | Where-Object other -eq 'player')
if ($pvp.Count) {
    Write-Host ("Player-to-player lines (PvP or heals, not analysed yet): {0} out, {1} in" -f
        @($pvp | Where-Object dir -eq 'out').Count, @($pvp | Where-Object dir -eq 'in').Count) -ForegroundColor DarkGray
}

if ($Csv) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $o1 = Join-Path $logDir "report_outgoing_$stamp.csv"
    $o2 = Join-Path $logDir "report_taken_$stamp.csv"
    if ($rows) { $rows | Export-Csv $o1 -NoTypeInformation }
    if ($taken) { $taken | Export-Csv $o2 -NoTypeInformation }
    Write-Host "CSV written to $logDir" -ForegroundColor Cyan
}
