# squash-idea.ps1
# Called by Squash-New-Idea.bat. You do not run this file directly.
#
# What is new in this version:
#   * Long notes are split into chunks first, so the model cannot choke.
#   * Every chunk keeps the note's title, so ideas do not lose their meaning.
#   * A second pass links ideas ACROSS chunks and removes duplicates.
#   * Off-topic thoughts are "parked" in their own file instead of being
#     mixed into the idea notes. Nothing is deleted.
#
# Everything else works the same as before.

$ErrorActionPreference = "Stop"
$Vault     = Split-Path $PSScriptRoot -Parent
$Inbox     = Join-Path $Vault "00-Drop-Notes-Here"
$DayDir    = Join-Path $Vault "01-Organize-The-Day"
$IdeaDir   = Join-Path $Vault "02-Generate-Ideas"
$OrderDir  = Join-Path $Vault "03-Tidy-Up-Ideas"
$OutDir    = Join-Path $Vault "04-Ready-AI-Instructions"
$TaskDir   = Join-Path $Vault "05-Build-Tasks"
$StateFile = Join-Path $PSScriptRoot "processed.txt"
$Ollama    = "http://127.0.0.1:11434"
$Builder   = "qwen2.5:14b"
$Reviewer  = "gemma2:9b"
$Fence     = [string]::new([char]96, 3)
$Utf8      = New-Object System.Text.UTF8Encoding($false)
$Today     = Get-Date -Format "yyyy-MM-dd"
$MaxQuestions = 10
$ChunkSoftLimit = 3500
$ChunkMinSize   = 400

foreach ($d in @($Inbox, $DayDir, $IdeaDir, $OrderDir, $OutDir, $TaskDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
if (-not (Test-Path $StateFile)) { [IO.File]::WriteAllText($StateFile, "", $Utf8) }

# ---------------- instructions for the models ----------------

$ExtractSystem = @'
You help a VR game developer who has dyslexia and a drifting mind. They
write notes fast and their thoughts wander. Your job is to split the
chunk they give you into the right buckets WITHOUT judgement. Never scold
them for going off-topic. Just sort.

Return JSON only, in this shape:
{
  "daily_tasks":  ["..."],
  "ideas":        [ { "name": "...", "category": "...", "summary": "...",
                      "details": ["..."], "feeling": "...",
                      "links": [{"to": "...", "how": "..."}] } ],
  "tangents":     [ { "text": "...", "kind": "personal | unrelated | later | question" } ]
}

Rules for daily_tasks:
- Only real errands/chores for today. Not game work. Empty list if none.

Rules for ideas:
- One entry per separate THING IN THE GAME: an item to model, a character,
  a mechanic, a game rule, a UI piece, a script that will be needed.
- Split big ideas into their parts.
- If a sentence is about the game, it belongs here even if it feels
  half-formed. Half-formed game ideas are still game ideas.
- Categories: "3D model", "Character", "Character mechanic", "Game logic",
  "UI", "Visual design", "Script needed", "Audio", "Other".
- "to" in links must be the exact name of another idea in your list,
  or a name from EXISTING IDEA NOTES.
- Use only what is in the chunk. Do not invent features. Do not write code.

Rules for tangents (be strict):
- Anything NOT about this VR game goes here, not into ideas.
- Personal life ("call mum", "buy milk") -> kind "personal".
- A different project or game entirely -> kind "unrelated".
- A game idea clearly for later ("maybe sequel could...") -> kind "later".
- A question the writer is asking themselves -> kind "question".
- Keep the tangent text close to their own words. Short.
- If you are unsure, put it in ideas AND add a "question" tangent about it.
  Never silently drop a line.

You may be given only ONE CHUNK of a longer note. The chunk starts with
"NOTE TITLE: ..." which tells you what the whole note is about. Use the
title to judge whether a sentence belongs to this game. Only report what
is in this chunk. Another pass will merge ideas across chunks, so do not
worry about duplicating something you saw before - just be precise about
what THIS chunk says.
'@

$ReconcileSystem = @'
You clean up a first-pass extraction from a long note that was processed
in chunks. You did NOT see the whole note - only the summaries and
tangents below. Your job is reconciliation, not invention.

Return JSON only, in this shape:
{
  "ideas": [
    { "name": "...", "category": "...", "summary": "...", "details": ["..."],
      "feeling": "...", "links": [{"to": "...", "how": "..."}],
      "merged_from_indices": [1, 4, 7] }
  ],
  "tangents": [ { "text": "...", "kind": "personal | unrelated | later | question" } ]
}

Rules:
- If two entries describe the SAME idea, merge them into one. Combine
  details. Keep the clearest name.
- Put the original indices into merged_from_indices so the writer can audit.
- If an entry is truly a tangent misclassified as an idea, remove it from
  ideas and re-add it under tangents.
- Add cross-idea links that only became visible now that all chunks are
  together. "to" must be an idea name from the merged list.
- Do not invent ideas that were not in the first-pass list.
- Keep tangents exactly as they were unless you are moving an idea into
  them. Do not rewrite tangent text.
'@

$TaskSystem = @'
You help a VR game developer who has dyslexia and struggles with priorities and yak-shaving.
Take the idea notes and turn each into a real build task list, in dependency order.

Return JSON only, in this shape:
{"tasks": [{"idea": "Idea Name", "steps": [{"step": "short action", "kind": "model | animation | script | system | art | design | test", "depends_on": "what must exist first, or 'nothing'"}]}]}

Rules:
- One entry per idea. One action per step. Short plain words.
- Model before animation. Core script before systems that use it.
- Only include steps that are really needed. If unclear, add "Decide: <the thing>".
- Do not write code.
'@

$OrderSystem = @'
You help a VR game developer who has dyslexia. YOU put their ideas into a linear work order. Never ask them to order, rank or prioritise anything.

Return JSON only, in this shape:
{"order": [{"step": "short action", "why": "short reason"}], "questions": ["..."]}

Rules for order: one linear list covering every idea note. Dependencies first.
Rules for questions: only what you still need to know. Most important first. At most 10. One thing per question. Short plain words. Say what you assumed. Never ask what "done" looks like. Never ask them to order or prioritise. Empty list if nothing is unclear.
'@

$PromptSystem = @'
You write AI prompts that a VR game developer will paste into another AI tool later. Do not write code yourself.

Return JSON only, in this shape:
{"title": "short title", "prompts": [{"label": "...", "text": "..."}]}

Rules: first prompt label is "Full prompt" and covers everything in work order. Compact, no filler words. Per-kind prompts only if kinds are clearly separate. Use only facts from notes and answers. Unknown -> [TBD: what is unknown].
'@

$ReviewSystem = @'
You check an AI prompt that a different AI wrote from a developer's notes. You did not write it. Try to break it.
Look only for: (1) steps assuming something the notes never say, (2) linearity losing a connection, (3) ambiguity, (4) invented facts.
Each finding is one short plain sentence. Do not rewrite. If nothing, return empty list.
Return JSON only: {"findings": ["..."]}
'@

# ---------------- helpers ----------------

function Say([string]$t, [string]$c = "Gray") { Write-Host $t -ForegroundColor $c }
function Write-Note([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $Utf8) }
function Add-Note([string]$path, [string]$text) { [IO.File]::AppendAllText($path, $text, $Utf8) }
function Read-Note([string]$path) { return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
function Safe([string]$n) {
    $s = ($n -replace '[\\/:*?"<>|#^\[\]]', '-').Trim()
    if (-not $s) { $s = "Idea" }
    return $s
}
function Clean([string]$s) {
    $c = ($s -replace '["\[\]\(\)\{\}<>|#;]', ' ').Trim()
    if ($c.Length -gt 40) { $c = $c.Substring(0, 40) }
    return $c
}
function Key($f) { return $f.Name + "|" + (Get-FileHash -Path $f.FullName).Hash }

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
function Ask-Model([string]$model, [string]$system, [string]$prompt) {
    $body = @{
        model   = $model
        system  = $system
        prompt  = $prompt
        format  = "json"
        stream  = $false
        options = @{ temperature = 0.2; num_ctx = 16384 }
    } | ConvertTo-Json -Depth 6
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    for ($try = 1; $try -le 2; $try++) {
        try {
            $r   = Invoke-WebRequest -Uri "$Ollama/api/generate" -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -UseBasicParsing -TimeoutSec 900
            $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
            return (($txt | ConvertFrom-Json).response | ConvertFrom-Json)
        } catch {
            if ($try -eq 2) { throw }
            Say "      (reply was not usable, trying once more)" DarkYellow
        }
    }
}

function Split-NoteIntoChunks {
    param(
        [string]$Text,
        [string]$Title = "",
        [int]$SoftLimit = 3500,
        [int]$MinChunk  = 400
    )
    if (-not $Text) { return @() }

    $header = ""
    if ($Title) { $header += "NOTE TITLE: " + $Title + "`n" }
    $firstHeading = [regex]::Match($Text, '(?m)^#\s+(.+)$')
    if ($firstHeading.Success -and ($firstHeading.Groups[1].Value.Trim() -ne $Title)) {
        $header += "NOTE'S OWN HEADING: " + $firstHeading.Groups[1].Value.Trim() + "`n"
    }
    if ($header) { $header += "`n---`n`n" }

    if (($header.Length + $Text.Length) -le $SoftLimit) {
        return @($header + $Text)
    }

    $pieces = [System.Collections.Generic.List[string]]::new()
    $current = ""
    foreach ($line in ($Text -split "(?m)(`r?`n)")) {
        $current += $line
        if ($line -eq "" -and $current.Length -ge $MinChunk) {
            $pieces.Add($current); $current = ""
        }
        elseif ($line -match '^#{1,6}\s' -and $current.Length -ge $MinChunk) {
            $pieces.Add($current); $current = ""
        }
        elseif ($current.Length -gt ($SoftLimit * 1.2)) {
            $pieces.Add($current); $current = ""
        }
    }
    if ($current.Trim()) { $pieces.Add($current) }

    $budget = $SoftLimit - $header.Length
    if ($budget -lt 800) { $budget = 800 }

    $chunks = [System.Collections.Generic.List[string]]::new()
    $buf = ""
    foreach ($p in $pieces) {
        if (($buf.Length + $p.Length) -gt $budget -and $buf.Length -gt 0) {
            $chunks.Add($header + $buf); $buf = ""
        }
        $buf += $p
    }
    if ($buf.Trim()) { $chunks.Add($header + $buf) }
    if ($chunks.Count -eq 0) { $chunks.Add($header + $Text) }
    return $chunks
}

function Update-Map {
    $files = @(Get-ChildItem -Path $IdeaDir -Filter *.md | Where-Object { $_.Name -notlike "_*" } | Sort-Object BaseName)
    $id = @{}
    $k = 0
    foreach ($f in $files) { $k++; $id[$f.BaseName] = "n$k" }

    $groups = @{}
    $edges  = New-Object System.Collections.Generic.List[string]
    $wiki   = New-Object System.Collections.Generic.List[string]

    foreach ($f in $files) {
        $t = Read-Note $f.FullName
        $cat = "Other"
        $m = [regex]::Match($t, '(?m)^Category:\s*(.+)$')
        if ($m.Success) { $cat = $m.Groups[1].Value.Trim() }
        if (-not $groups.ContainsKey($cat)) { $groups[$cat] = New-Object System.Collections.Generic.List[string] }
        $groups[$cat].Add($f.BaseName)

        $out = New-Object System.Collections.Generic.List[string]
        foreach ($e in [regex]::Matches($t, '(?m)^\s*- \[\[([^\]]+)\]\] - (.*)$')) {
            $to = $e.Groups[1].Value.Trim()
            if ($id.ContainsKey($to)) {
                $label = Clean $e.Groups[2].Value
                if ($label) { $edges.Add("    " + $id[$f.BaseName] + " -->|" + $label + "| " + $id[$to]) }
                else        { $edges.Add("    " + $id[$f.BaseName] + " --> " + $id[$to]) }
                $out.Add("[[$to]]")
            }
        }

        if ($out.Count -gt 0) {
            $wiki.Add("- [[" + $f.BaseName + "]] -> " + (($out | Select-Object -Unique) -join ", "))
        } else {
            $wiki.Add("- [[" + $f.BaseName + "]] -> (no links yet)")
        }
    }

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("# All Ideas Map")
    $L.Add("")
    $L.Add("> [!info] Auto-rebuilt")
    $L.Add("> This map is rebuilt every time you run Squash-New-Idea.bat.")
    $L.Add("")

    foreach ($c in ($groups.Keys | Sort-Object)) {
        $L.Add("## $c")
        foreach ($n in $groups[$c]) { $L.Add("- [[$n]]") }
        $L.Add("")
    }

    $L.Add("## Diagram")
    $L.Add("")
    $L.Add($Fence + "mermaid")
    $L.Add("flowchart LR")
    foreach ($f in $files) {
        $nid   = $id[$f.BaseName]
        $label = Clean $f.BaseName
        $L.Add("    " + $nid + '["' + $label + '"]')
    }
    foreach ($e in $edges) { $L.Add($e) }
    foreach ($f in $files) {
        $nid    = $id[$f.BaseName]
        $target = $f.BaseName
        $L.Add("    click " + $nid + ' "' + $target + '" "Open ' + $target + '"')
    }
    $L.Add($Fence)
    $L.Add("")

    $L.Add("## Links (for graph view)")
    $L.Add("")
    foreach ($w in $wiki) { $L.Add($w) }
    $L.Add("")

    Write-Note (Join-Path $IdeaDir "_All-Ideas-Map.md") ($L -join "`n")
}

# ---------------- the pipeline for one note ----------------

function Process-Note($file) {
    $src  = $file.BaseName
    $name = Safe $src
    $key  = Key $file
    $dump = Read-Note $file.FullName

    Say ""
    Say "=== Working on: $($file.Name) ===" Cyan
    Say "Reading your note and splitting it up (about a minute)..." Yellow

    $existing = @(Get-ChildItem -Path $IdeaDir -Filter *.md | Where-Object { $_.Name -notlike "_*" } | ForEach-Object { $_.BaseName })
    $existingText = "None yet."
    if ($existing.Count -gt 0) { $existingText = $existing -join ", " }

    # PASS 1 - chunk by chunk
    $chunks = Split-NoteIntoChunks -Text $dump -Title $src -SoftLimit $ChunkSoftLimit -MinChunk $ChunkMinSize
    Say ("      Note is " + $dump.Length + " chars, split into " + $chunks.Count + " chunk(s).") DarkGray

    $pass1Ideas    = [System.Collections.Generic.List[object]]::new()
    $pass1Tangents = [System.Collections.Generic.List[object]]::new()
    $mergedTasks   = [System.Collections.Generic.List[string]]::new()

    $ci = 0
    foreach ($chunk in $chunks) {
        $ci++
        Say ("      Pass 1 - chunk " + $ci + " of " + $chunks.Count + "...") Yellow

        $known = @($existing) + @($pass1Ideas | ForEach-Object { Safe ([string]$_.name) })
        $known = @($known | Where-Object { $_ } | Select-Object -Unique)
        $knownText = "None yet."
        if ($known.Count -gt 0) { $knownText = $known -join ", " }

        $partPrompt  = "EXISTING IDEA NOTES: " + $knownText + "`n`n"
        $partPrompt += "CHUNK " + $ci + " OF " + $chunks.Count + " OF THIS NOTE:`n`n"
        $partPrompt += $chunk
        $partPrompt += "`n`n"
        $partPrompt += "IMPORTANT: Only report what is in THIS chunk. If a line refers to something you cannot see, put it in tangents with kind 'question'. Do not try to summarise other chunks."

        try {
            $p = Ask-Model $Builder $ExtractSystem $partPrompt
        } catch {
            Say ("      ! chunk " + $ci + " failed, skipping: " + $_.Exception.Message) DarkYellow
            continue
        }
        if (-not $p) { continue }

        foreach ($t in @($p.daily_tasks | Where-Object { $_ }))              { $mergedTasks.Add([string]$t) }
        foreach ($i in @($p.ideas       | Where-Object { $_ -and $_.name })) { $pass1Ideas.Add($i) }
        foreach ($g in @($p.tangents    | Where-Object { $_ -and $_.text })) { $pass1Tangents.Add($g) }
    }

    # PASS 2 - reconcile across chunks
    Say ("      Pass 2 - reconciling " + $pass1Ideas.Count + " idea(s) across all chunks...") Yellow

    $reconInput = New-Object System.Text.StringBuilder
    [void]$reconInput.AppendLine("ORIGINAL NOTE TITLE: " + $src)
    [void]$reconInput.AppendLine("")
    [void]$reconInput.AppendLine("IDEAS FOUND IN EACH CHUNK:")
    $idx = 0
    foreach ($i in $pass1Ideas) {
        $idx++
        [void]$reconInput.AppendLine("[" + $idx + "] name=" + $i.name + " | category=" + $i.category + " | summary=" + $i.summary)
    }
    [void]$reconInput.AppendLine("")
    [void]$reconInput.AppendLine("PARKED TANGENTS:")
    $idx = 0
    foreach ($t in $pass1Tangents) {
        $idx++
        [void]$reconInput.AppendLine("[" + $idx + "] kind=" + $t.kind + " | text=" + $t.text)
    }

    $finalIdeas    = @($pass1Ideas)
    $finalTangents = @($pass1Tangents)
    try {
        $recon = Ask-Model $Builder $ReconcileSystem ($reconInput.ToString())
        if ($recon -and @($recon.ideas).Count -gt 0) {
            $finalIdeas = @($recon.ideas)
            Say ("      Reconciler merged down to " + $finalIdeas.Count + " idea(s).") Green
        } else {
            Say "      Reconciler returned nothing, using pass-1 results as-is." DarkYellow
        }
        if ($recon -and @($recon.tangents).Count -gt 0) {
            $finalTangents = @($recon.tangents)
        }
    } catch {
        Say ("      Reconciler failed, using pass-1 results as-is: " + $_.Exception.Message) DarkYellow
    }

    $x = [pscustomobject]@{
        daily_tasks = @($mergedTasks | Select-Object -Unique)
        ideas       = $finalIdeas
        tangents    = $finalTangents
    }

    # Step 1 - daily tasks
    Say ""
    Say "[1/4] Organize the day" Yellow
    $tasks = @($x.daily_tasks | Where-Object { $_ })
    if ($tasks.Count -gt 0) {
        $dayFile = Join-Path $DayDir "$Today-Daily-Plan.md"
        if (-not (Test-Path $dayFile)) {
            Write-Note $dayFile ("# Daily Plan - " + $Today + "`n`n> [!tip] Tick tasks as you finish them.`n")
        }
        $block = "`n## From [[" + $src + "]]`n" + (($tasks | ForEach-Object { "- [ ] $_" }) -join "`n") + "`n"
        Add-Note $dayFile $block
        foreach ($t in $tasks) { Say "      - $t" Green }
    } else {
        Say "      No daily tasks in this note."
    }

    # Step 2 - write idea notes
    Say ""
    Say "[2/4] Generate ideas (one note per idea)" Yellow
    $made = New-Object System.Collections.Generic.List[string]
    foreach ($i in @($x.ideas | Where-Object { $_ -and $_.name })) {
        $n = Safe ([string]$i.name)
        $p = Join-Path $IdeaDir "$n.md"
        $det = (@($i.details | Where-Object { $_ }) | ForEach-Object { "- $_" }) -join "`n"
        $lnk = (@($i.links | Where-Object { $_ -and $_.to }) | ForEach-Object { "- [[" + (Safe ([string]$_.to)) + "]] - " + $_.how }) -join "`n"
        if (Test-Path $p) {
            $t = "`n`n## Added from [[" + $src + "]] (" + $Today + ")`n" + $i.summary + "`n"
            if ($det) { $t += $det + "`n" }
            if ($lnk) { $t += "`n### Connections`n" + $lnk + "`n" }
            Add-Note $p $t
            Say "      $n  (updated)" Green
        } else {
            $t  = "---`n"
            $t += "type: vr-game-idea`n"
            $t += "category: `"$($i.category)`"`n"
            $t += "created: " + $Today + "`n"
            $t += "---`n`n"
            $t += "# " + $i.name + "`n`n"
            $t += "> [!abstract] Category`n> " + $i.category + "`n`n"
            $t += "> [!info] Source`n> From: [[" + $src + "]]`n`n"
            $t += "## What it is`n" + $i.summary + "`n"
            if ($det) { $t += "`n## Details`n" + $det + "`n" }
            if ($i.feeling) { $t += "`n> [!quote] How it should look or feel`n> " + (($i.feeling -split "`n") -join "`n> ") + "`n" }
            $t += "`n## Connections`n"
            if ($lnk) { $t += $lnk + "`n" } else { $t += "- (none yet)`n" }
            Write-Note $p $t
            Say "      $n  ($($i.category))" Green
        }
        if (-not $made.Contains($n)) { $made.Add($n) }
    }
    if ($made.Count -eq 0) { throw "No ideas were found in the note." }

    # Step 2b - park the tangents
    $tangents = @($x.tangents | Where-Object { $_ -and $_.text })
    if ($tangents.Count -gt 0) {
        $parkFile = Join-Path $IdeaDir ("_Parked-from-" + $src + ".md")
        $PL = New-Object System.Collections.Generic.List[string]
        $PL.Add("# Parked thoughts from [[" + $src + "]]")
        $PL.Add("")
        $PL.Add("> [!info] What this is")
        $PL.Add("> These came out of the same note but are not ideas for this game.")
        $PL.Add("> Nothing here is deleted. When a tangent turns out to matter,")
        $PL.Add("> copy it into a new note in 00-Drop-Notes-Here and run Squash-New-Idea again.")
        $PL.Add("")
        $PL.Add("> [!quote] Source")
        $PL.Add("> From: [[" + $src + "]]  ")
        $PL.Add("> Date: " + $Today)
        $PL.Add("")
        $groups = $tangents | Group-Object -Property kind
        foreach ($g in $groups) {
            $label = switch ($g.Name) {
                "personal"  { "Personal / life" }
                "unrelated" { "Other projects / other games" }
                "later"     { "Later / maybe-sequel" }
                "question"  { "Questions to yourself" }
                default     { "Other" }
            }
            $PL.Add("## $label")
            $PL.Add("")
            foreach ($t in $g.Group) { $PL.Add("- " + $t.text) }
            $PL.Add("")
        }
        Write-Note $parkFile ($PL -join "`n")
        Say ("      Parked " + $tangents.Count + " non-idea thought(s): _Parked-from-" + $src + ".md") Green
    } else {
        Say "      Nothing to park (no off-topic thoughts in this note)." DarkGray
    }

    Update-Map
    Say "      Map updated: 02-Generate-Ideas\_All-Ideas-Map.md" Green

    $ideaText = ($made | ForEach-Object { "=== " + $_ + " ===`n" + (Read-Note (Join-Path $IdeaDir "$_.md")) }) -join "`n`n"

    # Step 2c - build tasks
    Say ""
    Say "[2b] Build tasks (what to do first for each idea)" Yellow
    $tk = Ask-Model $Builder $TaskSystem ("IDEA NOTES:`n" + $ideaText)
    $taskLines = New-Object System.Collections.Generic.List[string]
    $taskLines.Add("# Build Tasks - " + $src)
    $taskLines.Add("")
    $taskLines.Add("> [!tip] Work top to bottom. Each step says what must exist first.")
    $taskLines.Add("")
    $taskLines.Add("> [!info] Links")
    $taskLines.Add("> Source: [[" + $src + "]]  ")
    $taskLines.Add("> Order: [[" + $name + "-Work-Order]]")
    $taskLines.Add("")
    foreach ($g in @($tk.tasks)) {
        if (-not $g -or -not $g.idea) { continue }
        $taskLines.Add("## " + $g.idea)
        $taskLines.Add("")
        $n = 0
        foreach ($s in @($g.steps)) {
            $n++
            $dep = ""
            if ($s.depends_on -and $s.depends_on -ne "nothing") { $dep = " _(after: " + $s.depends_on + ")_" }
            $taskLines.Add("- [ ] **" + $n + ".** " + $s.step + " `[" + $s.kind + "`]" + $dep)
        }
        $taskLines.Add("")
    }
    $taskFile = Join-Path $TaskDir "$name-Build-Tasks.md"
    Write-Note $taskFile ($taskLines -join "`n")
    Say "      Build task list: 05-Build-Tasks\$name-Build-Tasks.md" Green
    foreach ($tl in $taskLines) { if ($tl -like "- [ ]*") { Say ("      " + $tl) Green } }

    # Step 3 - order + questions
    Say ""
    Say "[3/4] Tidy up ideas (putting them in order)" Yellow
    $base = "BRAIN DUMP:`n" + $dump + "`n`nIDEA NOTES:`n" + $ideaText
    $o = Ask-Model $Builder $OrderSystem ($base + "`n`nANSWERS SO FAR: none")
    $answers = New-Object System.Collections.Generic.List[object]
    $qs = @($o.questions | Where-Object { $_ } | Select-Object -First $MaxQuestions)
    if ($qs.Count -gt 0) {
        Say ""
        Say ("Up to " + $qs.Count + " quick questions so the prompt comes out right.") Cyan
        Say "Type an answer and press Enter. Or press Enter to skip. Type 'stop' to stop asking." Cyan
        $qn = 0
        foreach ($q in $qs) {
            $qn++
            Say ""
            Say ("Question " + $qn + " of " + $qs.Count + ": " + $q) White
            $a = Read-Host "Your answer"
            if ($a -and $a.Trim().ToLower() -eq "stop") { Say "      Stopping questions." DarkYellow; break }
            if ($a -and $a.Trim()) { $answers.Add([pscustomobject]@{ q = [string]$q; a = $a.Trim() }) }
        }
    }
    $ansText = "none"
    if ($answers.Count -gt 0) {
        $ansText = ($answers | ForEach-Object { "Q: " + $_.q + "`nA: " + $_.a }) -join "`n`n"
        Say ""
        Say "Updating the order with your answers..." Yellow
        $o2 = Ask-Model $Builder $OrderSystem ($base + "`n`nANSWERS SO FAR:`n" + $ansText + "`n`nDo not ask more questions. Return an empty questions list.")
        if (@($o2.order).Count -gt 0) { $o = $o2 }
    }
    $orderLines = New-Object System.Collections.Generic.List[string]
    $k = 0
    foreach ($s in @($o.order)) {
        $k++
        if ($s -is [string]) { $orderLines.Add("$k. $s") } else { $orderLines.Add("$k. **" + $s.step + "** - " + $s.why) }
    }
    $t  = "# Work Order - " + $src + "`n`n"
    $t += "> [!info] Links`n> From: [[" + $src + "]]  `n> Ideas: " + (($made | ForEach-Object { "[[$_]]" }) -join ", ") + "`n`n"
    $t += "## Order`n" + ($orderLines -join "`n") + "`n"
    if ($answers.Count -gt 0) {
        $t += "`n## Your answers`n" + (($answers | ForEach-Object { "- **Q:** " + $_.q + "`n  **A:** " + $_.a }) -join "`n") + "`n"
    }
    Write-Note (Join-Path $OrderDir "$name-Work-Order.md") $t
    Say ""
    foreach ($ol in $orderLines) { Say ("      " + ($ol -replace '\*\*', '')) Green }

    # Step 4 - prompt + reviewer
    Say ""
    Say "[4/4] Ready AI instructions" Yellow
    $pr = Ask-Model $Builder $PromptSystem ("WORK ORDER:`n" + ($orderLines -join "`n") + "`n`nIDEA NOTES:`n" + $ideaText + "`n`nANSWERS:`n" + $ansText)
    $prompts = @($pr.prompts | Where-Object { $_ -and $_.text })
    if ($prompts.Count -eq 0) { throw "The prompt came back empty." }
    $title = $src
    if ($pr.title) { $title = [string]$pr.title }

    Say "      Second AI ($Reviewer) is checking the prompt..." Yellow
    $finds = @()
    try {
        $rv = Ask-Model $Reviewer $ReviewSystem ("NOTES:`n" + $dump + "`n`n" + $ideaText + "`n`nANSWERS:`n" + $ansText + "`n`nPROMPT:`n" + [string]$prompts[0].text)
        $finds = @($rv.findings | Where-Object { $_ })
        if ($finds.Count -eq 0) { $finds = @("No problems found.") }
    } catch {
        $finds = @("Second AI not available - check skipped.")
    }

    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("# Ready AI Instructions - $title")
    $L.Add("")
    $L.Add("> [!info] Links")
    $L.Add("> From: [[" + $src + "]]  ")
    $L.Add("> Order: [[" + $name + "-Work-Order]]  ")
    $L.Add("> Build tasks: [[" + $name + "-Build-Tasks]]  ")
    $L.Add("> Map: [[_All-Ideas-Map]]")
    $L.Add("")
    $L.Add("> [!tip] Copy a box below into your AI tool.")
    foreach ($p in $prompts) {
        $L.Add("")
        $L.Add("## " + $p.label)
        $L.Add("")
        $L.Add($Fence + "text")
        $L.Add([string]$p.text)
        $L.Add($Fence)
    }
    $L.Add("")
    $L.Add("## Second AI check (" + $Reviewer + ")")
    $L.Add("")
    if ($finds.Count -eq 1 -and $finds[0] -eq "No problems found.") {
        $L.Add("> [!success] No problems found")
        $L.Add("> The second AI read the prompt and found nothing to fix.")
    } elseif ($finds.Count -eq 1 -and $finds[0] -like "Second AI not available*") {
        $L.Add("> [!warning] Check skipped")
        $L.Add("> " + $finds[0])
    } else {
        $L.Add("> [!warning] The second AI found things to fix")
        foreach ($f in $finds) { $L.Add("> - " + $f) }
        $L.Add("")
        $L.Add("Fix these in the box above before copying, or add a line to your note and re-run.")
    }
    $outFile = Join-Path $OutDir "$name-AI-Prompt.md"
    Write-Note $outFile ($L -join "`n")
    foreach ($f in $finds) { Say "      - $f" Green }

    Add-Note $StateFile ($key + "`n")
    Say ""
    Say "DONE. Your prompt is in: 04-Ready-AI-Instructions\$name-AI-Prompt.md" Cyan
    try {
        $vaultName = [uri]::EscapeDataString((Split-Path $Vault -Leaf))
        $fileRef   = [uri]::EscapeDataString("04-Ready-AI-Instructions/$name-AI-Prompt")
        Start-Process ("obsidian://open?vault=" + $vaultName + "&file=" + $fileRef)
    } catch { }
}

# ---------------- main ----------------

Say "Squash New Idea" Cyan
Say "Notes are read from: $Inbox"
Ensure-Ollama

$done = @{}
foreach ($line in (Get-Content -Path $StateFile)) { if ($line) { $done[$line] = $true } }
$all  = @(Get-ChildItem -Path $Inbox -Filter *.md | Where-Object { $_.Length -gt 0 } | Sort-Object LastWriteTime -Descending)
$todo = @($all | Where-Object { -not $done.ContainsKey((Key $_)) })

if ($todo.Count -eq 0) {
    Say ""
    Say "No new or changed notes in 00-Drop-Notes-Here." White
    if ($all.Count -eq 0) { return }
    Say "Run one again? Type its number, or press Enter to close." White
    $i = 0
    foreach ($f in $all) { $i++; Say ("  " + $i + ". " + $f.Name) }
    $pick = Read-Host "Number"
    $num = 0
    if ([int]::TryParse($pick, [ref]$num) -and $num -ge 1 -and $num -le $all.Count) { $todo = @($all[$num - 1]) } else { return }
}

$first = $true
foreach ($f in $todo) {
    if (-not $first) {
        $yn = Read-Host ("Also do '" + $f.Name + "'? (y = yes, Enter = no)")
        if ($yn -ne "y") { break }
    }
    $first = $false
    try { Process-Note $f } catch { Say ("Something went wrong with " + $f.Name + ": " + $_.Exception.Message) Red }
}