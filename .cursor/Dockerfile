FROM ruby:4.0.9-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_BIN=/usr/local/bundle/bin \
    GEM_HOME=/usr/local/bundle \
    BROWSER_PATH=/usr/bin/chromium \
    PATH=/usr/local/bundle/bin:/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN find /usr/local/lib/ruby/gems -name "*.gemspec" -size 0 -delete

COPY script/agent-env/system-deps.sh /tmp/system-deps.sh
RUN bash /tmp/system-deps.sh && rm /tmp/system-deps.sh

# Cursor runs environment.json's terminals (the web process) in tmux sessions
RUN apt-get update -qq && apt-get install -y --no-install-recommends tmux && rm -rf /var/lib/apt/lists/*

# The Node in .nvmrc, for npm ci of the linters, linked at /opt/node (on PATH above) whatever its version
COPY .nvmrc /tmp/dandelion/.nvmrc
COPY script/agent-env/node.sh /tmp/dandelion/script/agent-env/node.sh
RUN NODE_PREFIX="$(bash /tmp/dandelion/script/agent-env/node.sh)" && \
    { [ -z "$NODE_PREFIX" ] || ln -sfn "$NODE_PREFIX" /opt/node; } && \
    rm -rf /tmp/dandelion

# Login shells source /etc/profile, which resets PATH, so put gem executables and Node back on it
RUN echo 'export PATH=/usr/local/bundle/bin:/opt/node/bin:$PATH' > /etc/profile.d/bundle.sh

RUN useradd --create-home --shell /bin/bash cursor && \
    echo "cursor ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cursor && \
    chmod 0440 /etc/sudoers.d/cursor && \
    mkdir -p /data/db && \
    chown -R cursor:cursor /data/db /usr/local/bundle

WORKDIR /home/cursor
USER cursor
