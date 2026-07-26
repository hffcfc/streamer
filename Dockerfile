# =============================================================================
# Dockerfile — YouTube Frontend (Next.js 16 + Bun + yt-dlp + FFmpeg)
# =============================================================================
# This Dockerfile does ONE thing: installs ALL dependencies and libraries.
# It does NOT contain or copy any application source code.
#
# After the build, run.sh takes over as the container's entrypoint.
# run.sh creates ALL source code files, installs npm deps, builds Next.js,
# and starts all services.
#
# The ONLY two files you need:
#   1. Dockerfile  (this file — installs everything)
#   2. run.sh      (creates source code + starts server)
#
# Build:  docker build -t yt-frontend .
# Run:    docker run -d -p 80:80 -v yt-data:/app/data -v yt-db:/app/db yt-frontend
# =============================================================================

FROM oven/bun:1.1-debian

# Avoid interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# =============================================================================
# Install ALL system dependencies
# =============================================================================
# These are installed ONCE during the Docker build and cached in the image.
# run.sh does NOT install anything — it uses these pre-installed binaries.
#
#   python3 + pip  -> yt-dlp runtime (yt-dlp is a Python application)
#   ffmpeg         -> video merge / audio extraction / format conversion
#   curl, wget     -> networking + healthchecks
#   ca-certificates-> TLS certificate verification
#   gnupg          -> GPG key verification (for apt repos)
#   git            -> some npm postinstall scripts require it
#   tini           -> proper PID 1 signal handling (SIGTERM/SIGINT)
#   netcat-openbsd -> port readiness checks
#   caddy          -> reverse proxy (XTransformPort gateway on port 80)
#   procps         -> process inspection (pgrep, pkill, etc.)
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        wget \
        ca-certificates \
        gnupg \
        debian-keyring \
        debian-archive-keyring \
        apt-transport-https \
    && curl -1sLf 'https://cloudsmith.io' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://cloudsmith.io' | tee /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        ffmpeg \
        git \
        tini \
        netcat-openbsd \
        caddy \
        procps \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Install yt-dlp via pip
# =============================================================================
# yt-dlp is a Python application. We install the latest version because YouTube
# frequently breaks older versions.
RUN pip3 install --no-cache-dir --break-system-packages -U yt-dlp

# Sanity check: verify all required binaries are available on PATH
RUN yt-dlp --version && \
    ffmpeg -version | head -n 1 && \
    python3 --version && \
    caddy version && \
    bun --version

# =============================================================================
# Set up the working directory
# =============================================================================
WORKDIR /app

# =============================================================================
# Copy run.sh — the ONLY application file needed
# =============================================================================
# run.sh is the container's startup script. It:
#   - Writes out ALL 117 application source code files via heredocs
#   - Installs npm dependencies (bun install)
#   - Generates the Prisma client
#   - Builds the Next.js production bundle
#   - Creates runtime directories, JSON data files, cookies placeholder
#   - Creates the Caddyfile
#   - Validates the environment
#   - Initializes the SQLite database
#   - Starts Caddy + progress-service + Next.js
#   - Monitors all processes
COPY run.sh ./run.sh
RUN chmod +x ./run.sh

# =============================================================================
# Persistent volumes
# =============================================================================
# These directories persist across container restarts:
#   /app/db       -> SQLite database
#   /app/data     -> JSON files + downloads
#   /app/cookies  -> cookies.txt (admin can replace)
#   /app/logs     -> startup.log, error.log, service logs
#   /app/.next    -> Next.js build output (cached across restarts)
#   /app/node_modules -> npm dependencies (cached across restarts)
VOLUME ["/app/db", "/app/data", "/app/cookies", "/app/logs", "/app/.next", "/app/node_modules"]

# =============================================================================
# Expose ports
# =============================================================================
#   80   -> Caddy gateway (MAIN entry point — use this in your browser)
#   3000 -> Next.js direct (optional, for debugging)
#   3001 -> socket.io progress-service (optional, for debugging)
EXPOSE 80 3000 3001

# =============================================================================
# Healthcheck
# =============================================================================
# Hits the Next.js /api/settings endpoint. Returns 200 when the app is up.
# start_period is 180s because the first run needs to install deps + build.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=5 \
    CMD curl -fsS "http://127.0.0" || exit 1

# =============================================================================
# Entrypoint — tini (PID 1) runs run.sh
# =============================================================================
# tini ensures proper signal handling so SIGTERM/SIGINT propagate cleanly
# to all child processes (Caddy, progress-service, Next.js).
ENTRYPOINT ["/usr/bin/tini", "--", "./run.sh"]
