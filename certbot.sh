#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.ini"
CERTS_DIR="$SCRIPT_DIR/certs"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: $CONFIG_FILE not found. Copy config.ini.example to config.ini and fill in your values."
    exit 1
fi

# Parse global settings
LINODE_TOKEN=""
EMAIL=""
PROPAGATION_SECONDS="120"

# Collect cert blocks: each element is a DOMAINS value
CERT_DOMAINS=()

in_cert_block=false
while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip leading/trailing whitespace
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Skip empty lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue

    # Detect [[cert]] block
    if [[ "$line" == "[[cert]]" ]]; then
        in_cert_block=true
        continue
    fi

    # Parse key=value
    if [[ "$line" =~ ^([A-Za-z_]+)=(.+)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        if $in_cert_block; then
            if [[ "$key" == "DOMAINS" ]]; then
                CERT_DOMAINS+=("$value")
                in_cert_block=false
            fi
        else
            case "$key" in
                LINODE_TOKEN) LINODE_TOKEN="$value" ;;
                EMAIL) EMAIL="$value" ;;
                PROPAGATION_SECONDS) PROPAGATION_SECONDS="$value" ;;
            esac
        fi
    fi
done < "$CONFIG_FILE"

# Validate required settings
if [[ -z "$LINODE_TOKEN" ]]; then
    echo "Error: LINODE_TOKEN not set in config.ini"
    exit 1
fi
if [[ -z "$EMAIL" ]]; then
    echo "Error: EMAIL not set in config.ini"
    exit 1
fi
if [[ ${#CERT_DOMAINS[@]} -eq 0 ]]; then
    echo "Error: No [[cert]] blocks found in config.ini"
    exit 1
fi

# Ensure certs directory exists
mkdir -p "$CERTS_DIR"

echo "=== Certbot DNS-Linode ==="
echo "Email: $EMAIL"
echo "Propagation wait: ${PROPAGATION_SECONDS}s"
echo "Certificates to process: ${#CERT_DOMAINS[@]}"
echo ""

# Process each certificate block
SUCCESS=()
FAILED=()

for domains in "${CERT_DOMAINS[@]}"; do
    # Build -d flags
    d_flags=()
    for d in $domains; do
        d_flags+=("-d" "$d")
    done

    # Use the first domain as the cert name (strip leading *. for wildcard)
    first_domain="${domains%% *}"
    cert_name="${first_domain#\*.}"

    echo "--- Requesting certificate for: $domains ---"

    # Create temporary credentials file
    cred_file="$(mktemp)"
    cat > "$cred_file" <<EOF
dns_linode_key = $LINODE_TOKEN
dns_linode_version = 4
EOF
    chmod 600 "$cred_file"

    # Run certbot in Docker
    if docker run --rm \
        -v "$CERTS_DIR:/etc/letsencrypt" \
        -v "$cred_file:/tmp/linode.ini:ro" \
        certbot/dns-linode \
        certonly \
        --dns-linode \
        --dns-linode-credentials /tmp/linode.ini \
        --dns-linode-propagation-seconds "$PROPAGATION_SECONDS" \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive \
        --cert-name "$cert_name" \
        "${d_flags[@]}"; then
        SUCCESS+=("$cert_name")
    else
        FAILED+=("$cert_name")
    fi

    # Clean up temp credentials
    rm -f "$cred_file"
    echo ""
done

# Summary
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
