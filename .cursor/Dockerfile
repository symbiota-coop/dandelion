FROM ruby:3.4.7-bookworm

ARG TARGETARCH
ARG BUNDLER_VERSION=2.4.19
ARG MONGODB_VERSION=8.2.6

ENV DEBIAN_FRONTEND=noninteractive \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_BIN=/usr/local/bundle/bin \
    GEM_HOME=/usr/local/bundle \
    BROWSER_PATH=/usr/bin/chromium \
    PATH=/usr/local/bundle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN find /usr/local/lib/ruby/gems -name "*.gemspec" -size 0 -delete

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      build-essential \
      ca-certificates \
      chromium \
      curl \
      fonts-liberation \
      git \
      imagemagick \
      libffi-dev \
      libssl-dev \
      libtool \
      libxml2-dev \
      libxslt1-dev \
      libyaml-dev \
      libzstd-dev \
      pkg-config \
      sudo \
      tzdata \
      zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
      amd64) mongo_package="mongodb-linux-x86_64-debian12-${MONGODB_VERSION}" ;; \
      arm64) mongo_package="mongodb-linux-aarch64-ubuntu2204-${MONGODB_VERSION}" ;; \
      *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://fastdl.mongodb.org/linux/${mongo_package}.tgz" -o /tmp/mongodb.tgz && \
    mkdir -p /tmp/mongodb /usr/local/mongodb && \
    tar -xzf /tmp/mongodb.tgz -C /tmp/mongodb --strip-components=1 && \
    cp /tmp/mongodb/bin/mongod /tmp/mongodb/bin/mongos /usr/local/bin/ && \
    rm -rf /tmp/mongodb /tmp/mongodb.tgz

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
