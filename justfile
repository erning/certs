# Request/renew Let's Encrypt certificates via Certbot DNS-Linode
#
# Usage:
#   just certs              # request/renew all certificates
#   just certs --dry-run    # dry run

[private]
default:
    @just --list

config := "config.json"
certs_dir := justfile_directory() / "certs"

# Request/renew all certificates
certs *flags:
    #!/usr/bin/env bash
    set -euo pipefail

    CONFIG="{{ justfile_directory() }}/{{ config }}"
    CERTS_DIR="{{ certs_dir }}"

    if [[ ! -f "$CONFIG" ]]; then
        echo "Error: $CONFIG not found. Copy config.json.example to config.json and fill in your values."
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed."
        exit 1
    fi

    LINODE_TOKEN=$(jq -r '.linode_token' "$CONFIG")
    EMAIL=$(jq -r '.email' "$CONFIG")
    PROPAGATION_SECONDS=$(jq -r '.propagation_seconds' "$CONFIG")

    mkdir -p "$CERTS_DIR"

    CRED_FILE=$(mktemp)
    trap 'rm -f "$CRED_FILE"' EXIT
    printf 'dns_linode_key = %s\ndns_linode_version = 4\n' "$LINODE_TOKEN" > "$CRED_FILE"
    chmod 600 "$CRED_FILE"

    TOTAL=$(jq '.certs | length' "$CONFIG")
    echo "=== Certbot DNS-Linode ==="
    echo "Email: $EMAIL"
    echo "Propagation wait: ${PROPAGATION_SECONDS}s"
    echo "Certificates to process: $TOTAL"
    echo ""

    SUCCESS=()
    FAILED=()

    for i in $(seq 0 $((TOTAL - 1))); do
        entry=$(jq -c ".certs[$i]" "$CONFIG")

        # Build -d flags
        d_flags=()
        while read -r d; do
            d_flags+=("-d" "$d")
        done < <(echo "$entry" | jq -r '.domains[]')

        # Cert name: first domain, strip leading *.
        cert_name=$(echo "$entry" | jq -r '.domains[0]' | sed 's/^\*\.//')

        echo "--- Requesting certificate for: ${d_flags[*]} ---"

        if docker run --rm \
            -v "$CERTS_DIR:/etc/letsencrypt" \
            -v "$CRED_FILE:/tmp/linode.ini:ro" \
            certbot/dns-linode \
            certonly \
            --dns-linode \
            --dns-linode-credentials /tmp/linode.ini \
            --dns-linode-propagation-seconds "$PROPAGATION_SECONDS" \
            --email "$EMAIL" \
            --agree-tos \
            --non-interactive \
            --cert-name "$cert_name" \
            "${d_flags[@]}" \
            {{ flags }}; then
            SUCCESS+=("$cert_name")
        else
            FAILED+=("$cert_name")
        fi

        echo ""
    done

    echo "=== Summary ==="
    if [[ ${#SUCCESS[@]} -gt 0 ]]; then
        echo "Succeeded:"
        for name in "${SUCCESS[@]}"; do
            echo "  - $name (certs/live/$name/)"
        done
    fi
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        echo "Failed:"
        for name in "${FAILED[@]}"; do
            echo "  - $name"
        done
        exit 1
    fi
    echo "All certificates obtained successfully."
