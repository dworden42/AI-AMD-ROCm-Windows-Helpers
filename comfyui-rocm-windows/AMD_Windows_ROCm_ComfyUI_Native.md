# Running ComfyUI Natively on AMD ROCm in Windows

> [!NOTE]
> **Project Context & Disclaimer**:
> - **Proof of Concept**: This setup script and patch collection represent an early **proof of concept** created to overcome current Windows AMD ROCm hurdles. While this setup has been tested and verified on local AMD hardware (such as Radeon RX 7000 / 9000 series GPUs), AMD hardware configurations, Windows driver versions, and environments can differ significantly—what works seamlessly in one test environment may require adjustments or further testing on yours. Community feedback and real-world testing are warmly welcomed!
> - **AI-Assisted Development**: These scripts, patches, and documentation were created with AI assistance. In the spirit of complete transparency: if you prefer not to use AI-assisted code, please feel free to pass on this script and wait for official upstream Windows ROCm fixes from the respective project maintainers.

---

## Overview

Historically, running modern generative AI workflows on AMD Radeon hardware required dual-booting Linux, setting up heavy WSL2 virtual machines, or settling for severely constrained DirectML fallbacks.

AMD now publishes official native Windows ROCm wheels (`rocm-rel-7.2.1` / PyTorch `2.9.1+rocm7.2.1`), but setting up **ComfyUI** natively on Windows with these packages out of the box presents multiple subtle blockers:

1. **The PyPI Dependency Overwrite Trap**: Installing standard ComfyUI or custom node `requirements.txt` files prompts `pip` to overwrite ROCm-enabled PyTorch builds with standard PyPI CPU or CUDA wheels, breaking GPU acceleration.
2. **Missing `rocm_sdk` Windows Library Stubs**: AMD's `rocm_sdk` Python module expects Linux-oriented shared libraries (`hipsparselt`, `hipdnn`, `rocm-openblas`). On Windows, missing definitions cause `rocm_sdk.initialize_process` to fail with `ModuleNotFoundError` or assertion errors.
3. **Dynamic DLL Path Resolution**: Windows cannot resolve the ROCm runtime DLLs (`_rocm_sdk_core\bin`, `_rocm_sdk_libraries_custom\bin`, and AMD's system ROCm directory) without explicit environment `PATH` injection prior to starting the Python runtime.
4. **Attention Mechanism Incompatibilities**: ComfyUI's default split cross-attention crashes on AMD ROCm. Forcing PyTorch native Scaled Dot-Product Attention (SDPA) is required for stable generation.
5. **Git Dubious Ownership & Detached HEAD Pitfalls**: Reinstalling Windows, changing user accounts, or installing nodes via managers frequently leads to Git `dubious ownership` blocks or detached HEAD states that break automated updates.

The companion PowerShell script [`comfyui.ps1`](file:///C:/Users/donwo/.gemini/antigravity-ide/scratch/comfyui-rocm-windows-gist/comfyui.ps1) solves all of these problems automatically.

---

## Features

- **Automated ROCm Environment Bootstrap**: Automatically provisions a dedicated Python 3.12 virtual environment, pulls the ComfyUI repository, installs dependencies, and pins the official AMD ROCm 7.2.1 PyTorch wheels.
- **In-Memory & SDK Patching**: Automatically inspects and safely stubs missing Windows library entries in `rocm_sdk\_dist_info.py`.
- **Protected Updates**: Updates ComfyUI and all installed `custom_nodes` via `git pull`, automatically resolving detached HEAD states and re-verifying ROCm wheel integrity after every node installation.
- **Dubious Ownership Remediation**: Detects Git dubious ownership errors and includes an automated ACL repair tool (`fix-ownership`) using `takeown` and `icacls`.
- **Background Server Management**: Starts ComfyUI as a detached background process with PID tracking, graceful shutdown timeout, and separated standard output (`.out`) and error (`.err`) logs.

---

## Prerequisites

Before running the script, ensure your system has the following installed:

1. **Operating System**: Windows 10 or Windows 11 (64-bit).
2. **AMD Graphics Driver**: AMD Software: Adrenalin Edition or the AMD ROCm Windows Preview Driver.
3. **Python 3.12 (64-bit)**: Download and install from [python.org](https://www.python.org/downloads/). Ensure **"Add python.exe to PATH"** is selected during installation.
4. **Git for Windows**: Download and install from [git-scm.com](https://git-scm.com/).
5. **PowerShell 7+**: Recommended for modern execution (`pwsh`).

---

## Quick Start

### 1. Download & Configure the Script

Save [`comfyui.ps1`](file:///C:/Users/donwo/.gemini/antigravity-ide/scratch/comfyui-rocm-windows-gist/comfyui.ps1) to a folder of your choice (e.g. `C:\AI\scripts\comfyui.ps1`).

Open `comfyui.ps1` in an editor to review the top configuration section. Adjust the directory paths if you want ComfyUI stored in a specific location:

```powershell
# --- Configuration ---
$COMFYUI_PATH     = "C:\AI\ComfyUI"
$OUTPUT_DIRECTORY = Join-Path $COMFYUI_PATH "output"
$USER_DIRECTORY   = Join-Path $COMFYUI_PATH "user"
```

### 2. Install ComfyUI & ROCm Dependencies

Open PowerShell and run:

```powershell
.\comfyui.ps1 install
```

This single command will:
1. Verify system dependencies (`git`, `python 3.12`, AMD GPU presence).
2. Clone the latest ComfyUI repository to `$COMFYUI_PATH`.
3. Create a dedicated `venv-3.12` virtual environment.
4. Install all ComfyUI base dependencies.
5. Download and install official AMD ROCm PyTorch wheels (`torch 2.9.1+rocm7.2.1`, `torchvision`, `torchaudio`).
6. Download and install AMD ROCm SDK wheels and apply necessary Windows stubs.

### 3. Start the Server

```powershell
.\comfyui.ps1 start
```

ComfyUI starts in the background. The script reports the assigned Process ID (PID) and the log file paths:
- Output log: `$env:TEMP\comfyui.log.out`
- Error log: `$env:TEMP\comfyui.log.err`

Open your web browser and navigate to:
```
http://127.0.0.1:8188
```

---

## Command Reference

| Command | Description |
| :--- | :--- |
| `.\comfyui.ps1 start` | Starts ComfyUI in the background with ROCm environment variables and logging enabled. |
| `.\comfyui.ps1 stop` | Gracefully signals ComfyUI to exit (falls back to forced termination after 5 seconds). |
| `.\comfyui.ps1 restart` | Restarts the background ComfyUI instance. |
| `.\comfyui.ps1 status` | Displays whether ComfyUI is currently active and its Process ID (PID). |
| `.\comfyui.ps1 update` | Stops ComfyUI, pulls git updates for ComfyUI and all custom nodes, re-applies ROCm dependency protection, and restarts the server. |
| `.\comfyui.ps1 install` | Performs the full installation from scratch. |
| `.\comfyui.ps1 fix-ownership` | Fixes Windows file permissions and user SID mismatches using `takeown` and `icacls`. |

---

## How It Solves ROCm On Windows

### 1. PyTorch Wheel Protection
When custom nodes run `pip install -r requirements.txt`, pip's resolver may see a newer CPU or CUDA build on PyPI and silently overwrite your ROCm installation. `Install-PythonDeps` inspects the installed torch version after any dependency install; if torch was reverted, it re-installs the pinned ROCm wheels without allowing pip dependencies to regress.

### 2. `rocm_sdk` Windows Stubbing
AMD's official `rocm_sdk` module checks for several shared libraries at runtime that only exist under Linux ELF formats. The `Install-RocmSdk` function patches `Lib\site-packages\rocm_sdk\_dist_info.py` by safely injecting Windows stubs:

```python
# [comfyui-script] windows-missing-libs
LibraryEntry("hipsparselt", "core", "libhipsparselt.so.0", "")
LibraryEntry("hipdnn", "core", "libhipdnn.so.0", "")
LibraryEntry("rocm-openblas", "core", "librocm-openblas.so.0", "")
```

This prevents `initialize_process` from crashing when ComfyUI initializes the ROCm execution provider.

### 3. Runtime PATH Resolution
Before spawning `main.py`, `Start-ComfyUI` dynamically locates and prepends the ROCm binary directories to the Windows process `PATH`:
- `venv-3.12\Lib\site-packages\_rocm_sdk_core\bin`
- `venv-3.12\Lib\site-packages\_rocm_sdk_libraries_custom\bin`
- `C:\Program Files\AMD\ROCm\bin` (if system ROCm is present)

### 4. GPU Architecture Tuning
The script configures crucial ROCm and PyTorch memory environment variables tailored for AMD RDNA architectures:
- `TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1` enables high-performance Triton kernels.
- `HSA_OVERRIDE_GFX_VERSION=11.0.0` maps the GPU target (default is GFX1100 for RDNA3 cards like the RX 7900 XTX / 7900 XT / 7800 XT).
  > **Note**: For RDNA2 cards (e.g., RX 6800 XT, RX 6900 XT), change this variable in `comfyui.ps1` to `10.3.0`.
- `HIP_FORCE_DEV_KERNARG=1` avoids host memory synchronization stalls.
- `PYTORCH_ALLOC_CONF=garbage_collection_threshold:0.8,max_split_size_mb:512` mitigates VRAM fragmentation.
- `--use-pytorch-cross-attention` leverages native PyTorch SDPA, bypassing CUDA-specific split attention routines.

---

## Troubleshooting

### ComfyUI Fails to Start
Check the error log located at `$env:TEMP\comfyui.log.err`:
```powershell
Get-Content "$env:TEMP\comfyui.log.err" -Tail 50
```

### Dubious Ownership in Git
If you copied your ComfyUI installation from another machine, drive, or reinstalled Windows, Git will refuse to pull updates due to mismatched Windows Security Identifiers (SIDs):
```powershell
# Run PowerShell as Administrator, then:
.\comfyui.ps1 fix-ownership
```

### Out of Memory (OOM) Errors
AMD GPUs with 16GB or less VRAM may encounter allocation errors on high-resolution FLUX or SDXL workflows. Ensure the `--reserve-vram 0.9` parameter is preserved in `$STARTUP_OPTIONS` to leave breathing room for the Windows Desktop Window Manager (DWM).

---

## License

This script and instructional guide are provided under the [MIT License](https://opensource.org/licenses/MIT).
