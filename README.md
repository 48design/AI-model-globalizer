# AI Model Globalizer

A tiny helper to centralize AI model files for deduplication and organization.

## What it does

We all know this issue with gigabytes or even terabytes of AI models. We downloaded them manually, or software automatically downloaded them for us. Many applications use the same models, but since they don't communicate with each other ("Hey buddy! Did you already download the latest SDXL model? Yes?! Nice! Then I can use it, too!!"), we end up with multiple copies of the same huge model in multiple places.

And you know how crazy storage prices are right now.

The result is often a chaotic collection of model folders spread across different AI tools, each containing its own copy of checkpoints, LoRAs, ControlNets, VAEs, upscalers, text encoders, and many more. Not only does this waste storage space, it also makes managing and organizing models increasingly difficult.

AI Model Globalizer helps solve this problem by scanning your AI-related folders, detecting supported model files, and centralizing them into a single global model repository.

Instead of keeping multiple physical copies of the same file, the original file locations are replaced with NTFS hardlinks. To your AI software, everything still appears exactly where it was before. Under the hood, however, all applications can share the same physical file on disk.

## Features

* Centralize AI models in a single location
* Reduce duplicate storage usage
* Keep existing software working without reconfiguration
* Automatic category detection (LoRA, Checkpoints, ControlNet, VAE, ESRGAN, etc.)
* Detection of already-globalized files
* Configurable ignored folders
* Simulation mode before making changes
* Detailed scan statistics and processing summary
* Uses NTFS hardlinks for maximum compatibility

## Global Structure

Models are organized into a structure similar to:

```text
_global_models/
├── Checkpoints/
│   └── sdxl_base_1.0.safetensors/
│       └── hash_or_size/
│           └── sdxl_base_1.0.safetensors
├── LoRA/
│   └── cinematic_style.safetensors/
│       └── hash_or_size/
│           └── cinematic_style.safetensors
├── ControlNet/
│   └── control_v11p_sd15_openpose.pth/
│       └── hash_or_size/
│           └── control_v11p_sd15_openpose.pth
```

This makes it much easier to see what models you actually have and where they belong.

## Supported Model Types

By default the script scans common AI model formats such as:

* `.safetensors`
* `.gguf`
* `.ckpt`
* `.onnx`
* `.bin`

Additional formats can easily be added.

## How It Works

1. Scan all configured folders
2. Skip ignored directories
3. Skip files already located in the global repository
4. Skip files already hardlinked to the global repository
5. Categorize detected models
6. Show a detailed summary
7. Wait for confirmation
8. Copy models into the global repository
9. Replace original files with NTFS hardlinks

No changes are made until execution is explicitly confirmed.

## Requirements

* Windows
* NTFS file system
* Permission to create hardlinks (`mklink /H`)

## Disclaimer

Always keep backups of important data and test on a smaller collection before processing a large model library. While the script tries to be careful, you are ultimately responsible for your own data.
