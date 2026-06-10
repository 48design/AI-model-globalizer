# AI Model Globalizer

A Windows batch helper that centralizes AI model files into one global repository while keeping original file paths usable via links.

## What it does

AI toolchains often download the same large models multiple times into different folders.

AI Model Globalizer scans for supported model files, groups them into a global structure, and replaces original file paths with links so software can keep using the same paths.

The result:

- less duplicate storage
- cleaner model organization
- no per-app path reconfiguration for linked files

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

## CLI usage

```text
ai_model_globalizer.bat [verify|repair] [global=PATH | global PATH] [mode=auto|hardlink|symlink | mode VALUE]
```

## Examples

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

### Normal run

1. Optional legacy migration check (if global folder changed)
2. Scan model files recursively
3. Skip ignored folders, reparse trees, global-folder files, already-globalized files
4. Categorize candidates and summarize
5. Wait for explicit confirmation (`E`)
6. Move/store into global structure
7. Recreate original file path as hardlink or symlink (per mode)

### Legacy migration behavior

When you change global folder from default `_global_models`:

- same volume: script migrates legacy store to new global path before scan
- cross-volume: migration is skipped for safety and a notice is shown

## Notes on links

- Hardlinks require same NTFS volume.
- Symlink creation may require admin rights or Developer Mode.
- No copy-only fallback mode is used for link replacement.
- If link creation fails, source restoration is attempted.

## Requirements

- Windows
- NTFS for hardlink mode
- Permission to create links (`mklink /H` for hardlinks, `mklink` for symlinks)
- Enough free space for temporary move/organization operations

## Safety / disclaimer

- Always back up important data first.
- Test on a small model subset before running on large libraries.
- You are responsible for validating results in your environment.
