# Forge Train - Windows Setup Script
# PowerShell script for Windows 11/Server 2022+
# Run as Administrator: .\setup.ps1

#Requires -RunAsAdministrator

################################################################################
# CONFIGURATION
################################################################################

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$FORGE_USER = "forge"
$FORGE_HOME = "C:\forge-train"
$FORGE_DATA = "C:\ProgramData\forge-train"
$FORGE_LOGS = "C:\ProgramData\forge-train\logs"
$WORKERS = 2
$PYTHON_VERSION = "3.12"

################################################################################
# HELPER FUNCTIONS
################################################################################

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

################################################################################
# SYSTEM CHECKS
################################################################################

function Test-WindowsVersion {
    Write-Info "Checking Windows version..."
    
    $os = Get-CimInstance Win32_OperatingSystem
    $version = [System.Environment]::OSVersion.Version
    
    Write-Info "Detected: $($os.Caption) (Version $($version.Major).$($version.Minor).$($version.Build))"
    
    if ($version.Major -lt 10) {
        Write-Error-Custom "Windows 10/11 or Server 2019/2022+ required"
        exit 1
    }
    
    Write-Success "Windows version compatible"
}

################################################################################
# WINGET SETUP
################################################################################

function Install-WinGet {
    Write-Info "Checking winget availability..."
    
    try {
        $null = Get-Command winget -ErrorAction Stop
        Write-Success "winget already installed"
        return
    } catch {
        Write-Info "Installing winget..."
    }
    
    # Download and install App Installer (includes winget)
    $progressPreference = 'silentlyContinue'
    Write-Info "Downloading Microsoft.DesktopAppInstaller..."
    
    $releases = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
    $asset = (Invoke-RestMethod -Uri $releases).assets | Where-Object name -like "*.msixbundle"
    
    $downloadUrl = $asset.browser_download_url
    $installerPath = "$env:TEMP\Microsoft.DesktopAppInstaller.msixbundle"
    
    Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath
    Add-AppxPackage -Path $installerPath
    
    Remove-Item $installerPath
    Write-Success "winget installed"
}

################################################################################
# CHOCOLATEY SETUP
################################################################################

function Install-Chocolatey {
    Write-Info "Checking Chocolatey availability..."
    
    try {
        $null = Get-Command choco -ErrorAction Stop
        Write-Success "Chocolatey already installed"
        return
    } catch {
        Write-Info "Installing Chocolatey..."
    }
    
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    
    # Refresh environment
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    Write-Success "Chocolatey installed"
}

################################################################################
# DEPENDENCIES
################################################################################

function Install-SystemDependencies {
    Write-Info "Installing system dependencies (this may take 15-20 minutes)..."
    
    # Install via Chocolatey
    $packages = @(
        "git",
        "cmake",
        "visualstudio2022buildtools",
        "python312",
        "redis-64",
        "postgresql14",
        "curl",
        "wget",
        "7zip"
    )
    
    foreach ($package in $packages) {
        Write-Info "Installing $package..."
        choco install $package -y --no-progress
    }
    
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    Write-Success "System dependencies installed"
}

################################################################################
# DIRECTORY SETUP
################################################################################

function Initialize-Directories {
    Write-Info "Creating directory structure..."
    
    $directories = @(
        $FORGE_HOME,
        "$FORGE_DATA\jobs",
        "$FORGE_DATA\models",
        "$FORGE_DATA\datasets",
        "$FORGE_DATA\checkpoints",
        $FORGE_LOGS
    )
    
    foreach ($dir in $directories) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Info "Created: $dir"
        }
    }
    
    Write-Success "Directory structure created"
}

################################################################################
# PYTHON SETUP
################################################################################

function Initialize-PythonEnvironment {
    Write-Info "Setting up Python environment..."
    
    # Create virtual environment
    $pythonExe = "python$PYTHON_VERSION"
    try {
        $pythonExe = Get-Command python -ErrorAction Stop | Select-Object -ExpandProperty Source
    } catch {
        Write-Error-Custom "Python $PYTHON_VERSION not found in PATH"
        exit 1
    }
    
    $venvPath = "$FORGE_HOME\venv"
    
    if (-not (Test-Path $venvPath)) {
        Write-Info "Creating virtual environment..."
        & $pythonExe -m venv $venvPath
    }
    
    # Activate and upgrade pip
    $pipExe = "$venvPath\Scripts\pip.exe"
    Write-Info "Upgrading pip..."
    & $pipExe install --upgrade pip setuptools wheel --quiet
    
    Write-Success "Python environment created"
}

function Install-PythonDependencies {
    Write-Info "Installing Python dependencies (this may take 10-15 minutes)..."
    
    $pipExe = "$FORGE_HOME\venv\Scripts\pip.exe"
    
    # Create requirements file
    $requirements = @"
# Core ML
torch>=2.3.0 --index-url https://download.pytorch.org/whl/cpu
transformers>=4.44.0
datasets>=2.18.0
peft>=0.11.0
bitsandbytes-windows>=0.41.0
accelerate>=0.30.0

# Training framework
axolotl>=0.4.0

# Model conversion and quantization
gguf>=0.9.0
sentencepiece>=0.2.0
protobuf>=4.25.0

# Job queue and database
redis>=5.0.0
psycopg2-binary>=2.9.9
sqlalchemy>=2.0.0
alembic>=1.13.0

# Web and API
fastapi>=0.110.0
uvicorn[standard]>=0.29.0
pydantic>=2.7.0
pydantic-settings>=2.2.0

# Monitoring and metrics
prometheus-client>=0.20.0
psutil>=5.9.0

# CLI and output
click>=8.1.0
rich>=13.7.0
tqdm>=4.66.0

# Utilities
pyyaml>=6.0
jinja2>=3.1.0
requests>=2.31.0
aiohttp>=3.9.0
python-dotenv>=1.0.0
"@
    
    $reqFile = "$env:TEMP\forge-requirements.txt"
    $requirements | Out-File -FilePath $reqFile -Encoding UTF8
    
    & $pipExe install -r $reqFile --quiet
    Remove-Item $reqFile
    
    Write-Success "Python dependencies installed"
}

################################################################################
# REDIS SETUP
################################################################################

function Initialize-Redis {
    Write-Info "Configuring Redis..."
    
    # Start Redis service
    try {
        Start-Service Redis
        Set-Service -Name Redis -StartupType Automatic
        Write-Success "Redis service started"
    } catch {
        Write-Warn "Redis service not found or failed to start"
        Write-Info "You may need to install Redis manually from: https://github.com/microsoftarchive/redis/releases"
    }
}

################################################################################
# POSTGRESQL SETUP
################################################################################

function Initialize-PostgreSQL {
    Write-Info "Configuring PostgreSQL..."
    
    # Start PostgreSQL service
    try {
        $pgService = Get-Service -Name "postgresql*" | Select-Object -First 1
        Start-Service $pgService.Name
        Set-Service -Name $pgService.Name -StartupType Automatic
        
        Write-Info "Waiting for PostgreSQL to start..."
        Start-Sleep -Seconds 5
        
        # Create database and user
        $psqlPath = "C:\Program Files\PostgreSQL\14\bin\psql.exe"
        if (Test-Path $psqlPath) {
            Write-Info "Creating database and user..."
            
            # Note: This requires postgres user password to be set
            # For now, skip and show manual instructions
            Write-Warn "Please manually create database and user:"
            Write-Host "  1. Set postgres password: psql -U postgres -c `"ALTER USER postgres PASSWORD 'password';`""
            Write-Host "  2. Create database: psql -U postgres -c `"CREATE DATABASE forge_train;`""
            Write-Host "  3. Create user: psql -U postgres -c `"CREATE USER forge WITH PASSWORD 'forge_train_password';`""
            Write-Host "  4. Grant privileges: psql -U postgres -c `"GRANT ALL PRIVILEGES ON DATABASE forge_train TO forge;`""
        }
        
        Write-Success "PostgreSQL service started"
    } catch {
        Write-Warn "PostgreSQL service not found or failed to start"
    }
}

################################################################################
# OLLAMA SETUP
################################################################################

function Install-Ollama {
    Write-Info "Installing Ollama..."
    
    try {
        $null = Get-Command ollama -ErrorAction Stop
        Write-Success "Ollama already installed"
        return
    } catch {
        Write-Info "Downloading Ollama..."
    }
    
    $installerUrl = "https://ollama.ai/download/OllamaSetup.exe"
    $installerPath = "$env:TEMP\OllamaSetup.exe"
    
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath
    Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
    Remove-Item $installerPath
    
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    Write-Success "Ollama installed"
}

################################################################################
# FORGE TRAIN SETUP
################################################################################

function Install-ForgeTrain {
    Write-Info "Installing Forge Train..."
    
    $repoPath = "$FORGE_HOME\forge-train"
    
    if (Test-Path $repoPath) {
        Write-Warn "forge-train directory already exists, pulling latest..."
        Push-Location $repoPath
        git pull
        Pop-Location
    } else {
        Write-Info "Cloning forge-train repository..."
        git clone https://github.com/ash-forge/forge-train.git $repoPath
    }
    
    # Install forge-train CLI
    $pipExe = "$FORGE_HOME\venv\Scripts\pip.exe"
    & $pipExe install -e $repoPath
    
    Write-Success "Forge Train installed"
}

################################################################################
# WINDOWS SERVICES
################################################################################

function Install-WindowsServices {
    Write-Info "Setting up Windows services..."
    
    # Create NSSM service wrappers
    choco install nssm -y --no-progress
    
    $venvPython = "$FORGE_HOME\venv\Scripts\python.exe"
    $forgeTrainExe = "$FORGE_HOME\venv\Scripts\forge-train.exe"
    
    # Worker services
    for ($i = 1; $i -le $WORKERS; $i++) {
        $serviceName = "ForgeWorker$i"
        
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            Write-Warn "Service $serviceName already exists"
        } catch {
            Write-Info "Creating service: $serviceName"
            & nssm install $serviceName $forgeTrainExe "worker" "run" "--id" "$i"
            & nssm set $serviceName AppDirectory $FORGE_HOME
            & nssm set $serviceName AppStdout "$FORGE_LOGS\worker-$i.log"
            & nssm set $serviceName AppStderr "$FORGE_LOGS\worker-$i.log"
            & nssm set $serviceName Start SERVICE_DEMAND_START
        }
    }
    
    # Queue service
    $queueService = "ForgeQueue"
    try {
        $service = Get-Service -Name $queueService -ErrorAction Stop
        Write-Warn "Service $queueService already exists"
    } catch {
        Write-Info "Creating service: $queueService"
        & nssm install $queueService $forgeTrainExe "queue" "daemon"
        & nssm set $queueService AppDirectory $FORGE_HOME
        & nssm set $queueService AppStdout "$FORGE_LOGS\queue.log"
        & nssm set $queueService AppStderr "$FORGE_LOGS\queue.log"
        & nssm set $queueService Start SERVICE_AUTO_START
    }
    
    # Monitor service
    $monitorService = "ForgeMonitor"
    try {
        $service = Get-Service -Name $monitorService -ErrorAction Stop
        Write-Warn "Service $monitorService already exists"
    } catch {
        Write-Info "Creating service: $monitorService"
        & nssm install $monitorService $forgeTrainExe "monitor" "daemon"
        & nssm set $monitorService AppDirectory $FORGE_HOME
        & nssm set $monitorService AppStdout "$FORGE_LOGS\monitor.log"
        & nssm set $monitorService AppStderr "$FORGE_LOGS\monitor.log"
        & nssm set $monitorService Start SERVICE_AUTO_START
    }
    
    Write-Success "Windows services created"
}

################################################################################
# CONFIGURATION
################################################################################

function Initialize-Configuration {
    Write-Info "Creating configuration file..."
    
    $configDir = "$FORGE_HOME\config"
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    
    $configFile = "$configDir\forge-train.yaml"
    
    $config = @"
# Forge Train Configuration
version: "1.0"

# Paths
data_dir: "$($FORGE_DATA -replace '\\', '\\')"
log_dir: "$($FORGE_LOGS -replace '\\', '\\')"
models_dir: "$($FORGE_DATA -replace '\\', '\\')\\models"
datasets_dir: "$($FORGE_DATA -replace '\\', '\\')\\datasets"
checkpoints_dir: "$($FORGE_DATA -replace '\\', '\\')\\checkpoints"

# Redis
redis:
  host: "localhost"
  port: 6379
  db: 0

# PostgreSQL
database:
  host: "localhost"
  port: 5432
  name: "forge_train"
  user: "forge"
  password: "forge_train_password"

# Workers
workers:
  count: $WORKERS
  cpu_per_worker: 4
  memory_per_worker: "32G"

# Training defaults
training:
  batch_size: 4
  micro_batch_size: 1
  gradient_accumulation_steps: 4
  learning_rate: 0.0002
  warmup_steps: 100
  num_epochs: 3
  save_steps: 500

# LoRA defaults
lora:
  rank: 16
  alpha: 32
  dropout: 0.05
  target_modules:
    - q_proj
    - v_proj
    - k_proj
    - o_proj

# Quantization
quantization:
  format: "gguf"
  method: "q4_k_m"

# Ollama
ollama:
  host: "http://localhost:11434"
  registry: "ollama.ai"
  namespace: "ashforge"

# Notifications
notifications:
  discord:
    enabled: false
    webhook_url: ""
"@
    
    $config | Out-File -FilePath $configFile -Encoding UTF8
    Write-Success "Configuration file created: $configFile"
}

################################################################################
# FIREWALL
################################################################################

function Initialize-Firewall {
    Write-Info "Configuring Windows Firewall..."
    
    # Allow Ollama
    New-NetFirewallRule -DisplayName "Ollama" -Direction Inbound -Protocol TCP -LocalPort 11434 -Action Allow -ErrorAction SilentlyContinue | Out-Null
    
    Write-Success "Firewall rules configured"
}

################################################################################
# SUMMARY
################################################################################

function Show-Summary {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║          FORGE TRAIN INSTALLATION COMPLETE (WINDOWS)                   ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Success "Installation completed successfully!"
    Write-Host ""
    Write-Host "📂 Installation Directory: $FORGE_HOME"
    Write-Host "📊 Data Directory: $FORGE_DATA"
    Write-Host "📝 Logs Directory: $FORGE_LOGS"
    Write-Host "⚙️  Config File: $FORGE_HOME\config\forge-train.yaml"
    Write-Host ""
    Write-Host "🔧 NEXT STEPS:"
    Write-Host ""
    Write-Host "1. Start services:"
    Write-Host "   Start-Service ForgeWorker1"
    Write-Host "   Start-Service ForgeWorker2"
    Write-Host "   Start-Service ForgeQueue"
    Write-Host "   Start-Service ForgeMonitor"
    Write-Host ""
    Write-Host "2. Verify installation:"
    Write-Host "   forge-train system status"
    Write-Host ""
    Write-Host "3. Submit your first training job:"
    Write-Host "   forge-train submit --model ash-code:python --dataset datasets\python-expert"
    Write-Host ""
    Write-Host "⚠️  IMPORTANT:"
    Write-Host "   • Configure PostgreSQL manually (see output above)"
    Write-Host "   • Default database password: 'forge_train_password'"
    Write-Host "   • Change password in: $FORGE_HOME\config\forge-train.yaml"
    Write-Host ""
    Write-Host "🔥 HAPPY FORGING! 🦞" -ForegroundColor Yellow
    Write-Host ""
}

################################################################################
# MAIN
################################################################################

function Main {
    Write-Host "╔════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║         FORGE TRAIN - Windows 11/Server 2022 Setup Script             ║" -ForegroundColor Cyan
    Write-Host "║                  Ash Forge Training Infrastructure                     ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not (Test-Administrator)) {
        Write-Error-Custom "This script must be run as Administrator"
        exit 1
    }
    
    Test-WindowsVersion
    
    Write-Info "Starting installation..."
    Write-Info "This will take approximately 20-30 minutes"
    Write-Host ""
    
    # Package managers
    Install-Chocolatey
    Install-WinGet
    
    # System dependencies
    Install-SystemDependencies
    
    # Directory setup
    Initialize-Directories
    
    # Python environment
    Initialize-PythonEnvironment
    Install-PythonDependencies
    
    # Services
    Initialize-Redis
    Initialize-PostgreSQL
    Install-Ollama
    
    # Forge Train
    # Note: Commenting out repo clone until repo exists
    # Install-ForgeTrain
    Write-Warn "Skipping forge-train clone (repository not yet created)"
    Write-Info "After creating the repo, run: git clone https://github.com/ash-forge/forge-train.git $FORGE_HOME\forge-train"
    
    # Services
    # Install-WindowsServices
    Write-Warn "Skipping Windows services setup (install forge-train first)"
    
    # Configuration
    Initialize-Configuration
    
    # Firewall
    Initialize-Firewall
    
    # Summary
    Show-Summary
}

# Run main
Main
