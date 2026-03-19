# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Automated Let's Encrypt certificate management using Certbot DNS-Linode plugin via Docker. A `justfile` serves as the task runner, reading domain configuration from `config.json` (parsed with `jq`).

## Commands

```bash
just                  # list available recipes
just list             # show certificate status
just renew            # request/renew all certificates
just renew --dry-run  # dry run (no actual cert issuance)
```

## Architecture

- **justfile** — single entry point; the `renew` recipe is a bash script that loops over `config.json` entries, running `docker run certbot/dns-linode` for each certificate
- **config.json** — real config with Linode API token, email, and cert definitions; encrypted at rest via git-crypt (see `.gitattributes`)
- **config.example.jsonc** — JSONC reference with comments; not machine-parsed
- **certs/** — output directory for Let's Encrypt data (gitignored)

## Dependencies

- `just` (task runner)
- `jq` (JSON parsing)
- `docker` (runs `certbot/dns-linode` image)
- `git-crypt` (encrypts `config.json` in the repo)

## Key Design Decisions

- Cert name is derived from the first domain in each entry, stripping any leading `*.` (e.g., `*.erning.com` → `erning.com`)
- Linode credentials are written to a temp file with `trap` cleanup, mounted read-only into the container
- Extra flags passed to `just renew` are forwarded directly to certbot (via justfile `*flags` parameter)
