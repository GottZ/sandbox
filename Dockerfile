# Claude Code Development Sandbox
# A comprehensive development environment with multiple language runtimes and tools

FROM ubuntu:24.04

LABEL maintainer="Claude Code Sandbox"
LABEL description="Full-featured development sandbox for Claude Code"

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Set up locale
RUN apt-get update && apt-get install -y locales && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install base system utilities and network diagnostics
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Essential utilities
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    build-essential \
    pkg-config \
    # Network diagnostics
    iputils-ping \
    traceroute \
    net-tools \
    nmap \
    tcpdump \
    dnsutils \
    netcat-openbsd \
    iperf3 \
    iproute2 \
    mtr-tiny \
    whois \
    host \
    # Version control
    git \
    git-lfs \
    # Download utilities
    curl \
    wget \
    # Image processing
    imagemagick \
    # PostgreSQL client
    postgresql-client \
    libpq-dev \
    # Debugging tools
    strace \
    ltrace \
    gdb \
    valgrind \
    htop \
    btop \
    # Text processing and editors
    jq \
    vim \
    nano \
    # Terminal utilities
    tmux \
    screen \
    tree \
    less \
    file \
    unzip \
    zip \
    xz-utils \
    # Process utilities
    procps \
    lsof \
    # SSL/TLS tools
    openssl \
    libssl-dev \
    # Misc development
    cmake \
    ninja-build \
    autoconf \
    automake \
    libtool \
    # Python (useful for scripting)
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install yq (YAML processor)
RUN wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && \
    chmod +x /usr/local/bin/yq

# Install ripgrep
RUN curl -LO https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep_15.1.0-1_amd64.deb && \
    dpkg -i ripgrep_15.1.0-1_amd64.deb && \
    rm ripgrep_15.1.0-1_amd64.deb

# Install fd-find
RUN curl -LO https://github.com/sharkdp/fd/releases/download/v10.3.0/fd_10.3.0_amd64.deb && \
    dpkg -i fd_10.3.0_amd64.deb && \
    rm fd_10.3.0_amd64.deb

# Install bat (better cat)
RUN curl -LO https://github.com/sharkdp/bat/releases/download/v0.26.0/bat_0.26.0_amd64.deb && \
    dpkg -i bat_0.26.0_amd64.deb && \
    rm bat_0.26.0_amd64.deb

# Install Docker CLI and Docker daemon (for dind mode)
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin && \
    rm -rf /var/lib/apt/lists/*

# Install Node.js (LTS v24 Krypton)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g npm@latest

# Install Bun
RUN curl -fsSL https://bun.sh/install | bash
ENV BUN_INSTALL="/root/.bun"
ENV PATH="$BUN_INSTALL/bin:$PATH"

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:$PATH"
RUN rustup component add rustfmt clippy rust-analyzer

# Install Zig
RUN curl -LO https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz && \
    tar -xf zig-x86_64-linux-0.15.2.tar.xz && \
    mv zig-x86_64-linux-0.15.2 /opt/zig && \
    rm zig-x86_64-linux-0.15.2.tar.xz
ENV PATH="/opt/zig:$PATH"

# Install zls (Zig Language Server)
RUN curl -LO https://github.com/zigtools/zls/releases/download/0.15.0/zls-x86_64-linux.tar.xz && \
    tar -xf zls-x86_64-linux.tar.xz && \
    mv zls /usr/local/bin/ && \
    rm zls-x86_64-linux.tar.xz

# Install useful Rust tools
RUN cargo install \
    cargo-watch \
    cargo-edit \
    cargo-audit \
    tokei \
    hyperfine \
    && rm -rf /root/.cargo/registry/cache

# Claude Code will be installed as the claude user later (requires ~/.local/bin)

# Install Playwright dependencies first (for all browsers)
RUN npx playwright install-deps

# Install Playwright with all browsers
RUN npm install -g playwright @playwright/test && \
    npx playwright install chromium firefox webkit

# Install additional browser runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Display server for headed mode (optional)
    xvfb \
    # Fonts for proper text rendering
    fonts-liberation \
    fonts-noto-color-emoji \
    fonts-noto-cjk \
    # Additional libs sometimes needed
    libatk-bridge2.0-0 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libasound2t64 \
    && rm -rf /var/lib/apt/lists/*

# Set Playwright environment variables
ENV PLAYWRIGHT_BROWSERS_PATH=/home/claude/.cache/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# Create non-root user for Claude (required for --dangerously-skip-permissions)
# Remove existing UID 1000 user if present, then create claude user
RUN if getent passwd 1000 > /dev/null; then userdel -r $(getent passwd 1000 | cut -d: -f1) 2>/dev/null || true; fi && \
    useradd -m -s /bin/bash -u 1000 claude && \
    mkdir -p /home/claude/.claude /home/claude/.config/claude /home/claude/.anthropic /home/claude/.local/bin && \
    chown -R claude:claude /home/claude

# Give claude user passwordless sudo access for full control and install bindfs + expect
RUN apt-get update && apt-get install -y sudo bindfs expect && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    rm -rf /var/lib/apt/lists/*

# Create mount staging directories
RUN mkdir -p /mnt/bindfs /mnt/workspace

# Copy and set up entrypoint script and claude wrapper
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY claude-wrapper.sh /usr/local/bin/claude-wrapper
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-wrapper

# Set up working directory
WORKDIR /workspace
RUN chown claude:claude /workspace

# Copy rust/bun/zig/playwright to claude user
RUN cp -r /root/.cargo /home/claude/.cargo && \
    cp -r /root/.rustup /home/claude/.rustup && \
    cp -r /root/.bun /home/claude/.bun && \
    cp -r /root/.cache /home/claude/.cache && \
    chown -R claude:claude /home/claude/.cargo /home/claude/.rustup /home/claude/.bun /home/claude/.cache

# Configure git defaults for claude user
RUN su - claude -c 'git config --global init.defaultBranch main && \
    git config --global core.editor vim && \
    git config --global pull.rebase false'

# Set up a nice prompt for claude user
RUN echo 'PS1="\[\e[1;36m\][sandbox]\[\e[0m\] \[\e[1;32m\]\w\[\e[0m\] \$ "' >> /home/claude/.bashrc

# Add helpful aliases for claude user
RUN echo 'alias ll="ls -la"' >> /home/claude/.bashrc && \
    echo 'alias la="ls -A"' >> /home/claude/.bashrc && \
    echo 'alias l="ls -CF"' >> /home/claude/.bashrc && \
    echo 'alias grep="grep --color=auto"' >> /home/claude/.bashrc && \
    echo 'alias rg="rg --smart-case"' >> /home/claude/.bashrc

# Update PATH and environment for claude user
RUN echo 'export PATH="/home/claude/.local/bin:/home/claude/.cargo/bin:/home/claude/.bun/bin:/opt/zig:$PATH"' >> /home/claude/.bashrc && \
    echo 'export RUSTUP_HOME=/home/claude/.rustup' >> /home/claude/.bashrc && \
    echo 'export CARGO_HOME=/home/claude/.cargo' >> /home/claude/.bashrc && \
    echo 'export PLAYWRIGHT_BROWSERS_PATH=/home/claude/.cache/ms-playwright' >> /home/claude/.bashrc && \
    echo 'export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1' >> /home/claude/.bashrc

# Switch to claude user
USER claude
ENV HOME=/home/claude
ENV PATH="/home/claude/.local/bin:/home/claude/.cargo/bin:/home/claude/.bun/bin:/opt/zig:$PATH"

# Configure npm to install global packages to ~/.local and install Claude Code
RUN mkdir -p ~/.local && \
    npm config set prefix ~/.local && \
    npm install -g @anthropic-ai/claude-code && \
    ls -la ~/.local/bin/
ENV BUN_INSTALL="/home/claude/.bun"
ENV RUSTUP_HOME=/home/claude/.rustup
ENV CARGO_HOME=/home/claude/.cargo
ENV PLAYWRIGHT_BROWSERS_PATH=/home/claude/.cache/ms-playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# Verify installations
RUN echo "=== Verifying installations ===" && \
    node --version && \
    npm --version && \
    bun --version && \
    rustc --version && \
    cargo --version && \
    zig version && \
    docker --version && \
    git --version && \
    python3 --version && \
    convert --version | head -1 && \
    psql --version && \
    npx playwright --version && \
    echo "=== Verifying Playwright browsers ===" && \
    ls -la $PLAYWRIGHT_BROWSERS_PATH && \
    echo "=== All tools installed successfully ==="

# Set entrypoint for bindfs mount handling
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default command
CMD ["/bin/bash"]
