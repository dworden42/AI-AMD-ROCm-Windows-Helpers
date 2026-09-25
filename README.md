# AMD ROCm Windows Helpers & Utilities

A curated collection of automation scripts, runtime patches, and technical guides designed to deploy and run modern generative AI workloads natively on **Windows** using **AMD ROCm™**.

> [!NOTE]
> **Project Context & Disclaimer**:
> - **Proof of Concept**: This collection of setup scripts, utilities, and technical documentation represents an early **proof of concept** created to overcome current Windows AMD ROCm hurdles. While these setups have been tested and verified on local AMD hardware (such as Radeon RX 7000 and RX 9000 series GPUs), hardware configurations, Windows driver versions, and environments can differ significantly—what works seamlessly in one test environment may require adjustments or further testing on yours. Community feedback, issue reports, and real-world testing are warmly welcomed!
> - **AI-Assisted Development**: These scripts, patches, and documentation were created with AI assistance. In the spirit of complete transparency: if you prefer not to use AI-assisted code, please feel free to pass on these utilities and wait for official upstream Windows ROCm fixes from the respective project maintainers.

---

## Overview

Historically, running advanced generative AI workflows on AMD Radeon™ hardware on Windows required dual-booting Linux, setting up heavy WSL2 virtual machines, or settling for constrained DirectML fallbacks.

With AMD's official release of native Windows ROCm PyTorch wheels (such as `rocm-rel-7.2.1` / PyTorch `2.9.1+rocm7.2.1`), native execution on Windows is now a reality. However, developers and creators frequently run into subtle ecosystem blockers:

1. **PyPI Dependency Overwrite Traps**: Standard package installations and `requirements.txt` files frequently overwrite ROCm-enabled PyTorch builds with standard PyPI CPU or CUDA wheels.
2. **Missing `rocm_sdk` Windows Stubs**: AMD's `rocm_sdk` Python module expects Linux-oriented shared libraries, causing process initialization to fail on Windows.
3. **Missing Distributed (`USE_DISTRIBUTED=0`) Extensions**: Windows ROCm PyTorch wheels lack `torch._C._distributed_c10d`, causing libraries that unconditionally import distributed tensors (like `torchao`, `diffusers`, and `accelerate`) to crash immediately.
4. **Dynamic DLL Path Resolution**: Windows cannot resolve ROCm runtime DLLs without explicit environment `PATH` configuration prior to Python execution.
5. **Cross-Attention Crashes**: Default split cross-attention implementations crash on Windows ROCm unless forced to native Scaled Dot-Product Attention (SDPA).

This repository provides dedicated PowerShell automation scripts and in-depth technical documentation to solve these problems cleanly and repeatably.

---

## Utilities & Documentation

| Component | Description | Documentation | Utility Script |
| :--- | :--- | :--- | :--- |
| **ComfyUI Native ROCm** | Native Windows ComfyUI manager with dependency pinning, runtime DLL injection, SDPA enforcement, and background execution. | [ComfyUI Guide](comfyui-rocm-windows/AMD_Windows_ROCm_ComfyUI_Native.md) | [`comfyui.ps1`](comfyui-rocm-windows/comfyui.ps1) |
| **AI-Toolkit Standalone** | Standalone LoRA training environment (Flux, Chroma, SDXL, SD 1.5) with distributed tensor emulation and `torchao` patching. | [AI-Toolkit Guide](amd-ai-toolkit-standalone/AMD_AI_TOOLKIT_STANDALONE.md) | [`Setup-AmdAiToolkit.ps1`](amd-ai-toolkit-standalone/Setup-AmdAiToolkit.ps1) |

---

### 1. ComfyUI Native AMD ROCm Helper

- **Documentation**: [`comfyui-rocm-windows/AMD_Windows_ROCm_ComfyUI_Native.md`](comfyui-rocm-windows/AMD_Windows_ROCm_ComfyUI_Native.md)
- **Utility Script**: [`comfyui-rocm-windows/comfyui.ps1`](comfyui-rocm-windows/comfyui.ps1)

**Key Capabilities**:
- **Automated Virtualenv Bootstrap**: Automatically provisions Python 3.12 virtual environments and strictly pins official AMD ROCm 7.2.1 PyTorch wheels.
- **In-Memory & SDK Patching**: Inspects and safely stubs missing Windows library entries in `rocm_sdk\_dist_info.py`.
- **Protected Node Updates**: Safely updates ComfyUI and custom nodes while preventing PyPI from silently replacing ROCm PyTorch wheels with CPU/CUDA wheels.
- **Git Ownership Remediation**: Detects Git `dubious ownership` errors common across user migrations or multi-drive setups and applies ACL repairs (`takeown` / `icacls`).
- **Background Daemon Management**: Supports starting ComfyUI as a detached background service with PID tracking, graceful shutdown, and split stdout/stderr logging.

---

### 2. Standalone AI-Toolkit Setup & Patch Suite

- **Documentation**: [`amd-ai-toolkit-standalone/AMD_AI_TOOLKIT_STANDALONE.md`](amd-ai-toolkit-standalone/AMD_AI_TOOLKIT_STANDALONE.md)
- **Utility Script**: [`amd-ai-toolkit-standalone/Setup-AmdAiToolkit.ps1`](amd-ai-toolkit-standalone/Setup-AmdAiToolkit.ps1)

**Key Capabilities**:
- **Distributed Tensor Emulation**: Emulates missing `c10d` C++ distributed extensions on Windows, allowing `torchao` and `diffusers` to import cleanly without crashing.
- **`torchao` & `accelerate` Runtime Patching**: Automatically applies surgical patches to resolve Windows import blockers.
- **Full Model Architecture Support**: Enables training LoRAs for Flux.1, Chroma, SDXL, and SD 1.5 directly on Windows with AMD hardware.
- **Zero-Wait Standalone Execution**: Designed for engineers and creators who prefer working in terminal environments or standalone automation pipelines without waiting for upstream PR merges.

---

## Hardware & Architecture Compatibility Matrix

| GPU Model Family | Architecture | Target `HSA_OVERRIDE_GFX_VERSION` | Backend | Status |
| :--- | :--- | :--- | :--- | :--- |
| **Radeon™ RX 9070 XT / 9070** | RDNA 4 (Navi 48) | `11.0.0` | ROCm 7.2.1 | **Verified / Primary Test System** |
| **Radeon™ RX 7900 XTX / XT / GRE** | RDNA 3 (Navi 31) | `11.0.0` | ROCm 7.2.1 | Verified / Production |
| **Radeon™ RX 7800 XT / 7700 XT** | RDNA 3 (Navi 32) | `11.0.1` | ROCm 7.2.1 | Supported |
| **Radeon™ RX 7600 XT / 7600** | RDNA 3 (Navi 33) | `11.0.2` | ROCm 7.2.1 | Supported |
| **Radeon™ RX 6950 XT / 6900 XT / 6800** | RDNA 2 (Navi 21) | `10.3.0` | ROCm 7.2.1 | Supported |
| **Radeon™ RX 6700 XT / 6750 XT** | RDNA 2 (Navi 22) | `10.3.0` | ROCm 7.2.1 | Supported |

---

## System Prerequisites

Before using any of the helpers in this repository, ensure your Windows host meets the following prerequisites:

1. **Operating System**: Windows 10 (version 21H2 or newer) or Windows 11 (64-bit).
2. **AMD Graphics Driver**: AMD Software: Adrenalin Edition 24.x+ or official ROCm-supported driver.
3. **AMD ROCm™ & HIP SDK for Windows**:
   - Install **AMD ROCm 7.2 (or compatible 7.x) & HIP SDK** from the [AMD Developer Portal](https://www.amd.com/en/developer/resources/rocm-hub/hip-sdk.html).
   - Expected default installation path: `C:\Program Files\AMD\ROCm\7.2\` or `C:\Program Files\AMD\ROCm\`.
4. **Python**: Python 3.12 (64-bit) from [python.org](https://www.python.org/downloads/). Ensure **"Add python.exe to PATH"** is enabled.
5. **Git**: Git for Windows from [git-scm.com](https://git-scm.com/).
6. **PowerShell**: PowerShell 7+ (`pwsh`) is strongly recommended.

---

## Quick Start

### Running ComfyUI
To set up or launch ComfyUI with native AMD ROCm:
```powershell
# Run from PowerShell 7+
./comfyui-rocm-windows/comfyui.ps1 -Help
```

Refer to the [ComfyUI Native Guide](comfyui-rocm-windows/AMD_Windows_ROCm_ComfyUI_Native.md) for full commands (`run`, `start`, `stop`, `update`, `fix-ownership`).

### Setting Up AI-Toolkit
To provision a standalone AI-Toolkit training environment:
```powershell
# Run from PowerShell 7+
./amd-ai-toolkit-standalone/Setup-AmdAiToolkit.ps1
```

Refer to the [AI-Toolkit Standalone Guide](amd-ai-toolkit-standalone/AMD_AI_TOOLKIT_STANDALONE.md) for training configuration examples and troubleshooting.

---

## Contributing & Community

Issues, hardware reports, and pull requests are welcome! If you test these utilities on other AMD GPU configurations or newer ROCm builds, please feel free to open an issue or submit a PR documenting your results.
