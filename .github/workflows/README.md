# Automation

The workflows that run coding agents on this repo. Read this before changing one, its prompt or its models. `AGENTS.md` covers the rest: CI's tests and lint job (Tests, Linting) and the nightly package updates (Dependencies).

This file is here rather than at `.github/README.md`, which GitHub would show as the repo's front page in place of the root `README.md`.

## Logs are public

This repo's workflow logs are public, so keep emails and query results out of anything its workflows print.

## Daily bug reviews

- `daily-bug-review-claude.yml`, `-codex.yml`, `-cursor.yml` and `-opencode.yml` run Claude, Codex, Cursor and opencode on the same prompt (`.github/prompts/daily-bug-review.md`), with the steps they share in `.github/actions`
- Their models are in `.github/models.env`. opencode takes several (`OPENCODE_MODELS`), each with its own effort where it has a choice of them, and runs a review with each

## Issues to pull requests

- When someone with write access opens an issue, Claude works on it and opens a pull request from `claude/issue-<number>`, or comments if there's nothing to change (`issue-to-pr.yml`, with the prompt `.github/prompts/issue-to-pr.md`)
- The `no-pr` label skips it

## Replies to users' emails

- Claude drafts replies to users' emails, with the prompt `.github/prompts/user-query-replies.md`
- Its tool permissions are beside the prompt (`user-query-replies.settings.json`): only tools that read, as emails are untrusted
- It has a Gmail MCP server of its own, `script/gmail_mcp.rb`, which drafts but can't send
- Its workflow runs from a private repo, because its logs hold emails
