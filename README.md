# Forge Train 🦞🔥

**Automated training infrastructure for Ash Forge**

Forge Train is a complete training pipeline for fine-tuning, quantizing, and publishing specialized AI models for the Ash Forge ecosystem.

---

## 🚀 Quick Start

### 1. Installation

**One-command setup on Ubuntu 26.04 LTS:**

```bash
curl -sSL https://raw.githubusercontent.com/ash-forge/forge-train/main/setup.sh | sudo bash
```

This installs:
- Python 3.12 + PyTorch (CPU)
- Redis (job queue)
- PostgreSQL (job history)
- Ollama (model serving)
- Forge Train CLI

### 2. Start Workers

```bash
# Start 2 training workers
sudo systemctl start forge-worker@{1..2}
sudo systemctl enable forge-worker@{1..2}

# Start queue manager
sudo systemctl start forge-queue
sudo systemctl enable forge-queue
```

### 3. Submit Training Job

```bash
forge-train submit \
  --model ash-code:python \
  --dataset datasets/python-expert \
  --epochs 3 \
  --notify discord
```

### 4. Monitor Progress

```bash
# Check queue
forge-train queue list

# Check job status
forge-train status job_12345

# System resources
forge-train system resources
```

---

## 📋 Features

✅ **One-Command Setup** - Complete installation in 15 minutes  
✅ **Parallel Training** - Run 2+ models simultaneously  
✅ **Full Automation** - Dataset → Training → Quantization → Publishing  
✅ **CPU Optimized** - Efficient LoRA fine-tuning on CPU  
✅ **Queue System** - Priority-based job scheduling  
✅ **Monitoring** - Real-time metrics and progress tracking  
✅ **Discord Notifications** - Get notified when training completes  
✅ **Checkpoint Recovery** - Auto-resume from failures  

---

## 🎯 How It Works

### 1. Submit Job

```bash
forge-train submit --model ash-code:python --dataset datasets/python-expert
```

The job is added to the Redis queue with your specified priority.

### 2. Worker Picks Up Job

A worker pulls the job from the queue and:
1. Downloads the base model (`gemma4:turbo`)
2. Validates and prepares the dataset
3. Configures LoRA training parameters
4. Starts training with Axolotl

### 3. Training Runs (24-72 hours)

The worker:
- Checkpoints every 500 steps
- Logs loss curves and metrics
- Monitors CPU/memory usage
- Can auto-resume if interrupted

### 4. Post-Processing

After training completes:
1. Merge LoRA adapters with base model
2. Quantize to GGUF Q4_K_M (3GB size)
3. Package as Ollama model
4. Push to registry
5. Send Discord notification

### 5. Model Ready!

```bash
ollama pull ashforge/ash-code:python
```

---

## 📦 Architecture

```
┌─────────────┐
│   CLI User  │
└──────┬──────┘
       │ submit job
       ▼
┌─────────────────┐
│  Redis Queue    │ ◄─── Priority-based job queue
└────────┬────────┘
         │
    ┌────┴────┐
    ▼         ▼
┌────────┐ ┌────────┐
│Worker 1│ │Worker 2│ ◄─── Parallel execution
└───┬────┘ └───┬────┘
    │          │
    ├── 4 CPU cores, 32GB RAM
    ├── Dataset validation
    ├── LoRA training (Axolotl)
    ├── Checkpoint management
    ├── Quantization (GGUF)
    └── Ollama packaging
         │
         ▼
   ┌──────────────┐
   │ PostgreSQL   │ ◄─── Job history & metrics
   └──────────────┘
         │
         ▼
   ┌──────────────┐
   │   Ollama     │ ◄─── Model serving
   └──────────────┘
```

---

## 🛠️ CLI Commands

### Job Management

```bash
# Submit job
forge-train submit --model <name> --dataset <path>

# Queue operations
forge-train queue list
forge-train queue list --status running

# Job status
forge-train status <job-id>

# Cancel job
forge-train cancel <job-id>
```

### Worker Management

```bash
# Start workers
forge-train worker start --workers 2

# Stop workers
forge-train worker stop

# Worker status
forge-train worker status
```

### Model Management

```bash
# List trained models
forge-train models list
forge-train models list --category code

# Test model
forge-train test ash-code:python --prompt "Write a function to sort a list"
```

### System Management

```bash
# System status
forge-train system status

# Resource monitoring
forge-train system resources

# Start monitoring dashboard
forge-train monitor dashboard --port 8080
```

### Dataset Management

```bash
# Validate dataset
forge-train dataset validate datasets/python-expert

# Dataset statistics
forge-train dataset stats datasets/python-expert
```

---

## 📊 Training Times

**CPU Training (Xeon E3-1270 v6, 4c/8t, 64GB RAM):**

| Model Size | Examples | Time     |
|-----------|----------|----------|
| Small     | 2k       | 24-48h   |
| Medium    | 5k       | 48-72h   |
| Large     | 10k      | 96-168h  |

**Throughput:**
- 2 workers × 24/7 = **12-20 models/month**
- Full 50-model ecosystem = **3-4 months**

---

## 📂 Directory Structure

```
/opt/forge-train/          # Installation directory
├── venv/                  # Python virtual environment
├── forge-train/           # Repository
└── config/                # Configuration files

/var/lib/forge-train/      # Data directory
├── jobs/                  # Job metadata
├── models/                # Trained models
├── datasets/              # Training datasets
└── checkpoints/           # Training checkpoints

/var/log/forge-train/      # Logs
├── worker-1.log
├── worker-2.log
├── queue.log
└── monitor.log
```

---

## ⚙️ Configuration

Edit `/opt/forge-train/config/forge-train.yaml`:

```yaml
# Workers
workers:
  count: 2
  cpu_per_worker: 4
  memory_per_worker: "32G"

# Training defaults
training:
  batch_size: 4
  learning_rate: 0.0002
  num_epochs: 3

# LoRA defaults
lora:
  rank: 16
  alpha: 32
  target_modules: ["q_proj", "v_proj", "k_proj", "o_proj"]

# Notifications
notifications:
  discord:
    enabled: true
    webhook_url: "https://discord.com/api/webhooks/..."
```

---

## 🔐 Security

**Default credentials:**
- Database password: `forge_train_password`
- Change in: `/opt/forge-train/config/forge-train.yaml`

**Update PostgreSQL password:**

```bash
sudo -u postgres psql -c "ALTER USER forge PASSWORD 'new_password';"
```

**Firewall:**
- SSH (port 22) - open
- Ollama (port 11434) - closed by default
- Dashboard (port 8080) - closed by default

---

## 📚 Documentation

- [Installation Guide](docs/INSTALLATION.md)
- [Training Guide](docs/TRAINING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [API Reference](docs/API.md)

---

## 🧩 Ecosystem

Forge Train is part of the **Ash Forge** ecosystem:

- **forge-train** (this repo) - Training infrastructure
- **ash-bot** - Discord bot with learning system
- **ash-engine** - C++ inference engine
- **forge-creator** - Model creation tools
- **forge-models** - Pre-trained model catalog

---

## 📈 Roadmap

**v1.0 (Current):**
- ✅ CPU-based LoRA training
- ✅ Parallel worker execution
- ✅ Redis job queue
- ✅ GGUF quantization
- ✅ Ollama packaging

**v1.1 (Planned):**
- GPU support (optional)
- Distributed training across multiple servers
- Advanced monitoring dashboard (Grafana)
- Model versioning and rollback
- A/B testing framework

**v2.0 (Future):**
- Web UI for job management
- Automatic hyperparameter tuning
- Community model marketplace
- Federated learning support

---

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

**Areas we need help:**
- Dataset creation and curation
- Training optimization
- Documentation
- Testing on different hardware
- Community model submissions

---

## 📜 License

Apache 2.0 - See [LICENSE](LICENSE) for details

---

## 🦞 Built by Ash Forge

**Forge your AI. Your way.**

- Website: [ash-forge.com](https://ash-forge.com)
- GitHub: [github.com/ash-forge](https://github.com/ash-forge)
- Discord: [Join our community](https://discord.gg/DCYC2fFQQ6)

---

## 🔥 Happy Forging!

Questions? Issues? Ideas?

Open an issue or join our Discord community!
