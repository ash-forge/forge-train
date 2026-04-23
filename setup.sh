#!/bin/bash
set -euo pipefail

# Forge Train - Ubuntu 26.04 LTS Setup Script
# Installs and configures complete training infrastructure for Ash Forge
# Usage: sudo ./setup.sh

################################################################################
# CONFIGURATION
################################################################################

FORGE_USER="${FORGE_USER:-forge}"
FORGE_HOME="/opt/forge-train"
FORGE_DATA="/var/lib/forge-train"
FORGE_LOGS="/var/log/forge-train"
WORKERS="${WORKERS:-2}"
PYTHON_VERSION="3.12"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# HELPER FUNCTIONS
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

check_ubuntu_version() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS version"
        exit 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_error "This script is designed for Ubuntu 26.04 LTS"
        log_warn "Detected: $ID $VERSION_ID"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    log_info "Detected: Ubuntu $VERSION_ID ($VERSION_CODENAME)"
}

################################################################################
# SYSTEM SETUP
################################################################################

install_system_dependencies() {
    log_info "Installing system dependencies..."
    
    apt-get update
    apt-get install -y \
        build-essential \
        cmake \
        git \
        curl \
        wget \
        htop \
        tmux \
        vim \
        jq \
        redis-server \
        postgresql \
        postgresql-contrib \
        nginx \
        python${PYTHON_VERSION} \
        python${PYTHON_VERSION}-dev \
        python${PYTHON_VERSION}-venv \
        python3-pip \
        libopenblas-dev \
        libgomp1 \
        ccache
    
    log_success "System dependencies installed"
}

setup_user() {
    log_info "Creating forge user..."
    
    if id "$FORGE_USER" &>/dev/null; then
        log_warn "User $FORGE_USER already exists"
    else
        useradd -r -m -d "$FORGE_HOME" -s /bin/bash "$FORGE_USER"
        log_success "Created user: $FORGE_USER"
    fi
    
    # Create directories
    mkdir -p "$FORGE_HOME"
    mkdir -p "$FORGE_DATA"/{jobs,models,datasets,checkpoints}
    mkdir -p "$FORGE_LOGS"
    
    chown -R "$FORGE_USER:$FORGE_USER" "$FORGE_HOME"
    chown -R "$FORGE_USER:$FORGE_USER" "$FORGE_DATA"
    chown -R "$FORGE_USER:$FORGE_USER" "$FORGE_LOGS"
    
    log_success "Directory structure created"
}

################################################################################
# PYTHON SETUP
################################################################################

setup_python_environment() {
    log_info "Setting up Python environment..."
    
    # Create virtual environment
    su - "$FORGE_USER" -c "python${PYTHON_VERSION} -m venv $FORGE_HOME/venv"
    
    # Upgrade pip
    su - "$FORGE_USER" -c "$FORGE_HOME/venv/bin/pip install --upgrade pip setuptools wheel"
    
    log_success "Python virtual environment created"
}

install_python_dependencies() {
    log_info "Installing Python dependencies (this may take 10-15 minutes)..."
    
    # Create requirements.txt
    cat > /tmp/forge-requirements.txt <<'EOF'
# Core ML
torch>=2.3.0
transformers>=4.44.0
datasets>=2.18.0
peft>=0.11.0
bitsandbytes>=0.43.0

# Training framework
axolotl>=0.4.0

# Model conversion and quantization
gguf>=0.9.0
sentencepiece>=0.2.0

# Job queue and database
redis>=5.0.0
psycopg2-binary>=2.9.9
sqlalchemy>=2.0.0

# Web and API
fastapi>=0.110.0
uvicorn[standard]>=0.29.0
pydantic>=2.7.0

# Monitoring and metrics
prometheus-client>=0.20.0
psutil>=5.9.0

# Utilities
pyyaml>=6.0
jinja2>=3.1.0
click>=8.1.0
rich>=13.7.0
tqdm>=4.66.0
requests>=2.31.0
EOF
    
    # Install in virtual environment
    su - "$FORGE_USER" -c "$FORGE_HOME/venv/bin/pip install -r /tmp/forge-requirements.txt"
    
    rm /tmp/forge-requirements.txt
    log_success "Python dependencies installed"
}

################################################################################
# REDIS SETUP
################################################################################

setup_redis() {
    log_info "Configuring Redis..."
    
    # Backup original config
    cp /etc/redis/redis.conf /etc/redis/redis.conf.backup
    
    # Configure Redis for job queue
    cat >> /etc/redis/redis.conf <<'EOF'

# Forge Train Configuration
maxmemory 2gb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
save 60 10000
EOF
    
    systemctl enable redis-server
    systemctl restart redis-server
    
    log_success "Redis configured and started"
}

################################################################################
# POSTGRESQL SETUP
################################################################################

setup_postgresql() {
    log_info "Configuring PostgreSQL..."
    
    # Start PostgreSQL
    systemctl enable postgresql
    systemctl start postgresql
    
    # Create database and user
    su - postgres -c "psql -c \"CREATE DATABASE forge_train;\" 2>/dev/null || true"
    su - postgres -c "psql -c \"CREATE USER $FORGE_USER WITH PASSWORD 'forge_train_password';\" 2>/dev/null || true"
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE forge_train TO $FORGE_USER;\""
    
    log_success "PostgreSQL database created"
    log_warn "Default password: 'forge_train_password' - Please change in production!"
}

################################################################################
# OLLAMA SETUP
################################################################################

install_ollama() {
    log_info "Installing Ollama..."
    
    # Download and install Ollama
    curl -fsSL https://ollama.ai/install.sh | sh
    
    # Create systemd service for Ollama
    cat > /etc/systemd/system/ollama.service <<EOF
[Unit]
Description=Ollama Service
After=network.target

[Service]
Type=simple
User=$FORGE_USER
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_MODELS=$FORGE_DATA/models"

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable ollama
    systemctl start ollama
    
    log_success "Ollama installed and started"
}

################################################################################
# FORGE TRAIN SETUP
################################################################################

install_forge_train() {
    log_info "Installing Forge Train CLI..."
    
    # Clone repository (or copy local files)
    if [[ -d "$FORGE_HOME/forge-train" ]]; then
        log_warn "forge-train directory already exists, pulling latest..."
        cd "$FORGE_HOME/forge-train"
        su - "$FORGE_USER" -c "cd $FORGE_HOME/forge-train && git pull"
    else
        log_info "Cloning forge-train repository..."
        su - "$FORGE_USER" -c "git clone https://github.com/ash-forge/forge-train.git $FORGE_HOME/forge-train"
    fi
    
    # Install forge-train CLI
    su - "$FORGE_USER" -c "$FORGE_HOME/venv/bin/pip install -e $FORGE_HOME/forge-train"
    
    # Create symlink for easy access
    ln -sf "$FORGE_HOME/venv/bin/forge-train" /usr/local/bin/forge-train
    
    log_success "Forge Train CLI installed"
}

setup_systemd_services() {
    log_info "Setting up systemd services..."
    
    # Worker service template
    cat > /etc/systemd/system/forge-worker@.service <<EOF
[Unit]
Description=Forge Train Worker %i
After=network.target redis-server.service postgresql.service

[Service]
Type=simple
User=$FORGE_USER
WorkingDirectory=$FORGE_HOME
Environment="PATH=$FORGE_HOME/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$FORGE_HOME/venv/bin/forge-train worker run --id %i
Restart=always
RestartSec=10

# Resource limits (per worker)
CPUQuota=400%
MemoryMax=32G
TasksMax=1000

# Logging
StandardOutput=append:$FORGE_LOGS/worker-%i.log
StandardError=append:$FORGE_LOGS/worker-%i.log

[Install]
WantedBy=multi-user.target
EOF
    
    # Queue service
    cat > /etc/systemd/system/forge-queue.service <<EOF
[Unit]
Description=Forge Train Queue Manager
After=network.target redis-server.service postgresql.service

[Service]
Type=simple
User=$FORGE_USER
WorkingDirectory=$FORGE_HOME
Environment="PATH=$FORGE_HOME/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$FORGE_HOME/venv/bin/forge-train queue daemon
Restart=always
RestartSec=5

StandardOutput=append:$FORGE_LOGS/queue.log
StandardError=append:$FORGE_LOGS/queue.log

[Install]
WantedBy=multi-user.target
EOF
    
    # Monitoring service
    cat > /etc/systemd/system/forge-monitor.service <<EOF
[Unit]
Description=Forge Train Monitor
After=network.target

[Service]
Type=simple
User=$FORGE_USER
WorkingDirectory=$FORGE_HOME
Environment="PATH=$FORGE_HOME/venv/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$FORGE_HOME/venv/bin/forge-train monitor daemon
Restart=always
RestartSec=5

StandardOutput=append:$FORGE_LOGS/monitor.log
StandardError=append:$FORGE_LOGS/monitor.log

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    
    log_success "Systemd services created"
}

################################################################################
# FIREWALL SETUP
################################################################################

setup_firewall() {
    log_info "Configuring firewall..."
    
    # Install ufw if not present
    apt-get install -y ufw
    
    # Configure basic rules
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH
    ufw allow 22/tcp comment 'SSH'
    
    # Allow Ollama (if exposing externally)
    # ufw allow 11434/tcp comment 'Ollama'
    
    # Enable firewall
    ufw --force enable
    
    log_success "Firewall configured"
}

################################################################################
# FINAL CONFIGURATION
################################################################################

create_config_file() {
    log_info "Creating default configuration..."
    
    mkdir -p "$FORGE_HOME/config"
    
    cat > "$FORGE_HOME/config/forge-train.yaml" <<EOF
# Forge Train Configuration
version: "1.0"

# Paths
data_dir: "$FORGE_DATA"
log_dir: "$FORGE_LOGS"
models_dir: "$FORGE_DATA/models"
datasets_dir: "$FORGE_DATA/datasets"
checkpoints_dir: "$FORGE_DATA/checkpoints"

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
  user: "$FORGE_USER"
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
EOF
    
    chown "$FORGE_USER:$FORGE_USER" "$FORGE_HOME/config/forge-train.yaml"
    
    log_success "Configuration file created: $FORGE_HOME/config/forge-train.yaml"
}

print_summary() {
    echo
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║                    FORGE TRAIN INSTALLATION COMPLETE                   ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo
    log_success "Installation completed successfully!"
    echo
    echo "📂 Installation Directory: $FORGE_HOME"
    echo "📊 Data Directory: $FORGE_DATA"
    echo "📝 Logs Directory: $FORGE_LOGS"
    echo "⚙️  Config File: $FORGE_HOME/config/forge-train.yaml"
    echo
    echo "🔧 NEXT STEPS:"
    echo
    echo "1. Start workers:"
    echo "   sudo systemctl start forge-worker@{1..$WORKERS}"
    echo "   sudo systemctl enable forge-worker@{1..$WORKERS}"
    echo
    echo "2. Start queue manager:"
    echo "   sudo systemctl start forge-queue"
    echo "   sudo systemctl enable forge-queue"
    echo
    echo "3. Start monitoring:"
    echo "   sudo systemctl start forge-monitor"
    echo "   sudo systemctl enable forge-monitor"
    echo
    echo "4. Verify installation:"
    echo "   forge-train system status"
    echo
    echo "5. Submit your first training job:"
    echo "   forge-train submit --model ash-code:python --dataset datasets/python-expert"
    echo
    echo "📚 DOCUMENTATION:"
    echo "   • Installation: $FORGE_HOME/forge-train/docs/INSTALLATION.md"
    echo "   • Training Guide: $FORGE_HOME/forge-train/docs/TRAINING.md"
    echo "   • Troubleshooting: $FORGE_HOME/forge-train/docs/TROUBLESHOOTING.md"
    echo
    echo "⚠️  IMPORTANT:"
    echo "   • Default database password: 'forge_train_password'"
    echo "   • Change password in: $FORGE_HOME/config/forge-train.yaml"
    echo "   • Update PostgreSQL password: sudo -u postgres psql -c \"ALTER USER $FORGE_USER PASSWORD 'new_password';\""
    echo
    echo "🔥 HAPPY FORGING! 🦞"
    echo
}

################################################################################
# MAIN EXECUTION
################################################################################

main() {
    echo "╔════════════════════════════════════════════════════════════════════════╗"
    echo "║              FORGE TRAIN - Ubuntu 26.04 LTS Setup Script              ║"
    echo "║                    Ash Forge Training Infrastructure                   ║"
    echo "╚════════════════════════════════════════════════════════════════════════╝"
    echo
    
    check_root
    check_ubuntu_version
    
    log_info "Starting installation..."
    log_info "This will take approximately 15-20 minutes"
    echo
    
    # System setup
    install_system_dependencies
    setup_user
    
    # Python environment
    setup_python_environment
    install_python_dependencies
    
    # Services
    setup_redis
    setup_postgresql
    install_ollama
    
    # Forge Train
    # Note: Commenting out repo clone since repo doesn't exist yet
    # install_forge_train
    log_warn "Skipping forge-train clone (repository not yet created)"
    log_info "After creating the repo, run: su - forge -c 'git clone https://github.com/ash-forge/forge-train.git /opt/forge-train/forge-train'"
    
    setup_systemd_services
    
    # Security
    setup_firewall
    
    # Configuration
    create_config_file
    
    # Summary
    print_summary
}

# Run main function
main "$@"
