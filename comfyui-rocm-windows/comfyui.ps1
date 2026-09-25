#Requires -Version 7.0
# ==============================================================================
# ComfyUI Native Windows AMD ROCm Lifecycle & Management Script
# ==============================================================================
# Features:
# - Native AMD ROCm setup on Windows (no WSL2 or Linux VM overhead)
# - Automated installation of official AMD ROCm 7.2.1 / PyTorch wheels
# - Automatic rocm_sdk library stub patch for Windows compatibility
# - Automatic ROCm DLL and system PATH resolution at runtime
# - Git repository and custom node batch updater with detached HEAD recovery
# - Dubious git ownership detection & automated ACL ownership repair
# - Background daemon management with PID tracking and graceful shutdown
# ==============================================================================

# Stop immediately on unhandled errors
$ErrorActionPreference = "Stop"

# --- Configuration ---
# Target directory where ComfyUI is installed or will be cloned
$COMFYUI_PATH = "C:\AI\ComfyUI"

# Custom directory for generated outputs (images, videos, audio)
$OUTPUT_DIRECTORY = Join-Path $COMFYUI_PATH "output"

# Custom user directory for workflows, settings, and node cache
$USER_DIRECTORY = Join-Path $COMFYUI_PATH "user"

# Process management and logging
$PID_FILE = Join-Path $env:TEMP "comfyui.pid"
$LOG_FILE = Join-Path $env:TEMP "comfyui.log"

# Virtual environment and entry point
$PYTHON_EXEC = Join-Path $COMFYUI_PATH "venv-3.12\Scripts\python.exe"
$MAIN_SCRIPT = Join-Path $COMFYUI_PATH "main.py"
$COMFYUI_REPO_URL = "https://github.com/comfyanonymous/ComfyUI.git"

# Official AMD ROCm Windows PyTorch & SDK Wheel URLs
$PYTORCH_ROCM_BASE = "https://repo.radeon.com/rocm/windows/rocm-rel-7.2.1"
$PYTORCH_TORCH_VERSION = "2.9.1+rocm7.2.1"
$PYTORCH_WHEELS = @(
    "$PYTORCH_ROCM_BASE/torch-2.9.1+rocm7.2.1-cp312-cp312-win_amd64.whl",
    "$PYTORCH_ROCM_BASE/torchaudio-2.9.1+rocm7.2.1-cp312-cp312-win_amd64.whl",
    "$PYTORCH_ROCM_BASE/torchvision-0.24.1+rocm7.2.1-cp312-cp312-win_amd64.whl"
)
$ROCM_SDK_WHEELS = @(
    "$PYTORCH_ROCM_BASE/rocm-7.2.1.tar.gz",
    "$PYTORCH_ROCM_BASE/rocm_sdk_core-7.2.1-py3-none-win_amd64.whl",
    "$PYTORCH_ROCM_BASE/rocm_sdk_devel-7.2.1-py3-none-win_amd64.whl",
    "$PYTORCH_ROCM_BASE/rocm_sdk_libraries_custom-7.2.1-py3-none-win_amd64.whl"
)

# Base startup arguments passed to main.py
$STARTUP_OPTIONS = @(
    "--disable-smart-memory",
    "--output-directory", "`"$OUTPUT_DIRECTORY`"",
    "--user-directory", "`"$USER_DIRECTORY`"",
    "--reserve-vram", "0.9",
    "--listen", "0.0.0.0"
)

# Cache for AMD GPU detection
$script:IsAmdGpuCached = $null

# --- Helper Functions ---

# Checks if an AMD GPU is present in the host system
function Test-AmdGpu {
    if ($null -ne $script:IsAmdGpuCached) {
        return $script:IsAmdGpuCached
    }

    try {
        $videoControllers = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
        $hasAmd = $videoControllers | Where-Object { $_.Name -match "AMD|Radeon|ROCm" } | Select-Object -First 1
        $script:IsAmdGpuCached = ($null -ne $hasAmd)
        
        if ($script:IsAmdGpuCached) {
            Write-Host "-> AMD GPU detected: $($hasAmd.Name)"
        }
        
        return $script:IsAmdGpuCached
    } catch {
        $script:IsAmdGpuCached = $false
        return $false
    }
}

# Checks for required system tools and runtime dependencies
function Test-Dependencies {
    # Check for git
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Error "Error: 'git' command not found. Please install Git for Windows from https://git-scm.com/"
        exit 1
    }

    # Check for Python 3.12
    $pythonVersions = @()
    $pythonCommands = @("python3.12", "python3", "python")
    
    foreach ($cmd in $pythonCommands) {
        if (Get-Command $cmd -ErrorAction SilentlyContinue) {
            $version = & $cmd --version 2>&1 | Select-String -Pattern "Python (\d+\.\d+)" | ForEach-Object { $_.Matches.Groups[1].Value }
            if ($version -eq "3.12") {
                $script:PYTHON_CMD = $cmd

                # Check for ROCm if an AMD GPU is detected
                if (Test-AmdGpu) {
                    $rocmInfo = Get-Command rocminfo -ErrorAction SilentlyContinue
                    if (-not $rocmInfo) {
                        $rocmPaths = @(
                            "C:\Program Files\AMD\ROCm",
                            "C:\Program Files (x86)\AMD\ROCm"
                        )
                        $rocmFound = $false
                        foreach ($path in $rocmPaths) {
                            if (Test-Path $path) {
                                Write-Host "-> ROCm installation found at: $path"
                                $rocmFound = $true
                                break
                            }
                        }

                        if (-not $rocmFound) {
                            Write-Warning "AMD GPU detected, but system-wide ROCm installation not found."
                            Write-Warning "Ensure AMD Adrenalin drivers or ROCm Windows packages are installed."
                        }
                    } else {
                        Write-Host "-> ROCm drivers detected."
                    }
                }

                return
            }
            $pythonVersions += "$cmd ($version)"
        }
    }

    Write-Error "Error: Python 3.12 not found. Available versions: $($pythonVersions -join ', ')"
    Write-Error "Please install Python 3.12 (64-bit) from https://www.python.org/downloads/"
    exit 1
}

# Installs ROCm SDK packages and applies compatibility stubs for Windows
function Install-RocmSdk {
    # Uninstall the PyPI stub first so it doesn't shadow the real package
    & $PYTHON_EXEC -m pip uninstall rocm-sdk -y 2>$null
    Write-Host "  > Installing AMD ROCm SDK packages..."
    & $PYTHON_EXEC -m pip install --no-cache-dir $ROCM_SDK_WHEELS
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install ROCm SDK packages"
    }

    # Patch rocm_sdk _dist_info.py to register libraries that don't exist natively on Windows.
    # Without this, rocm_sdk.initialize_process raises ModuleNotFoundError.
    $distInfoPath = Join-Path (Split-Path $PYTHON_EXEC) "..\Lib\site-packages\rocm_sdk\_dist_info.py"
    $distInfoPath = [System.IO.Path]::GetFullPath($distInfoPath)
    if (Test-Path $distInfoPath) {
        $content = Get-Content $distInfoPath -Raw
        if ($content -match '# \[comfyui-script\] windows-missing-libs') {
            $cleaned = $content -replace '\r?\n# \[comfyui-script\] windows-missing-libs\r?\n[\s\S]*?(?=\r?\n(?!LibraryEntry)|\Z)', ''
            Set-Content -Path $distInfoPath -Value $cleaned -NoNewline
            $content = $cleaned
            Write-Host "  > Removed stale comfyui-script patch from rocm_sdk _dist_info.py."
        }

        $missingEntries = @()
        $missingLibs = @(
            @{ name = "hipsparselt"; entry = 'LibraryEntry("hipsparselt", "core", "libhipsparselt.so.0", "")' },
            @{ name = "hipdnn"; entry = 'LibraryEntry("hipdnn", "core", "libhipdnn.so.0", "")' },
            @{ name = "rocm-openblas"; entry = 'LibraryEntry("rocm-openblas", "core", "librocm-openblas.so.0", "")' }
        )
        foreach ($lib in $missingLibs) {
            if ($content -notmatch ([regex]::Escape('"' + $lib.name + '"'))) {
                $missingEntries += $lib.entry
            }
        }
        if ($missingEntries.Count -gt 0) {
            $patch = "`n# [comfyui-script] windows-missing-libs`n" + ($missingEntries -join "`n") + "`n"
            Add-Content -Path $distInfoPath -Value $patch
            Write-Host "  > Patched rocm_sdk _dist_info.py with missing Windows library stubs ($($missingEntries.Count) entries added)."
        } else {
            Write-Host "  > rocm_sdk _dist_info.py already contains all required library stubs; no patch needed."
        }
    }
}

# Installs Python packages from requirements.txt and ensures ROCm PyTorch wheels are preserved
function Install-PythonDeps {
    param(
        [string]$RequirementsFile,
        [switch]$UpgradeTorch
    )

    if (-not (Test-Path $RequirementsFile)) {
        return
    }

    Write-Host "  > Installing packages from $RequirementsFile..."
    & $PYTHON_EXEC -m pip install --no-cache-dir -r $RequirementsFile
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install packages from $RequirementsFile"
    }

    # If AMD GPU is detected, override PyTorch with ROCm release wheels AFTER requirements.txt
    # so pip cannot replace them with a CPU-only build from PyPI.
    if (Test-AmdGpu) {
        $installedTorch = & $PYTHON_EXEC -m pip show torch 2>$null | Select-String "^Version:" | ForEach-Object { $_ -replace "^Version:\s*", "" }
        if ($UpgradeTorch -or ($installedTorch -ne $PYTORCH_TORCH_VERSION)) {
            Write-Host "  > Installing PyTorch ROCm wheels (current: '$installedTorch', target: '$PYTORCH_TORCH_VERSION')..."
            & $PYTHON_EXEC -m pip install --no-cache-dir --no-deps $PYTORCH_WHEELS
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to install PyTorch ROCm wheels"
            }
            Install-RocmSdk
        } else {
            Write-Host "  > PyTorch $PYTORCH_TORCH_VERSION already installed, skipping."
        }
    }
}

# Clones and installs ComfyUI, virtual environment, and dependencies from scratch
function Install-ComfyUI {
    Test-Dependencies

    # --- Step 1: Ensure ComfyUI repository is cloned ---
    if (-not (Test-Path $COMFYUI_PATH)) {
        Write-Host "ComfyUI directory not found. Starting installation..."
        $parentPath = Split-Path $COMFYUI_PATH -Parent
        if ($parentPath -and -not (Test-Path $parentPath)) {
            New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
        }

        Write-Host "-> Cloning ComfyUI from $COMFYUI_REPO_URL..."
        git clone $COMFYUI_REPO_URL $COMFYUI_PATH
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone ComfyUI repository"
        }
    } else {
        Write-Host "ComfyUI directory already exists at $COMFYUI_PATH. Verifying setup..."
    }

    # --- Step 2: Ensure Python virtual environment exists ---
    $venvPath = Join-Path $COMFYUI_PATH "venv-3.12"
    if (-not (Test-Path $venvPath)) {
        Write-Host "Python virtual environment not found. Creating it..."
        Write-Host "-> Creating virtual environment with Python 3.12..."
        
        $pythonCmd = "python3.12"
        if (-not (Get-Command $pythonCmd -ErrorAction SilentlyContinue)) {
            $pythonCmd = "python"
        }
        
        & $pythonCmd -m venv $venvPath
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create virtual environment"
        }
    } else {
        Write-Host "Python virtual environment already exists."
    }

    # Ensure output and user directories exist
    if (-not (Test-Path $OUTPUT_DIRECTORY)) {
        New-Item -ItemType Directory -Path $OUTPUT_DIRECTORY -Force | Out-Null
    }
    if (-not (Test-Path $USER_DIRECTORY)) {
        New-Item -ItemType Directory -Path $USER_DIRECTORY -Force | Out-Null
    }

    # --- Step 3: Install dependencies ---
    Write-Host "-> Checking and installing Python dependencies..."
    $reqFile = Join-Path $COMFYUI_PATH "requirements.txt"
    Install-PythonDeps -RequirementsFile $reqFile -UpgradeTorch
    Write-Host "Setup complete! You can now start ComfyUI using: .\comfyui.ps1 start"
}

# Updates ComfyUI core and all installed custom nodes from their git remotes
function Update-ComfyUI {
    Test-Dependencies
    $comfyUiUpdated = $false
    $comfyUiFailed = $false
    $updatedNodes = [System.Collections.Generic.List[string]]::new()
    $failedNodes = [System.Collections.Generic.List[string]]::new()
    Write-Host "Updating ComfyUI..."

    if (-not (Test-Path $COMFYUI_PATH)) {
        Write-Error "Error: ComfyUI directory not found at $COMFYUI_PATH"
        return $false
    }

    Write-Host "-> Pulling latest changes for ComfyUI repository..."
    Push-Location $COMFYUI_PATH
    try {
        # Check and resolve git dubious ownership (common across account migrations or drive moves)
        $ownerCheck = git rev-parse --git-dir 2>&1
        if ($ownerCheck -match "dubious ownership") {
            $safePath = ($COMFYUI_PATH -replace '\\', '/')
            Write-Host "  > Adding safe.directory exception for: $safePath"
            git config --global --add safe.directory $safePath
        }

        # Recover from detached HEAD if present
        $headRef = git symbolic-ref -q HEAD 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  > HEAD is detached. Attempting to switch to default branch."
            $hasMain = git show-ref --verify --quiet refs/heads/main 2>&1; $?
            $hasMaster = git show-ref --verify --quiet refs/heads/master 2>&1; $?

            if ($hasMain) {
                Write-Host "  > Switching to 'main' branch."
                git checkout main
            } elseif ($hasMaster) {
                Write-Host "  > Switching to 'master' branch."
                git checkout master
            } else {
                Write-Host "  ! Could not find 'main' or 'master' branch. Update skipped."
                throw "No default branch found"
            }
        }

        $pullOutput = git pull 2>&1
        $pullOutput | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to pull ComfyUI updates"
        }
        $comfyUiUpdated = ($pullOutput -notmatch "Already up to date")

        # Install/update Python requirements for ComfyUI core
        $reqFile = Join-Path $COMFYUI_PATH "requirements.txt"
        Install-PythonDeps -RequirementsFile $reqFile -UpgradeTorch
    } catch {
        Write-Error "  ! Failed to update or install requirements for ComfyUI. Please check manually."
        $comfyUiFailed = $true
    } finally {
        Pop-Location
    }

    # Update custom nodes
    $customNodesPath = Join-Path $COMFYUI_PATH "custom_nodes"
    if (-not (Test-Path $customNodesPath)) {
        Write-Host "-> Custom nodes directory not found. Skipping node updates."
    } else {
        Write-Host "-> Updating custom nodes..."
        Get-ChildItem -Path $customNodesPath -Directory | ForEach-Object {
            $nodeDir = $_.FullName
            $gitDir = Join-Path $nodeDir ".git"

            if (Test-Path $gitDir) {
                $nodeName = $_.Name
                Write-Host "  - Updating node: $nodeName"

                Push-Location $nodeDir
                try {
                    $ownerCheck = git rev-parse --git-dir 2>&1
                    if ($ownerCheck -match "dubious ownership") {
                        $safePath = ($nodeDir -replace '\\', '/')
                        Write-Host "    > Adding safe.directory exception for: $safePath"
                        git config --global --add safe.directory $safePath
                    }

                    $headRef = git symbolic-ref -q HEAD 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "    > HEAD is detached. Attempting to switch to default branch."
                        $hasMain = git show-ref --verify --quiet refs/heads/main 2>&1; $?
                        $hasMaster = git show-ref --verify --quiet refs/heads/master 2>&1; $?

                        if ($hasMain) {
                            Write-Host "    > Switching to 'main' branch."
                            git checkout main
                        } elseif ($hasMaster) {
                            Write-Host "    > Switching to 'master' branch."
                            git checkout master
                        } else {
                            Write-Host "    ! Could not find 'main' or 'master' branch. Update skipped."
                            throw "No default branch found"
                        }
                    }

                    $pullOutput = git pull 2>&1
                    $pullOutput | ForEach-Object { Write-Host "    $_" }
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to pull updates"
                    }

                    if ($pullOutput -notmatch "Already up to date") {
                        $updatedNodes.Add($nodeName)
                    }

                    $nodeReqFile = Join-Path $nodeDir "requirements.txt"
                    Install-PythonDeps -RequirementsFile $nodeReqFile
                } catch {
                    Write-Error "  ! Failed to update or install requirements for node: $nodeName. Please check manually."
                    $failedNodes.Add($nodeName)
                } finally {
                    Pop-Location
                }
            }
        }
    }

    # --- Update Report ---
    Write-Host ""
    Write-Host "===== Update Report =====" -ForegroundColor Cyan
    if ($comfyUiFailed) {
        Write-Host "  ComfyUI core:   FAILED" -ForegroundColor Red
    } elseif ($comfyUiUpdated) {
        Write-Host "  ComfyUI core:   Updated" -ForegroundColor Green
    } else {
        Write-Host "  ComfyUI core:   Already up to date"
    }
    Write-Host "  Custom nodes updated:  $($updatedNodes.Count)"
    if ($updatedNodes.Count -gt 0) {
        $updatedNodes | ForEach-Object { Write-Host "    + $_" -ForegroundColor Green }
    }
    Write-Host "  Custom nodes failed:   $($failedNodes.Count)"
    if ($failedNodes.Count -gt 0) {
        $failedNodes | ForEach-Object { Write-Host "    x $_" -ForegroundColor Red }
    }
    Write-Host "=========================" -ForegroundColor Cyan

    $updateHadErrors = $comfyUiFailed -or ($failedNodes.Count -gt 0)
    return (-not $updateHadErrors)
}

# Checks if the ComfyUI process is currently running based on the PID file
function Test-Running {
    if (Test-Path $PID_FILE) {
        $processId = Get-Content $PID_FILE -Raw
        $processId = $processId.Trim()
        try {
            $null = Get-Process -Id $processId -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }
    return $false
}

# Starts the ComfyUI server in the background
function Start-ComfyUI {
    if (Test-Running) {
        $processId = Get-Content $PID_FILE
        Write-Host "ComfyUI is already running with PID $processId."
        return
    }

    Write-Host "Starting ComfyUI... Log files: $LOG_FILE.out and $LOG_FILE.err"
    
    # Determine cross-attention flag based on GPU type
    $crossAttentionFlag = "--use-split-cross-attention"
    if (Test-AmdGpu) {
        $crossAttentionFlag = "--use-pytorch-cross-attention"
        Write-Host "-> Using PyTorch cross-attention for AMD ROCm"
        
        # Optimized ROCm environment flags
        # Default HSA_OVERRIDE_GFX_VERSION:
        # - 11.0.0 for RDNA3 (RX 7900 XTX / 7900 XT / 7800 XT / 7700 XT)
        # - 10.3.0 for RDNA2 (RX 6900 XT / 6800 XT / 6700 XT)
        $env:TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL = "1"
        $env:HSA_OVERRIDE_GFX_VERSION = "11.0.0"
        $env:HIP_FORCE_DEV_KERNARG = "1"
        $env:PYTORCH_ALLOC_CONF = "garbage_collection_threshold:0.8,max_split_size_mb:512"
        
        # Add ROCm DLL directories to PATH so Windows can resolve dynamic link dependencies
        $venvSitePackages = Join-Path $COMFYUI_PATH "venv-3.12\Lib\site-packages"
        $dllPaths = @(
            (Join-Path $venvSitePackages "_rocm_sdk_core\bin"),
            (Join-Path $venvSitePackages "_rocm_sdk_libraries_custom\bin")
        )
        $rocmBin = Get-ChildItem "C:\Program Files\AMD\ROCm" -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1 |
            ForEach-Object { Join-Path $_.FullName "bin" }
        if ($rocmBin) {
            $dllPaths += $rocmBin
        }
        foreach ($p in $dllPaths) {
            if (Test-Path $p) {
                $currentPaths = $env:PATH -split ';'
                if ($p -notin $currentPaths) {
                    $env:PATH = "$p;$env:PATH"
                    Write-Host "-> Added to PATH: $p"
                }
            }
        }
    }
    
    # Build complete startup options with cross-attention flag
    $completeStartupOptions = @($crossAttentionFlag) + $STARTUP_OPTIONS
    
    # Start the process in the background, redirecting output to log files
    $stdoutLog = "$LOG_FILE.out"
    $stderrLog = "$LOG_FILE.err"
    $processArgs = @($MAIN_SCRIPT) + $completeStartupOptions
    $process = Start-Process -FilePath $PYTHON_EXEC `
        -ArgumentList $processArgs `
        -WorkingDirectory $COMFYUI_PATH `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -WindowStyle Hidden `
        -PassThru

    # Store the PID
    $process.Id | Out-File -FilePath $PID_FILE -NoNewline

    # Check that process started successfully
    Start-Sleep -Seconds 2
    if (-not (Test-Running)) {
        Write-Error "Error: ComfyUI failed to start. Check the logs for details."
        Write-Host "Stdout: $stdoutLog"
        Write-Host "Stderr: $stderrLog"
        Remove-Item $PID_FILE -ErrorAction SilentlyContinue
        return
    }

    Write-Host "ComfyUI started successfully with PID: $($process.Id)"
    Write-Host "Stdout: $stdoutLog"
    Write-Host "Stderr: $stderrLog"
}

# Stops the ComfyUI server gracefully with a timeout fallback
function Stop-ComfyUI {
    if (-not (Test-Running)) {
        Write-Host "ComfyUI is not running."
        Remove-Item $PID_FILE -ErrorAction SilentlyContinue
        return
    }

    $processId = (Get-Content $PID_FILE -Raw).Trim()
    Write-Host "Stopping ComfyUI (PID: $processId)..."

    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        
        # Attempt graceful window shutdown
        $process.CloseMainWindow() | Out-Null
        
        # Wait up to 5 seconds for normal termination
        $waited = $process.WaitForExit(5000)
        
        if ($waited) {
            Write-Host "ComfyUI stopped."
        } else {
            Write-Host "ComfyUI did not terminate within 5 seconds. Forcing shutdown..."
            Stop-Process -Id $processId -Force
            Write-Host "ComfyUI stopped forcefully."
        }
    } catch {
        Write-Host "Process not found or already terminated."
    } finally {
        Remove-Item $PID_FILE -ErrorAction SilentlyContinue
    }
}

# Takes ownership of the ComfyUI directory tree by the current user
# Fixes ACL permission issues and SID mismatches after reinstalling Windows or migrating drives
function Repair-Ownership {
    Write-Host "-> Taking ownership of: $COMFYUI_PATH"
    Write-Host "   This may take a moment for large directories..."

    takeown /f $COMFYUI_PATH /r /d y 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "takeown failed. Try running this script from an elevated PowerShell prompt (Run as Administrator)."
        return
    }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    icacls $COMFYUI_PATH /grant "${currentUser}:(OI)(CI)F" /t /q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "icacls failed. Try running this script from an elevated PowerShell prompt (Run as Administrator)."
        return
    }

    Write-Host "-> Ownership transferred to: $currentUser"
    Write-Host "-> Run 'update' or 'start' again to proceed normally."
}

# Displays the current server running status
function Show-Status {
    if (Test-Running) {
        $processId = (Get-Content $PID_FILE -Raw).Trim()
        Write-Host "ComfyUI is running with PID $processId."
    } else {
        Write-Host "ComfyUI is stopped."
    }
}

# --- Main Logic ---

$command = if ($args.Count -gt 0) { $args[0] } else { "status" }

switch ($command.ToLower()) {
    "start" {
        Start-ComfyUI
    }
    "stop" {
        Stop-ComfyUI
    }
    "restart" {
        Stop-ComfyUI
        Start-ComfyUI
    }
    "install" {
        Install-ComfyUI
    }
    "update" {
        $wasRunning = Test-Running
        if ($wasRunning) {
            Write-Host "-> ComfyUI is running. Stopping before update..."
            Stop-ComfyUI
        }

        $updateSuccess = Update-ComfyUI
        if ($updateSuccess -and $wasRunning) {
            Write-Host "-> Restarting ComfyUI after successful update..."
            Start-ComfyUI
        } elseif (-not $updateSuccess) {
            Write-Error "Error: Update failed. ComfyUI will not be restarted. Please inspect logs."
        }
    }
    "status" {
        Show-Status
    }
    "fix-ownership" {
        Repair-Ownership
    }
    default {
        $scriptName = Split-Path $MyInvocation.MyCommand.Path -Leaf
        Write-Host "Usage: .\$scriptName {start|stop|restart|status|update|install|fix-ownership}"
        exit 1
    }
}
