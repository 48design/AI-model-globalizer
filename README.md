# AI Model Globalizer

![AI Model Globalizer header](assets/ssd_bursting.jpg)

A Windows helper for people whose AI model folders have started multiplying like rabbits.

We all know this issue with gigabytes or even terabytes of AI models. We downloaded them manually, or software automatically downloaded them for us. Many applications use the same models, but since they don't communicate with each other ("Hey buddy! Did you already download the latest SDXL model? Yes?! Nice! Then I can use it, too!!"), we end up with multiple copies of the same huge model in multiple places.

And you know how crazy storage prices are right now.

The result is often a chaotic collection of model folders spread across different AI tools, each containing its own copy of checkpoints, LoRAs, ControlNets, VAEs, upscalers, text encoders, and many more. Not only does this waste storage space, it also makes managing and organizing models increasingly difficult.

AI Model Globalizer helps solve this problem by scanning your AI-related folders, detecting supported model files, and centralizing them into a single global model repository.

Instead of keeping multiple physical copies of the same file, the original file locations are replaced with filesystem links. To your AI software, everything still appears exactly where it was before. Under the hood, however, all applications can share the same physical file on disk.

## What it does

In short: it turns model-folder chaos into one shared model library without forcing every AI tool to learn a new path.

The result:

- less duplicate storage eating your drive like a hungry orc
- cleaner model organization
- no per-app path reconfiguration for linked files
- fewer "why is my 2 TB SSD full again?" moments

## Features

- Centralized global model store (default: `_global_models`)
- Custom global store path via CLI (`global=...` or `global ...`)
- Link mode selection:
  - `mode=auto` (default)
  - `mode=hardlink`
  - `mode=symlink`
- Auto mode chooses:
  - hardlink on same NTFS volume
  - symlink otherwise
- Detects already-globalized files (hardlink or symlink)
- Skips ignored folders and reparse-path trees during scan
- Category detection (Checkpoints, LoRA, ControlNet, VAE, Upscale, Embeddings, etc.)
- Verify mode (`verify`) for link checks
- Repair mode (`repair` / `migrate`) for global-store cleanup/normalization
- Legacy global-folder migration when changing global path (same-volume safe path)
- Migration progress visibility (file count + live `robocopy` output)

## Supported model file types

By default:

- `.safetensors`
- `.gguf`
- `.ckpt`
- `.onnx`

## Global structure

```text
<global_folder>/
├── <Category>/
│   └── <ModelName>/
│       └── <size_or_sha256>/
│           └── <filename.ext>
```

Example:

```text
_MODELS_/Checkpoints/sdxl_base_1.0/size_6754032123/sdxl_base_1.0.safetensors
```

## C# version (recommended)

If you just want the newer C# version, start here. It is faster, friendlier, and less "ancient batch-file wizardry" than the original script.

What started as a proof-of-concept batch script quickly turned into a mature C# application, mostly because some jobs should not be left to slow-as-hell batch magic forever. The result: much better speed, clearer progress output, and a proper single-EXE build for normal humans.

### Quick start

Build:

```text
dotnet build csharp\AiModelGlobalizer.csproj
```

Run:

```text
dotnet run --project csharp --
```

On startup, it asks for:
- scan folder
- global output folder

Press ENTER to keep the defaults, or type your own paths if your models live in a folder called something deeply sensible like `D:\AI\final_final_models_REAL`.

It scans first, shows live progress (`dirs`, `models`, `candidates`, `skipped`), prepares the plan, and then asks for `E` before making changes.
Nothing is moved until you explicitly confirm. No surprise model teleportation.

All eligible model files are moved into the global folder and linked back to their original paths. Duplicate-looking files are hashed so they can be identified safely, but duplicates are not the only files processed. The goal is one global home for the models, not just duplicate cleanup.

After an interactive run, it waits for ENTER before closing so you can actually read the result instead of watching a console window vanish like a startled raccoon.

### Run without prompts (for scripts)

```text
dotnet run --project csharp -- no-prompt scan="D:\AI Libraries" global="D:\AI\_global_models"
```

### Useful commands

Verify links:

```text
dotnet run --project csharp -- verify "global=D:\AI\_global_models"
```

Repair/migrate global store:

```text
dotnet run --project csharp -- repair "global=D:\AI\_global_models"
```

Write extra debug file list during scan:

```text
dotnet run --project csharp -- debug
```

This creates `ai_model_globalizer_found_files.txt`. Most users do not need it; it is mainly useful when the tool and your folder layout are having a little disagreement.

### Build a single EXE

All options below produce one `.exe`, because nobody asked for a souvenir basket of runtime files.

For the recommended standalone build, you can also run:

```text
csharp\build.bat
```

This publishes the Native AOT EXE to `csharp\bin\Release\net9.0\win-x64\publish\`.

**Option A — tiniest EXE** (needs installed .NET runtime):

```text
dotnet publish csharp\AiModelGlobalizer.csproj -c Release -f net9.0 -r win-x64 --self-contained false -p:PublishSingleFile=true
```

**Option B — fully standalone, still small (recommended for sharing):**

```text
dotnet publish csharp\AiModelGlobalizer.csproj -c Release -f net9.0 -r win-x64 --self-contained true -p:PublishAot=true -p:StripSymbols=true
```

**Option C — fully standalone, biggest file:**

```text
dotnet publish csharp\AiModelGlobalizer.csproj -c Release -f net9.0 -r win-x64 --self-contained true -p:PublishSingleFile=true
```

Published files are in:

```text
csharp\bin\Release\<TFM>\win-x64\publish\
```

Size (measured in this repo, win-x64):
- Option A: ~0.21 MB
- Option B: ~2.00 MB
- Option C: ~67.68 MB

Notes:
- Symlink creation may require admin rights or Windows Developer Mode. Windows likes paperwork.

## Original batch script (a bit outdated and slow)

The batch file is still included as the original proof of concept and behavior reference.

It works, it started the whole thing, and it deserves a respectful little nod. But for normal use, the C# version above is the recommended path unless you specifically want the classic batch experience.

### Batch CLI usage

```text
ai_model_globalizer.bat [verify|repair] [global=PATH | global PATH] [mode=auto|hardlink|symlink | mode VALUE]
```

### Batch examples

```text
ai_model_globalizer.bat
ai_model_globalizer.bat --help
ai_model_globalizer.bat "global _MODELS_"
ai_model_globalizer.bat "global=_MODELS_"
ai_model_globalizer.bat "global=D:\AI\_global_models"
ai_model_globalizer.bat global "D:\AI Models\_MODELS_"
ai_model_globalizer.bat /global=D:\AI\_global_models /mode=auto
ai_model_globalizer.bat mode=hardlink
ai_model_globalizer.bat verify "global=D:\AI\_global_models"
```

## How it works

Short version: scan first, explain the plan, ask for confirmation, then do the filesystem magic.

### Normal run

1. Optional legacy migration check (if global folder changed)
2. Scan model files recursively
3. Skip ignored folders, reparse trees, global-folder files, already-globalized files
4. Categorize all eligible model files and prepare the globalize plan
5. Wait for explicit confirmation (`E`)
6. Move/store into global structure
7. Recreate original file path as hardlink or symlink (per mode)

### Legacy migration behavior

When you change global folder from default `_global_models`:

- same volume: script migrates legacy store to new global path before scan
- cross-volume: migration is skipped for safety and a notice is shown

## Notes on links

- Hardlinks require same NTFS volume.
- Symlink creation may require admin rights or Developer Mode, because Windows has opinions.
- No copy-only fallback mode is used for link replacement.
- If link creation fails, source restoration is attempted.

## Requirements

- Windows
- NTFS for hardlink mode
- Permission to create links (`mklink /H` for hardlinks, `mklink` for symlinks)
- Enough free space for temporary move/organization operations

## Safety / disclaimer

- Always back up important data first. Yes, really. Future-you deserves snacks, not data recovery.
- Test on a small model subset before running on your entire dragon hoard.
- Read the scan summary before pressing `E`.
- You are responsible for validating results in your environment.

## GitHub release: direct download for users

This repo includes a workflow at `.github/workflows/release.yml`, but normal users can happily ignore that machinery.

**Important:**
- End users do **not** need GitHub Actions.
- End users just download the `.exe` (or `.zip`) from **GitHub Releases** and run it.
- The workflow is for maintainers who publish new releases.
- Windows may show an "unknown publisher" / SmartScreen warning because the EXE is not code-signed yet. This is expected for small unsigned tools; annoying, but not mysterious.
- Releases include `SHA256SUMS.txt` so downloads can be checked against published hashes if you want the extra peace-of-mind ritual.

What it does:
- builds a single-file Native AOT `AiModelGlobalizer.exe` for `win-x64`
- creates release assets (`.exe`, `.zip`, and `SHA256SUMS.txt`)
- publishes them to GitHub Releases when you push a tag like `v1.0.0`

### Publish a new downloadable release

1. Commit and push your changes to `main`.
2. Create and push a version tag (example: `v1.0.0`).
3. Wait for the Release workflow to finish in GitHub Actions.
4. Open **GitHub → Releases**; users can download the attached `.exe` or `.zip` directly.

If you run the workflow manually (`workflow_dispatch`), assets are uploaded as workflow artifacts instead of creating a GitHub Release.
