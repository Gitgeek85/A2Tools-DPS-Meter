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

$all = @(Get-Content $Path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
if ($LastMinutes -gt 0) {
    $cut = [DateTimeOffset]::UtcNow.AddMinutes(-$LastMinutes).ToUnixTimeMilliseconds()
    $all = @($all | Where-Object { $_.ts -ge $cut })
}
# Older lines have no "kind": they are hits.
$hits   = @($all | Where-Object { -not $_.kind -or $_.kind -eq 'hit' })
$events = @($all | Where-Object { $_.kind -in 'heal', 'hot', 'mp' })
$stats  = @($all | Where-Object { $_.kind -eq 'stats' })
# You = the actor of your outgoing hits.
$me = ($hits | Where-Object dir -eq 'out' | Group-Object actor | Sort-Object Count -Descending | Select-Object -First 1).Name
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
# ---------- 3. Healing received ----------
Write-Host ""
Write-Host "=== HEALING RECEIVED ===" -ForegroundColor Yellow
$healRows = [System.Collections.Generic.List[object]]::new()
foreach ($e in ($events | Where-Object { $_.kind -in 'heal', 'hot' -and [string]$_.target -eq $me })) {
    $src = if ([string]$e.actor -eq $me) { 'You' } else { 'Party' }
    $healRows.Add([pscustomobject]@{ From = $src; Skill = (Get-SkillName $e.skill); Type = $e.kind.ToUpper(); Amount = [int64]$e.amount })
}
# Party heals the meter files as player-on-player "hits"
foreach ($h in ($hits | Where-Object { $_.dir -eq 'in' -and $_.other -eq 'player' -and $_.friendly })) {
    $healRows.Add([pscustomobject]@{ From = 'Party'; Skill = (Get-SkillName $h.skill); Type = 'HEAL'; Amount = [int64]$h.total })
}
# Life steal on your own hits
$steal = @($hits | Where-Object { $_.dir -eq 'out' -and $_.heal -gt 0 })
foreach ($h in $steal) {
    $healRows.Add([pscustomobject]@{ From = 'You'; Skill = (Get-SkillName $h.skill) + ' (life steal)'; Type = 'STEAL'; Amount = [int64]$h.heal })
}
if ($healRows.Count) {
    $ht = ($healRows | Measure-Object Amount -Sum).Sum
    Write-Host ("  Total healed {0:N0} from {1} ticks" -f $ht, $healRows.Count)
    $healRows | Group-Object From, Skill, Type | ForEach-Object {
        $m = $_.Group | Measure-Object Amount -Sum -Average -Maximum
        [pscustomobject]@{
            From = $_.Group[0].From; Skill = $_.Group[0].Skill; Type = $_.Group[0].Type
            Ticks = $_.Count; Total = [int64]$m.Sum; Share = '{0:N1}%' -f (100 * $m.Sum / $ht)
            Avg = [int][math]::Round($m.Average); Max = [int]$m.Maximum
        }
    } | Sort-Object Total -Descending | Select-Object -First 20 | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
} else { Write-Host "  (no heals on you in this log - new builds of the meter log these)" }

# ---------- 4. MP and other resources ----------
Write-Host "=== MP / RESOURCE RESTORES ===" -ForegroundColor Yellow
$mp = @($events | Where-Object { $_.kind -eq 'mp' -and [string]$_.target -eq $me })
if ($mp.Count) {
    $mp | Group-Object skill | ForEach-Object {
        $m = $_.Group | Measure-Object amount -Sum -Average -Maximum
        [pscustomobject]@{ Skill = (Get-SkillName ([int]$_.Name)); Ticks = $_.Count; Total = [int64]$m.Sum; Avg = [int][math]::Round($m.Average); Max = [int]$m.Maximum }
    } | Sort-Object Total -Descending | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
} else { Write-Host "  (no MP restore records on you yet)" }

# ---------- 5. Stat sheet (raw) - to find which ids are HP / MP ----------
if ($stats.Count) {
    Write-Host "=== STAT RECORDS (raw ids - for mapping HP/MP etc.) ===" -ForegroundColor Yellow
    $flat = foreach ($st in $stats) { foreach ($v in $st.values) { [pscustomobject]@{ Id = [int]$v[0]; Val = [int64]$v[1]; Ts = $st.ts } } }
    $flat | Group-Object Id | ForEach-Object {
        $m = $_.Group | Measure-Object Val -Minimum -Maximum
        [pscustomobject]@{ StatId = [int]$_.Name; Updates = $_.Count; Min = $m.Minimum; Max = $m.Maximum; Last = ($_.Group | Sort-Object Ts | Select-Object -Last 1).Val }
    } | Sort-Object { -$_.Updates } | Select-Object -First 30 | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host "  Ids that change often with Min..Max like your HP/MP bar are the ones to map." -ForegroundColor DarkGray
}

# ---------- 6. Cooldowns (observed from your casts) ----------
Write-Host "=== SKILL CAST GAPS (observed cooldowns) ===" -ForegroundColor Yellow
Write-Host "  A cast = hits of one skill less than 1.5 s apart. Shortest gap ~ the cooldown; long average = held or forgotten." -ForegroundColor DarkGray
$cd = foreach ($g in ($hits | Where-Object { $_.dir -eq 'out' -and -not $_.dot } | Group-Object { Get-SkillName $_.skill })) {
    $ts = @($g.Group | Sort-Object ts | ForEach-Object { [int64]$_.ts })
    $casts = [System.Collections.Generic.List[int64]]::new()
    foreach ($t in $ts) { if ($casts.Count -eq 0 -or $t - $casts[$casts.Count - 1] -gt 1500) { $casts.Add($t) } else { $casts[$casts.Count - 1] = $t } }
    if ($casts.Count -lt 3) { continue }
    $gaps = for ($i = 1; $i -lt $casts.Count; $i++) { ($casts[$i] - $casts[$i - 1]) / 1000.0 }
    $gaps = @($gaps | Where-Object { $_ -lt 120 })   # ignore gaps between fights
    if ($gaps.Count -lt 2) { continue }
    [pscustomobject]@{
        Skill = $g.Name; Casts = $casts.Count
        'MinGap(s)' = [math]::Round(($gaps | Measure-Object -Minimum).Minimum, 1)
        'MedianGap(s)' = [math]::Round((Get-Median ([double[]]$gaps)), 1)
        'AvgGap(s)' = [math]::Round(($gaps | Measure-Object -Average).Average, 1)
    }
}
if ($cd) { $cd | Sort-Object 'MinGap(s)' -Descending | Format-Table -AutoSize | Out-String -Width 200 | Write-Host }

$pvp = @($hits | Where-Object { $_.other -eq 'player' -and -not $_.friendly -and $_.dir -eq 'out' })
if ($pvp.Count) { Write-Host ("PvP hits logged (not analysed yet): {0}" -f $pvp.Count) -ForegroundColor DarkGray }

if ($Csv) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $o1 = Join-Path $logDir "report_outgoing_$stamp.csv"
    $o2 = Join-Path $logDir "report_taken_$stamp.csv"
    if ($rows) { $rows | Export-Csv $o1 -NoTypeInformation }
    if ($taken) { $taken | Export-Csv $o2 -NoTypeInformation }
    Write-Host "CSV written to $logDir" -ForegroundColor Cyan
}
