# review-prompt.ps1
# Separate Reviewer AI (runs gemma2:9b, distinct from the qwen2.5:14b builder model).
# Attempts to break the draft prompt in Map.md before handover.

param(
    [string]$MapFile = "C:\Users\natal\Documents\OpenOctoFun\Map.md"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $MapFile)) {
    Write-Output "SKIP: Map.md not found."
    exit 0
}

$mapContent = Get-Content -Path $MapFile -Raw -Encoding UTF8

$systemPrompt = @"
You are a separate Reviewer AI inspecting a draft prompt built from an Idea Map.
You did NOT build this prompt. Your job is to break it before handover.

Check strictly for these four failure modes:
1. Steps assuming knowledge never stated in the nodes or links.
2. Linearity that flattens important connections from the map.
3. Ambiguity (words or steps another AI will misinterpret).
4. Anything invented by the builder that was not in the user's nodes/links.

Rules:
- State findings in plain, direct words.
- One finding per block. No dense paragraphs.
- Do not rewrite or override the prompt yourself; report the findings so the user decides.
"@

$body = @{
    model = "gemma2:9b"
    system = $systemPrompt
    prompt = "Here is the current Idea Map, Ordered Map, and Draft Prompt:`n`n$mapContent`n`nBreak the Draft Prompt against the Nodes and Links:"
    stream = $false
    options = @{ temperature = 0.1; num_ctx = 8192 }
} | ConvertTo-Json -Depth 5

try {
    $res = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/generate" -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8"
    Write-Output $res.response.Trim()
} catch {
    Write-Output "Separate reviewer (gemma2:9b) is currently unavailable - skipping check."
}
