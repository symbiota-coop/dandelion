FROM ruby:3.4.7-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_BIN=/usr/local/bundle/bin \
    GEM_HOME=/usr/local/bundle \
    BROWSER_PATH=/usr/bin/chromium \
    PATH=/usr/local/bundle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN find /usr/local/lib/ruby/gems -name "*.gemspec" -size 0 -delete

COPY script/agent-env/system-deps.sh /tmp/system-deps.sh
RUN bash /tmp/system-deps.sh && rm /tmp/system-deps.sh

# Login shells source /etc/profile, which resets PATH, so put gem executables back on it
RUN echo 'export PATH=/usr/local/bundle/bin:$PATH' > /etc/profile.d/bundle.sh

RUN useradd --create-home --shell /bin/bash cursor && \
    echo "cursor ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cursor && \
    chmod 0440 /etc/sudoers.d/cursor && \
    mkdir -p /data/db && \
    chown -R cursor:cursor /data/db /usr/local/bundle

WORKDIR /home/cursor
USER cursor
