# =============================================================================
# Dockerfile — StreamVault (YouTube Frontend)
# =============================================================================
# Builds a reusable image with ALL system + npm dependencies pre-installed.
# run.sh (executed at container start) handles:
#   - Writing all 117 source files (heredocs)
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
# -----------------------------------------------------------------------------
RUN pip3 install --no-cache-dir --break-system-packages yt-dlp

# -----------------------------------------------------------------------------
# Bun runtime (JavaScriptCore — NOT Node.js/V8)
# -----------------------------------------------------------------------------
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local/bun bash

ENV BUN_INSTALL=/usr/local/bun
ENV PATH=/usr/local/bun/bin:$PATH

# Verify Bun is accessible
RUN bun --version

# -----------------------------------------------------------------------------
# Working directory
# -----------------------------------------------------------------------------
WORKDIR /app

# -----------------------------------------------------------------------------
# Install npm dependencies (cached layer — only rebuilds when package.json
# or bun.lock change, NOT when source code changes)
# -----------------------------------------------------------------------------
COPY package.json bun.lock ./
RUN bun install --no-cache

# -----------------------------------------------------------------------------
# Copy run.sh — the entrypoint that writes source, builds, and serves
# -----------------------------------------------------------------------------
COPY run.sh ./
RUN chmod +x run.sh

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
