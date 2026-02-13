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
    sudo \
    locales \
    && rm -rf /var/lib/apt/lists/* \
    && locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Node.js 22 LTS (Claude Code 실행용)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# agent-deck (statically linked binary)
COPY agent-deck /usr/local/bin/agent-deck
RUN chmod +x /usr/local/bin/agent-deck

# jekim 유저 생성 (sudo 권한, 호스트 UID/GID와 매칭)
RUN useradd -m -s /bin/bash -u 1005 -U jekim && \
    echo "jekim ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER jekim
WORKDIR /home/jekim/workspace

CMD ["/bin/bash"]
