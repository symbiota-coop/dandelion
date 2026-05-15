#!/usr/bin/env bash
set -euo pipefail

bundle config set build.nokogiri "--use-system-libraries"
bundle install

if [ ! -f .env ]; then
  cp .env.example .env
fi

if [ ! -f .env.test ]; then
  cp .env.test.example .env.test
fi

mkdir -p app/assets/dragonfly capybara log tmp
