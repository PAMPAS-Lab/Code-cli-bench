# syntax=docker/dockerfile:1.7
FROM node:20.19-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Etc/UTC \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_LINK_MODE=copy \
    UV_NO_SYNC_INSTALLS=1

RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && apt-get install -y --no-install-recommends \
    locales ca-certificates tzdata curl git vim python3 python3-pip\
    && sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh

ARG USERNAME=appuser
RUN useradd -m -s /bin/bash ${USERNAME} \
    && mkdir -p /home/${USERNAME}/.local/bin \
    && cp /root/.local/bin/uv /home/${USERNAME}/.local/bin/uv \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

RUN mkdir -p /workspace && chown -R ${USERNAME}:${USERNAME} /workspace
ENV PATH="/home/${USERNAME}/.local/bin:${PATH}"

#claude code
RUN npm install -g @anthropic-ai/claude-code@1.0.81
COPY claude/cli.js /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js
COPY claude/claude.json /home/${USERNAME}/.claude.json
RUN chmod 755 /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js

USER ${USERNAME}
WORKDIR /workspace
COPY --chown=${USERNAME}:${USERNAME} . /workspace/agent-bench/
RUN chmod +x /workspace/agent-bench/*.sh

#pywen
RUN git clone https://github.com/leeyeel/Pywen.git
RUN cd Pywen \
    && git checkout multi-agent\
    && uv venv \ 
    && uv sync --all-extras \
    && uv pip install -e .

ENV PATH="/workspace/Pywen/.venv/bin:${PATH}"
