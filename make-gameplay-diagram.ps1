# make-gameplay-diagram.ps1
# Standalone. Reads octo-config\rules.md and octo-config\project-brief.md,
# reads every idea note in 02-Generate-Ideas\, keeps only the ones that
# belong to this game (decided by the model from the rules and brief),
# and writes 02-Generate-Ideas\_Gameplay-Diagram.md.
#
# Does not touch the pipeline, processed.txt, or any note.
# All punctuation is ASCII.

param([switch]$Open)

$ErrorActionPreference = "Stop"
$Vault      = Split-Path $PSScriptRoot -Parent
$IdeaDir    = Join-Path $Vault "02-Generate-Ideas"
$RulesFile  = Join-Path $PSScriptRoot "rules.md"
$BriefFile  = Join-Path $PSScriptRoot "project-brief.md"
$OutFile    = Join-Path $IdeaDir "_Gameplay-Diagram.md"
$Ollama     = "http://127.0.0.1:11434"
$Builder    = "qwen2.5:14b"
$Fence      = [string]::new([char]96, 3)
$Utf8       = New-Object System.Text.UTF8Encoding($false)
$Today      = Get-Date -Format "yyyy-MM-dd"
$script:LastRaw = ""
$script:Ctx = 8192

function Say([string]$t, [string]$c = "Gray") { Write-Host $t -ForegroundColor $c }
function Read-Note([string]$path) { return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
function Write-Note([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $Utf8) }

function Normalize([string]$s) {
    if (-not $s) { return "" }
    $s = $s.ToLower()
    $s = $s -replace [char]0x2013, "-"
    $s = $s -replace [char]0x2014, "-"
    $s = $s -replace [char]0x2018, "'"
    $s = $s -replace [char]0x2019, "'"
    $s = $s -replace [char]0x201C, '"'
    $s = $s -replace [char]0x201D, '"'
    $s = $s -replace '\s+', ' '
    $s = $s -replace '[^a-z0-9 \-]', ''
    return $s.Trim()
}

if (-not (Test-Path $IdeaDir)) {
    Say ("No idea folder: " + $IdeaDir) Red
    return
}
if (-not (Test-Path $RulesFile)) {
    Say ("No rules file: " + $RulesFile) Red
    Say "Create octo-config\rules.md with the current rules text and try again."
    return
}
$rulesText = Read-Note $RulesFile
if (-not $rulesText.Trim()) {
    Say ("rules.md is empty: " + $RulesFile) Red
    return
}

$briefText = "No project brief. Assume a generic game."
if (Test-Path $BriefFile) {
    $b = Read-Note $BriefFile
    if ($b.Trim()) {
        $b = $b -replace '(?s)^---\r?\n.*?\r?\n---\r?\n', ''
        $b = $b -replace '(?s)^\s*#\s+[^\n]+\r?\n', ''
        $b = $b -replace '(?s)^\s*>\s*\[![^\]]+\][^\n]*\r?\n(?:\s*>[^\n]*\r?\n)*', ''
        if ($b.Trim()) { $briefText = $b.Trim() }
    }
}

function Test-Ollama {
    try { Invoke-WebRequest -Uri "$Ollama/api/tags" -UseBasicParsing -TimeoutSec 3 | Out-Null; return $true } catch { return $false }
}
function Ensure-Ollama {
    if (Test-Ollama) { return }
    Say "Starting Ollama..."
    Start-Process -FilePath "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" -ArgumentList "serve" -WindowStyle Hidden
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Ollama) { return }
    }
    throw "Ollama did not start."
}

function Read-ErrorBody($ex) {
    try {
        if ($ex.Response) {
            $s = $ex.Response.GetResponseStream()
            if ($s) {
                $reader = New-Object System.IO.StreamReader($s)
                return $reader.ReadToEnd()
            }
        }
    } catch { }
    return ""
}

function Stop-Model([string]$model) {
    try {
        $body = @{ model = $model; keep_alive = 0 } | ConvertTo-Json
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        Invoke-WebRequest -Uri "$Ollama/api/generate" -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -UseBasicParsing -TimeoutSec 30 | Out-Null
    } catch { }
}

function Ensure-Model([string]$model) {
    Say ("Loading model: " + $model + " (this can take 30 seconds)") DarkGray
    $body = @{ model = $model; prompt = "hi"; stream = $false; options = @{ num_ctx = $script:Ctx } } | ConvertTo-Json -Depth 6
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    try {
        Invoke-WebRequest -Uri "$Ollama/api/generate" -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -UseBasicParsing -TimeoutSec 300 | Out-Null
        Say "  model loaded." DarkGray
    } catch {
        $detail = Read-ErrorBody $_.Exception
        if (-not $detail) { $detail = $_.Exception.Message }
        throw ("Could not load " + $model + ": " + $detail)
    }
}

function Ask-Once([string]$model, [string]$system, [string]$prompt, [int]$ctx) {
    $body = @{
        model    = $model
        system   = $system
        prompt   = $prompt
        format   = "json"
        stream   = $false
        keep_alive = "10m"
        options  = @{ temperature = 0.2; num_ctx = $ctx }
    } | ConvertTo-Json -Depth 6
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $r = Invoke-WebRequest -Uri "$Ollama/api/generate" -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -UseBasicParsing -TimeoutSec 900
    $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    $raw = ($txt | ConvertFrom-Json).response
    $script:LastRaw = $raw
    $start = $raw.IndexOf("{")
    $end   = $raw.LastIndexOf("}")
    if ($start -ge 0 -and $end -gt $start) { $raw = $raw.Substring($start, $end - $start + 1) }
    return ($raw | ConvertFrom-Json)
}

function Ask-Model([string]$model, [string]$system, [string]$prompt) {
    $contexts = @($script:Ctx, 4096, 2048)
    foreach ($ctx in $contexts) {
        for ($try = 1; $try -le 2; $try++) {
            try {
                return (Ask-Once $model $system $prompt $ctx)
            } catch {
                $detail = Read-ErrorBody $_.Exception
                if (-not $detail) { $detail = $_.Exception.Message }
                if ($script:LastRaw) {
                    $preview = $script:LastRaw.Substring(0, [Math]::Min(400, $script:LastRaw.Length))
                    Say ("      raw reply (" + $script:LastRaw.Length + " chars): " + $preview) DarkRed
                } else {
                    Say ("      no reply: " + $detail) DarkRed
                }
                if ($try -ge 2) {
                    if ($ctx -eq $contexts[$contexts.Count - 1]) { throw }
                    Say ("      reducing context to " + $contexts[$contexts.IndexOf($ctx) + 1] + " and retrying") DarkYellow
                    Stop-Model $model
                    Start-Sleep -Seconds 2
                    Ensure-Model $model
                    break
                }
                Say ("      (retry " + ($try + 1) + " of 2, ctx = " + $ctx + ")") DarkYellow
                Start-Sleep -Seconds 2
            }
        }
    }
}

Ensure-Ollama
Ensure-Model $Builder

Say ""
Say ("Building: " + $OutFile) Cyan
Say ("  rules.md: " + $rulesText.Length + " chars") DarkGray
Say ("  project-brief.md: " + $briefText.Length + " chars") DarkGray
Say ""

$RelevanceSystem = @'
Read the RULES and the PROJECT BRIEF. This project is one specific game. There are idea notes in the vault from many different projects, some unrelated.

Decide which idea-note CATEGORIES and which SOURCE NOTE NAMES belong to this game. An idea note is relevant if its category is in your category list, or if its source note is in your source list, or both.

Return JSON only, in this shape:
{
  "categories": [ "Card", "Token", "Rule" ],
  "source_notes": [ "Cards 1-60" ],
  "reasoning": "one short sentence"
}

Rules:
- Categories are the idea-note category values (Card, Token, Rule, Component, Art, Text, Player aid, Playtest, Other). Include the categories this game actually uses.
- Source notes are the note names idea notes came from (the From: field). Include only source notes that are about this game.
- If you cannot decide, include the category or source note. Better to over-include than to lose real components.
- Return empty lists only if there is really nothing in the rules to go on.
'@

Say "Step 0 of 5: deciding which idea notes belong to this game..." Yellow
$d0 = $null
try {
    $d0 = Ask-Model $Builder $RelevanceSystem ("PROJECT BRIEF:`n" + $briefText + "`n`nRULES:`n" + $rulesText)
} catch {
    Say ("  failed: " + $_.Exception.Message) Red
    return
}
$keepCats = @($d0.categories | Where-Object { $_ } | ForEach-Object { Normalize ([string]$_) })
$keepSrc  = @($d0.source_notes | Where-Object { $_ } | ForEach-Object { Normalize ([string]$_) })
if ($d0.reasoning) { Say ("  " + $d0.reasoning) DarkGray }
Say ("  categories to keep: " + ($(if ($keepCats.Count) { $keepCats -join ", " } else { "(none)" }))) DarkGray
Say ("  source notes to keep: " + ($(if ($keepSrc.Count) { $keepSrc -join ", " } else { "(none)" }))) DarkGray

$allIdeaFiles = @(Get-ChildItem -Path $IdeaDir -Filter *.md | Where-Object { $_.Name -notlike "_*" } | Sort-Object Name)
Say ("  total idea notes: " + $allIdeaFiles.Count) DarkGray

function Get-IdeaMeta([System.IO.FileInfo]$f) {
    $t = Read-Note $f.FullName
    $cat = ""
    $src = ""
    $m1 = [regex]::Match($t, '(?m)^category:\s*"?([^"\r\n]+)"?\s*$')
    if ($m1.Success) { $cat = $m1.Groups[1].Value.Trim() }
    $m2 = [regex]::Match($t, '(?m)^>\s*From:\s*\[\[([^\]]+)\]\]')
    if (-not $m2.Success) { $m2 = [regex]::Match($t, 'From:\s*\[\[([^\]]+)\]\]') }
    if ($m2.Success) { $src = $m2.Groups[1].Value.Trim() }
    return [pscustomobject]@{ File = $f; Category = $cat; Source = $src; Text = $t }
}

$metas = @($allIdeaFiles | ForEach-Object { Get-IdeaMeta $_ })

function Apply-Filter($metas, $cats, $srcs) {
    $keptList = New-Object System.Collections.Generic.List[object]
    $skippedList = New-Object System.Collections.Generic.List[object]
    foreach ($m in $metas) {
        $mc = Normalize $m.Category
        $ms = Normalize $m.Source
        $catMatch = $cats.Count -eq 0 -or ($mc -and ($cats -contains $mc))
        $srcMatch = $srcs.Count -eq 0 -or ($ms -and ($srcs -contains $ms))
        $keep = $catMatch -or $srcMatch
        if ($cats.Count -eq 0 -and $srcs.Count -eq 0) { $keep = $true }
        if ($keep) { $keptList.Add($m) } else { $skippedList.Add($m) }
    }
    return @{ Kept = $keptList; Skipped = $skippedList }
}

$result = Apply-Filter $metas $keepCats $keepSrc
$kept = $result.Kept
$skipped = $result.Skipped

if ($kept.Count -eq 0) {
    Say "  no match with categories + sources. Retrying with categories only..." DarkYellow
    $result = Apply-Filter $metas $keepCats @()
    $kept = $result.Kept
    $skipped = $result.Skipped
}
if ($kept.Count -eq 0) {
    Say "  no match with categories either. Retrying with any listed category..." DarkYellow
    $result = Apply-Filter $metas @() @()
    $kept = $result.Kept
    $skipped = $result.Skipped
}
if ($kept.Count -eq 0) {
    Say "  still nothing. Processing all idea notes as a fallback." DarkYellow
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($m in $metas) { $kept.Add($m) }
    $skipped = New-Object System.Collections.Generic.List[object]
}

Say ("  kept: " + $kept.Count + "  skipped: " + $skipped.Count) Green

$ideaSummary = ($kept | ForEach-Object {
    $summary = ""
    $m = [regex]::Match($_.Text, '(?m)^## What it is\s*\r?\n+(.+)$')
    if ($m.Success) { $summary = $m.Groups[1].Value.Trim() }
    "- " + $_.File.BaseName + " [" + $_.Category + "] - " + $summary
}) -join "`n"

Say ("  idea summary block: " + $ideaSummary.Length + " chars") DarkGray
Say ""

$ComponentsSystem = @'
Read the RULES and the PROJECT BRIEF. List every physical component in the game and every named rule concept. Every entry must name a specific thing. No "concepts", no "mechanics", no "elements" without saying which.

Return JSON only, in this shape:
{ "components": [ { "name": "exact name", "type": "card | token | board | player piece | marker | deck | other", "purpose": "one short sentence naming what it is and what it does" } ] }

Rules:
- One entry per distinct physical thing or named rule concept.
- If the rules name specific cards (for example "Ministry of Truth"), give each its own entry.
- If cards are a generic class ("Contradiction Card"), one entry for the class.
- "type" must be one of: card, token, board, player piece, marker, deck, other.
- Do not invent. Only things the rules name.
'@

Say "Step 1 of 5: components..." Yellow
$d1 = $null
try {
    $d1 = Ask-Model $Builder $ComponentsSystem ("PROJECT BRIEF:`n" + $briefText + "`n`nRULES:`n" + $rulesText)
} catch {
    Say ("  failed: " + $_.Exception.Message) Red
    return
}
$components = @($d1.components | Where-Object { $_ -and $_.name })
Say ("  " + $components.Count + " component(s).") Green

$ConnectionsSystem = @'
Read the RULES and the PROJECT BRIEF. You are given the list of COMPONENTS already found. List every concrete interaction between components, or between a rule and a component. One arrow per interaction. Every arrow names two specific things.

Return JSON only, in this shape:
{ "connections": [ { "from": "component or rule name", "to": "component or rule name", "label": "short verb phrase", "basis": "short quote or cite from the rules" } ] }

Rules:
- "from" and "to" must be names from the COMPONENTS list, or exact rule names from the rules text.
- Do not merge several interactions into one arrow.
- Do not invent. Only what the rules describe.
'@

$compList = ($components | ForEach-Object { "- " + $_.name + " (" + $_.type + ")" }) -join "`n"
Say "Step 2 of 5: connections..." Yellow
$d2 = $null
try {
    $d2 = Ask-Model $Builder $ConnectionsSystem ("PROJECT BRIEF:`n" + $briefText + "`n`nCOMPONENTS:`n" + $compList + "`n`nRULES:`n" + $rulesText)
} catch {
    Say ("  failed: " + $_.Exception.Message) Red
    return
}
$connections = @($d2.connections | Where-Object { $_ -and $_.from -and $_.to })
Say ("  " + $connections.Count + " connection(s).") Green

$TurnSystem = @'
Read the RULES and the PROJECT BRIEF. Describe a single player's turn as a linear sequence of steps. One action per step, imperative voice, plain words. Do not include anything that is not a turn step.

Return JSON only, in this shape:
{ "turn_flow": [ { "step": "short imperative", "detail": "one short sentence" } ] }

Rules:
- One linear sequence. Branches go in the detail, not as separate steps.
- If the rules do not describe a turn, return an empty list.
- Do not invent steps.
'@

Say "Step 3 of 5: turn flow..." Yellow
$d3 = $null
try {
    $d3 = Ask-Model $Builder $TurnSystem ("PROJECT BRIEF:`n" + $briefText + "`n`nRULES:`n" + $rulesText)
} catch {
    Say ("  failed: " + $_.Exception.Message) Red
    return
}
$turnFlow = @($d3.turn_flow | Where-Object { $_ -and $_.step })
Say ("  " + $turnFlow.Count + " step(s).") Green

$GapsSystem = @'
You are checking a game's rules against the current idea notes. List things the rules imply that the notes do not specify, or contradictions between a note and the rules. Each gap must name the specific component or rule where the information is missing.

Return JSON only, in this shape:
{ "gaps": [ "one short sentence naming the specific component or rule" ] }

Rules:
- Only real gaps. Not things that are simply not mentioned because they are outside the rules.
- Each gap names the specific thing. No "the mechanics", no "the rules" in general.
- If there are no gaps, return an empty list.
'@

Say "Step 4 of 5: gaps..." Yellow
$d4 = $null
try {
    $d4 = Ask-Model $Builder $GapsSystem ("PROJECT BRIEF:`n" + $briefText + "`n`nRULES:`n" + $rulesText + "`n`nRELEVANT IDEA NOTES (name, category, summary):`n" + $ideaSummary)
} catch {
    Say ("  failed: " + $_.Exception.Message) Red
    return
}
$gaps = @($d4.gaps | Where-Object { $_ })
Say ("  " + $gaps.Count + " gap(s).") Green

function Sanitize([string]$s) {
    if (-not $s) { return "" }
    return ($s -replace '"', "'" -replace "`r?`n", " ").Trim()
}
function NodeId([string]$s, [hashtable]$seen) {
    $base = ($s -replace '[^A-Za-z0-9]', '_')
    if (-not $base) { $base = "n" }
    if (-not $seen.ContainsKey($base)) { $seen[$base] = 1; return $base }
    $seen[$base]++
    return ($base + "_" + $seen[$base])
}

$L = New-Object System.Collections.Generic.List[string]
$L.Add("---")
$L.Add("type: gameplay-diagram")
$L.Add("created: " + $Today)
$L.Add("---")
$L.Add("")
$L.Add("# Gameplay Diagram")
$L.Add("")
$L.Add("> [!info] What this is")
$L.Add("> Built from octo-config\rules.md and the idea notes that belong to this game.")
$L.Add("> The rules are treated as authoritative. Contradictions appear under Gaps.")
$L.Add("> Re-run Make-Gameplay-Diagram.bat after editing the rules or the notes.")
$L.Add("")
$L.Add("> [!note] Idea notes used")
$L.Add("> " + $kept.Count + " of " + $allIdeaFiles.Count + " idea notes matched this game.")
$L.Add("")

$L.Add("## Components")
$L.Add("")
$grouped = @{}
foreach ($c in $components) {
    $t = [string]$c.type
    if (-not $t) { $t = "other" }
    if (-not $grouped.ContainsKey($t)) { $grouped[$t] = New-Object System.Collections.Generic.List[object] }
    $grouped[$t].Add($c)
}
foreach ($t in ($grouped.Keys | Sort-Object)) {
    $L.Add("### " + (Get-Culture).TextInfo.ToTitleCase($t))
    $L.Add("")
    foreach ($c in $grouped[$t]) {
        $L.Add("- **" + $c.name + "** - " + (Sanitize $c.purpose))
    }
    $L.Add("")
}

$L.Add("## Component Diagram")
$L.Add("")
$L.Add($Fence + "mermaid")
$L.Add("flowchart LR")
$seen = @{}
$idFor = @{}
foreach ($t in ($grouped.Keys | Sort-Object)) {
    $L.Add("    subgraph g_" + ($t -replace '[^A-Za-z0-9]', '_') + "[" + (Get-Culture).TextInfo.ToTitleCase($t) + "]")
    foreach ($c in $grouped[$t]) {
        $id = NodeId ([string]$c.name) $seen
        $idFor[[string]$c.name] = $id
        $L.Add("        " + $id + '["' + (Sanitize $c.name) + '"]')
    }
    $L.Add("    end")
}
foreach ($conn in $connections) {
    $fid = $idFor[[string]$conn.from]
    $tid = $idFor[[string]$conn.to]
    if (-not $fid) { $fid = NodeId ([string]$conn.from) $seen; $idFor[[string]$conn.from] = $fid }
    if (-not $tid) { $tid = NodeId ([string]$conn.to)   $seen; $idFor[[string]$conn.to]   = $tid }
    $lbl = Sanitize $conn.label
    if ($lbl) { $L.Add("    " + $fid + " -->|" + $lbl + "| " + $tid) }
    else       { $L.Add("    " + $fid + " --> " + $tid) }
}
$L.Add($Fence)
$L.Add("")

$L.Add("## Connections")
$L.Add("")
$L.Add("| From | To | What happens | Basis |")
$L.Add("|------|----|--------------|-------|")
foreach ($conn in $connections) {
    $L.Add("| " + (Sanitize $conn.from) + " | " + (Sanitize $conn.to) + " | " + (Sanitize $conn.label) + " | " + (Sanitize $conn.basis) + " |")
}
$L.Add("")

$L.Add("## Turn Flow")
$L.Add("")
$L.Add($Fence + "mermaid")
$L.Add("flowchart TD")
$tfId = @{}
$i = 0
foreach ($s in $turnFlow) {
    $i++
    $id = "t" + $i
    $tfId[$i] = $id
    $L.Add("    " + $id + '["' + $i + ". " + (Sanitize $s.step) + '"]')
}
for ($k = 1; $k -lt $i; $k++) {
    $L.Add("    " + $tfId[$k] + " --> " + $tfId[$k + 1])
}
$L.Add($Fence)
$L.Add("")
$L.Add("### Turn steps")
$L.Add("")
$j = 0
foreach ($s in $turnFlow) {
    $j++
    $L.Add(($j.ToString() + ". **" + $s.step + "** - " + (Sanitize $s.detail)))
}
$L.Add("")

$L.Add("## Gaps")
$L.Add("")
if ($gaps.Count -eq 0) {
    $L.Add("> [!success] No gaps found")
    $L.Add("> The rules and the idea notes did not surface any contradictions or missing details.")
} else {
    $L.Add("> [!warning] Things to fill in")
    foreach ($g in $gaps) { $L.Add("> - " + (Sanitize $g)) }
}
$L.Add("")

$L.Add("## Skipped idea notes")
$L.Add("")
$L.Add("> [!note] These did not match this game and were not used.")
$L.Add("> If any of them should be used, add its category or source note name to the relevance filter and re-run.")
$L.Add("")
if ($skipped.Count -eq 0) {
    $L.Add("- (none)")
} else {
    foreach ($s in $skipped) {
        $L.Add("- [[" + $s.File.BaseName + "]] [" + $s.Category + "] from [[" + $s.Source + "]]")
    }
}
$L.Add("")

Say ""
Say ("Writing: " + $OutFile) Cyan
Write-Note $OutFile ($L -join "`n")
Say ("Wrote: " + $OutFile) Green
Say ("  components: " + $components.Count + "  connections: " + $connections.Count + "  turn steps: " + $turnFlow.Count + "  gaps: " + $gaps.Count) DarkGray
Say ("  idea notes used: " + $kept.Count + " of " + $allIdeaFiles.Count) DarkGray

if ($Open) {
    try {
        $vaultName = [uri]::EscapeDataString((Split-Path $Vault -Leaf))
        $fileRef   = [uri]::EscapeDataString("02-Generate-Ideas/_Gameplay-Diagram")
        Start-Process ("obsidian://open?vault=" + $vaultName + "&file=" + $fileRef)
    } catch { }
}