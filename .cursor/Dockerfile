FROM ruby:3.4.7-bookworm

ARG BUNDLER_VERSION=2.4.19

ENV DEBIAN_FRONTEND=noninteractive \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_BIN=/usr/local/bundle/bin \
    GEM_HOME=/usr/local/bundle \
    BROWSER_PATH=/usr/bin/chromium \
    PATH=/usr/local/bundle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN find /usr/local/lib/ruby/gems -name "*.gemspec" -size 0 -delete

COPY script/agent-env/system-deps.sh /tmp/system-deps.sh
RUN bash /tmp/system-deps.sh && rm /tmp/system-deps.sh

RUN gem install bundler -v "${BUNDLER_VERSION}" && \
    gem install foreman && \
    ln -sf /usr/local/bundle/bin/bundle /usr/local/bin/bundle && \
    ln -sf /usr/local/bundle/bin/bundler /usr/local/bin/bundler && \
    ln -sf /usr/local/bundle/bin/foreman /usr/local/bin/foreman && \
    useradd --create-home --shell /bin/bash cursor && \
    echo "cursor ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cursor && \
    chmod 0440 /etc/sudoers.d/cursor && \
    mkdir -p /data/db && \
    chown -R cursor:cursor /data/db /usr/local/bundle

WORKDIR /home/cursor
USER cursor
