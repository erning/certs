# certs

Automated Let's Encrypt wildcard certificates via [Certbot DNS-Linode](https://certbot-dns-linode.readthedocs.io/) in Docker.

## Prerequisites

- [just](https://github.com/casey/just)
- [jq](https://jqlang.github.io/jq/)
- [Docker](https://www.docker.com/)
- [git-crypt](https://github.com/AGWA/git-crypt) (for config encryption)

## Setup

```bash
cp config.example.jsonc config.json
```

Edit `config.json` with your Linode API token, email, and domains:

```json
{
  "linode_token": "your-api-token-here",
  "email": "admin@example.com",
  "propagation_seconds": 120,
  "certs": [
    { "domains": ["example.com", "*.example.com"] }
  ]
}
```

## Usage

```bash
just list             # show certificate status
just renew            # request/renew all certificates
just renew --dry-run  # dry run
```

Certificates are stored in `certs/live/<domain>/`.

## Config Encryption

`config.json` is encrypted via git-crypt so the Linode API token is never stored in plaintext in the repository. After cloning, unlock with:

```bash
git-crypt unlock
```
