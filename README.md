# Octo Vault

A tiny Windows setup script that turns a plain folder into a local, AI-assisted note-processing vault.

## What it is

Octo Vault is a batch file that creates a working folder structure for a local-first notes workflow. You drop messy notes in, and a small chain of scripts — backed by a local Ollama model — helps you organize them, generate ideas, tidy those ideas up, and turn them into actionable tasks. No cloud, no accounts, no subscriptions. Everything runs on your own machine.

Think of it as scaffolding: it builds the folders, copies in the PowerShell helpers, and writes the launcher shortcuts, so you can start using the workflow in about thirty seconds instead of an afternoon.

## The idea behind the folder names

The numbered folders spell out the pipeline:

| Folder | Purpose |
|---|---|
| `00-Drop-Notes-Here` | The inbox. Paste raw, unfiltered thoughts. |
| `01-Organize-The-Day` | Sort and structure what is in the inbox. |
| `02-Generate-Ideas` | Brainstorm from your notes. |
| `03-Tidy-Up-Ideas` | Refine and prune the good ones. |
| `04-Ready-AI-Instructions` | Prompts and instructions prepared for the model. |
| `05-Build-Tasks` | Turn ideas into concrete next steps. |
| `octo-config` | The engine room: scripts, launchers, state files. |

## What the setup script does

It is deliberately boring, and that is the point:

1. **Creates the folder tree** above (reusing anything that already exists).
2. **Copies three PowerShell helpers** (`squash-idea.ps1`, `review-prompt.ps1`, `watch-new-notes.ps1`) from a template folder, but never overwrites ones you have already edited.
3. **Writes three double-click launchers** into `octo-config`:
   - `start-assistant.bat` — boots Ollama and the Octo server.
   - `Squash-New-Idea.bat` — runs the main note-squashing script.
   - `stop-assistant.bat` — kills everything and frees your VRAM (handy if you also use the GPU for VR).
4. **Creates an empty `processed.txt`** so the watcher knows what it has already seen.

Nothing is installed system-wide. Nothing phones home. If you delete the folder, it is gone.

## Requirements

### Windows

It is a `.bat` file.

### Ollama

Install Ollama from [ollama.com](https://ollama.com).

### Models

The `stop-assistant.bat` launcher references two models by name. You need to pull them before using Octo Vault:

```bash
ollama pull qwen2.5:14b
ollama pull gemma2:9b
