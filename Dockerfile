# =============================================================================
# Dockerfile — YouTube Frontend (Next.js 16 + Bun + yt-dlp + FFmpeg)
# =============================================================================
FROM oven/bun:1.1-debian

# Avoid interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# =============================================================================
# Install ALL system dependencies
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        wget \
        ca-certificates \
        gnupg \
        debian-keyring \
        debian-archive-keyring \
        apt-transport-https \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list \
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
# Install yt-dlp (Via Python Virtual Environment)
# =============================================================================
# This is the safest way to install yt-dlp in Docker. It avoids Debian's 
# PEP 668 restrictions and avoids GitHub API rate limits by using PyPI.
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN pip install --no-cache-dir -U yt-dlp

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
# Copy run.sh — the application bootstrap script
# =============================================================================
COPY run.sh ./run.sh
RUN chmod +x ./run.sh

# =============================================================================
# Persistent volumes
# =============================================================================
VOLUME ["/app/db", "/app/data", "/app/cookies", "/app/logs", "/app/.next", "/app/node_modules"]

# =============================================================================
# Expose ports
# =============================================================================
EXPOSE 80 3000 3001

# =============================================================================
# Healthcheck
# =============================================================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=5 \
    CMD curl -fsS "http://127.0.0.1/api/settings" || exit 1

# =============================================================================
# Entrypoint — tini (PID 1) runs run.sh
# =============================================================================
ENTRYPOINT ["/usr/bin/tini", "--", "./run.sh"]
