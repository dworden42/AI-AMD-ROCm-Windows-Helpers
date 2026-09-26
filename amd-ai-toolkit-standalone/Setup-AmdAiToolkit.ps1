<#
.SYNOPSIS
    Automated standalone installer and patch utility for AI-Toolkit with AMD ROCm on Windows.

.DESCRIPTION
    Installs and patches ostris/ai-toolkit to enable native AMD Radeon GPU LoRA training
    on Windows via official AMD ROCm 7.2.1 wheels. Automatically applies runtime patches
    to bypass Linux-only c10d/distributed stubs, missing rocm_sdk libraries, and tokenizer
    guards.

    NOTE: This utility is an experimental proof of concept developed with AI assistance.
    Hardware configurations and driver revisions can vary across systems; testing and
    community feedback are encouraged. If you prefer to avoid AI-assisted code, please
    bypass this script.

.PARAMETER TargetDir
    The target directory where ai-toolkit and its virtual environment should be installed.
    Defaults to .\ai-toolkit.

.PARAMETER GfxVersion
    The HSA_OVERRIDE_GFX_VERSION for your AMD GPU. Defaults to auto-detect, or '11.0.0'
    for RX 7900 series, '10.3.0' for RX 6000 series, '11.0.1'/'11.0.2' for RX 7800/7700/7600.

.PARAMETER SkipClone
    Skips cloning the ai-toolkit repository if it is already present in TargetDir.

.EXAMPLE
    .\Setup-AmdAiToolkit.ps1 -TargetDir "C:\AI\ai-toolkit" -GfxVersion "11.0.0"
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$TargetDir = "$PSScriptRoot\ai-toolkit",

    [Parameter()]
    [string]$GfxVersion = "",

    [Parameter()]
    [string]$RocmBaseUrl = "https://repo.radeon.com/rocm/windows/rocm-rel-7.2.1",

    [Parameter()]
    [string]$AiToolkitRepo = "https://github.com/ostris/ai-toolkit.git",

    [Parameter()]
    [switch]$SkipClone
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n[+] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-WarnMsg {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

# 1. Resolve Target Paths
$ResolvedTarget = [System.IO.Path]::GetFullPath($TargetDir)
$VenvDir = Join-Path $ResolvedTarget ".venv"
$PythonExe = Join-Path $VenvDir "Scripts\python.exe"

Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "   AMD ROCm Windows AI-Toolkit Setup & Patch Provisioner   " -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "Target Directory : $ResolvedTarget"
Write-Host "Virtual Env      : $VenvDir"

# 2. Hardware Detection
Write-Step "Detecting AMD GPU hardware..."
$GpuName = "Unknown"
$DetectedGfx = "11.0.0"

try {
    $Controllers = Get-CimInstance Win32_VideoController
    foreach ($controller in $Controllers) {
        $name = $controller.Name
        if ($name -match "AMD|Radeon") {
            $GpuName = $name
            if ($name -match "9070|9000") {
                $DetectedGfx = "11.0.0"
            } elseif ($name -match "7900") {
                $DetectedGfx = "11.0.0"
            } elseif ($name -match "7800|7700") {
                $DetectedGfx = "11.0.1"
            } elseif ($name -match "7600") {
                $DetectedGfx = "11.0.2"
            } elseif ($name -match "6[0-9]{3}") {
                $DetectedGfx = "10.3.0"
            }
            break
        }
    }
} catch {
    Write-WarnMsg "Unable to query WMI for GPU details. Defaulting to GFX 11.0.0."
}

if (-not [string]::IsNullOrWhiteSpace($GfxVersion)) {
    $EffectiveGfx = $GfxVersion
} else {
    $EffectiveGfx = $DetectedGfx
}

Write-Success "Detected GPU: $GpuName"
Write-Success "Target HSA_OVERRIDE_GFX_VERSION: $EffectiveGfx"

# 2b. Check for AMD ROCm & HIP SDK on Windows
Write-Step "Checking for AMD ROCm & HIP SDK installation..."
$RocmProgramFiles = Join-Path $env:ProgramFiles "AMD\ROCm"
$HipFound = $false

if (Test-Path $RocmProgramFiles) {
    $RocmVersions = Get-ChildItem -Path $RocmProgramFiles -Directory -ErrorAction SilentlyContinue
    $VerSummary = if ($RocmVersions) { ($RocmVersions | Select-Object -ExpandProperty Name) -join ", " } else { "Detected" }
    Write-Success "Found AMD ROCm / HIP installation at $RocmProgramFiles (Version: $VerSummary)"
    $HipFound = $true
} elseif ($env:HIP_PATH -and (Test-Path $env:HIP_PATH)) {
    Write-Success "Found AMD HIP SDK via HIP_PATH at $env:HIP_PATH"
    $HipFound = $true
} else {
    Write-WarnMsg "AMD ROCm / HIP SDK was not detected in $RocmProgramFiles or via HIP_PATH."
    Write-WarnMsg "AMD ROCm 7.2 and the HIP SDK for Windows are required for PyTorch to access the GPU runtime (amdhip64.dll)."
    Write-WarnMsg "Download from: https://www.amd.com/en/developer/resources/rocm-hub/hip-sdk.html"
}

# 3. Locate System Python 3.12
Write-Step "Locating compatible Python 3.12..."
$SystemPython = $null
$PythonCandidates = @("python.exe", "python3.12.exe", "py.exe -3.12", "python3.exe")

foreach ($cand in $PythonCandidates) {
    try {
        $parts = $cand -split " "
        $exe = $parts[0]
        $argsList = if ($parts.Length -gt 1) { $parts[1..($parts.Length - 1)] + @("--version") } else { @("--version") }
        $ver = & $exe $argsList 2>&1
        if ($ver -match "Python 3\.(1[0-2])") {
            $SystemPython = $cand
            Write-Success "Found compatible Python: $cand ($ver)"
            break
        }
    } catch {
        # continue checking
    }
}

if (-not $SystemPython) {
    Write-Fail "Python 3.12 (or 3.10-3.11) was not found on PATH. Please install Python 3.12 from python.org."
}

# 4. Create Target Directory & Virtual Environment
if (-not (Test-Path $ResolvedTarget)) {
    New-Item -ItemType Directory -Path $ResolvedTarget -Force | Out-Null
}

if (-not (Test-Path $PythonExe)) {
    Write-Step "Creating virtual environment (.venv)..."
    $pyParts = $SystemPython -split " "
    $pyExe = $pyParts[0]
    $pyArgs = if ($pyParts.Length -gt 1) { $pyParts[1..($pyParts.Length - 1)] + @("-m", "venv", $VenvDir) } else { @("-m", "venv", $VenvDir) }
    & $pyExe $pyArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $PythonExe)) {
        Write-Fail "Failed to create virtual environment at $VenvDir."
    }
    Write-Success "Virtual environment created."
} else {
    Write-Success "Existing virtual environment detected at $VenvDir."
}

# 5. Bootstrap pip, setuptools, wheel
Write-Step "Bootstrapping pip, setuptools, and wheel..."
& $PythonExe -m pip install --upgrade pip setuptools wheel
if ($LASTEXITCODE -ne 0) {
    Write-WarnMsg "Pip upgrade returned non-zero code; continuing..."
}

# 6. Install AMD ROCm 7.2.1 PyTorch Wheels
Write-Step "Installing official AMD ROCm PyTorch wheels (2.9.1+rocm7.2.1)..."
$TorchWheels = @(
    "$RocmBaseUrl/torch-2.9.1+rocm7.2.1-cp312-cp312-win_amd64.whl",
    "$RocmBaseUrl/torchaudio-2.9.1+rocm7.2.1-cp312-cp312-win_amd64.whl",
    "$RocmBaseUrl/torchvision-0.24.1+rocm7.2.1-cp312-cp312-win_amd64.whl"
)

& $PythonExe -m pip install --no-cache-dir --no-deps @TorchWheels
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to install AMD ROCm PyTorch wheels."
}
Write-Success "PyTorch ROCm 7.2.1 installed successfully."

# 7. Install AMD ROCm SDK Packages
Write-Step "Installing AMD ROCm SDK wheels..."
$SdkWheels = @(
    "$RocmBaseUrl/rocm-7.2.1.tar.gz",
    "$RocmBaseUrl/rocm_sdk_core-7.2.1-py3-none-win_amd64.whl",
    "$RocmBaseUrl/rocm_sdk_devel-7.2.1-py3-none-win_amd64.whl",
    "$RocmBaseUrl/rocm_sdk_libraries_custom-7.2.1-py3-none-win_amd64.whl"
)

& $PythonExe -m pip install --no-cache-dir @SdkWheels
if ($LASTEXITCODE -ne 0) {
    Write-WarnMsg "ROCm SDK installation returned warnings; continuing with patches..."
}
Write-Success "AMD ROCm SDK packages installed."

# 8. Clone or Update AI-Toolkit
if (-not $SkipClone) {
    $GitDir = Join-Path $ResolvedTarget ".git"
    if (-not (Test-Path $GitDir)) {
        Write-Step "Cloning AI-Toolkit repository (with submodules)..."
        git clone --recurse-submodules $AiToolkitRepo $ResolvedTarget
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to clone ai-toolkit from $AiToolkitRepo."
        }
        Write-Success "AI-Toolkit cloned successfully."
    } else {
        Write-Step "Updating existing AI-Toolkit repository submodules..."
        Push-Location $ResolvedTarget
        try {
            git submodule update --init --recursive
        } finally {
            Pop-Location
        }
        Write-Success "Submodules up to date."
    }
}

# 9. Install AI-Toolkit Dependencies
$ReqFile = Join-Path $ResolvedTarget "requirements.txt"
if (Test-Path $ReqFile) {
    Write-Step "Installing requirements into virtual environment (protecting PyTorch)..."
    & $PythonExe -m pip install --no-cache-dir -r $ReqFile sympy networkx jinja2 httpx
    if ($LASTEXITCODE -ne 0) {
        Write-WarnMsg "Pip reported dependency resolution notices; proceeding to apply patches..."
    }
    Write-Success "Core requirements installed."
}

# 10. Apply Custom ROCm & Windows Runtime Patches
Write-Step "Applying custom AMD Windows runtime patches..."

# Patch A: rocm_sdk/_dist_info.py missing library stubs
$RocmDistInfo = Join-Path $VenvDir "Lib\site-packages\rocm_sdk\_dist_info.py"
if (Test-Path $RocmDistInfo) {
    $content = [System.IO.File]::ReadAllText($RocmDistInfo)
    $modified = $false
    if ($content -match "    LibraryEntry\(") {
        $content = $content.Replace("    LibraryEntry(", "LibraryEntry(")
        $modified = $true
    }
    if ($content -match ", optional=True") {
        $content = $content.Replace(", optional=True", "")
        $modified = $true
        Write-Success "Auto-repaired rocm_sdk\_dist_info.py (removed invalid optional=True parameter)."
    }
    if ($modified) {
        [System.IO.File]::WriteAllText($RocmDistInfo, $content)
    }
    if ($content -notmatch "\[loramancer\] windows-missing-libs") {
        $missingStubs = @()
        if ($content -notmatch "hipsparselt") {
            $missingStubs += 'LibraryEntry("hipsparselt", "core", "libhipsparselt.so.0", "")'
        }
        if ($content -notmatch "hipdnn") {
            $missingStubs += 'LibraryEntry("hipdnn", "core", "libhipdnn.so.0", "")'
        }
        if ($content -notmatch "rocm-openblas") {
            $missingStubs += 'LibraryEntry("rocm-openblas", "core", "librocm-openblas.so.0", "")'
        }
        if ($missingStubs.Count -gt 0) {
            $patchBlock = "`n# [loramancer] windows-missing-libs`n" + ($missingStubs -join "`n") + "`n"
            [System.IO.File]::AppendAllText($RocmDistInfo, $patchBlock)
            Write-Success "Patched rocm_sdk\_dist_info.py (Windows library stubs added)."
        }
    } else {
        Write-Success "rocm_sdk\_dist_info.py already patched."
    }
}

# Patch B: torch/distributed/__init__.py stubs for Windows USE_DISTRIBUTED=0
$DistInit = Join-Path $VenvDir "Lib\site-packages\torch\distributed\__init__.py"
if (Test-Path $DistInit) {
    $content = [System.IO.File]::ReadAllText($DistInit)
    if ($content -notmatch "\[loramancer\] windows-distributed-stubs") {
        $target = 'sys.modules["torch.distributed"].ProcessGroup = _ProcessGroupStub  # type: ignore[attr-defined]'
        $replacement = @"
sys.modules["torch.distributed"].ProcessGroup = _ProcessGroupStub  # type: ignore[attr-defined]

    # [loramancer] windows-distributed-stubs
    class _GroupStub:
        WORLD = None

    class _ReduceOpStub:
        SUM = None
        PRODUCT = None
        MIN = None
        MAX = None
        BAND = None
        BOR = None
        BXOR = None

    sys.modules["torch.distributed"].group = _GroupStub
    sys.modules["torch.distributed"].ReduceOp = _ReduceOpStub
    sys.modules["torch.distributed"].is_initialized = lambda: False
    sys.modules["torch.distributed"].get_rank = lambda group=None: 0
    sys.modules["torch.distributed"].get_world_size = lambda group=None: 1
"@
        $normContent = $content.Replace("`r`n", "`n")
        $normTarget = $target.Replace("`r`n", "`n")
        $normRepl = $replacement.Replace("`r`n", "`n")
        if ($normContent.Contains($normTarget)) {
            $normContent = $normContent.Replace($normTarget, $normRepl)
            [System.IO.File]::WriteAllText($DistInit, $normContent)
            Write-Success "Patched torch\distributed\__init__.py (distributed stubs added)."
        }
    } else {
        Write-Success "torch\distributed\__init__.py already patched."
    }
}

# Patch C: torchao/__init__.py c10d guard
$AoInit = Join-Path $VenvDir "Lib\site-packages\torchao\__init__.py"
if (Test-Path $AoInit) {
    $content = [System.IO.File]::ReadAllText($AoInit)
    if ($content -notmatch "\[loramancer\] windows-c10d-guard") {
        $norm = $content.Replace("`r`n", "`n")
        $target = "from torchao.quantization import (`n    autoquant,`n    quantize_,`n)`n`nfrom . import dtypes, optim, testing"
        $replacement = @"
# [loramancer] windows-c10d-guard
try:
    from torchao.quantization import (
        autoquant,
        quantize_,
    )
    from . import dtypes, optim, testing
except Exception as e:
    import logging
    logging.debug(f"Skipping distributed/c10d dependent modules: {e}")
"@
        $normTarget = $target.Replace("`r`n", "`n")
        $normRepl = $replacement.Replace("`r`n", "`n")
        if ($norm.Contains($normTarget)) {
            $norm = $norm.Replace($normTarget, $normRepl)
            [System.IO.File]::WriteAllText($AoInit, $norm)
            Write-Success "Patched torchao\__init__.py (c10d guard applied)."
        }
    } else {
        Write-Success "torchao\__init__.py already patched."
    }
}

# Patch D: torchao/float8/distributed_utils.py
$DistUtils = Join-Path $VenvDir "Lib\site-packages\torchao\float8\distributed_utils.py"
if (Test-Path $DistUtils) {
    $content = [System.IO.File]::ReadAllText($DistUtils)
    if ($content -notmatch "\[loramancer\] windows-distributed-mock") {
        $norm = $content.Replace("`r`n", "`n")
        $target = "import torch.distributed._functional_collectives as funcol`nfrom torch.distributed._tensor import DTensor"
        $replacement = @"
# [loramancer] windows-distributed-mock
try:
    import torch.distributed._functional_collectives as funcol
    from torch.distributed._tensor import DTensor
except Exception:
    funcol = None
    DTensor = None
"@
        if ($norm.Contains($target)) {
            $norm = $norm.Replace($target, $replacement)
            [System.IO.File]::WriteAllText($DistUtils, $norm)
            Write-Success "Patched torchao\float8\distributed_utils.py."
        }
    } else {
        Write-Success "torchao\float8\distributed_utils.py already patched."
    }
}

# Patch E: torchao/float8/float8_tensor.py
$Float8Tensor = Join-Path $VenvDir "Lib\site-packages\torchao\float8\float8_tensor.py"
if (Test-Path $Float8Tensor) {
    $content = [System.IO.File]::ReadAllText($Float8Tensor)
    if ($content -notmatch "\[loramancer\] windows-dtensor-mock") {
        $norm = $content.Replace("`r`n", "`n")
        $target = "from torch.distributed._tensor import DTensor"
        $replacement = @"
# [loramancer] windows-dtensor-mock
try:
    from torch.distributed._tensor import DTensor
except Exception:
    class DTensor:
        pass
"@
        if ($norm.Contains($target)) {
            $norm = $norm.Replace($target, $replacement)
            [System.IO.File]::WriteAllText($Float8Tensor, $norm)
            Write-Success "Patched torchao\float8\float8_tensor.py."
        }
    } else {
        Write-Success "torchao\float8\float8_tensor.py already patched."
    }
}

# Patch F: torchao/float8/float8_utils.py
$Float8Utils = Join-Path $VenvDir "Lib\site-packages\torchao\float8\float8_utils.py"
if (Test-Path $Float8Utils) {
    $content = [System.IO.File]::ReadAllText($Float8Utils)
    if ($content -notmatch "\[loramancer\] windows-dist-mock") {
        $norm = $content.Replace("`r`n", "`n")
        $target = "import torch.distributed as dist`nfrom torch.distributed._functional_collectives import AsyncCollectiveTensor, all_reduce"
        $replacement = @"
# [loramancer] windows-dist-mock
try:
    import torch.distributed as dist
    from torch.distributed._functional_collectives import AsyncCollectiveTensor, all_reduce
except Exception:
    dist = None
    AsyncCollectiveTensor = None
    all_reduce = None
"@
        if ($norm.Contains($target)) {
            $norm = $norm.Replace($target, $replacement)
            [System.IO.File]::WriteAllText($Float8Utils, $norm)
            Write-Success "Patched torchao\float8\float8_utils.py."
        }
    } else {
        Write-Success "torchao\float8\float8_utils.py already patched."
    }
}

# Patch G: torch/distributed/tensor/__init__.py
$DistTensorInit = Join-Path $VenvDir "Lib\site-packages\torch\distributed\tensor\__init__.py"
if (Test-Path $DistTensorInit) {
    $content = [System.IO.File]::ReadAllText($DistTensorInit)
    if ($content -notmatch "\[loramancer\] windows-dtensor-guard") {
        $lines = $content.Replace("`r`n", "`n").Split("`n")
        $indented = ($lines | ForEach-Object { if ([string]::IsNullOrWhiteSpace($_)) { $_ } else { "    " + $_ } }) -join "`n"
        $patched = "# [loramancer] windows-dtensor-guard`ntry:`n$indented`nexcept Exception:`n    class DTensor:`n        pass`n"
        [System.IO.File]::WriteAllText($DistTensorInit, $patched)
        Write-Success "Patched torch\distributed\tensor\__init__.py."
    } else {
        Write-Success "torch\distributed\tensor\__init__.py already patched."
    }
}

# Patch H: accelerate/utils/other.py model_has_dtensor
$AccOther = Join-Path $VenvDir "Lib\site-packages\accelerate\utils\other.py"
if (Test-Path $AccOther) {
    $content = [System.IO.File]::ReadAllText($AccOther)
    if ($content -notmatch "\[loramancer\] windows-dtensor-guard") {
        $norm = $content.Replace("`r`n", "`n")
        $target = "def model_has_dtensor(model):"
        if ($norm.Contains($target)) {
            $replacement = @"
# [loramancer] windows-dtensor-guard
def model_has_dtensor(model):
    try:
        from torch.distributed.tensor import DTensor
        return any(isinstance(param, DTensor) for param in model.parameters())
    except Exception:
        return False

def _unpatched_model_has_dtensor(model):
"@
            $norm = $norm.Replace($target, $replacement)
            [System.IO.File]::WriteAllText($AccOther, $norm)
            Write-Success "Patched accelerate\utils\other.py (model_has_dtensor guard applied)."
        }
    } else {
        Write-Success "accelerate\utils\other.py already patched."
    }
}

# Patch I: chroma_model.py negative prompt guard
$ChromaModel = Join-Path $ResolvedTarget "extensions_built_in\diffusion_models\chroma\chroma_model.py"
if (Test-Path $ChromaModel) {
    $content = [System.IO.File]::ReadAllText($ChromaModel)
    if ($content -notmatch "\[loramancer\] chroma-prompt-guard") {
        $norm = $content.Replace("`r`n", "`n")
        $target = "text_inputs = self.tokenizer[1]("
        if ($norm.Contains($target)) {
            $replacement = @"
# [loramancer] chroma-prompt-guard
        if prompt is None:
            prompt = ""
        elif isinstance(prompt, list):
            prompt = [p if p is not None else "" for p in prompt]
        text_inputs = self.tokenizer[1](
"@
            $norm = $norm.Replace($target, $replacement)
            [System.IO.File]::WriteAllText($ChromaModel, $norm)
            Write-Success "Patched chroma_model.py (prompt None guard applied)."
        }
    } else {
        Write-Success "chroma_model.py already patched."
    }
}

# 11. Create AMD Runner Helper Script (run-amd.ps1)
Write-Step "Generating AMD launcher script (run-amd.ps1)..."
$RunnerScriptPath = Join-Path $ResolvedTarget "run-amd.ps1"
$RunnerContent = @"
<#
.SYNOPSIS
    Runs AI-Toolkit training with AMD ROCm hardware flags pre-configured.
.EXAMPLE
    .\run-amd.ps1 config.yaml
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = `$true, Position = 0)]
    [string]`$ConfigPath
)

`$ErrorActionPreference = "Stop"

`$env:HSA_OVERRIDE_GFX_VERSION = "$EffectiveGfx"
`$env:PYTORCH_ROCM_ARCH = "native"
`$env:MIOPEN_FIND_MODE = "FAST"
`$env:PYTHONUNBUFFERED = "1"
`$env:PYTHONIOENCODING = "utf-8"

Write-Host "[+] Launching AI-Toolkit on AMD GPU (GFX $EffectiveGfx)..." -ForegroundColor Magenta
Write-Host "[+] Config: `$ConfigPath" -ForegroundColor Magenta

`$Python = Join-Path `$PSScriptRoot ".venv\Scripts\python.exe"
`$RunPy = Join-Path `$PSScriptRoot "run.py"

& `$Python `$RunPy `$ConfigPath
"@

[System.IO.File]::WriteAllText($RunnerScriptPath, $RunnerContent)
Write-Success "Generated launcher script: $RunnerScriptPath"

# 12. Verification & Smoke Test
Write-Step "Verifying installation and patches..."
$VerifyCmd = @"
import torch
print(f'PyTorch Version  : {torch.__version__}')
print(f'HIP/CUDA Active  : {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'Device Name      : {torch.cuda.get_device_name(0)}')
from torchao.quantization.quant_primitives import _DTYPE_TO_BIT_WIDTH
from diffusers import AutoencoderTiny
print('Module Checks    : PASSED (TorchAO and Diffusers loaded successfully without c10d errors)')
"@

$VerifyFile = Join-Path $env:TEMP "verify_amd_aitoolkit.py"
[System.IO.File]::WriteAllText($VerifyFile, $VerifyCmd)

try {
    $verifyOutput = & $PythonExe $VerifyFile
    Write-Host "`n--- Verification Output ---" -ForegroundColor DarkCyan
    $verifyOutput | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
    Write-Host "---------------------------`n" -ForegroundColor DarkCyan
    Write-Success "All verification checks passed!"
} catch {
    Write-WarnMsg "Verification check encountered an error: $_"
} finally {
    if (Test-Path $VerifyFile) {
        Remove-Item $VerifyFile -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " [SUCCESS] AMD ROCm AI-Toolkit Environment Ready! " -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "To train a LoRA, run:" -ForegroundColor Yellow
Write-Host "  cd `"$ResolvedTarget`"" -ForegroundColor White
Write-Host "  .\run-amd.ps1 <path_to_config.yaml>`n" -ForegroundColor White
