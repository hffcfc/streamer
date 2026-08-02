# =============================================================================
# Dockerfile — StreamVault (YouTube Frontend)
# =============================================================================
# This Dockerfile installs ONLY system-level dependencies:
#   - apt packages (ffmpeg, python3, curl, git, tini, etc.)
#   - yt-dlp (Python, via pip)
#   - Bun runtime (JavaScriptCore)
#
# It does NOT install npm packages or copy source code.
# Everything else is handled by run.sh at container start:
#   - Writes all 117 source files (including package.json) via heredocs
#   - Runs `bun install` (npm dependencies)
#   - Generates Prisma client
#   - Builds Next.js (production)
#   - Initializes SQLite database
#   - Starts Next.js on :80 (NO reverse proxy)
#
# Why this split:
#   - Dockerfile = slow-changing system deps (cached, reusable image)
#   - run.sh     = the entire application (self-contained, no external files)
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
# Copy run.sh — the ONLY file needed from the build context.
# run.sh is fully self-contained: it embeds all 117 source files as heredocs
# (including package.json), runs bun install, builds Next.js, and serves.
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
