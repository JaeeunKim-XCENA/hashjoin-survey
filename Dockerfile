FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    ripgrep \
    jq \
    tmux \
    python3 \
    python3-pip \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 LTS (Claude Code 실행용)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# agent-deck (statically linked binary)
COPY agent-deck /usr/local/bin/agent-deck
RUN chmod +x /usr/local/bin/agent-deck

WORKDIR /workspace

CMD ["/bin/bash"]
