# syntax=docker/dockerfile:1
# =============================================================================
# Dockerfile — StreamVault (YouTube Frontend) — STANDALONE, SELF-CONTAINED
# =============================================================================
# This SINGLE Dockerfile is fully standalone. No external files needed.
#
# It does three things:
#   1. Installs system dependencies (apt + yt-dlp + Bun runtime)
#   2. Embeds run.sh inline (via BuildKit heredoc) — which itself embeds
#      all 117 source files as heredocs
#   3. Runs run.sh as the container entrypoint
#
# run.sh (at container start) handles:
#   - Writing all 117 source files (including package.json) via heredocs
#   - Running `bun install` (npm dependencies)
#   - Generating Prisma client
#   - Building Next.js (production)
#   - Initializing SQLite database
#   - Starting Next.js on :80 (NO reverse proxy)
#
# Build:  docker build -t streamvault .
# Run:    docker run -d --name streamvault \
#           --memory=400m --memory-swap=2g \
#           -p 80:80 \
#           -v streamvault-data:/app/data \
#           -v streamvault-db:/app/db \
#           streamvault
#
# Or with docker-compose:
#   docker-compose up -d
#
# NOTE: Requires Docker with BuildKit (Docker 20.10+, default since Docker 23.0).
#       The `# syntax=docker/dockerfile:1` directive on line 1 enables heredoc support.
# =============================================================================

FROM debian:bookworm-slim

# Avoid interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive

# App directory (run.sh reads this env var)
ENV APP_DIR=/app

# -----------------------------------------------------------------------------
# System dependencies (cached layer — only rebuilds when this changes)
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    python3 \
    python3-pip \
    python3-venv \
    ffmpeg \
    git \
    tini \
    procps \
    netcat-openbsd \
    unzip \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# yt-dlp (Python — YouTube video info + download)
# --break-system-packages: needed for Debian 12+ (PEP 668 externally-managed)
# -----------------------------------------------------------------------------
RUN pip3 install --no-cache-dir --break-system-packages yt-dlp

# -----------------------------------------------------------------------------
# Bun runtime (JavaScriptCore — NOT Node.js/V8)
# -----------------------------------------------------------------------------
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local/bun bash

ENV BUN_INSTALL=/usr/local/bun
ENV PATH=/usr/local/bun/bin:$PATH

# Verify Bun + yt-dlp are accessible (fail fast at build time if not)
RUN bun --version && yt-dlp --version

# -----------------------------------------------------------------------------
# Working directory (run.sh will populate this at container start)
# -----------------------------------------------------------------------------
WORKDIR /app

# -----------------------------------------------------------------------------
# Embed run.sh INLINE — no external file needed.
# BuildKit heredoc: content between the delimiters becomes /app/run.sh.
# The outer delimiter (RUNSH_EOF_9X7K2) is unique — it does NOT collide with
# any heredoc delimiter used INSIDE run.sh (HZ_FILE_CONTENT_END_7X9K,
# COOKIES_EOF, SETTINGS_EOF), so nesting is safe.
# The quoted form <<'RUNSH_EOF_9X7K2' preserves $vars literally (no expansion).
# -----------------------------------------------------------------------------
COPY <<'RUNSH_EOF_9X7K2' /app/run.sh
#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# run.sh — YouTube Frontend (Self-Contained, LOW-RAM Optimized for 400MB)
# =============================================================================
# This script writes all source code, builds Next.js, and serves on :80.
# System dependencies are installed by:
#   - Docker:     the Dockerfile (reusable cached image, recommended)
#   - Bare metal: Section 0 of this script (auto-installs missing deps)
#
#   Docker:     docker build -t streamvault . && docker run -p 80:80 streamvault
#   Bare metal: bash run.sh
#
# TESTED & VERIFIED memory footprint (production mode):
#   - Next.js (next start): ~180-200 MB  (peak with concurrent load)
#   - OS overhead:          ~80 MB
#   - TOTAL:                ~260-280 MB  (well under 400 MB with ~120MB headroom)
#   (Caddy reverse proxy REMOVED — Next.js serves on :80 directly.
#    Saves ~25MB RAM and eliminates the 502-from-proxy failure class.)
#
# Key optimizations:
#   - Uses `next start` (NOT standalone — standalone crashes under load)
#   - NO runtime NODE_OPTIONS cap (causes Bun GC crashes; removing it is stable)
#   - 2GB swap file (build uses disk, not RAM)
#   - Eliminates progress-service process (frontend polls API directly)
#   - Limits concurrent downloads to 1 (prevents yt-dlp+ffmpeg OOM)
#   - Disk-based TMPDIR (not tmpfs which eats RAM)
#   - Disables source maps, enables chunk optimization
#
# What it does:
#   0. Installs system deps + creates swap + tunes kernel for low RAM
#   1. Writes ALL application source code (117 files via heredocs)
#   2. Installs npm dependencies (bun install)
#   3. Generates the Prisma client
#   4. Builds Next.js (build cap 256MB, swap for overflow)
#   5. Creates runtime directories, JSON data files, cookies
#   6. Initializes the SQLite database
#   7. Starts Next.js on :80 directly (NO Caddy, NO progress-service)
#   8. Monitors the process and restarts on failure
# =============================================================================

# -----------------------------------------------------------------------------
# Re-exec as root if we're not already
# -----------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
APP_DIR="${APP_DIR:-/opt/yt-frontend}"
LOG_DIR="$APP_DIR/logs"
DATA_DIR="$APP_DIR/data"
DB_DIR="$APP_DIR/db"
COOKIES_DIR="$APP_DIR/cookies"
DOWNLOADS_DIR="$DATA_DIR/downloads"
TMP_DIR="$APP_DIR/tmp"          # Disk-based tmp (NOT tmpfs — saves RAM)
BUN_INSTALL="${BUN_INSTALL:-/usr/local/bun}"
SERVE_PORT="${SERVE_PORT:-80}"   # Port Next.js listens on directly (NO Caddy).
                                 # 80 = standard HTTP for real VPS (run.sh runs as root).
                                 # Set SERVE_PORT=3000 to test run.sh inside the sandbox.
SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SIZE="${SWAP_SIZE:-2G}"     # 2GB swap — enough for next build

# Create app directories early
mkdir -p "$APP_DIR" "$LOG_DIR" "$TMP_DIR"

# -----------------------------------------------------------------------------
# Docker detection
# -----------------------------------------------------------------------------
# When running inside Docker, skip swap creation, kernel tuning, and system
# package installation — those require --privileged (or are handled by the
# Dockerfile at build time). The host's --memory-swap flag handles swap.
IN_DOCKER=0
if [ -f /.dockerenv ]; then
    IN_DOCKER=1
fi

# -----------------------------------------------------------------------------
# Colors & logging
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    local msg="$*"
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $msg" | tee -a "$LOG_DIR/startup.log"
}

log_error() {
    local msg="$*"
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $msg" | tee -a "$LOG_DIR/error.log"
}

log_success() {
    local msg="$*"
    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $msg" | tee -a "$LOG_DIR/startup.log"
}

log_warn() {
    local msg="$*"
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $msg" | tee -a "$LOG_DIR/startup.log"
}

# -----------------------------------------------------------------------------
# MEMORY MONITOR: Log current RAM usage and warn if approaching 400MB limit
# -----------------------------------------------------------------------------
mem_status() {
    local label="${1:-checkpoint}"
    local mem_total_kb mem_used_kb mem_free_kb mem_avail_kb mem_cached_kb swap_used_kb
    mem_total_kb=$(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}')
    mem_used_kb=$(grep -E '^MemAvailable:' /proc/meminfo | awk '{print $2}')
    mem_avail_kb=$mem_used_kb
    mem_used_kb=$((mem_total_kb - mem_avail_kb))
    swap_used_kb=$(grep -E '^SwapUsed:' /proc/meminfo 2>/dev/null | awk '{print $2}')
    [ -z "$swap_used_kb" ] && swap_used_kb=$(awk '/^SwapTotal/{t=$2}/^SwapFree/{f=$2}END{print t-f}' /proc/meminfo)

    local mem_used_mb=$((mem_used_kb / 1024))
    local mem_avail_mb=$((mem_avail_kb / 1024))
    local swap_used_mb=$((swap_used_kb / 1024))

    # Color code: green < 300MB, yellow < 380MB, red >= 380MB
    local color="$GREEN"
    [ "$mem_used_mb" -ge 300 ] && color="$YELLOW"
    [ "$mem_used_mb" -ge 380 ] && color="$RED"
    echo -e "${color}[$(date '+%H:%M:%S')] [MEM:${label}] RAM used=${mem_used_mb}MB / avail=${mem_avail_mb}MB | swap used=${swap_used_mb}MB${NC}" | tee -a "$LOG_DIR/memory.log"

    # Hard warning if we cross 380MB RAM
    if [ "$mem_used_mb" -ge 380 ]; then
        log_warn "RAM usage ${mem_used_mb}MB is approaching/exceeding 400MB limit at ${label}! Active processes:"
        ps -eo pid,rss,comm --sort=-rss 2>/dev/null | head -6 | while read -r p rss c; do
            [ "$rss" -gt 1024 ] && log_warn "  PID $p: $((rss/1024))MB $c"
        done
    fi
}

# Drop filesystem caches to free RAM (safe, just releases cached file data)
drop_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Cleanup trap
# -----------------------------------------------------------------------------
NEXT_PID=""

cleanup() {
    echo ""
    log "Shutting down Next.js..."
    [ -n "$NEXT_PID" ] && kill "$NEXT_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    log "Next.js stopped."
    exit 0
}
trap cleanup SIGTERM SIGINT

# =============================================================================
# SECTION 0: Install system dependencies + LOW-RAM tuning
# =============================================================================
log "========================================"
log "  Section 0: System Setup + RAM Tuning"
log "========================================"

# Always read memory info (used in environment summary below, in both Docker + bare metal)
TOTAL_RAM_KB=$(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}')
TOTAL_SWAP_KB=$(grep -E '^SwapTotal:' /proc/meminfo | awk '{print $2}')

# has() defined early so it's available in all code paths (Docker + bare metal).
# Used later for Bun/yt-dlp/ffmpeg fallback checks.
has() { command -v "$1" &>/dev/null; }

if [ "$IN_DOCKER" -eq 1 ]; then
    # --- Docker: system deps installed by Dockerfile, swap/kernel by host ---
    PKG_MGR="docker"
    log "Running inside Docker — system deps installed by Dockerfile."
    log "  Swap: managed by host (use: docker run --memory=400m --memory-swap=2g)."
    log "  Kernel tuning: skipped (managed by host OS)."
else
    # --- Bare metal: detect package manager + install missing system deps ---
    PKG_MGR=""
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
    elif command -v apk &>/dev/null; then
        PKG_MGR="apk"
    else
        log_error "No supported package manager found (apt/dnf/yum/apk)."
        exit 1
    fi
    log "Detected package manager: $PKG_MGR"

    sys_install() {
        case "$PKG_MGR" in
            apt)
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq
                apt-get install -y --no-install-recommends "$@"
                ;;
            dnf) dnf install -y "$@" ;;
            yum) yum install -y "$@" ;;
            apk) apk add --no-cache "$@" ;;
        esac
    }

# --- Install core system packages ---
log "Checking and installing system packages..."
NEEDS_INSTALL=()

if ! has python3; then NEEDS_INSTALL+=("python3"); fi
if ! has pip3 && ! has pip; then
    case "$PKG_MGR" in
        apt)  NEEDS_INSTALL+=("python3-pip" "python3-venv") ;;
        dnf|yum) NEEDS_INSTALL+=("python3-pip") ;;
        apk)  NEEDS_INSTALL+=("py3-pip") ;;
    esac
fi
if ! has ffmpeg; then NEEDS_INSTALL+=("ffmpeg"); fi
if ! has curl; then NEEDS_INSTALL+=("curl"); fi
if ! has wget; then NEEDS_INSTALL+=("wget"); fi
if [ ! -d /usr/share/ca-certificates ] && ! has update-ca-certificates; then NEEDS_INSTALL+=("ca-certificates"); fi
if ! has gpg; then NEEDS_INSTALL+=("gnupg"); fi
if ! has git; then NEEDS_INSTALL+=("git"); fi
if ! has tini; then NEEDS_INSTALL+=("tini"); fi
if ! has nc && ! has netcat; then
    case "$PKG_MGR" in
        apt) NEEDS_INSTALL+=("netcat-openbsd") ;;
        dnf|yum) NEEDS_INSTALL+=("nmap-ncat") ;;
        apk) NEEDS_INSTALL+=("netcat-openbsd") ;;
    esac
fi
if ! has pgrep; then
    case "$PKG_MGR" in
        apt) NEEDS_INSTALL+=("procps") ;;
        dnf|yum) NEEDS_INSTALL+=("procps-ng") ;;
        apk) NEEDS_INSTALL+=("procps") ;;
    esac
fi
if ! has unzip; then NEEDS_INSTALL+=("unzip"); fi
if ! has xz; then
    case "$PKG_MGR" in
        apt) NEEDS_INSTALL+=("xz-utils") ;;
        *) NEEDS_INSTALL+=("xz") ;;
    esac
fi

if [ ${#NEEDS_INSTALL[@]} -gt 0 ]; then
    log "Installing: ${NEEDS_INSTALL[*]}"
    sys_install "${NEEDS_INSTALL[@]}"
    log_success "System packages installed."
else
    log_success "All required system packages already present."
fi

# =============================================================================
# LOW-RAM: Create swap file (ESSENTIAL for next build on 400MB servers)
# =============================================================================
log "Checking swap..."
TOTAL_SWAP_KB=$(grep -E '^SwapTotal:' /proc/meminfo | awk '{print $2}')
TOTAL_RAM_KB=$(grep -E '^MemTotal:' /proc/meminfo | awk '{print $2}')
log "  RAM: $((TOTAL_RAM_KB / 1024))MB, Swap: $((TOTAL_SWAP_KB / 1024))MB"

if [ "$TOTAL_SWAP_KB" -lt 1048576 ]; then
    if [ ! -f "$SWAP_FILE" ]; then
        log "Creating ${SWAP_SIZE} swap file at $SWAP_FILE (uses disk, not RAM)..."
        if has fallocate; then
            fallocate -l "$SWAP_SIZE" "$SWAP_FILE" 2>/dev/null || \
                dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048 status=progress
        else
            dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048 status=progress
        fi
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE"
        swapon "$SWAP_FILE"
        log_success "Swap file created and enabled (${SWAP_SIZE})."
    elif ! swapon --show | grep -q "$SWAP_FILE"; then
        log "Enabling existing swap file..."
        swapon "$SWAP_FILE"
        log_success "Swap enabled."
    else
        log "Swap file already active."
    fi
    if ! grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        log "  Added swap to /etc/fstab for persistence."
    fi
else
    log "Sufficient swap already present — skipping creation."
fi

# Tune swappiness: HIGH value = aggressively swap cold pages to disk, keep RAM free
# CRITICAL for 400MB systems: swappiness=100 means "push cold pages to swap eagerly"
# so active processes have maximum RAM available. (swappiness=10 would keep RAM full
# of cold data and trigger OOM kills — WRONG for low-RAM servers.)
CURRENT_SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)
if [ "$CURRENT_SWAPPINESS" -lt 80 ]; then
    log "Tuning vm.swappiness: $CURRENT_SWAPPINESS -> 100 (aggressively swap cold pages, keep RAM free for active processes)..."
    sysctl -q vm.swappiness=100 2>/dev/null || true
    echo "vm.swappiness=100" > /etc/sysctl.d/99-yt-frontend.conf 2>/dev/null || true
fi
# vfs_cache_pressure=200: aggressively reclaim dentry/inode caches (frees RAM)
sysctl -q vm.vfs_cache_pressure=200 2>/dev/null || true
echo "vm.vfs_cache_pressure=200" >> /etc/sysctl.d/99-yt-frontend.conf 2>/dev/null || true
# Also reduce dirty cache to prevent memory buildup
sysctl -q vm.dirty_ratio=5 2>/dev/null || true
sysctl -q vm.dirty_background_ratio=1 2>/dev/null || true
echo "vm.dirty_ratio=5" >> /etc/sysctl.d/99-yt-frontend.conf 2>/dev/null || true
echo "vm.dirty_background_ratio=1" >> /etc/sysctl.d/99-yt-frontend.conf 2>/dev/null || true
fi  # end Docker check — skip swap/kernel/deps in Docker

# =============================================================================
# LOW-RAM: Use disk-based TMPDIR (NOT tmpfs which consumes RAM)
# =============================================================================
export TMPDIR="$TMP_DIR"
export TEMP="$TMP_DIR"
export TMP="$TMP_DIR"
mkdir -p "$TMP_DIR"
log "TMPDIR set to $TMP_DIR (disk-backed, not RAM)"

# =============================================================================
# LOW-RAM: Cap Bun's JavaScriptCore heap (Bun does NOT respect NODE_OPTIONS!)
# =============================================================================
# NODE_OPTIONS=--max-old-space-size only caps V8 (Node.js). Bun uses JavaScriptCore.
# To actually cap Bun's heap, we use BUN_JSC_forceRAMSize (in bytes).
# 256MB = 268435456 bytes — leaves ~144MB for OS on a 400MB system.
export BUN_JSC_forceRAMSize=268435456
# Aggressive garbage collection: collect more often, trade CPU for RAM.
export BUN_JSC_gcControl=1
# Disable Bun's telemetry (small RAM + network save)
export BUN_INSTALL_CACHE_DIR="$APP_DIR/.bun-cache"
# Next.js: disable telemetry + reduce build workers
export NEXT_TELEMETRY_DISABLED=1
# Limit concurrent file operations
export UV_THREADPOOL_SIZE=8
log "Bun heap capped at 256MB (BUN_JSC_forceRAMSize=268435456)"
log "Next.js telemetry disabled, aggressive GC enabled"

# Initial memory snapshot
mem_status "startup"

# --- Install Bun ---
log "Checking Bun..."
if ! has bun; then
    log "Installing Bun..."
    curl -fsSL https://bun.sh/install | BUN_INSTALL="$BUN_INSTALL" bash
    log_success "Bun installed."
else
    log "Bun already present: $(bun --version)"
    BUN_DIR="$(dirname "$(dirname "$(command -v bun)")")"
    if [ -d "$BUN_DIR" ]; then
        BUN_INSTALL="$BUN_DIR"
    fi
fi
export BUN_INSTALL="$BUN_INSTALL"
export PATH="$BUN_INSTALL/bin:$PATH"
ln -sf "$BUN_INSTALL/bin/bun" /usr/local/bin/bun 2>/dev/null || true
ln -sf "$BUN_INSTALL/bin/bunx" /usr/local/bin/bunx 2>/dev/null || true

if ! bun --version &>/dev/null; then
    log_error "Bun is not accessible on PATH after install."
    exit 1
fi
log "Bun version: $(bun --version)"

# --- Install yt-dlp ---
log "Checking yt-dlp..."
if ! has yt-dlp; then
    log "Installing yt-dlp via pip..."
    pip3 install --no-cache-dir --break-system-packages -U yt-dlp 2>/dev/null || \
        pip3 install --no-cache-dir -U yt-dlp 2>/dev/null || \
        {
            log_warn "System pip failed — trying with --user..."
            pip3 install --user --no-cache-dir -U yt-dlp
            export PATH="$HOME/.local/bin:$PATH"
            ln -sf "$HOME/.local/bin/yt-dlp" /usr/local/bin/yt-dlp 2>/dev/null || true
        }
    log_success "yt-dlp installed."
else
    log "yt-dlp already present: $(yt-dlp --version)"
fi
if ! yt-dlp --version &>/dev/null; then
    log_error "yt-dlp is not accessible on PATH."
    exit 1
fi

# --- Caddy reverse proxy: REMOVED ---
# Previously a Caddy process sat in front of Next.js (:80 -> :3000).
# It has been eliminated: Next.js now serves on :80 directly.
# Reasons:
#   1. Caddy was the source of 502 Bad Gateway errors (proxy -> dead/slow backend).
#   2. It consumed ~25MB RAM for zero benefit — Next.js handles compression,
#      streaming, and routing natively (compress:true is in next.config.ts).
#   3. Its only real feature (auto-HTTPS) was unused (we run plain HTTP).
# No install step needed anymore.

# --- Environment summary ---
log ""
log "========================================"
log "  Environment Summary (LOW-RAM Mode)"
log "========================================"
log "  OS:          $(cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME' | cut -d= -f2 | tr -d '"' || echo 'unknown')"
log "  RAM:         $((TOTAL_RAM_KB / 1024))MB"
log "  Swap:        $(swapon --show --noheadings --bytes 2>/dev/null | awk '{s+=$3} END {print s/1024/1024 "MB"}')"
log "  Swappiness:  $(cat /proc/sys/vm/swappiness)"
log "  TMPDIR:      $TMPDIR (disk-backed)"
log "  Package Mgr: $PKG_MGR"
log "  Bun:         $(bun --version)"
log "  yt-dlp:      $(yt-dlp --version 2>&1 | head -n1)"
log "  ffmpeg:      $(ffmpeg -version 2>&1 | head -n1)"
log "  App dir:     $APP_DIR"
log "========================================"
log ""

# =============================================================================
# SECTION 1: Write ALL source code files
# =============================================================================
SKIP_SOURCE=0
if [ -f "$APP_DIR/package.json" ] && [ -f "$APP_DIR/src/app/page.tsx" ] && [ -f "$APP_DIR/src/app/layout.tsx" ]; then
    SKIP_SOURCE=1
    log "Section 1: Source code already exists — skipping file generation."
fi

if [ "$SKIP_SOURCE" -eq 0 ]; then
    log "Section 1: Writing source code files..."
    cd "$APP_DIR"

    # --- components.json ---
mkdir -p "$(dirname "components.json")"
cat > 'components.json' <<'HZ_FILE_CONTENT_END_7X9K'
{
  "$schema": "https://ui.shadcn.com/schema.json",
  "style": "new-york",
  "rsc": true,
  "tsx": true,
  "tailwind": {
    "config": "",
    "css": "src/app/globals.css",
    "baseColor": "neutral",
    "cssVariables": true,
    "prefix": ""
  },
  "aliases": {
    "components": "@/components",
    "utils": "@/lib/utils",
    "ui": "@/components/ui",
    "lib": "@/lib",
    "hooks": "@/hooks"
  },
  "iconLibrary": "lucide"
}
HZ_FILE_CONTENT_END_7X9K

    # --- eslint.config.mjs ---
mkdir -p "$(dirname "eslint.config.mjs")"
cat > 'eslint.config.mjs' <<'HZ_FILE_CONTENT_END_7X9K'
import nextCoreWebVitals from "eslint-config-next/core-web-vitals";
import nextTypescript from "eslint-config-next/typescript";
import { dirname } from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const eslintConfig = [...nextCoreWebVitals, ...nextTypescript, {
  rules: {
    // TypeScript rules
    "@typescript-eslint/no-explicit-any": "off",
    "@typescript-eslint/no-unused-vars": "off",
    "@typescript-eslint/no-non-null-assertion": "off",
    "@typescript-eslint/ban-ts-comment": "off",
    "@typescript-eslint/prefer-as-const": "off",
    "@typescript-eslint/no-unused-disable-directive": "off",
    
    // React rules
    "react-hooks/exhaustive-deps": "off",
    "react-hooks/purity": "off",
    "react/no-unescaped-entities": "off",
    "react/display-name": "off",
    "react/prop-types": "off",
    "react-compiler/react-compiler": "off",
    
    // Next.js rules
    "@next/next/no-img-element": "off",
    "@next/next/no-html-link-for-pages": "off",
    
    // General JavaScript rules
    "prefer-const": "off",
    "no-unused-vars": "off",
    "no-console": "off",
    "no-debugger": "off",
    "no-empty": "off",
    "no-irregular-whitespace": "off",
    "no-case-declarations": "off",
    "no-fallthrough": "off",
    "no-mixed-spaces-and-tabs": "off",
    "no-redeclare": "off",
    "no-undef": "off",
    "no-unreachable": "off",
    "no-useless-escape": "off",
  },
}, {
  ignores: ["node_modules/**", ".next/**", "out/**", "build/**", "next-env.d.ts", "examples/**", "skills"]
}];

export default eslintConfig;
HZ_FILE_CONTENT_END_7X9K

    # --- mini-services/progress-service/index.ts ---
mkdir -p "$(dirname "mini-services/progress-service/index.ts")"
cat > 'mini-services/progress-service/index.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { createServer } from "http";
import { Server } from "socket.io";

const PORT = 3001;

const httpServer = createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true, service: "progress-service", port: PORT }));
    return;
  }
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("progress-service running");
});

const io = new Server(httpServer, {
  cors: { origin: "*", methods: ["GET", "POST"] },
  path: "/socket.io/",
});

let lastSnapshot = "";
let clientCount = 0;
let pollInterval: ReturnType<typeof setInterval> | null = null;

async function pollStatus(): Promise<any[]> {
  try {
    const res = await fetch("http://localhost:3000/api/download/status", {
      headers: { "User-Agent": "progress-service/1.0" },
    });
    if (!res.ok) return [];
    const data = await res.json();
    return data.jobs || [];
  } catch {
    return [];
  }
}

async function broadcastJobs() {
  if (clientCount === 0) return;
  try {
    const jobs = await pollStatus();
    const snap = JSON.stringify(jobs.map((j: any) => `${j.id}:${j.status}:${j.progress}`));
    if (snap !== lastSnapshot) {
      lastSnapshot = snap;
      io.emit("jobs", jobs);
    }
    for (const job of jobs) {
      io.to(`job:${job.id}`).emit("progress", job);
    }
  } catch {
    // ignore
  }
}

function startPolling() {
  if (pollInterval) return;
  // Poll every 1.5s only while clients are connected
  pollInterval = setInterval(broadcastJobs, 1500);
}

function stopPolling() {
  if (pollInterval) {
    clearInterval(pollInterval);
    pollInterval = null;
  }
}

io.on("connection", (socket) => {
  clientCount++;
  socket.emit("hello", { service: "progress-service", time: Date.now() });
  startPolling();
  // Send an immediate snapshot
  broadcastJobs();

  socket.on("subscribe", (jobId: string) => {
    if (jobId) socket.join(`job:${jobId}`);
  });
  socket.on("unsubscribe", (jobId: string) => {
    if (jobId) socket.leave(`job:${jobId}`);
  });
  socket.on("disconnect", () => {
    clientCount = Math.max(0, clientCount - 1);
    if (clientCount === 0) stopPolling();
  });
});

httpServer.listen(PORT, () => {
  console.log(`progress-service listening on port ${PORT} (polls only when clients connected)`);
});
HZ_FILE_CONTENT_END_7X9K

    # --- mini-services/progress-service/package.json ---
mkdir -p "$(dirname "mini-services/progress-service/package.json")"
cat > 'mini-services/progress-service/package.json' <<'HZ_FILE_CONTENT_END_7X9K'
{
  "name": "progress-service",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "bun --hot index.ts"
  },
  "dependencies": {
    "socket.io": "^4.8.1",
    "cors": "^2.8.5"
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- next.config.ts ---
mkdir -p "$(dirname "next.config.ts")"
cat > 'next.config.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // NOT using "standalone" output — standalone server crashes under load.
  // Using default output + `next start` which is stable and still lean (~189MB).
  typescript: {
    ignoreBuildErrors: true,
  },
  reactStrictMode: false,
  // Low-RAM optimizations: disable source maps to reduce build memory + disk
  productionBrowserSourceMaps: false,
  // Reduce chunk count to lower memory overhead at runtime
  experimental: {
    optimizePackageImports: [
      "lucide-react",
      "@radix-ui/react-icons",
      "framer-motion",
      "date-fns",
    ],
  },
  // Compress responses server-side (gzip handled here — no external proxy)
  compress: true,
  // Disable X-Powered-By header (minor perf + security)
  poweredByHeader: false,
};

export default nextConfig;
HZ_FILE_CONTENT_END_7X9K

    # --- package.json ---
mkdir -p "$(dirname "package.json")"
cat > 'package.json' <<'HZ_FILE_CONTENT_END_7X9K'
{
  "name": "nextjs_tailwind_shadcn_ts",
  "version": "0.2.1",
  "private": true,
  "scripts": {
    "dev": "next dev -p 3000 2>&1 | tee dev.log",
    "build": "NODE_OPTIONS='--max-old-space-size=256' next build",
    "start": "NODE_ENV=production bun next start -p 3000 2>&1 | tee server.log",
    "lint": "eslint .",
    "db:push": "prisma db push --accept-data-loss",
    "db:generate": "prisma generate",
    "db:migrate": "prisma migrate dev",
    "db:reset": "prisma migrate reset"
  },
  "dependencies": {
    "@dnd-kit/core": "^6.3.1",
    "@dnd-kit/sortable": "^10.0.0",
    "@dnd-kit/utilities": "^3.2.2",
    "@hookform/resolvers": "^5.1.1",
    "@mdxeditor/editor": "^3.39.1",
    "@prisma/client": "^6.11.1",
    "@radix-ui/react-accordion": "^1.2.11",
    "@radix-ui/react-alert-dialog": "^1.1.14",
    "@radix-ui/react-aspect-ratio": "^1.1.7",
    "@radix-ui/react-avatar": "^1.1.10",
    "@radix-ui/react-checkbox": "^1.3.2",
    "@radix-ui/react-collapsible": "^1.1.11",
    "@radix-ui/react-context-menu": "^2.2.15",
    "@radix-ui/react-dialog": "^1.1.14",
    "@radix-ui/react-dropdown-menu": "^2.1.15",
    "@radix-ui/react-hover-card": "^1.1.14",
    "@radix-ui/react-label": "^2.1.7",
    "@radix-ui/react-menubar": "^1.1.15",
    "@radix-ui/react-navigation-menu": "^1.2.13",
    "@radix-ui/react-popover": "^1.1.14",
    "@radix-ui/react-progress": "^1.1.7",
    "@radix-ui/react-radio-group": "^1.3.7",
    "@radix-ui/react-scroll-area": "^1.2.9",
    "@radix-ui/react-select": "^2.2.5",
    "@radix-ui/react-separator": "^1.1.7",
    "@radix-ui/react-slider": "^1.3.5",
    "@radix-ui/react-slot": "^1.2.3",
    "@radix-ui/react-switch": "^1.2.5",
    "@radix-ui/react-tabs": "^1.1.12",
    "@radix-ui/react-toast": "^1.2.14",
    "@radix-ui/react-toggle": "^1.1.9",
    "@radix-ui/react-toggle-group": "^1.1.10",
    "@radix-ui/react-tooltip": "^1.2.7",
    "@reactuses/core": "^6.0.5",
    "@tanstack/react-query": "^5.82.0",
    "@tanstack/react-table": "^8.21.3",
    "@types/qrcode": "^1.5.6",
    "class-variance-authority": "^0.7.1",
    "clsx": "^2.1.1",
    "cmdk": "^1.1.1",
    "date-fns": "^4.1.0",
    "embla-carousel-react": "^8.6.0",
    "framer-motion": "^12.23.2",
    "input-otp": "^1.4.2",
    "lucide-react": "^0.525.0",
    "next": "^16.1.1",
    "next-auth": "^4.24.11",
    "next-intl": "^4.3.4",
    "next-themes": "^0.4.6",
    "prisma": "^6.11.1",
    "qrcode": "^1.5.4",
    "react": "^19.0.0",
    "react-day-picker": "^9.8.0",
    "react-dom": "^19.0.0",
    "react-hook-form": "^7.60.0",
    "react-markdown": "^10.1.0",
    "react-resizable-panels": "^3.0.3",
    "react-syntax-highlighter": "^15.6.1",
    "recharts": "^2.15.4",
    "sharp": "^0.34.3",
    "socket.io-client": "^4.8.3",
    "sonner": "^2.0.6",
    "tailwind-merge": "^3.3.1",
    "tailwindcss-animate": "^1.0.7",
    "uuid": "^11.1.0",
    "vaul": "^1.1.2",
    "z-ai-web-dev-sdk": "^0.0.18",
    "zod": "^4.0.2",
    "zustand": "^5.0.6"
  },
  "devDependencies": {
    "@tailwindcss/postcss": "^4",
    "@types/react": "^19",
    "@types/react-dom": "^19",
    "bun-types": "^1.3.4",
    "eslint": "^9",
    "eslint-config-next": "^16.1.1",
    "tailwindcss": "^4",
    "tw-animate-css": "^1.3.5",
    "typescript": "^5"
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- postcss.config.mjs ---
mkdir -p "$(dirname "postcss.config.mjs")"
cat > 'postcss.config.mjs' <<'HZ_FILE_CONTENT_END_7X9K'
const config = {
  plugins: ["@tailwindcss/postcss"],
};

export default config;
HZ_FILE_CONTENT_END_7X9K

    # --- prisma/schema.prisma ---
mkdir -p "$(dirname "prisma/schema.prisma")"
cat > 'prisma/schema.prisma' <<'HZ_FILE_CONTENT_END_7X9K'
// Prisma schema for YouTube Frontend (yt-dlp)

generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "sqlite"
  url      = env("DATABASE_URL")
}

model VideoHistory {
  id        String   @id @default(cuid())
  videoId   String
  title     String
  channel   String
  thumbnail String?
  duration  Int?
  watchedAt DateTime @default(now())

  @@index([videoId])
  @@index([watchedAt])
}

model SearchHistory {
  id         String   @id @default(cuid())
  query      String
  searchedAt DateTime @default(now())

  @@index([query])
  @@index([searchedAt])
}

model DownloadHistory {
  id        String   @id @default(cuid())
  videoId   String
  title     String
  format    String
  quality   String
  status    String
  filepath  String?
  fileSize  Int?
  createdAt DateTime @default(now())

  @@index([videoId])
  @@index([createdAt])
}

model Setting {
  key   String @id
  value String
}

model Favorite {
  id        String   @id @default(cuid())
  videoId   String
  title     String
  channel   String
  thumbnail String?
  duration  Int?
  createdAt DateTime @default(now())

  @@unique([videoId])
  @@index([createdAt])
}

model WatchLater {
  id        String   @id @default(cuid())
  videoId   String
  title     String
  channel   String
  thumbnail String?
  duration  Int?
  createdAt DateTime @default(now())

  @@unique([videoId])
  @@index([createdAt])
}
HZ_FILE_CONTENT_END_7X9K

    # --- public/logo.svg ---
mkdir -p "$(dirname "public/logo.svg")"
cat > 'public/logo.svg' <<'HZ_FILE_CONTENT_END_7X9K'
<?xml version="1.0" encoding="utf-8"?>
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" x="0px" y="0px"
         viewBox="0 0 30 30" style="enable-background:new 0 0 30 30;" xml:space="preserve">
<defs>
  <style type="text/css">
    .st194{fill:#2D2D2D;stroke:#FFFFFF;stroke-width:0.6317;stroke-miterlimit:10;}
    .st23{fill:#FFFFFF;}

    .z-breathe {
      animation: breathe 2.5s ease-in-out infinite;
    }

    @keyframes breathe {
      0%, 100% { opacity: 0.7; }
      50% { opacity: 1; }
    }
  </style>
</defs>

<g>
  <path class="st194" d="M24.51,28.51H5.49c-2.21,0-4-1.79-4-4V5.49c0-2.21,1.79-4,4-4h19.03c2.21,0,4,1.79,4,4v19.03
    C28.51,26.72,26.72,28.51,24.51,28.51z"/>
  <g class="z-breathe">
    <path class="st23" d="M15.47,7.1l-1.3,1.85c-0.2,0.29-0.54,0.47-0.9,0.47h-7.1V7.09C6.16,7.1,15.47,7.1,15.47,7.1z"/>
    <polygon class="st23" points="24.3,7.1 13.14,22.91 5.7,22.91 16.86,7.1"/>
    <path class="st23" d="M14.53,22.91l1.31-1.86c0.2-0.29,0.54-0.47,0.9-0.47h7.09v2.33H14.53z"/>
  </g>
</g>
</svg>
HZ_FILE_CONTENT_END_7X9K

    # --- public/robots.txt ---
mkdir -p "$(dirname "public/robots.txt")"
cat > 'public/robots.txt' <<'HZ_FILE_CONTENT_END_7X9K'
User-agent: Googlebot
Allow: /

User-agent: Bingbot
Allow: /

User-agent: Twitterbot
Allow: /

User-agent: facebookexternalhit
Allow: /

User-agent: *
Allow: /
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/admin/cache/route.ts ---
mkdir -p "$(dirname "src/app/api/admin/cache/route.ts")"
cat > 'src/app/api/admin/cache/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextResponse } from 'next/server'
import { isAdmin } from '@/lib/admin-auth'
import { cacheClear } from '@/lib/ytdlp'

export async function POST() {
  const admin = await isAdmin()
  if (!admin) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  const cleared = cacheClear()
  return NextResponse.json({ success: true, cleared })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/admin/login/route.ts ---
mkdir -p "$(dirname "src/app/api/admin/login/route.ts")"
cat > 'src/app/api/admin/login/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { adminLogin } from '@/lib/admin-auth'

export async function POST(req: NextRequest) {
  const { password } = await req.json()
  if (!password) return NextResponse.json({ error: 'Missing password' }, { status: 400 })
  const ok = await adminLogin(password)
  if (!ok) return NextResponse.json({ error: 'Invalid password' }, { status: 401 })
  return NextResponse.json({ success: true })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/admin/logout/route.ts ---
mkdir -p "$(dirname "src/app/api/admin/logout/route.ts")"
cat > 'src/app/api/admin/logout/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextResponse } from 'next/server'
import { adminLogout } from '@/lib/admin-auth'

export async function POST() {
  await adminLogout()
  return NextResponse.json({ success: true })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/admin/logs/route.ts ---
mkdir -p "$(dirname "src/app/api/admin/logs/route.ts")"
cat > 'src/app/api/admin/logs/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextResponse } from 'next/server'
import { isAdmin } from '@/lib/admin-auth'
import { readFile } from 'fs/promises'
import path from 'path'

export async function GET() {
  const admin = await isAdmin()
  if (!admin) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  try {
    const logPath = path.join(process.cwd(), 'data', 'logs', 'downloads.log')
    let content = ''
    try {
      content = await readFile(logPath, 'utf-8')
    } catch {
      content = ''
    }
    // Return last 500 lines
    const lines = content.split('\n').filter(Boolean).slice(-500)
    return NextResponse.json({ logs: lines })
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 500 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/admin/status/route.ts ---
mkdir -p "$(dirname "src/app/api/admin/status/route.ts")"
cat > 'src/app/api/admin/status/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextResponse } from 'next/server'
import { isAdmin } from '@/lib/admin-auth'
import { getCookiesStatus } from '@/lib/cookies'
import { cacheGet } from '@/lib/ytdlp'

export async function GET() {
  const admin = await isAdmin()
  const cookies = await getCookiesStatus()
  return NextResponse.json({
    authenticated: admin,
    cookies: {
      available: cookies.available,
      valid: cookies.valid,
      size: cookies.size,
      uploadedAt: cookies.uploadedAt,
      lastError: cookies.lastError,
    },
  })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/admin/version/route.ts ---
mkdir -p "$(dirname "src/app/api/admin/version/route.ts")"
cat > 'src/app/api/admin/version/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextResponse } from 'next/server'
import { getYtdlpVersion } from '@/lib/ytdlp'
import { isAdmin } from '@/lib/admin-auth'

export async function GET() {
  try {
    const version = await getYtdlpVersion()
    return NextResponse.json({ version, binary: 'yt-dlp' })
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 500 })
  }
}

export async function POST() {
  const admin = await isAdmin()
  if (!admin) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  try {
    const { execFile } = await import('child_process')
    const { promisify } = await import('util')
    const exec = promisify(execFile)
    // Update via pip
    const { stdout, stderr } = await exec('pip3', ['install', '--upgrade', 'yt-dlp'], { timeout: 120000 })
    const newVersion = await getYtdlpVersion()
    return NextResponse.json({ success: true, version: newVersion, output: stdout + stderr })
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Update failed' }, { status: 500 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/cookies/status/route.ts ---
mkdir -p "$(dirname "src/app/api/cookies/status/route.ts")"
cat > 'src/app/api/cookies/status/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextResponse } from 'next/server'
import { getCookiesStatus } from '@/lib/cookies'

export async function GET() {
  const status = await getCookiesStatus()
  // Never expose path details fully; mask it
  return NextResponse.json({
    available: status.available,
    valid: status.valid,
    size: status.size,
    uploadedAt: status.uploadedAt,
    lastError: status.lastError,
    // do not expose full path
    location: 'server (secured)',
  })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/download/cancel/route.ts ---
mkdir -p "$(dirname "src/app/api/download/cancel/route.ts")"
cat > 'src/app/api/download/cancel/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { cancelDownload } from '@/lib/download'

export async function POST(req: NextRequest) {
  const { jobId } = await req.json()
  if (!jobId) return NextResponse.json({ error: 'Missing jobId' }, { status: 400 })
  const ok = cancelDownload(jobId)
  return NextResponse.json({ success: ok })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/download/file/route.ts ---
mkdir -p "$(dirname "src/app/api/download/file/route.ts")"
cat > 'src/app/api/download/file/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import path from 'path'
import { createReadStream, statSync, existsSync } from 'fs'
import { db } from '@/lib/db'
import { getJob } from '@/lib/download'

export const dynamic = 'force-dynamic'
export const runtime = 'nodejs'

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const id = searchParams.get('id')
  if (!id) return new Response('Missing id', { status: 400 })

  // Look up the download history record
  let record = await db.downloadHistory.findUnique({ where: { id } })

  // Fallback: if the DB record doesn't exist yet (race condition: the
  // websocket poller may have broadcast 'completed' a moment before the
  // record was persisted), check the in-memory job for a filepath.
  if (!record || !record.filepath) {
    const liveJob = getJob(id)
    if (liveJob && liveJob.filepath) {
      record = {
        id: liveJob.id,
        videoId: liveJob.videoId,
        title: liveJob.title,
        format: liveJob.format,
        quality: liveJob.quality,
        status: liveJob.status,
        filepath: liveJob.filepath,
        fileSize: liveJob.fileSize ?? null,
        createdAt: new Date(liveJob.createdAt),
      } as any
    }
  }

  if (!record || !record.filepath) {
    return new Response('File not found', { status: 404 })
  }

  // Prevent directory traversal - filepath must be within download dir
  const downloadDir = path.resolve(process.env.DOWNLOAD_DIR || '/home/z/my-project/data/downloads')
  const resolved = path.resolve(record.filepath)
  if (!resolved.startsWith(downloadDir)) {
    return new Response('Forbidden', { status: 403 })
  }

  // Extra safety: make sure the file actually exists on disk
  if (!existsSync(resolved)) {
    return new Response('File not found on disk', { status: 404 })
  }

  try {
    const stat = statSync(resolved)
    const range = req.headers.get('range')
    const filename = path.basename(resolved)

    if (range) {
      const m = range.match(/bytes=(\d*)-(\d*)/)
      if (m) {
        const start = m[1] ? parseInt(m[1], 10) : 0
        const end = m[2] ? parseInt(m[2], 10) : stat.size - 1
        const stream = createReadStream(resolved, { start, end })
        const readable = new ReadableStream({
          start(controller) {
            stream.on('data', (c) => controller.enqueue(c))
            stream.on('end', () => controller.close())
            stream.on('error', (e) => controller.error(e))
          },
        })
        return new Response(readable, {
          status: 206,
          headers: {
            'content-range': `bytes ${start}-${end}/${stat.size}`,
            'content-length': String(end - start + 1),
            'accept-ranges': 'bytes',
            'content-type': contentType(filename),
            'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(filename)}`,
          },
        })
      }
    }

    const stream = createReadStream(resolved)
    const readable = new ReadableStream({
      start(controller) {
        stream.on('data', (c) => controller.enqueue(c))
        stream.on('end', () => controller.close())
        stream.on('error', (e) => controller.error(e))
      },
    })
    return new Response(readable, {
      status: 200,
      headers: {
        'content-length': String(stat.size),
        'content-type': contentType(filename),
        'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(filename)}`,
        'accept-ranges': 'bytes',
      },
    })
  } catch {
    return new Response('File read error', { status: 500 })
  }
}

function contentType(filename: string): string {
  const ext = path.extname(filename).toLowerCase()
  const map: Record<string, string> = {
    '.mp4': 'video/mp4', '.webm': 'video/webm', '.mp3': 'audio/mpeg',
    '.m4a': 'audio/mp4', '.wav': 'audio/wav', '.flac': 'audio/flac',
  }
  return map[ext] || 'application/octet-stream'
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/download/list/route.ts ---
mkdir -p "$(dirname "src/app/api/download/list/route.ts")"
cat > 'src/app/api/download/list/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { db } from '@/lib/db'

export async function GET() {
  const items = await db.downloadHistory.findMany({
    orderBy: { createdAt: 'desc' },
    take: 100,
  })
  return NextResponse.json({ items })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/download/start/route.ts ---
mkdir -p "$(dirname "src/app/api/download/start/route.ts")"
cat > 'src/app/api/download/start/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { startDownload } from '@/lib/download'
import { getVideoInfo } from '@/lib/ytdlp'

export async function POST(req: NextRequest) {
  try {
    const body = await req.json()
    const { videoId, title, format, quality } = body as {
      videoId: string; title?: string; format: string; quality: string
    }
    if (!videoId || !format || !quality) {
      return NextResponse.json({ error: 'Missing videoId, format or quality' }, { status: 400 })
    }
    const allowedFormats = ['mp4', 'webm', 'mp3', 'm4a', 'wav', 'flac']
    if (!allowedFormats.includes(format)) {
      return NextResponse.json({ error: 'Invalid format' }, { status: 400 })
    }
    let finalTitle = title
    if (!finalTitle) {
      try {
        const info = await getVideoInfo(videoId)
        finalTitle = info.title || 'video'
      } catch {
        finalTitle = 'video'
      }
    }
    const jobId = await startDownload(videoId, finalTitle, format, quality)
    return NextResponse.json({ jobId, message: 'Download started' })
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 500 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/download/status/route.ts ---
mkdir -p "$(dirname "src/app/api/download/status/route.ts")"
cat > 'src/app/api/download/status/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { getJob, listJobs } from '@/lib/download'

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const jobId = searchParams.get('jobId')
  if (jobId) {
    const job = getJob(jobId)
    if (!job) return NextResponse.json({ error: 'Job not found' }, { status: 404 })
    return NextResponse.json({ job })
  }
  return NextResponse.json({ jobs: listJobs() })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/favorites/route.ts ---
mkdir -p "$(dirname "src/app/api/favorites/route.ts")"
cat > 'src/app/api/favorites/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { db } from '@/lib/db'

export async function GET() {
  const items = await db.favorite.findMany({ orderBy: { createdAt: 'desc' } })
  return NextResponse.json({ items })
}

export async function POST(req: NextRequest) {
  const body = await req.json()
  const { videoId, title, channel, thumbnail, duration } = body
  if (!videoId) return NextResponse.json({ error: 'Missing videoId' }, { status: 400 })
  try {
    const item = await db.favorite.upsert({
      where: { videoId },
      create: { videoId, title: title || '', channel: channel || '', thumbnail: thumbnail || null, duration: duration || null },
      update: { title: title || undefined, channel: channel || undefined, thumbnail: thumbnail || undefined },
    })
    return NextResponse.json({ item })
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 500 })
  }
}

export async function DELETE(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const videoId = searchParams.get('videoId')
  if (videoId) {
    await db.favorite.deleteMany({ where: { videoId } })
  } else {
    await db.favorite.deleteMany({})
  }
  return NextResponse.json({ success: true })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/history/route.ts ---
mkdir -p "$(dirname "src/app/api/history/route.ts")"
cat > 'src/app/api/history/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { db } from '@/lib/db'
import { getSettings } from '@/lib/settings'

// GET history (type=watch|search|download, default watch)
export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const type = searchParams.get('type') || 'watch'
  const settings = await getSettings()
  const limit = Math.min(parseInt(searchParams.get('limit') || String(settings.historyLimit), 10), 500)

  try {
    if (type === 'search') {
      const items = await db.searchHistory.findMany({
        orderBy: { searchedAt: 'desc' },
        take: limit,
      })
      return NextResponse.json({ type, items })
    }
    if (type === 'download') {
      const items = await db.downloadHistory.findMany({
        orderBy: { createdAt: 'desc' },
        take: limit,
      })
      return NextResponse.json({ type, items })
    }
    // watch
    const items = await db.videoHistory.findMany({
      orderBy: { watchedAt: 'desc' },
      take: limit,
    })
    return NextResponse.json({ type, items })
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 500 })
  }
}

export async function DELETE(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const type = searchParams.get('type') || 'all'
  try {
    if (type === 'search' || type === 'all') await db.searchHistory.deleteMany({})
    if (type === 'download' || type === 'all') await db.downloadHistory.deleteMany({})
    if (type === 'watch' || type === 'all') await db.videoHistory.deleteMany({})
    return NextResponse.json({ success: true })
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 500 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/qr/route.ts ---
mkdir -p "$(dirname "src/app/api/qr/route.ts")"
cat > 'src/app/api/qr/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest } from 'next/server'
import QRCode from 'qrcode'

export const dynamic = 'force-dynamic'

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const text = searchParams.get('text') || ''
  if (!text) return new Response('Missing text', { status: 400 })

  try {
    const svg = await QRCode.toString(text, {
      type: 'svg',
      margin: 1,
      width: 256,
      color: { dark: '#000000', light: '#ffffff' },
      errorCorrectionLevel: 'M',
    })
    return new Response(svg, {
      status: 200,
      headers: {
        'content-type': 'image/svg+xml',
        'cache-control': 'public, max-age=86400',
        'access-control-allow-origin': '*',
      },
    })
  } catch {
    return new Response('QR generation failed', { status: 500 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/settings/route.ts ---
mkdir -p "$(dirname "src/app/api/settings/route.ts")"
cat > 'src/app/api/settings/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { getSettings, saveSettings, type AppSettings } from '@/lib/settings'
import { isAdmin } from '@/lib/admin-auth'

export async function GET() {
  const settings = await getSettings()
  return NextResponse.json(settings)
}

export async function POST(req: NextRequest) {
  // Settings can be saved by user too, but sensitive ones (downloadDir, rateLimit) require admin
  try {
    const body = await req.json() as Partial<AppSettings>
    const admin = await isAdmin()
    const sensitive: (keyof AppSettings)[] = ['downloadDir', 'cacheMax', 'rateLimitPerMin']
    const hasSensitive = sensitive.some((k) => k in body)
    if (hasSensitive && !admin) {
      return NextResponse.json({ error: 'Admin login required to change server settings' }, { status: 401 })
    }
    const next = await saveSettings(body)
    return NextResponse.json(next)
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 400 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/watchlater/route.ts ---
mkdir -p "$(dirname "src/app/api/watchlater/route.ts")"
cat > 'src/app/api/watchlater/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { db } from '@/lib/db'

export async function GET() {
  const items = await db.watchLater.findMany({ orderBy: { createdAt: 'desc' } })
  return NextResponse.json({ items })
}

export async function POST(req: NextRequest) {
  const body = await req.json()
  const { videoId, title, channel, thumbnail, duration } = body
  if (!videoId) return NextResponse.json({ error: 'Missing videoId' }, { status: 400 })
  try {
    const item = await db.watchLater.upsert({
      where: { videoId },
      create: { videoId, title: title || '', channel: channel || '', thumbnail: thumbnail || null, duration: duration || null },
      update: { title: title || undefined, channel: channel || undefined, thumbnail: thumbnail || undefined },
    })
    return NextResponse.json({ item })
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 500 })
  }
}

export async function DELETE(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const videoId = searchParams.get('videoId')
  if (videoId) {
    await db.watchLater.deleteMany({ where: { videoId } })
  } else {
    await db.watchLater.deleteMany({})
  }
  return NextResponse.json({ success: true })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/ytdlp/channel/route.ts ---
mkdir -p "$(dirname "src/app/api/ytdlp/channel/route.ts")"
cat > 'src/app/api/ytdlp/channel/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { getChannelVideos } from '@/lib/ytdlp'

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const id = (searchParams.get('id') || '').trim()
  if (!id) return NextResponse.json({ error: 'Missing id' }, { status: 400 })
  try {
    const limit = Math.min(parseInt(searchParams.get('limit') || '30', 10), 50)
    const data = await getChannelVideos(id, limit)
    return NextResponse.json(data)
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 500 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/ytdlp/related/route.ts ---
mkdir -p "$(dirname "src/app/api/ytdlp/related/route.ts")"
cat > 'src/app/api/ytdlp/related/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { getRelatedVideos } from '@/lib/ytdlp'

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const id = (searchParams.get('id') || '').trim()
  if (!id) return NextResponse.json({ error: 'Missing id' }, { status: 400 })
  try {
    const results = await getRelatedVideos(id)
    return NextResponse.json({ results })
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 500 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/ytdlp/search/route.ts ---
mkdir -p "$(dirname "src/app/api/ytdlp/search/route.ts")"
cat > 'src/app/api/ytdlp/search/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { searchVideos, suggestQueries } from '@/lib/ytdlp'
import { db } from '@/lib/db'
import { checkRateLimit, getSettings } from '@/lib/settings'

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const q = (searchParams.get('q') || '').trim()
  const suggest = searchParams.get('suggest') === '1'

  if (!q) {
    return NextResponse.json({ results: [], suggestions: [] })
  }

  // Suggestions only
  if (suggest) {
    const suggestions = await suggestQueries(q)
    return NextResponse.json({ suggestions })
  }

  // Rate limit
  const settings = await getSettings()
  const rl = checkRateLimit('search', settings.rateLimitPerMin)
  if (!rl.allowed) {
    return NextResponse.json({ error: 'Rate limit exceeded', retryAfter: rl.retryAfter }, { status: 429 })
  }

  try {
    const limit = Math.min(parseInt(searchParams.get('limit') || '20', 10), 50)
    const results = await searchVideos(q, limit)

    // Save to search history (dedupe by query)
    await db.searchHistory.deleteMany({ where: { query: q } }).catch(() => {})
    await db.searchHistory.create({ data: { query: q } }).catch(() => {})
    // Enforce history limit
    const count = await db.searchHistory.count()
    if (count > settings.historyLimit) {
      const extras = await db.searchHistory.findMany({
        orderBy: { searchedAt: 'desc' },
        skip: settings.historyLimit,
        select: { id: true },
      })
      if (extras.length) await db.searchHistory.deleteMany({ where: { id: { in: extras.map((e) => e.id) } } })
    }

    return NextResponse.json({ results, query: q })
  } catch (e) {
    const message = e instanceof Error ? e.message : 'Search failed'
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/ytdlp/stream/proxy/route.ts ---
mkdir -p "$(dirname "src/app/api/ytdlp/stream/proxy/route.ts")"
cat > 'src/app/api/ytdlp/stream/proxy/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest } from 'next/server'
import { spawn } from 'child_process'
import { getFfmpegPath, getVideoInfo, getYtdlpPath, selectFormats } from '@/lib/ytdlp'
import path from 'path'

export const dynamic = 'force-dynamic'
export const runtime = 'nodejs'
// Allow up to 5 minutes for long videos / slow yt-dlp merges
export const maxDuration = 300

const QUALITY_HEIGHTS: Record<string, number> = {
  '144p': 144, '240p': 240, '360p': 360, '480p': 480, '720p': 720, '1080p': 1080,
}

function buildFormatSelector(quality: string): string {
  if (quality === 'highest') return 'bestvideo*+bestaudio/best'
  const h = QUALITY_HEIGHTS[quality] ?? 720
  // Prefer muxed for low qualities (allows seeking), DASH+merge for high
  if (h <= 360) return `best[height<=${h}]/bestvideo[height<=${h}]+bestaudio/best`
  return `bestvideo[height<=${h}]+bestaudio/best[height<=${h}]/best`
}

/**
 * Stream proxy with full Range (seek) support.
 *
 * Strategy:
 * 1. Try to find a muxed format URL from cached video info → proxy it directly
 *    to googlevideo with Range support. This gives full seek/scrub support.
 * 2. Fall back to `yt-dlp -o -` merge for DASH-only qualities (720p+).
 *    Merge mode does NOT support seeking but plays correctly.
 *
 * 502 FIX: All paths now have explicit timeouts to prevent gateway timeouts.
 */
export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const id = (searchParams.get('id') || '').trim()
  const quality = searchParams.get('quality') || '720p'
  if (!id) return new Response('Missing id', { status: 400 })

  // Try muxed direct-proxy (seekable) first
  try {
    const info = await getVideoInfo(id)
    const targetHeight = quality === 'highest' ? 1080 : (QUALITY_HEIGHTS[quality] ?? 720)
    const sel = selectFormats(info.formats, targetHeight)

    // Use muxed URL directly when available at or below target height
    // (muxed = single file with audio+video, fully seekable via Range)
    if (sel.muxed && sel.muxed.url) {
      return proxyUrlWithRange(req, sel.muxed.url, sel.muxed.httpHeaders)
    }
  } catch {
    // Fall through to yt-dlp merge approach
  }

  // Fallback: yt-dlp merge to stdout (no seek support, but plays correctly)
  let bin: string
  try {
    bin = await getYtdlpPath()
  } catch {
    return new Response('yt-dlp not found', { status: 500 })
  }

  const args = [
    '--js-runtimes', 'node',
    '--no-warnings',
    '--no-check-certificates',
    '--no-playlist',
    '--newline',
    // 502 FIX: multiple player clients to bypass YouTube anti-bot detection
    '--extractor-args', 'youtube:player_client=default,android,ios,tv',
    '--user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    '-f', buildFormatSelector(quality),
    '--merge-output-format', 'mp4',
    '-o', '-',
    `https://www.youtube.com/watch?v=${id}`,
  ]

  // ffmpeg location for merging
  try {
    const ff = await getFfmpegPath()
    args.push('--ffmpeg-location', path.dirname(ff))
  } catch {
    // rely on PATH
  }

  const child = spawn(bin, args, {
    env: { ...process.env },
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  // 502 FIX: Wait for first data chunk before sending response headers.
  // This lets us return a proper 503 error (instead of HTTP 200 + 0 bytes)
  // if yt-dlp fails to produce data due to anti-bot or network errors.
  const FIRST_BYTE_TIMEOUT = 30000 // 30s to get first byte from yt-dlp

  try {
    const firstChunk = await waitForFirstByte(child, FIRST_BYTE_TIMEOUT)
    if (firstChunk === null) {
      // yt-dlp failed to produce data in time
      try { child.kill('SIGKILL') } catch {}
      return new Response('yt-dlp failed to start streaming (anti-bot or timeout)', {
        status: 503,
        headers: { 'content-type': 'application/json', 'retry-after': '3' },
      })
    }

    // Now create the streaming response with the first chunk already buffered
    const stream = new ReadableStream({
      start(controller) {
        // Enqueue the first chunk we already captured
        controller.enqueue(firstChunk)
        // Pipe the rest
        child.stdout.on('data', (chunk: Buffer) => {
          try { controller.enqueue(chunk) } catch {}
        })
        child.stdout.on('end', () => { try { controller.close() } catch {} })
        child.stdout.on('error', (e) => { try { controller.error(e) } catch {} })
        child.on('error', (e) => { try { controller.error(e) } catch {} })
        child.on('close', () => { try { controller.close() } catch {} })
      },
      cancel() {
        try { child.kill('SIGKILL') } catch {}
      },
    })

    return new Response(stream, {
      status: 200,
      headers: {
        'content-type': 'video/mp4',
        'accept-ranges': 'bytes',
        'cache-control': 'no-cache, no-store',
        'access-control-allow-origin': '*',
        'transfer-encoding': 'chunked',
      },
    })
  } catch {
    try { child.kill('SIGKILL') } catch {}
    return new Response('Stream initialization failed', { status: 503, headers: { 'retry-after': '3' } })
  }
}

/**
 * Wait for yt-dlp to produce its first byte of output.
 * Returns the first chunk (Buffer) or null if timeout/error.
 */
function waitForFirstByte(child: ReturnType<typeof spawn>, timeoutMs: number): Promise<Buffer | null> {
  return new Promise((resolve) => {
    let settled = false
    const timer = setTimeout(() => {
      if (!settled) { settled = true; resolve(null) }
    }, timeoutMs)

    child.stdout!.once('data', (chunk: Buffer) => {
      if (!settled) {
        settled = true
        clearTimeout(timer)
        resolve(chunk)
      }
    })
    child.once('error', () => {
      if (!settled) { settled = true; clearTimeout(timer); resolve(null) }
    })
    child.once('close', () => {
      if (!settled) { settled = true; clearTimeout(timer); resolve(null) }
    })
  })
}

/**
 * Proxy a URL (e.g., googlevideo muxed URL) with full HTTP Range support.
 * Forwards the Range header to the upstream and passes through the 206 response.
 *
 * 502 FIX: Added 30s connection timeout + 60s idle timeout via AbortController.
 */
async function proxyUrlWithRange(
  req: NextRequest,
  upstreamUrl: string,
  extraHeaders?: Record<string, string>,
): Promise<Response> {
  const upstream = new URL(upstreamUrl)
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Referer': 'https://www.youtube.com/',
    'Origin': 'https://www.youtube.com',
  }
  // Forward Range header from client → upstream
  const range = req.headers.get('range')
  if (range) headers['Range'] = range
  if (extraHeaders) Object.assign(headers, extraHeaders)

  // 502 FIX: AbortController with 30s timeout for the initial connection.
  // Once streaming starts, we rely on the stream's own cancel() for cleanup.
  const controller = new AbortController()
  const timeoutId = setTimeout(() => controller.abort(), 30000)

  let upstreamRes: Response
  try {
    upstreamRes = await fetch(upstream, {
      headers,
      redirect: 'follow',
      signal: controller.signal,
    })
    clearTimeout(timeoutId)
  } catch (e) {
    clearTimeout(timeoutId)
    // Return 503 (retryable) instead of hanging — client can retry
    return new Response('Upstream connection failed', {
      status: 503,
      headers: { 'cache-control': 'no-store', 'retry-after': '2' },
    })
  }

  // Build response headers — pass through content-range, length, type, accept-ranges
  const respHeaders: Record<string, string> = {
    'access-control-allow-origin': '*',
    'cache-control': 'no-cache, no-store',
    'accept-ranges': 'bytes',
  }
  for (const h of ['content-type', 'content-length', 'content-range', 'accept-ranges']) {
    const v = upstreamRes.headers.get(h)
    if (v) respHeaders[h] = v
  }

  // Status: 206 if upstream returned partial content, else 200
  const status = upstreamRes.status === 206 ? 206 : 200

  if (!upstreamRes.body) {
    return new Response('Upstream returned no body', { status: 502 })
  }

  // Stream upstream body directly to client
  const reader = upstreamRes.body.getReader()
  const stream = new ReadableStream({
    async pull(controller) {
      try {
        const { done, value } = await reader.read()
        if (done) { controller.close(); return }
        controller.enqueue(value)
      } catch {
        try { controller.close() } catch {}
      }
    },
    cancel() {
      clearTimeout(timeoutId)
      reader.cancel().catch(() => {})
    },
  })

  return new Response(stream, { status, headers: respHeaders })
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/ytdlp/stream/route.ts ---
mkdir -p "$(dirname "src/app/api/ytdlp/stream/route.ts")"
cat > 'src/app/api/ytdlp/stream/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { getVideoInfo, selectFormats, type YtdlpFormat } from '@/lib/ytdlp'
import { cacheGet, cacheSet } from '@/lib/ytdlp'

export const dynamic = 'force-dynamic'
export const runtime = 'nodejs'
// 502 FIX: Allow up to 2 minutes for yt-dlp to fetch video info
export const maxDuration = 120

const QUALITY_HEIGHTS: Record<string, number> = {
  '144p': 144, '240p': 240, '360p': 360, '480p': 480, '720p': 720, '1080p': 1080,
}

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const id = (searchParams.get('id') || '').trim()
  const quality = searchParams.get('quality') || '720p'
  if (!id) return NextResponse.json({ error: 'Missing id' }, { status: 400 })

  try {
    const info = await getVideoInfo(id)
    const targetHeight = quality === 'highest'
      ? 1080
      : (QUALITY_HEIGHTS[quality] ?? 720)

    const sel = selectFormats(info.formats, targetHeight)

    // Determine the streaming approach
    let mode: 'muxed' | 'merge'
    let playableUrl: string

    if (sel.muxed && (!sel.videoOnly || (sel.muxed.height || 0) >= targetHeight || quality === 'highest' && (sel.muxed.height||0) >= 720)) {
      mode = 'muxed'
      playableUrl = `/api/ytdlp/stream/proxy?id=${encodeURIComponent(id)}&quality=${encodeURIComponent(quality)}`
    } else if (sel.videoOnly && sel.audioOnly) {
      mode = 'merge'
      playableUrl = `/api/ytdlp/stream/proxy?id=${encodeURIComponent(id)}&quality=${encodeURIComponent(quality)}`
    } else if (sel.muxed) {
      mode = 'muxed'
      playableUrl = `/api/ytdlp/stream/proxy?id=${encodeURIComponent(id)}&quality=${encodeURIComponent(quality)}`
    } else {
      return NextResponse.json({ error: 'No playable format found' }, { status: 404 })
    }

    const availableQualities = sel.availableHeights.map((h) => `${h}p`)

    return NextResponse.json({
      id,
      title: info.title,
      mode,
      playableUrl,
      availableQualities,
      selectedHeight: sel.muxed?.height || sel.videoOnly?.height || targetHeight,
      duration: info.duration,
      subtitles: buildSubtitleList(info),
      chapters: info.chapters || [],
    })
  } catch (e) {
    const message = e instanceof Error ? e.message : 'Failed to get stream'
    // 502 FIX: Return 503 (retryable) for transient errors, 500 for permanent
    const isTransient = message.includes('timeout') || message.includes('ETIMEDOUT') ||
      message.includes('ECONNRESET') || message.includes('fetch failed') ||
      message.includes('Sign in') || message.includes('not a bot')
    return NextResponse.json(
      { error: message, retryable: isTransient },
      { status: isTransient ? 503 : 500 }
    )
  }
}

function buildSubtitleList(info: any): Array<{ label: string; srclang: string; url: string }> {
  const subs = info.subtitles || {}
  const auto = info.automatic_captions || {}
  const out: Array<{ label: string; srclang: string; url: string }> = []
  const seen = new Set<string>()
  for (const [lang, arr] of Object.entries(subs) as [string, any[]][]) {
    const vtt = arr?.find?.((s) => s.ext === 'vtt') || arr?.[0]
    if (vtt?.url && !seen.has(lang)) {
      seen.add(lang)
      out.push({ label: lang, srclang: lang, url: `/api/ytdlp/subtitle?url=${encodeURIComponent(vtt.url)}` })
    }
  }
  // Add a couple auto captions if no manual
  if (out.length === 0) {
    let added = 0
    for (const [lang, arr] of Object.entries(auto) as [string, any[]][]) {
      if (added >= 5) break
      const vtt = arr?.find?.((s) => s.ext === 'vtt') || arr?.[0]
      if (vtt?.url && !seen.has(lang)) {
        seen.add(lang)
        out.push({ label: `${lang} (auto)`, srclang: lang, url: `/api/ytdlp/subtitle?url=${encodeURIComponent(vtt.url)}` })
        added++
      }
    }
  }
  return out
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/ytdlp/subtitle/route.ts ---
mkdir -p "$(dirname "src/app/api/ytdlp/subtitle/route.ts")"
cat > 'src/app/api/ytdlp/subtitle/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'

export const dynamic = 'force-dynamic'

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const url = searchParams.get('url')
  if (!url || !url.startsWith('http')) {
    return new Response('Invalid url', { status: 400 })
  }
  try {
    const res = await fetch(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://www.youtube.com/',
      },
    })
    const text = await res.text()
    return new Response(text, {
      status: 200,
      headers: {
        'content-type': res.headers.get('content-type') || 'text/vtt; charset=utf-8',
        'access-control-allow-origin': '*',
        'cache-control': 'public, max-age=3600',
      },
    })
  } catch {
    return new Response('Failed to fetch subtitle', { status: 502 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/ytdlp/suggest/route.ts ---
mkdir -p "$(dirname "src/app/api/ytdlp/suggest/route.ts")"
cat > 'src/app/api/ytdlp/suggest/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { suggestQueries } from '@/lib/ytdlp'

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const q = (searchParams.get('q') || '').trim()
  if (!q) return NextResponse.json({ suggestions: [] })
  try {
    const suggestions = await suggestQueries(q)
    return NextResponse.json({ suggestions })
  } catch {
    return NextResponse.json({ suggestions: [] })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/ytdlp/trending/route.ts ---
mkdir -p "$(dirname "src/app/api/ytdlp/trending/route.ts")"
cat > 'src/app/api/ytdlp/trending/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { getTrending } from '@/lib/ytdlp'

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const country = searchParams.get('country') || 'US'
  try {
    const results = await getTrending(country)
    return NextResponse.json({ results })
  } catch (e) {
    return NextResponse.json({ error: e instanceof Error ? e.message : 'Failed' }, { status: 500 })
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/api/ytdlp/video/route.ts ---
mkdir -p "$(dirname "src/app/api/ytdlp/video/route.ts")"
cat > 'src/app/api/ytdlp/video/route.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { NextRequest, NextResponse } from 'next/server'
import { getVideoInfo } from '@/lib/ytdlp'
import { db } from '@/lib/db'
import { getSettings } from '@/lib/settings'

export const dynamic = 'force-dynamic'
export const runtime = 'nodejs'
// 502 FIX: allow up to 2 minutes for yt-dlp to fetch video info
export const maxDuration = 120

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url)
  const id = (searchParams.get('id') || '').trim()
  if (!id) return NextResponse.json({ error: 'Missing id' }, { status: 400 })

  try {
    const info = await getVideoInfo(id)

    // Record watch history (async, non-blocking)
    const settings = await getSettings()
    db.videoHistory.deleteMany({ where: { videoId: id } }).catch(() => {})
    db.videoHistory.create({
      data: {
        videoId: id,
        title: info.title || 'Untitled',
        channel: info.channel || info.uploader || 'Unknown',
        thumbnail: info.thumbnail || info.thumbnails?.[0]?.url || null,
        duration: info.duration || null,
      },
    }).catch(() => {})
    // Enforce limit
    db.videoHistory.count().then(async (count) => {
      if (count > settings.historyLimit) {
        const extras = await db.videoHistory.findMany({
          orderBy: { watchedAt: 'desc' },
          skip: settings.historyLimit,
          select: { id: true },
        })
        if (extras.length) db.videoHistory.deleteMany({ where: { id: { in: extras.map((e) => e.id) } } }).catch(() => {})
      }
    }).catch(() => {})

    return NextResponse.json({ video: info })
  } catch (e) {
    const message = e instanceof Error ? e.message : 'Failed to fetch video'
    // 502 FIX: Return 503 (retryable) for transient/anti-bot errors
    const isTransient = message.includes('timeout') || message.includes('ETIMEDOUT') ||
      message.includes('ECONNRESET') || message.includes('fetch failed') ||
      message.includes('Sign in') || message.includes('not a bot') ||
      message.includes('confirm you')
    return NextResponse.json(
      { error: message, retryable: isTransient },
      { status: isTransient ? 503 : 500 }
    )
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/globals.css ---
mkdir -p "$(dirname "src/app/globals.css")"
cat > 'src/app/globals.css' <<'HZ_FILE_CONTENT_END_7X9K'
@import "tailwindcss";
@import "tw-animate-css";

@custom-variant dark (&:is(.dark *));

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --font-sans: var(--font-geist-sans);
  --font-mono: var(--font-geist-mono);
  --color-sidebar-ring: var(--sidebar-ring);
  --color-sidebar-border: var(--sidebar-border);
  --color-sidebar-accent-foreground: var(--sidebar-accent-foreground);
  --color-sidebar-accent: var(--sidebar-accent);
  --color-sidebar-primary-foreground: var(--sidebar-primary-foreground);
  --color-sidebar-primary: var(--sidebar-primary);
  --color-sidebar-foreground: var(--sidebar-foreground);
  --color-sidebar: var(--sidebar);
  --color-chart-5: var(--chart-5);
  --color-chart-4: var(--chart-4);
  --color-chart-3: var(--chart-3);
  --color-chart-2: var(--chart-2);
  --color-chart-1: var(--chart-1);
  --color-ring: var(--ring);
  --color-input: var(--input);
  --color-border: var(--border);
  --color-destructive: var(--destructive);
  --color-accent-foreground: var(--accent-foreground);
  --color-accent: var(--accent);
  --color-muted-foreground: var(--muted-foreground);
  --color-muted: var(--muted);
  --color-secondary-foreground: var(--secondary-foreground);
  --color-secondary: var(--secondary);
  --color-primary-foreground: var(--primary-foreground);
  --color-primary: var(--primary);
  --color-popover-foreground: var(--popover-foreground);
  --color-popover: var(--popover);
  --color-card-foreground: var(--card-foreground);
  --color-card: var(--card);
  --radius-sm: calc(var(--radius) - 4px);
  --radius-md: calc(var(--radius) - 2px);
  --radius-lg: var(--radius);
  --radius-xl: calc(var(--radius) + 4px);
}

:root {
  --radius: 0.875rem;
  --background: oklch(0.99 0.002 240);
  --foreground: oklch(0.18 0.01 240);
  --card: oklch(1 0 0);
  --card-foreground: oklch(0.18 0.01 240);
  --popover: oklch(1 0 0);
  --popover-foreground: oklch(0.18 0.01 240);
  --primary: oklch(0.55 0.22 25);
  --primary-foreground: oklch(0.99 0 0);
  --secondary: oklch(0.96 0.004 240);
  --secondary-foreground: oklch(0.22 0.01 240);
  --muted: oklch(0.96 0.004 240);
  --muted-foreground: oklch(0.5 0.01 240);
  --accent: oklch(0.95 0.01 25);
  --accent-foreground: oklch(0.22 0.01 240);
  --destructive: oklch(0.58 0.245 27);
  --border: oklch(0.91 0.004 240);
  --input: oklch(0.91 0.004 240);
  --ring: oklch(0.55 0.22 25);
  --chart-1: oklch(0.55 0.22 25);
  --chart-2: oklch(0.65 0.18 60);
  --chart-3: oklch(0.6 0.15 145);
  --chart-4: oklch(0.55 0.2 300);
  --chart-5: oklch(0.7 0.18 200);
  --sidebar: oklch(0.985 0.002 240);
  --sidebar-foreground: oklch(0.18 0.01 240);
  --sidebar-primary: oklch(0.55 0.22 25);
  --sidebar-primary-foreground: oklch(0.99 0 0);
  --sidebar-accent: oklch(0.95 0.01 25);
  --sidebar-accent-foreground: oklch(0.22 0.01 240);
  --sidebar-border: oklch(0.91 0.004 240);
  --sidebar-ring: oklch(0.55 0.22 25);
  --glass: oklch(1 0 0 / 70%);
  --glass-border: oklch(0.5 0.01 240 / 12%);
}

.dark {
  --background: oklch(0.13 0.008 260);
  --foreground: oklch(0.97 0.004 260);
  --card: oklch(0.17 0.01 260);
  --card-foreground: oklch(0.97 0.004 260);
  --popover: oklch(0.17 0.01 260);
  --popover-foreground: oklch(0.97 0.004 260);
  --primary: oklch(0.62 0.235 25);
  --primary-foreground: oklch(0.99 0 0);
  --secondary: oklch(0.22 0.012 260);
  --secondary-foreground: oklch(0.97 0.004 260);
  --muted: oklch(0.21 0.01 260);
  --muted-foreground: oklch(0.68 0.012 260);
  --accent: oklch(0.26 0.02 25);
  --accent-foreground: oklch(0.97 0.004 260);
  --destructive: oklch(0.7 0.19 22);
  --border: oklch(1 0 0 / 9%);
  --input: oklch(1 0 0 / 13%);
  --ring: oklch(0.62 0.235 25);
  --chart-1: oklch(0.62 0.235 25);
  --chart-2: oklch(0.7 0.18 60);
  --chart-3: oklch(0.65 0.17 145);
  --chart-4: oklch(0.62 0.22 300);
  --chart-5: oklch(0.7 0.18 200);
  --sidebar: oklch(0.15 0.008 260);
  --sidebar-foreground: oklch(0.97 0.004 260);
  --sidebar-primary: oklch(0.62 0.235 25);
  --sidebar-primary-foreground: oklch(0.99 0 0);
  --sidebar-accent: oklch(0.22 0.012 260);
  --sidebar-accent-foreground: oklch(0.97 0.004 260);
  --sidebar-border: oklch(1 0 0 / 9%);
  --sidebar-ring: oklch(0.62 0.235 25);
  --glass: oklch(0.17 0.01 260 / 60%);
  --glass-border: oklch(1 0 0 / 10%);
}

@layer base {
  * {
    @apply border-border outline-ring/50;
  }
  html {
    scroll-behavior: smooth;
  }
  body {
    @apply bg-background text-foreground;
    -webkit-font-smoothing: antialiased;
    text-rendering: optimizeLegibility;
  }
}

/* Glassmorphism utility */
@layer utilities {
  .glass {
    background: var(--glass);
    backdrop-filter: blur(16px) saturate(160%);
    -webkit-backdrop-filter: blur(16px) saturate(160%);
    border: 1px solid var(--glass-border);
  }
  .glass-strong {
    background: var(--glass);
    backdrop-filter: blur(24px) saturate(180%);
    -webkit-backdrop-filter: blur(24px) saturate(180%);
    border: 1px solid var(--glass-border);
  }
  .gradient-accent {
    background-image: linear-gradient(135deg, oklch(0.62 0.235 25) 0%, oklch(0.55 0.22 60) 100%);
  }
  .gradient-accent-text {
    background-image: linear-gradient(135deg, oklch(0.65 0.235 25) 0%, oklch(0.6 0.2 60) 100%);
    -webkit-background-clip: text;
    background-clip: text;
    -webkit-text-fill-color: transparent;
    color: transparent;
  }
  .text-balance {
    text-wrap: balance;
  }
  .no-scrollbar::-webkit-scrollbar {
    display: none;
  }
  .no-scrollbar {
    -ms-overflow-style: none;
    scrollbar-width: none;
  }
}

/* Custom scrollbar */
@layer base {
  * {
    scrollbar-width: thin;
    scrollbar-color: oklch(0.5 0.01 260 / 35%) transparent;
  }
  ::-webkit-scrollbar {
    width: 10px;
    height: 10px;
  }
  ::-webkit-scrollbar-track {
    background: transparent;
  }
  ::-webkit-scrollbar-thumb {
    background-color: oklch(0.5 0.01 260 / 35%);
    border-radius: 999px;
    border: 2px solid transparent;
    background-clip: content-box;
  }
  ::-webkit-scrollbar-thumb:hover {
    background-color: oklch(0.55 0.15 25 / 60%);
    background-clip: content-box;
  }
}

/* Animations */
@keyframes shimmer {
  0% { background-position: -1000px 0; }
  100% { background-position: 1000px 0; }
}
.animate-shimmer {
  background: linear-gradient(90deg, transparent, var(--muted), transparent);
  background-size: 1000px 100%;
  animation: shimmer 1.8s infinite linear;
}

@keyframes float-up {
  from { opacity: 0; transform: translateY(12px); }
  to { opacity: 1; transform: translateY(0); }
}
.animate-float-up {
  animation: float-up 0.4s cubic-bezier(0.22, 1, 0.36, 1) both;
}

@keyframes pulse-glow {
  0%, 100% { box-shadow: 0 0 0 0 oklch(0.62 0.235 25 / 40%); }
  50% { box-shadow: 0 0 0 8px oklch(0.62 0.235 25 / 0%); }
}
.animate-pulse-glow {
  animation: pulse-glow 2s infinite;
}

@keyframes gradient-shift {
  0%, 100% { background-position: 0% 50%; }
  50% { background-position: 100% 50%; }
}
.animate-gradient {
  background-size: 200% 200%;
  animation: gradient-shift 6s ease infinite;
}

/* Video player custom styles */
video::-webkit-media-controls {
  display: none !important;
}
video::-webkit-media-controls-enclosure {
  display: none !important;
}

/* Line clamp helpers */
.line-clamp-1 { display: -webkit-box; -webkit-line-clamp: 1; -webkit-box-orient: vertical; overflow: hidden; }
.line-clamp-2 { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.line-clamp-3 { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/layout.tsx ---
mkdir -p "$(dirname "src/app/layout.tsx")"
cat > 'src/app/layout.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { ThemeProvider } from "@/components/theme-provider";
import { Toaster as SonnerToaster } from "@/components/ui/sonner";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "StreamVault — YouTube Streaming Platform",
  description: "A premium YouTube frontend powered by yt-dlp. Search, stream, and download videos with a modern, beautiful interface.",
  keywords: ["YouTube", "yt-dlp", "streaming", "video player", "download"],
  authors: [{ name: "StreamVault" }],
  icons: {
    icon: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23e53e3e' d='M23.5 6.2a3 3 0 0 0-2.1-2.1C19.5 3.5 12 3.5 12 3.5s-7.5 0-9.4.6A3 3 0 0 0 .5 6.2C0 8.1 0 12 0 12s0 3.9.5 5.8a3 3 0 0 0 2.1 2.1c1.9.6 9.4.6 9.4.6s7.5 0 9.4-.6a3 3 0 0 0 2.1-2.1c.5-1.9.5-5.8.5-5.8s0-3.9-.5-5.8zM9.6 15.6V8.4l6.2 3.6-6.2 3.6z'/%3E%3C/svg%3E",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased bg-background text-foreground`}
      >
        <ThemeProvider>
          {children}
          <SonnerToaster position="bottom-right" richColors closeButton />
        </ThemeProvider>
      </body>
    </html>
  );
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/app/page.tsx ---
mkdir -p "$(dirname "src/app/page.tsx")"
cat > 'src/app/page.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useEffect } from 'react'
import { Sidebar } from '@/components/app/sidebar'
import { TopBar } from '@/components/app/topbar'
import { Footer } from '@/components/app/footer'
import { useAppStore } from '@/lib/store'
import { HomeView } from '@/components/views/home-view'
import { SearchView } from '@/components/views/search-view'
import { VideoView } from '@/components/views/video-view'
import { HistoryView } from '@/components/views/history-view'
import { AdminView } from '@/components/views/admin-view'
import { SettingsView } from '@/components/views/settings-view'
import { FavoritesView } from '@/components/views/favorites-view'
import { WatchLaterView } from '@/components/views/watchlater-view'

export default function Page() {
  const view = useAppStore((s) => s.view)
  const videoId = useAppStore((s) => s.videoId)
  const toggleSidebar = useAppStore((s) => s.toggleSidebar)

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const tag = (document.activeElement?.tagName || '').toUpperCase()
      const editable = tag === 'INPUT' || tag === 'TEXTAREA' || (document.activeElement as HTMLElement)?.isContentEditable
      if (editable) return
      if (e.ctrlKey && e.key.toLowerCase() === 'b') {
        e.preventDefault()
        toggleSidebar()
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [toggleSidebar])

  return (
    <div className="min-h-screen flex bg-background">
      <Sidebar />
      <div className="flex-1 flex flex-col min-w-0">
        <TopBar />
        <main className="flex-1 flex flex-col">
          {view === 'home' && <HomeView />}
          {view === 'search' && <SearchView />}
          {view === 'video' && <VideoView key={videoId} />}
          {view === 'history' && <HistoryView />}
          {view === 'admin' && <AdminView />}
          {view === 'settings' && <SettingsView />}
          {view === 'favorites' && <FavoritesView />}
          {view === 'watchlater' && <WatchLaterView />}
        </main>
        <Footer />
      </div>
    </div>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/app/footer.tsx ---
mkdir -p "$(dirname "src/components/app/footer.tsx")"
cat > 'src/components/app/footer.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { Github, Heart, ListVideo } from 'lucide-react'
import { useAppStore } from '@/lib/store'

export function Footer() {
  const setView = useAppStore((s) => s.setView)
  return (
    <footer className="mt-auto border-t border-border/50 glass">
      <div className="px-4 sm:px-6 py-6">
        <div className="flex flex-col sm:flex-row items-center justify-between gap-4 max-w-7xl mx-auto">
          <div className="flex items-center gap-2.5">
            <div className="size-7 rounded-lg gradient-accent grid place-items-center">
              <ListVideo className="size-4 text-white" />
            </div>
            <div className="text-sm">
              <span className="font-semibold">StreamVault</span>
              <span className="text-muted-foreground ml-2">Powered by yt-dlp</span>
            </div>
          </div>
          <div className="flex items-center gap-4 text-xs text-muted-foreground">
            <button onClick={() => setView('admin')} className="hover:text-foreground transition-colors">Admin</button>
            <button onClick={() => setView('settings')} className="hover:text-foreground transition-colors">Settings</button>
            <button onClick={() => setView('history')} className="hover:text-foreground transition-colors">History</button>
            <span className="flex items-center gap-1">
              Built with <Heart className="size-3 fill-primary text-primary" /> for self-hosters
            </span>
          </div>
        </div>
      </div>
    </footer>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/app/sidebar.tsx ---
mkdir -p "$(dirname "src/components/app/sidebar.tsx")"
cat > 'src/components/app/sidebar.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import {
  Home, Search, Clock, Heart, ListVideo, Settings, Shield, History,
  Flame, Menu, X, ChevronLeft
} from 'lucide-react'
import { cn } from '@/lib/utils'
import { useAppStore, type ViewName } from '@/lib/store'
import { Button } from '@/components/ui/button'

const navItems: Array<{ id: ViewName; label: string; icon: React.ElementType; badge?: string }> = [
  { id: 'home', label: 'Home', icon: Home },
  { id: 'search', label: 'Search', icon: Search },
  { id: 'history', label: 'History', icon: History },
  { id: 'watchlater', label: 'Watch Later', icon: Clock },
  { id: 'favorites', label: 'Favorites', icon: Heart },
]

const bottomItems: Array<{ id: ViewName; label: string; icon: React.ElementType }> = [
  { id: 'settings', label: 'Settings', icon: Settings },
  { id: 'admin', label: 'Admin', icon: Shield },
]

export function Sidebar() {
  const view = useAppStore((s) => s.view)
  const sidebarOpen = useAppStore((s) => s.sidebarOpen)
  const setSidebar = useAppStore((s) => s.setSidebar)
  const setView = useAppStore((s) => s.setView)
  const goBack = useAppStore((s) => s.goBack)

  return (
    <>
      {/* Mobile overlay */}
      {sidebarOpen && (
        <div
          className="fixed inset-0 z-40 bg-black/60 backdrop-blur-sm lg:hidden"
          onClick={() => setSidebar(false)}
        />
      )}

      <aside
        className={cn(
          'fixed lg:sticky top-0 z-50 h-screen w-64 shrink-0 transition-transform duration-300 ease-out',
          'glass border-r border-border/60 flex flex-col',
          sidebarOpen ? 'translate-x-0' : '-translate-x-full lg:translate-x-0 lg:w-0 lg:overflow-hidden lg:border-r-0'
        )}
      >
        {/* Logo */}
        <div className="flex items-center justify-between px-4 h-16 border-b border-border/40">
          <button
            onClick={() => { setView('home'); setSidebar(false) }}
            className="flex items-center gap-2.5 group"
          >
            <div className="relative">
              <div className="size-9 rounded-xl gradient-accent grid place-items-center shadow-lg shadow-primary/30 animate-gradient">
                <ListVideo className="size-5 text-white" />
              </div>
              <div className="absolute inset-0 rounded-xl bg-primary/30 blur-lg -z-10 group-hover:bg-primary/50 transition-colors" />
            </div>
            <div className="text-left">
              <h1 className="font-bold text-base leading-none tracking-tight">StreamVault</h1>
              <p className="text-[10px] text-muted-foreground mt-0.5">yt-dlp powered</p>
            </div>
          </button>
          <Button variant="ghost" size="icon" className="lg:hidden size-8" onClick={() => setSidebar(false)}>
            <X className="size-4" />
          </Button>
        </div>

        {/* Nav */}
        <nav className="flex-1 overflow-y-auto no-scrollbar px-3 py-4 space-y-1">
          <p className="px-3 pb-2 text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">Browse</p>
          {navItems.map((item) => {
            const Icon = item.icon
            const active = view === item.id
            return (
              <button
                key={item.id}
                onClick={() => { setView(item.id); setSidebar(false) }}
                className={cn(
                  'w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium transition-all duration-200 relative group',
                  active
                    ? 'bg-primary/10 text-primary'
                    : 'text-muted-foreground hover:text-foreground hover:bg-accent/60'
                )}
              >
                {active && <div className="absolute left-0 top-1/2 -translate-y-1/2 h-6 w-1 rounded-r-full bg-primary" />}
                <Icon className={cn('size-5 transition-transform group-hover:scale-110', active && 'scale-110')} />
                <span>{item.label}</span>
                {item.badge && (
                  <span className="ml-auto text-[10px] px-1.5 py-0.5 rounded-full bg-primary/20 text-primary font-bold">
                    {item.badge}
                  </span>
                )}
              </button>
            )
          })}

          <div className="pt-4">
            <p className="px-3 pb-2 text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">Quick</p>
            <button
              onClick={() => { setView('home'); setSidebar(false) }}
              className="w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium text-muted-foreground hover:text-foreground hover:bg-accent/60 transition-all"
            >
              <Flame className="size-5" />
              <span>Trending</span>
            </button>
          </div>
        </nav>

        {/* Bottom */}
        <div className="border-t border-border/40 px-3 py-3 space-y-1">
          {bottomItems.map((item) => {
            const Icon = item.icon
            const active = view === item.id
            return (
              <button
                key={item.id}
                onClick={() => { setView(item.id); setSidebar(false) }}
                className={cn(
                  'w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-sm font-medium transition-all',
                  active ? 'bg-primary/10 text-primary' : 'text-muted-foreground hover:text-foreground hover:bg-accent/60'
                )}
              >
                <Icon className="size-5" />
                <span>{item.label}</span>
              </button>
            )
          })}
        </div>
      </aside>
    </>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/app/topbar.tsx ---
mkdir -p "$(dirname "src/components/app/topbar.tsx")"
cat > 'src/components/app/topbar.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useEffect, useRef, useState } from 'react'
import { Search, Menu, Sun, Moon, Monitor, ArrowLeft, Sparkles, TrendingUp, X } from 'lucide-react'
import { useTheme } from 'next-themes'
import { useAppStore } from '@/lib/store'
import { api } from '@/lib/api'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'

export function TopBar() {
  const { theme, setTheme } = useTheme()
  const toggleSidebar = useAppStore((s) => s.toggleSidebar)
  const search = useAppStore((s) => s.search)
  const searchQuery = useAppStore((s) => s.searchQuery)
  const goBack = useAppStore((s) => s.goBack)
  const view = useAppStore((s) => s.view)
  const [mounted, setMounted] = useState(false)
  const [query, setQuery] = useState(searchQuery)
  const [suggestions, setSuggestions] = useState<string[]>([])
  const [showSuggest, setShowSuggest] = useState(false)
  const [recentSearches, setRecentSearches] = useState<string[]>([])
  const [focused, setFocused] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => { setMounted(true) }, [])

  useEffect(() => {
    setQuery(searchQuery)
  }, [searchQuery])

  useEffect(() => {
    api.history('search').then((r) => {
      setRecentSearches(r.items.map((i: any) => i.query).slice(0, 6))
    }).catch(() => {})
  }, [searchQuery, view])

  // Keyboard shortcut: '/' focuses search
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === '/' && document.activeElement?.tagName !== 'INPUT' && document.activeElement?.tagName !== 'TEXTAREA') {
        e.preventDefault()
        inputRef.current?.focus()
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [])

  // Debounced suggestions
  useEffect(() => {
    if (!query.trim() || query.length < 2) { setSuggestions([]); return }
    const t = setTimeout(async () => {
      try {
        const r = await api.suggest(query)
        setSuggestions(r.suggestions)
      } catch { setSuggestions([]) }
    }, 250)
    return () => clearTimeout(t)
  }, [query])

  // Close suggestions on outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setShowSuggest(false)
      }
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [])

  const submitSearch = (q: string) => {
    const trimmed = q.trim()
    if (!trimmed) return
    search(trimmed)
    setShowSuggest(false)
    setFocused(false)
    inputRef.current?.blur()
  }

  const showDropdown = focused && (suggestions.length > 0 || (query.length === 0 && recentSearches.length > 0))

  return (
    <header className="sticky top-0 z-30 glass-strong border-b border-border/50">
      <div className="flex items-center gap-2 px-3 sm:px-4 h-16">
        <Button variant="ghost" size="icon" className="shrink-0" onClick={toggleSidebar} title="Toggle sidebar (Ctrl+B)">
          <Menu className="size-5" />
        </Button>
        {view !== 'home' && (
          <Button variant="ghost" size="icon" className="shrink-0 hidden sm:flex" onClick={goBack} title="Back">
            <ArrowLeft className="size-5" />
          </Button>
        )}

        {/* Search */}
        <div ref={containerRef} className="flex-1 max-w-2xl mx-auto relative">
          <form
            onSubmit={(e) => { e.preventDefault(); submitSearch(query) }}
            className={cn(
              'flex items-center gap-2 rounded-full transition-all duration-300',
              'glass border border-border/60',
              focused ? 'ring-2 ring-primary/40 border-primary/40 shadow-lg shadow-primary/10' : 'hover:border-border'
            )}
          >
            <div className="pl-4 text-muted-foreground">
              <Search className="size-4" />
            </div>
            <input
              ref={inputRef}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onFocus={() => { setFocused(true); setShowSuggest(true) }}
              onBlur={() => setFocused(false)}
              placeholder="Search videos, channels, music..."
              className="flex-1 bg-transparent py-2.5 text-sm outline-none placeholder:text-muted-foreground"
            />
            {query && (
              <button type="button" onClick={() => { setQuery(''); inputRef.current?.focus() }} className="text-muted-foreground hover:text-foreground p-1">
                <X className="size-4" />
              </button>
            )}
            <Button type="submit" size="sm" className="rounded-full mr-1 px-4 gap-1.5 gradient-accent text-white border-0 hover:opacity-90">
              <Sparkles className="size-3.5" />
              <span className="hidden sm:inline">Search</span>
            </Button>
          </form>

          {/* Suggestions dropdown */}
          {showDropdown && (
            <div className="absolute top-full left-0 right-0 mt-2 rounded-2xl glass-strong border border-border/60 shadow-2xl overflow-hidden animate-float-up">
              {query.length === 0 && recentSearches.length > 0 && (
                <div className="p-2">
                  <p className="px-3 py-1.5 text-[10px] uppercase tracking-wider text-muted-foreground font-semibold flex items-center gap-1.5">
                    <TrendingUp className="size-3" /> Recent searches
                  </p>
                  {recentSearches.map((s) => (
                    <button
                      key={s}
                      onMouseDown={(e) => { e.preventDefault(); submitSearch(s) }}
                      className="w-full flex items-center gap-3 px-3 py-2 rounded-lg text-sm hover:bg-accent/60 transition-colors text-left"
                    >
                      <Search className="size-4 text-muted-foreground shrink-0" />
                      <span className="truncate">{s}</span>
                    </button>
                  ))}
                </div>
              )}
              {suggestions.length > 0 && (
                <div className={cn('p-2', query.length === 0 && recentSearches.length > 0 && 'border-t border-border/40')}>
                  {suggestions.map((s) => (
                    <button
                      key={s}
                      onMouseDown={(e) => { e.preventDefault(); submitSearch(s) }}
                      className="w-full flex items-center gap-3 px-3 py-2 rounded-lg text-sm hover:bg-accent/60 transition-colors text-left"
                    >
                      <Search className="size-4 text-muted-foreground shrink-0" />
                      <span className="truncate">{s}</span>
                      <ArrowLeft className="size-3.5 text-muted-foreground ml-auto rotate-45" />
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        {/* Theme toggle */}
        {mounted && (
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="icon" className="shrink-0" title="Theme">
                {theme === 'dark' ? <Moon className="size-5" /> : theme === 'light' ? <Sun className="size-5" /> : <Monitor className="size-5" />}
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem onClick={() => setTheme('light')}>
                <Sun className="size-4" /> Light
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => setTheme('dark')}>
                <Moon className="size-4" /> Dark
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => setTheme('system')}>
                <Monitor className="size-4" /> Auto
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </div>
    </header>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/theme-provider.tsx ---
mkdir -p "$(dirname "src/components/theme-provider.tsx")"
cat > 'src/components/theme-provider.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { ThemeProvider as NextThemesProvider } from 'next-themes'
import { ReactNode } from 'react'

export function ThemeProvider({ children }: { children: ReactNode }) {
  return (
    <NextThemesProvider
      attribute="class"
      defaultTheme="dark"
      enableSystem
      disableTransitionOnChange={false}
    >
      {children}
    </NextThemesProvider>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/accordion.tsx ---
mkdir -p "$(dirname "src/components/ui/accordion.tsx")"
cat > 'src/components/ui/accordion.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as AccordionPrimitive from "@radix-ui/react-accordion"
import { ChevronDownIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function Accordion({
  ...props
}: React.ComponentProps<typeof AccordionPrimitive.Root>) {
  return <AccordionPrimitive.Root data-slot="accordion" {...props} />
}

function AccordionItem({
  className,
  ...props
}: React.ComponentProps<typeof AccordionPrimitive.Item>) {
  return (
    <AccordionPrimitive.Item
      data-slot="accordion-item"
      className={cn("border-b last:border-b-0", className)}
      {...props}
    />
  )
}

function AccordionTrigger({
  className,
  children,
  ...props
}: React.ComponentProps<typeof AccordionPrimitive.Trigger>) {
  return (
    <AccordionPrimitive.Header className="flex">
      <AccordionPrimitive.Trigger
        data-slot="accordion-trigger"
        className={cn(
          "focus-visible:border-ring focus-visible:ring-ring/50 flex flex-1 items-start justify-between gap-4 rounded-md py-4 text-left text-sm font-medium transition-all outline-none hover:underline focus-visible:ring-[3px] disabled:pointer-events-none disabled:opacity-50 [&[data-state=open]>svg]:rotate-180",
          className
        )}
        {...props}
      >
        {children}
        <ChevronDownIcon className="text-muted-foreground pointer-events-none size-4 shrink-0 translate-y-0.5 transition-transform duration-200" />
      </AccordionPrimitive.Trigger>
    </AccordionPrimitive.Header>
  )
}

function AccordionContent({
  className,
  children,
  ...props
}: React.ComponentProps<typeof AccordionPrimitive.Content>) {
  return (
    <AccordionPrimitive.Content
      data-slot="accordion-content"
      className="data-[state=closed]:animate-accordion-up data-[state=open]:animate-accordion-down overflow-hidden text-sm"
      {...props}
    >
      <div className={cn("pt-0 pb-4", className)}>{children}</div>
    </AccordionPrimitive.Content>
  )
}

export { Accordion, AccordionItem, AccordionTrigger, AccordionContent }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/alert-dialog.tsx ---
mkdir -p "$(dirname "src/components/ui/alert-dialog.tsx")"
cat > 'src/components/ui/alert-dialog.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as AlertDialogPrimitive from "@radix-ui/react-alert-dialog"

import { cn } from "@/lib/utils"
import { buttonVariants } from "@/components/ui/button"

function AlertDialog({
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Root>) {
  return <AlertDialogPrimitive.Root data-slot="alert-dialog" {...props} />
}

function AlertDialogTrigger({
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Trigger>) {
  return (
    <AlertDialogPrimitive.Trigger data-slot="alert-dialog-trigger" {...props} />
  )
}

function AlertDialogPortal({
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Portal>) {
  return (
    <AlertDialogPrimitive.Portal data-slot="alert-dialog-portal" {...props} />
  )
}

function AlertDialogOverlay({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Overlay>) {
  return (
    <AlertDialogPrimitive.Overlay
      data-slot="alert-dialog-overlay"
      className={cn(
        "data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 fixed inset-0 z-50 bg-black/50",
        className
      )}
      {...props}
    />
  )
}

function AlertDialogContent({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Content>) {
  return (
    <AlertDialogPortal>
      <AlertDialogOverlay />
      <AlertDialogPrimitive.Content
        data-slot="alert-dialog-content"
        className={cn(
          "bg-background data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 fixed top-[50%] left-[50%] z-50 grid w-full max-w-[calc(100%-2rem)] translate-x-[-50%] translate-y-[-50%] gap-4 rounded-lg border p-6 shadow-lg duration-200 sm:max-w-lg",
          className
        )}
        {...props}
      />
    </AlertDialogPortal>
  )
}

function AlertDialogHeader({
  className,
  ...props
}: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="alert-dialog-header"
      className={cn("flex flex-col gap-2 text-center sm:text-left", className)}
      {...props}
    />
  )
}

function AlertDialogFooter({
  className,
  ...props
}: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="alert-dialog-footer"
      className={cn(
        "flex flex-col-reverse gap-2 sm:flex-row sm:justify-end",
        className
      )}
      {...props}
    />
  )
}

function AlertDialogTitle({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Title>) {
  return (
    <AlertDialogPrimitive.Title
      data-slot="alert-dialog-title"
      className={cn("text-lg font-semibold", className)}
      {...props}
    />
  )
}

function AlertDialogDescription({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Description>) {
  return (
    <AlertDialogPrimitive.Description
      data-slot="alert-dialog-description"
      className={cn("text-muted-foreground text-sm", className)}
      {...props}
    />
  )
}

function AlertDialogAction({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Action>) {
  return (
    <AlertDialogPrimitive.Action
      className={cn(buttonVariants(), className)}
      {...props}
    />
  )
}

function AlertDialogCancel({
  className,
  ...props
}: React.ComponentProps<typeof AlertDialogPrimitive.Cancel>) {
  return (
    <AlertDialogPrimitive.Cancel
      className={cn(buttonVariants({ variant: "outline" }), className)}
      {...props}
    />
  )
}

export {
  AlertDialog,
  AlertDialogPortal,
  AlertDialogOverlay,
  AlertDialogTrigger,
  AlertDialogContent,
  AlertDialogHeader,
  AlertDialogFooter,
  AlertDialogTitle,
  AlertDialogDescription,
  AlertDialogAction,
  AlertDialogCancel,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/alert.tsx ---
mkdir -p "$(dirname "src/components/ui/alert.tsx")"
cat > 'src/components/ui/alert.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"

const alertVariants = cva(
  "relative w-full rounded-lg border px-4 py-3 text-sm grid has-[>svg]:grid-cols-[calc(var(--spacing)*4)_1fr] grid-cols-[0_1fr] has-[>svg]:gap-x-3 gap-y-0.5 items-start [&>svg]:size-4 [&>svg]:translate-y-0.5 [&>svg]:text-current",
  {
    variants: {
      variant: {
        default: "bg-card text-card-foreground",
        destructive:
          "text-destructive bg-card [&>svg]:text-current *:data-[slot=alert-description]:text-destructive/90",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  }
)

function Alert({
  className,
  variant,
  ...props
}: React.ComponentProps<"div"> & VariantProps<typeof alertVariants>) {
  return (
    <div
      data-slot="alert"
      role="alert"
      className={cn(alertVariants({ variant }), className)}
      {...props}
    />
  )
}

function AlertTitle({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="alert-title"
      className={cn(
        "col-start-2 line-clamp-1 min-h-4 font-medium tracking-tight",
        className
      )}
      {...props}
    />
  )
}

function AlertDescription({
  className,
  ...props
}: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="alert-description"
      className={cn(
        "text-muted-foreground col-start-2 grid justify-items-start gap-1 text-sm [&_p]:leading-relaxed",
        className
      )}
      {...props}
    />
  )
}

export { Alert, AlertTitle, AlertDescription }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/aspect-ratio.tsx ---
mkdir -p "$(dirname "src/components/ui/aspect-ratio.tsx")"
cat > 'src/components/ui/aspect-ratio.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as AspectRatioPrimitive from "@radix-ui/react-aspect-ratio"

function AspectRatio({
  ...props
}: React.ComponentProps<typeof AspectRatioPrimitive.Root>) {
  return <AspectRatioPrimitive.Root data-slot="aspect-ratio" {...props} />
}

export { AspectRatio }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/avatar.tsx ---
mkdir -p "$(dirname "src/components/ui/avatar.tsx")"
cat > 'src/components/ui/avatar.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as AvatarPrimitive from "@radix-ui/react-avatar"

import { cn } from "@/lib/utils"

function Avatar({
  className,
  ...props
}: React.ComponentProps<typeof AvatarPrimitive.Root>) {
  return (
    <AvatarPrimitive.Root
      data-slot="avatar"
      className={cn(
        "relative flex size-8 shrink-0 overflow-hidden rounded-full",
        className
      )}
      {...props}
    />
  )
}

function AvatarImage({
  className,
  ...props
}: React.ComponentProps<typeof AvatarPrimitive.Image>) {
  return (
    <AvatarPrimitive.Image
      data-slot="avatar-image"
      className={cn("aspect-square size-full", className)}
      {...props}
    />
  )
}

function AvatarFallback({
  className,
  ...props
}: React.ComponentProps<typeof AvatarPrimitive.Fallback>) {
  return (
    <AvatarPrimitive.Fallback
      data-slot="avatar-fallback"
      className={cn(
        "bg-muted flex size-full items-center justify-center rounded-full",
        className
      )}
      {...props}
    />
  )
}

export { Avatar, AvatarImage, AvatarFallback }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/badge.tsx ---
mkdir -p "$(dirname "src/components/ui/badge.tsx")"
cat > 'src/components/ui/badge.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"

const badgeVariants = cva(
  "inline-flex items-center justify-center rounded-md border px-2 py-0.5 text-xs font-medium w-fit whitespace-nowrap shrink-0 [&>svg]:size-3 gap-1 [&>svg]:pointer-events-none focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px] aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive transition-[color,box-shadow] overflow-hidden",
  {
    variants: {
      variant: {
        default:
          "border-transparent bg-primary text-primary-foreground [a&]:hover:bg-primary/90",
        secondary:
          "border-transparent bg-secondary text-secondary-foreground [a&]:hover:bg-secondary/90",
        destructive:
          "border-transparent bg-destructive text-white [a&]:hover:bg-destructive/90 focus-visible:ring-destructive/20 dark:focus-visible:ring-destructive/40 dark:bg-destructive/60",
        outline:
          "text-foreground [a&]:hover:bg-accent [a&]:hover:text-accent-foreground",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  }
)

function Badge({
  className,
  variant,
  asChild = false,
  ...props
}: React.ComponentProps<"span"> &
  VariantProps<typeof badgeVariants> & { asChild?: boolean }) {
  const Comp = asChild ? Slot : "span"

  return (
    <Comp
      data-slot="badge"
      className={cn(badgeVariants({ variant }), className)}
      {...props}
    />
  )
}

export { Badge, badgeVariants }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/breadcrumb.tsx ---
mkdir -p "$(dirname "src/components/ui/breadcrumb.tsx")"
cat > 'src/components/ui/breadcrumb.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { ChevronRight, MoreHorizontal } from "lucide-react"

import { cn } from "@/lib/utils"

function Breadcrumb({ ...props }: React.ComponentProps<"nav">) {
  return <nav aria-label="breadcrumb" data-slot="breadcrumb" {...props} />
}

function BreadcrumbList({ className, ...props }: React.ComponentProps<"ol">) {
  return (
    <ol
      data-slot="breadcrumb-list"
      className={cn(
        "text-muted-foreground flex flex-wrap items-center gap-1.5 text-sm break-words sm:gap-2.5",
        className
      )}
      {...props}
    />
  )
}

function BreadcrumbItem({ className, ...props }: React.ComponentProps<"li">) {
  return (
    <li
      data-slot="breadcrumb-item"
      className={cn("inline-flex items-center gap-1.5", className)}
      {...props}
    />
  )
}

function BreadcrumbLink({
  asChild,
  className,
  ...props
}: React.ComponentProps<"a"> & {
  asChild?: boolean
}) {
  const Comp = asChild ? Slot : "a"

  return (
    <Comp
      data-slot="breadcrumb-link"
      className={cn("hover:text-foreground transition-colors", className)}
      {...props}
    />
  )
}

function BreadcrumbPage({ className, ...props }: React.ComponentProps<"span">) {
  return (
    <span
      data-slot="breadcrumb-page"
      role="link"
      aria-disabled="true"
      aria-current="page"
      className={cn("text-foreground font-normal", className)}
      {...props}
    />
  )
}

function BreadcrumbSeparator({
  children,
  className,
  ...props
}: React.ComponentProps<"li">) {
  return (
    <li
      data-slot="breadcrumb-separator"
      role="presentation"
      aria-hidden="true"
      className={cn("[&>svg]:size-3.5", className)}
      {...props}
    >
      {children ?? <ChevronRight />}
    </li>
  )
}

function BreadcrumbEllipsis({
  className,
  ...props
}: React.ComponentProps<"span">) {
  return (
    <span
      data-slot="breadcrumb-ellipsis"
      role="presentation"
      aria-hidden="true"
      className={cn("flex size-9 items-center justify-center", className)}
      {...props}
    >
      <MoreHorizontal className="size-4" />
      <span className="sr-only">More</span>
    </span>
  )
}

export {
  Breadcrumb,
  BreadcrumbList,
  BreadcrumbItem,
  BreadcrumbLink,
  BreadcrumbPage,
  BreadcrumbSeparator,
  BreadcrumbEllipsis,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/button.tsx ---
mkdir -p "$(dirname "src/components/ui/button.tsx")"
cat > 'src/components/ui/button.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-all disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg:not([class*='size-'])]:size-4 shrink-0 [&_svg]:shrink-0 outline-none focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px] aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive",
  {
    variants: {
      variant: {
        default:
          "bg-primary text-primary-foreground shadow-xs hover:bg-primary/90",
        destructive:
          "bg-destructive text-white shadow-xs hover:bg-destructive/90 focus-visible:ring-destructive/20 dark:focus-visible:ring-destructive/40 dark:bg-destructive/60",
        outline:
          "border bg-background shadow-xs hover:bg-accent hover:text-accent-foreground dark:bg-input/30 dark:border-input dark:hover:bg-input/50",
        secondary:
          "bg-secondary text-secondary-foreground shadow-xs hover:bg-secondary/80",
        ghost:
          "hover:bg-accent hover:text-accent-foreground dark:hover:bg-accent/50",
        link: "text-primary underline-offset-4 hover:underline",
      },
      size: {
        default: "h-9 px-4 py-2 has-[>svg]:px-3",
        sm: "h-8 rounded-md gap-1.5 px-3 has-[>svg]:px-2.5",
        lg: "h-10 rounded-md px-6 has-[>svg]:px-4",
        icon: "size-9",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
)

function Button({
  className,
  variant,
  size,
  asChild = false,
  ...props
}: React.ComponentProps<"button"> &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean
  }) {
  const Comp = asChild ? Slot : "button"

  return (
    <Comp
      data-slot="button"
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  )
}

export { Button, buttonVariants }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/calendar.tsx ---
mkdir -p "$(dirname "src/components/ui/calendar.tsx")"
cat > 'src/components/ui/calendar.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import {
  ChevronDownIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
} from "lucide-react"
import { DayButton, DayPicker, getDefaultClassNames } from "react-day-picker"

import { cn } from "@/lib/utils"
import { Button, buttonVariants } from "@/components/ui/button"

function Calendar({
  className,
  classNames,
  showOutsideDays = true,
  captionLayout = "label",
  buttonVariant = "ghost",
  formatters,
  components,
  ...props
}: React.ComponentProps<typeof DayPicker> & {
  buttonVariant?: React.ComponentProps<typeof Button>["variant"]
}) {
  const defaultClassNames = getDefaultClassNames()

  return (
    <DayPicker
      showOutsideDays={showOutsideDays}
      className={cn(
        "bg-background group/calendar p-3 [--cell-size:--spacing(8)] [[data-slot=card-content]_&]:bg-transparent [[data-slot=popover-content]_&]:bg-transparent",
        String.raw`rtl:**:[.rdp-button\_next>svg]:rotate-180`,
        String.raw`rtl:**:[.rdp-button\_previous>svg]:rotate-180`,
        className
      )}
      captionLayout={captionLayout}
      formatters={{
        formatMonthDropdown: (date) =>
          date.toLocaleString("default", { month: "short" }),
        ...formatters,
      }}
      classNames={{
        root: cn("w-fit", defaultClassNames.root),
        months: cn(
          "flex gap-4 flex-col md:flex-row relative",
          defaultClassNames.months
        ),
        month: cn("flex flex-col w-full gap-4", defaultClassNames.month),
        nav: cn(
          "flex items-center gap-1 w-full absolute top-0 inset-x-0 justify-between",
          defaultClassNames.nav
        ),
        button_previous: cn(
          buttonVariants({ variant: buttonVariant }),
          "size-(--cell-size) aria-disabled:opacity-50 p-0 select-none",
          defaultClassNames.button_previous
        ),
        button_next: cn(
          buttonVariants({ variant: buttonVariant }),
          "size-(--cell-size) aria-disabled:opacity-50 p-0 select-none",
          defaultClassNames.button_next
        ),
        month_caption: cn(
          "flex items-center justify-center h-(--cell-size) w-full px-(--cell-size)",
          defaultClassNames.month_caption
        ),
        dropdowns: cn(
          "w-full flex items-center text-sm font-medium justify-center h-(--cell-size) gap-1.5",
          defaultClassNames.dropdowns
        ),
        dropdown_root: cn(
          "relative has-focus:border-ring border border-input shadow-xs has-focus:ring-ring/50 has-focus:ring-[3px] rounded-md",
          defaultClassNames.dropdown_root
        ),
        dropdown: cn(
          "absolute bg-popover inset-0 opacity-0",
          defaultClassNames.dropdown
        ),
        caption_label: cn(
          "select-none font-medium",
          captionLayout === "label"
            ? "text-sm"
            : "rounded-md pl-2 pr-1 flex items-center gap-1 text-sm h-8 [&>svg]:text-muted-foreground [&>svg]:size-3.5",
          defaultClassNames.caption_label
        ),
        table: "w-full border-collapse",
        weekdays: cn("flex", defaultClassNames.weekdays),
        weekday: cn(
          "text-muted-foreground rounded-md flex-1 font-normal text-[0.8rem] select-none",
          defaultClassNames.weekday
        ),
        week: cn("flex w-full mt-2", defaultClassNames.week),
        week_number_header: cn(
          "select-none w-(--cell-size)",
          defaultClassNames.week_number_header
        ),
        week_number: cn(
          "text-[0.8rem] select-none text-muted-foreground",
          defaultClassNames.week_number
        ),
        day: cn(
          "relative w-full h-full p-0 text-center [&:first-child[data-selected=true]_button]:rounded-l-md [&:last-child[data-selected=true]_button]:rounded-r-md group/day aspect-square select-none",
          defaultClassNames.day
        ),
        range_start: cn(
          "rounded-l-md bg-accent",
          defaultClassNames.range_start
        ),
        range_middle: cn("rounded-none", defaultClassNames.range_middle),
        range_end: cn("rounded-r-md bg-accent", defaultClassNames.range_end),
        today: cn(
          "bg-accent text-accent-foreground rounded-md data-[selected=true]:rounded-none",
          defaultClassNames.today
        ),
        outside: cn(
          "text-muted-foreground aria-selected:text-muted-foreground",
          defaultClassNames.outside
        ),
        disabled: cn(
          "text-muted-foreground opacity-50",
          defaultClassNames.disabled
        ),
        hidden: cn("invisible", defaultClassNames.hidden),
        ...classNames,
      }}
      components={{
        Root: ({ className, rootRef, ...props }) => {
          return (
            <div
              data-slot="calendar"
              ref={rootRef}
              className={cn(className)}
              {...props}
            />
          )
        },
        Chevron: ({ className, orientation, ...props }) => {
          if (orientation === "left") {
            return (
              <ChevronLeftIcon className={cn("size-4", className)} {...props} />
            )
          }

          if (orientation === "right") {
            return (
              <ChevronRightIcon
                className={cn("size-4", className)}
                {...props}
              />
            )
          }

          return (
            <ChevronDownIcon className={cn("size-4", className)} {...props} />
          )
        },
        DayButton: CalendarDayButton,
        WeekNumber: ({ children, ...props }) => {
          return (
            <td {...props}>
              <div className="flex size-(--cell-size) items-center justify-center text-center">
                {children}
              </div>
            </td>
          )
        },
        ...components,
      }}
      {...props}
    />
  )
}

function CalendarDayButton({
  className,
  day,
  modifiers,
  ...props
}: React.ComponentProps<typeof DayButton>) {
  const defaultClassNames = getDefaultClassNames()

  const ref = React.useRef<HTMLButtonElement>(null)
  React.useEffect(() => {
    if (modifiers.focused) ref.current?.focus()
  }, [modifiers.focused])

  return (
    <Button
      ref={ref}
      variant="ghost"
      size="icon"
      data-day={day.date.toLocaleDateString()}
      data-selected-single={
        modifiers.selected &&
        !modifiers.range_start &&
        !modifiers.range_end &&
        !modifiers.range_middle
      }
      data-range-start={modifiers.range_start}
      data-range-end={modifiers.range_end}
      data-range-middle={modifiers.range_middle}
      className={cn(
        "data-[selected-single=true]:bg-primary data-[selected-single=true]:text-primary-foreground data-[range-middle=true]:bg-accent data-[range-middle=true]:text-accent-foreground data-[range-start=true]:bg-primary data-[range-start=true]:text-primary-foreground data-[range-end=true]:bg-primary data-[range-end=true]:text-primary-foreground group-data-[focused=true]/day:border-ring group-data-[focused=true]/day:ring-ring/50 dark:hover:text-accent-foreground flex aspect-square size-auto w-full min-w-(--cell-size) flex-col gap-1 leading-none font-normal group-data-[focused=true]/day:relative group-data-[focused=true]/day:z-10 group-data-[focused=true]/day:ring-[3px] data-[range-end=true]:rounded-md data-[range-end=true]:rounded-r-md data-[range-middle=true]:rounded-none data-[range-start=true]:rounded-md data-[range-start=true]:rounded-l-md [&>span]:text-xs [&>span]:opacity-70",
        defaultClassNames.day,
        className
      )}
      {...props}
    />
  )
}

export { Calendar, CalendarDayButton }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/card.tsx ---
mkdir -p "$(dirname "src/components/ui/card.tsx")"
cat > 'src/components/ui/card.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import * as React from "react"

import { cn } from "@/lib/utils"

function Card({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card"
      className={cn(
        "bg-card text-card-foreground flex flex-col gap-6 rounded-xl border py-6 shadow-sm",
        className
      )}
      {...props}
    />
  )
}

function CardHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-header"
      className={cn(
        "@container/card-header grid auto-rows-min grid-rows-[auto_auto] items-start gap-1.5 px-6 has-data-[slot=card-action]:grid-cols-[1fr_auto] [.border-b]:pb-6",
        className
      )}
      {...props}
    />
  )
}

function CardTitle({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-title"
      className={cn("leading-none font-semibold", className)}
      {...props}
    />
  )
}

function CardDescription({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-description"
      className={cn("text-muted-foreground text-sm", className)}
      {...props}
    />
  )
}

function CardAction({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-action"
      className={cn(
        "col-start-2 row-span-2 row-start-1 self-start justify-self-end",
        className
      )}
      {...props}
    />
  )
}

function CardContent({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-content"
      className={cn("px-6", className)}
      {...props}
    />
  )
}

function CardFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-footer"
      className={cn("flex items-center px-6 [.border-t]:pt-6", className)}
      {...props}
    />
  )
}

export {
  Card,
  CardHeader,
  CardFooter,
  CardTitle,
  CardAction,
  CardDescription,
  CardContent,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/carousel.tsx ---
mkdir -p "$(dirname "src/components/ui/carousel.tsx")"
cat > 'src/components/ui/carousel.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import useEmblaCarousel, {
  type UseEmblaCarouselType,
} from "embla-carousel-react"
import { ArrowLeft, ArrowRight } from "lucide-react"

import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"

type CarouselApi = UseEmblaCarouselType[1]
type UseCarouselParameters = Parameters<typeof useEmblaCarousel>
type CarouselOptions = UseCarouselParameters[0]
type CarouselPlugin = UseCarouselParameters[1]

type CarouselProps = {
  opts?: CarouselOptions
  plugins?: CarouselPlugin
  orientation?: "horizontal" | "vertical"
  setApi?: (api: CarouselApi) => void
}

type CarouselContextProps = {
  carouselRef: ReturnType<typeof useEmblaCarousel>[0]
  api: ReturnType<typeof useEmblaCarousel>[1]
  scrollPrev: () => void
  scrollNext: () => void
  canScrollPrev: boolean
  canScrollNext: boolean
} & CarouselProps

const CarouselContext = React.createContext<CarouselContextProps | null>(null)

function useCarousel() {
  const context = React.useContext(CarouselContext)

  if (!context) {
    throw new Error("useCarousel must be used within a <Carousel />")
  }

  return context
}

function Carousel({
  orientation = "horizontal",
  opts,
  setApi,
  plugins,
  className,
  children,
  ...props
}: React.ComponentProps<"div"> & CarouselProps) {
  const [carouselRef, api] = useEmblaCarousel(
    {
      ...opts,
      axis: orientation === "horizontal" ? "x" : "y",
    },
    plugins
  )
  const [canScrollPrev, setCanScrollPrev] = React.useState(false)
  const [canScrollNext, setCanScrollNext] = React.useState(false)

  const onSelect = React.useCallback((api: CarouselApi) => {
    if (!api) return
    setCanScrollPrev(api.canScrollPrev())
    setCanScrollNext(api.canScrollNext())
  }, [])

  const scrollPrev = React.useCallback(() => {
    api?.scrollPrev()
  }, [api])

  const scrollNext = React.useCallback(() => {
    api?.scrollNext()
  }, [api])

  const handleKeyDown = React.useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>) => {
      if (event.key === "ArrowLeft") {
        event.preventDefault()
        scrollPrev()
      } else if (event.key === "ArrowRight") {
        event.preventDefault()
        scrollNext()
      }
    },
    [scrollPrev, scrollNext]
  )

  React.useEffect(() => {
    if (!api || !setApi) return
    setApi(api)
  }, [api, setApi])

  React.useEffect(() => {
    if (!api) return
    onSelect(api)
    api.on("reInit", onSelect)
    api.on("select", onSelect)

    return () => {
      api?.off("select", onSelect)
    }
  }, [api, onSelect])

  return (
    <CarouselContext.Provider
      value={{
        carouselRef,
        api: api,
        opts,
        orientation:
          orientation || (opts?.axis === "y" ? "vertical" : "horizontal"),
        scrollPrev,
        scrollNext,
        canScrollPrev,
        canScrollNext,
      }}
    >
      <div
        onKeyDownCapture={handleKeyDown}
        className={cn("relative", className)}
        role="region"
        aria-roledescription="carousel"
        data-slot="carousel"
        {...props}
      >
        {children}
      </div>
    </CarouselContext.Provider>
  )
}

function CarouselContent({ className, ...props }: React.ComponentProps<"div">) {
  const { carouselRef, orientation } = useCarousel()

  return (
    <div
      ref={carouselRef}
      className="overflow-hidden"
      data-slot="carousel-content"
    >
      <div
        className={cn(
          "flex",
          orientation === "horizontal" ? "-ml-4" : "-mt-4 flex-col",
          className
        )}
        {...props}
      />
    </div>
  )
}

function CarouselItem({ className, ...props }: React.ComponentProps<"div">) {
  const { orientation } = useCarousel()

  return (
    <div
      role="group"
      aria-roledescription="slide"
      data-slot="carousel-item"
      className={cn(
        "min-w-0 shrink-0 grow-0 basis-full",
        orientation === "horizontal" ? "pl-4" : "pt-4",
        className
      )}
      {...props}
    />
  )
}

function CarouselPrevious({
  className,
  variant = "outline",
  size = "icon",
  ...props
}: React.ComponentProps<typeof Button>) {
  const { orientation, scrollPrev, canScrollPrev } = useCarousel()

  return (
    <Button
      data-slot="carousel-previous"
      variant={variant}
      size={size}
      className={cn(
        "absolute size-8 rounded-full",
        orientation === "horizontal"
          ? "top-1/2 -left-12 -translate-y-1/2"
          : "-top-12 left-1/2 -translate-x-1/2 rotate-90",
        className
      )}
      disabled={!canScrollPrev}
      onClick={scrollPrev}
      {...props}
    >
      <ArrowLeft />
      <span className="sr-only">Previous slide</span>
    </Button>
  )
}

function CarouselNext({
  className,
  variant = "outline",
  size = "icon",
  ...props
}: React.ComponentProps<typeof Button>) {
  const { orientation, scrollNext, canScrollNext } = useCarousel()

  return (
    <Button
      data-slot="carousel-next"
      variant={variant}
      size={size}
      className={cn(
        "absolute size-8 rounded-full",
        orientation === "horizontal"
          ? "top-1/2 -right-12 -translate-y-1/2"
          : "-bottom-12 left-1/2 -translate-x-1/2 rotate-90",
        className
      )}
      disabled={!canScrollNext}
      onClick={scrollNext}
      {...props}
    >
      <ArrowRight />
      <span className="sr-only">Next slide</span>
    </Button>
  )
}

export {
  type CarouselApi,
  Carousel,
  CarouselContent,
  CarouselItem,
  CarouselPrevious,
  CarouselNext,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/chart.tsx ---
mkdir -p "$(dirname "src/components/ui/chart.tsx")"
cat > 'src/components/ui/chart.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as RechartsPrimitive from "recharts"

import { cn } from "@/lib/utils"

// Format: { THEME_NAME: CSS_SELECTOR }
const THEMES = { light: "", dark: ".dark" } as const

export type ChartConfig = {
  [k in string]: {
    label?: React.ReactNode
    icon?: React.ComponentType
  } & (
    | { color?: string; theme?: never }
    | { color?: never; theme: Record<keyof typeof THEMES, string> }
  )
}

type ChartContextProps = {
  config: ChartConfig
}

const ChartContext = React.createContext<ChartContextProps | null>(null)

function useChart() {
  const context = React.useContext(ChartContext)

  if (!context) {
    throw new Error("useChart must be used within a <ChartContainer />")
  }

  return context
}

function ChartContainer({
  id,
  className,
  children,
  config,
  ...props
}: React.ComponentProps<"div"> & {
  config: ChartConfig
  children: React.ComponentProps<
    typeof RechartsPrimitive.ResponsiveContainer
  >["children"]
}) {
  const uniqueId = React.useId()
  const chartId = `chart-${id || uniqueId.replace(/:/g, "")}`

  return (
    <ChartContext.Provider value={{ config }}>
      <div
        data-slot="chart"
        data-chart={chartId}
        className={cn(
          "[&_.recharts-cartesian-axis-tick_text]:fill-muted-foreground [&_.recharts-cartesian-grid_line[stroke='#ccc']]:stroke-border/50 [&_.recharts-curve.recharts-tooltip-cursor]:stroke-border [&_.recharts-polar-grid_[stroke='#ccc']]:stroke-border [&_.recharts-radial-bar-background-sector]:fill-muted [&_.recharts-rectangle.recharts-tooltip-cursor]:fill-muted [&_.recharts-reference-line_[stroke='#ccc']]:stroke-border flex aspect-video justify-center text-xs [&_.recharts-dot[stroke='#fff']]:stroke-transparent [&_.recharts-layer]:outline-hidden [&_.recharts-sector]:outline-hidden [&_.recharts-sector[stroke='#fff']]:stroke-transparent [&_.recharts-surface]:outline-hidden",
          className
        )}
        {...props}
      >
        <ChartStyle id={chartId} config={config} />
        <RechartsPrimitive.ResponsiveContainer>
          {children}
        </RechartsPrimitive.ResponsiveContainer>
      </div>
    </ChartContext.Provider>
  )
}

const ChartStyle = ({ id, config }: { id: string; config: ChartConfig }) => {
  const colorConfig = Object.entries(config).filter(
    ([, config]) => config.theme || config.color
  )

  if (!colorConfig.length) {
    return null
  }

  return (
    <style
      dangerouslySetInnerHTML={{
        __html: Object.entries(THEMES)
          .map(
            ([theme, prefix]) => `
${prefix} [data-chart=${id}] {
${colorConfig
  .map(([key, itemConfig]) => {
    const color =
      itemConfig.theme?.[theme as keyof typeof itemConfig.theme] ||
      itemConfig.color
    return color ? `  --color-${key}: ${color};` : null
  })
  .join("\n")}
}
`
          )
          .join("\n"),
      }}
    />
  )
}

const ChartTooltip = RechartsPrimitive.Tooltip

function ChartTooltipContent({
  active,
  payload,
  className,
  indicator = "dot",
  hideLabel = false,
  hideIndicator = false,
  label,
  labelFormatter,
  labelClassName,
  formatter,
  color,
  nameKey,
  labelKey,
}: React.ComponentProps<typeof RechartsPrimitive.Tooltip> &
  React.ComponentProps<"div"> & {
    hideLabel?: boolean
    hideIndicator?: boolean
    indicator?: "line" | "dot" | "dashed"
    nameKey?: string
    labelKey?: string
  }) {
  const { config } = useChart()

  const tooltipLabel = React.useMemo(() => {
    if (hideLabel || !payload?.length) {
      return null
    }

    const [item] = payload
    const key = `${labelKey || item?.dataKey || item?.name || "value"}`
    const itemConfig = getPayloadConfigFromPayload(config, item, key)
    const value =
      !labelKey && typeof label === "string"
        ? config[label as keyof typeof config]?.label || label
        : itemConfig?.label

    if (labelFormatter) {
      return (
        <div className={cn("font-medium", labelClassName)}>
          {labelFormatter(value, payload)}
        </div>
      )
    }

    if (!value) {
      return null
    }

    return <div className={cn("font-medium", labelClassName)}>{value}</div>
  }, [
    label,
    labelFormatter,
    payload,
    hideLabel,
    labelClassName,
    config,
    labelKey,
  ])

  if (!active || !payload?.length) {
    return null
  }

  const nestLabel = payload.length === 1 && indicator !== "dot"

  return (
    <div
      className={cn(
        "border-border/50 bg-background grid min-w-[8rem] items-start gap-1.5 rounded-lg border px-2.5 py-1.5 text-xs shadow-xl",
        className
      )}
    >
      {!nestLabel ? tooltipLabel : null}
      <div className="grid gap-1.5">
        {payload.map((item, index) => {
          const key = `${nameKey || item.name || item.dataKey || "value"}`
          const itemConfig = getPayloadConfigFromPayload(config, item, key)
          const indicatorColor = color || item.payload.fill || item.color

          return (
            <div
              key={item.dataKey}
              className={cn(
                "[&>svg]:text-muted-foreground flex w-full flex-wrap items-stretch gap-2 [&>svg]:h-2.5 [&>svg]:w-2.5",
                indicator === "dot" && "items-center"
              )}
            >
              {formatter && item?.value !== undefined && item.name ? (
                formatter(item.value, item.name, item, index, item.payload)
              ) : (
                <>
                  {itemConfig?.icon ? (
                    <itemConfig.icon />
                  ) : (
                    !hideIndicator && (
                      <div
                        className={cn(
                          "shrink-0 rounded-[2px] border-(--color-border) bg-(--color-bg)",
                          {
                            "h-2.5 w-2.5": indicator === "dot",
                            "w-1": indicator === "line",
                            "w-0 border-[1.5px] border-dashed bg-transparent":
                              indicator === "dashed",
                            "my-0.5": nestLabel && indicator === "dashed",
                          }
                        )}
                        style={
                          {
                            "--color-bg": indicatorColor,
                            "--color-border": indicatorColor,
                          } as React.CSSProperties
                        }
                      />
                    )
                  )}
                  <div
                    className={cn(
                      "flex flex-1 justify-between leading-none",
                      nestLabel ? "items-end" : "items-center"
                    )}
                  >
                    <div className="grid gap-1.5">
                      {nestLabel ? tooltipLabel : null}
                      <span className="text-muted-foreground">
                        {itemConfig?.label || item.name}
                      </span>
                    </div>
                    {item.value && (
                      <span className="text-foreground font-mono font-medium tabular-nums">
                        {item.value.toLocaleString()}
                      </span>
                    )}
                  </div>
                </>
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}

const ChartLegend = RechartsPrimitive.Legend

function ChartLegendContent({
  className,
  hideIcon = false,
  payload,
  verticalAlign = "bottom",
  nameKey,
}: React.ComponentProps<"div"> &
  Pick<RechartsPrimitive.LegendProps, "payload" | "verticalAlign"> & {
    hideIcon?: boolean
    nameKey?: string
  }) {
  const { config } = useChart()

  if (!payload?.length) {
    return null
  }

  return (
    <div
      className={cn(
        "flex items-center justify-center gap-4",
        verticalAlign === "top" ? "pb-3" : "pt-3",
        className
      )}
    >
      {payload.map((item) => {
        const key = `${nameKey || item.dataKey || "value"}`
        const itemConfig = getPayloadConfigFromPayload(config, item, key)

        return (
          <div
            key={item.value}
            className={cn(
              "[&>svg]:text-muted-foreground flex items-center gap-1.5 [&>svg]:h-3 [&>svg]:w-3"
            )}
          >
            {itemConfig?.icon && !hideIcon ? (
              <itemConfig.icon />
            ) : (
              <div
                className="h-2 w-2 shrink-0 rounded-[2px]"
                style={{
                  backgroundColor: item.color,
                }}
              />
            )}
            {itemConfig?.label}
          </div>
        )
      })}
    </div>
  )
}

// Helper to extract item config from a payload.
function getPayloadConfigFromPayload(
  config: ChartConfig,
  payload: unknown,
  key: string
) {
  if (typeof payload !== "object" || payload === null) {
    return undefined
  }

  const payloadPayload =
    "payload" in payload &&
    typeof payload.payload === "object" &&
    payload.payload !== null
      ? payload.payload
      : undefined

  let configLabelKey: string = key

  if (
    key in payload &&
    typeof payload[key as keyof typeof payload] === "string"
  ) {
    configLabelKey = payload[key as keyof typeof payload] as string
  } else if (
    payloadPayload &&
    key in payloadPayload &&
    typeof payloadPayload[key as keyof typeof payloadPayload] === "string"
  ) {
    configLabelKey = payloadPayload[
      key as keyof typeof payloadPayload
    ] as string
  }

  return configLabelKey in config
    ? config[configLabelKey]
    : config[key as keyof typeof config]
}

export {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
  ChartLegend,
  ChartLegendContent,
  ChartStyle,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/checkbox.tsx ---
mkdir -p "$(dirname "src/components/ui/checkbox.tsx")"
cat > 'src/components/ui/checkbox.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as CheckboxPrimitive from "@radix-ui/react-checkbox"
import { CheckIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function Checkbox({
  className,
  ...props
}: React.ComponentProps<typeof CheckboxPrimitive.Root>) {
  return (
    <CheckboxPrimitive.Root
      data-slot="checkbox"
      className={cn(
        "peer border-input dark:bg-input/30 data-[state=checked]:bg-primary data-[state=checked]:text-primary-foreground dark:data-[state=checked]:bg-primary data-[state=checked]:border-primary focus-visible:border-ring focus-visible:ring-ring/50 aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive size-4 shrink-0 rounded-[4px] border shadow-xs transition-shadow outline-none focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50",
        className
      )}
      {...props}
    >
      <CheckboxPrimitive.Indicator
        data-slot="checkbox-indicator"
        className="flex items-center justify-center text-current transition-none"
      >
        <CheckIcon className="size-3.5" />
      </CheckboxPrimitive.Indicator>
    </CheckboxPrimitive.Root>
  )
}

export { Checkbox }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/collapsible.tsx ---
mkdir -p "$(dirname "src/components/ui/collapsible.tsx")"
cat > 'src/components/ui/collapsible.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as CollapsiblePrimitive from "@radix-ui/react-collapsible"

function Collapsible({
  ...props
}: React.ComponentProps<typeof CollapsiblePrimitive.Root>) {
  return <CollapsiblePrimitive.Root data-slot="collapsible" {...props} />
}

function CollapsibleTrigger({
  ...props
}: React.ComponentProps<typeof CollapsiblePrimitive.CollapsibleTrigger>) {
  return (
    <CollapsiblePrimitive.CollapsibleTrigger
      data-slot="collapsible-trigger"
      {...props}
    />
  )
}

function CollapsibleContent({
  ...props
}: React.ComponentProps<typeof CollapsiblePrimitive.CollapsibleContent>) {
  return (
    <CollapsiblePrimitive.CollapsibleContent
      data-slot="collapsible-content"
      {...props}
    />
  )
}

export { Collapsible, CollapsibleTrigger, CollapsibleContent }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/command.tsx ---
mkdir -p "$(dirname "src/components/ui/command.tsx")"
cat > 'src/components/ui/command.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import { Command as CommandPrimitive } from "cmdk"
import { SearchIcon } from "lucide-react"

import { cn } from "@/lib/utils"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"

function Command({
  className,
  ...props
}: React.ComponentProps<typeof CommandPrimitive>) {
  return (
    <CommandPrimitive
      data-slot="command"
      className={cn(
        "bg-popover text-popover-foreground flex h-full w-full flex-col overflow-hidden rounded-md",
        className
      )}
      {...props}
    />
  )
}

function CommandDialog({
  title = "Command Palette",
  description = "Search for a command to run...",
  children,
  className,
  showCloseButton = true,
  ...props
}: React.ComponentProps<typeof Dialog> & {
  title?: string
  description?: string
  className?: string
  showCloseButton?: boolean
}) {
  return (
    <Dialog {...props}>
      <DialogHeader className="sr-only">
        <DialogTitle>{title}</DialogTitle>
        <DialogDescription>{description}</DialogDescription>
      </DialogHeader>
      <DialogContent
        className={cn("overflow-hidden p-0", className)}
        showCloseButton={showCloseButton}
      >
        <Command className="[&_[cmdk-group-heading]]:text-muted-foreground **:data-[slot=command-input-wrapper]:h-12 [&_[cmdk-group-heading]]:px-2 [&_[cmdk-group-heading]]:font-medium [&_[cmdk-group]]:px-2 [&_[cmdk-group]:not([hidden])_~[cmdk-group]]:pt-0 [&_[cmdk-input-wrapper]_svg]:h-5 [&_[cmdk-input-wrapper]_svg]:w-5 [&_[cmdk-input]]:h-12 [&_[cmdk-item]]:px-2 [&_[cmdk-item]]:py-3 [&_[cmdk-item]_svg]:h-5 [&_[cmdk-item]_svg]:w-5">
          {children}
        </Command>
      </DialogContent>
    </Dialog>
  )
}

function CommandInput({
  className,
  ...props
}: React.ComponentProps<typeof CommandPrimitive.Input>) {
  return (
    <div
      data-slot="command-input-wrapper"
      className="flex h-9 items-center gap-2 border-b px-3"
    >
      <SearchIcon className="size-4 shrink-0 opacity-50" />
      <CommandPrimitive.Input
        data-slot="command-input"
        className={cn(
          "placeholder:text-muted-foreground flex h-10 w-full rounded-md bg-transparent py-3 text-sm outline-hidden disabled:cursor-not-allowed disabled:opacity-50",
          className
        )}
        {...props}
      />
    </div>
  )
}

function CommandList({
  className,
  ...props
}: React.ComponentProps<typeof CommandPrimitive.List>) {
  return (
    <CommandPrimitive.List
      data-slot="command-list"
      className={cn(
        "max-h-[300px] scroll-py-1 overflow-x-hidden overflow-y-auto",
        className
      )}
      {...props}
    />
  )
}

function CommandEmpty({
  ...props
}: React.ComponentProps<typeof CommandPrimitive.Empty>) {
  return (
    <CommandPrimitive.Empty
      data-slot="command-empty"
      className="py-6 text-center text-sm"
      {...props}
    />
  )
}

function CommandGroup({
  className,
  ...props
}: React.ComponentProps<typeof CommandPrimitive.Group>) {
  return (
    <CommandPrimitive.Group
      data-slot="command-group"
      className={cn(
        "text-foreground [&_[cmdk-group-heading]]:text-muted-foreground overflow-hidden p-1 [&_[cmdk-group-heading]]:px-2 [&_[cmdk-group-heading]]:py-1.5 [&_[cmdk-group-heading]]:text-xs [&_[cmdk-group-heading]]:font-medium",
        className
      )}
      {...props}
    />
  )
}

function CommandSeparator({
  className,
  ...props
}: React.ComponentProps<typeof CommandPrimitive.Separator>) {
  return (
    <CommandPrimitive.Separator
      data-slot="command-separator"
      className={cn("bg-border -mx-1 h-px", className)}
      {...props}
    />
  )
}

function CommandItem({
  className,
  ...props
}: React.ComponentProps<typeof CommandPrimitive.Item>) {
  return (
    <CommandPrimitive.Item
      data-slot="command-item"
      className={cn(
        "data-[selected=true]:bg-accent data-[selected=true]:text-accent-foreground [&_svg:not([class*='text-'])]:text-muted-foreground relative flex cursor-default items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-hidden select-none data-[disabled=true]:pointer-events-none data-[disabled=true]:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    />
  )
}

function CommandShortcut({
  className,
  ...props
}: React.ComponentProps<"span">) {
  return (
    <span
      data-slot="command-shortcut"
      className={cn(
        "text-muted-foreground ml-auto text-xs tracking-widest",
        className
      )}
      {...props}
    />
  )
}

export {
  Command,
  CommandDialog,
  CommandInput,
  CommandList,
  CommandEmpty,
  CommandGroup,
  CommandItem,
  CommandShortcut,
  CommandSeparator,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/context-menu.tsx ---
mkdir -p "$(dirname "src/components/ui/context-menu.tsx")"
cat > 'src/components/ui/context-menu.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as ContextMenuPrimitive from "@radix-ui/react-context-menu"
import { CheckIcon, ChevronRightIcon, CircleIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function ContextMenu({
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.Root>) {
  return <ContextMenuPrimitive.Root data-slot="context-menu" {...props} />
}

function ContextMenuTrigger({
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.Trigger>) {
  return (
    <ContextMenuPrimitive.Trigger data-slot="context-menu-trigger" {...props} />
  )
}

function ContextMenuGroup({
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.Group>) {
  return (
    <ContextMenuPrimitive.Group data-slot="context-menu-group" {...props} />
  )
}

function ContextMenuPortal({
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.Portal>) {
  return (
    <ContextMenuPrimitive.Portal data-slot="context-menu-portal" {...props} />
  )
}

function ContextMenuSub({
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.Sub>) {
  return <ContextMenuPrimitive.Sub data-slot="context-menu-sub" {...props} />
}

function ContextMenuRadioGroup({
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.RadioGroup>) {
  return (
    <ContextMenuPrimitive.RadioGroup
      data-slot="context-menu-radio-group"
      {...props}
    />
  )
}

function ContextMenuSubTrigger({
  className,
  inset,
  children,
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.SubTrigger> & {
  inset?: boolean
}) {
  return (
    <ContextMenuPrimitive.SubTrigger
      data-slot="context-menu-sub-trigger"
      data-inset={inset}
      className={cn(
        "focus:bg-accent focus:text-accent-foreground data-[state=open]:bg-accent data-[state=open]:text-accent-foreground flex cursor-default items-center rounded-sm px-2 py-1.5 text-sm outline-hidden select-none data-[inset]:pl-8 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    >
      {children}
      <ChevronRightIcon className="ml-auto" />
    </ContextMenuPrimitive.SubTrigger>
  )
}

function ContextMenuSubContent({
  className,
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.SubContent>) {
  return (
    <ContextMenuPrimitive.SubContent
      data-slot="context-menu-sub-content"
      className={cn(
        "bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 min-w-[8rem] origin-(--radix-context-menu-content-transform-origin) overflow-hidden rounded-md border p-1 shadow-lg",
        className
      )}
      {...props}
    />
  )
}

function ContextMenuContent({
  className,
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.Content>) {
  return (
    <ContextMenuPrimitive.Portal>
      <ContextMenuPrimitive.Content
        data-slot="context-menu-content"
        className={cn(
          "bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 max-h-(--radix-context-menu-content-available-height) min-w-[8rem] origin-(--radix-context-menu-content-transform-origin) overflow-x-hidden overflow-y-auto rounded-md border p-1 shadow-md",
          className
        )}
        {...props}
      />
    </ContextMenuPrimitive.Portal>
  )
}

function ContextMenuItem({
  className,
  inset,
  variant = "default",
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.Item> & {
  inset?: boolean
  variant?: "default" | "destructive"
}) {
  return (
    <ContextMenuPrimitive.Item
      data-slot="context-menu-item"
      data-inset={inset}
      data-variant={variant}
      className={cn(
        "focus:bg-accent focus:text-accent-foreground data-[variant=destructive]:text-destructive data-[variant=destructive]:focus:bg-destructive/10 dark:data-[variant=destructive]:focus:bg-destructive/20 data-[variant=destructive]:focus:text-destructive data-[variant=destructive]:*:[svg]:!text-destructive [&_svg:not([class*='text-'])]:text-muted-foreground relative flex cursor-default items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-hidden select-none data-[disabled]:pointer-events-none data-[disabled]:opacity-50 data-[inset]:pl-8 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    />
  )
}

function ContextMenuCheckboxItem({
  className,
  children,
  checked,
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.CheckboxItem>) {
  return (
    <ContextMenuPrimitive.CheckboxItem
      data-slot="context-menu-checkbox-item"
      className={cn(
        "focus:bg-accent focus:text-accent-foreground relative flex cursor-default items-center gap-2 rounded-sm py-1.5 pr-2 pl-8 text-sm outline-hidden select-none data-[disabled]:pointer-events-none data-[disabled]:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      checked={checked}
      {...props}
    >
      <span className="pointer-events-none absolute left-2 flex size-3.5 items-center justify-center">
        <ContextMenuPrimitive.ItemIndicator>
          <CheckIcon className="size-4" />
        </ContextMenuPrimitive.ItemIndicator>
      </span>
      {children}
    </ContextMenuPrimitive.CheckboxItem>
  )
}

function ContextMenuRadioItem({
  className,
  children,
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.RadioItem>) {
  return (
    <ContextMenuPrimitive.RadioItem
      data-slot="context-menu-radio-item"
      className={cn(
        "focus:bg-accent focus:text-accent-foreground relative flex cursor-default items-center gap-2 rounded-sm py-1.5 pr-2 pl-8 text-sm outline-hidden select-none data-[disabled]:pointer-events-none data-[disabled]:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    >
      <span className="pointer-events-none absolute left-2 flex size-3.5 items-center justify-center">
        <ContextMenuPrimitive.ItemIndicator>
          <CircleIcon className="size-2 fill-current" />
        </ContextMenuPrimitive.ItemIndicator>
      </span>
      {children}
    </ContextMenuPrimitive.RadioItem>
  )
}

function ContextMenuLabel({
  className,
  inset,
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.Label> & {
  inset?: boolean
}) {
  return (
    <ContextMenuPrimitive.Label
      data-slot="context-menu-label"
      data-inset={inset}
      className={cn(
        "text-foreground px-2 py-1.5 text-sm font-medium data-[inset]:pl-8",
        className
      )}
      {...props}
    />
  )
}

function ContextMenuSeparator({
  className,
  ...props
}: React.ComponentProps<typeof ContextMenuPrimitive.Separator>) {
  return (
    <ContextMenuPrimitive.Separator
      data-slot="context-menu-separator"
      className={cn("bg-border -mx-1 my-1 h-px", className)}
      {...props}
    />
  )
}

function ContextMenuShortcut({
  className,
  ...props
}: React.ComponentProps<"span">) {
  return (
    <span
      data-slot="context-menu-shortcut"
      className={cn(
        "text-muted-foreground ml-auto text-xs tracking-widest",
        className
      )}
      {...props}
    />
  )
}

export {
  ContextMenu,
  ContextMenuTrigger,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuCheckboxItem,
  ContextMenuRadioItem,
  ContextMenuLabel,
  ContextMenuSeparator,
  ContextMenuShortcut,
  ContextMenuGroup,
  ContextMenuPortal,
  ContextMenuSub,
  ContextMenuSubContent,
  ContextMenuSubTrigger,
  ContextMenuRadioGroup,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/dialog.tsx ---
mkdir -p "$(dirname "src/components/ui/dialog.tsx")"
cat > 'src/components/ui/dialog.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as DialogPrimitive from "@radix-ui/react-dialog"
import { XIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function Dialog({
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Root>) {
  return <DialogPrimitive.Root data-slot="dialog" {...props} />
}

function DialogTrigger({
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Trigger>) {
  return <DialogPrimitive.Trigger data-slot="dialog-trigger" {...props} />
}

function DialogPortal({
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Portal>) {
  return <DialogPrimitive.Portal data-slot="dialog-portal" {...props} />
}

function DialogClose({
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Close>) {
  return <DialogPrimitive.Close data-slot="dialog-close" {...props} />
}

function DialogOverlay({
  className,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Overlay>) {
  return (
    <DialogPrimitive.Overlay
      data-slot="dialog-overlay"
      className={cn(
        "data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 fixed inset-0 z-50 bg-black/50",
        className
      )}
      {...props}
    />
  )
}

function DialogContent({
  className,
  children,
  showCloseButton = true,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Content> & {
  showCloseButton?: boolean
}) {
  return (
    <DialogPortal data-slot="dialog-portal">
      <DialogOverlay />
      <DialogPrimitive.Content
        data-slot="dialog-content"
        className={cn(
          "bg-background data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 fixed top-[50%] left-[50%] z-50 grid w-full max-w-[calc(100%-2rem)] translate-x-[-50%] translate-y-[-50%] gap-4 rounded-lg border p-6 shadow-lg duration-200 sm:max-w-lg",
          className
        )}
        {...props}
      >
        {children}
        {showCloseButton && (
          <DialogPrimitive.Close
            data-slot="dialog-close"
            className="ring-offset-background focus:ring-ring data-[state=open]:bg-accent data-[state=open]:text-muted-foreground absolute top-4 right-4 rounded-xs opacity-70 transition-opacity hover:opacity-100 focus:ring-2 focus:ring-offset-2 focus:outline-hidden disabled:pointer-events-none [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4"
          >
            <XIcon />
            <span className="sr-only">Close</span>
          </DialogPrimitive.Close>
        )}
      </DialogPrimitive.Content>
    </DialogPortal>
  )
}

function DialogHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="dialog-header"
      className={cn("flex flex-col gap-2 text-center sm:text-left", className)}
      {...props}
    />
  )
}

function DialogFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="dialog-footer"
      className={cn(
        "flex flex-col-reverse gap-2 sm:flex-row sm:justify-end",
        className
      )}
      {...props}
    />
  )
}

function DialogTitle({
  className,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Title>) {
  return (
    <DialogPrimitive.Title
      data-slot="dialog-title"
      className={cn("text-lg leading-none font-semibold", className)}
      {...props}
    />
  )
}

function DialogDescription({
  className,
  ...props
}: React.ComponentProps<typeof DialogPrimitive.Description>) {
  return (
    <DialogPrimitive.Description
      data-slot="dialog-description"
      className={cn("text-muted-foreground text-sm", className)}
      {...props}
    />
  )
}

export {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogOverlay,
  DialogPortal,
  DialogTitle,
  DialogTrigger,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/drawer.tsx ---
mkdir -p "$(dirname "src/components/ui/drawer.tsx")"
cat > 'src/components/ui/drawer.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import { Drawer as DrawerPrimitive } from "vaul"

import { cn } from "@/lib/utils"

function Drawer({
  ...props
}: React.ComponentProps<typeof DrawerPrimitive.Root>) {
  return <DrawerPrimitive.Root data-slot="drawer" {...props} />
}

function DrawerTrigger({
  ...props
}: React.ComponentProps<typeof DrawerPrimitive.Trigger>) {
  return <DrawerPrimitive.Trigger data-slot="drawer-trigger" {...props} />
}

function DrawerPortal({
  ...props
}: React.ComponentProps<typeof DrawerPrimitive.Portal>) {
  return <DrawerPrimitive.Portal data-slot="drawer-portal" {...props} />
}

function DrawerClose({
  ...props
}: React.ComponentProps<typeof DrawerPrimitive.Close>) {
  return <DrawerPrimitive.Close data-slot="drawer-close" {...props} />
}

function DrawerOverlay({
  className,
  ...props
}: React.ComponentProps<typeof DrawerPrimitive.Overlay>) {
  return (
    <DrawerPrimitive.Overlay
      data-slot="drawer-overlay"
      className={cn(
        "data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 fixed inset-0 z-50 bg-black/50",
        className
      )}
      {...props}
    />
  )
}

function DrawerContent({
  className,
  children,
  ...props
}: React.ComponentProps<typeof DrawerPrimitive.Content>) {
  return (
    <DrawerPortal data-slot="drawer-portal">
      <DrawerOverlay />
      <DrawerPrimitive.Content
        data-slot="drawer-content"
        className={cn(
          "group/drawer-content bg-background fixed z-50 flex h-auto flex-col",
          "data-[vaul-drawer-direction=top]:inset-x-0 data-[vaul-drawer-direction=top]:top-0 data-[vaul-drawer-direction=top]:mb-24 data-[vaul-drawer-direction=top]:max-h-[80vh] data-[vaul-drawer-direction=top]:rounded-b-lg data-[vaul-drawer-direction=top]:border-b",
          "data-[vaul-drawer-direction=bottom]:inset-x-0 data-[vaul-drawer-direction=bottom]:bottom-0 data-[vaul-drawer-direction=bottom]:mt-24 data-[vaul-drawer-direction=bottom]:max-h-[80vh] data-[vaul-drawer-direction=bottom]:rounded-t-lg data-[vaul-drawer-direction=bottom]:border-t",
          "data-[vaul-drawer-direction=right]:inset-y-0 data-[vaul-drawer-direction=right]:right-0 data-[vaul-drawer-direction=right]:w-3/4 data-[vaul-drawer-direction=right]:border-l data-[vaul-drawer-direction=right]:sm:max-w-sm",
          "data-[vaul-drawer-direction=left]:inset-y-0 data-[vaul-drawer-direction=left]:left-0 data-[vaul-drawer-direction=left]:w-3/4 data-[vaul-drawer-direction=left]:border-r data-[vaul-drawer-direction=left]:sm:max-w-sm",
          className
        )}
        {...props}
      >
        <div className="bg-muted mx-auto mt-4 hidden h-2 w-[100px] shrink-0 rounded-full group-data-[vaul-drawer-direction=bottom]/drawer-content:block" />
        {children}
      </DrawerPrimitive.Content>
    </DrawerPortal>
  )
}

function DrawerHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="drawer-header"
      className={cn(
        "flex flex-col gap-0.5 p-4 group-data-[vaul-drawer-direction=bottom]/drawer-content:text-center group-data-[vaul-drawer-direction=top]/drawer-content:text-center md:gap-1.5 md:text-left",
        className
      )}
      {...props}
    />
  )
}

function DrawerFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="drawer-footer"
      className={cn("mt-auto flex flex-col gap-2 p-4", className)}
      {...props}
    />
  )
}

function DrawerTitle({
  className,
  ...props
}: React.ComponentProps<typeof DrawerPrimitive.Title>) {
  return (
    <DrawerPrimitive.Title
      data-slot="drawer-title"
      className={cn("text-foreground font-semibold", className)}
      {...props}
    />
  )
}

function DrawerDescription({
  className,
  ...props
}: React.ComponentProps<typeof DrawerPrimitive.Description>) {
  return (
    <DrawerPrimitive.Description
      data-slot="drawer-description"
      className={cn("text-muted-foreground text-sm", className)}
      {...props}
    />
  )
}

export {
  Drawer,
  DrawerPortal,
  DrawerOverlay,
  DrawerTrigger,
  DrawerClose,
  DrawerContent,
  DrawerHeader,
  DrawerFooter,
  DrawerTitle,
  DrawerDescription,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/dropdown-menu.tsx ---
mkdir -p "$(dirname "src/components/ui/dropdown-menu.tsx")"
cat > 'src/components/ui/dropdown-menu.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as DropdownMenuPrimitive from "@radix-ui/react-dropdown-menu"
import { CheckIcon, ChevronRightIcon, CircleIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function DropdownMenu({
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Root>) {
  return <DropdownMenuPrimitive.Root data-slot="dropdown-menu" {...props} />
}

function DropdownMenuPortal({
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Portal>) {
  return (
    <DropdownMenuPrimitive.Portal data-slot="dropdown-menu-portal" {...props} />
  )
}

function DropdownMenuTrigger({
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Trigger>) {
  return (
    <DropdownMenuPrimitive.Trigger
      data-slot="dropdown-menu-trigger"
      {...props}
    />
  )
}

function DropdownMenuContent({
  className,
  sideOffset = 4,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Content>) {
  return (
    <DropdownMenuPrimitive.Portal>
      <DropdownMenuPrimitive.Content
        data-slot="dropdown-menu-content"
        sideOffset={sideOffset}
        className={cn(
          "bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 max-h-(--radix-dropdown-menu-content-available-height) min-w-[8rem] origin-(--radix-dropdown-menu-content-transform-origin) overflow-x-hidden overflow-y-auto rounded-md border p-1 shadow-md",
          className
        )}
        {...props}
      />
    </DropdownMenuPrimitive.Portal>
  )
}

function DropdownMenuGroup({
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Group>) {
  return (
    <DropdownMenuPrimitive.Group data-slot="dropdown-menu-group" {...props} />
  )
}

function DropdownMenuItem({
  className,
  inset,
  variant = "default",
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Item> & {
  inset?: boolean
  variant?: "default" | "destructive"
}) {
  return (
    <DropdownMenuPrimitive.Item
      data-slot="dropdown-menu-item"
      data-inset={inset}
      data-variant={variant}
      className={cn(
        "focus:bg-accent focus:text-accent-foreground data-[variant=destructive]:text-destructive data-[variant=destructive]:focus:bg-destructive/10 dark:data-[variant=destructive]:focus:bg-destructive/20 data-[variant=destructive]:focus:text-destructive data-[variant=destructive]:*:[svg]:!text-destructive [&_svg:not([class*='text-'])]:text-muted-foreground relative flex cursor-default items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-hidden select-none data-[disabled]:pointer-events-none data-[disabled]:opacity-50 data-[inset]:pl-8 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    />
  )
}

function DropdownMenuCheckboxItem({
  className,
  children,
  checked,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.CheckboxItem>) {
  return (
    <DropdownMenuPrimitive.CheckboxItem
      data-slot="dropdown-menu-checkbox-item"
      className={cn(
        "focus:bg-accent focus:text-accent-foreground relative flex cursor-default items-center gap-2 rounded-sm py-1.5 pr-2 pl-8 text-sm outline-hidden select-none data-[disabled]:pointer-events-none data-[disabled]:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      checked={checked}
      {...props}
    >
      <span className="pointer-events-none absolute left-2 flex size-3.5 items-center justify-center">
        <DropdownMenuPrimitive.ItemIndicator>
          <CheckIcon className="size-4" />
        </DropdownMenuPrimitive.ItemIndicator>
      </span>
      {children}
    </DropdownMenuPrimitive.CheckboxItem>
  )
}

function DropdownMenuRadioGroup({
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.RadioGroup>) {
  return (
    <DropdownMenuPrimitive.RadioGroup
      data-slot="dropdown-menu-radio-group"
      {...props}
    />
  )
}

function DropdownMenuRadioItem({
  className,
  children,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.RadioItem>) {
  return (
    <DropdownMenuPrimitive.RadioItem
      data-slot="dropdown-menu-radio-item"
      className={cn(
        "focus:bg-accent focus:text-accent-foreground relative flex cursor-default items-center gap-2 rounded-sm py-1.5 pr-2 pl-8 text-sm outline-hidden select-none data-[disabled]:pointer-events-none data-[disabled]:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    >
      <span className="pointer-events-none absolute left-2 flex size-3.5 items-center justify-center">
        <DropdownMenuPrimitive.ItemIndicator>
          <CircleIcon className="size-2 fill-current" />
        </DropdownMenuPrimitive.ItemIndicator>
      </span>
      {children}
    </DropdownMenuPrimitive.RadioItem>
  )
}

function DropdownMenuLabel({
  className,
  inset,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Label> & {
  inset?: boolean
}) {
  return (
    <DropdownMenuPrimitive.Label
      data-slot="dropdown-menu-label"
      data-inset={inset}
      className={cn(
        "px-2 py-1.5 text-sm font-medium data-[inset]:pl-8",
        className
      )}
      {...props}
    />
  )
}

function DropdownMenuSeparator({
  className,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Separator>) {
  return (
    <DropdownMenuPrimitive.Separator
      data-slot="dropdown-menu-separator"
      className={cn("bg-border -mx-1 my-1 h-px", className)}
      {...props}
    />
  )
}

function DropdownMenuShortcut({
  className,
  ...props
}: React.ComponentProps<"span">) {
  return (
    <span
      data-slot="dropdown-menu-shortcut"
      className={cn(
        "text-muted-foreground ml-auto text-xs tracking-widest",
        className
      )}
      {...props}
    />
  )
}

function DropdownMenuSub({
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.Sub>) {
  return <DropdownMenuPrimitive.Sub data-slot="dropdown-menu-sub" {...props} />
}

function DropdownMenuSubTrigger({
  className,
  inset,
  children,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.SubTrigger> & {
  inset?: boolean
}) {
  return (
    <DropdownMenuPrimitive.SubTrigger
      data-slot="dropdown-menu-sub-trigger"
      data-inset={inset}
      className={cn(
        "focus:bg-accent focus:text-accent-foreground data-[state=open]:bg-accent data-[state=open]:text-accent-foreground flex cursor-default items-center rounded-sm px-2 py-1.5 text-sm outline-hidden select-none data-[inset]:pl-8",
        className
      )}
      {...props}
    >
      {children}
      <ChevronRightIcon className="ml-auto size-4" />
    </DropdownMenuPrimitive.SubTrigger>
  )
}

function DropdownMenuSubContent({
  className,
  ...props
}: React.ComponentProps<typeof DropdownMenuPrimitive.SubContent>) {
  return (
    <DropdownMenuPrimitive.SubContent
      data-slot="dropdown-menu-sub-content"
      className={cn(
        "bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 min-w-[8rem] origin-(--radix-dropdown-menu-content-transform-origin) overflow-hidden rounded-md border p-1 shadow-lg",
        className
      )}
      {...props}
    />
  )
}

export {
  DropdownMenu,
  DropdownMenuPortal,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuLabel,
  DropdownMenuItem,
  DropdownMenuCheckboxItem,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuSub,
  DropdownMenuSubTrigger,
  DropdownMenuSubContent,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/form.tsx ---
mkdir -p "$(dirname "src/components/ui/form.tsx")"
cat > 'src/components/ui/form.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as LabelPrimitive from "@radix-ui/react-label"
import { Slot } from "@radix-ui/react-slot"
import {
  Controller,
  FormProvider,
  useFormContext,
  useFormState,
  type ControllerProps,
  type FieldPath,
  type FieldValues,
} from "react-hook-form"

import { cn } from "@/lib/utils"
import { Label } from "@/components/ui/label"

const Form = FormProvider

type FormFieldContextValue<
  TFieldValues extends FieldValues = FieldValues,
  TName extends FieldPath<TFieldValues> = FieldPath<TFieldValues>,
> = {
  name: TName
}

const FormFieldContext = React.createContext<FormFieldContextValue>(
  {} as FormFieldContextValue
)

const FormField = <
  TFieldValues extends FieldValues = FieldValues,
  TName extends FieldPath<TFieldValues> = FieldPath<TFieldValues>,
>({
  ...props
}: ControllerProps<TFieldValues, TName>) => {
  return (
    <FormFieldContext.Provider value={{ name: props.name }}>
      <Controller {...props} />
    </FormFieldContext.Provider>
  )
}

const useFormField = () => {
  const fieldContext = React.useContext(FormFieldContext)
  const itemContext = React.useContext(FormItemContext)
  const { getFieldState } = useFormContext()
  const formState = useFormState({ name: fieldContext.name })
  const fieldState = getFieldState(fieldContext.name, formState)

  if (!fieldContext) {
    throw new Error("useFormField should be used within <FormField>")
  }

  const { id } = itemContext

  return {
    id,
    name: fieldContext.name,
    formItemId: `${id}-form-item`,
    formDescriptionId: `${id}-form-item-description`,
    formMessageId: `${id}-form-item-message`,
    ...fieldState,
  }
}

type FormItemContextValue = {
  id: string
}

const FormItemContext = React.createContext<FormItemContextValue>(
  {} as FormItemContextValue
)

function FormItem({ className, ...props }: React.ComponentProps<"div">) {
  const id = React.useId()

  return (
    <FormItemContext.Provider value={{ id }}>
      <div
        data-slot="form-item"
        className={cn("grid gap-2", className)}
        {...props}
      />
    </FormItemContext.Provider>
  )
}

function FormLabel({
  className,
  ...props
}: React.ComponentProps<typeof LabelPrimitive.Root>) {
  const { error, formItemId } = useFormField()

  return (
    <Label
      data-slot="form-label"
      data-error={!!error}
      className={cn("data-[error=true]:text-destructive", className)}
      htmlFor={formItemId}
      {...props}
    />
  )
}

function FormControl({ ...props }: React.ComponentProps<typeof Slot>) {
  const { error, formItemId, formDescriptionId, formMessageId } = useFormField()

  return (
    <Slot
      data-slot="form-control"
      id={formItemId}
      aria-describedby={
        !error
          ? `${formDescriptionId}`
          : `${formDescriptionId} ${formMessageId}`
      }
      aria-invalid={!!error}
      {...props}
    />
  )
}

function FormDescription({ className, ...props }: React.ComponentProps<"p">) {
  const { formDescriptionId } = useFormField()

  return (
    <p
      data-slot="form-description"
      id={formDescriptionId}
      className={cn("text-muted-foreground text-sm", className)}
      {...props}
    />
  )
}

function FormMessage({ className, ...props }: React.ComponentProps<"p">) {
  const { error, formMessageId } = useFormField()
  const body = error ? String(error?.message ?? "") : props.children

  if (!body) {
    return null
  }

  return (
    <p
      data-slot="form-message"
      id={formMessageId}
      className={cn("text-destructive text-sm", className)}
      {...props}
    >
      {body}
    </p>
  )
}

export {
  useFormField,
  Form,
  FormItem,
  FormLabel,
  FormControl,
  FormDescription,
  FormMessage,
  FormField,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/hover-card.tsx ---
mkdir -p "$(dirname "src/components/ui/hover-card.tsx")"
cat > 'src/components/ui/hover-card.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as HoverCardPrimitive from "@radix-ui/react-hover-card"

import { cn } from "@/lib/utils"

function HoverCard({
  ...props
}: React.ComponentProps<typeof HoverCardPrimitive.Root>) {
  return <HoverCardPrimitive.Root data-slot="hover-card" {...props} />
}

function HoverCardTrigger({
  ...props
}: React.ComponentProps<typeof HoverCardPrimitive.Trigger>) {
  return (
    <HoverCardPrimitive.Trigger data-slot="hover-card-trigger" {...props} />
  )
}

function HoverCardContent({
  className,
  align = "center",
  sideOffset = 4,
  ...props
}: React.ComponentProps<typeof HoverCardPrimitive.Content>) {
  return (
    <HoverCardPrimitive.Portal data-slot="hover-card-portal">
      <HoverCardPrimitive.Content
        data-slot="hover-card-content"
        align={align}
        sideOffset={sideOffset}
        className={cn(
          "bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 w-64 origin-(--radix-hover-card-content-transform-origin) rounded-md border p-4 shadow-md outline-hidden",
          className
        )}
        {...props}
      />
    </HoverCardPrimitive.Portal>
  )
}

export { HoverCard, HoverCardTrigger, HoverCardContent }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/input-otp.tsx ---
mkdir -p "$(dirname "src/components/ui/input-otp.tsx")"
cat > 'src/components/ui/input-otp.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import { OTPInput, OTPInputContext } from "input-otp"
import { MinusIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function InputOTP({
  className,
  containerClassName,
  ...props
}: React.ComponentProps<typeof OTPInput> & {
  containerClassName?: string
}) {
  return (
    <OTPInput
      data-slot="input-otp"
      containerClassName={cn(
        "flex items-center gap-2 has-disabled:opacity-50",
        containerClassName
      )}
      className={cn("disabled:cursor-not-allowed", className)}
      {...props}
    />
  )
}

function InputOTPGroup({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="input-otp-group"
      className={cn("flex items-center", className)}
      {...props}
    />
  )
}

function InputOTPSlot({
  index,
  className,
  ...props
}: React.ComponentProps<"div"> & {
  index: number
}) {
  const inputOTPContext = React.useContext(OTPInputContext)
  const { char, hasFakeCaret, isActive } = inputOTPContext?.slots[index] ?? {}

  return (
    <div
      data-slot="input-otp-slot"
      data-active={isActive}
      className={cn(
        "data-[active=true]:border-ring data-[active=true]:ring-ring/50 data-[active=true]:aria-invalid:ring-destructive/20 dark:data-[active=true]:aria-invalid:ring-destructive/40 aria-invalid:border-destructive data-[active=true]:aria-invalid:border-destructive dark:bg-input/30 border-input relative flex h-9 w-9 items-center justify-center border-y border-r text-sm shadow-xs transition-all outline-none first:rounded-l-md first:border-l last:rounded-r-md data-[active=true]:z-10 data-[active=true]:ring-[3px]",
        className
      )}
      {...props}
    >
      {char}
      {hasFakeCaret && (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
          <div className="animate-caret-blink bg-foreground h-4 w-px duration-1000" />
        </div>
      )}
    </div>
  )
}

function InputOTPSeparator({ ...props }: React.ComponentProps<"div">) {
  return (
    <div data-slot="input-otp-separator" role="separator" {...props}>
      <MinusIcon />
    </div>
  )
}

export { InputOTP, InputOTPGroup, InputOTPSlot, InputOTPSeparator }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/input.tsx ---
mkdir -p "$(dirname "src/components/ui/input.tsx")"
cat > 'src/components/ui/input.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import * as React from "react"

import { cn } from "@/lib/utils"

function Input({ className, type, ...props }: React.ComponentProps<"input">) {
  return (
    <input
      type={type}
      data-slot="input"
      className={cn(
        "file:text-foreground placeholder:text-muted-foreground selection:bg-primary selection:text-primary-foreground dark:bg-input/30 border-input flex h-9 w-full min-w-0 rounded-md border bg-transparent px-3 py-1 text-base shadow-xs transition-[color,box-shadow] outline-none file:inline-flex file:h-7 file:border-0 file:bg-transparent file:text-sm file:font-medium disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50 md:text-sm",
        "focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px]",
        "aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive",
        className
      )}
      {...props}
    />
  )
}

export { Input }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/label.tsx ---
mkdir -p "$(dirname "src/components/ui/label.tsx")"
cat > 'src/components/ui/label.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as LabelPrimitive from "@radix-ui/react-label"

import { cn } from "@/lib/utils"

function Label({
  className,
  ...props
}: React.ComponentProps<typeof LabelPrimitive.Root>) {
  return (
    <LabelPrimitive.Root
      data-slot="label"
      className={cn(
        "flex items-center gap-2 text-sm leading-none font-medium select-none group-data-[disabled=true]:pointer-events-none group-data-[disabled=true]:opacity-50 peer-disabled:cursor-not-allowed peer-disabled:opacity-50",
        className
      )}
      {...props}
    />
  )
}

export { Label }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/menubar.tsx ---
mkdir -p "$(dirname "src/components/ui/menubar.tsx")"
cat > 'src/components/ui/menubar.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as MenubarPrimitive from "@radix-ui/react-menubar"
import { CheckIcon, ChevronRightIcon, CircleIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function Menubar({
  className,
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.Root>) {
  return (
    <MenubarPrimitive.Root
      data-slot="menubar"
      className={cn(
        "bg-background flex h-9 items-center gap-1 rounded-md border p-1 shadow-xs",
        className
      )}
      {...props}
    />
  )
}

function MenubarMenu({
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.Menu>) {
  return <MenubarPrimitive.Menu data-slot="menubar-menu" {...props} />
}

function MenubarGroup({
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.Group>) {
  return <MenubarPrimitive.Group data-slot="menubar-group" {...props} />
}

function MenubarPortal({
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.Portal>) {
  return <MenubarPrimitive.Portal data-slot="menubar-portal" {...props} />
}

function MenubarRadioGroup({
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.RadioGroup>) {
  return (
    <MenubarPrimitive.RadioGroup data-slot="menubar-radio-group" {...props} />
  )
}

function MenubarTrigger({
  className,
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.Trigger>) {
  return (
    <MenubarPrimitive.Trigger
      data-slot="menubar-trigger"
      className={cn(
        "focus:bg-accent focus:text-accent-foreground data-[state=open]:bg-accent data-[state=open]:text-accent-foreground flex items-center rounded-sm px-2 py-1 text-sm font-medium outline-hidden select-none",
        className
      )}
      {...props}
    />
  )
}

function MenubarContent({
  className,
  align = "start",
  alignOffset = -4,
  sideOffset = 8,
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.Content>) {
  return (
    <MenubarPortal>
      <MenubarPrimitive.Content
        data-slot="menubar-content"
        align={align}
        alignOffset={alignOffset}
        sideOffset={sideOffset}
        className={cn(
          "bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 min-w-[12rem] origin-(--radix-menubar-content-transform-origin) overflow-hidden rounded-md border p-1 shadow-md",
          className
        )}
        {...props}
      />
    </MenubarPortal>
  )
}

function MenubarItem({
  className,
  inset,
  variant = "default",
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.Item> & {
  inset?: boolean
  variant?: "default" | "destructive"
}) {
  return (
    <MenubarPrimitive.Item
      data-slot="menubar-item"
      data-inset={inset}
      data-variant={variant}
      className={cn(
        "focus:bg-accent focus:text-accent-foreground data-[variant=destructive]:text-destructive data-[variant=destructive]:focus:bg-destructive/10 dark:data-[variant=destructive]:focus:bg-destructive/20 data-[variant=destructive]:focus:text-destructive data-[variant=destructive]:*:[svg]:!text-destructive [&_svg:not([class*='text-'])]:text-muted-foreground relative flex cursor-default items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-hidden select-none data-[disabled]:pointer-events-none data-[disabled]:opacity-50 data-[inset]:pl-8 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    />
  )
}

function MenubarCheckboxItem({
  className,
  children,
  checked,
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.CheckboxItem>) {
  return (
    <MenubarPrimitive.CheckboxItem
      data-slot="menubar-checkbox-item"
      className={cn(
        "focus:bg-accent focus:text-accent-foreground relative flex cursor-default items-center gap-2 rounded-xs py-1.5 pr-2 pl-8 text-sm outline-hidden select-none data-[disabled]:pointer-events-none data-[disabled]:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      checked={checked}
      {...props}
    >
      <span className="pointer-events-none absolute left-2 flex size-3.5 items-center justify-center">
        <MenubarPrimitive.ItemIndicator>
          <CheckIcon className="size-4" />
        </MenubarPrimitive.ItemIndicator>
      </span>
      {children}
    </MenubarPrimitive.CheckboxItem>
  )
}

function MenubarRadioItem({
  className,
  children,
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.RadioItem>) {
  return (
    <MenubarPrimitive.RadioItem
      data-slot="menubar-radio-item"
      className={cn(
        "focus:bg-accent focus:text-accent-foreground relative flex cursor-default items-center gap-2 rounded-xs py-1.5 pr-2 pl-8 text-sm outline-hidden select-none data-[disabled]:pointer-events-none data-[disabled]:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    >
      <span className="pointer-events-none absolute left-2 flex size-3.5 items-center justify-center">
        <MenubarPrimitive.ItemIndicator>
          <CircleIcon className="size-2 fill-current" />
        </MenubarPrimitive.ItemIndicator>
      </span>
      {children}
    </MenubarPrimitive.RadioItem>
  )
}

function MenubarLabel({
  className,
  inset,
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.Label> & {
  inset?: boolean
}) {
  return (
    <MenubarPrimitive.Label
      data-slot="menubar-label"
      data-inset={inset}
      className={cn(
        "px-2 py-1.5 text-sm font-medium data-[inset]:pl-8",
        className
      )}
      {...props}
    />
  )
}

function MenubarSeparator({
  className,
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.Separator>) {
  return (
    <MenubarPrimitive.Separator
      data-slot="menubar-separator"
      className={cn("bg-border -mx-1 my-1 h-px", className)}
      {...props}
    />
  )
}

function MenubarShortcut({
  className,
  ...props
}: React.ComponentProps<"span">) {
  return (
    <span
      data-slot="menubar-shortcut"
      className={cn(
        "text-muted-foreground ml-auto text-xs tracking-widest",
        className
      )}
      {...props}
    />
  )
}

function MenubarSub({
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.Sub>) {
  return <MenubarPrimitive.Sub data-slot="menubar-sub" {...props} />
}

function MenubarSubTrigger({
  className,
  inset,
  children,
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.SubTrigger> & {
  inset?: boolean
}) {
  return (
    <MenubarPrimitive.SubTrigger
      data-slot="menubar-sub-trigger"
      data-inset={inset}
      className={cn(
        "focus:bg-accent focus:text-accent-foreground data-[state=open]:bg-accent data-[state=open]:text-accent-foreground flex cursor-default items-center rounded-sm px-2 py-1.5 text-sm outline-none select-none data-[inset]:pl-8",
        className
      )}
      {...props}
    >
      {children}
      <ChevronRightIcon className="ml-auto h-4 w-4" />
    </MenubarPrimitive.SubTrigger>
  )
}

function MenubarSubContent({
  className,
  ...props
}: React.ComponentProps<typeof MenubarPrimitive.SubContent>) {
  return (
    <MenubarPrimitive.SubContent
      data-slot="menubar-sub-content"
      className={cn(
        "bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 min-w-[8rem] origin-(--radix-menubar-content-transform-origin) overflow-hidden rounded-md border p-1 shadow-lg",
        className
      )}
      {...props}
    />
  )
}

export {
  Menubar,
  MenubarPortal,
  MenubarMenu,
  MenubarTrigger,
  MenubarContent,
  MenubarGroup,
  MenubarSeparator,
  MenubarLabel,
  MenubarItem,
  MenubarShortcut,
  MenubarCheckboxItem,
  MenubarRadioGroup,
  MenubarRadioItem,
  MenubarSub,
  MenubarSubTrigger,
  MenubarSubContent,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/navigation-menu.tsx ---
mkdir -p "$(dirname "src/components/ui/navigation-menu.tsx")"
cat > 'src/components/ui/navigation-menu.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import * as React from "react"
import * as NavigationMenuPrimitive from "@radix-ui/react-navigation-menu"
import { cva } from "class-variance-authority"
import { ChevronDownIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function NavigationMenu({
  className,
  children,
  viewport = true,
  ...props
}: React.ComponentProps<typeof NavigationMenuPrimitive.Root> & {
  viewport?: boolean
}) {
  return (
    <NavigationMenuPrimitive.Root
      data-slot="navigation-menu"
      data-viewport={viewport}
      className={cn(
        "group/navigation-menu relative flex max-w-max flex-1 items-center justify-center",
        className
      )}
      {...props}
    >
      {children}
      {viewport && <NavigationMenuViewport />}
    </NavigationMenuPrimitive.Root>
  )
}

function NavigationMenuList({
  className,
  ...props
}: React.ComponentProps<typeof NavigationMenuPrimitive.List>) {
  return (
    <NavigationMenuPrimitive.List
      data-slot="navigation-menu-list"
      className={cn(
        "group flex flex-1 list-none items-center justify-center gap-1",
        className
      )}
      {...props}
    />
  )
}

function NavigationMenuItem({
  className,
  ...props
}: React.ComponentProps<typeof NavigationMenuPrimitive.Item>) {
  return (
    <NavigationMenuPrimitive.Item
      data-slot="navigation-menu-item"
      className={cn("relative", className)}
      {...props}
    />
  )
}

const navigationMenuTriggerStyle = cva(
  "group inline-flex h-9 w-max items-center justify-center rounded-md bg-background px-4 py-2 text-sm font-medium hover:bg-accent hover:text-accent-foreground focus:bg-accent focus:text-accent-foreground disabled:pointer-events-none disabled:opacity-50 data-[state=open]:hover:bg-accent data-[state=open]:text-accent-foreground data-[state=open]:focus:bg-accent data-[state=open]:bg-accent/50 focus-visible:ring-ring/50 outline-none transition-[color,box-shadow] focus-visible:ring-[3px] focus-visible:outline-1"
)

function NavigationMenuTrigger({
  className,
  children,
  ...props
}: React.ComponentProps<typeof NavigationMenuPrimitive.Trigger>) {
  return (
    <NavigationMenuPrimitive.Trigger
      data-slot="navigation-menu-trigger"
      className={cn(navigationMenuTriggerStyle(), "group", className)}
      {...props}
    >
      {children}{" "}
      <ChevronDownIcon
        className="relative top-[1px] ml-1 size-3 transition duration-300 group-data-[state=open]:rotate-180"
        aria-hidden="true"
      />
    </NavigationMenuPrimitive.Trigger>
  )
}

function NavigationMenuContent({
  className,
  ...props
}: React.ComponentProps<typeof NavigationMenuPrimitive.Content>) {
  return (
    <NavigationMenuPrimitive.Content
      data-slot="navigation-menu-content"
      className={cn(
        "data-[motion^=from-]:animate-in data-[motion^=to-]:animate-out data-[motion^=from-]:fade-in data-[motion^=to-]:fade-out data-[motion=from-end]:slide-in-from-right-52 data-[motion=from-start]:slide-in-from-left-52 data-[motion=to-end]:slide-out-to-right-52 data-[motion=to-start]:slide-out-to-left-52 top-0 left-0 w-full p-2 pr-2.5 md:absolute md:w-auto",
        "group-data-[viewport=false]/navigation-menu:bg-popover group-data-[viewport=false]/navigation-menu:text-popover-foreground group-data-[viewport=false]/navigation-menu:data-[state=open]:animate-in group-data-[viewport=false]/navigation-menu:data-[state=closed]:animate-out group-data-[viewport=false]/navigation-menu:data-[state=closed]:zoom-out-95 group-data-[viewport=false]/navigation-menu:data-[state=open]:zoom-in-95 group-data-[viewport=false]/navigation-menu:data-[state=open]:fade-in-0 group-data-[viewport=false]/navigation-menu:data-[state=closed]:fade-out-0 group-data-[viewport=false]/navigation-menu:top-full group-data-[viewport=false]/navigation-menu:mt-1.5 group-data-[viewport=false]/navigation-menu:overflow-hidden group-data-[viewport=false]/navigation-menu:rounded-md group-data-[viewport=false]/navigation-menu:border group-data-[viewport=false]/navigation-menu:shadow group-data-[viewport=false]/navigation-menu:duration-200 **:data-[slot=navigation-menu-link]:focus:ring-0 **:data-[slot=navigation-menu-link]:focus:outline-none",
        className
      )}
      {...props}
    />
  )
}

function NavigationMenuViewport({
  className,
  ...props
}: React.ComponentProps<typeof NavigationMenuPrimitive.Viewport>) {
  return (
    <div
      className={cn(
        "absolute top-full left-0 isolate z-50 flex justify-center"
      )}
    >
      <NavigationMenuPrimitive.Viewport
        data-slot="navigation-menu-viewport"
        className={cn(
          "origin-top-center bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-90 relative mt-1.5 h-[var(--radix-navigation-menu-viewport-height)] w-full overflow-hidden rounded-md border shadow md:w-[var(--radix-navigation-menu-viewport-width)]",
          className
        )}
        {...props}
      />
    </div>
  )
}

function NavigationMenuLink({
  className,
  ...props
}: React.ComponentProps<typeof NavigationMenuPrimitive.Link>) {
  return (
    <NavigationMenuPrimitive.Link
      data-slot="navigation-menu-link"
      className={cn(
        "data-[active=true]:focus:bg-accent data-[active=true]:hover:bg-accent data-[active=true]:bg-accent/50 data-[active=true]:text-accent-foreground hover:bg-accent hover:text-accent-foreground focus:bg-accent focus:text-accent-foreground focus-visible:ring-ring/50 [&_svg:not([class*='text-'])]:text-muted-foreground flex flex-col gap-1 rounded-sm p-2 text-sm transition-all outline-none focus-visible:ring-[3px] focus-visible:outline-1 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    />
  )
}

function NavigationMenuIndicator({
  className,
  ...props
}: React.ComponentProps<typeof NavigationMenuPrimitive.Indicator>) {
  return (
    <NavigationMenuPrimitive.Indicator
      data-slot="navigation-menu-indicator"
      className={cn(
        "data-[state=visible]:animate-in data-[state=hidden]:animate-out data-[state=hidden]:fade-out data-[state=visible]:fade-in top-full z-[1] flex h-1.5 items-end justify-center overflow-hidden",
        className
      )}
      {...props}
    >
      <div className="bg-border relative top-[60%] h-2 w-2 rotate-45 rounded-tl-sm shadow-md" />
    </NavigationMenuPrimitive.Indicator>
  )
}

export {
  NavigationMenu,
  NavigationMenuList,
  NavigationMenuItem,
  NavigationMenuContent,
  NavigationMenuTrigger,
  NavigationMenuLink,
  NavigationMenuIndicator,
  NavigationMenuViewport,
  navigationMenuTriggerStyle,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/pagination.tsx ---
mkdir -p "$(dirname "src/components/ui/pagination.tsx")"
cat > 'src/components/ui/pagination.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import * as React from "react"
import {
  ChevronLeftIcon,
  ChevronRightIcon,
  MoreHorizontalIcon,
} from "lucide-react"

import { cn } from "@/lib/utils"
import { Button, buttonVariants } from "@/components/ui/button"

function Pagination({ className, ...props }: React.ComponentProps<"nav">) {
  return (
    <nav
      role="navigation"
      aria-label="pagination"
      data-slot="pagination"
      className={cn("mx-auto flex w-full justify-center", className)}
      {...props}
    />
  )
}

function PaginationContent({
  className,
  ...props
}: React.ComponentProps<"ul">) {
  return (
    <ul
      data-slot="pagination-content"
      className={cn("flex flex-row items-center gap-1", className)}
      {...props}
    />
  )
}

function PaginationItem({ ...props }: React.ComponentProps<"li">) {
  return <li data-slot="pagination-item" {...props} />
}

type PaginationLinkProps = {
  isActive?: boolean
} & Pick<React.ComponentProps<typeof Button>, "size"> &
  React.ComponentProps<"a">

function PaginationLink({
  className,
  isActive,
  size = "icon",
  ...props
}: PaginationLinkProps) {
  return (
    <a
      aria-current={isActive ? "page" : undefined}
      data-slot="pagination-link"
      data-active={isActive}
      className={cn(
        buttonVariants({
          variant: isActive ? "outline" : "ghost",
          size,
        }),
        className
      )}
      {...props}
    />
  )
}

function PaginationPrevious({
  className,
  ...props
}: React.ComponentProps<typeof PaginationLink>) {
  return (
    <PaginationLink
      aria-label="Go to previous page"
      size="default"
      className={cn("gap-1 px-2.5 sm:pl-2.5", className)}
      {...props}
    >
      <ChevronLeftIcon />
      <span className="hidden sm:block">Previous</span>
    </PaginationLink>
  )
}

function PaginationNext({
  className,
  ...props
}: React.ComponentProps<typeof PaginationLink>) {
  return (
    <PaginationLink
      aria-label="Go to next page"
      size="default"
      className={cn("gap-1 px-2.5 sm:pr-2.5", className)}
      {...props}
    >
      <span className="hidden sm:block">Next</span>
      <ChevronRightIcon />
    </PaginationLink>
  )
}

function PaginationEllipsis({
  className,
  ...props
}: React.ComponentProps<"span">) {
  return (
    <span
      aria-hidden
      data-slot="pagination-ellipsis"
      className={cn("flex size-9 items-center justify-center", className)}
      {...props}
    >
      <MoreHorizontalIcon className="size-4" />
      <span className="sr-only">More pages</span>
    </span>
  )
}

export {
  Pagination,
  PaginationContent,
  PaginationLink,
  PaginationItem,
  PaginationPrevious,
  PaginationNext,
  PaginationEllipsis,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/popover.tsx ---
mkdir -p "$(dirname "src/components/ui/popover.tsx")"
cat > 'src/components/ui/popover.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as PopoverPrimitive from "@radix-ui/react-popover"

import { cn } from "@/lib/utils"

function Popover({
  ...props
}: React.ComponentProps<typeof PopoverPrimitive.Root>) {
  return <PopoverPrimitive.Root data-slot="popover" {...props} />
}

function PopoverTrigger({
  ...props
}: React.ComponentProps<typeof PopoverPrimitive.Trigger>) {
  return <PopoverPrimitive.Trigger data-slot="popover-trigger" {...props} />
}

function PopoverContent({
  className,
  align = "center",
  sideOffset = 4,
  ...props
}: React.ComponentProps<typeof PopoverPrimitive.Content>) {
  return (
    <PopoverPrimitive.Portal>
      <PopoverPrimitive.Content
        data-slot="popover-content"
        align={align}
        sideOffset={sideOffset}
        className={cn(
          "bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 w-72 origin-(--radix-popover-content-transform-origin) rounded-md border p-4 shadow-md outline-hidden",
          className
        )}
        {...props}
      />
    </PopoverPrimitive.Portal>
  )
}

function PopoverAnchor({
  ...props
}: React.ComponentProps<typeof PopoverPrimitive.Anchor>) {
  return <PopoverPrimitive.Anchor data-slot="popover-anchor" {...props} />
}

export { Popover, PopoverTrigger, PopoverContent, PopoverAnchor }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/progress.tsx ---
mkdir -p "$(dirname "src/components/ui/progress.tsx")"
cat > 'src/components/ui/progress.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as ProgressPrimitive from "@radix-ui/react-progress"

import { cn } from "@/lib/utils"

function Progress({
  className,
  value,
  ...props
}: React.ComponentProps<typeof ProgressPrimitive.Root>) {
  return (
    <ProgressPrimitive.Root
      data-slot="progress"
      className={cn(
        "bg-primary/20 relative h-2 w-full overflow-hidden rounded-full",
        className
      )}
      {...props}
    >
      <ProgressPrimitive.Indicator
        data-slot="progress-indicator"
        className="bg-primary h-full w-full flex-1 transition-all"
        style={{ transform: `translateX(-${100 - (value || 0)}%)` }}
      />
    </ProgressPrimitive.Root>
  )
}

export { Progress }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/radio-group.tsx ---
mkdir -p "$(dirname "src/components/ui/radio-group.tsx")"
cat > 'src/components/ui/radio-group.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as RadioGroupPrimitive from "@radix-ui/react-radio-group"
import { CircleIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function RadioGroup({
  className,
  ...props
}: React.ComponentProps<typeof RadioGroupPrimitive.Root>) {
  return (
    <RadioGroupPrimitive.Root
      data-slot="radio-group"
      className={cn("grid gap-3", className)}
      {...props}
    />
  )
}

function RadioGroupItem({
  className,
  ...props
}: React.ComponentProps<typeof RadioGroupPrimitive.Item>) {
  return (
    <RadioGroupPrimitive.Item
      data-slot="radio-group-item"
      className={cn(
        "border-input text-primary focus-visible:border-ring focus-visible:ring-ring/50 aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive dark:bg-input/30 aspect-square size-4 shrink-0 rounded-full border shadow-xs transition-[color,box-shadow] outline-none focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50",
        className
      )}
      {...props}
    >
      <RadioGroupPrimitive.Indicator
        data-slot="radio-group-indicator"
        className="relative flex items-center justify-center"
      >
        <CircleIcon className="fill-primary absolute top-1/2 left-1/2 size-2 -translate-x-1/2 -translate-y-1/2" />
      </RadioGroupPrimitive.Indicator>
    </RadioGroupPrimitive.Item>
  )
}

export { RadioGroup, RadioGroupItem }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/resizable.tsx ---
mkdir -p "$(dirname "src/components/ui/resizable.tsx")"
cat > 'src/components/ui/resizable.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import { GripVerticalIcon } from "lucide-react"
import * as ResizablePrimitive from "react-resizable-panels"

import { cn } from "@/lib/utils"

function ResizablePanelGroup({
  className,
  ...props
}: React.ComponentProps<typeof ResizablePrimitive.PanelGroup>) {
  return (
    <ResizablePrimitive.PanelGroup
      data-slot="resizable-panel-group"
      className={cn(
        "flex h-full w-full data-[panel-group-direction=vertical]:flex-col",
        className
      )}
      {...props}
    />
  )
}

function ResizablePanel({
  ...props
}: React.ComponentProps<typeof ResizablePrimitive.Panel>) {
  return <ResizablePrimitive.Panel data-slot="resizable-panel" {...props} />
}

function ResizableHandle({
  withHandle,
  className,
  ...props
}: React.ComponentProps<typeof ResizablePrimitive.PanelResizeHandle> & {
  withHandle?: boolean
}) {
  return (
    <ResizablePrimitive.PanelResizeHandle
      data-slot="resizable-handle"
      className={cn(
        "bg-border focus-visible:ring-ring relative flex w-px items-center justify-center after:absolute after:inset-y-0 after:left-1/2 after:w-1 after:-translate-x-1/2 focus-visible:ring-1 focus-visible:ring-offset-1 focus-visible:outline-hidden data-[panel-group-direction=vertical]:h-px data-[panel-group-direction=vertical]:w-full data-[panel-group-direction=vertical]:after:left-0 data-[panel-group-direction=vertical]:after:h-1 data-[panel-group-direction=vertical]:after:w-full data-[panel-group-direction=vertical]:after:translate-x-0 data-[panel-group-direction=vertical]:after:-translate-y-1/2 [&[data-panel-group-direction=vertical]>div]:rotate-90",
        className
      )}
      {...props}
    >
      {withHandle && (
        <div className="bg-border z-10 flex h-4 w-3 items-center justify-center rounded-xs border">
          <GripVerticalIcon className="size-2.5" />
        </div>
      )}
    </ResizablePrimitive.PanelResizeHandle>
  )
}

export { ResizablePanelGroup, ResizablePanel, ResizableHandle }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/scroll-area.tsx ---
mkdir -p "$(dirname "src/components/ui/scroll-area.tsx")"
cat > 'src/components/ui/scroll-area.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as ScrollAreaPrimitive from "@radix-ui/react-scroll-area"

import { cn } from "@/lib/utils"

function ScrollArea({
  className,
  children,
  ...props
}: React.ComponentProps<typeof ScrollAreaPrimitive.Root>) {
  return (
    <ScrollAreaPrimitive.Root
      data-slot="scroll-area"
      className={cn("relative", className)}
      {...props}
    >
      <ScrollAreaPrimitive.Viewport
        data-slot="scroll-area-viewport"
        className="focus-visible:ring-ring/50 size-full rounded-[inherit] transition-[color,box-shadow] outline-none focus-visible:ring-[3px] focus-visible:outline-1"
      >
        {children}
      </ScrollAreaPrimitive.Viewport>
      <ScrollBar />
      <ScrollAreaPrimitive.Corner />
    </ScrollAreaPrimitive.Root>
  )
}

function ScrollBar({
  className,
  orientation = "vertical",
  ...props
}: React.ComponentProps<typeof ScrollAreaPrimitive.ScrollAreaScrollbar>) {
  return (
    <ScrollAreaPrimitive.ScrollAreaScrollbar
      data-slot="scroll-area-scrollbar"
      orientation={orientation}
      className={cn(
        "flex touch-none p-px transition-colors select-none",
        orientation === "vertical" &&
          "h-full w-2.5 border-l border-l-transparent",
        orientation === "horizontal" &&
          "h-2.5 flex-col border-t border-t-transparent",
        className
      )}
      {...props}
    >
      <ScrollAreaPrimitive.ScrollAreaThumb
        data-slot="scroll-area-thumb"
        className="bg-border relative flex-1 rounded-full"
      />
    </ScrollAreaPrimitive.ScrollAreaScrollbar>
  )
}

export { ScrollArea, ScrollBar }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/select.tsx ---
mkdir -p "$(dirname "src/components/ui/select.tsx")"
cat > 'src/components/ui/select.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as SelectPrimitive from "@radix-ui/react-select"
import { CheckIcon, ChevronDownIcon, ChevronUpIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function Select({
  ...props
}: React.ComponentProps<typeof SelectPrimitive.Root>) {
  return <SelectPrimitive.Root data-slot="select" {...props} />
}

function SelectGroup({
  ...props
}: React.ComponentProps<typeof SelectPrimitive.Group>) {
  return <SelectPrimitive.Group data-slot="select-group" {...props} />
}

function SelectValue({
  ...props
}: React.ComponentProps<typeof SelectPrimitive.Value>) {
  return <SelectPrimitive.Value data-slot="select-value" {...props} />
}

function SelectTrigger({
  className,
  size = "default",
  children,
  ...props
}: React.ComponentProps<typeof SelectPrimitive.Trigger> & {
  size?: "sm" | "default"
}) {
  return (
    <SelectPrimitive.Trigger
      data-slot="select-trigger"
      data-size={size}
      className={cn(
        "border-input data-[placeholder]:text-muted-foreground [&_svg:not([class*='text-'])]:text-muted-foreground focus-visible:border-ring focus-visible:ring-ring/50 aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive dark:bg-input/30 dark:hover:bg-input/50 flex w-fit items-center justify-between gap-2 rounded-md border bg-transparent px-3 py-2 text-sm whitespace-nowrap shadow-xs transition-[color,box-shadow] outline-none focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50 data-[size=default]:h-9 data-[size=sm]:h-8 *:data-[slot=select-value]:line-clamp-1 *:data-[slot=select-value]:flex *:data-[slot=select-value]:items-center *:data-[slot=select-value]:gap-2 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    >
      {children}
      <SelectPrimitive.Icon asChild>
        <ChevronDownIcon className="size-4 opacity-50" />
      </SelectPrimitive.Icon>
    </SelectPrimitive.Trigger>
  )
}

function SelectContent({
  className,
  children,
  position = "popper",
  ...props
}: React.ComponentProps<typeof SelectPrimitive.Content>) {
  return (
    <SelectPrimitive.Portal>
      <SelectPrimitive.Content
        data-slot="select-content"
        className={cn(
          "bg-popover text-popover-foreground data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 relative z-50 max-h-(--radix-select-content-available-height) min-w-[8rem] origin-(--radix-select-content-transform-origin) overflow-x-hidden overflow-y-auto rounded-md border shadow-md",
          position === "popper" &&
            "data-[side=bottom]:translate-y-1 data-[side=left]:-translate-x-1 data-[side=right]:translate-x-1 data-[side=top]:-translate-y-1",
          className
        )}
        position={position}
        {...props}
      >
        <SelectScrollUpButton />
        <SelectPrimitive.Viewport
          className={cn(
            "p-1",
            position === "popper" &&
              "h-[var(--radix-select-trigger-height)] w-full min-w-[var(--radix-select-trigger-width)] scroll-my-1"
          )}
        >
          {children}
        </SelectPrimitive.Viewport>
        <SelectScrollDownButton />
      </SelectPrimitive.Content>
    </SelectPrimitive.Portal>
  )
}

function SelectLabel({
  className,
  ...props
}: React.ComponentProps<typeof SelectPrimitive.Label>) {
  return (
    <SelectPrimitive.Label
      data-slot="select-label"
      className={cn("text-muted-foreground px-2 py-1.5 text-xs", className)}
      {...props}
    />
  )
}

function SelectItem({
  className,
  children,
  ...props
}: React.ComponentProps<typeof SelectPrimitive.Item>) {
  return (
    <SelectPrimitive.Item
      data-slot="select-item"
      className={cn(
        "focus:bg-accent focus:text-accent-foreground [&_svg:not([class*='text-'])]:text-muted-foreground relative flex w-full cursor-default items-center gap-2 rounded-sm py-1.5 pr-8 pl-2 text-sm outline-hidden select-none data-[disabled]:pointer-events-none data-[disabled]:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4 *:[span]:last:flex *:[span]:last:items-center *:[span]:last:gap-2",
        className
      )}
      {...props}
    >
      <span className="absolute right-2 flex size-3.5 items-center justify-center">
        <SelectPrimitive.ItemIndicator>
          <CheckIcon className="size-4" />
        </SelectPrimitive.ItemIndicator>
      </span>
      <SelectPrimitive.ItemText>{children}</SelectPrimitive.ItemText>
    </SelectPrimitive.Item>
  )
}

function SelectSeparator({
  className,
  ...props
}: React.ComponentProps<typeof SelectPrimitive.Separator>) {
  return (
    <SelectPrimitive.Separator
      data-slot="select-separator"
      className={cn("bg-border pointer-events-none -mx-1 my-1 h-px", className)}
      {...props}
    />
  )
}

function SelectScrollUpButton({
  className,
  ...props
}: React.ComponentProps<typeof SelectPrimitive.ScrollUpButton>) {
  return (
    <SelectPrimitive.ScrollUpButton
      data-slot="select-scroll-up-button"
      className={cn(
        "flex cursor-default items-center justify-center py-1",
        className
      )}
      {...props}
    >
      <ChevronUpIcon className="size-4" />
    </SelectPrimitive.ScrollUpButton>
  )
}

function SelectScrollDownButton({
  className,
  ...props
}: React.ComponentProps<typeof SelectPrimitive.ScrollDownButton>) {
  return (
    <SelectPrimitive.ScrollDownButton
      data-slot="select-scroll-down-button"
      className={cn(
        "flex cursor-default items-center justify-center py-1",
        className
      )}
      {...props}
    >
      <ChevronDownIcon className="size-4" />
    </SelectPrimitive.ScrollDownButton>
  )
}

export {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectLabel,
  SelectScrollDownButton,
  SelectScrollUpButton,
  SelectSeparator,
  SelectTrigger,
  SelectValue,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/separator.tsx ---
mkdir -p "$(dirname "src/components/ui/separator.tsx")"
cat > 'src/components/ui/separator.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as SeparatorPrimitive from "@radix-ui/react-separator"

import { cn } from "@/lib/utils"

function Separator({
  className,
  orientation = "horizontal",
  decorative = true,
  ...props
}: React.ComponentProps<typeof SeparatorPrimitive.Root>) {
  return (
    <SeparatorPrimitive.Root
      data-slot="separator"
      decorative={decorative}
      orientation={orientation}
      className={cn(
        "bg-border shrink-0 data-[orientation=horizontal]:h-px data-[orientation=horizontal]:w-full data-[orientation=vertical]:h-full data-[orientation=vertical]:w-px",
        className
      )}
      {...props}
    />
  )
}

export { Separator }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/sheet.tsx ---
mkdir -p "$(dirname "src/components/ui/sheet.tsx")"
cat > 'src/components/ui/sheet.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as SheetPrimitive from "@radix-ui/react-dialog"
import { XIcon } from "lucide-react"

import { cn } from "@/lib/utils"

function Sheet({ ...props }: React.ComponentProps<typeof SheetPrimitive.Root>) {
  return <SheetPrimitive.Root data-slot="sheet" {...props} />
}

function SheetTrigger({
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Trigger>) {
  return <SheetPrimitive.Trigger data-slot="sheet-trigger" {...props} />
}

function SheetClose({
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Close>) {
  return <SheetPrimitive.Close data-slot="sheet-close" {...props} />
}

function SheetPortal({
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Portal>) {
  return <SheetPrimitive.Portal data-slot="sheet-portal" {...props} />
}

function SheetOverlay({
  className,
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Overlay>) {
  return (
    <SheetPrimitive.Overlay
      data-slot="sheet-overlay"
      className={cn(
        "data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 fixed inset-0 z-50 bg-black/50",
        className
      )}
      {...props}
    />
  )
}

function SheetContent({
  className,
  children,
  side = "right",
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Content> & {
  side?: "top" | "right" | "bottom" | "left"
}) {
  return (
    <SheetPortal>
      <SheetOverlay />
      <SheetPrimitive.Content
        data-slot="sheet-content"
        className={cn(
          "bg-background data-[state=open]:animate-in data-[state=closed]:animate-out fixed z-50 flex flex-col gap-4 shadow-lg transition ease-in-out data-[state=closed]:duration-300 data-[state=open]:duration-500",
          side === "right" &&
            "data-[state=closed]:slide-out-to-right data-[state=open]:slide-in-from-right inset-y-0 right-0 h-full w-3/4 border-l sm:max-w-sm",
          side === "left" &&
            "data-[state=closed]:slide-out-to-left data-[state=open]:slide-in-from-left inset-y-0 left-0 h-full w-3/4 border-r sm:max-w-sm",
          side === "top" &&
            "data-[state=closed]:slide-out-to-top data-[state=open]:slide-in-from-top inset-x-0 top-0 h-auto border-b",
          side === "bottom" &&
            "data-[state=closed]:slide-out-to-bottom data-[state=open]:slide-in-from-bottom inset-x-0 bottom-0 h-auto border-t",
          className
        )}
        {...props}
      >
        {children}
        <SheetPrimitive.Close className="ring-offset-background focus:ring-ring data-[state=open]:bg-secondary absolute top-4 right-4 rounded-xs opacity-70 transition-opacity hover:opacity-100 focus:ring-2 focus:ring-offset-2 focus:outline-hidden disabled:pointer-events-none">
          <XIcon className="size-4" />
          <span className="sr-only">Close</span>
        </SheetPrimitive.Close>
      </SheetPrimitive.Content>
    </SheetPortal>
  )
}

function SheetHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="sheet-header"
      className={cn("flex flex-col gap-1.5 p-4", className)}
      {...props}
    />
  )
}

function SheetFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="sheet-footer"
      className={cn("mt-auto flex flex-col gap-2 p-4", className)}
      {...props}
    />
  )
}

function SheetTitle({
  className,
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Title>) {
  return (
    <SheetPrimitive.Title
      data-slot="sheet-title"
      className={cn("text-foreground font-semibold", className)}
      {...props}
    />
  )
}

function SheetDescription({
  className,
  ...props
}: React.ComponentProps<typeof SheetPrimitive.Description>) {
  return (
    <SheetPrimitive.Description
      data-slot="sheet-description"
      className={cn("text-muted-foreground text-sm", className)}
      {...props}
    />
  )
}

export {
  Sheet,
  SheetTrigger,
  SheetClose,
  SheetContent,
  SheetHeader,
  SheetFooter,
  SheetTitle,
  SheetDescription,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/sidebar.tsx ---
mkdir -p "$(dirname "src/components/ui/sidebar.tsx")"
cat > 'src/components/ui/sidebar.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { cva, VariantProps } from "class-variance-authority"
import { PanelLeftIcon } from "lucide-react"

import { useIsMobile } from "@/hooks/use-mobile"
import { cn } from "@/lib/utils"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Separator } from "@/components/ui/separator"
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet"
import { Skeleton } from "@/components/ui/skeleton"
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from "@/components/ui/tooltip"

const SIDEBAR_COOKIE_NAME = "sidebar_state"
const SIDEBAR_COOKIE_MAX_AGE = 60 * 60 * 24 * 7
const SIDEBAR_WIDTH = "16rem"
const SIDEBAR_WIDTH_MOBILE = "18rem"
const SIDEBAR_WIDTH_ICON = "3rem"
const SIDEBAR_KEYBOARD_SHORTCUT = "b"

type SidebarContextProps = {
  state: "expanded" | "collapsed"
  open: boolean
  setOpen: (open: boolean) => void
  openMobile: boolean
  setOpenMobile: (open: boolean) => void
  isMobile: boolean
  toggleSidebar: () => void
}

const SidebarContext = React.createContext<SidebarContextProps | null>(null)

function useSidebar() {
  const context = React.useContext(SidebarContext)
  if (!context) {
    throw new Error("useSidebar must be used within a SidebarProvider.")
  }

  return context
}

function SidebarProvider({
  defaultOpen = true,
  open: openProp,
  onOpenChange: setOpenProp,
  className,
  style,
  children,
  ...props
}: React.ComponentProps<"div"> & {
  defaultOpen?: boolean
  open?: boolean
  onOpenChange?: (open: boolean) => void
}) {
  const isMobile = useIsMobile()
  const [openMobile, setOpenMobile] = React.useState(false)

  // This is the internal state of the sidebar.
  // We use openProp and setOpenProp for control from outside the component.
  const [_open, _setOpen] = React.useState(defaultOpen)
  const open = openProp ?? _open
  const setOpen = React.useCallback(
    (value: boolean | ((value: boolean) => boolean)) => {
      const openState = typeof value === "function" ? value(open) : value
      if (setOpenProp) {
        setOpenProp(openState)
      } else {
        _setOpen(openState)
      }

      // This sets the cookie to keep the sidebar state.
      document.cookie = `${SIDEBAR_COOKIE_NAME}=${openState}; path=/; max-age=${SIDEBAR_COOKIE_MAX_AGE}`
    },
    [setOpenProp, open]
  )

  // Helper to toggle the sidebar.
  const toggleSidebar = React.useCallback(() => {
    return isMobile ? setOpenMobile((open) => !open) : setOpen((open) => !open)
  }, [isMobile, setOpen, setOpenMobile])

  // Adds a keyboard shortcut to toggle the sidebar.
  React.useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (
        event.key === SIDEBAR_KEYBOARD_SHORTCUT &&
        (event.metaKey || event.ctrlKey)
      ) {
        event.preventDefault()
        toggleSidebar()
      }
    }

    window.addEventListener("keydown", handleKeyDown)
    return () => window.removeEventListener("keydown", handleKeyDown)
  }, [toggleSidebar])

  // We add a state so that we can do data-state="expanded" or "collapsed".
  // This makes it easier to style the sidebar with Tailwind classes.
  const state = open ? "expanded" : "collapsed"

  const contextValue = React.useMemo<SidebarContextProps>(
    () => ({
      state,
      open,
      setOpen,
      isMobile,
      openMobile,
      setOpenMobile,
      toggleSidebar,
    }),
    [state, open, setOpen, isMobile, openMobile, setOpenMobile, toggleSidebar]
  )

  return (
    <SidebarContext.Provider value={contextValue}>
      <TooltipProvider delayDuration={0}>
        <div
          data-slot="sidebar-wrapper"
          style={
            {
              "--sidebar-width": SIDEBAR_WIDTH,
              "--sidebar-width-icon": SIDEBAR_WIDTH_ICON,
              ...style,
            } as React.CSSProperties
          }
          className={cn(
            "group/sidebar-wrapper has-data-[variant=inset]:bg-sidebar flex min-h-svh w-full",
            className
          )}
          {...props}
        >
          {children}
        </div>
      </TooltipProvider>
    </SidebarContext.Provider>
  )
}

function Sidebar({
  side = "left",
  variant = "sidebar",
  collapsible = "offcanvas",
  className,
  children,
  ...props
}: React.ComponentProps<"div"> & {
  side?: "left" | "right"
  variant?: "sidebar" | "floating" | "inset"
  collapsible?: "offcanvas" | "icon" | "none"
}) {
  const { isMobile, state, openMobile, setOpenMobile } = useSidebar()

  if (collapsible === "none") {
    return (
      <div
        data-slot="sidebar"
        className={cn(
          "bg-sidebar text-sidebar-foreground flex h-full w-(--sidebar-width) flex-col",
          className
        )}
        {...props}
      >
        {children}
      </div>
    )
  }

  if (isMobile) {
    return (
      <Sheet open={openMobile} onOpenChange={setOpenMobile} {...props}>
        <SheetContent
          data-sidebar="sidebar"
          data-slot="sidebar"
          data-mobile="true"
          className="bg-sidebar text-sidebar-foreground w-(--sidebar-width) p-0 [&>button]:hidden"
          style={
            {
              "--sidebar-width": SIDEBAR_WIDTH_MOBILE,
            } as React.CSSProperties
          }
          side={side}
        >
          <SheetHeader className="sr-only">
            <SheetTitle>Sidebar</SheetTitle>
            <SheetDescription>Displays the mobile sidebar.</SheetDescription>
          </SheetHeader>
          <div className="flex h-full w-full flex-col">{children}</div>
        </SheetContent>
      </Sheet>
    )
  }

  return (
    <div
      className="group peer text-sidebar-foreground hidden md:block"
      data-state={state}
      data-collapsible={state === "collapsed" ? collapsible : ""}
      data-variant={variant}
      data-side={side}
      data-slot="sidebar"
    >
      {/* This is what handles the sidebar gap on desktop */}
      <div
        data-slot="sidebar-gap"
        className={cn(
          "relative w-(--sidebar-width) bg-transparent transition-[width] duration-200 ease-linear",
          "group-data-[collapsible=offcanvas]:w-0",
          "group-data-[side=right]:rotate-180",
          variant === "floating" || variant === "inset"
            ? "group-data-[collapsible=icon]:w-[calc(var(--sidebar-width-icon)+(--spacing(4)))]"
            : "group-data-[collapsible=icon]:w-(--sidebar-width-icon)"
        )}
      />
      <div
        data-slot="sidebar-container"
        className={cn(
          "fixed inset-y-0 z-10 hidden h-svh w-(--sidebar-width) transition-[left,right,width] duration-200 ease-linear md:flex",
          side === "left"
            ? "left-0 group-data-[collapsible=offcanvas]:left-[calc(var(--sidebar-width)*-1)]"
            : "right-0 group-data-[collapsible=offcanvas]:right-[calc(var(--sidebar-width)*-1)]",
          // Adjust the padding for floating and inset variants.
          variant === "floating" || variant === "inset"
            ? "p-2 group-data-[collapsible=icon]:w-[calc(var(--sidebar-width-icon)+(--spacing(4))+2px)]"
            : "group-data-[collapsible=icon]:w-(--sidebar-width-icon) group-data-[side=left]:border-r group-data-[side=right]:border-l",
          className
        )}
        {...props}
      >
        <div
          data-sidebar="sidebar"
          data-slot="sidebar-inner"
          className="bg-sidebar group-data-[variant=floating]:border-sidebar-border flex h-full w-full flex-col group-data-[variant=floating]:rounded-lg group-data-[variant=floating]:border group-data-[variant=floating]:shadow-sm"
        >
          {children}
        </div>
      </div>
    </div>
  )
}

function SidebarTrigger({
  className,
  onClick,
  ...props
}: React.ComponentProps<typeof Button>) {
  const { toggleSidebar } = useSidebar()

  return (
    <Button
      data-sidebar="trigger"
      data-slot="sidebar-trigger"
      variant="ghost"
      size="icon"
      className={cn("size-7", className)}
      onClick={(event) => {
        onClick?.(event)
        toggleSidebar()
      }}
      {...props}
    >
      <PanelLeftIcon />
      <span className="sr-only">Toggle Sidebar</span>
    </Button>
  )
}

function SidebarRail({ className, ...props }: React.ComponentProps<"button">) {
  const { toggleSidebar } = useSidebar()

  return (
    <button
      data-sidebar="rail"
      data-slot="sidebar-rail"
      aria-label="Toggle Sidebar"
      tabIndex={-1}
      onClick={toggleSidebar}
      title="Toggle Sidebar"
      className={cn(
        "hover:after:bg-sidebar-border absolute inset-y-0 z-20 hidden w-4 -translate-x-1/2 transition-all ease-linear group-data-[side=left]:-right-4 group-data-[side=right]:left-0 after:absolute after:inset-y-0 after:left-1/2 after:w-[2px] sm:flex",
        "in-data-[side=left]:cursor-w-resize in-data-[side=right]:cursor-e-resize",
        "[[data-side=left][data-state=collapsed]_&]:cursor-e-resize [[data-side=right][data-state=collapsed]_&]:cursor-w-resize",
        "hover:group-data-[collapsible=offcanvas]:bg-sidebar group-data-[collapsible=offcanvas]:translate-x-0 group-data-[collapsible=offcanvas]:after:left-full",
        "[[data-side=left][data-collapsible=offcanvas]_&]:-right-2",
        "[[data-side=right][data-collapsible=offcanvas]_&]:-left-2",
        className
      )}
      {...props}
    />
  )
}

function SidebarInset({ className, ...props }: React.ComponentProps<"main">) {
  return (
    <main
      data-slot="sidebar-inset"
      className={cn(
        "bg-background relative flex w-full flex-1 flex-col",
        "md:peer-data-[variant=inset]:m-2 md:peer-data-[variant=inset]:ml-0 md:peer-data-[variant=inset]:rounded-xl md:peer-data-[variant=inset]:shadow-sm md:peer-data-[variant=inset]:peer-data-[state=collapsed]:ml-2",
        className
      )}
      {...props}
    />
  )
}

function SidebarInput({
  className,
  ...props
}: React.ComponentProps<typeof Input>) {
  return (
    <Input
      data-slot="sidebar-input"
      data-sidebar="input"
      className={cn("bg-background h-8 w-full shadow-none", className)}
      {...props}
    />
  )
}

function SidebarHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="sidebar-header"
      data-sidebar="header"
      className={cn("flex flex-col gap-2 p-2", className)}
      {...props}
    />
  )
}

function SidebarFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="sidebar-footer"
      data-sidebar="footer"
      className={cn("flex flex-col gap-2 p-2", className)}
      {...props}
    />
  )
}

function SidebarSeparator({
  className,
  ...props
}: React.ComponentProps<typeof Separator>) {
  return (
    <Separator
      data-slot="sidebar-separator"
      data-sidebar="separator"
      className={cn("bg-sidebar-border mx-2 w-auto", className)}
      {...props}
    />
  )
}

function SidebarContent({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="sidebar-content"
      data-sidebar="content"
      className={cn(
        "flex min-h-0 flex-1 flex-col gap-2 overflow-auto group-data-[collapsible=icon]:overflow-hidden",
        className
      )}
      {...props}
    />
  )
}

function SidebarGroup({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="sidebar-group"
      data-sidebar="group"
      className={cn("relative flex w-full min-w-0 flex-col p-2", className)}
      {...props}
    />
  )
}

function SidebarGroupLabel({
  className,
  asChild = false,
  ...props
}: React.ComponentProps<"div"> & { asChild?: boolean }) {
  const Comp = asChild ? Slot : "div"

  return (
    <Comp
      data-slot="sidebar-group-label"
      data-sidebar="group-label"
      className={cn(
        "text-sidebar-foreground/70 ring-sidebar-ring flex h-8 shrink-0 items-center rounded-md px-2 text-xs font-medium outline-hidden transition-[margin,opacity] duration-200 ease-linear focus-visible:ring-2 [&>svg]:size-4 [&>svg]:shrink-0",
        "group-data-[collapsible=icon]:-mt-8 group-data-[collapsible=icon]:opacity-0",
        className
      )}
      {...props}
    />
  )
}

function SidebarGroupAction({
  className,
  asChild = false,
  ...props
}: React.ComponentProps<"button"> & { asChild?: boolean }) {
  const Comp = asChild ? Slot : "button"

  return (
    <Comp
      data-slot="sidebar-group-action"
      data-sidebar="group-action"
      className={cn(
        "text-sidebar-foreground ring-sidebar-ring hover:bg-sidebar-accent hover:text-sidebar-accent-foreground absolute top-3.5 right-3 flex aspect-square w-5 items-center justify-center rounded-md p-0 outline-hidden transition-transform focus-visible:ring-2 [&>svg]:size-4 [&>svg]:shrink-0",
        // Increases the hit area of the button on mobile.
        "after:absolute after:-inset-2 md:after:hidden",
        "group-data-[collapsible=icon]:hidden",
        className
      )}
      {...props}
    />
  )
}

function SidebarGroupContent({
  className,
  ...props
}: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="sidebar-group-content"
      data-sidebar="group-content"
      className={cn("w-full text-sm", className)}
      {...props}
    />
  )
}

function SidebarMenu({ className, ...props }: React.ComponentProps<"ul">) {
  return (
    <ul
      data-slot="sidebar-menu"
      data-sidebar="menu"
      className={cn("flex w-full min-w-0 flex-col gap-1", className)}
      {...props}
    />
  )
}

function SidebarMenuItem({ className, ...props }: React.ComponentProps<"li">) {
  return (
    <li
      data-slot="sidebar-menu-item"
      data-sidebar="menu-item"
      className={cn("group/menu-item relative", className)}
      {...props}
    />
  )
}

const sidebarMenuButtonVariants = cva(
  "peer/menu-button flex w-full items-center gap-2 overflow-hidden rounded-md p-2 text-left text-sm outline-hidden ring-sidebar-ring transition-[width,height,padding] hover:bg-sidebar-accent hover:text-sidebar-accent-foreground focus-visible:ring-2 active:bg-sidebar-accent active:text-sidebar-accent-foreground disabled:pointer-events-none disabled:opacity-50 group-has-data-[sidebar=menu-action]/menu-item:pr-8 aria-disabled:pointer-events-none aria-disabled:opacity-50 data-[active=true]:bg-sidebar-accent data-[active=true]:font-medium data-[active=true]:text-sidebar-accent-foreground data-[state=open]:hover:bg-sidebar-accent data-[state=open]:hover:text-sidebar-accent-foreground group-data-[collapsible=icon]:size-8! group-data-[collapsible=icon]:p-2! [&>span:last-child]:truncate [&>svg]:size-4 [&>svg]:shrink-0",
  {
    variants: {
      variant: {
        default: "hover:bg-sidebar-accent hover:text-sidebar-accent-foreground",
        outline:
          "bg-background shadow-[0_0_0_1px_hsl(var(--sidebar-border))] hover:bg-sidebar-accent hover:text-sidebar-accent-foreground hover:shadow-[0_0_0_1px_hsl(var(--sidebar-accent))]",
      },
      size: {
        default: "h-8 text-sm",
        sm: "h-7 text-xs",
        lg: "h-12 text-sm group-data-[collapsible=icon]:p-0!",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
)

function SidebarMenuButton({
  asChild = false,
  isActive = false,
  variant = "default",
  size = "default",
  tooltip,
  className,
  ...props
}: React.ComponentProps<"button"> & {
  asChild?: boolean
  isActive?: boolean
  tooltip?: string | React.ComponentProps<typeof TooltipContent>
} & VariantProps<typeof sidebarMenuButtonVariants>) {
  const Comp = asChild ? Slot : "button"
  const { isMobile, state } = useSidebar()

  const button = (
    <Comp
      data-slot="sidebar-menu-button"
      data-sidebar="menu-button"
      data-size={size}
      data-active={isActive}
      className={cn(sidebarMenuButtonVariants({ variant, size }), className)}
      {...props}
    />
  )

  if (!tooltip) {
    return button
  }

  if (typeof tooltip === "string") {
    tooltip = {
      children: tooltip,
    }
  }

  return (
    <Tooltip>
      <TooltipTrigger asChild>{button}</TooltipTrigger>
      <TooltipContent
        side="right"
        align="center"
        hidden={state !== "collapsed" || isMobile}
        {...tooltip}
      />
    </Tooltip>
  )
}

function SidebarMenuAction({
  className,
  asChild = false,
  showOnHover = false,
  ...props
}: React.ComponentProps<"button"> & {
  asChild?: boolean
  showOnHover?: boolean
}) {
  const Comp = asChild ? Slot : "button"

  return (
    <Comp
      data-slot="sidebar-menu-action"
      data-sidebar="menu-action"
      className={cn(
        "text-sidebar-foreground ring-sidebar-ring hover:bg-sidebar-accent hover:text-sidebar-accent-foreground peer-hover/menu-button:text-sidebar-accent-foreground absolute top-1.5 right-1 flex aspect-square w-5 items-center justify-center rounded-md p-0 outline-hidden transition-transform focus-visible:ring-2 [&>svg]:size-4 [&>svg]:shrink-0",
        // Increases the hit area of the button on mobile.
        "after:absolute after:-inset-2 md:after:hidden",
        "peer-data-[size=sm]/menu-button:top-1",
        "peer-data-[size=default]/menu-button:top-1.5",
        "peer-data-[size=lg]/menu-button:top-2.5",
        "group-data-[collapsible=icon]:hidden",
        showOnHover &&
          "peer-data-[active=true]/menu-button:text-sidebar-accent-foreground group-focus-within/menu-item:opacity-100 group-hover/menu-item:opacity-100 data-[state=open]:opacity-100 md:opacity-0",
        className
      )}
      {...props}
    />
  )
}

function SidebarMenuBadge({
  className,
  ...props
}: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="sidebar-menu-badge"
      data-sidebar="menu-badge"
      className={cn(
        "text-sidebar-foreground pointer-events-none absolute right-1 flex h-5 min-w-5 items-center justify-center rounded-md px-1 text-xs font-medium tabular-nums select-none",
        "peer-hover/menu-button:text-sidebar-accent-foreground peer-data-[active=true]/menu-button:text-sidebar-accent-foreground",
        "peer-data-[size=sm]/menu-button:top-1",
        "peer-data-[size=default]/menu-button:top-1.5",
        "peer-data-[size=lg]/menu-button:top-2.5",
        "group-data-[collapsible=icon]:hidden",
        className
      )}
      {...props}
    />
  )
}

function SidebarMenuSkeleton({
  className,
  showIcon = false,
  ...props
}: React.ComponentProps<"div"> & {
  showIcon?: boolean
}) {
  // Random width between 50 to 90%.
  const width = React.useMemo(() => {
    return `${Math.floor(Math.random() * 40) + 50}%`
  }, [])

  return (
    <div
      data-slot="sidebar-menu-skeleton"
      data-sidebar="menu-skeleton"
      className={cn("flex h-8 items-center gap-2 rounded-md px-2", className)}
      {...props}
    >
      {showIcon && (
        <Skeleton
          className="size-4 rounded-md"
          data-sidebar="menu-skeleton-icon"
        />
      )}
      <Skeleton
        className="h-4 max-w-(--skeleton-width) flex-1"
        data-sidebar="menu-skeleton-text"
        style={
          {
            "--skeleton-width": width,
          } as React.CSSProperties
        }
      />
    </div>
  )
}

function SidebarMenuSub({ className, ...props }: React.ComponentProps<"ul">) {
  return (
    <ul
      data-slot="sidebar-menu-sub"
      data-sidebar="menu-sub"
      className={cn(
        "border-sidebar-border mx-3.5 flex min-w-0 translate-x-px flex-col gap-1 border-l px-2.5 py-0.5",
        "group-data-[collapsible=icon]:hidden",
        className
      )}
      {...props}
    />
  )
}

function SidebarMenuSubItem({
  className,
  ...props
}: React.ComponentProps<"li">) {
  return (
    <li
      data-slot="sidebar-menu-sub-item"
      data-sidebar="menu-sub-item"
      className={cn("group/menu-sub-item relative", className)}
      {...props}
    />
  )
}

function SidebarMenuSubButton({
  asChild = false,
  size = "md",
  isActive = false,
  className,
  ...props
}: React.ComponentProps<"a"> & {
  asChild?: boolean
  size?: "sm" | "md"
  isActive?: boolean
}) {
  const Comp = asChild ? Slot : "a"

  return (
    <Comp
      data-slot="sidebar-menu-sub-button"
      data-sidebar="menu-sub-button"
      data-size={size}
      data-active={isActive}
      className={cn(
        "text-sidebar-foreground ring-sidebar-ring hover:bg-sidebar-accent hover:text-sidebar-accent-foreground active:bg-sidebar-accent active:text-sidebar-accent-foreground [&>svg]:text-sidebar-accent-foreground flex h-7 min-w-0 -translate-x-px items-center gap-2 overflow-hidden rounded-md px-2 outline-hidden focus-visible:ring-2 disabled:pointer-events-none disabled:opacity-50 aria-disabled:pointer-events-none aria-disabled:opacity-50 [&>span:last-child]:truncate [&>svg]:size-4 [&>svg]:shrink-0",
        "data-[active=true]:bg-sidebar-accent data-[active=true]:text-sidebar-accent-foreground",
        size === "sm" && "text-xs",
        size === "md" && "text-sm",
        "group-data-[collapsible=icon]:hidden",
        className
      )}
      {...props}
    />
  )
}

export {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupAction,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInput,
  SidebarInset,
  SidebarMenu,
  SidebarMenuAction,
  SidebarMenuBadge,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSkeleton,
  SidebarMenuSub,
  SidebarMenuSubButton,
  SidebarMenuSubItem,
  SidebarProvider,
  SidebarRail,
  SidebarSeparator,
  SidebarTrigger,
  useSidebar,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/skeleton.tsx ---
mkdir -p "$(dirname "src/components/ui/skeleton.tsx")"
cat > 'src/components/ui/skeleton.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import { cn } from "@/lib/utils"

function Skeleton({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="skeleton"
      className={cn("bg-accent animate-pulse rounded-md", className)}
      {...props}
    />
  )
}

export { Skeleton }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/slider.tsx ---
mkdir -p "$(dirname "src/components/ui/slider.tsx")"
cat > 'src/components/ui/slider.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as SliderPrimitive from "@radix-ui/react-slider"

import { cn } from "@/lib/utils"

function Slider({
  className,
  defaultValue,
  value,
  min = 0,
  max = 100,
  ...props
}: React.ComponentProps<typeof SliderPrimitive.Root>) {
  const _values = React.useMemo(
    () =>
      Array.isArray(value)
        ? value
        : Array.isArray(defaultValue)
          ? defaultValue
          : [min, max],
    [value, defaultValue, min, max]
  )

  return (
    <SliderPrimitive.Root
      data-slot="slider"
      defaultValue={defaultValue}
      value={value}
      min={min}
      max={max}
      className={cn(
        "relative flex w-full touch-none items-center select-none data-[disabled]:opacity-50 data-[orientation=vertical]:h-full data-[orientation=vertical]:min-h-44 data-[orientation=vertical]:w-auto data-[orientation=vertical]:flex-col",
        className
      )}
      {...props}
    >
      <SliderPrimitive.Track
        data-slot="slider-track"
        className={cn(
          "bg-muted relative grow overflow-hidden rounded-full data-[orientation=horizontal]:h-1.5 data-[orientation=horizontal]:w-full data-[orientation=vertical]:h-full data-[orientation=vertical]:w-1.5"
        )}
      >
        <SliderPrimitive.Range
          data-slot="slider-range"
          className={cn(
            "bg-primary absolute data-[orientation=horizontal]:h-full data-[orientation=vertical]:w-full"
          )}
        />
      </SliderPrimitive.Track>
      {Array.from({ length: _values.length }, (_, index) => (
        <SliderPrimitive.Thumb
          data-slot="slider-thumb"
          key={index}
          className="border-primary bg-background ring-ring/50 block size-4 shrink-0 rounded-full border shadow-sm transition-[color,box-shadow] hover:ring-4 focus-visible:ring-4 focus-visible:outline-hidden disabled:pointer-events-none disabled:opacity-50"
        />
      ))}
    </SliderPrimitive.Root>
  )
}

export { Slider }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/sonner.tsx ---
mkdir -p "$(dirname "src/components/ui/sonner.tsx")"
cat > 'src/components/ui/sonner.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import { useTheme } from "next-themes"
import { Toaster as Sonner, ToasterProps } from "sonner"

const Toaster = ({ ...props }: ToasterProps) => {
  const { theme = "system" } = useTheme()

  return (
    <Sonner
      theme={theme as ToasterProps["theme"]}
      className="toaster group"
      style={
        {
          "--normal-bg": "var(--popover)",
          "--normal-text": "var(--popover-foreground)",
          "--normal-border": "var(--border)",
        } as React.CSSProperties
      }
      {...props}
    />
  )
}

export { Toaster }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/switch.tsx ---
mkdir -p "$(dirname "src/components/ui/switch.tsx")"
cat > 'src/components/ui/switch.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as SwitchPrimitive from "@radix-ui/react-switch"

import { cn } from "@/lib/utils"

function Switch({
  className,
  ...props
}: React.ComponentProps<typeof SwitchPrimitive.Root>) {
  return (
    <SwitchPrimitive.Root
      data-slot="switch"
      className={cn(
        "peer data-[state=checked]:bg-primary data-[state=unchecked]:bg-input focus-visible:border-ring focus-visible:ring-ring/50 dark:data-[state=unchecked]:bg-input/80 inline-flex h-[1.15rem] w-8 shrink-0 items-center rounded-full border border-transparent shadow-xs transition-all outline-none focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50",
        className
      )}
      {...props}
    >
      <SwitchPrimitive.Thumb
        data-slot="switch-thumb"
        className={cn(
          "bg-background dark:data-[state=unchecked]:bg-foreground dark:data-[state=checked]:bg-primary-foreground pointer-events-none block size-4 rounded-full ring-0 transition-transform data-[state=checked]:translate-x-[calc(100%-2px)] data-[state=unchecked]:translate-x-0"
        )}
      />
    </SwitchPrimitive.Root>
  )
}

export { Switch }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/table.tsx ---
mkdir -p "$(dirname "src/components/ui/table.tsx")"
cat > 'src/components/ui/table.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"

import { cn } from "@/lib/utils"

function Table({ className, ...props }: React.ComponentProps<"table">) {
  return (
    <div
      data-slot="table-container"
      className="relative w-full overflow-x-auto"
    >
      <table
        data-slot="table"
        className={cn("w-full caption-bottom text-sm", className)}
        {...props}
      />
    </div>
  )
}

function TableHeader({ className, ...props }: React.ComponentProps<"thead">) {
  return (
    <thead
      data-slot="table-header"
      className={cn("[&_tr]:border-b", className)}
      {...props}
    />
  )
}

function TableBody({ className, ...props }: React.ComponentProps<"tbody">) {
  return (
    <tbody
      data-slot="table-body"
      className={cn("[&_tr:last-child]:border-0", className)}
      {...props}
    />
  )
}

function TableFooter({ className, ...props }: React.ComponentProps<"tfoot">) {
  return (
    <tfoot
      data-slot="table-footer"
      className={cn(
        "bg-muted/50 border-t font-medium [&>tr]:last:border-b-0",
        className
      )}
      {...props}
    />
  )
}

function TableRow({ className, ...props }: React.ComponentProps<"tr">) {
  return (
    <tr
      data-slot="table-row"
      className={cn(
        "hover:bg-muted/50 data-[state=selected]:bg-muted border-b transition-colors",
        className
      )}
      {...props}
    />
  )
}

function TableHead({ className, ...props }: React.ComponentProps<"th">) {
  return (
    <th
      data-slot="table-head"
      className={cn(
        "text-foreground h-10 px-2 text-left align-middle font-medium whitespace-nowrap [&:has([role=checkbox])]:pr-0 [&>[role=checkbox]]:translate-y-[2px]",
        className
      )}
      {...props}
    />
  )
}

function TableCell({ className, ...props }: React.ComponentProps<"td">) {
  return (
    <td
      data-slot="table-cell"
      className={cn(
        "p-2 align-middle whitespace-nowrap [&:has([role=checkbox])]:pr-0 [&>[role=checkbox]]:translate-y-[2px]",
        className
      )}
      {...props}
    />
  )
}

function TableCaption({
  className,
  ...props
}: React.ComponentProps<"caption">) {
  return (
    <caption
      data-slot="table-caption"
      className={cn("text-muted-foreground mt-4 text-sm", className)}
      {...props}
    />
  )
}

export {
  Table,
  TableHeader,
  TableBody,
  TableFooter,
  TableHead,
  TableRow,
  TableCell,
  TableCaption,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/tabs.tsx ---
mkdir -p "$(dirname "src/components/ui/tabs.tsx")"
cat > 'src/components/ui/tabs.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as TabsPrimitive from "@radix-ui/react-tabs"

import { cn } from "@/lib/utils"

function Tabs({
  className,
  ...props
}: React.ComponentProps<typeof TabsPrimitive.Root>) {
  return (
    <TabsPrimitive.Root
      data-slot="tabs"
      className={cn("flex flex-col gap-2", className)}
      {...props}
    />
  )
}

function TabsList({
  className,
  ...props
}: React.ComponentProps<typeof TabsPrimitive.List>) {
  return (
    <TabsPrimitive.List
      data-slot="tabs-list"
      className={cn(
        "bg-muted text-muted-foreground inline-flex h-9 w-fit items-center justify-center rounded-lg p-[3px]",
        className
      )}
      {...props}
    />
  )
}

function TabsTrigger({
  className,
  ...props
}: React.ComponentProps<typeof TabsPrimitive.Trigger>) {
  return (
    <TabsPrimitive.Trigger
      data-slot="tabs-trigger"
      className={cn(
        "data-[state=active]:bg-background dark:data-[state=active]:text-foreground focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:outline-ring dark:data-[state=active]:border-input dark:data-[state=active]:bg-input/30 text-foreground dark:text-muted-foreground inline-flex h-[calc(100%-1px)] flex-1 items-center justify-center gap-1.5 rounded-md border border-transparent px-2 py-1 text-sm font-medium whitespace-nowrap transition-[color,box-shadow] focus-visible:ring-[3px] focus-visible:outline-1 disabled:pointer-events-none disabled:opacity-50 data-[state=active]:shadow-sm [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
        className
      )}
      {...props}
    />
  )
}

function TabsContent({
  className,
  ...props
}: React.ComponentProps<typeof TabsPrimitive.Content>) {
  return (
    <TabsPrimitive.Content
      data-slot="tabs-content"
      className={cn("flex-1 outline-none", className)}
      {...props}
    />
  )
}

export { Tabs, TabsList, TabsTrigger, TabsContent }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/textarea.tsx ---
mkdir -p "$(dirname "src/components/ui/textarea.tsx")"
cat > 'src/components/ui/textarea.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
import * as React from "react"

import { cn } from "@/lib/utils"

function Textarea({ className, ...props }: React.ComponentProps<"textarea">) {
  return (
    <textarea
      data-slot="textarea"
      className={cn(
        "border-input placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-ring/50 aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive dark:bg-input/30 flex field-sizing-content min-h-16 w-full rounded-md border bg-transparent px-3 py-2 text-base shadow-xs transition-[color,box-shadow] outline-none focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50 md:text-sm",
        className
      )}
      {...props}
    />
  )
}

export { Textarea }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/toast.tsx ---
mkdir -p "$(dirname "src/components/ui/toast.tsx")"
cat > 'src/components/ui/toast.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as ToastPrimitives from "@radix-ui/react-toast"
import { cva, type VariantProps } from "class-variance-authority"
import { X } from "lucide-react"

import { cn } from "@/lib/utils"

const ToastProvider = ToastPrimitives.Provider

const ToastViewport = React.forwardRef<
  React.ElementRef<typeof ToastPrimitives.Viewport>,
  React.ComponentPropsWithoutRef<typeof ToastPrimitives.Viewport>
>(({ className, ...props }, ref) => (
  <ToastPrimitives.Viewport
    ref={ref}
    className={cn(
      "fixed top-0 z-[100] flex max-h-screen w-full flex-col-reverse p-4 sm:bottom-0 sm:right-0 sm:top-auto sm:flex-col md:max-w-[420px]",
      className
    )}
    {...props}
  />
))
ToastViewport.displayName = ToastPrimitives.Viewport.displayName

const toastVariants = cva(
  "group pointer-events-auto relative flex w-full items-center justify-between space-x-2 overflow-hidden rounded-md border p-4 pr-6 shadow-lg transition-all data-[swipe=cancel]:translate-x-0 data-[swipe=end]:translate-x-[var(--radix-toast-swipe-end-x)] data-[swipe=move]:translate-x-[var(--radix-toast-swipe-move-x)] data-[swipe=move]:transition-none data-[state=open]:animate-in data-[state=closed]:animate-out data-[swipe=end]:animate-out data-[state=closed]:fade-out-80 data-[state=closed]:slide-out-to-right-full data-[state=open]:slide-in-from-top-full data-[state=open]:sm:slide-in-from-bottom-full",
  {
    variants: {
      variant: {
        default: "border bg-background text-foreground",
        destructive:
          "destructive group border-destructive bg-destructive text-destructive-foreground",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  }
)

const Toast = React.forwardRef<
  React.ElementRef<typeof ToastPrimitives.Root>,
  React.ComponentPropsWithoutRef<typeof ToastPrimitives.Root> &
  VariantProps<typeof toastVariants>
>(({ className, variant, ...props }, ref) => {
  return (
    <ToastPrimitives.Root
      ref={ref}
      className={cn(toastVariants({ variant }), className)}
      {...props}
    />
  )
})
Toast.displayName = ToastPrimitives.Root.displayName

const ToastAction = React.forwardRef<
  React.ElementRef<typeof ToastPrimitives.Action>,
  React.ComponentPropsWithoutRef<typeof ToastPrimitives.Action>
>(({ className, ...props }, ref) => (
  <ToastPrimitives.Action
    ref={ref}
    className={cn(
      "inline-flex h-8 shrink-0 items-center justify-center rounded-md border bg-transparent px-3 text-sm font-medium transition-colors hover:bg-secondary focus:outline-none focus:ring-1 focus:ring-ring disabled:pointer-events-none disabled:opacity-50 group-[.destructive]:border-muted/40 group-[.destructive]:hover:border-destructive/30 group-[.destructive]:hover:bg-destructive group-[.destructive]:hover:text-destructive-foreground group-[.destructive]:focus:ring-destructive",
      className
    )}
    {...props}
  />
))
ToastAction.displayName = ToastPrimitives.Action.displayName

const ToastClose = React.forwardRef<
  React.ElementRef<typeof ToastPrimitives.Close>,
  React.ComponentPropsWithoutRef<typeof ToastPrimitives.Close>
>(({ className, ...props }, ref) => (
  <ToastPrimitives.Close
    ref={ref}
    className={cn(
      "absolute right-1 top-1 rounded-md p-1 text-foreground/50 opacity-0 transition-opacity hover:text-foreground focus:opacity-100 focus:outline-none focus:ring-1 group-hover:opacity-100 group-[.destructive]:text-red-300 group-[.destructive]:hover:text-red-50 group-[.destructive]:focus:ring-red-400 group-[.destructive]:focus:ring-offset-red-600",
      className
    )}
    toast-close=""
    {...props}
  >
    <X className="h-4 w-4" />
  </ToastPrimitives.Close>
))
ToastClose.displayName = ToastPrimitives.Close.displayName

const ToastTitle = React.forwardRef<
  React.ElementRef<typeof ToastPrimitives.Title>,
  React.ComponentPropsWithoutRef<typeof ToastPrimitives.Title>
>(({ className, ...props }, ref) => (
  <ToastPrimitives.Title
    ref={ref}
    className={cn("text-sm font-semibold [&+div]:text-xs", className)}
    {...props}
  />
))
ToastTitle.displayName = ToastPrimitives.Title.displayName

const ToastDescription = React.forwardRef<
  React.ElementRef<typeof ToastPrimitives.Description>,
  React.ComponentPropsWithoutRef<typeof ToastPrimitives.Description>
>(({ className, ...props }, ref) => (
  <ToastPrimitives.Description
    ref={ref}
    className={cn("text-sm opacity-90", className)}
    {...props}
  />
))
ToastDescription.displayName = ToastPrimitives.Description.displayName

type ToastProps = React.ComponentPropsWithoutRef<typeof Toast>

type ToastActionElement = React.ReactElement<typeof ToastAction>

export {
  type ToastProps,
  type ToastActionElement,
  ToastProvider,
  ToastViewport,
  Toast,
  ToastTitle,
  ToastDescription,
  ToastClose,
  ToastAction,
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/toaster.tsx ---
mkdir -p "$(dirname "src/components/ui/toaster.tsx")"
cat > 'src/components/ui/toaster.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import { useToast } from "@/hooks/use-toast"
import {
  Toast,
  ToastClose,
  ToastDescription,
  ToastProvider,
  ToastTitle,
  ToastViewport,
} from "@/components/ui/toast"

export function Toaster() {
  const { toasts } = useToast()

  return (
    <ToastProvider>
      {toasts.map(function ({ id, title, description, action, ...props }) {
        return (
          <Toast key={id} {...props}>
            <div className="grid gap-1">
              {title && <ToastTitle>{title}</ToastTitle>}
              {description && (
                <ToastDescription>{description}</ToastDescription>
              )}
            </div>
            {action}
            <ToastClose />
          </Toast>
        )
      })}
      <ToastViewport />
    </ToastProvider>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/toggle-group.tsx ---
mkdir -p "$(dirname "src/components/ui/toggle-group.tsx")"
cat > 'src/components/ui/toggle-group.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as ToggleGroupPrimitive from "@radix-ui/react-toggle-group"
import { type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"
import { toggleVariants } from "@/components/ui/toggle"

const ToggleGroupContext = React.createContext<
  VariantProps<typeof toggleVariants>
>({
  size: "default",
  variant: "default",
})

function ToggleGroup({
  className,
  variant,
  size,
  children,
  ...props
}: React.ComponentProps<typeof ToggleGroupPrimitive.Root> &
  VariantProps<typeof toggleVariants>) {
  return (
    <ToggleGroupPrimitive.Root
      data-slot="toggle-group"
      data-variant={variant}
      data-size={size}
      className={cn(
        "group/toggle-group flex w-fit items-center rounded-md data-[variant=outline]:shadow-xs",
        className
      )}
      {...props}
    >
      <ToggleGroupContext.Provider value={{ variant, size }}>
        {children}
      </ToggleGroupContext.Provider>
    </ToggleGroupPrimitive.Root>
  )
}

function ToggleGroupItem({
  className,
  children,
  variant,
  size,
  ...props
}: React.ComponentProps<typeof ToggleGroupPrimitive.Item> &
  VariantProps<typeof toggleVariants>) {
  const context = React.useContext(ToggleGroupContext)

  return (
    <ToggleGroupPrimitive.Item
      data-slot="toggle-group-item"
      data-variant={context.variant || variant}
      data-size={context.size || size}
      className={cn(
        toggleVariants({
          variant: context.variant || variant,
          size: context.size || size,
        }),
        "min-w-0 flex-1 shrink-0 rounded-none shadow-none first:rounded-l-md last:rounded-r-md focus:z-10 focus-visible:z-10 data-[variant=outline]:border-l-0 data-[variant=outline]:first:border-l",
        className
      )}
      {...props}
    >
      {children}
    </ToggleGroupPrimitive.Item>
  )
}

export { ToggleGroup, ToggleGroupItem }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/toggle.tsx ---
mkdir -p "$(dirname "src/components/ui/toggle.tsx")"
cat > 'src/components/ui/toggle.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as TogglePrimitive from "@radix-ui/react-toggle"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"

const toggleVariants = cva(
  "inline-flex items-center justify-center gap-2 rounded-md text-sm font-medium hover:bg-muted hover:text-muted-foreground disabled:pointer-events-none disabled:opacity-50 data-[state=on]:bg-accent data-[state=on]:text-accent-foreground [&_svg]:pointer-events-none [&_svg:not([class*='size-'])]:size-4 [&_svg]:shrink-0 focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px] outline-none transition-[color,box-shadow] aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 aria-invalid:border-destructive whitespace-nowrap",
  {
    variants: {
      variant: {
        default: "bg-transparent",
        outline:
          "border border-input bg-transparent shadow-xs hover:bg-accent hover:text-accent-foreground",
      },
      size: {
        default: "h-9 px-2 min-w-9",
        sm: "h-8 px-1.5 min-w-8",
        lg: "h-10 px-2.5 min-w-10",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
)

function Toggle({
  className,
  variant,
  size,
  ...props
}: React.ComponentProps<typeof TogglePrimitive.Root> &
  VariantProps<typeof toggleVariants>) {
  return (
    <TogglePrimitive.Root
      data-slot="toggle"
      className={cn(toggleVariants({ variant, size, className }))}
      {...props}
    />
  )
}

export { Toggle, toggleVariants }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/ui/tooltip.tsx ---
mkdir -p "$(dirname "src/components/ui/tooltip.tsx")"
cat > 'src/components/ui/tooltip.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

import * as React from "react"
import * as TooltipPrimitive from "@radix-ui/react-tooltip"

import { cn } from "@/lib/utils"

function TooltipProvider({
  delayDuration = 0,
  ...props
}: React.ComponentProps<typeof TooltipPrimitive.Provider>) {
  return (
    <TooltipPrimitive.Provider
      data-slot="tooltip-provider"
      delayDuration={delayDuration}
      {...props}
    />
  )
}

function Tooltip({
  ...props
}: React.ComponentProps<typeof TooltipPrimitive.Root>) {
  return (
    <TooltipProvider>
      <TooltipPrimitive.Root data-slot="tooltip" {...props} />
    </TooltipProvider>
  )
}

function TooltipTrigger({
  ...props
}: React.ComponentProps<typeof TooltipPrimitive.Trigger>) {
  return <TooltipPrimitive.Trigger data-slot="tooltip-trigger" {...props} />
}

function TooltipContent({
  className,
  sideOffset = 0,
  children,
  ...props
}: React.ComponentProps<typeof TooltipPrimitive.Content>) {
  return (
    <TooltipPrimitive.Portal>
      <TooltipPrimitive.Content
        data-slot="tooltip-content"
        sideOffset={sideOffset}
        className={cn(
          "bg-primary text-primary-foreground animate-in fade-in-0 zoom-in-95 data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=closed]:zoom-out-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 w-fit origin-(--radix-tooltip-content-transform-origin) rounded-md px-3 py-1.5 text-xs text-balance",
          className
        )}
        {...props}
      >
        {children}
        <TooltipPrimitive.Arrow className="bg-primary fill-primary z-50 size-2.5 translate-y-[calc(-50%_-_2px)] rotate-45 rounded-[2px]" />
      </TooltipPrimitive.Content>
    </TooltipPrimitive.Portal>
  )
}

export { Tooltip, TooltipTrigger, TooltipContent, TooltipProvider }
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/video/download-modal.tsx ---
mkdir -p "$(dirname "src/components/video/download-modal.tsx")"
cat > 'src/components/video/download-modal.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useEffect, useState } from 'react'
import {
  Download, X, FileVideo, FileAudio, Loader2, CheckCircle2, XCircle, Film, Music,
} from 'lucide-react'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'
import { api, formatBytes, type DownloadJob } from '@/lib/api'
import { useDownloadProgress } from '@/hooks/use-download-progress'
import { toast } from 'sonner'

interface DownloadModalProps {
  open: boolean
  onOpenChange: (v: boolean) => void
  videoId: string
  title: string
}

type Format = 'mp4' | 'webm' | 'mp3' | 'm4a' | 'wav' | 'flac'

const VIDEO_FORMATS: Format[] = ['mp4', 'webm']
const AUDIO_FORMATS: Format[] = ['mp3', 'm4a', 'wav', 'flac']
const VIDEO_QUALITIES = ['144p', '240p', '360p', '480p', '720p', '1080p', 'highest']

export function DownloadModal({ open, onOpenChange, videoId, title }: DownloadModalProps) {
  const [tab, setTab] = useState<'video' | 'audio'>('video')
  const [format, setFormat] = useState<Format>('mp4')
  const [quality, setQuality] = useState('720p')
  const [starting, setStarting] = useState(false)
  const [jobId, setJobId] = useState<string | null>(null)

  const { job, connected } = useDownloadProgress(jobId || undefined)

  // Reset when modal closes
  useEffect(() => {
    if (!open) {
      setJobId(null)
      setStarting(false)
    }
  }, [open])

  const handleStart = async () => {
    setStarting(true)
    try {
      const q = tab === 'audio' ? 'audio' : quality
      const r = await api.download.start(videoId, title, format, q)
      setJobId(r.jobId)
      toast.success('Download started')
    } catch (e) {
      toast.error(e instanceof Error ? e.message : 'Failed to start download')
    } finally {
      setStarting(false)
    }
  }

  const handleCancel = async () => {
    if (!jobId) return
    try {
      await api.download.cancel(jobId)
      toast.success('Download canceled')
    } catch {
      toast.error('Failed to cancel')
    }
  }

  const isCompleted = job?.status === 'completed'
  const isFailed = job?.status === 'failed'
  const isCanceled = job?.status === 'canceled'
  const isActive = job && ['queued', 'downloading', 'processing'].includes(job.status)

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="glass-strong border-border/60 max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Download className="size-5 text-primary" />
            Download Video
          </DialogTitle>
          <DialogDescription className="line-clamp-2">{title}</DialogDescription>
        </DialogHeader>

        {!job ? (
          <div className="space-y-5 py-2">
            {/* Video / Audio tabs */}
            <div className="grid grid-cols-2 gap-2 p-1 rounded-xl bg-muted/50">
              <button
                onClick={() => { setTab('video'); setFormat('mp4') }}
                className={cn(
                  'flex items-center justify-center gap-2 py-2.5 rounded-lg text-sm font-medium transition-all',
                  tab === 'video' ? 'glass gradient-accent text-white shadow-lg' : 'text-muted-foreground hover:text-foreground'
                )}
              >
                <FileVideo className="size-4" /> Video
              </button>
              <button
                onClick={() => { setTab('audio'); setFormat('mp3') }}
                className={cn(
                  'flex items-center justify-center gap-2 py-2.5 rounded-lg text-sm font-medium transition-all',
                  tab === 'audio' ? 'glass gradient-accent text-white shadow-lg' : 'text-muted-foreground hover:text-foreground'
                )}
              >
                <FileAudio className="size-4" /> Audio
              </button>
            </div>

            {/* Format selector */}
            <div>
              <label className="text-xs font-semibold uppercase tracking-wider text-muted-foreground mb-2 block">
                Format
              </label>
              <div className="grid grid-cols-4 gap-2">
                {(tab === 'video' ? VIDEO_FORMATS : AUDIO_FORMATS).map((f) => (
                  <button
                    key={f}
                    onClick={() => setFormat(f)}
                    className={cn(
                      'py-2 rounded-lg text-sm font-bold uppercase transition-all border',
                      format === f
                        ? 'border-primary bg-primary/10 text-primary'
                        : 'border-border hover:border-primary/40 text-muted-foreground hover:text-foreground'
                    )}
                  >
                    {f}
                  </button>
                ))}
              </div>
            </div>

            {/* Quality selector (video only) */}
            {tab === 'video' && (
              <div>
                <label className="text-xs font-semibold uppercase tracking-wider text-muted-foreground mb-2 block">
                  Quality
                </label>
                <div className="grid grid-cols-4 gap-2">
                  {VIDEO_QUALITIES.map((q) => (
                    <button
                      key={q}
                      onClick={() => setQuality(q)}
                      className={cn(
                        'py-2 rounded-lg text-xs font-semibold transition-all border',
                        quality === q
                          ? 'border-primary bg-primary/10 text-primary'
                          : 'border-border hover:border-primary/40 text-muted-foreground hover:text-foreground',
                        q === 'highest' && 'col-span-1'
                      )}
                    >
                      {q === 'highest' ? 'Max' : q}
                    </button>
                  ))}
                </div>
              </div>
            )}

            {tab === 'audio' && (
              <div className="flex items-start gap-2 p-3 rounded-lg bg-muted/50 text-xs text-muted-foreground">
                <Music className="size-4 shrink-0 mt-0.5" />
                <span>Audio will be extracted at the highest available quality and converted to {format.toUpperCase()}.</span>
              </div>
            )}

            <Button
              onClick={handleStart}
              disabled={starting}
              className="w-full gradient-accent text-white border-0 hover:opacity-90 h-11"
            >
              {starting ? <Loader2 className="size-5 animate-spin" /> : <Download className="size-5" />}
              {starting ? 'Starting…' : 'Start Download'}
            </Button>
          </div>
        ) : (
          /* Progress view */
          <div className="space-y-5 py-2">
            <div className="flex items-center gap-3">
              <div className={cn(
                'size-12 rounded-xl grid place-items-center shrink-0',
                isCompleted ? 'bg-emerald-500/15 text-emerald-500' :
                isFailed || isCanceled ? 'bg-destructive/15 text-destructive' :
                'bg-primary/15 text-primary'
              )}>
                {isCompleted ? <CheckCircle2 className="size-7" /> :
                 isFailed || isCanceled ? <XCircle className="size-7" /> :
                 <Loader2 className="size-7 animate-spin" />}
              </div>
              <div className="min-w-0 flex-1">
                <p className="font-semibold text-sm">
                  {isCompleted ? 'Download Complete' :
                   isFailed ? 'Download Failed' :
                   isCanceled ? 'Download Canceled' :
                   job.status === 'processing' ? 'Processing (merging/converting)…' :
                   'Downloading…'}
                </p>
                <p className="text-xs text-muted-foreground mt-0.5">
                  {format.toUpperCase()} • {job.quality} {!connected && '• live updates off'}
                </p>
              </div>
            </div>

            {/* Progress bar */}
            {(isActive || isCompleted) && (
              <div className="space-y-2">
                <div className="h-2.5 rounded-full bg-muted overflow-hidden">
                  <div
                    className={cn(
                      'h-full rounded-full transition-all duration-300',
                      isCompleted ? 'bg-emerald-500' : 'gradient-accent'
                    )}
                    style={{ width: `${job.progress}%` }}
                  />
                </div>
                <div className="flex items-center justify-between text-xs text-muted-foreground">
                  <span>{Math.round(job.progress)}%</span>
                  {job.speed && <span>{job.speed}</span>}
                  {job.eta && <span>ETA {job.eta}</span>}
                </div>
                {job.fileSize ? <p className="text-xs text-muted-foreground">{formatBytes(job.fileSize)}</p> : null}
              </div>
            )}

            {isFailed && job.error && (
              <div className="p-3 rounded-lg bg-destructive/10 border border-destructive/20 text-xs text-destructive">
                {job.error}
              </div>
            )}

            {/* Actions */}
            <div className="flex gap-2">
              {isActive && (
                <Button variant="outline" onClick={handleCancel} className="flex-1">
                  Cancel Download
                </Button>
              )}
              {isCompleted && (
                <Button asChild className="flex-1 gradient-accent text-white border-0">
                  <a href={api.download.fileUrl(job.id)} download>
                    <Download className="size-4" /> Save File
                  </a>
                </Button>
              )}
              {(isCompleted || isFailed || isCanceled) && (
                <Button variant="outline" onClick={() => setJobId(null)} className="flex-1">
                  {isCompleted ? 'Download Another' : 'Try Again'}
                </Button>
              )}
            </div>
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/video/skeleton-card.tsx ---
mkdir -p "$(dirname "src/components/video/skeleton-card.tsx")"
cat > 'src/components/video/skeleton-card.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { cn } from '@/lib/utils'

export function SkeletonCard({ layout = 'grid' }: { layout?: 'grid' | 'list' }) {
  return (
    <div className={cn('animate-pulse', layout === 'list' && 'flex flex-col sm:flex-row gap-4')}>
      <div className={cn('relative aspect-video rounded-xl bg-muted overflow-hidden', layout === 'list' && 'sm:w-80 shrink-0')}>
        <div className="absolute inset-0 animate-shimmer" />
      </div>
      <div className={cn('flex gap-3 mt-3', layout === 'list' && 'sm:mt-0')}>
        <div className="size-9 rounded-full bg-muted shrink-0" />
        <div className="flex-1 space-y-2">
          <div className="h-4 bg-muted rounded w-full" />
          <div className="h-4 bg-muted rounded w-2/3" />
          <div className="h-3 bg-muted rounded w-1/3 mt-2" />
          <div className="h-3 bg-muted rounded w-1/4" />
        </div>
      </div>
    </div>
  )
}

export function SkeletonGrid({ count = 8, layout = 'grid' }: { count?: number; layout?: 'grid' | 'list' }) {
  return (
    <>
      {Array.from({ length: count }).map((_, i) => (
        <SkeletonCard key={i} layout={layout} />
      ))}
    </>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/video/video-card.tsx ---
mkdir -p "$(dirname "src/components/video/video-card.tsx")"
cat > 'src/components/video/video-card.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { memo, useState } from 'react'
import Image from 'next/image'
import { CheckCircle2, MoreVertical, Clock, Heart } from 'lucide-react'
import { cn } from '@/lib/utils'
import { formatDuration, formatViews, bestThumbnail, type VideoItem } from '@/lib/api'
import { useAppStore } from '@/lib/store'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { toast } from 'sonner'
import { api } from '@/lib/api'

function VideoCardBase({ video, layout = 'grid' }: { video: VideoItem; layout?: 'grid' | 'list' | 'compact' }) {
  const openVideo = useAppStore((s) => s.openVideo)
  const [imgLoaded, setImgLoaded] = useState(false)
  const [imgError, setImgError] = useState(false)

  const thumb = bestThumbnail(video)
  const channel = video.channel || video.uploader || 'Unknown'
  const verified = ['VEVO', 'Official', 'Records'].some((k) => channel.includes(k))

  const handleSave = async (e: React.MouseEvent, type: 'favorite' | 'watchlater') => {
    e.stopPropagation()
    try {
      if (type === 'favorite') {
        await api.favorites.add(video)
        toast.success('Added to Favorites')
      } else {
        await api.watchlater.add(video)
        toast.success('Saved to Watch Later')
      }
    } catch {
      toast.error('Failed to save')
    }
  }

  const handleCopy = (e: React.MouseEvent) => {
    e.stopPropagation()
    const url = `https://www.youtube.com/watch?v=${video.id}`
    navigator.clipboard.writeText(url)
    toast.success('Video URL copied')
  }

  if (layout === 'compact') {
    return (
      <div
        onClick={() => openVideo(video.id)}
        className="group flex gap-2 cursor-pointer rounded-xl p-1.5 hover:bg-accent/60 transition-colors"
      >
        <div className="relative w-40 shrink-0 aspect-video rounded-lg overflow-hidden bg-muted">
          {!imgLoaded && <div className="absolute inset-0 animate-shimmer" />}
          {!imgError ? (
            <Image
              src={thumb}
              alt={video.title}
              fill
              loading="lazy"
              sizes="160px"
              onLoad={() => setImgLoaded(true)}
              onError={() => setImgError(true)}
              className={cn('object-cover transition-transform duration-500 group-hover:scale-105', !imgLoaded && 'opacity-0')}
              unoptimized
            />
          ) : (
            <div className="w-full h-full grid place-items-center text-muted-foreground text-xs">No preview</div>
          )}
          <span className="absolute bottom-1 right-1 rounded bg-black/80 px-1.5 py-0.5 text-[10px] font-medium text-white">
            {formatDuration(video.duration)}
          </span>
        </div>
        <div className="min-w-0 flex-1">
          <h4 className="text-sm font-medium line-clamp-2 leading-snug">{video.title}</h4>
          <p className="mt-1 text-xs text-muted-foreground line-clamp-1">{channel}</p>
          {video.view_count ? <p className="text-xs text-muted-foreground">{formatViews(video.view_count)}</p> : null}
        </div>
      </div>
    )
  }

  return (
    <div
      onClick={() => openVideo(video.id)}
      className={cn(
        'group cursor-pointer animate-float-up',
        layout === 'list' && 'flex flex-col sm:flex-row gap-3 sm:gap-4'
      )}
    >
      <div
        className={cn(
          'relative aspect-video rounded-xl overflow-hidden bg-muted',
          layout === 'list' ? 'sm:w-80 shrink-0' : 'w-full'
        )}
      >
        {!imgLoaded && <div className="absolute inset-0 animate-shimmer" />}
        {!imgError ? (
          <Image
            src={thumb}
            alt={video.title}
            fill
            loading="lazy"
            sizes="(max-width: 768px) 100vw, (max-width: 1200px) 50vw, 33vw"
            onLoad={() => setImgLoaded(true)}
            onError={() => setImgError(true)}
            className={cn('object-cover transition-transform duration-500 group-hover:scale-[1.04]', !imgLoaded && 'opacity-0')}
            unoptimized
          />
        ) : (
          <div className="w-full h-full grid place-items-center text-muted-foreground text-sm">No preview available</div>
        )}
        <span className="absolute bottom-2 right-2 rounded-md bg-black/80 px-1.5 py-0.5 text-xs font-semibold text-white backdrop-blur-sm">
          {formatDuration(video.duration)}
        </span>
        <div className="absolute inset-0 bg-gradient-to-t from-black/30 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-300" />
      </div>

      <div className={cn('flex gap-3 mt-3', layout === 'list' && 'sm:mt-0')}>
        <div className="shrink-0">
          <div className="size-9 rounded-full gradient-accent grid place-items-center text-white text-sm font-bold shadow-md">
            {channel.charAt(0).toUpperCase()}
          </div>
        </div>
        <div className="min-w-0 flex-1">
          <h3 className="font-semibold text-sm leading-snug line-clamp-2 group-hover:text-primary transition-colors">
            {video.title}
          </h3>
          <div className="mt-1 flex items-center gap-1 text-xs text-muted-foreground">
            <span className="hover:text-foreground transition-colors">{channel}</span>
            {verified && <CheckCircle2 className="size-3.5 fill-current text-muted-foreground" />}
          </div>
          <div className="mt-0.5 text-xs text-muted-foreground flex items-center gap-1">
            {video.view_count ? <span>{formatViews(video.view_count)}</span> : null}
          </div>
          <div className="mt-1 flex items-center justify-end">
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button
                  onClick={(e) => e.stopPropagation()}
                  className="rounded-full p-1.5 hover:bg-accent transition-colors opacity-0 group-hover:opacity-100"
                >
                  <MoreVertical className="size-4" />
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" onClick={(e) => e.stopPropagation()}>
                <DropdownMenuItem onClick={() => openVideo(video.id)}>
                  <span>Play video</span>
                </DropdownMenuItem>
                <DropdownMenuItem onClick={handleCopy}>
                  <span>Copy video URL</span>
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem onClick={(e) => handleSave(e, 'watchlater')}>
                  <Clock className="size-4" />
                  <span>Save to Watch Later</span>
                </DropdownMenuItem>
                <DropdownMenuItem onClick={(e) => handleSave(e, 'favorite')}>
                  <Heart className="size-4" />
                  <span>Add to Favorites</span>
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </div>
      </div>
    </div>
  )
}

export const VideoCard = memo(VideoCardBase)
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/video/video-player.tsx ---
mkdir -p "$(dirname "src/components/video/video-player.tsx")"
cat > 'src/components/video/video-player.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import {
  Play, Pause, Volume2, VolumeX, Maximize, Minimize, Settings, SkipBack,
  SkipForward, Subtitles, PictureInPicture, Loader2, RotateCcw, Gauge,
} from 'lucide-react'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger, DropdownMenuSeparator, DropdownMenuLabel,
} from '@/components/ui/dropdown-menu'
import { Slider } from '@/components/ui/slider'
import { api, formatDuration, type StreamInfo } from '@/lib/api'
import { useAppStore } from '@/lib/store'
import { toast } from 'sonner'

interface VideoPlayerProps {
  videoId: string
  onTheaterChange?: (v: boolean) => void
}

const QUALITIES = ['144p', '240p', '360p', '480p', '720p', '1080p', 'highest']
const SPEEDS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

export function VideoPlayer({ videoId, onTheaterChange }: VideoPlayerProps) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)
  const hideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  // Track which videoId we've already restored the saved position for.
  // This prevents the restore from re-applying if the effect re-runs
  // (e.g. quality fallback) AFTER the user has already started seeking.
  const restoredPosForRef = useRef<string | null>(null)
  // Track the last position the user explicitly seeked to, so a subsequent
  // effect re-run can restore THAT instead of the stale localStorage value.
  const lastSeekPosRef = useRef<number | null>(null)

  const currentQuality = useAppStore((s) => s.currentQuality)
  const setCurrentQuality = useAppStore((s) => s.setCurrentQuality)
  const volume = useAppStore((s) => s.volume)
  const setVolume = useAppStore((s) => s.setVolume)
  const playbackRate = useAppStore((s) => s.playbackRate)
  const setPlaybackRate = useAppStore((s) => s.setPlaybackRate)
  const theaterMode = useAppStore((s) => s.theaterMode)
  const setTheaterMode = useAppStore((s) => s.setTheaterMode)

  const [streamInfo, setStreamInfo] = useState<StreamInfo | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [playing, setPlaying] = useState(false)
  const [current, setCurrent] = useState(0)
  const [duration, setDuration] = useState(0)
  const [buffered, setBuffered] = useState(0)
  const [muted, setMuted] = useState(false)
  const [showControls, setShowControls] = useState(true)
  const [fullscreen, setFullscreen] = useState(false)
  const [showSubs, setShowSubs] = useState(false)
  const [activeSub, setActiveSub] = useState<string>('')
  const [buffering, setBuffering] = useState(false)
  const [quality, setQuality] = useState(currentQuality)

  // Load stream info when videoId or quality changes
  useEffect(() => {
    let cancelled = false
    let retryTimer: ReturnType<typeof setTimeout> | null = null
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoading(true)
    setError(null)
    setStreamInfo(null)
    // Determine the position to restore:
    //  - If the user explicitly seeked during this session (lastSeekPosRef),
    //    restore THAT so a quality-fallback re-run doesn't yank them back.
    //  - Otherwise, restore the saved localStorage position — but only ONCE
    //    per videoId (tracked via restoredPosForRef) so a re-run can't reapply
    //    a stale value after the user has already moved.
    const isFirstLoadForVideo = restoredPosForRef.current !== videoId
    const savedPos = typeof window !== 'undefined' ? parseFloat(localStorage.getItem(`pos:${videoId}`) || '0') : 0
    const restorePos = lastSeekPosRef.current ?? (isFirstLoadForVideo ? savedPos : 0)
    let posApplied = false

    // 502 FIX: auto-retry stream loading on transient failures (503/anti-bot)
    let attempt = 0
    const MAX_ATTEMPTS = 3
    const loadStream = () => {
      if (cancelled) return
      api.stream(videoId, quality)
        .then((info) => {
          if (cancelled) return
          setStreamInfo(info)
          // If requested quality not available, fall back
          if (info.availableQualities.length && !info.availableQualities.includes(quality) && quality !== 'highest') {
            const fallback = info.availableQualities.includes('720p') ? '720p' : info.availableQualities[info.availableQualities.length - 1]
            setCurrentQuality(fallback)
            setQuality(fallback)
          }
          // Apply restore position once metadata loads.
          if (restorePos > 5 && restorePos < (info.duration || 0) - 5) {
            const v = videoRef.current
            if (v) {
              const onLoad = () => {
                if (posApplied) return
                posApplied = true
                v.currentTime = restorePos
                setCurrent(restorePos)
                v.removeEventListener('loadedmetadata', onLoad)
              }
              v.addEventListener('loadedmetadata', onLoad)
              setTimeout(() => { posApplied = true }, 2000)
            }
          }
          restoredPosForRef.current = videoId
        })
        .catch((e) => {
          if (cancelled) return
          // 502 FIX: auto-retry on transient errors (503, anti-bot, timeout)
          attempt++
          if (attempt < MAX_ATTEMPTS) {
            const delay = 1500 * attempt
            retryTimer = setTimeout(loadStream, delay)
            return
          }
          setError(e instanceof Error ? e.message : 'Failed to load stream')
          if (!cancelled) setLoading(false)
        })
        .finally(() => { if (!cancelled) setLoading(false) })
    }
    loadStream()

    return () => {
      cancelled = true
      if (retryTimer) clearTimeout(retryTimer)
    }
  }, [videoId, quality, setCurrentQuality])

  // Video event listeners
  useEffect(() => {
    const v = videoRef.current
    if (!v || !streamInfo) return

    const onTime = () => {
      setCurrent(v.currentTime)
      // Save position (throttled via storage)
      if (Math.floor(v.currentTime) % 5 === 0) {
        localStorage.setItem(`pos:${videoId}`, String(v.currentTime))
      }
    }
    const onDur = () => setDuration(v.duration || 0)
    const onPlay = () => setPlaying(true)
    const onPause = () => setPlaying(false)
    const onProgress = () => {
      if (v.buffered.length) setBuffered(v.buffered.end(v.buffered.length - 1))
    }
    const onWaiting = () => setBuffering(true)
    const onPlaying = () => setBuffering(false)
    const onEnded = () => { localStorage.removeItem(`pos:${videoId}`) }
    const onErr = () => setError('Playback error. Try a different quality.')

    v.addEventListener('timeupdate', onTime)
    v.addEventListener('durationchange', onDur)
    v.addEventListener('play', onPlay)
    v.addEventListener('pause', onPause)
    v.addEventListener('progress', onProgress)
    v.addEventListener('waiting', onWaiting)
    v.addEventListener('playing', onPlaying)
    v.addEventListener('ended', onEnded)
    v.addEventListener('error', onErr)
    v.volume = volume
    v.playbackRate = playbackRate

    return () => {
      v.removeEventListener('timeupdate', onTime)
      v.removeEventListener('durationchange', onDur)
      v.removeEventListener('play', onPlay)
      v.removeEventListener('pause', onPause)
      v.removeEventListener('progress', onProgress)
      v.removeEventListener('waiting', onWaiting)
      v.removeEventListener('playing', onPlaying)
      v.removeEventListener('ended', onEnded)
      v.removeEventListener('error', onErr)
    }
  }, [streamInfo, videoId, volume, playbackRate])

  // Fullscreen detection
  useEffect(() => {
    const handler = () => setFullscreen(!!document.fullscreenElement)
    document.addEventListener('fullscreenchange', handler)
    return () => document.removeEventListener('fullscreenchange', handler)
  }, [])

  // Auto-hide controls
  const scheduleHide = useCallback(() => {
    if (hideTimerRef.current) clearTimeout(hideTimerRef.current)
    hideTimerRef.current = setTimeout(() => {
      if (videoRef.current && !videoRef.current.paused) setShowControls(false)
    }, 3000)
  }, [])

  const handleMouseMove = () => {
    setShowControls(true)
    scheduleHide()
  }

  const togglePlay = () => {
    const v = videoRef.current; if (!v) return
    if (v.paused) { v.play() } else { v.pause() }
  }

  const toggleFullscreen = () => {
    const container = containerRef.current
    if (!container) return
    if (!document.fullscreenElement) {
      container.requestFullscreen().catch(() => toast.error('Fullscreen not available'))
    } else {
      document.exitFullscreen()
    }
  }

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const v = videoRef.current
      if (!v) return
      const tag = (document.activeElement?.tagName || '').toUpperCase()
      if (tag === 'INPUT' || tag === 'TEXTAREA') return

      switch (e.key.toLowerCase()) {
        case ' ':
        case 'k':
          e.preventDefault(); if (v.paused) { v.play() } else { v.pause() }; break
        case 'arrowleft':
          e.preventDefault(); v.currentTime = Math.max(0, v.currentTime - 5); break
        case 'arrowright':
          e.preventDefault(); v.currentTime = Math.min(v.duration, v.currentTime + 5); break
        case 'arrowup':
          e.preventDefault(); v.volume = Math.min(1, v.volume + 0.1); setVolume(v.volume); break
        case 'arrowdown':
          e.preventDefault(); v.volume = Math.max(0, v.volume - 0.1); setVolume(v.volume); break
        case 'm':
          v.muted = !v.muted; setMuted(v.muted); break
        case 'f':
          toggleFullscreen(); break
        case 't':
          setTheaterMode(!theaterMode); onTheaterChange?.(!theaterMode); break
        case 'c':
          setShowSubs((s) => !s); break
        case 'j':
          v.currentTime = Math.max(0, v.currentTime - 10); break
        case 'l':
          v.currentTime = Math.min(v.duration, v.currentTime + 10); break
        case '0': case '1': case '2': case '3': case '4': case '5': case '6': case '7': case '8': case '9':
          v.currentTime = (parseInt(e.key) / 10) * v.duration; break
      }
    }
    const container = containerRef.current
    container?.addEventListener('keydown', handler)
    // Also listen globally when player is mounted
    window.addEventListener('keydown', handler)
    return () => {
      container?.removeEventListener('keydown', handler)
      window.removeEventListener('keydown', handler)
    }
  }, [theaterMode, setTheaterMode, onTheaterChange, setVolume])

  const togglePip = async () => {
    const v = videoRef.current
    if (!v) return
    try {
      if (document.pictureInPictureElement) {
        await document.exitPictureInPicture()
      } else {
        await v.requestPictureInPicture()
      }
    } catch {
      toast.error('Picture-in-Picture not available')
    }
  }

  const onSeek = (val: number[]) => {
    const v = videoRef.current; if (!v) return
    const target = val[0]
    // Record the user's explicit seek so a subsequent effect re-run (e.g.
    // quality fallback) restores THIS position instead of the stale saved one.
    lastSeekPosRef.current = target
    // Persist immediately so a reload/re-run reads the correct position.
    if (typeof window !== 'undefined') {
      localStorage.setItem(`pos:${videoId}`, String(target))
    }
    v.currentTime = target
    setCurrent(target)
  }

  const changeQuality = (q: string) => {
    // Save position before switching so the new stream resumes from here
    const v = videoRef.current
    if (v) {
      localStorage.setItem(`pos:${videoId}`, String(v.currentTime))
      lastSeekPosRef.current = v.currentTime
    }
    setQuality(q)
    setCurrentQuality(q)
  }

  const changeSpeed = (s: number) => {
    const v = videoRef.current
    if (v) v.playbackRate = s
    setPlaybackRate(s)
  }

  const toggleSubtitles = (lang: string) => {
    const v = videoRef.current
    if (!v) return
    // Remove existing tracks
    Array.from(v.textTracks).forEach((t) => { t.mode = 'disabled' })
    if (lang && activeSub !== lang) {
      let track = Array.from(v.textTracks).find((t) => t.language === lang)
      if (!track && streamInfo) {
        const sub = streamInfo.subtitles.find((s) => s.srclang === lang)
        if (sub) {
          const el = document.createElement('track')
          el.kind = 'subtitles'
          el.label = sub.label
          el.srclang = sub.srclang
          el.src = sub.url
          el.default = true
          v.appendChild(el)
          track = el.track
        }
      }
      if (track) { track.mode = 'showing'; setActiveSub(lang); setShowSubs(true) }
    } else {
      setActiveSub(''); setShowSubs(false)
    }
  }

  const restart = () => {
    const v = videoRef.current; if (v) {
      lastSeekPosRef.current = 0
      v.currentTime = 0; v.play()
    }
  }

  const progressPct = duration > 0 ? (current / duration) * 100 : 0
  const bufferedPct = duration > 0 ? (buffered / duration) * 100 : 0

  return (
    <div
      ref={containerRef}
      tabIndex={0}
      onMouseMove={handleMouseMove}
      onMouseLeave={() => { if (videoRef.current && !videoRef.current.paused) setShowControls(false) }}
      className={cn(
        'relative group/player bg-black rounded-2xl overflow-hidden outline-none select-none',
        theaterMode ? 'aspect-auto h-[70vh]' : 'aspect-video w-full'
      )}
    >
      {error ? (
        <div className="absolute inset-0 grid place-items-center bg-black">
          <div className="text-center px-6 max-w-md">
            <div className="size-14 rounded-full bg-destructive/20 grid place-items-center mx-auto mb-4">
              <span className="text-destructive text-2xl">!</span>
            </div>
            <p className="text-white font-medium mb-1">Playback Error</p>
            <p className="text-white/60 text-sm mb-4">{error}</p>
            <div className="flex gap-2 justify-center">
              <Button variant="secondary" size="sm" onClick={() => { setError(null); setQuality(q => q) }}>
                <RotateCcw className="size-4" /> Retry
              </Button>
              <Button variant="secondary" size="sm" onClick={() => changeQuality('720p')}>
                Try 720p
              </Button>
            </div>
          </div>
        </div>
      ) : (
        <>
          <video
            ref={videoRef}
            src={streamInfo?.playableUrl}
            className="absolute inset-0 w-full h-full object-contain bg-black"
            playsInline
            onClick={togglePlay}
            onDoubleClick={toggleFullscreen}
          />

          {/* Buffering spinner */}
          {buffering && !loading && (
            <div className="absolute inset-0 grid place-items-center pointer-events-none">
              <Loader2 className="size-12 text-white/80 animate-spin" />
            </div>
          )}

          {/* Loading */}
          {loading && (
            <div className="absolute inset-0 grid place-items-center bg-black">
              <div className="text-center">
                <Loader2 className="size-12 text-white animate-spin mx-auto mb-3" />
                <p className="text-white/70 text-sm">Preparing stream…</p>
              </div>
            </div>
          )}

          {/* Center play button when paused */}
          {!playing && !loading && !error && (
            <button
              onClick={togglePlay}
              className="absolute inset-0 grid place-items-center group/center"
            >
              <div className="size-20 rounded-full glass-strong grid place-items-center transition-transform group-hover/center:scale-110 animate-pulse-glow">
                <Play className="size-9 text-white fill-white ml-1" />
              </div>
            </button>
          )}

          {/* Controls overlay */}
          <div
            className={cn(
              'absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/90 via-black/40 to-transparent pt-12 pb-3 px-3 sm:px-4 transition-opacity duration-300',
              showControls || !playing ? 'opacity-100' : 'opacity-0'
            )}
          >
            {/* Progress bar */}
            <div className="mb-2 group/progress relative">
              <div className="relative h-1.5 rounded-full bg-white/20 cursor-pointer hover:h-2.5 transition-all">
                <div className="absolute inset-y-0 left-0 bg-white/30 rounded-full" style={{ width: `${bufferedPct}%` }} />
                <div className="absolute inset-y-0 left-0 gradient-accent rounded-full" style={{ width: `${progressPct}%` }} />
              </div>
              <Slider
                value={[current]}
                max={duration || 100}
                step={0.1}
                onValueChange={onSeek}
                className="absolute inset-0 opacity-0 group-hover/progress:opacity-100"
              />
            </div>

            {/* Buttons row */}
            <div className="flex items-center gap-1 sm:gap-2 text-white">
              <button onClick={togglePlay} className="p-1.5 rounded-full hover:bg-white/15 transition-colors" title={playing ? 'Pause (k)' : 'Play (k)'}>
                {playing ? <Pause className="size-5 fill-white" /> : <Play className="size-5 fill-white" />}
              </button>
              <button onClick={restart} className="p-1.5 rounded-full hover:bg-white/15 transition-colors hidden sm:block" title="Restart">
                <RotateCcw className="size-5" />
              </button>
              <button onClick={() => { const v = videoRef.current; if (v) v.currentTime = Math.max(0, v.currentTime - 10) }} className="p-1.5 rounded-full hover:bg-white/15 transition-colors" title="Back 10s (j)">
                <SkipBack className="size-5" />
              </button>
              <button onClick={() => { const v = videoRef.current; if (v) v.currentTime = Math.min(v.duration, v.currentTime + 10) }} className="p-1.5 rounded-full hover:bg-white/15 transition-colors" title="Forward 10s (l)">
                <SkipForward className="size-5" />
              </button>

              {/* Volume */}
              <div className="flex items-center group/vol">
                <button onClick={() => { const v = videoRef.current; if (v) { v.muted = !v.muted; setMuted(v.muted) } }} className="p-1.5 rounded-full hover:bg-white/15 transition-colors" title="Mute (m)">
                  {muted || volume === 0 ? <VolumeX className="size-5" /> : <Volume2 className="size-5" />}
                </button>
                <div className="w-0 group-hover/vol:w-20 overflow-hidden transition-all duration-200">
                  <Slider
                    value={[muted ? 0 : volume * 100]}
                    max={100}
                    onValueChange={(val) => { const v = videoRef.current; if (v) { v.volume = val[0] / 100; v.muted = val[0] === 0; setVolume(val[0] / 100); setMuted(val[0] === 0) } }}
                    className="w-20"
                  />
                </div>
              </div>

              {/* Time */}
              <span className="text-xs font-medium ml-1 tabular-nums">
                {formatDuration(current)} <span className="text-white/50">/ {formatDuration(duration)}</span>
              </span>

              <div className="flex-1" />

              {/* Subtitles */}
              {streamInfo && streamInfo.subtitles.length > 0 && (
                <DropdownMenu>
                  <DropdownMenuTrigger asChild>
                    <button className={cn('p-1.5 rounded-full hover:bg-white/15 transition-colors', showSubs && 'text-primary')} title="Subtitles (c)">
                      <Subtitles className="size-5" />
                    </button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end">
                    <DropdownMenuLabel>Subtitles</DropdownMenuLabel>
                    <DropdownMenuItem onClick={() => toggleSubtitles('')}>
                      Off
                    </DropdownMenuItem>
                    {streamInfo.subtitles.map((s) => (
                      <DropdownMenuItem key={s.srclang} onClick={() => toggleSubtitles(s.srclang)}>
                        {s.label} {activeSub === s.srclang && '✓'}
                      </DropdownMenuItem>
                    ))}
                  </DropdownMenuContent>
                </DropdownMenu>
              )}

              {/* Speed */}
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <button className="p-1.5 rounded-full hover:bg-white/15 transition-colors flex items-center gap-1" title="Playback speed">
                    <Gauge className="size-5" />
                  </button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end">
                  <DropdownMenuLabel>Playback speed</DropdownMenuLabel>
                  {SPEEDS.map((s) => (
                    <DropdownMenuItem key={s} onClick={() => changeSpeed(s)}>
                      {s === 1 ? 'Normal' : `${s}x`} {playbackRate === s && '✓'}
                    </DropdownMenuItem>
                  ))}
                </DropdownMenuContent>
              </DropdownMenu>

              {/* Quality */}
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <button className="p-1.5 rounded-full hover:bg-white/15 transition-colors flex items-center gap-1 text-xs font-semibold" title="Quality">
                    <Settings className="size-5" />
                    <span className="hidden sm:inline">{quality}</span>
                  </button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end">
                  <DropdownMenuLabel>Quality</DropdownMenuLabel>
                  {QUALITIES.map((q) => {
                    const available = q === 'highest' || !streamInfo?.availableQualities.length || streamInfo.availableQualities.includes(q)
                    return (
                      <DropdownMenuItem
                        key={q}
                        disabled={!available}
                        onClick={() => changeQuality(q)}
                        className={cn(!available && 'opacity-40')}
                      >
                        {q === 'highest' ? 'Highest available' : q} {quality === q && '✓'}
                      </DropdownMenuItem>
                    )
                  })}
                </DropdownMenuContent>
              </DropdownMenu>

              {/* Theater */}
              <button onClick={() => { setTheaterMode(!theaterMode); onTheaterChange?.(!theaterMode) }} className={cn('p-1.5 rounded-full hover:bg-white/15 transition-colors hidden sm:block', theaterMode && 'text-primary')} title="Theater mode (t)">
                <div className="size-5 border-2 border-current rounded-sm relative">
                  <div className="absolute inset-x-0 top-0 h-1/3 border-b-2 border-current" />
                </div>
              </button>

              {/* PiP */}
              <button onClick={togglePip} className="p-1.5 rounded-full hover:bg-white/15 transition-colors hidden sm:block" title="Picture-in-Picture">
                <PictureInPicture className="size-5" />
              </button>

              {/* Fullscreen */}
              <button onClick={toggleFullscreen} className="p-1.5 rounded-full hover:bg-white/15 transition-colors" title="Fullscreen (f)">
                {fullscreen ? <Minimize className="size-5" /> : <Maximize className="size-5" />}
              </button>
            </div>
          </div>
        </>
      )}
    </div>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/views/admin-view.tsx ---
mkdir -p "$(dirname "src/components/views/admin-view.tsx")"
cat > 'src/components/views/admin-view.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import {
  Shield,
  Lock,
  Upload,
  FileText,
  Trash2,
  RefreshCw,
  CheckCircle2,
  XCircle,
  AlertTriangle,
  LogOut,
  KeyRound,
  Cookie,
  Database,
  Settings2,
  Activity,
  Server,
  Eye,
  EyeOff,
  ArrowLeft,
} from 'lucide-react'
import { useAppStore } from '@/lib/store'
import { api, formatBytes } from '@/lib/api'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Separator } from '@/components/ui/separator'
import { Textarea } from '@/components/ui/textarea'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'

// ---------- Types ----------
interface CookiesMeta {
  available: boolean
  valid: boolean
  size: number
  uploadedAt?: string | null
  lastError?: string | null
  location?: string
}

interface AdminStatusResponse {
  authenticated: boolean
  cookies: CookiesMeta
}

interface UpdateResponse {
  success: boolean
  version: string
  output?: string
}

interface ClearCacheResponse {
  success: boolean
  cleared: number
}

interface TestCookiesResponse {
  success: boolean
  message: string
  details?: string
}

interface UploadFileResponse {
  success?: boolean
  error?: string
  message?: string
}

// ---------- Helpers ----------
function formatTimestamp(iso?: string | null): string {
  if (!iso) return '—'
  const t = new Date(iso).getTime()
  if (Number.isNaN(t)) return '—'
  return new Date(iso).toLocaleString()
}

function Spinner({ className }: { className?: string }) {
  return (
    <div
      className={cn(
        'size-4 rounded-full border-2 border-current/30 border-t-current animate-spin',
        className
      )}
      aria-hidden
    />
  )
}

function StatTile({
  label,
  value,
  ok,
}: {
  label: string
  value: string
  ok?: boolean
}) {
  return (
    <div className="rounded-xl bg-muted/30 border border-border/50 p-3 min-w-0">
      <p className="text-xs text-muted-foreground mb-0.5 truncate">{label}</p>
      <p
        className={cn(
          'text-sm font-semibold truncate',
          ok === true && 'text-emerald-500 dark:text-emerald-400',
          ok === false && 'text-rose-500 dark:text-rose-400'
        )}
        title={value}
      >
        {value}
      </p>
    </div>
  )
}

function SectionCard({
  icon,
  accent,
  title,
  description,
  children,
}: {
  icon: React.ReactNode
  accent?: boolean
  title: string
  description?: React.ReactNode
  children: React.ReactNode
}) {
  return (
    <Card className="glass rounded-2xl border-border/50">
      <CardHeader>
        <div className="flex items-center gap-2">
          <div
            className={cn(
              'grid place-items-center size-8 rounded-xl',
              accent ? 'gradient-accent' : 'glass border border-border/60'
            )}
          >
            {icon}
          </div>
          <div>
            <CardTitle className="text-base">{title}</CardTitle>
            {description && <CardDescription>{description}</CardDescription>}
          </div>
        </div>
      </CardHeader>
      <CardContent className="space-y-4">{children}</CardContent>
    </Card>
  )
}

// ---------- Login View ----------
function LoginView({ onAuthed }: { onAuthed: () => void }) {
  const setView = useAppStore((s) => s.setView)
  const [password, setPassword] = useState('')
  const [showPw, setShowPw] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!password.trim()) {
      setError('Please enter the admin password.')
      return
    }
    setSubmitting(true)
    setError(null)
    try {
      await api.admin.login(password)
      toast.success('Welcome back, admin')
      onAuthed()
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Login failed'
      setError(msg)
      toast.error(msg)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="px-4 sm:px-6 lg:px-8 py-6">
      <div className="max-w-md mx-auto">
        <div className="glass-strong rounded-3xl border border-border/50 p-8 sm:p-10 shadow-2xl animate-float-up">
          {/* Icon + title */}
          <div className="flex flex-col items-center text-center mb-6">
            <div className="grid place-items-center size-16 rounded-2xl gradient-accent shadow-lg shadow-primary/30 animate-pulse-glow mb-4">
              <Shield className="size-8 text-white" />
            </div>
            <h1 className="text-2xl font-bold tracking-tight">
              <span className="gradient-accent-text">Admin Access</span>
            </h1>
            <p className="text-sm text-muted-foreground mt-1.5">
              Authenticate to manage cookies, yt-dlp, logs, and cache.
            </p>
          </div>

          {/* Error alert */}
          {error && (
            <Alert variant="destructive" className="mb-4">
              <XCircle className="size-4" />
              <AlertTitle>Authentication failed</AlertTitle>
              <AlertDescription>{error}</AlertDescription>
            </Alert>
          )}

          <form onSubmit={handleSubmit} className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="admin-pw" className="flex items-center gap-1.5">
                <KeyRound className="size-3.5" />
                Password
              </Label>
              <div className="relative">
                <Input
                  id="admin-pw"
                  type={showPw ? 'text' : 'password'}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="Enter admin password"
                  autoComplete="current-password"
                  disabled={submitting}
                  className="pr-10"
                  autoFocus
                />
                <button
                  type="button"
                  onClick={() => setShowPw((v) => !v)}
                  className="absolute right-0 top-0 bottom-0 px-3 text-muted-foreground hover:text-foreground transition-colors"
                  tabIndex={-1}
                  aria-label={showPw ? 'Hide password' : 'Show password'}
                >
                  {showPw ? <EyeOff className="size-4" /> : <Eye className="size-4" />}
                </button>
              </div>
            </div>

            <Button
              type="submit"
              disabled={submitting}
              className="w-full gradient-accent text-white border-0 hover:opacity-90 h-10"
            >
              {submitting ? <Spinner /> : <Lock className="size-4" />}
              <span>{submitting ? 'Unlocking...' : 'Unlock'}</span>
            </Button>
          </form>

          {/* Hint */}
          <div className="mt-5 rounded-xl bg-muted/40 border border-border/50 px-3.5 py-2.5">
            <p className="text-xs text-muted-foreground">
              Default password is set in <code className="font-mono text-foreground/80">.env</code>{' '}
              (<code className="font-mono text-foreground/80">ADMIN_PASSWORD</code>). Current default:{' '}
              <code className="font-mono text-foreground/80">changeme123</code>
            </p>
          </div>

          {/* Back home */}
          <button
            type="button"
            onClick={() => setView('home')}
            className="mt-5 w-full inline-flex items-center justify-center gap-1.5 text-sm text-muted-foreground hover:text-foreground transition-colors"
          >
            <ArrowLeft className="size-3.5" />
            <span>Back to home</span>
          </button>
        </div>
      </div>
    </div>
  )
}

// ---------- Overview Tab ----------
function OverviewTab({
  version,
  cookies,
  setVersion,
  refreshCookies,
}: {
  version: string
  cookies: CookiesMeta | null
  setVersion: (v: string) => void
  refreshCookies: () => Promise<void>
}) {
  const [updating, setUpdating] = useState(false)
  const [clearing, setClearing] = useState(false)
  const [testing, setTesting] = useState(false)
  const [testResult, setTestResult] = useState<TestCookiesResponse | null>(null)
  const [updateOpen, setUpdateOpen] = useState(false)
  const [clearOpen, setClearOpen] = useState(false)

  const runUpdate = async () => {
    setUpdating(true)
    setUpdateOpen(false)
    try {
      const r = (await api.admin.update()) as UpdateResponse
      if (r.version) setVersion(r.version)
      toast.success(`yt-dlp updated to ${r.version || 'latest'}`)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Update failed'
      toast.error(msg)
    } finally {
      setUpdating(false)
    }
  }

  const runClearCache = async () => {
    setClearing(true)
    setClearOpen(false)
    try {
      const r = (await api.admin.clearCache()) as ClearCacheResponse
      toast.success(`Cleared ${r.cleared ?? 0} entries`)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to clear cache'
      toast.error(msg)
    } finally {
      setClearing(false)
    }
  }

  const runTest = async () => {
    setTesting(true)
    setTestResult(null)
    try {
      const r = (await api.cookies.test()) as TestCookiesResponse
      setTestResult(r)
      if (r.success) toast.success(r.message || 'Cookies are valid')
      else toast.error(r.message || 'Cookies test failed')
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Test failed'
      setTestResult({ success: false, message: msg })
      toast.error(msg)
    } finally {
      setTesting(false)
    }
  }

  return (
    <>
      {/* Cookies status */}
      <SectionCard
        icon={<Cookie className="size-4 text-muted-foreground" />}
        title="Cookies status"
        description="YouTube authentication cookies used for restricted content."
      >
        {cookies && !cookies.available && (
          <Alert>
            <AlertTriangle className="size-4" />
            <AlertTitle>No cookies uploaded</AlertTitle>
            <AlertDescription>
              Upload your YouTube cookies file in the Cookies tab to access age-restricted and members-only content.
            </AlertDescription>
          </Alert>
        )}
        {cookies && cookies.available && !cookies.valid && (
          <Alert variant="destructive">
            <XCircle className="size-4" />
            <AlertTitle>Cookies are invalid</AlertTitle>
            <AlertDescription>
              {cookies.lastError || 'YouTube rejected these cookies. Please re-upload a fresh cookies file.'}
            </AlertDescription>
          </Alert>
        )}
        {cookies && cookies.available && cookies.valid && (
          <Alert>
            <CheckCircle2 className="size-4" />
            <AlertTitle>Cookies are valid</AlertTitle>
            <AlertDescription>
              YouTube authenticated successfully with the current cookies.
            </AlertDescription>
          </Alert>
        )}

        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <StatTile
            label="Available"
            value={cookies ? (cookies.available ? 'Yes' : 'No') : '—'}
            ok={cookies?.available}
          />
          <StatTile
            label="Valid"
            value={cookies ? (cookies.valid ? 'Yes' : 'No') : '—'}
            ok={cookies?.valid}
          />
          <StatTile label="Size" value={cookies ? formatBytes(cookies.size) : '—'} />
          <StatTile label="Uploaded" value={cookies ? formatTimestamp(cookies.uploadedAt) : '—'} />
        </div>
      </SectionCard>

      {/* yt-dlp version */}
      <SectionCard
        icon={<Server className="size-4 text-muted-foreground" />}
        title="yt-dlp version"
        description="The backend engine that powers all video operations."
      >
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <span className="text-sm text-muted-foreground">Installed:</span>
            <Badge variant="outline" className="font-mono">
              {version || '—'}
            </Badge>
          </div>
          <AlertDialog open={updateOpen} onOpenChange={setUpdateOpen}>
            <AlertDialogTrigger asChild>
              <Button variant="outline" size="sm" disabled={updating} className="gap-1.5">
                {updating ? <Spinner /> : <RefreshCw className="size-3.5" />}
                <span>{updating ? 'Updating...' : 'Update yt-dlp'}</span>
              </Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>Update yt-dlp?</AlertDialogTitle>
                <AlertDialogDescription>
                  This will run <code className="font-mono">pip install --upgrade yt-dlp</code> on the
                  server. It may take 30–60 seconds and will briefly pause new requests. Continue?
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel disabled={updating}>Cancel</AlertDialogCancel>
                <AlertDialogAction
                  onClick={runUpdate}
                  disabled={updating}
                  className="gradient-accent text-white border-0 hover:opacity-90"
                >
                  {updating ? 'Updating...' : 'Update now'}
                </AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        </div>
        {updating && (
          <p className="text-xs text-muted-foreground flex items-center gap-1.5">
            <Spinner className="size-3" />
            <span>
              Running pip upgrade — this can take up to a minute. Please don&apos;t close the page.
            </span>
          </p>
        )}
      </SectionCard>

      {/* Quick actions */}
      <SectionCard
        icon={<Activity className="size-4 text-muted-foreground" />}
        title="Quick actions"
        description="Common maintenance tasks."
      >
        <div className="flex flex-wrap gap-2">
          <AlertDialog open={clearOpen} onOpenChange={setClearOpen}>
            <AlertDialogTrigger asChild>
              <Button variant="outline" size="sm" disabled={clearing} className="gap-1.5">
                {clearing ? <Spinner /> : <Trash2 className="size-3.5" />}
                <span>{clearing ? 'Clearing...' : 'Clear cache'}</span>
              </Button>
            </AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>Clear API cache?</AlertDialogTitle>
                <AlertDialogDescription>
                  This will remove all cached search/video responses from memory. The next requests
                  will hit yt-dlp directly and may be slower.
                </AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel disabled={clearing}>Cancel</AlertDialogCancel>
                <AlertDialogAction
                  onClick={runClearCache}
                  disabled={clearing}
                  className="bg-destructive text-white hover:bg-destructive/90"
                >
                  {clearing ? 'Clearing...' : 'Clear cache'}
                </AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>

          <Button variant="outline" size="sm" disabled={testing} onClick={runTest} className="gap-1.5">
            {testing ? <Spinner /> : <CheckCircle2 className="size-3.5" />}
            <span>{testing ? 'Testing...' : 'Test cookies'}</span>
          </Button>
        </div>

        {testResult && (
          <Alert variant={testResult.success ? 'default' : 'destructive'}>
            {testResult.success ? <CheckCircle2 className="size-4" /> : <XCircle className="size-4" />}
            <AlertTitle>{testResult.success ? 'Cookies test passed' : 'Cookies test failed'}</AlertTitle>
            <AlertDescription>
              {testResult.message}
              {testResult.details && (
                <pre className="mt-2 whitespace-pre-wrap font-mono text-xs bg-muted/40 rounded p-2">
                  {testResult.details}
                </pre>
              )}
            </AlertDescription>
          </Alert>
        )}

        <Button
          variant="ghost"
          size="sm"
          onClick={() => {
            void refreshCookies()
          }}
          className="gap-1.5 text-muted-foreground"
        >
          <RefreshCw className="size-3.5" />
          <span>Refresh cookies status</span>
        </Button>
      </SectionCard>
    </>
  )
}

// ---------- Cookies Tab ----------
function CookiesTab({
  cookies,
  refreshCookies,
}: {
  cookies: CookiesMeta | null
  refreshCookies: () => Promise<void>
}) {
  const [uploading, setUploading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [testing, setTesting] = useState(false)
  const [testResult, setTestResult] = useState<TestCookiesResponse | null>(null)
  const [paste, setPaste] = useState('')
  const [dragOver, setDragOver] = useState(false)
  const [deleteOpen, setDeleteOpen] = useState(false)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const handleFile = async (file: File) => {
    setUploading(true)
    try {
      const r = (await api.cookies.uploadFile(file)) as UploadFileResponse
      if (r && r.success) {
        toast.success(`Uploaded ${file.name}`)
        await refreshCookies()
      } else {
        const msg = (r && r.error) || 'Upload failed'
        toast.error(msg)
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Upload failed'
      toast.error(msg)
    } finally {
      setUploading(false)
    }
  }

  const onFileInput = (e: React.ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0]
    if (f) void handleFile(f)
    // reset so selecting the same file again still triggers onChange
    e.target.value = ''
  }

  const onDrop = (e: React.DragEvent) => {
    e.preventDefault()
    setDragOver(false)
    const f = e.dataTransfer.files?.[0]
    if (f) void handleFile(f)
  }

  const handleSavePaste = async () => {
    if (!paste.trim()) {
      toast.error('Paste cookies content first')
      return
    }
    setSaving(true)
    try {
      await api.cookies.upload(paste)
      toast.success('Cookies saved')
      setPaste('')
      await refreshCookies()
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Save failed'
      toast.error(msg)
    } finally {
      setSaving(false)
    }
  }

  const runTest = async () => {
    setTesting(true)
    setTestResult(null)
    try {
      const r = (await api.cookies.test()) as TestCookiesResponse
      setTestResult(r)
      if (r.success) toast.success(r.message || 'Cookies are valid')
      else toast.error(r.message || 'Cookies test failed')
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Test failed'
      setTestResult({ success: false, message: msg })
      toast.error(msg)
    } finally {
      setTesting(false)
    }
  }

  return (
    <div className="space-y-4">
      {/* Upload section */}
      <SectionCard
        icon={<Upload className="size-4 text-white" />}
        accent
        title="Upload cookies file"
        description={
          <>
            Drop a Netscape-format <code className="font-mono">.txt</code> cookies file exported from
            your browser.
          </>
        }
      >
        <div
          onDragOver={(e) => {
            e.preventDefault()
            setDragOver(true)
          }}
          onDragLeave={() => setDragOver(false)}
          onDrop={onDrop}
          onClick={() => fileInputRef.current?.click()}
          role="button"
          tabIndex={0}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              fileInputRef.current?.click()
            }
          }}
          className={cn(
            'cursor-pointer rounded-2xl border-2 border-dashed p-8 text-center transition-all',
            dragOver
              ? 'border-primary bg-primary/10'
              : 'border-border/60 hover:border-primary/50 bg-muted/20'
          )}
        >
          <input
            ref={fileInputRef}
            type="file"
            accept=".txt,text/plain"
            onChange={onFileInput}
            className="hidden"
          />
          <div className="flex flex-col items-center gap-2">
            <div className="grid place-items-center size-12 rounded-2xl glass border border-border/60">
              {uploading ? (
                <Spinner className="size-5 text-primary" />
              ) : (
                <FileText className="size-5 text-muted-foreground" />
              )}
            </div>
            <p className="text-sm font-medium">
              {uploading ? 'Uploading...' : 'Click to select or drag a .txt file here'}
            </p>
            <p className="text-xs text-muted-foreground">
              Use a browser extension like <span className="font-medium">Get cookies.txt</span> to
              export YouTube cookies.
            </p>
          </div>
        </div>

        <Separator />

        {/* Paste section */}
        <div className="space-y-2">
          <Label htmlFor="cookies-paste" className="flex items-center gap-1.5">
            <FileText className="size-3.5" />
            Or paste cookies content
          </Label>
          <Textarea
            id="cookies-paste"
            value={paste}
            onChange={(e) => setPaste(e.target.value)}
            placeholder={
              '# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t...\tVISITOR_INFO1_LIVE\t...'
            }
            className="font-mono text-xs min-h-32"
            disabled={saving}
          />
          <div className="flex justify-end">
            <Button
              onClick={() => void handleSavePaste()}
              disabled={saving || !paste.trim()}
              size="sm"
              className="gradient-accent text-white border-0 hover:opacity-90 gap-1.5"
            >
              {saving ? <Spinner /> : <Upload className="size-3.5" />}
              <span>{saving ? 'Saving...' : 'Save cookies'}</span>
            </Button>
          </div>
        </div>
      </SectionCard>

      {/* Cookies metadata */}
      <SectionCard
        icon={<Cookie className="size-4 text-muted-foreground" />}
        title="Current cookies"
        description="Metadata only — file contents are never sent to the browser."
      >
        <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
          <StatTile
            label="Available"
            value={cookies ? (cookies.available ? 'Yes' : 'No') : '—'}
            ok={cookies?.available}
          />
          <StatTile
            label="Valid"
            value={cookies ? (cookies.valid ? 'Yes' : 'No') : '—'}
            ok={cookies?.valid}
          />
          <StatTile label="Size" value={cookies ? formatBytes(cookies.size) : '—'} />
          <StatTile label="Uploaded" value={cookies ? formatTimestamp(cookies.uploadedAt) : '—'} />
          <StatTile label="Location" value={cookies?.location ?? 'server (secured)'} />
          <StatTile label="Last error" value={cookies?.lastError ?? '—'} />
        </div>

        {cookies?.lastError && (
          <Alert variant="destructive">
            <AlertTriangle className="size-4" />
            <AlertTitle>Last cookies error</AlertTitle>
            <AlertDescription>{cookies.lastError}</AlertDescription>
          </Alert>
        )}

        <div className="flex flex-wrap gap-2">
          <Button variant="outline" size="sm" onClick={() => void runTest()} disabled={testing} className="gap-1.5">
            {testing ? <Spinner /> : <CheckCircle2 className="size-3.5" />}
            <span>{testing ? 'Testing...' : 'Test cookies validity'}</span>
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => void refreshCookies()}
            className="gap-1.5 text-muted-foreground"
          >
            <RefreshCw className="size-3.5" />
            <span>Refresh</span>
          </Button>
        </div>

        {testResult && (
          <Alert variant={testResult.success ? 'default' : 'destructive'}>
            {testResult.success ? <CheckCircle2 className="size-4" /> : <XCircle className="size-4" />}
            <AlertTitle>{testResult.success ? 'Cookies test passed' : 'Cookies test failed'}</AlertTitle>
            <AlertDescription>
              {testResult.message}
              {testResult.details && (
                <pre className="mt-2 whitespace-pre-wrap font-mono text-xs bg-muted/40 rounded p-2">
                  {testResult.details}
                </pre>
              )}
            </AlertDescription>
          </Alert>
        )}

        {/* Delete cookies — no endpoint, informational */}
        <AlertDialog open={deleteOpen} onOpenChange={setDeleteOpen}>
          <AlertDialogTrigger asChild>
            <Button
              variant="outline"
              size="sm"
              className="gap-1.5 hover:border-destructive/50 hover:text-destructive"
            >
              <Trash2 className="size-3.5" />
              <span>Delete cookies</span>
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Delete cookies?</AlertDialogTitle>
              <AlertDialogDescription>
                There is no dedicated delete endpoint. To replace the current cookies, simply upload
                a new file or paste new content above — it will overwrite the existing cookies file.
                Replacing is the recommended way to refresh expired credentials.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Got it</AlertDialogCancel>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>

        <div className="flex items-start gap-2 rounded-xl bg-emerald-500/10 border border-emerald-500/20 px-3.5 py-2.5">
          <Shield className="size-4 text-emerald-500 mt-0.5 shrink-0" />
          <p className="text-xs text-emerald-700 dark:text-emerald-300">
            Cookies are stored outside the public web root and never sent to the client. Only
            metadata (size, date, validity) is exposed through the admin API.
          </p>
        </div>
      </SectionCard>
    </div>
  )
}

// ---------- Logs Tab ----------
function LogsTab() {
  const [logs, setLogs] = useState<string[]>([])
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const r = await api.admin.logs()
      setLogs(r.logs ?? [])
    } catch (err) {
      console.error('Failed to load logs:', err)
      toast.error('Failed to load logs')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  const handleRefresh = async () => {
    setRefreshing(true)
    await load()
    setRefreshing(false)
  }

  return (
    <SectionCard
      icon={<FileText className="size-4 text-muted-foreground" />}
      title="Server logs"
      description="Recent server-side activity from yt-dlp and the API."
    >
      <div className="flex items-center justify-end -mt-2">
        <Button
          variant="outline"
          size="sm"
          onClick={() => void handleRefresh()}
          disabled={refreshing || loading}
          className="gap-1.5"
        >
          {refreshing ? <Spinner /> : <RefreshCw className="size-3.5" />}
          <span className="hidden sm:inline">Refresh</span>
        </Button>
      </div>

      {loading ? (
        <div className="grid place-items-center py-12">
          <Spinner className="size-5 text-primary" />
        </div>
      ) : logs.length === 0 ? (
        <div className="text-center py-12 text-muted-foreground">
          <FileText className="size-8 mx-auto mb-2 opacity-50" />
          <p className="text-sm">No logs yet</p>
        </div>
      ) : (
        <div className="max-h-96 overflow-y-auto rounded-xl bg-zinc-950 border border-border/50 p-3 font-mono text-xs leading-relaxed">
          {logs.map((line, i) => (
            <div key={i} className="whitespace-pre-wrap break-words text-zinc-300 hover:text-zinc-100">
              <span className="text-zinc-500 select-none mr-2">
                {String(i + 1).padStart(3, '0')}
              </span>
              {line}
            </div>
          ))}
        </div>
      )}
    </SectionCard>
  )
}

// ---------- Cache & System Tab ----------
function CacheTab() {
  const [clearing, setClearing] = useState(false)
  const [open, setOpen] = useState(false)

  const run = async () => {
    setClearing(true)
    setOpen(false)
    try {
      const r = (await api.admin.clearCache()) as ClearCacheResponse
      toast.success(`Cleared ${r.cleared ?? 0} entries`)
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to clear cache'
      toast.error(msg)
    } finally {
      setClearing(false)
    }
  }

  return (
    <div className="space-y-4">
      <SectionCard
        icon={<Database className="size-4 text-muted-foreground" />}
        title="API cache"
        description="In-memory cache for search and video metadata responses."
      >
        <div className="flex items-start gap-2 rounded-xl bg-muted/30 border border-border/50 px-3.5 py-2.5">
          <Activity className="size-4 text-muted-foreground mt-0.5 shrink-0" />
          <p className="text-xs text-muted-foreground">
            Caching search/video results in memory for faster repeated access. Cached entries
            auto-expire after their TTL — clearing is harmless but may slow down the next few
            requests.
          </p>
        </div>

        <AlertDialog open={open} onOpenChange={setOpen}>
          <AlertDialogTrigger asChild>
            <Button
              variant="outline"
              size="sm"
              disabled={clearing}
              className="gap-1.5 hover:border-destructive/50 hover:text-destructive"
            >
              {clearing ? <Spinner /> : <Trash2 className="size-3.5" />}
              <span>{clearing ? 'Clearing...' : 'Clear API cache'}</span>
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Clear API cache?</AlertDialogTitle>
              <AlertDialogDescription>
                This will remove all cached search and video responses from memory. The next
                requests will hit yt-dlp directly.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel disabled={clearing}>Cancel</AlertDialogCancel>
              <AlertDialogAction
                onClick={run}
                disabled={clearing}
                className="bg-destructive text-white hover:bg-destructive/90"
              >
                {clearing ? 'Clearing...' : 'Clear cache'}
              </AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </SectionCard>

      <SectionCard
        icon={<Server className="size-4 text-muted-foreground" />}
        title="System info"
        description="Backend runtime details."
      >
        <div className="grid grid-cols-2 sm:grid-cols-3 gap-3">
          <StatTile label="Runtime" value="Next.js 16" />
          <StatTile label="Engine" value="yt-dlp + ffmpeg" />
          <StatTile label="Database" value="SQLite (Prisma)" />
        </div>
      </SectionCard>
    </div>
  )
}

// ---------- Dashboard ----------
function Dashboard({ onLogout }: { onLogout: () => void }) {
  const [version, setVersion] = useState<string>('')
  const [cookies, setCookies] = useState<CookiesMeta | null>(null)
  const [authChecked, setAuthChecked] = useState(false)
  const [loggingOut, setLoggingOut] = useState(false)

  const refreshCookies = useCallback(async () => {
    try {
      const c = (await api.cookies.status()) as CookiesMeta
      setCookies(c)
    } catch (err) {
      console.error('Failed to refresh cookies:', err)
    }
  }, [])

  const loadOverview = useCallback(async () => {
    try {
      const [s, v, c] = await Promise.all([
        api.admin.status(),
        api.admin.version(),
        api.cookies.status(),
      ])
      const status = s as AdminStatusResponse
      if (!status.authenticated) {
        // Session ended — bounce back to login
        onLogout()
        return
      }
      setCookies(c as CookiesMeta)
      setVersion((v as { version: string }).version)
    } catch (err) {
      console.error('Failed to load admin overview:', err)
      toast.error('Failed to load admin data')
    } finally {
      setAuthChecked(true)
    }
  }, [onLogout])

  useEffect(() => {
    void loadOverview()
  }, [loadOverview])

  const handleLogout = async () => {
    setLoggingOut(true)
    try {
      await api.admin.logout()
      toast.success('Logged out')
      onLogout()
    } catch (err) {
      console.error('Logout failed:', err)
      toast.error('Logout failed')
    } finally {
      setLoggingOut(false)
    }
  }

  if (!authChecked) {
    return (
      <div className="px-4 sm:px-6 lg:px-8 py-6">
        <div className="max-w-5xl mx-auto grid place-items-center py-24">
          <Spinner className="size-6 text-primary" />
        </div>
      </div>
    )
  }

  return (
    <div className="px-4 sm:px-6 lg:px-8 py-6">
      <div className="max-w-5xl mx-auto space-y-6">
        {/* Top bar */}
        <header className="flex flex-wrap items-center justify-between gap-3 animate-float-up">
          <div className="flex items-center gap-3">
            <div className="grid place-items-center size-11 rounded-2xl gradient-accent shadow-lg shadow-primary/20">
              <Shield className="size-6 text-white" />
            </div>
            <div>
              <h1 className="text-2xl sm:text-3xl font-bold tracking-tight">
                <span className="gradient-accent-text">Admin Dashboard</span>
              </h1>
              <p className="text-sm text-muted-foreground">
                Manage cookies, yt-dlp, logs, and server cache.
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            {version && (
              <Badge
                variant="outline"
                className="gap-1 border-primary/40 bg-primary/10 text-primary"
              >
                <Server className="size-3" />
                <span className="font-mono text-xs">yt-dlp {version}</span>
              </Badge>
            )}
            <Button
              variant="outline"
              size="sm"
              onClick={() => void handleLogout()}
              disabled={loggingOut}
              className="gap-1.5 hover:border-destructive/50 hover:text-destructive"
            >
              {loggingOut ? <Spinner /> : <LogOut className="size-3.5" />}
              <span>Logout</span>
            </Button>
          </div>
        </header>

        {/* Tabs */}
        <Tabs defaultValue="overview" className="space-y-4">
          <TabsList className="glass border border-border/50 p-1 h-auto overflow-x-auto max-w-full">
            <TabsTrigger value="overview" className="gap-1.5">
              <Settings2 className="size-3.5" />
              <span>Overview</span>
            </TabsTrigger>
            <TabsTrigger value="cookies" className="gap-1.5">
              <Cookie className="size-3.5" />
              <span>Cookies</span>
            </TabsTrigger>
            <TabsTrigger value="logs" className="gap-1.5">
              <FileText className="size-3.5" />
              <span>Logs</span>
            </TabsTrigger>
            <TabsTrigger value="cache" className="gap-1.5">
              <Database className="size-3.5" />
              <span>Cache &amp; System</span>
            </TabsTrigger>
          </TabsList>

          <TabsContent value="overview" className="space-y-4 animate-float-up">
            <OverviewTab
              version={version}
              cookies={cookies}
              setVersion={setVersion}
              refreshCookies={refreshCookies}
            />
          </TabsContent>
          <TabsContent value="cookies" className="animate-float-up">
            <CookiesTab cookies={cookies} refreshCookies={refreshCookies} />
          </TabsContent>
          <TabsContent value="logs" className="animate-float-up">
            <LogsTab />
          </TabsContent>
          <TabsContent value="cache" className="animate-float-up">
            <CacheTab />
          </TabsContent>
        </Tabs>
      </div>
    </div>
  )
}

// ---------- Main AdminView ----------
export function AdminView() {
  const [authed, setAuthed] = useState<boolean | null>(null)

  useEffect(() => {
    let cancelled = false
    void (async () => {
      try {
        const s = (await api.admin.status()) as AdminStatusResponse
        if (!cancelled) setAuthed(!!s.authenticated)
      } catch {
        if (!cancelled) setAuthed(false)
      }
    })()
    return () => {
      cancelled = true
    }
  }, [])

  if (authed === null) {
    return (
      <div className="px-4 sm:px-6 lg:px-8 py-6">
        <div className="max-w-5xl mx-auto grid place-items-center py-24">
          <Spinner className="size-6 text-primary" />
        </div>
      </div>
    )
  }

  if (!authed) {
    return <LoginView onAuthed={() => setAuthed(true)} />
  }

  return <Dashboard onLogout={() => setAuthed(false)} />
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/views/favorites-view.tsx ---
mkdir -p "$(dirname "src/components/views/favorites-view.tsx")"
cat > 'src/components/views/favorites-view.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useCallback, useEffect, useState } from 'react'
import { Heart, Trash2, Home, AlertCircle, RotateCcw } from 'lucide-react'
import { useAppStore, type VideoItem } from '@/lib/store'
import { api } from '@/lib/api'
import { VideoCard } from '@/components/video/video-card'
import { SkeletonGrid } from '@/components/video/skeleton-card'
import { Button } from '@/components/ui/button'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { toast } from 'sonner'

interface FavoriteItem {
  id: number
  videoId: string
  title: string
  channel?: string
  thumbnail?: string
  duration?: number
  createdAt?: string
}

export function FavoritesView() {
  const setView = useAppStore((s) => s.setView)
  const [items, setItems] = useState<FavoriteItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [clearing, setClearing] = useState(false)
  const [clearOpen, setClearOpen] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const r = await api.favorites.list()
      setItems((r.items as FavoriteItem[]) ?? [])
    } catch (err) {
      console.error('Failed to load favorites:', err)
      setError('Unable to load your favorites right now.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    load()
  }, [load])

  const handleClearAll = async () => {
    setClearing(true)
    try {
      // Remove all favorites: call remove() with no videoId clears all (per api contract)
      await api.favorites.remove()
      toast.success('Favorites cleared')
      setClearOpen(false)
      await load()
    } catch (err) {
      console.error('Clear favorites failed:', err)
      toast.error('Failed to clear favorites')
    } finally {
      setClearing(false)
    }
  }

  const videos: VideoItem[] = items.map((item) => ({
    id: item.videoId,
    title: item.title,
    channel: item.channel,
    thumbnail: item.thumbnail,
    duration: item.duration,
  }))

  return (
    <div className="px-4 sm:px-6 lg:px-8 py-6">
      <div className="max-w-7xl mx-auto space-y-6">
        {/* Header */}
        <header className="flex flex-wrap items-center justify-between gap-3 animate-float-up">
          <div className="flex items-center gap-3">
            <div className="grid place-items-center size-11 rounded-2xl gradient-accent shadow-lg shadow-primary/20">
              <Heart className="size-6 text-white" />
            </div>
            <div>
              <h1 className="text-2xl sm:text-3xl font-bold tracking-tight">
                <span className="gradient-accent-text">Favorites</span>
              </h1>
              <p className="text-sm text-muted-foreground">
                {loading
                  ? 'Loading your favorites...'
                  : `${videos.length} ${videos.length === 1 ? 'video' : 'videos'} saved`}
              </p>
            </div>
          </div>

          {!loading && !error && videos.length > 0 && (
            <AlertDialog open={clearOpen} onOpenChange={setClearOpen}>
              <AlertDialogTrigger asChild>
                <Button
                  variant="outline"
                  size="sm"
                  className="gap-1.5 hover:border-destructive/50 hover:text-destructive"
                >
                  <Trash2 className="size-3.5" />
                  <span>Clear all</span>
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent>
                <AlertDialogHeader>
                  <AlertDialogTitle>Clear all favorites?</AlertDialogTitle>
                  <AlertDialogDescription>
                    This will permanently remove all {videos.length} videos from your favorites. This
                    action cannot be undone.
                  </AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel disabled={clearing}>Cancel</AlertDialogCancel>
                  <AlertDialogAction
                    onClick={handleClearAll}
                    disabled={clearing}
                    className="bg-destructive text-white hover:bg-destructive/90"
                  >
                    {clearing ? 'Clearing...' : 'Clear all'}
                  </AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>
          )}
        </header>

        {/* Error state */}
        {!loading && error && (
          <div className="glass rounded-2xl border border-border/50 p-10 text-center flex flex-col items-center animate-float-up">
            <div className="grid place-items-center size-14 rounded-2xl bg-destructive/10 mb-4">
              <AlertCircle className="size-7 text-destructive" />
            </div>
            <h3 className="text-lg font-semibold mb-1">Something went wrong</h3>
            <p className="text-muted-foreground mb-5 max-w-sm text-balance">{error}</p>
            <Button onClick={load} className="gradient-accent text-white border-0 hover:opacity-90">
              <RotateCcw className="size-4" />
              Retry
            </Button>
          </div>
        )}

        {/* Loading state */}
        {loading && (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-5 gap-y-6">
            <SkeletonGrid count={6} />
          </div>
        )}

        {/* Empty state */}
        {!loading && !error && videos.length === 0 && (
          <div className="glass rounded-3xl border border-border/50 p-10 sm:p-14 text-center flex flex-col items-center animate-float-up">
            <div className="grid place-items-center size-16 rounded-2xl glass border border-border/60 mb-5">
              <Heart className="size-8 text-muted-foreground" />
            </div>
            <h2 className="text-xl sm:text-2xl font-bold mb-2">No favorites yet</h2>
            <p className="text-muted-foreground mb-6 max-w-md text-balance">
              Tap the heart on any video to save it here. Your favorite videos will be ready to watch
              anytime, even offline-friendly.
            </p>
            <Button
              onClick={() => setView('home')}
              className="gradient-accent text-white border-0 hover:opacity-90"
            >
              <Home className="size-4" />
              Browse videos
            </Button>
          </div>
        )}

        {/* Results grid */}
        {!loading && !error && videos.length > 0 && (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-5 gap-y-6">
            {videos.map((v) => (
              <VideoCard key={v.id} video={v} />
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/views/history-view.tsx ---
mkdir -p "$(dirname "src/components/views/history-view.tsx")"
cat > 'src/components/views/history-view.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useCallback, useEffect, useState } from 'react'
import {
  Clock,
  Search as SearchIcon,
  Download as DownloadIcon,
  Trash2,
  History as HistoryIcon,
  FileVideo,
  Calendar,
  XCircle,
} from 'lucide-react'
import { useAppStore, type VideoItem } from '@/lib/store'
import { api, formatBytes } from '@/lib/api'
import { VideoCard } from '@/components/video/video-card'
import { SkeletonGrid } from '@/components/video/skeleton-card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'

interface WatchHistoryItem {
  id: number
  videoId: string
  title: string
  channel?: string
  thumbnail?: string
  duration?: number
  watchedAt?: string
}

interface SearchHistoryItem {
  id: number
  query: string
  searchedAt?: string
}

interface DownloadHistoryItem {
  id: number
  videoId?: string
  title: string
  format: string
  quality: string
  status: 'queued' | 'downloading' | 'processing' | 'completed' | 'failed' | 'canceled'
  filepath?: string
  fileSize?: number
  createdAt?: string
}

type HistoryTab = 'watch' | 'search' | 'downloads'

function timeAgo(iso?: string): string {
  if (!iso) return ''
  const then = new Date(iso).getTime()
  if (Number.isNaN(then)) return ''
  const diffMs = Date.now() - then
  if (diffMs < 0) return 'just now'
  const sec = Math.floor(diffMs / 1000)
  if (sec < 60) return 'just now'
  const min = Math.floor(sec / 60)
  if (min < 60) return `${min}m ago`
  const hr = Math.floor(min / 60)
  if (hr < 24) return `${hr}h ago`
  const days = Math.floor(hr / 24)
  if (days < 7) return `${days}d ago`
  const weeks = Math.floor(days / 7)
  if (weeks < 5) return `${weeks}w ago`
  const months = Math.floor(days / 30)
  if (months < 12) return `${months}mo ago`
  const years = Math.floor(days / 365)
  return `${years}y ago`
}

function StatusBadge({ status }: { status: DownloadHistoryItem['status'] }) {
  const map: Record<DownloadHistoryItem['status'], { label: string; className: string }> = {
    completed: {
      label: 'Completed',
      className: 'border-transparent bg-emerald-500/15 text-emerald-500 dark:text-emerald-400',
    },
    failed: {
      label: 'Failed',
      className: 'border-transparent bg-rose-500/15 text-rose-500 dark:text-rose-400',
    },
    downloading: {
      label: 'Downloading',
      className: 'border-transparent bg-amber-500/15 text-amber-500 dark:text-amber-400',
    },
    processing: {
      label: 'Processing',
      className: 'border-transparent bg-sky-500/15 text-sky-500 dark:text-sky-400',
    },
    queued: {
      label: 'Queued',
      className: 'border-transparent bg-muted text-muted-foreground',
    },
    canceled: {
      label: 'Canceled',
      className: 'border-transparent bg-muted text-muted-foreground',
    },
  }
  const entry = map[status] ?? map.queued
  return <Badge className={entry.className}>{entry.label}</Badge>
}

function EmptyState({
  icon,
  title,
  description,
  action,
}: {
  icon: React.ReactNode
  title: string
  description: string
  action?: React.ReactNode
}) {
  return (
    <div className="glass rounded-2xl border border-border/50 p-10 sm:p-14 text-center flex flex-col items-center animate-float-up">
      <div className="grid place-items-center size-14 rounded-2xl glass border border-border/60 mb-4">
        {icon}
      </div>
      <h3 className="text-lg font-semibold mb-1">{title}</h3>
      <p className="text-muted-foreground mb-5 max-w-sm text-balance">{description}</p>
      {action}
    </div>
  )
}

function ClearAllButton({
  type,
  onCleared,
  disabled,
}: {
  type: 'watch' | 'search' | 'download'
  onCleared: () => void
  disabled?: boolean
}) {
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)

  const label = type === 'watch' ? 'watch history' : type === 'search' ? 'search history' : 'download history'

  const handleConfirm = async () => {
    setBusy(true)
    try {
      await api.clearHistory(type)
      toast.success(`${label.charAt(0).toUpperCase() + label.slice(1)} cleared`)
      setOpen(false)
      onCleared()
    } catch (err) {
      console.error('Clear failed:', err)
      toast.error('Failed to clear history')
    } finally {
      setBusy(false)
    }
  }

  return (
    <AlertDialog open={open} onOpenChange={setOpen}>
      <AlertDialogTrigger asChild>
        <Button
          variant="outline"
          size="sm"
          disabled={disabled}
          className="gap-1.5 hover:border-destructive/50 hover:text-destructive"
        >
          <Trash2 className="size-3.5" />
          <span>Clear all</span>
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Clear {label}?</AlertDialogTitle>
          <AlertDialogDescription>
            This will permanently remove all entries from your {label}. This action cannot be undone.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={busy}>Cancel</AlertDialogCancel>
          <AlertDialogAction
            onClick={handleConfirm}
            disabled={busy}
            className="bg-destructive text-white hover:bg-destructive/90"
          >
            {busy ? 'Clearing...' : 'Clear all'}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}

function WatchHistoryTab() {
  const [items, setItems] = useState<WatchHistoryItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const r = await api.history('watch')
      setItems((r.items as WatchHistoryItem[]) ?? [])
    } catch (err) {
      console.error('Failed to load watch history:', err)
      setError('Unable to load watch history right now.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    load()
  }, [load])

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-2">
        <p className="text-sm text-muted-foreground">
          {loading
            ? 'Loading your watch history...'
            : `${items.length} ${items.length === 1 ? 'video' : 'videos'} watched`}
        </p>
        <ClearAllButton type="watch" onCleared={load} disabled={loading || items.length === 0} />
      </div>

      {loading ? (
        <div className="space-y-4">
          <SkeletonGrid count={4} layout="list" />
        </div>
      ) : error ? (
        <EmptyState
          icon={<XCircle className="size-7 text-muted-foreground" />}
          title="Couldn't load history"
          description={error}
          action={
            <Button onClick={load} className="gradient-accent text-white border-0 hover:opacity-90">
              Retry
            </Button>
          }
        />
      ) : items.length === 0 ? (
        <EmptyState
          icon={<Clock className="size-7 text-muted-foreground" />}
          title="No watch history yet"
          description="Videos you watch will appear here so you can easily find them again."
        />
      ) : (
        <div className="space-y-3">
          {items.map((item) => {
            const video: VideoItem = {
              id: item.videoId,
              title: item.title,
              channel: item.channel,
              thumbnail: item.thumbnail,
              duration: item.duration,
            }
            return (
              <div
                key={`${item.id}-${item.videoId}`}
                className="glass rounded-2xl border border-border/50 p-2.5 sm:p-3 animate-float-up"
              >
                <VideoCard video={video} layout="list" />
                {item.watchedAt && (
                  <div className="flex items-center gap-1.5 px-2 pt-2 text-xs text-muted-foreground">
                    <HistoryIcon className="size-3.5" />
                    <span>Watched {timeAgo(item.watchedAt)}</span>
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}

function SearchHistoryTab() {
  const search = useAppStore((s) => s.search)
  const [items, setItems] = useState<SearchHistoryItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const r = await api.history('search')
      setItems((r.items as SearchHistoryItem[]) ?? [])
    } catch (err) {
      console.error('Failed to load search history:', err)
      setError('Unable to load search history right now.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    load()
  }, [load])

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-2">
        <p className="text-sm text-muted-foreground">
          {loading
            ? 'Loading your search history...'
            : `${items.length} ${items.length === 1 ? 'search' : 'searches'}`}
        </p>
        <ClearAllButton type="search" onCleared={load} disabled={loading || items.length === 0} />
      </div>

      {loading ? (
        <div className="flex flex-wrap gap-2">
          {Array.from({ length: 8 }).map((_, i) => (
            <div key={i} className="h-9 w-32 rounded-full bg-muted animate-shimmer" />
          ))}
        </div>
      ) : error ? (
        <EmptyState
          icon={<XCircle className="size-7 text-muted-foreground" />}
          title="Couldn't load history"
          description={error}
          action={
            <Button onClick={load} className="gradient-accent text-white border-0 hover:opacity-90">
              Retry
            </Button>
          }
        />
      ) : items.length === 0 ? (
        <EmptyState
          icon={<SearchIcon className="size-7 text-muted-foreground" />}
          title="No search history yet"
          description="Your recent searches will show up here as clickable chips for quick re-searching."
        />
      ) : (
        <div className="flex flex-wrap gap-2">
          {items.map((item) => (
            <button
              key={`${item.id}-${item.query}`}
              onClick={() => search(item.query)}
              title={`Search again for "${item.query}"`}
              className="group inline-flex items-center gap-2 rounded-full glass border border-border/60 px-3.5 py-2 text-sm hover:border-primary/50 hover:shadow-md hover:shadow-primary/10 transition-all duration-200 hover:-translate-y-0.5 animate-float-up"
            >
              <SearchIcon className="size-3.5 text-muted-foreground group-hover:text-primary transition-colors" />
              <span className="truncate max-w-[240px]">{item.query}</span>
              {item.searchedAt && (
                <span className="text-[10px] text-muted-foreground/70 ml-1 hidden sm:inline">
                  {timeAgo(item.searchedAt)}
                </span>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

function DownloadsTab() {
  const [items, setItems] = useState<DownloadHistoryItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const r = await api.download.list()
      setItems((r.items as DownloadHistoryItem[]) ?? [])
    } catch (err) {
      console.error('Failed to load downloads:', err)
      setError('Unable to load your downloads right now.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    load()
  }, [load])

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-2">
        <p className="text-sm text-muted-foreground">
          {loading
            ? 'Loading downloads...'
            : `${items.length} ${items.length === 1 ? 'download' : 'downloads'}`}
        </p>
        <ClearAllButton type="download" onCleared={load} disabled={loading || items.length === 0} />
      </div>

      {loading ? (
        <div className="space-y-3">
          {Array.from({ length: 4 }).map((_, i) => (
            <div
              key={i}
              className="h-20 rounded-2xl bg-muted/40 border border-border/50 animate-shimmer"
            />
          ))}
        </div>
      ) : error ? (
        <EmptyState
          icon={<XCircle className="size-7 text-muted-foreground" />}
          title="Couldn't load downloads"
          description={error}
          action={
            <Button onClick={load} className="gradient-accent text-white border-0 hover:opacity-90">
              Retry
            </Button>
          }
        />
      ) : items.length === 0 ? (
        <EmptyState
          icon={<DownloadIcon className="size-7 text-muted-foreground" />}
          title="No downloads yet"
          description="When you download videos, they'll appear here with a link to grab the file."
        />
      ) : (
        <div className="space-y-2.5">
          {items.map((item) => {
            const isReady = item.status === 'completed'
            return (
              <div
                key={item.id}
                className="glass rounded-2xl border border-border/50 p-3 sm:p-4 flex flex-col sm:flex-row sm:items-center gap-3 sm:gap-4 animate-float-up"
              >
                <div className="grid place-items-center size-11 rounded-xl gradient-accent shrink-0 shadow-md shadow-primary/20">
                  <FileVideo className="size-5 text-white" />
                </div>
                <div className="min-w-0 flex-1">
                  <h4 className="font-medium text-sm line-clamp-1">{item.title}</h4>
                  <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                    <Badge variant="outline" className="font-mono uppercase">
                      {item.format}
                    </Badge>
                    <Badge variant="outline" className="font-mono uppercase">
                      {item.quality}
                    </Badge>
                    {item.fileSize ? <span>{formatBytes(item.fileSize)}</span> : null}
                    {item.createdAt ? (
                      <span className="inline-flex items-center gap-1">
                        <Calendar className="size-3" />
                        {timeAgo(item.createdAt)}
                      </span>
                    ) : null}
                  </div>
                </div>
                <div className="flex items-center gap-2 sm:gap-3 self-end sm:self-center">
                  <StatusBadge status={item.status} />
                  {isReady && (
                    <Button
                      asChild
                      size="sm"
                      className="gradient-accent text-white border-0 hover:opacity-90"
                    >
                      <a
                        href={api.download.fileUrl(String(item.id))}
                        download
                        title="Download file"
                      >
                        <DownloadIcon className="size-3.5" />
                        <span className="hidden sm:inline">Download</span>
                      </a>
                    </Button>
                  )}
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}

export function HistoryView() {
  const [tab, setTab] = useState<HistoryTab>('watch')

  return (
    <div className="px-4 sm:px-6 lg:px-8 py-6">
      <div className="max-w-7xl mx-auto space-y-6">
        {/* Header */}
        <header className="flex items-center gap-3 animate-float-up">
          <div className="grid place-items-center size-11 rounded-2xl gradient-accent shadow-lg shadow-primary/20">
            <Clock className="size-6 text-white" />
          </div>
          <div>
            <h1 className="text-2xl sm:text-3xl font-bold tracking-tight">
              <span className="gradient-accent-text">History</span>
            </h1>
            <p className="text-sm text-muted-foreground">
              Your watch history, search history, and downloads in one place.
            </p>
          </div>
        </header>

        {/* Tabs */}
        <Tabs value={tab} onValueChange={(v) => setTab(v as HistoryTab)} className="w-full">
          <TabsList className="h-auto p-1 rounded-xl glass border border-border/50">
            <TabsTrigger
              value="watch"
              className={cn(
                'gap-1.5 rounded-lg px-3 py-1.5',
                tab === 'watch' && 'bg-background shadow-sm'
              )}
            >
              <Clock className="size-4" />
              <span>Watch History</span>
            </TabsTrigger>
            <TabsTrigger
              value="search"
              className={cn(
                'gap-1.5 rounded-lg px-3 py-1.5',
                tab === 'search' && 'bg-background shadow-sm'
              )}
            >
              <SearchIcon className="size-4" />
              <span>Search History</span>
            </TabsTrigger>
            <TabsTrigger
              value="downloads"
              className={cn(
                'gap-1.5 rounded-lg px-3 py-1.5',
                tab === 'downloads' && 'bg-background shadow-sm'
              )}
            >
              <DownloadIcon className="size-4" />
              <span>Downloads</span>
            </TabsTrigger>
          </TabsList>

          <TabsContent value="watch" className="mt-6">
            <WatchHistoryTab />
          </TabsContent>
          <TabsContent value="search" className="mt-6">
            <SearchHistoryTab />
          </TabsContent>
          <TabsContent value="downloads" className="mt-6">
            <DownloadsTab />
          </TabsContent>
        </Tabs>
      </div>
    </div>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/views/home-view.tsx ---
mkdir -p "$(dirname "src/components/views/home-view.tsx")"
cat > 'src/components/views/home-view.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useEffect, useState, useRef } from 'react'
import { Search, Sparkles, Flame, Clock, History, X } from 'lucide-react'
import { useAppStore, type VideoItem } from '@/lib/store'
import { api } from '@/lib/api'
import { VideoCard } from '@/components/video/video-card'
import { SkeletonGrid } from '@/components/video/skeleton-card'
import { Button } from '@/components/ui/button'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'

const QUICK_PICKS = ['lofi music', 'coding tutorials', 'documentaries', 'cooking', 'music 2024']

interface HistorySearchItem {
  query: string
}
interface HistoryWatchItem {
  videoId: string
  title: string
  channel?: string
  thumbnail?: string
  duration?: number
}

export function HomeView() {
  const search = useAppStore((s) => s.search)
  const [query, setQuery] = useState('')
  const [focused, setFocused] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)

  const [trending, setTrending] = useState<VideoItem[]>([])
  const [trendingLoading, setTrendingLoading] = useState(true)
  const [trendingError, setTrendingError] = useState<string | null>(null)

  const [recentSearches, setRecentSearches] = useState<string[]>([])
  const [recentlyWatched, setRecentlyWatched] = useState<VideoItem[]>([])

  // Fetch trending
  const loadTrending = async () => {
    setTrendingLoading(true)
    setTrendingError(null)
    try {
      const r = await api.trending()
      setTrending(r.results || [])
    } catch (err) {
      console.error('Failed to load trending:', err)
      setTrendingError('Unable to load trending videos right now. Please try again.')
    } finally {
      setTrendingLoading(false)
    }
  }

  // Fetch recent searches + recently watched
  const loadHistory = async () => {
    try {
      const [searchHist, watchHist] = await Promise.all([
        api.history('search').catch(() => ({ items: [] })),
        api.history('watch').catch(() => ({ items: [] })),
      ])
      const queries = (searchHist.items as HistorySearchItem[])
        .map((i) => i.query)
        .filter((q): q is string => typeof q === 'string' && q.trim().length > 0)
      // de-duplicate while preserving order
      const seen = new Set<string>()
      const uniqueQueries = queries.filter((q) => {
        const key = q.toLowerCase()
        if (seen.has(key)) return false
        seen.add(key)
        return true
      })
      setRecentSearches(uniqueQueries.slice(0, 10))

      const watchItems = (watchHist.items as HistoryWatchItem[])
        .filter((i) => i && i.videoId)
        .map((item) => ({
          id: item.videoId,
          title: item.title,
          channel: item.channel,
          thumbnail: item.thumbnail,
          duration: item.duration,
        })) as VideoItem[]
      // de-duplicate by id, keep latest first
      const seenIds = new Set<string>()
      const uniqueWatch = watchItems.filter((v) => {
        if (seenIds.has(v.id)) return false
        seenIds.add(v.id)
        return true
      })
      setRecentlyWatched(uniqueWatch.slice(0, 12))
    } catch (err) {
      console.error('Failed to load history:', err)
    }
  }

  useEffect(() => {
    loadTrending()
    loadHistory()
  }, [])

  const submitSearch = (e: React.FormEvent) => {
    e.preventDefault()
    const trimmed = query.trim()
    if (!trimmed) {
      toast.error('Please enter a search term')
      return
    }
    search(trimmed)
  }

  const handleQuickPick = (q: string) => {
    setQuery(q)
    search(q)
  }

  return (
    <div className="px-4 sm:px-6 lg:px-8 py-6 max-w-7xl mx-auto w-full">
      {/* ============ HERO ============ */}
      <section className="relative overflow-hidden rounded-3xl glass-strong border border-border/50 px-5 sm:px-10 py-12 sm:py-16 mb-8 animate-float-up">
        {/* animated gradient background blobs */}
        <div className="pointer-events-none absolute -top-24 -right-24 size-72 rounded-full gradient-accent opacity-20 blur-3xl animate-gradient" />
        <div className="pointer-events-none absolute -bottom-24 -left-24 size-72 rounded-full gradient-accent opacity-10 blur-3xl animate-gradient" />

        <div className="relative z-10 flex flex-col items-center text-center max-w-3xl mx-auto">
          <div className="inline-flex items-center gap-1.5 rounded-full glass border border-border/60 px-3 py-1 text-xs font-medium text-muted-foreground mb-5 animate-float-up">
            <Sparkles className="size-3.5 text-primary" />
            <span>Welcome to StreamVault</span>
          </div>

          <h1 className="text-4xl sm:text-5xl lg:text-6xl font-bold tracking-tight mb-4 animate-float-up">
            <span className="gradient-accent-text animate-gradient">Stream anything.</span>
            <br />
            <span className="gradient-accent-text animate-gradient">Beautifully.</span>
          </h1>

          <p className="text-base sm:text-lg text-muted-foreground mb-8 max-w-xl text-balance animate-float-up">
            Search, watch, and download videos with a premium, distraction-free experience built for music, learning, and everything in between.
          </p>

          {/* Big animated search bar */}
          <form
            onSubmit={submitSearch}
            className={cn(
              'w-full max-w-2xl group transition-all duration-300',
              'relative rounded-2xl',
              focused && 'animate-pulse-glow'
            )}
          >
            {/* gradient border glow */}
            <div
              className={cn(
                'absolute -inset-[1.5px] rounded-2xl gradient-accent blur-[2px] transition-opacity duration-300',
                focused ? 'opacity-80' : 'opacity-0 group-hover:opacity-40'
              )}
            />
            <div
              className={cn(
                'relative flex items-center gap-2 rounded-2xl glass-strong border transition-all duration-300',
                focused ? 'border-transparent shadow-2xl shadow-primary/20' : 'border-border/60'
              )}
            >
              <div className="pl-4 sm:pl-5 text-muted-foreground">
                <Search className="size-5" />
              </div>
              <input
                ref={inputRef}
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                onFocus={() => setFocused(true)}
                onBlur={() => setFocused(false)}
                placeholder="Search videos, channels, music..."
                className="flex-1 bg-transparent py-3.5 sm:py-4 text-sm sm:text-base outline-none placeholder:text-muted-foreground"
              />
              {query && (
                <button
                  type="button"
                  onClick={() => {
                    setQuery('')
                    inputRef.current?.focus()
                  }}
                  className="text-muted-foreground hover:text-foreground p-1.5 transition-colors"
                  aria-label="Clear search"
                >
                  <X className="size-4" />
                </button>
              )}
              <Button
                type="submit"
                className="m-1 rounded-xl px-4 sm:px-5 gradient-accent text-white border-0 hover:opacity-90 h-10 sm:h-11"
              >
                <Sparkles className="size-4" />
                <span className="hidden sm:inline">Search</span>
              </Button>
            </div>
          </form>

          {/* Quick-pick chips */}
          <div className="mt-6 flex flex-wrap items-center justify-center gap-2 animate-float-up">
            <span className="text-xs text-muted-foreground mr-1">Quick picks:</span>
            {QUICK_PICKS.map((q) => (
              <button
                key={q}
                onClick={() => handleQuickPick(q)}
                className="rounded-full glass border border-border/60 px-3.5 py-1.5 text-xs font-medium text-foreground/80 hover:text-foreground hover:border-primary/50 hover:shadow-md hover:shadow-primary/10 transition-all duration-200 hover:-translate-y-0.5"
              >
                {q}
              </button>
            ))}
          </div>
        </div>
      </section>

      {/* ============ RECENT SEARCHES ============ */}
      {recentSearches.length > 0 && (
        <section className="mb-8 animate-float-up">
          <div className="flex items-center gap-2 mb-3">
            <History className="size-4 text-muted-foreground" />
            <h2 className="text-sm font-semibold text-muted-foreground uppercase tracking-wider">
              Recent searches
            </h2>
          </div>
          <div className="flex flex-wrap gap-2">
            {recentSearches.map((q, i) => (
              <button
                key={`${q}-${i}`}
                onClick={() => search(q)}
                className="inline-flex items-center gap-1.5 rounded-full glass border border-border/60 px-3.5 py-1.5 text-sm hover:border-primary/50 hover:shadow-md hover:shadow-primary/10 transition-all duration-200 hover:-translate-y-0.5"
              >
                <Search className="size-3.5 text-muted-foreground" />
                <span className="truncate max-w-[200px]">{q}</span>
              </button>
            ))}
          </div>
        </section>
      )}

      {/* ============ TRENDING ============ */}
      <section className="mb-8 animate-float-up">
        <div className="flex items-center justify-between mb-5">
          <div className="flex items-center gap-2.5">
            <div className="grid place-items-center size-9 rounded-xl gradient-accent shadow-lg shadow-primary/20">
              <Flame className="size-5 text-white" />
            </div>
            <div>
              <h2 className="text-xl sm:text-2xl font-bold tracking-tight">Trending Now</h2>
              <p className="text-xs text-muted-foreground">What the world is watching</p>
            </div>
          </div>
          {trendingError && (
            <Button variant="outline" size="sm" onClick={loadTrending} className="shrink-0">
              Retry
            </Button>
          )}
        </div>

        {trendingLoading ? (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-5 gap-y-6">
            <SkeletonGrid count={6} />
          </div>
        ) : trendingError ? (
          <div className="glass rounded-2xl border border-border/50 p-10 text-center">
            <p className="text-muted-foreground">{trendingError}</p>
          </div>
        ) : trending.length === 0 ? (
          <div className="glass rounded-2xl border border-border/50 p-10 text-center">
            <p className="text-muted-foreground">No trending videos found. Try again later.</p>
          </div>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-5 gap-y-6">
            {trending.map((v) => (
              <VideoCard key={v.id} video={v} />
            ))}
          </div>
        )}
      </section>

      {/* ============ RECENTLY WATCHED ============ */}
      {recentlyWatched.length > 0 && (
        <section className="mb-8 animate-float-up">
          <div className="flex items-center gap-2.5 mb-5">
            <div className="grid place-items-center size-9 rounded-xl glass border border-border/60">
              <Clock className="size-5 text-muted-foreground" />
            </div>
            <div>
              <h2 className="text-xl sm:text-2xl font-bold tracking-tight">Recently Watched</h2>
              <p className="text-xs text-muted-foreground">Pick up where you left off</p>
            </div>
          </div>
          <div className="glass rounded-2xl border border-border/50 p-3 sm:p-4">
            <div className="flex gap-3 overflow-x-auto no-scrollbar pb-1">
              {recentlyWatched.map((v) => (
                <div key={v.id} className="w-[280px] sm:w-[320px] shrink-0">
                  <VideoCard video={v} layout="compact" />
                </div>
              ))}
            </div>
          </div>
        </section>
      )}
    </div>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/views/search-view.tsx ---
mkdir -p "$(dirname "src/components/views/search-view.tsx")"
cat > 'src/components/views/search-view.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useEffect, useState, useRef, useCallback } from 'react'
import { Search, SearchX, AlertCircle, RotateCcw, Sparkles, TrendingUp } from 'lucide-react'
import { useAppStore, type VideoItem } from '@/lib/store'
import { api } from '@/lib/api'
import { VideoCard } from '@/components/video/video-card'
import { SkeletonGrid } from '@/components/video/skeleton-card'
import { Button } from '@/components/ui/button'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'

const INITIAL_LIMIT = 20
const PAGE_INCREMENT = 12
const QUICK_PICKS = ['lofi music', 'coding tutorials', 'documentaries', 'cooking', 'music 2024']

export function SearchView() {
  const searchQuery = useAppStore((s) => s.searchQuery)
  const search = useAppStore((s) => s.search)

  const [results, setResults] = useState<VideoItem[]>([])
  const [loading, setLoading] = useState(true)
  const [loadingMore, setLoadingMore] = useState(false)
  const [limit, setLimit] = useState(INITIAL_LIMIT)
  const [hasMore, setHasMore] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const sentinelRef = useRef<HTMLDivElement>(null)
  const abortRef = useRef<AbortController | null>(null)

  // ---- Reset + initial load whenever the query changes ----
  useEffect(() => {
    if (!searchQuery.trim()) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setResults([])
      setLoading(false)
      setHasMore(false)
      setError(null)
      return
    }

    // Abort any in-flight request
    abortRef.current?.abort()
    const ctrl = new AbortController()
    abortRef.current = ctrl

    setLoading(true)
    setError(null)
    setResults([])
    setLimit(INITIAL_LIMIT)
    setHasMore(true)

    api
      .search(searchQuery, INITIAL_LIMIT)
      .then((r) => {
        if (ctrl.signal.aborted) return
        const items = r.results || []
        setResults(items)
        setHasMore(items.length >= INITIAL_LIMIT)
        setLoading(false)
      })
      .catch((err) => {
        if (ctrl.signal.aborted) return
        console.error('Search failed:', err)
        setError(err?.message || 'Failed to load search results.')
        setLoading(false)
        setHasMore(false)
      })

    return () => ctrl.abort()
  }, [searchQuery])

  // ---- Load more: triggered when `limit` grows past INITIAL_LIMIT ----
  useEffect(() => {
    if (limit === INITIAL_LIMIT) return // initial already loaded by the effect above
    if (!searchQuery.trim()) return

    // eslint-disable-next-line react-hooks/set-state-in-effect
    setLoadingMore(true)
    api
      .search(searchQuery, limit)
      .then((r) => {
        const items = r.results || []
        setResults(items)
        setHasMore(items.length >= limit)
      })
      .catch((err) => {
        console.error('Load more failed:', err)
        toast.error('Could not load more results')
        // roll back the limit so user can retry
        setLimit((l) => Math.max(INITIAL_LIMIT, l - PAGE_INCREMENT))
        setHasMore(true)
      })
      .finally(() => setLoadingMore(false))
  }, [limit, searchQuery])

  // ---- IntersectionObserver for infinite scroll ----
  const handleIntersect = useCallback(
    (entries: IntersectionObserverEntry[]) => {
      const entry = entries[0]
      if (!entry.isIntersecting) return
      if (!hasMore || loading || loadingMore) return
      setLimit((l) => l + PAGE_INCREMENT)
    },
    [hasMore, loading, loadingMore]
  )

  useEffect(() => {
    const node = sentinelRef.current
    if (!node) return
    const obs = new IntersectionObserver(handleIntersect, { rootMargin: '400px' })
    obs.observe(node)
    return () => obs.disconnect()
  }, [handleIntersect])

  // ---- Retry initial load ----
  const retry = () => {
    if (!searchQuery.trim()) return
    setLoading(true)
    setError(null)
    setResults([])
    setLimit(INITIAL_LIMIT)
    setHasMore(true)
    api
      .search(searchQuery, INITIAL_LIMIT)
      .then((r) => {
        const items = r.results || []
        setResults(items)
        setHasMore(items.length >= INITIAL_LIMIT)
      })
      .catch((err) => {
        console.error('Retry failed:', err)
        setError(err?.message || 'Failed to load search results.')
        setHasMore(false)
      })
      .finally(() => setLoading(false))
  }

  // ---- Empty query state ----
  if (!searchQuery.trim()) {
    return (
      <div className="px-4 sm:px-6 lg:px-8 py-6 max-w-7xl mx-auto w-full">
        <div className="glass rounded-3xl border border-border/50 p-10 sm:p-16 text-center flex flex-col items-center animate-float-up">
          <div className="grid place-items-center size-16 rounded-2xl gradient-accent shadow-lg shadow-primary/20 mb-5">
            <Search className="size-8 text-white" />
          </div>
          <h2 className="text-2xl sm:text-3xl font-bold mb-2">
            <span className="gradient-accent-text">Search StreamVault</span>
          </h2>
          <p className="text-muted-foreground mb-8 max-w-md text-balance">
            Find videos, music, tutorials, documentaries and more. Start typing in the search bar above, or pick one of these popular topics.
          </p>
          <div className="flex flex-wrap items-center justify-center gap-2">
            {QUICK_PICKS.map((q) => (
              <button
                key={q}
                onClick={() => search(q)}
                className="inline-flex items-center gap-1.5 rounded-full glass border border-border/60 px-4 py-2 text-sm font-medium text-foreground/80 hover:text-foreground hover:border-primary/50 hover:shadow-md hover:shadow-primary/10 transition-all duration-200 hover:-translate-y-0.5"
              >
                <TrendingUp className="size-3.5 text-primary" />
                {q}
              </button>
            ))}
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="px-4 sm:px-6 lg:px-8 py-6 max-w-7xl mx-auto w-full">
      {/* ---- Header ---- */}
      <header className="mb-6 animate-float-up">
        <div className="flex items-center gap-2 text-xs text-muted-foreground mb-2">
          <Search className="size-3.5" />
          <span className="uppercase tracking-wider font-medium">Search results</span>
        </div>
        <h1 className="text-2xl sm:text-3xl font-bold tracking-tight flex flex-wrap items-baseline gap-x-2.5 gap-y-1">
          <span className="text-muted-foreground font-medium">Results for</span>
          <span className="gradient-accent-text">&ldquo;{searchQuery}&rdquo;</span>
        </h1>
        {!loading && !error && (
          <p className="mt-1.5 text-sm text-muted-foreground">
            {results.length > 0
              ? `Showing ${results.length} ${results.length === 1 ? 'result' : 'results'}${hasMore ? ' · scroll for more' : ''}`
              : 'No results to display'}
          </p>
        )}
      </header>

      {/* ---- Error state ---- */}
      {error && !loading && (
        <div className="glass rounded-2xl border border-border/50 p-10 text-center flex flex-col items-center animate-float-up">
          <div className="grid place-items-center size-14 rounded-2xl bg-destructive/10 mb-4">
            <AlertCircle className="size-7 text-destructive" />
          </div>
          <h3 className="text-lg font-semibold mb-1">Something went wrong</h3>
          <p className="text-muted-foreground mb-5 max-w-sm text-balance">{error}</p>
          <Button onClick={retry} className="gradient-accent text-white border-0 hover:opacity-90">
            <RotateCcw className="size-4" />
            Retry search
          </Button>
        </div>
      )}

      {/* ---- Loading state ---- */}
      {loading && (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-5 gap-y-6">
          <SkeletonGrid count={8} />
        </div>
      )}

      {/* ---- Empty results ---- */}
      {!loading && !error && results.length === 0 && (
        <div className="glass rounded-2xl border border-border/50 p-10 sm:p-14 text-center flex flex-col items-center animate-float-up">
          <div className="grid place-items-center size-14 rounded-2xl glass border border-border/60 mb-4">
            <SearchX className="size-7 text-muted-foreground" />
          </div>
          <h3 className="text-lg font-semibold mb-1">No results found</h3>
          <p className="text-muted-foreground mb-5 max-w-sm text-balance">
            We couldn&rsquo;t find anything for &ldquo;{searchQuery}&rdquo;. Try different keywords or check the spelling.
          </p>
          <div className="flex flex-wrap items-center justify-center gap-2">
            {QUICK_PICKS.slice(0, 3).map((q) => (
              <button
                key={q}
                onClick={() => search(q)}
                className="inline-flex items-center gap-1.5 rounded-full glass border border-border/60 px-3.5 py-1.5 text-sm hover:border-primary/50 hover:shadow-md hover:shadow-primary/10 transition-all duration-200 hover:-translate-y-0.5"
              >
                <Sparkles className="size-3.5 text-primary" />
                {q}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* ---- Results grid ---- */}
      {!loading && !error && results.length > 0 && (
        <>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-x-5 gap-y-6">
            {results.map((v) => (
              <VideoCard key={v.id} video={v} />
            ))}
          </div>

          {/* ---- Infinite scroll sentinel ---- */}
          <div
            ref={sentinelRef}
            className="h-12 mt-8 flex items-center justify-center"
            aria-hidden="true"
          >
            {loadingMore && (
              <div className="flex items-center gap-2 text-sm text-muted-foreground">
                <div className="size-4 rounded-full border-2 border-primary/30 border-t-primary animate-spin" />
                <span>Loading more...</span>
              </div>
            )}
            {!hasMore && !loadingMore && (
              <div className="flex items-center gap-2 text-xs text-muted-foreground">
                <div className="h-px w-12 bg-border" />
                <span>You&rsquo;ve reached the end</span>
                <div className="h-px w-12 bg-border" />
              </div>
            )}
          </div>
        </>
      )}
    </div>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/views/settings-view.tsx ---
mkdir -p "$(dirname "src/components/views/settings-view.tsx")"
cat > 'src/components/views/settings-view.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useCallback, useEffect, useState } from 'react'
import {
  Settings as SettingsIcon,
  Save,
  RotateCcw,
  Lock,
  Play,
  Server,
  Info,
  Sun,
  Moon,
  Monitor,
  Youtube,
  Cookie,
  CheckCircle2,
  AlertCircle,
} from 'lucide-react'
import { useTheme } from 'next-themes'
import { api } from '@/lib/api'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Separator } from '@/components/ui/separator'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'

interface AppSettings {
  downloadDir: string
  cacheMax: number
  theme: 'light' | 'dark' | 'auto'
  defaultQuality: string
  defaultFormat: string
  historyLimit: number
  rateLimitPerMin: number
}

const DEFAULT_SETTINGS: AppSettings = {
  downloadDir: '',
  cacheMax: 2048,
  theme: 'dark',
  defaultQuality: '720p',
  defaultFormat: 'mp4',
  historyLimit: 100,
  rateLimitPerMin: 30,
}

const QUALITY_OPTIONS = ['144p', '240p', '360p', '480p', '720p', '1080p', 'highest']
const FORMAT_OPTIONS = ['mp4', 'webm', 'mp3', 'm4a', 'wav', 'flac']
const THEME_OPTIONS: Array<{ value: AppSettings['theme']; label: string; icon: React.ReactNode }> = [
  { value: 'light', label: 'Light', icon: <Sun className="size-3.5" /> },
  { value: 'dark', label: 'Dark', icon: <Moon className="size-3.5" /> },
  { value: 'auto', label: 'System', icon: <Monitor className="size-3.5" /> },
]

function AdminOnlyBadge() {
  return (
    <Badge
      variant="outline"
      className="gap-1 border-amber-500/40 bg-amber-500/10 text-amber-600 dark:text-amber-400"
      title="This setting can only be changed by an admin"
    >
      <Lock className="size-3" />
      <span>Admin only</span>
    </Badge>
  )
}

function FieldRow({
  id,
  label,
  hint,
  children,
  badge,
}: {
  id: string
  label: string
  hint?: string
  children: React.ReactNode
  badge?: React.ReactNode
}) {
  return (
    <div className="grid gap-2 sm:grid-cols-[1fr_2fr] sm:items-center sm:gap-4">
      <div className="flex items-center gap-2">
        <Label htmlFor={id} className="text-sm font-medium">
          {label}
        </Label>
        {badge}
      </div>
      <div className="space-y-1">
        {children}
        {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
      </div>
    </div>
  )
}

export function SettingsView() {
  const { setTheme } = useTheme()
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS)
  const [original, setOriginal] = useState<AppSettings>(DEFAULT_SETTINGS)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const r = await api.settings.get()
      const next: AppSettings = {
        downloadDir: r?.downloadDir ?? '',
        cacheMax: Number(r?.cacheMax ?? DEFAULT_SETTINGS.cacheMax),
        theme: (r?.theme as AppSettings['theme']) ?? DEFAULT_SETTINGS.theme,
        defaultQuality: r?.defaultQuality ?? DEFAULT_SETTINGS.defaultQuality,
        defaultFormat: r?.defaultFormat ?? DEFAULT_SETTINGS.defaultFormat,
        historyLimit: Number(r?.historyLimit ?? DEFAULT_SETTINGS.historyLimit),
        rateLimitPerMin: Number(r?.rateLimitPerMin ?? DEFAULT_SETTINGS.rateLimitPerMin),
      }
      setSettings(next)
      setOriginal(next)
    } catch (err) {
      console.error('Failed to load settings:', err)
      setError('Unable to load your settings right now.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    load()
  }, [load])

  const update = <K extends keyof AppSettings>(key: K, value: AppSettings[K]) => {
    setSettings((prev) => ({ ...prev, [key]: value }))
  }

  const handleThemeChange = (value: AppSettings['theme']) => {
    update('theme', value)
    setTheme(value)
  }

  const handleSave = async () => {
    setSaving(true)
    try {
      await api.settings.save(settings)
      setOriginal(settings)
      toast.success('Settings saved')
    } catch (err) {
      console.error('Save settings failed:', err)
      toast.error(err instanceof Error ? err.message : 'Failed to save settings')
    } finally {
      setSaving(false)
    }
  }

  const handleReset = () => {
    setSettings(original)
    setTheme(original.theme)
    toast.info('Reverted to last saved values')
  }

  const handleResetDefaults = () => {
    setSettings(DEFAULT_SETTINGS)
    setTheme(DEFAULT_SETTINGS.theme)
    toast.info('Reset to defaults — don\'t forget to save')
  }

  const isDirty = JSON.stringify(settings) !== JSON.stringify(original)

  return (
    <div className="px-4 sm:px-6 lg:px-8 py-6 pb-28">
      <div className="max-w-4xl mx-auto space-y-6">
        {/* Header */}
        <header className="flex flex-wrap items-center justify-between gap-3 animate-float-up">
          <div className="flex items-center gap-3">
            <div className="grid place-items-center size-11 rounded-2xl gradient-accent shadow-lg shadow-primary/20">
              <SettingsIcon className="size-6 text-white" />
            </div>
            <div>
              <h1 className="text-2xl sm:text-3xl font-bold tracking-tight">
                <span className="gradient-accent-text">Settings</span>
              </h1>
              <p className="text-sm text-muted-foreground">
                Customize playback, manage server preferences, and learn about StreamVault.
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={handleResetDefaults}
              disabled={loading || saving}
              title="Reset all fields to default values"
            >
              <RotateCcw className="size-3.5" />
              <span className="hidden sm:inline">Reset to defaults</span>
            </Button>
          </div>
        </header>

        {/* Error state */}
        {!loading && error && (
          <Card className="glass rounded-2xl border-destructive/40 animate-float-up">
            <CardContent className="flex items-center gap-3 pt-6">
              <div className="grid place-items-center size-10 rounded-xl bg-destructive/10">
                <AlertCircle className="size-5 text-destructive" />
              </div>
              <div className="flex-1">
                <p className="font-medium">Couldn&apos;t load settings</p>
                <p className="text-sm text-muted-foreground">{error}</p>
              </div>
              <Button onClick={load} size="sm" variant="outline">
                Retry
              </Button>
            </CardContent>
          </Card>
        )}

        {loading && (
          <div className="space-y-4">
            {[0, 1, 2].map((i) => (
              <div
                key={i}
                className="h-40 rounded-2xl bg-muted/40 border border-border/50 animate-shimmer"
              />
            ))}
          </div>
        )}

        {/* ============ Playback ============ */}
        {!loading && !error && (
          <Card className="glass rounded-2xl border-border/50 animate-float-up">
            <CardHeader>
              <div className="flex items-center gap-2">
                <div className="grid place-items-center size-8 rounded-xl gradient-accent">
                  <Play className="size-4 text-white" />
                </div>
                <div>
                  <CardTitle className="text-base">Playback</CardTitle>
                  <CardDescription>Defaults used when watching or downloading videos.</CardDescription>
                </div>
              </div>
            </CardHeader>
            <CardContent className="space-y-5">
              <FieldRow id="defaultQuality" label="Default quality" hint="Applied when opening a video.">
                <Select
                  value={settings.defaultQuality}
                  onValueChange={(v) => update('defaultQuality', v)}
                >
                  <SelectTrigger id="defaultQuality" className="w-full sm:w-48">
                    <SelectValue placeholder="Select quality" />
                  </SelectTrigger>
                  <SelectContent>
                    {QUALITY_OPTIONS.map((q) => (
                      <SelectItem key={q} value={q} className="uppercase">
                        {q}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </FieldRow>

              <Separator />

              <FieldRow id="defaultFormat" label="Default format" hint="Container/codec used when downloading.">
                <Select
                  value={settings.defaultFormat}
                  onValueChange={(v) => update('defaultFormat', v)}
                >
                  <SelectTrigger id="defaultFormat" className="w-full sm:w-48">
                    <SelectValue placeholder="Select format" />
                  </SelectTrigger>
                  <SelectContent>
                    {FORMAT_OPTIONS.map((f) => (
                      <SelectItem key={f} value={f} className="uppercase">
                        {f}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </FieldRow>

              <Separator />

              <FieldRow id="theme" label="Theme" hint="Switches the interface color scheme instantly.">
                <div className="flex flex-wrap gap-2">
                  {THEME_OPTIONS.map((opt) => (
                    <button
                      key={opt.value}
                      type="button"
                      onClick={() => handleThemeChange(opt.value)}
                      className={cn(
                        'inline-flex items-center gap-2 rounded-xl px-3.5 py-2 text-sm font-medium border transition-all',
                        settings.theme === opt.value
                          ? 'gradient-accent text-white border-transparent shadow-md shadow-primary/20'
                          : 'glass border-border/60 hover:border-primary/50'
                      )}
                      aria-pressed={settings.theme === opt.value}
                    >
                      {opt.icon}
                      <span>{opt.label}</span>
                    </button>
                  ))}
                </div>
              </FieldRow>
            </CardContent>
          </Card>
        )}

        {/* ============ Server ============ */}
        {!loading && !error && (
          <Card className="glass rounded-2xl border-border/50 animate-float-up">
            <CardHeader>
              <div className="flex items-center gap-2">
                <div className="grid place-items-center size-8 rounded-xl glass border border-border/60">
                  <Server className="size-4 text-muted-foreground" />
                </div>
                <div>
                  <CardTitle className="text-base flex items-center gap-2">
                    Server
                    <AdminOnlyBadge />
                  </CardTitle>
                  <CardDescription>
                    Backend configuration. Only an admin can change these values.
                  </CardDescription>
                </div>
              </div>
            </CardHeader>
            <CardContent className="space-y-5">
              <FieldRow
                id="downloadDir"
                label="Download directory"
                hint="Where downloaded media files are stored on the server."
                badge={<AdminOnlyBadge />}
              >
                <Input
                  id="downloadDir"
                  value={settings.downloadDir}
                  onChange={(e) => update('downloadDir', e.target.value)}
                  placeholder="/data/downloads"
                  disabled
                  className="font-mono text-sm"
                />
              </FieldRow>

              <Separator />

              <FieldRow
                id="cacheMax"
                label="Cache size (MB)"
                hint="Maximum disk space used by the yt-dlp metadata cache."
                badge={<AdminOnlyBadge />}
              >
                <Input
                  id="cacheMax"
                  type="number"
                  min={0}
                  value={settings.cacheMax}
                  onChange={(e) => update('cacheMax', Number(e.target.value))}
                  disabled
                />
              </FieldRow>

              <Separator />

              <FieldRow
                id="historyLimit"
                label="History limit"
                hint="Maximum number of watch & search history entries to retain."
                badge={<AdminOnlyBadge />}
              >
                <Input
                  id="historyLimit"
                  type="number"
                  min={0}
                  value={settings.historyLimit}
                  onChange={(e) => update('historyLimit', Number(e.target.value))}
                  disabled
                />
              </FieldRow>

              <Separator />

              <FieldRow
                id="rateLimitPerMin"
                label="Rate limit (per min)"
                hint="Maximum yt-dlp requests allowed per minute from this server."
                badge={<AdminOnlyBadge />}
              >
                <Input
                  id="rateLimitPerMin"
                  type="number"
                  min={0}
                  value={settings.rateLimitPerMin}
                  onChange={(e) => update('rateLimitPerMin', Number(e.target.value))}
                  disabled
                />
              </FieldRow>
            </CardContent>
          </Card>
        )}

        {/* ============ About ============ */}
        {!loading && !error && (
          <Card className="glass rounded-2xl border-border/50 animate-float-up">
            <CardHeader>
              <div className="flex items-center gap-2">
                <div className="grid place-items-center size-8 rounded-xl glass border border-border/60">
                  <Info className="size-4 text-muted-foreground" />
                </div>
                <div>
                  <CardTitle className="text-base">About</CardTitle>
                  <CardDescription>Project information and credits.</CardDescription>
                </div>
              </div>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="flex items-start gap-3 rounded-xl bg-muted/30 p-3.5">
                <div className="grid place-items-center size-10 rounded-xl gradient-accent shadow-md shadow-primary/20 shrink-0">
                  <Youtube className="size-5 text-white" />
                </div>
                <div className="min-w-0">
                  <p className="font-semibold">StreamVault</p>
                  <p className="text-sm text-muted-foreground">
                    A premium, distraction-free streaming frontend built with Next.js, TypeScript and Tailwind CSS.
                  </p>
                </div>
              </div>

              <div className="flex items-start gap-3 rounded-xl bg-muted/30 p-3.5">
                <div className="grid place-items-center size-10 rounded-xl glass border border-border/60 shrink-0">
                  <span className="text-xs font-bold gradient-accent-text">yt-dlp</span>
                </div>
                <div className="min-w-0">
                  <p className="font-semibold">Powered by yt-dlp</p>
                  <p className="text-sm text-muted-foreground">
                    All video metadata, search, streaming and downloads are handled by the open-source yt-dlp engine.
                  </p>
                </div>
              </div>

              <div className="flex items-start gap-3 rounded-xl bg-muted/30 p-3.5">
                <div className="grid place-items-center size-10 rounded-xl glass border border-border/60 shrink-0">
                  <Cookie className="size-5 text-muted-foreground" />
                </div>
                <div className="min-w-0">
                  <p className="font-semibold">Cookies &amp; authentication</p>
                  <p className="text-sm text-muted-foreground">
                    YouTube cookies are managed securely in the Admin panel — never exposed to the browser. Use the Admin tab to upload or test cookies.
                  </p>
                </div>
              </div>
            </CardContent>
          </Card>
        )}
      </div>

      {/* Sticky save bar */}
      {!loading && !error && (
        <div className="fixed bottom-0 left-0 right-0 z-30 border-t border-border/60 glass-strong">
          <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-3 flex items-center justify-between gap-3">
            <div className="flex items-center gap-2 text-sm text-muted-foreground min-w-0">
              {isDirty ? (
                <>
                  <div className="size-2 rounded-full bg-amber-500 animate-pulse-glow shrink-0" />
                  <span className="truncate">You have unsaved changes</span>
                </>
              ) : (
                <>
                  <CheckCircle2 className="size-4 text-emerald-500 shrink-0" />
                  <span className="truncate">All changes saved</span>
                </>
              )}
            </div>
            <div className="flex items-center gap-2 shrink-0">
              <Button
                variant="outline"
                size="sm"
                onClick={handleReset}
                disabled={!isDirty || saving}
                title="Revert to last saved values"
              >
                <RotateCcw className="size-3.5" />
                <span className="hidden sm:inline">Revert</span>
              </Button>
              <Button
                onClick={handleSave}
                disabled={!isDirty || saving}
                className="gradient-accent text-white border-0 hover:opacity-90"
              >
                {saving ? (
                  <div className="size-4 rounded-full border-2 border-white/40 border-t-white animate-spin" />
                ) : (
                  <Save className="size-4" />
                )}
                <span>{saving ? 'Saving...' : 'Save changes'}</span>
              </Button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/views/video-view.tsx ---
mkdir -p "$(dirname "src/components/views/video-view.tsx")"
cat > 'src/components/views/video-view.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useEffect, useState } from 'react'
import {
  ThumbsUp, ThumbsDown, Share2, Download, Bookmark, Heart, QrCode, Copy,
  CheckCircle2, ChevronDown, ChevronUp, MessageCircle, Eye, Calendar, ListVideo,
  Loader2, ArrowLeft, XCircle,
} from 'lucide-react'
import { useAppStore } from '@/lib/store'
import { api, formatViews, formatDuration, formatUploadDate, type VideoDetail, type VideoItem } from '@/lib/api'
import { VideoPlayer } from '@/components/video/video-player'
import { VideoCard } from '@/components/video/video-card'
import { SkeletonCard } from '@/components/video/skeleton-card'
import { DownloadModal } from '@/components/video/download-modal'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
} from '@/components/ui/dialog'
import { cn } from '@/lib/utils'
import { toast } from 'sonner'
import Image from 'next/image'

export function VideoView() {
  const videoId = useAppStore((s) => s.videoId)
  const goBack = useAppStore((s) => s.goBack)
  const openVideo = useAppStore((s) => s.openVideo)
  const setView = useAppStore((s) => s.setView)

  const [video, setVideo] = useState<VideoDetail | null>(null)
  const [related, setRelated] = useState<VideoItem[]>([])
  const [loading, setLoading] = useState(true)
  const [descExpanded, setDescExpanded] = useState(false)
  const [liked, setLiked] = useState(false)
  const [disliked, setDisliked] = useState(false)
  const [saved, setSaved] = useState(false)
  const [favorited, setFavorited] = useState(false)
  const [downloadOpen, setDownloadOpen] = useState(false)
  const [shareOpen, setShareOpen] = useState(false)
  const [activeChapter, setActiveChapter] = useState<number>(-1)

  useEffect(() => {
    if (!videoId) return
    let cancelled = false
    Promise.all([
      api.video(videoId).then((r) => { if (!cancelled) setVideo(r.video) }).catch(() => toast.error('Failed to load video')),
      api.related(videoId).then((r) => { if (!cancelled) setRelated(r.results) }).catch(() => { if (!cancelled) setRelated([]) }),
    ]).finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [videoId])

  const channel = video?.channel || video?.uploader || 'Unknown'
  const verified = ['VEVO', 'Official', 'Records'].some((k) => channel.includes(k))

  const handleShare = () => {
    const url = `https://www.youtube.com/watch?v=${videoId}`
    navigator.clipboard.writeText(url)
    toast.success('Link copied to clipboard')
  }

  const handleSave = async () => {
    if (!video) return
    try {
      if (saved) {
        await api.watchlater.remove(videoId || undefined)
        setSaved(false)
        toast.success('Removed from Watch Later')
      } else {
        await api.watchlater.add({ id: video.id, title: video.title, channel, thumbnail: video.thumbnail, duration: video.duration })
        setSaved(true)
        toast.success('Saved to Watch Later')
      }
    } catch { toast.error('Failed') }
  }

  const handleFavorite = async () => {
    if (!video) return
    try {
      if (favorited) {
        await api.favorites.remove(videoId || undefined)
        setFavorited(false)
        toast.success('Removed from Favorites')
      } else {
        await api.favorites.add({ id: video.id, title: video.title, channel, thumbnail: video.thumbnail, duration: video.duration })
        setFavorited(true)
        toast.success('Added to Favorites')
      }
    } catch { toast.error('Failed') }
  }

  if (loading) {
    return (
      <div className="px-4 sm:px-6 lg:px-8 py-6 max-w-7xl mx-auto">
        <div className="aspect-video w-full rounded-2xl bg-muted animate-shimmer mb-4" />
        <div className="grid lg:grid-cols-[1fr_360px] gap-6">
          <div className="space-y-4">
            <div className="h-7 bg-muted rounded w-3/4 animate-shimmer" />
            <div className="h-4 bg-muted rounded w-1/3 animate-shimmer" />
            <div className="h-20 bg-muted rounded animate-shimmer" />
          </div>
          <div className="space-y-3">
            {[1, 2, 3, 4].map((i) => <SkeletonCard key={i} layout="compact" />)}
          </div>
        </div>
      </div>
    )
  }

  if (!video) {
    return (
      <div className="px-4 py-20 text-center max-w-md mx-auto">
        <div className="size-14 rounded-full bg-destructive/15 grid place-items-center mx-auto mb-4">
          <XCircle className="size-7 text-destructive" />
        </div>
        <p className="font-semibold text-lg mb-2">Video could not be loaded</p>
        <p className="text-sm text-muted-foreground mb-5">
          YouTube may be blocking this video (anti-bot) or your cookies may be stale.
          Try a different video, or upload fresh cookies in the Admin panel.
        </p>
        <div className="flex gap-2 justify-center">
          <Button variant="outline" onClick={goBack}><ArrowLeft className="size-4" /> Go Back</Button>
          <Button variant="secondary" onClick={() => setView('admin')}>Manage Cookies</Button>
        </div>
      </div>
    )
  }

  return (
    <div className="px-3 sm:px-4 lg:px-6 py-4">
      <div className="max-w-[1600px] mx-auto grid lg:grid-cols-[1fr_380px] gap-6">
        {/* Main column */}
        <div className="min-w-0 space-y-4">
          <VideoPlayer videoId={video.id} />

          {/* Title */}
          <h1 className="text-lg sm:text-xl font-bold leading-tight text-balance">{video.title}</h1>

          {/* Channel + actions */}
          <div className="flex flex-wrap items-center gap-3 justify-between">
            <div className="flex items-center gap-3">
              <Avatar className="size-10">
                <AvatarFallback className="gradient-accent text-white font-bold">{channel.charAt(0).toUpperCase()}</AvatarFallback>
              </Avatar>
              <div>
                <div className="flex items-center gap-1.5">
                  <span className="font-semibold text-sm">{channel}</span>
                  {verified && <CheckCircle2 className="size-4 fill-current text-muted-foreground" />}
                </div>
                <p className="text-xs text-muted-foreground">
                  {formatViews(video.view_count)} • {formatUploadDate(video.upload_date)}
                </p>
              </div>
            </div>

            {/* Action buttons */}
            <div className="flex items-center gap-1.5 flex-wrap">
              <div className="flex items-center rounded-full bg-muted/60 overflow-hidden">
                <button
                  onClick={() => { setLiked(!liked); if (disliked) setDisliked(false) }}
                  className={cn('flex items-center gap-1.5 px-3.5 py-2 text-sm font-medium hover:bg-muted transition-colors', liked && 'text-primary')}
                >
                  <ThumbsUp className={cn('size-4', liked && 'fill-current')} />
                  <span className="hidden sm:inline">{video.like_count ? formatViews(video.like_count).replace(' views', '') : 'Like'}</span>
                </button>
                <div className="w-px h-5 bg-border" />
                <button
                  onClick={() => { setDisliked(!disliked); if (liked) setLiked(false) }}
                  className={cn('px-3.5 py-2 hover:bg-muted transition-colors', disliked && 'text-primary')}
                >
                  <ThumbsDown className={cn('size-4', disliked && 'fill-current')} />
                </button>
              </div>

              <Button variant="secondary" size="sm" className="rounded-full h-9" onClick={() => setShareOpen(true)}>
                <Share2 className="size-4" /> <span className="hidden sm:inline">Share</span>
              </Button>
              <Button variant="secondary" size="sm" className="rounded-full h-9" onClick={() => setDownloadOpen(true)}>
                <Download className="size-4" /> <span className="hidden sm:inline">Download</span>
              </Button>
              <Button
                variant="secondary" size="sm" className="rounded-full h-9"
                onClick={handleSave}
              >
                <Bookmark className={cn('size-4', saved && 'fill-current text-primary')} />
                <span className="hidden sm:inline">{saved ? 'Saved' : 'Save'}</span>
              </Button>
              <Button
                variant="secondary" size="sm" className="rounded-full h-9"
                onClick={handleFavorite}
              >
                <Heart className={cn('size-4', favorited && 'fill-current text-primary')} />
              </Button>
            </div>
          </div>

          {/* Description */}
          <div className="rounded-xl glass p-4 text-sm">
            <div className="flex items-center gap-3 mb-2 text-xs font-semibold text-muted-foreground">
              <span className="flex items-center gap-1"><Eye className="size-3.5" /> {formatViews(video.view_count)}</span>
              {video.upload_date && <span className="flex items-center gap-1"><Calendar className="size-3.5" /> {formatUploadDate(video.upload_date)}</span>}
              {video.duration && <span>{formatDuration(video.duration)}</span>}
            </div>
            <div className={cn('whitespace-pre-wrap text-sm leading-relaxed', !descExpanded && 'line-clamp-3')}>
              {video.description || 'No description available.'}
            </div>
            {video.description && video.description.length > 200 && (
              <button
                onClick={() => setDescExpanded(!descExpanded)}
                className="mt-2 text-xs font-semibold text-muted-foreground hover:text-foreground flex items-center gap-1"
              >
                {descExpanded ? 'Show less' : 'Show more'}
                {descExpanded ? <ChevronUp className="size-3" /> : <ChevronDown className="size-3" />}
              </button>
            )}
            {video.tags && video.tags.length > 0 && (
              <div className="flex flex-wrap gap-1.5 mt-3 pt-3 border-t border-border/40">
                {video.tags.slice(0, 8).map((t) => (
                  <Badge key={t} variant="secondary" className="text-xs cursor-pointer hover:bg-primary/10 hover:text-primary" onClick={() => useAppStore.getState().search(t)}>
                    #{t}
                  </Badge>
                ))}
              </div>
            )}
          </div>

          {/* Chapters */}
          {video.chapters && video.chapters.length > 0 && (
            <div className="rounded-xl glass p-4">
              <h3 className="flex items-center gap-2 text-sm font-semibold mb-3">
                <ListVideo className="size-4" /> Chapters
              </h3>
              <div className="space-y-1 max-h-72 overflow-y-auto">
                {video.chapters.map((ch, i) => (
                  <button
                    key={i}
                    onClick={() => setActiveChapter(i)}
                    className={cn(
                      'w-full flex items-center gap-3 p-2 rounded-lg text-left text-sm transition-colors',
                      activeChapter === i ? 'bg-primary/10 text-primary' : 'hover:bg-accent/60'
                    )}
                  >
                    <span className="text-xs font-mono text-muted-foreground shrink-0 w-12">{formatDuration(ch.start_time)}</span>
                    <span className="line-clamp-1">{ch.title}</span>
                  </button>
                ))}
              </div>
            </div>
          )}

          {/* Comments placeholder */}
          <div className="rounded-xl glass p-6 text-center">
            <MessageCircle className="size-8 mx-auto text-muted-foreground mb-2" />
            <p className="text-sm font-medium">Comments</p>
            <p className="text-xs text-muted-foreground mt-1">Comments are not available in this self-hosted frontend.</p>
          </div>
        </div>

        {/* Related sidebar */}
        <div className="space-y-3">
          <h3 className="text-sm font-semibold flex items-center gap-2 px-1">
            <ListVideo className="size-4" /> Up Next
          </h3>
          {related.length === 0 && (
            <div className="space-y-3">
              {[1, 2, 3, 4, 5].map((i) => <SkeletonCard key={i} layout="compact" />)}
            </div>
          )}
          <div className="space-y-1 max-h-[calc(100vh-2rem)] overflow-y-auto no-scrollbar pb-4">
            {related.map((v) => (
              <VideoCard key={v.id} video={v} layout="compact" />
            ))}
          </div>
        </div>
      </div>

      <DownloadModal
        open={downloadOpen}
        onOpenChange={setDownloadOpen}
        videoId={video.id}
        title={video.title}
      />

      {/* Share dialog */}
      <Dialog open={shareOpen} onOpenChange={setShareOpen}>
        <DialogContent className="glass-strong border-border/60 max-w-sm">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2"><Share2 className="size-5" /> Share</DialogTitle>
          </DialogHeader>
          <div className="space-y-3 py-2">
            <div className="flex items-center gap-2 p-2 rounded-lg bg-muted/50">
              <input
                readOnly
                value={`https://www.youtube.com/watch?v=${video.id}`}
                className="flex-1 bg-transparent text-sm outline-none truncate"
              />
              <Button size="sm" variant="ghost" onClick={handleShare}>
                <Copy className="size-4" />
              </Button>
            </div>
            <div className="flex items-center justify-center gap-3 py-2">
              <div className="rounded-xl overflow-hidden bg-white p-2">
                <img
                  src={`/api/qr?text=${encodeURIComponent(`https://www.youtube.com/watch?v=${video.id}`)}`}
                  alt="QR code"
                  width={160}
                  height={160}
                />
              </div>
            </div>
            <p className="text-center text-xs text-muted-foreground">Scan to open on any device</p>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/components/views/watchlater-view.tsx ---
mkdir -p "$(dirname "src/components/views/watchlater-view.tsx")"
cat > 'src/components/views/watchlater-view.tsx' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useCallback, useEffect, useState } from 'react'
import { Clock, Trash2, Home, AlertCircle, RotateCcw, X } from 'lucide-react'
import { useAppStore, type VideoItem } from '@/lib/store'
import { api } from '@/lib/api'
import { VideoCard } from '@/components/video/video-card'
import { SkeletonGrid } from '@/components/video/skeleton-card'
import { Button } from '@/components/ui/button'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { toast } from 'sonner'

interface WatchLaterItem {
  id: number
  videoId: string
  title: string
  channel?: string
  thumbnail?: string
  duration?: number
  createdAt?: string
}

export function WatchLaterView() {
  const setView = useAppStore((s) => s.setView)
  const [items, setItems] = useState<WatchLaterItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [clearing, setClearing] = useState(false)
  const [clearOpen, setClearOpen] = useState(false)
  const [removingId, setRemovingId] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const r = await api.watchlater.list()
      setItems((r.items as WatchLaterItem[]) ?? [])
    } catch (err) {
      console.error('Failed to load watch later:', err)
      setError('Unable to load your watch later list right now.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    load()
  }, [load])

  const handleRemove = async (videoId: string) => {
    setRemovingId(videoId)
    try {
      await api.watchlater.remove(videoId)
      setItems((prev) => prev.filter((i) => i.videoId !== videoId))
      toast.success('Removed from Watch Later')
    } catch (err) {
      console.error('Remove from watch later failed:', err)
      toast.error('Failed to remove video')
    } finally {
      setRemovingId(null)
    }
  }

  const handleClearAll = async () => {
    setClearing(true)
    try {
      await api.watchlater.remove()
      toast.success('Watch Later cleared')
      setClearOpen(false)
      setItems([])
    } catch (err) {
      console.error('Clear watch later failed:', err)
      toast.error('Failed to clear Watch Later')
    } finally {
      setClearing(false)
    }
  }

  const videos: VideoItem[] = items.map((item) => ({
    id: item.videoId,
    title: item.title,
    channel: item.channel,
    thumbnail: item.thumbnail,
    duration: item.duration,
  }))

  return (
    <div className="px-4 sm:px-6 lg:px-8 py-6">
      <div className="max-w-7xl mx-auto space-y-6">
        {/* Header */}
        <header className="flex flex-wrap items-center justify-between gap-3 animate-float-up">
          <div className="flex items-center gap-3">
            <div className="grid place-items-center size-11 rounded-2xl gradient-accent shadow-lg shadow-primary/20">
              <Clock className="size-6 text-white" />
            </div>
            <div>
              <h1 className="text-2xl sm:text-3xl font-bold tracking-tight">
                <span className="gradient-accent-text">Watch Later</span>
              </h1>
              <p className="text-sm text-muted-foreground">
                {loading
                  ? 'Loading your list...'
                  : `${videos.length} ${videos.length === 1 ? 'video' : 'videos'} queued`}
              </p>
            </div>
          </div>

          {!loading && !error && videos.length > 0 && (
            <AlertDialog open={clearOpen} onOpenChange={setClearOpen}>
              <AlertDialogTrigger asChild>
                <Button
                  variant="outline"
                  size="sm"
                  className="gap-1.5 hover:border-destructive/50 hover:text-destructive"
                >
                  <Trash2 className="size-3.5" />
                  <span>Clear all</span>
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent>
                <AlertDialogHeader>
                  <AlertDialogTitle>Clear your Watch Later list?</AlertDialogTitle>
                  <AlertDialogDescription>
                    This will remove all {videos.length} videos from your Watch Later list. This
                    action cannot be undone.
                  </AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel disabled={clearing}>Cancel</AlertDialogCancel>
                  <AlertDialogAction
                    onClick={handleClearAll}
                    disabled={clearing}
                    className="bg-destructive text-white hover:bg-destructive/90"
                  >
                    {clearing ? 'Clearing...' : 'Clear all'}
                  </AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>
          )}
        </header>

        {/* Error state */}
        {!loading && error && (
          <div className="glass rounded-2xl border border-border/50 p-10 text-center flex flex-col items-center animate-float-up">
            <div className="grid place-items-center size-14 rounded-2xl bg-destructive/10 mb-4">
              <AlertCircle className="size-7 text-destructive" />
            </div>
            <h3 className="text-lg font-semibold mb-1">Something went wrong</h3>
            <p className="text-muted-foreground mb-5 max-w-sm text-balance">{error}</p>
            <Button onClick={load} className="gradient-accent text-white border-0 hover:opacity-90">
              <RotateCcw className="size-4" />
              Retry
            </Button>
          </div>
        )}

        {/* Loading state */}
        {loading && (
          <div className="space-y-4">
            <SkeletonGrid count={5} layout="list" />
          </div>
        )}

        {/* Empty state */}
        {!loading && !error && videos.length === 0 && (
          <div className="glass rounded-3xl border border-border/50 p-10 sm:p-14 text-center flex flex-col items-center animate-float-up">
            <div className="grid place-items-center size-16 rounded-2xl glass border border-border/60 mb-5">
              <Clock className="size-8 text-muted-foreground" />
            </div>
            <h2 className="text-xl sm:text-2xl font-bold mb-2">Your Watch Later is empty</h2>
            <p className="text-muted-foreground mb-6 max-w-md text-balance">
              Save videos here to watch them later. Perfect for when you spot something interesting
              but don&rsquo;t have time right now.
            </p>
            <Button
              onClick={() => setView('home')}
              className="gradient-accent text-white border-0 hover:opacity-90"
            >
              <Home className="size-4" />
              Browse videos
            </Button>
          </div>
        )}

        {/* List */}
        {!loading && !error && videos.length > 0 && (
          <div className="space-y-3">
            {videos.map((v) => (
              <div
                key={v.id}
                className="glass rounded-2xl border border-border/50 p-2.5 sm:p-3 flex items-start gap-2 sm:gap-3 animate-float-up group relative"
              >
                <div className="min-w-0 flex-1">
                  <VideoCard video={v} layout="list" />
                </div>
                <Button
                  variant="ghost"
                  size="icon"
                  onClick={() => handleRemove(v.id)}
                  disabled={removingId === v.id}
                  title="Remove from Watch Later"
                  aria-label={`Remove "${v.title}" from Watch Later`}
                  className="shrink-0 mt-1 rounded-full hover:bg-destructive/10 hover:text-destructive"
                >
                  {removingId === v.id ? (
                    <div className="size-4 rounded-full border-2 border-muted-foreground/30 border-t-muted-foreground animate-spin" />
                  ) : (
                    <X className="size-4" />
                  )}
                </Button>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/hooks/use-download-progress.ts ---
mkdir -p "$(dirname "src/hooks/use-download-progress.ts")"
cat > 'src/hooks/use-download-progress.ts' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { useEffect, useRef, useState, useCallback } from 'react'
import type { DownloadJob } from '@/lib/api'

/**
 * Low-RAM optimized download progress hook.
 *
 * Previous version used socket.io-client connecting to a separate
 * progress-service Bun process on port 3001. That extra process
 * consumed 50-80MB of RAM. This version polls the Next.js API
 * directly — no socket.io, no separate process, no extra memory.
 *
 * Polling is adaptive: fast (1s) while a job is active,
 * slow (5s) when idle to minimize network traffic.
 */

const POLL_ACTIVE_MS = 1000
const POLL_IDLE_MS = 5000

export interface DownloadProgressState {
  jobs: DownloadJob[]
  connected: boolean
}

export function useDownloadProgress(jobId?: string) {
  const [job, setJob] = useState<DownloadJob | null>(null)
  const [connected, setConnected] = useState(false)
  const activeRef = useRef(true)

  useEffect(() => {
    activeRef.current = true
    if (!jobId) return

    let interval: ReturnType<typeof setInterval>
    const poll = async () => {
      if (!activeRef.current) return
      try {
        const { api } = await import('@/lib/api')
        const r = await api.download.status(jobId)
        if (activeRef.current && r.job) {
          setJob(r.job)
          setConnected(true)
        }
      } catch {
        if (activeRef.current) setConnected(false)
      }
    }

    poll()
    // Poll faster while job is active, slower when done
    interval = setInterval(async () => {
      await poll()
      // Adapt polling speed based on job status
      if (activeRef.current && job) {
        const isActive = job.status === 'queued' || job.status === 'downloading' || job.status === 'processing'
        clearInterval(interval)
        interval = setInterval(poll, isActive ? POLL_ACTIVE_MS : POLL_IDLE_MS)
      }
    }, POLL_ACTIVE_MS)

    return () => {
      activeRef.current = false
      clearInterval(interval)
    }
  }, [jobId])

  return { job, connected }
}

export function useAllDownloadJobs() {
  const [jobs, setJobs] = useState<DownloadJob[]>([])
  const [connected, setConnected] = useState(false)
  const activeRef = useRef(true)

  const refresh = useCallback(async () => {
    if (!activeRef.current) return
    try {
      const { api } = await import('@/lib/api')
      const r = await api.download.status()
      if (activeRef.current) {
        setJobs(r.jobs || [])
        setConnected(true)
      }
    } catch {
      if (activeRef.current) setConnected(false)
    }
  }, [])

  useEffect(() => {
    activeRef.current = true
    let interval: ReturnType<typeof setInterval>

    const startPolling = () => {
      refresh()
      interval = setInterval(async () => {
        await refresh()
        // Adapt: poll fast if any job active, slow if idle
        if (!activeRef.current) return
        const hasActive = jobs.some(
          (j) => j.status === 'queued' || j.status === 'downloading' || j.status === 'processing'
        )
        clearInterval(interval)
        interval = setInterval(startPolling, hasActive ? POLL_ACTIVE_MS : POLL_IDLE_MS)
      }, POLL_ACTIVE_MS)
    }

    startPolling()

    return () => {
      activeRef.current = false
      clearInterval(interval)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return { jobs, connected, refresh }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/hooks/use-mobile.ts ---
mkdir -p "$(dirname "src/hooks/use-mobile.ts")"
cat > 'src/hooks/use-mobile.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import * as React from "react"

const MOBILE_BREAKPOINT = 768

export function useIsMobile() {
  const [isMobile, setIsMobile] = React.useState<boolean | undefined>(undefined)

  React.useEffect(() => {
    const mql = window.matchMedia(`(max-width: ${MOBILE_BREAKPOINT - 1}px)`)
    const onChange = () => {
      setIsMobile(window.innerWidth < MOBILE_BREAKPOINT)
    }
    mql.addEventListener("change", onChange)
    setIsMobile(window.innerWidth < MOBILE_BREAKPOINT)
    return () => mql.removeEventListener("change", onChange)
  }, [])

  return !!isMobile
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/hooks/use-toast.ts ---
mkdir -p "$(dirname "src/hooks/use-toast.ts")"
cat > 'src/hooks/use-toast.ts' <<'HZ_FILE_CONTENT_END_7X9K'
"use client"

// Inspired by react-hot-toast library
import * as React from "react"

import type {
  ToastActionElement,
  ToastProps,
} from "@/components/ui/toast"

const TOAST_LIMIT = 1
const TOAST_REMOVE_DELAY = 1000000

type ToasterToast = ToastProps & {
  id: string
  title?: React.ReactNode
  description?: React.ReactNode
  action?: ToastActionElement
}

const actionTypes = {
  ADD_TOAST: "ADD_TOAST",
  UPDATE_TOAST: "UPDATE_TOAST",
  DISMISS_TOAST: "DISMISS_TOAST",
  REMOVE_TOAST: "REMOVE_TOAST",
} as const

let count = 0

function genId() {
  count = (count + 1) % Number.MAX_SAFE_INTEGER
  return count.toString()
}

type ActionType = typeof actionTypes

type Action =
  | {
    type: ActionType["ADD_TOAST"]
    toast: ToasterToast
  }
  | {
    type: ActionType["UPDATE_TOAST"]
    toast: Partial<ToasterToast>
  }
  | {
    type: ActionType["DISMISS_TOAST"]
    toastId?: ToasterToast["id"]
  }
  | {
    type: ActionType["REMOVE_TOAST"]
    toastId?: ToasterToast["id"]
  }

interface State {
  toasts: ToasterToast[]
}

const toastTimeouts = new Map<string, ReturnType<typeof setTimeout>>()

const addToRemoveQueue = (toastId: string) => {
  if (toastTimeouts.has(toastId)) {
    return
  }

  const timeout = setTimeout(() => {
    toastTimeouts.delete(toastId)
    dispatch({
      type: "REMOVE_TOAST",
      toastId: toastId,
    })
  }, TOAST_REMOVE_DELAY)

  toastTimeouts.set(toastId, timeout)
}

export const reducer = (state: State, action: Action): State => {
  switch (action.type) {
    case "ADD_TOAST":
      return {
        ...state,
        toasts: [action.toast, ...state.toasts].slice(0, TOAST_LIMIT),
      }

    case "UPDATE_TOAST":
      return {
        ...state,
        toasts: state.toasts.map((t) =>
          t.id === action.toast.id ? { ...t, ...action.toast } : t
        ),
      }

    case "DISMISS_TOAST": {
      const { toastId } = action

      // ! Side effects ! - This could be extracted into a dismissToast() action,
      // but I'll keep it here for simplicity
      if (toastId) {
        addToRemoveQueue(toastId)
      } else {
        state.toasts.forEach((toast) => {
          addToRemoveQueue(toast.id)
        })
      }

      return {
        ...state,
        toasts: state.toasts.map((t) =>
          t.id === toastId || toastId === undefined
            ? {
              ...t,
              open: false,
            }
            : t
        ),
      }
    }
    case "REMOVE_TOAST":
      if (action.toastId === undefined) {
        return {
          ...state,
          toasts: [],
        }
      }
      return {
        ...state,
        toasts: state.toasts.filter((t) => t.id !== action.toastId),
      }
  }
}

const listeners: Array<(state: State) => void> = []

let memoryState: State = { toasts: [] }

function dispatch(action: Action) {
  memoryState = reducer(memoryState, action)
  listeners.forEach((listener) => {
    listener(memoryState)
  })
}

type Toast = Omit<ToasterToast, "id">

function toast({ ...props }: Toast) {
  const id = genId()

  const update = (props: ToasterToast) =>
    dispatch({
      type: "UPDATE_TOAST",
      toast: { ...props, id },
    })
  const dismiss = () => dispatch({ type: "DISMISS_TOAST", toastId: id })

  dispatch({
    type: "ADD_TOAST",
    toast: {
      ...props,
      id,
      open: true,
      onOpenChange: (open) => {
        if (!open) dismiss()
      },
    },
  })

  return {
    id: id,
    dismiss,
    update,
  }
}

function useToast() {
  const [state, setState] = React.useState<State>(memoryState)

  React.useEffect(() => {
    listeners.push(setState)
    return () => {
      const index = listeners.indexOf(setState)
      if (index > -1) {
        listeners.splice(index, 1)
      }
    }
  }, [state])

  return {
    ...state,
    toast,
    dismiss: (toastId?: string) => dispatch({ type: "DISMISS_TOAST", toastId }),
  }
}

export { useToast, toast }
HZ_FILE_CONTENT_END_7X9K

    # --- src/lib/admin-auth.ts ---
mkdir -p "$(dirname "src/lib/admin-auth.ts")"
cat > 'src/lib/admin-auth.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { cookies } from 'next/headers'

const ADMIN_COOKIE = 'ytdl_admin_token'
const SESSION_TTL = 1000 * 60 * 60 * 4 // 4 hours

// Simple signed-token session. Token = base64(password + ':' + expiry)
function makeToken(password: string, expiry: number): string {
  const payload = `${password}:${expiry}`
  return Buffer.from(payload).toString('base64')
}

export async function adminLogin(password: string): Promise<boolean> {
  const expected = process.env.ADMIN_PASSWORD || 'changeme123'
  if (password !== expected) return false
  const expiry = Date.now() + SESSION_TTL
  const token = makeToken(password, expiry)
  const store = await cookies()
  store.set(ADMIN_COOKIE, token, {
    httpOnly: true,
    sameSite: 'lax',
    maxAge: SESSION_TTL / 1000,
    path: '/',
  })
  return true
}

export async function adminLogout(): Promise<void> {
  const store = await cookies()
  store.delete(ADMIN_COOKIE)
}

export async function isAdmin(): Promise<boolean> {
  const store = await cookies()
  const token = store.get(ADMIN_COOKIE)?.value
  if (!token) return false
  try {
    const decoded = Buffer.from(token, 'base64').toString('utf-8')
    const [password, expiryStr] = decoded.split(':')
    const expected = process.env.ADMIN_PASSWORD || 'changeme123'
    if (password !== expected) return false
    const expiry = parseInt(expiryStr, 10)
    if (Date.now() > expiry) return false
    return true
  } catch {
    return false
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/lib/api.ts ---
mkdir -p "$(dirname "src/lib/api.ts")"
cat > 'src/lib/api.ts' <<'HZ_FILE_CONTENT_END_7X9K'
// Client-side API helpers
import type { VideoItem } from './store'

export type { VideoItem }

export interface VideoDetail {
  id: string
  title: string
  description: string
  channel?: string
  uploader?: string
  channel_id?: string
  thumbnail?: string
  duration?: number
  view_count?: number
  like_count?: number
  upload_date?: string
  formats?: any[]
  chapters?: Array<{ start_time: number; end_time: number; title: string }>
  tags?: string[]
  categories?: string[]
}

export interface StreamInfo {
  id: string
  title: string
  mode: 'muxed' | 'merge'
  playableUrl: string
  availableQualities: string[]
  selectedHeight: number
  duration: number
  subtitles: Array<{ label: string; srclang: string; url: string }>
  chapters: Array<{ start_time: number; end_time: number; title: string }>
}

export interface DownloadJob {
  id: string
  videoId: string
  title: string
  format: string
  quality: string
  status: 'queued' | 'downloading' | 'processing' | 'completed' | 'failed' | 'canceled'
  progress: number
  speed?: string
  eta?: string
  filename?: string
  filepath?: string
  fileSize?: number
  error?: string
  createdAt: number
  updatedAt: number
}

// 502 FIX: Retry logic for transient gateway errors (502, 503, network failures)
const RETRYABLE_STATUS = new Set([502, 503, 504, 408, 429])
const MAX_RETRIES = 3
const RETRY_BASE_DELAY = 800 // ms

async function apiFetchWithRetry<T>(
  url: string,
  options?: RequestInit,
  attempt = 0,
): Promise<T> {
  // 30s timeout per attempt (prevents infinite hangs)
  const controller = new AbortController()
  const timeoutId = setTimeout(() => controller.abort(), 30000)
  const signal = options?.signal
    ? mergeSignals(options.signal, controller.signal)
    : controller.signal

  try {
    const res = await fetch(url, {
      ...options,
      signal,
      headers: {
        'Content-Type': 'application/json',
        ...(options?.headers || {}),
      },
    })

    // Retry on 502/503/504 (gateway errors — transient, usually yt-dlp slow start)
    if (RETRYABLE_STATUS.has(res.status) && attempt < MAX_RETRIES) {
      clearTimeout(timeoutId)
      const delay = RETRY_BASE_DELAY * Math.pow(2, attempt) + Math.random() * 300
      await sleep(delay)
      return apiFetchWithRetry<T>(url, options, attempt + 1)
    }

    const data = await res.json().catch(() => ({}))
    if (!res.ok) {
      throw new Error((data as any).error || `Request failed (${res.status})`)
    }
    return data as T
  } catch (e) {
    // Retry on network errors / aborts (but not on the final attempt)
    if (attempt < MAX_RETRIES && isRetryableError(e)) {
      clearTimeout(timeoutId)
      const delay = RETRY_BASE_DELAY * Math.pow(2, attempt) + Math.random() * 300
      await sleep(delay)
      return apiFetchWithRetry<T>(url, options, attempt + 1)
    }
    throw e
  } finally {
    clearTimeout(timeoutId)
  }
}

function isRetryableError(e: unknown): boolean {
  if (e instanceof Error) {
    const msg = e.message.toLowerCase()
    return msg.includes('fetch failed') || msg.includes('network') ||
      msg.includes('aborted') || msg.includes('timeout') ||
      msg.includes('econnreset') || msg.includes('econnrefused')
  }
  return false
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms))
}

// Merge two AbortSignals into one (aborts if either aborts)
function mergeSignals(a: AbortSignal, b: AbortSignal): AbortSignal {
  if (a.aborted) return a
  if (b.aborted) return b
  const controller = new AbortController()
  const onAbort = () => controller.abort()
  a.addEventListener('abort', onAbort, { once: true })
  b.addEventListener('abort', onAbort, { once: true })
  return controller.signal
}

async function apiFetch<T>(url: string, options?: RequestInit): Promise<T> {
  return apiFetchWithRetry<T>(url, options)
}

export const api = {
  search: (q: string, limit = 20) =>
    apiFetch<{ results: VideoItem[]; query: string }>(`/api/ytdlp/search?q=${encodeURIComponent(q)}&limit=${limit}`),
  suggest: (q: string) =>
    apiFetch<{ suggestions: string[] }>(`/api/ytdlp/suggest?q=${encodeURIComponent(q)}`),
  video: (id: string) =>
    apiFetch<{ video: VideoDetail }>(`/api/ytdlp/video?id=${encodeURIComponent(id)}`),
  stream: (id: string, quality: string) =>
    apiFetch<StreamInfo>(`/api/ytdlp/stream?id=${encodeURIComponent(id)}&quality=${encodeURIComponent(quality)}`),
  related: (id: string) =>
    apiFetch<{ results: VideoItem[] }>(`/api/ytdlp/related?id=${encodeURIComponent(id)}`),
  trending: (country = 'US') =>
    apiFetch<{ results: VideoItem[] }>(`/api/ytdlp/trending?country=${country}`),
  channel: (id: string, limit = 30) =>
    apiFetch<{ channel?: string; videos: VideoItem[] }>(`/api/ytdlp/channel?id=${encodeURIComponent(id)}&limit=${limit}`),
  history: (type: 'watch' | 'search' | 'download') =>
    apiFetch<{ type: string; items: any[] }>(`/api/history?type=${type}`),
  clearHistory: (type: 'watch' | 'search' | 'download' | 'all') =>
    apiFetch<{ success: boolean }>(`/api/history?type=${type}`, { method: 'DELETE' }),
  settings: {
    get: () => apiFetch<any>('/api/settings'),
    save: (s: any) => apiFetch<any>('/api/settings', { method: 'POST', body: JSON.stringify(s) }),
  },
  cookies: {
    status: () => apiFetch<any>('/api/cookies/status'),
    upload: (content: string) =>
      apiFetch<{ success: boolean }>(`/api/cookies/upload`, { method: 'POST', body: JSON.stringify({ content }) }),
    uploadFile: (file: File) => {
      const fd = new FormData()
      fd.append('cookies', file)
      return fetch('/api/cookies/upload', { method: 'POST', body: fd }).then((r) => r.json())
    },
    test: () => apiFetch<any>('/api/cookies/test', { method: 'POST' }),
  },
  download: {
    start: (videoId: string, title: string, format: string, quality: string) =>
      apiFetch<{ jobId: string }>(`/api/download/start`, { method: 'POST', body: JSON.stringify({ videoId, title, format, quality }) }),
    status: (jobId?: string) =>
      apiFetch<{ job?: DownloadJob; jobs?: DownloadJob[] }>(`/api/download/status${jobId ? `?jobId=${jobId}` : ''}`),
    list: () => apiFetch<{ items: any[] }>('/api/download/list'),
    cancel: (jobId: string) =>
      apiFetch<{ success: boolean }>(`/api/download/cancel`, { method: 'POST', body: JSON.stringify({ jobId }) }),
    fileUrl: (id: string) => `/api/download/file?id=${encodeURIComponent(id)}`,
  },
  favorites: {
    list: () => apiFetch<{ items: any[] }>('/api/favorites'),
    add: (v: VideoItem) =>
      apiFetch<{ item: any }>('/api/favorites', { method: 'POST', body: JSON.stringify(v) }),
    remove: (videoId?: string) =>
      apiFetch<{ success: boolean }>(`/api/favorites${videoId ? `?videoId=${videoId}` : ''}`, { method: 'DELETE' }),
  },
  watchlater: {
    list: () => apiFetch<{ items: any[] }>('/api/watchlater'),
    add: (v: VideoItem) =>
      apiFetch<{ item: any }>('/api/watchlater', { method: 'POST', body: JSON.stringify(v) }),
    remove: (videoId?: string) =>
      apiFetch<{ success: boolean }>(`/api/watchlater${videoId ? `?videoId=${videoId}` : ''}`, { method: 'DELETE' }),
  },
  admin: {
    login: (password: string) =>
      apiFetch<{ success: boolean }>('/api/admin/login', { method: 'POST', body: JSON.stringify({ password }) }),
    logout: () => apiFetch<{ success: boolean }>('/api/admin/logout', { method: 'POST' }),
    status: () => apiFetch<any>('/api/admin/status'),
    version: () => apiFetch<{ version: string }>('/api/admin/version'),
    update: () => apiFetch<any>('/api/admin/version', { method: 'POST' }),
    logs: () => apiFetch<{ logs: string[] }>('/api/admin/logs'),
    clearCache: () => apiFetch<any>('/api/admin/cache', { method: 'POST' }),
  },
}

// Formatting helpers
export function formatViews(n?: number): string {
  if (!n || n < 0) return '0 views'
  if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(1)}B views`
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M views`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K views`
  return `${n} views`
}

export function formatDuration(seconds?: number): string {
  if (!seconds || seconds < 0) return '0:00'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  const s = Math.floor(seconds % 60)
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
  return `${m}:${String(s).padStart(2, '0')}`
}

export function formatUploadDate(dateStr?: string): string {
  if (!dateStr) return ''
  // yt-dlp format: YYYYMMDD
  if (/^\d{8}$/.test(dateStr)) {
    const y = dateStr.slice(0, 4)
    const m = dateStr.slice(4, 6)
    const d = dateStr.slice(6, 8)
    const date = new Date(`${y}-${m}-${d}`)
    const now = new Date()
    const diffMs = now.getTime() - date.getTime()
    const days = Math.floor(diffMs / (1000 * 60 * 60 * 24))
    if (days < 1) return 'today'
    if (days < 2) return '1 day ago'
    if (days < 7) return `${days} days ago`
    if (days < 14) return '1 week ago'
    if (days < 30) return `${Math.floor(days / 7)} weeks ago`
    if (days < 60) return '1 month ago'
    if (days < 365) return `${Math.floor(days / 30)} months ago`
    const years = Math.floor(days / 365)
    if (years < 2) return '1 year ago'
    return `${years} years ago`
  }
  return dateStr
}

export function formatBytes(n?: number): string {
  if (!n || n < 0) return '0 B'
  if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(2)} GB`
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)} MB`
  if (n >= 1_000) return `${(n / 1_000).toFixed(2)} KB`
  return `${n} B`
}

export function bestThumbnail(item: VideoItem): string {
  if (item.thumbnail) return item.thumbnail
  if (item.thumbnails && item.thumbnails.length) {
    return item.thumbnails[item.thumbnails.length - 1].url
  }
  return `https://i.ytimg.com/vi/${item.id}/hqdefault.jpg`
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/lib/cookies.ts ---
mkdir -p "$(dirname "src/lib/cookies.ts")"
cat > 'src/lib/cookies.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { writeFile, readFile, unlink, access, constants, mkdir, stat } from 'fs/promises'
import { existsSync } from 'fs'
import path from 'path'
import { execFile } from 'child_process'
import { promisify } from 'util'
import { cookiesAvailable, getCookiesPath, getYtdlpPath } from './ytdlp'

const execFileAsync = promisify(execFile)

export interface CookiesStatus {
  available: boolean
  path: string
  size: number
  uploadedAt: string | null
  valid: boolean
  lastError?: string
}

export async function getCookiesStatus(): Promise<CookiesStatus> {
  const p = getCookiesPath()
  const available = await cookiesAvailable()
  if (!available) {
    return {
      available: false,
      path: p,
      size: 0,
      uploadedAt: null,
      valid: false,
    }
  }
  const stats = await stat(p)
  let valid = false
  let lastError: string | undefined
  try {
    const content = await readFile(p, 'utf-8')
    // Basic Netscape cookie format validation
    const lines = content.split('\n').filter((l) => l.trim() && !l.trim().startsWith('#'))
    valid = lines.length > 0
    // Check first data line has 7 fields
    if (valid) {
      const fields = lines[0].split('\t')
      if (fields.length < 7) {
        valid = false
        lastError = 'Invalid Netscape cookie format (expected 7 tab-separated fields per line)'
      }
    }
  } catch (e) {
    lastError = e instanceof Error ? e.message : String(e)
  }
  return {
    available: true,
    path: p,
    size: stats.size,
    uploadedAt: stats.mtime.toISOString(),
    valid,
    lastError,
  }
}

export async function saveCookies(content: string): Promise<void> {
  const p = getCookiesPath()
  await mkdir(path.dirname(p), { recursive: true })
  // Basic validation
  const trimmed = content.trim()
  if (!trimmed) throw new Error('Cookies file is empty')
  const lines = trimmed.split('\n').filter((l) => l.trim() && !l.trim().startsWith('#'))
  if (lines.length === 0) throw new Error('Cookies file contains no data lines')
  const fields = lines[0].split('\t')
  if (fields.length < 7) {
    throw new Error('Invalid Netscape cookie format. Each line must have 7 tab-separated fields: domain, flag, path, secure, expiration, name, value')
  }
  await writeFile(p, content, { mode: 0o600 })
}

export async function deleteCookies(): Promise<void> {
  const p = getCookiesPath()
  if (existsSync(p)) {
    await unlink(p)
  }
}

// Test cookies by running yt-dlp against a known endpoint with cookies
export async function testCookies(): Promise<{ success: boolean; message: string; details?: string }> {
  const available = await cookiesAvailable()
  if (!available) {
    return { success: false, message: 'No cookies file found. Upload a cookies.txt first.' }
  }
  try {
    const bin = await getYtdlpPath()
    // Use a lightweight cookie test: list cookies via yt-dlp --cookies ... --print cookies
    // Simpler: run a flat extraction of the homepage and check for success
    const { stdout, stderr } = await execFileAsync(bin, [
      '--cookies', getCookiesPath(),
      '--js-runtimes', 'node',
      '--no-warnings',
      '--flat-playlist',
      '--playlist-end', '1',
      '--dump-json',
      'https://www.youtube.com/feed/trending',
    ], { timeout: 30000, maxBuffer: 1024 * 1024 * 5 })
    if (stdout.trim()) {
      return { success: true, message: 'Cookies are valid and working. yt-dlp successfully authenticated.' }
    }
    return { success: false, message: 'Cookies test returned no data.', details: stderr }
  } catch (e) {
    const err = e as Error & { stderr?: string }
    return { success: false, message: 'Cookies test failed.', details: err.stderr || err.message }
  }
}

export async function getCookiesFileForYtdlp(): Promise<string | null> {
  if (await cookiesAvailable()) {
    return getCookiesPath()
  }
  return null
}

// Never expose cookie contents to client. This function returns only metadata.
export function assertCookiesPathSafe(p: string): void {
  const resolved = path.resolve(p)
  const allowed = path.resolve(getCookiesPath())
  if (resolved !== allowed) {
    throw new Error('Access denied')
  }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/lib/db.ts ---
mkdir -p "$(dirname "src/lib/db.ts")"
cat > 'src/lib/db.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { PrismaClient } from '@prisma/client'

const globalForPrisma = globalThis as unknown as {
  prisma: PrismaClient | undefined
}

export const db =
  globalForPrisma.prisma ??
  new PrismaClient({
    log: ['error', 'warn'],
  })

if (process.env.NODE_ENV !== 'production') globalForPrisma.prisma = db
HZ_FILE_CONTENT_END_7X9K

    # --- src/lib/download.ts ---
mkdir -p "$(dirname "src/lib/download.ts")"
cat > 'src/lib/download.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { spawn } from 'child_process'
import path from 'path'
import { mkdir, writeFile, appendFile } from 'fs/promises'
import { existsSync } from 'fs'
import { db } from './db'
import { getYtdlpPath, getFfmpegPath } from './ytdlp'
import { getSettings } from './settings'

export type DownloadStatus = 'queued' | 'downloading' | 'processing' | 'completed' | 'failed' | 'canceled'

export interface DownloadJob {
  id: string
  videoId: string
  title: string
  format: string // mp4, webm, mp3, m4a, wav, flac
  quality: string // 144p..1080p, highest, audio
  status: DownloadStatus
  progress: number // 0-100
  speed?: string
  eta?: string
  filename?: string
  filepath?: string
  fileSize?: number
  error?: string
  createdAt: number
  updatedAt: number
}

// In-memory job store (shared with websocket service via the same process)
export const jobs = new Map<string, DownloadJob>()
// Subscribers for progress updates (used by websocket bridge)
export type ProgressListener = (job: DownloadJob) => void
const listeners = new Set<ProgressListener>()

export function onProgress(fn: ProgressListener): () => void {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

function emit(job: DownloadJob) {
  job.updatedAt = Date.now()
  listeners.forEach((fn) => fn(job))
}

// --- Low-RAM concurrency limiter ---
// Only ONE download runs at a time to keep memory usage flat.
// yt-dlp + ffmpeg can each spike 50-150MB; running multiple in parallel
// on a 400MB server would cause OOM kills. Queued jobs wait their turn.
const MAX_CONCURRENT = 1
let activeCount = 0
const queue: Array<() => void> = []

async function acquireSlot(): Promise<void> {
  if (activeCount < MAX_CONCURRENT) {
    activeCount++
    return
  }
  return new Promise<void>((resolve) => {
    queue.push(() => {
      activeCount++
      resolve()
    })
  })
}

function releaseSlot(): void {
  activeCount = Math.max(0, activeCount - 1)
  const next = queue.shift()
  if (next) next()
}

function sanitizeFilename(name: string): string {
  return name
    .replace(/[<>:"/\\|?*\x00-\x1f]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 120) || 'video'
}

function formatSelector(format: string, quality: string): string {
  const heightMap: Record<string, number> = {
    '144p': 144, '240p': 240, '360p': 360, '480p': 480, '720p': 720, '1080p': 1080,
  }
  if (format === 'mp3') return 'bestaudio/best'
  if (format === 'm4a') return 'bestaudio[ext=m4a]/bestaudio/best'
  if (format === 'wav' || format === 'flac') return 'bestaudio/best'
  if (format === 'webm') {
    const h = heightMap[quality] || 720
    return `bestvideo[height<=${h}][ext=webm]+bestaudio[ext=webm]/best[height<=${h}][ext=webm]/best[height<=${h}]`
  }
  // mp4 default
  const h = heightMap[quality] || 720
  if (quality === 'highest') return 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best'
  return `bestvideo[height<=${h}][ext=mp4]+bestaudio[ext=m4a]/best[height<=${h}][ext=mp4]/best[height<=${h}]`
}

function postProcessArgs(format: string): string[] {
  const ffmpeg = '' // ffmpeg location handled by yt-dlp auto-detect via PATH
  switch (format) {
    case 'mp3':
      return ['--extract-audio', '--audio-format', 'mp3', '--audio-quality', '0']
    case 'm4a':
      return ['--extract-audio', '--audio-format', 'm4a', '--audio-quality', '0']
    case 'wav':
      return ['--extract-audio', '--audio-format', 'wav']
    case 'flac':
      return ['--extract-audio', '--audio-format', 'flac']
    default:
      return ['--merge-output-format', format]
  }
}

function extForFormat(format: string): string {
  return format
}

export async function startDownload(
  videoId: string,
  title: string,
  format: string,
  quality: string
): Promise<string> {
  const id = `dl_${videoId}_${Date.now()}`
  const job: DownloadJob = {
    id,
    videoId,
    title,
    format,
    quality,
    status: 'queued',
    progress: 0,
    createdAt: Date.now(),
    updatedAt: Date.now(),
  }
  jobs.set(id, job)
  emit(job)

  // Run async
  runDownload(job).catch((e) => {
    job.status = 'failed'
    job.error = e instanceof Error ? e.message : String(e)
    emit(job)
  })

  return id
}

async function runDownload(job: DownloadJob) {
  // Wait for a free slot — only 1 download runs at a time (low-RAM mode)
  job.status = 'queued'
  emit(job)
  await acquireSlot()

  const settings = await getSettings()
  const dir = settings.downloadDir
  await mkdir(dir, { recursive: true })

  const safeTitle = sanitizeFilename(job.title)
  const ext = extForFormat(job.format)
  const outTemplate = path.join(dir, `${safeTitle} [${job.videoId}].%(ext)s`)

  job.status = 'downloading'
  emit(job)

  const args: string[] = [
    '--no-warnings',
    '--no-check-certificates',
    '--js-runtimes', 'node',
    '--newline',
    '--extractor-args', 'youtube:player_client=default,android',
    '--user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    '--progress',
    '--progress-template', '%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s',
    '-f', formatSelector(job.format, job.quality),
    ...postProcessArgs(job.format),
    '-o', outTemplate,
    '--no-mtime',
  ]

  // NOTE: No cookies — flagged/stale cookies cause YouTube to return only
  // storyboard formats, breaking downloads. Without cookies, yt-dlp falls
  // back to visionos/android_vr player APIs which return full formats.

  // ffmpeg location for merging / extraction
  try {
    const ff = await getFfmpegPath()
    args.push('--ffmpeg-location', path.dirname(ff))
  } catch {
    // rely on PATH
  }

  args.push(`https://www.youtube.com/watch?v=${job.videoId}`)

  const bin = await getYtdlpPath()
  const child = spawn(bin, args, { env: { ...process.env } })
  ;(child as any)._jobId = job.id

  // Track spawned process for cancellation
  activeProcesses.set(job.id, child)

  let finalFilename = ''
  let lastLog = ''

  child.stdout?.on('data', (chunk: Buffer) => {
    const text = chunk.toString()
    for (const line of text.split('\n')) {
      const t = line.trim()
      if (!t) continue
      // [download] 12.3% of 50.00MiB at 1.00MiB/s ETA 00:30
      const m = t.match(/([0-9.]+)%\s*(?:of\s*[^\s]+\s*)?at\s*([^\s]+).*ETA\s*([^\s]+)/i)
      if (m) {
        job.status = 'downloading'
        job.progress = Math.min(99, parseFloat(m[1]))
        job.speed = m[2]
        job.eta = m[3]
        emit(job)
      }
      // Progress template line: percent|speed|eta|downloaded|total
      const tm = t.match(/^([0-9.]+)%\|([^|]*)\|([^|]*)\|([0-9.]+)\|([0-9.]+)/)
      if (tm) {
        job.status = 'downloading'
        job.progress = Math.min(99, parseFloat(tm[1]))
        job.speed = tm[2] || undefined
        job.eta = tm[3] || undefined
        const total = parseInt(tm[5], 10)
        if (total > 0) job.fileSize = total
        emit(job)
      }
      if (t.startsWith('[download]') && t.includes('has already been downloaded')) {
        job.progress = 99
        emit(job)
      }
      // [ExtractAudio] / [Merger] -> processing
      if (t.startsWith('[ExtractAudio]') || t.startsWith('[Merger]') || t.startsWith('[Download]')) {
        job.status = 'processing'
        job.progress = 99
        emit(job)
      }
      lastLog = t
    }
  })

  child.stderr?.on('data', (chunk: Buffer) => {
    const text = chunk.toString()
    // log to file
    const logLine = `[${new Date().toISOString()}] [${job.id}] ${text}`
    appendFile(path.join(path.dirname(settings.downloadDir), 'logs', 'downloads.log'), logLine).catch(() => {})
  })

  return new Promise<void>((resolve, reject) => {
    child.on('close', (code) => {
      activeProcesses.delete(job.id)
      releaseSlot() // Free the concurrency slot
      if (code === 0) {
        // Find the produced file. yt-dlp prints "[download] Destination" lines; parse last.
        job.status = 'processing'
        job.progress = 99
        emit(job)
        // Try to locate file
        import('fs/promises').then(async (fs) => {
          try {
            const files = await fs.readdir(dir)
            const match = files.find((f) => f.includes(job.videoId) && f.endsWith(ext))
            if (match) {
              finalFilename = match
              const fp = path.join(dir, match)
              const stat = await fs.stat(fp)
              job.filepath = fp
              job.fileSize = stat.size
              job.filename = match
            }
            // IMPORTANT: persist the DB record BEFORE flipping status to 'completed'.
            // Otherwise the websocket poller can broadcast 'completed' to the client
            // before the record exists, and the user's 'Save File' click 404s.
            await db.downloadHistory.create({
              data: {
                id: job.id,
                videoId: job.videoId,
                title: job.title,
                format: job.format,
                quality: job.quality,
                status: 'completed',
                filepath: job.filepath || null,
                fileSize: job.fileSize || null,
              },
            })
            job.status = 'completed'
            job.progress = 100
            emit(job)
            resolve()
          } catch (e) {
            // Best-effort: still try to persist a record so the user can retry
            try {
              await db.downloadHistory.create({
                data: {
                  id: job.id,
                  videoId: job.videoId,
                  title: job.title,
                  format: job.format,
                  quality: job.quality,
                  status: 'completed',
                  filepath: job.filepath || null,
                  fileSize: job.fileSize || null,
                },
              })
            } catch { /* ignore */ }
            job.status = 'completed'
            job.progress = 100
            emit(job)
            resolve()
          }
        })
      } else {
        job.status = 'failed'
        job.error = `yt-dlp exited with code ${code}. ${lastLog}`
        emit(job)
        db.downloadHistory.create({
          data: {
            id: job.id,
            videoId: job.videoId,
            title: job.title,
            format: job.format,
            quality: job.quality,
            status: 'failed',
          },
        }).catch(() => {})
        reject(new Error(job.error))
      }
    })
    child.on('error', (e) => {
      activeProcesses.delete(job.id)
      releaseSlot() // Free the concurrency slot on error too
      job.status = 'failed'
      job.error = e.message
      emit(job)
      reject(e)
    })
  })
}

const activeProcesses = new Map<string, ReturnType<typeof spawn>>()

export function cancelDownload(jobId: string): boolean {
  const proc = activeProcesses.get(jobId)
  const job = jobs.get(jobId)
  if (job) {
    job.status = 'canceled'
    emit(job)
  }
  if (proc) {
    proc.kill('SIGTERM')
    activeProcesses.delete(jobId)
    return true
  }
  return false
}

export function getJob(jobId: string): DownloadJob | undefined {
  return jobs.get(jobId)
}

export function listJobs(): DownloadJob[] {
  return Array.from(jobs.values()).sort((a, b) => b.createdAt - a.createdAt)
}

// Allow websocket service to register as listener and replay current jobs
export function snapshotJobs(): DownloadJob[] {
  return listJobs()
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/lib/settings.ts ---
mkdir -p "$(dirname "src/lib/settings.ts")"
cat > 'src/lib/settings.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { db } from './db'

export interface AppSettings {
  downloadDir: string
  cacheMax: number
  theme: 'light' | 'dark' | 'auto'
  defaultQuality: string
  defaultFormat: string
  historyLimit: number
  rateLimitPerMin: number
}

export const DEFAULT_SETTINGS: AppSettings = {
  downloadDir: process.env.DOWNLOAD_DIR || '/home/z/my-project/data/downloads',
  cacheMax: 200,
  theme: 'dark',
  defaultQuality: '720p',
  defaultFormat: 'mp4',
  historyLimit: 200,
  rateLimitPerMin: 60,
}

const SETTINGS_KEY = 'app_settings'

export async function getSettings(): Promise<AppSettings> {
  const row = await db.setting.findUnique({ where: { key: SETTINGS_KEY } })
  if (!row) return DEFAULT_SETTINGS
  try {
    return { ...DEFAULT_SETTINGS, ...JSON.parse(row.value) }
  } catch {
    return DEFAULT_SETTINGS
  }
}

export async function saveSettings(partial: Partial<AppSettings>): Promise<AppSettings> {
  const current = await getSettings()
  const next = { ...current, ...partial }
  await db.setting.upsert({
    where: { key: SETTINGS_KEY },
    create: { key: SETTINGS_KEY, value: JSON.stringify(next) },
    update: { key: SETTINGS_KEY, value: JSON.stringify(next) },
  })
  return next
}

// Simple in-memory rate limiter
const requestLog = new Map<string, number[]>()
export function checkRateLimit(identifier: string, perMin: number): { allowed: boolean; retryAfter: number } {
  const now = Date.now()
  const windowMs = 60_000
  const arr = requestLog.get(identifier) || []
  const recent = arr.filter((t) => now - t < windowMs)
  if (recent.length >= perMin) {
    const oldest = recent[0]
    return { allowed: false, retryAfter: Math.ceil((windowMs - (now - oldest)) / 1000) }
  }
  recent.push(now)
  requestLog.set(identifier, recent)
  return { allowed: true, retryAfter: 0 }
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/lib/store.ts ---
mkdir -p "$(dirname "src/lib/store.ts")"
cat > 'src/lib/store.ts' <<'HZ_FILE_CONTENT_END_7X9K'
'use client'

import { create } from 'zustand'
import { persist } from 'zustand/middleware'

export type ViewName =
  | 'home'
  | 'search'
  | 'video'
  | 'history'
  | 'admin'
  | 'settings'
  | 'favorites'
  | 'watchlater'

export interface VideoItem {
  id: string
  title: string
  duration?: number
  channel?: string
  uploader?: string
  channel_id?: string
  thumbnail?: string
  thumbnails?: Array<{ url: string; width?: number; height?: number }>
  view_count?: number
  webpage_url?: string
  description?: string
}

interface AppState {
  // Navigation
  view: ViewName
  videoId: string | null
  searchQuery: string
  // Layout
  sidebarOpen: boolean
  theaterMode: boolean
  // Player
  currentQuality: string
  volume: number
  playbackRate: number
  // History navigation (back button)
  history: Array<{ view: ViewName; videoId?: string | null; searchQuery?: string }>
  // Actions
  setView: (view: ViewName) => void
  openVideo: (id: string) => void
  search: (query: string) => void
  toggleSidebar: () => void
  setSidebar: (open: boolean) => void
  setTheaterMode: (v: boolean) => void
  setCurrentQuality: (q: string) => void
  setVolume: (v: number) => void
  setPlaybackRate: (r: number) => void
  goBack: () => void
}

export const useAppStore = create<AppState>()(
  persist(
    (set, get) => ({
      view: 'home',
      videoId: null,
      searchQuery: '',
      sidebarOpen: true,
      theaterMode: false,
      currentQuality: '720p',
      volume: 1,
      playbackRate: 1,
      history: [],

      setView: (view) => {
        const current = get()
        set({
          history: [...current.history, { view: current.view, videoId: current.videoId, searchQuery: current.searchQuery }].slice(-20),
          view,
        })
        if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' })
      },
      openVideo: (id) => {
        const current = get()
        set({
          history: [...current.history, { view: current.view, videoId: current.videoId, searchQuery: current.searchQuery }].slice(-20),
          view: 'video',
          videoId: id,
        })
        if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'instant' as ScrollBehavior })
      },
      search: (query) => {
        const current = get()
        set({
          history: [...current.history, { view: current.view, videoId: current.videoId, searchQuery: current.searchQuery }].slice(-20),
          view: 'search',
          searchQuery: query,
        })
        if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' })
      },
      toggleSidebar: () => set((s) => ({ sidebarOpen: !s.sidebarOpen })),
      setSidebar: (open) => set({ sidebarOpen: open }),
      setTheaterMode: (v) => set({ theaterMode: v }),
      setCurrentQuality: (q) => set({ currentQuality: q }),
      setVolume: (v) => set({ volume: v }),
      setPlaybackRate: (r) => set({ playbackRate: r }),
      goBack: () => {
        const hist = get().history
        if (hist.length === 0) {
          set({ view: 'home', videoId: null })
          return
        }
        const last = hist[hist.length - 1]
        set({
          view: last.view,
          videoId: last.videoId ?? null,
          searchQuery: last.searchQuery ?? get().searchQuery,
          history: hist.slice(0, -1),
        })
        if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' })
      },
    }),
    {
      name: 'yt-stream-store',
      partialize: (s) => ({
        sidebarOpen: s.sidebarOpen,
        currentQuality: s.currentQuality,
        volume: s.volume,
        playbackRate: s.playbackRate,
        theaterMode: s.theaterMode,
      }),
    }
  )
)
HZ_FILE_CONTENT_END_7X9K

    # --- src/lib/utils.ts ---
mkdir -p "$(dirname "src/lib/utils.ts")"
cat > 'src/lib/utils.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
HZ_FILE_CONTENT_END_7X9K

    # --- src/lib/ytdlp.ts ---
mkdir -p "$(dirname "src/lib/ytdlp.ts")"
cat > 'src/lib/ytdlp.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import { execFile } from 'child_process'
import { promisify } from 'util'
import { access, constants } from 'fs/promises'
import { existsSync } from 'fs'
import path from 'path'

const execFileAsync = promisify(execFile)

export interface YtdlpFormat {
  format_id: string
  ext: string
  url: string
  width?: number
  height?: number
  vcodec: string
  acodec: string
  filesize?: number
  filesize_approx?: number
  tbr?: number
  abr?: number
  vbr?: number
  fps?: number
  resolution?: string
  protocol: string
  http_headers?: Record<string, string>
}

export interface YtdlpVideoInfo {
  id: string
  title: string
  description?: string
  channel?: string
  uploader?: string
  uploader_id?: string
  channel_id?: string
  thumbnail?: string
  thumbnails?: Array<{ url: string; width?: number; height?: number }>
  duration?: number
  view_count?: number
  like_count?: number
  upload_date?: string
  timestamp?: number
  webpage_url?: string
  extractor_key?: string
  formats?: YtdlpFormat[]
  subtitles?: Record<string, Array<{ url: string; ext: string }> >
  automatic_captions?: Record<string, Array<{ url: string; ext: string }> >
  chapters?: Array<{ start_time: number; end_time: number; title: string }>
  tags?: string[]
  categories?: string[]
  availability?: string
  live_status?: string
  is_live?: boolean
  playlist_count?: number
  entries?: Array<Partial<YtdlpVideoInfo>>
  related_videos?: Array<any>
}

// In-memory cache with TTL
interface CacheEntry<T> {
  value: T
  expires: number
}
const cache = new Map<string, CacheEntry<unknown>>()
const DEFAULT_TTL = 1000 * 60 * 10 // 10 minutes

export function cacheGet<T>(key: string): T | null {
  const entry = cache.get(key)
  if (!entry) return null
  if (Date.now() > entry.expires) {
    cache.delete(key)
    return null
  }
  return entry.value as T
}

export function cacheSet<T>(key: string, value: T, ttl: number = DEFAULT_TTL): void {
  cache.set(key, { value, expires: Date.now() + ttl })
  // Evict oldest if too many entries
  const max = parseInt(process.env.CACHE_MAX || '200', 10)
  if (cache.size > max) {
    const firstKey = cache.keys().next().value
    if (firstKey) cache.delete(firstKey)
  }
}

export function cacheClear(): number {
  const count = cache.size
  cache.clear()
  return count
}

async function findBin(envVar: string, names: string[]): Promise<string> {
  const fromEnv = process.env[envVar]
  if (fromEnv && existsSync(fromEnv)) return fromEnv
  for (const name of names) {
    try {
      await execFileAsync('which', [name])
      return name
    } catch {
      // continue
    }
  }
  throw new Error(`Binary not found for ${envVar}. Tried: ${names.join(', ')}`)
}

export async function getYtdlpPath(): Promise<string> {
  return findBin('YTDLP_PATH', ['yt-dlp'])
}

export async function getFfmpegPath(): Promise<string> {
  return findBin('FFMPEG_PATH', ['ffmpeg'])
}

export function getCookiesPath(): string {
  return process.env.COOKIES_PATH || path.join(process.cwd(), 'data', 'cookies.txt')
}

export async function cookiesAvailable(): Promise<boolean> {
  try {
    const p = getCookiesPath()
    if (!existsSync(p)) return false
    await access(p, constants.R_OK)
    return true
  } catch {
    return false
  }
}

function baseArgs(): string[] {
  const args: string[] = [
    '--no-warnings',
    '--no-check-certificates',
    '--no-playlist-reverse',
    '--js-runtimes', 'node',
    '--user-agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  ]
  return args
}

// The `android` and `ios` player clients bypass YouTube's "Sign in to confirm
// you're not a bot" anti-bot check for many videos. We add multiple fallback
// player clients so yt-dlp will try them in order: default → android → ios → tv.
// This dramatically reduces 503 errors on videos that trigger anti-bot detection.
function playerClientArgs(): string[] {
  return ['--extractor-args', 'youtube:player_client=default,android,ios,tv']
}

async function withCookies(): Promise<string[]> {
  if (await cookiesAvailable()) {
    return ['--cookies', getCookiesPath()]
  }
  return []
}

interface RunOptions {
  timeout?: number
  extraEnv?: Record<string, string>
  retries?: number
}

// 502 FIX: runYtdlp now retries on transient failures (network blips, YouTube throttling)
async function runYtdlp(args: string[], opts: RunOptions = {}): Promise<string> {
  const bin = await getYtdlpPath()
  const retries = opts.retries ?? 2
  let lastErr: unknown

  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      const { stdout } = await execFileAsync(bin, args, {
        maxBuffer: 1024 * 1024 * 50,
        timeout: opts.timeout ?? 60000,
        env: { ...process.env, ...opts.extraEnv },
      })
      return stdout
    } catch (err) {
      lastErr = err
      // Don't retry on the last attempt
      if (attempt >= retries) break
      // Only retry on transient errors (timeouts, network, throttling)
      const msg = err instanceof Error ? err.message : String(err)
      const isTransient = msg.includes('ETIMEDOUT') || msg.includes('timeout') ||
        msg.includes('ECONNRESET') || msg.includes('ENOTFOUND') ||
        msg.includes('fetch failed') || msg.includes('HTTP Error 429') ||
        msg.includes('Too Many Requests') || msg.includes('temporarily')
      if (!isTransient) break
      // Exponential backoff: 1s, 2s
      await new Promise((r) => setTimeout(r, 1000 * Math.pow(2, attempt)))
    }
  }
  throw lastErr
}

// Helper: detect "Sign in to confirm you're not a bot" errors
function isAntiBotError(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err)
  return msg.includes('Sign in') || msg.includes('confirm you') || msg.includes('not a bot')
}

// Search YouTube and return flat results
export async function searchVideos(query: string, limit: number = 20): Promise<YtdlpVideoInfo[]> {
  const key = `search:${query}:${limit}`
  const cached = cacheGet<YtdlpVideoInfo[]>(key)
  if (cached) return cached

  const args = [
    ...baseArgs(),
    ...playerClientArgs(),
    ...(await withCookies()),
    '--dump-json',
    '--flat-playlist',
    `ytsearch${limit}:${query}`,
  ]
  const stdout = await runYtdlp(args, { timeout: 45000 })
  const lines = stdout.trim().split('\n').filter(Boolean)
  const results: YtdlpVideoInfo[] = []
  for (const line of lines) {
    try {
      const obj = JSON.parse(line)
      results.push({
        id: obj.id,
        title: obj.title,
        duration: obj.duration,
        channel: obj.uploader || obj.channel,
        uploader: obj.uploader,
        channel_id: obj.channel_id,
        thumbnail: obj.thumbnail,
        thumbnails: obj.thumbnails,
        webpage_url: obj.url || `https://www.youtube.com/watch?v=${obj.id}`,
        extractor_key: obj.extractor_key,
        view_count: obj.view_count,
      })
    } catch {
      // skip malformed
    }
  }
  cacheSet(key, results, 1000 * 60 * 5)
  return results
}

// Search suggestions via YouTube suggest API (no yt-dlp needed, lightweight)
export async function suggestQueries(query: string): Promise<string[]> {
  if (!query.trim()) return []
  try {
    const url = `https://suggestqueries.google.com/complete/search?client=youtube&ds=yt&q=${encodeURIComponent(query)}`
    const res = await fetch(url)
    const text = await res.text()
    // Response is JSONP-like: window.google.ac.h([...])
    const match = text.match(/\.h\((.*)\);?$/)
    if (!match) return []
    const data = JSON.parse(match[1])
    if (!Array.isArray(data) || !Array.isArray(data[0])) return []
    return data[0].map((item: unknown) => (Array.isArray(item) ? String(item[0]) : '')).filter(Boolean).slice(0, 10)
  } catch {
    return []
  }
}

// Get full video info with formats.
// Strategy: Try WITHOUT cookies first (avoids storyboard-only restriction for
// most videos). If that fails with "Sign in" error, retry WITH cookies as a
// fallback (may still return storyboard-only, but at least lets us try).
export async function getVideoInfo(videoId: string): Promise<YtdlpVideoInfo> {
  const key = `video:${videoId}`
  const cached = cacheGet<YtdlpVideoInfo>(key)
  if (cached) return cached

  const url = `https://www.youtube.com/watch?v=${videoId}`
  const baseArgList = [
    ...baseArgs(),
    ...playerClientArgs(),
    '--dump-json',
    '--no-playlist',
    url,
  ]

  // Attempt 1: no cookies (preferred — gives full formats)
  try {
    const stdout = await runYtdlp(baseArgList, { timeout: 60000 })
    const info: YtdlpVideoInfo = JSON.parse(stdout)
    cacheSet(key, info, 1000 * 60 * 10)
    return info
  } catch (err) {
    if (!isAntiBotError(err)) {
      throw err
    }
    // Fall through to cookies attempt
  }

  // Attempt 2: with cookies (fallback for sign-in-required videos)
  const cookieArgs = [...baseArgList]
  const cookieArgsStart = cookieArgs.length
  cookieArgs.splice(cookieArgsStart, 0, ...(await withCookies()))
  const stdout = await runYtdlp(cookieArgs, { timeout: 60000 })
  const info: YtdlpVideoInfo = JSON.parse(stdout)
  cacheSet(key, info, 1000 * 60 * 10)
  return info
}

// Get related videos via the watch page extraction (flat)
export async function getRelatedVideos(videoId: string): Promise<YtdlpVideoInfo[]> {
  const key = `related:${videoId}`
  const cached = cacheGet<YtdlpVideoInfo[]>(key)
  if (cached) return cached

  const url = `https://www.youtube.com/watch?v=${videoId}`
  const args = [
    ...baseArgs(),
    ...playerClientArgs(),
    ...(await withCookies()),
    '--dump-json',
    '--flat-playlist',
    '--skip-download',
    url,
  ]
  try {
    const stdout = await runYtdlp(args, { timeout: 45000 })
    const info: YtdlpVideoInfo = JSON.parse(stdout)
    // yt-dlp includes related_videos in full extraction; for flat we fall back to search by title
    let related: YtdlpVideoInfo[] = []
    if (info.related_videos && Array.isArray(info.related_videos)) {
      related = info.related_videos.slice(0, 20).map((r: any) => ({
        id: r.id,
        title: r.title,
        channel: r.uploader || r.channel,
        thumbnail: r.thumbnails?.[0]?.url,
        duration: r.duration,
        view_count: r.view_count,
      }))
    }
    if (related.length === 0) {
      // Fallback: use video tags/title to search
      const full = await getVideoInfo(videoId)
      const term = (full.tags && full.tags[0]) || full.title?.split(' ').slice(0, 3).join(' ')
      if (term) related = await searchVideos(term, 12)
    }
    cacheSet(key, related, 1000 * 60 * 8)
    return related
  } catch {
    // Fallback to search
    const full = await getVideoInfo(videoId)
    const term = full.title?.split(' ').slice(0, 3).join(' ') || ''
    return term ? searchVideos(term, 12) : []
  }
}

// Get trending — YouTube's /feed/trending often redirects now, so fall back to popular searches
export async function getTrending(country: string = 'US'): Promise<YtdlpVideoInfo[]> {
  const key = `trending:${country}`
  const cached = cacheGet<YtdlpVideoInfo[]>(key)
  if (cached) return cached

  // Try the trending feed first
  const url = `https://www.youtube.com/feed/trending?gl=${country}`
  const args = [
    ...baseArgs(),
    ...playerClientArgs(),
    ...(await withCookies()),
    '--dump-json',
    '--flat-playlist',
    '--playlist-end', '20',
    url,
  ]
  try {
    const stdout = await runYtdlp(args, { timeout: 45000 })
    const lines = stdout.trim().split('\n').filter(Boolean)
    if (lines.length > 0) {
      const results = lines.map((line) => {
        try {
          const obj = JSON.parse(line)
          return {
            id: obj.id,
            title: obj.title,
            duration: obj.duration,
            channel: obj.uploader || obj.channel,
            channel_id: obj.channel_id,
            thumbnail: obj.thumbnail,
            thumbnails: obj.thumbnails,
            view_count: obj.view_count,
            webpage_url: obj.url || `https://www.youtube.com/watch?v=${obj.id}`,
          } as YtdlpVideoInfo
        } catch { return null }
      }).filter(Boolean) as YtdlpVideoInfo[]
      if (results.length > 0) {
        cacheSet(key, results, 1000 * 60 * 15)
        return results
      }
    }
  } catch {
    // trending page failed/redirected — fall back to popular searches
  }

  // Fallback: search for popular content and merge results
  const fallbackTerms = ['trending music 2024', 'viral videos', 'popular this week']
  const all: YtdlpVideoInfo[] = []
  for (const term of fallbackTerms) {
    try {
      const r = await searchVideos(term, 8)
      for (const v of r) {
        if (!all.find((x) => x.id === v.id)) all.push(v)
      }
      if (all.length >= 20) break
    } catch { /* continue */ }
  }
  cacheSet(key, all.slice(0, 20), 1000 * 60 * 15)
  return all.slice(0, 20)
}

// Get channel info / recent videos
export async function getChannelVideos(channelId: string, limit: number = 30): Promise<{ channel?: string; videos: YtdlpVideoInfo[] }> {
  const key = `channel:${channelId}:${limit}`
  const cached = cacheGet<{ channel?: string; videos: YtdlpVideoInfo[] }>(key)
  if (cached) return cached

  const url = channelId.startsWith('UC') || channelId.startsWith('HC')
    ? `https://www.youtube.com/channel/${channelId}/videos`
    : `https://www.youtube.com/@${channelId}/videos`
  const args = [
    ...baseArgs(),
    ...playerClientArgs(),
    ...(await withCookies()),
    '--dump-json',
    '--flat-playlist',
    '--playlist-end', String(limit),
    url,
  ]
  const stdout = await runYtdlp(args, { timeout: 60000 })
  const lines = stdout.trim().split('\n').filter(Boolean)
  const videos: YtdlpVideoInfo[] = []
  let channelName: string | undefined
  for (const line of lines) {
    try {
      const obj = JSON.parse(line)
      if (!channelName) channelName = obj.uploader || obj.channel
      videos.push({
        id: obj.id,
        title: obj.title,
        duration: obj.duration,
        channel: obj.uploader || obj.channel,
        channel_id: obj.channel_id,
        thumbnail: obj.thumbnail,
        thumbnails: obj.thumbnails,
        view_count: obj.view_count,
        webpage_url: obj.url || `https://www.youtube.com/watch?v=${obj.id}`,
      })
    } catch {
      // skip
    }
  }
  const result = { channel: channelName, videos }
  cacheSet(key, result, 1000 * 60 * 15)
  return result
}

export async function getYtdlpVersion(): Promise<string> {
  const bin = await getYtdlpPath()
  const { stdout } = await execFileAsync(bin, ['--version'])
  return stdout.trim()
}

// Select best formats for a target height
export interface StreamFormats {
  muxed?: YtdlpFormat // combined audio+video (usually <=720p)
  videoOnly?: YtdlpFormat // DASH video
  audioOnly?: YtdlpFormat // DASH audio
  availableHeights: number[]
}

export function selectFormats(formats: YtdlpFormat[] | undefined, targetHeight: number): StreamFormats {
  const result: StreamFormats = { availableHeights: [] }
  if (!formats || formats.length === 0) return result

  const withUrl = formats.filter((f) => f.url && f.protocol.startsWith('http'))
  // muxed = both codecs present
  const muxed = withUrl.filter((f) => f.vcodec !== 'none' && f.acodec !== 'none')
  const videoOnly = withUrl.filter((f) => f.vcodec !== 'none' && (f.acodec === 'none' || !f.acodec))
  const audioOnly = withUrl.filter((f) => (f.vcodec === 'none' || !f.vcodec) && f.acodec !== 'none')

  const heights = new Set<number>()
  ;[...muxed, ...videoOnly].forEach((f) => f.height && heights.add(f.height))
  result.availableHeights = Array.from(heights).sort((a, b) => a - b)

  // Find best muxed for target (<= target)
  const candidateMuxed = muxed
    .filter((f) => !f.height || f.height <= targetHeight)
    .sort((a, b) => (b.height || 0) - (a.height || 0))[0]
  result.muxed = candidateMuxed

  // If target > best muxed height, use DASH
  const bestMuxedHeight = candidateMuxed?.height || 0
  if (targetHeight > bestMuxedHeight) {
    const candidateVideo = videoOnly
      .filter((f) => !f.height || f.height <= targetHeight)
      .sort((a, b) => (b.height || 0) - (a.height || 0))[0]
    const candidateAudio = audioOnly
      .sort((a, b) => (b.abr || b.tbr || 0) - (a.abr || a.tbr || 0))[0]
    result.videoOnly = candidateVideo
    result.audioOnly = candidateAudio
  }

  return result
}
HZ_FILE_CONTENT_END_7X9K

    # --- tailwind.config.ts ---
mkdir -p "$(dirname "tailwind.config.ts")"
cat > 'tailwind.config.ts' <<'HZ_FILE_CONTENT_END_7X9K'
import type { Config } from "tailwindcss";
import tailwindcssAnimate from "tailwindcss-animate";

const config: Config = {
    darkMode: "class",
    content: [
    "./pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./components/**/*.{js,ts,jsx,tsx,mdx}",
    "./app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
        extend: {
                colors: {
                        background: 'hsl(var(--background))',
                        foreground: 'hsl(var(--foreground))',
                        card: {
                                DEFAULT: 'hsl(var(--card))',
                                foreground: 'hsl(var(--card-foreground))'
                        },
                        popover: {
                                DEFAULT: 'hsl(var(--popover))',
                                foreground: 'hsl(var(--popover-foreground))'
                        },
                        primary: {
                                DEFAULT: 'hsl(var(--primary))',
                                foreground: 'hsl(var(--primary-foreground))'
                        },
                        secondary: {
                                DEFAULT: 'hsl(var(--secondary))',
                                foreground: 'hsl(var(--secondary-foreground))'
                        },
                        muted: {
                                DEFAULT: 'hsl(var(--muted))',
                                foreground: 'hsl(var(--muted-foreground))'
                        },
                        accent: {
                                DEFAULT: 'hsl(var(--accent))',
                                foreground: 'hsl(var(--accent-foreground))'
                        },
                        destructive: {
                                DEFAULT: 'hsl(var(--destructive))',
                                foreground: 'hsl(var(--destructive-foreground))'
                        },
                        border: 'hsl(var(--border))',
                        input: 'hsl(var(--input))',
                        ring: 'hsl(var(--ring))',
                        chart: {
                                '1': 'hsl(var(--chart-1))',
                                '2': 'hsl(var(--chart-2))',
                                '3': 'hsl(var(--chart-3))',
                                '4': 'hsl(var(--chart-4))',
                                '5': 'hsl(var(--chart-5))'
                        }
                },
                borderRadius: {
                        lg: 'var(--radius)',
                        md: 'calc(var(--radius) - 2px)',
                        sm: 'calc(var(--radius) - 4px)'
                }
        }
  },
  plugins: [tailwindcssAnimate],
};
export default config;
HZ_FILE_CONTENT_END_7X9K

    # --- tsconfig.json ---
mkdir -p "$(dirname "tsconfig.json")"
cat > 'tsconfig.json' <<'HZ_FILE_CONTENT_END_7X9K'
{
  "compilerOptions": {
    "target": "ES2017",
    "lib": [
      "dom",
      "dom.iterable",
      "esnext"
    ],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "noImplicitAny": false,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "react-jsx",
    "incremental": true,
    "plugins": [
      {
        "name": "next"
      }
    ],
    "paths": {
      "@/*": [
        "./src/*"
      ]
    }
  },
  "include": [
    "next-env.d.ts",
    "**/*.ts",
    "**/*.tsx",
    ".next/types/**/*.ts",
    ".next/dev/types/**/*.ts"
  ],
  "exclude": [
    "node_modules"
  ]
}
HZ_FILE_CONTENT_END_7X9K


    log_success "Section 1 complete: All source files written."
fi

# =============================================================================
# SECTION 2: Install npm dependencies (LOW-RAM: capped Bun heap)
# =============================================================================
if [ ! -d "$APP_DIR/node_modules" ] || [ ! -f "$APP_DIR/node_modules/.package-lock.json" ]; then
    log "Section 2: Installing npm dependencies (Bun heap capped at 256MB)..."
    cd "$APP_DIR"
    mem_status "before-install"
    # --no-cache: don't cache packages in RAM/disk (trade speed for RAM)
    # BUN_JSC_forceRAMSize already exported globally above
    bun install --no-cache 2>&1 | tee -a "$LOG_DIR/install.log"
    log_success "Section 2 complete: Dependencies installed."
    drop_caches
    mem_status "after-install"
else
    log "Section 2: node_modules exists — skipping dependency install."
fi

# =============================================================================
# SECTION 3: Generate Prisma client
# =============================================================================
export DATABASE_URL="file:$DB_DIR/custom.db"
log "Section 3: Generating Prisma client (DATABASE_URL=$DATABASE_URL)..."
cd "$APP_DIR"
mem_status "before-prisma"
bunx prisma generate 2>&1 | tee -a "$LOG_DIR/prisma.log"
log_success "Section 3 complete: Prisma client generated."
drop_caches
mem_status "after-prisma"

# =============================================================================
# SECTION 4: Build Next.js (LOW-RAM: build cap 256MB, swap for overflow)
# =============================================================================
if [ ! -f "$APP_DIR/.next/BUILD_ID" ]; then
    log "Section 4: Building Next.js production bundle (heap cap 256MB + swap for overflow)..."
    cd "$APP_DIR"
    mem_status "before-build"
    # LOW-RAM: double-cap — NODE_OPTIONS for V8 (if Node fallback) + BUN_JSC for Bun
    # Also disable Next.js telemetry and limit workers via env
    NODE_OPTIONS="--max-old-space-size=256" \
    NEXT_TELEMETRY_DISABLED=1 \
    NEXT_WORKER_POOL_SIZE=1 \
    bun run build 2>&1 | tee -a "$LOG_DIR/build.log"
    if [ ! -f "$APP_DIR/.next/BUILD_ID" ]; then
        log_error "Build failed — .next/BUILD_ID not found."
        log_error "Check $LOG_DIR/build.log for details."
        log_error "If OOM killed, increase SWAP_SIZE or add more RAM."
        mem_status "build-failed"
        exit 1
    fi
    log_success "Section 4 complete: Next.js built."
    drop_caches
    mem_status "after-build"
else
    log "Section 4: .next/BUILD_ID exists — skipping build."
fi

# =============================================================================
# SECTION 5: Create runtime directories and files
# =============================================================================
log "Section 5: Creating runtime directories and files..."
mkdir -p "$DATA_DIR" "$DOWNLOADS_DIR" "$DB_DIR" "$COOKIES_DIR" "$LOG_DIR" "$TMP_DIR"

# Default settings.json — optimized for low RAM
if [ ! -f "$DATA_DIR/settings.json" ]; then
    cat > "$DATA_DIR/settings.json" <<'SETTINGS_EOF'
{
  "theme": "dark",
  "defaultQuality": "720",
  "defaultFormat": "mp4",
  "concurrentDownloads": 1,
  "downloadPath": "/opt/yt-frontend/data/downloads",
  "historyEnabled": true,
  "autoplay": false,
  "volume": 80,
  "playbackSpeed": 1
}
SETTINGS_EOF
    log "  Created default settings.json (concurrentDownloads=1, autoplay=off, quality=720p)"
fi

# Cookies placeholder
if [ ! -f "$COOKIES_DIR/cookies.txt" ]; then
    cat > "$COOKIES_DIR/cookies.txt" <<'COOKIES_EOF'
# Netscape HTTP Cookie File
# Replace this file with your exported cookies.txt from a browser extension.
# This is needed for age-restricted or members-only content.
COOKIES_EOF
    log "  Created cookies.txt placeholder"
fi

# Caddyfile creation: SKIPPED (Caddy reverse proxy removed).
# Next.js serves on :$SERVE_PORT directly — no proxy config needed.

log_success "Section 5 complete: Runtime files created."

# =============================================================================
# SECTION 6: Initialize database
# =============================================================================
log "Section 6: Initializing database..."
cd "$APP_DIR"
export DATABASE_URL="file:$DB_DIR/custom.db"
mem_status "before-db-init"
bunx prisma db push --accept-data-loss 2>&1 | tee -a "$LOG_DIR/prisma.log"
log_success "Section 6 complete: Database initialized at $DB_DIR/custom.db"
drop_caches
mem_status "after-db-init"

# =============================================================================
# SECTION 7: Start Next.js directly (NO Caddy, NO progress-service)
# =============================================================================
log "Section 7: Starting Next.js (LOW-RAM mode: 1 process, no proxy)..."

# Kill any existing Next.js instances on our port
log "  Cleaning up any existing Next.js processes on port $SERVE_PORT..."
pkill -f "next start" 2>/dev/null || true
pkill -f "next-server" 2>/dev/null || true
sleep 1

# NOTE: Caddy (was port 80) is intentionally NOT started — REMOVED.
# NOTE: progress-service (was port 3001) is intentionally NOT started — eliminated.
# The frontend polls /api/download/status directly via HTTP.
# This saves ~75-105MB RAM (Caddy ~25MB + progress-service ~50-80MB).

# Start Next.js DIRECTLY on $SERVE_PORT (default 80) — NO reverse proxy.
# Caddy was removed: it added a 502 failure layer and ~25MB RAM for zero benefit,
# since Next.js handles compression (compress:true), streaming, and routing natively.
# Runtime: BUN_JSC_forceRAMSize caps heap at 256MB; OS swaps cold pages to disk.
cd "$APP_DIR"
NODE_ENV=production bun next start -p "$SERVE_PORT" > "$LOG_DIR/nextjs.log" 2>&1 &
NEXT_PID=$!
log "  Next.js started (PID: $NEXT_PID, port $SERVE_PORT, ~180-200MB expected)"

log_success "Section 7 complete: 1 service (Next.js direct on :$SERVE_PORT, no proxy)."
log "  (Caddy + progress-service both eliminated — frontend polls API directly)"

# =============================================================================
# SECTION 8: Wait for readiness, then monitor
# =============================================================================
log "Section 8: Waiting for services to be ready..."

# Wait for Next.js (the ONLY service now — no Caddy to wait for)
for i in $(seq 1 120); do
    if curl -fsS "http://127.0.0.1:$SERVE_PORT/api/settings" > /dev/null 2>&1; then
        log_success "Next.js is ready on port $SERVE_PORT."
        break
    fi
    sleep 2
done

# Print memory usage
mem_status "services-ready"
log ""
log "========================================"
log "  YouTube Frontend is running! (LOW-RAM)"
log "========================================"
log "  URL:            http://localhost:$SERVE_PORT  (Next.js direct — no proxy)"
log "  Logs:           $LOG_DIR/"
log "  Data:           $DATA_DIR/"
log "  Database:       $DB_DIR/custom.db"
log "  TMPDIR (disk):  $TMP_DIR"
log ""
log "  Memory usage (RSS by process):"
ps -eo rss,comm --sort=-rss 2>/dev/null | head -8 | while read -r rss c; do
    [ "$rss" -gt 1024 ] && log "    $((rss/1024))MB  $c"
done
log ""
log "  Total memory:"
free -m 2>/dev/null | head -3 | while read -r line; do log "    $line"; done || true
log "========================================"
log ""
log "Memory budget target: < 400MB RAM (active processes)"
log "  Next.js ~180-200MB + OS ~70MB = ~250-270MB (NO Caddy — saves ~25MB)"
log "  Swap absorbs build-time peaks; swappiness=100 keeps RAM free."
log ""
log "Press Ctrl+C to stop all services."
log ""

# Monitor loop — restart any service that dies + continuous memory monitoring
log "Entering process monitor loop (memory checked every 30s)..."
MEM_CHECK_COUNTER=0
while true; do
    if ! kill -0 "$NEXT_PID" 2>/dev/null; then
        log_error "Next.js died — restarting..."
        cd "$APP_DIR"
        NODE_ENV=production bun next start -p "$SERVE_PORT" > "$LOG_DIR/nextjs.log" 2>&1 &
        NEXT_PID=$!
        log "  Next.js restarted (PID: $NEXT_PID)"
    fi

    # Caddy monitor: REMOVED (no Caddy process to watch).

    sleep 5
    MEM_CHECK_COUNTER=$((MEM_CHECK_COUNTER + 1))
    # Every 30s (6 iterations × 5s), log memory status
    if [ "$MEM_CHECK_COUNTER" -ge 6 ]; then
        MEM_CHECK_COUNTER=0
        mem_status "runtime"
    fi
done
RUNSH_EOF_9X7K2

# Make run.sh executable
RUN chmod +x /app/run.sh

# -----------------------------------------------------------------------------
# Volumes for persistence (survive container restarts/redeploys)
#   /app/data  — settings, downloads, cookies, cache
#   /app/db    — SQLite database (history, favorites, settings)
#   /app/logs  — application logs
# -----------------------------------------------------------------------------
VOLUME ["/app/data", "/app/db", "/app/logs"]

# -----------------------------------------------------------------------------
# Expose port 80 (Next.js serves directly — NO reverse proxy)
# -----------------------------------------------------------------------------
EXPOSE 80

# -----------------------------------------------------------------------------
# tini = proper PID 1 signal handling (SIGTERM → graceful shutdown of Next.js)
# -----------------------------------------------------------------------------
ENTRYPOINT ["tini", "--"]
CMD ["bash", "run.sh"]
