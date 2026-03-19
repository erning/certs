# Request/renew Let's Encrypt certificates via Certbot DNS-Linode
#
# Usage:
#   just renew              # request/renew all certificates
#   just renew --dry-run    # dry run

[private]
default:
    @just --list

config := "config.json"
certs_dir := justfile_directory() / "certs"

# Request/renew all certificates
renew *flags:
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

# List certificate status
list:
    #!/usr/bin/env bash
    set -euo pipefail

    CONFIG="{{ justfile_directory() }}/{{ config }}"
    CERTS_DIR="{{ certs_dir }}"

    if [[ ! -f "$CONFIG" ]]; then
        echo "Error: $CONFIG not found."
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed."
        exit 1
    fi

    config_names=()

    TOTAL=$(jq '.certs | length' "$CONFIG")
    for i in $(seq 0 $((TOTAL - 1))); do
        entry=$(jq -c ".certs[$i]" "$CONFIG")
        cert_name=$(echo "$entry" | jq -r '.domains[0]' | sed 's/^\*\.//')
        config_domains=$(echo "$entry" | jq -r '.domains[]' | sort)
        config_domains_display=$(echo "$entry" | jq -r '.domains | join(", ")')

        config_names+=("$cert_name")

        cert_pem="$CERTS_DIR/live/$cert_name/cert.pem"

        if [[ ! -f "$cert_pem" ]]; then
            echo "$cert_name [NOT ISSUED]"
            echo "  Domains (config): $config_domains_display"
        else
            # Extract SANs from certificate
            cert_sans=$(openssl x509 -in "$cert_pem" -noout -text \
                | grep -A1 "Subject Alternative Name" \
                | tail -1 \
                | sed 's/DNS://g; s/[[:space:]]//g' \
                | tr ',' '\n' \
                | sort)
            cert_sans_display=$(echo "$cert_sans" | paste -sd, - | sed 's/,/, /g')

            # Get expiry date
            expiry_str=$(openssl x509 -in "$cert_pem" -noout -enddate | cut -d= -f2)
            expiry_display=$(date -u -d "$expiry_str" "+%Y-%m-%d")
            expiry_epoch=$(date -d "$expiry_str" "+%s")
            now_epoch=$(date "+%s")
            days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

            # Compare config domains with cert SANs
            mismatch=""
            if [[ "$config_domains" != "$cert_sans" ]]; then
                mismatch=" [MISMATCH]"
            fi

            echo "$cert_name$mismatch"
            echo "  Domains: $cert_sans_display"
            if [[ -n "$mismatch" ]]; then
                echo "  Domains (config): $config_domains_display"
            fi
            echo "  Expires: $expiry_display ($days_left days)"
        fi
        echo ""
    done

    # Find certs not in config
    if [[ -d "$CERTS_DIR/live" ]]; then
        for dir in "$CERTS_DIR/live"/*/; do
            [[ -d "$dir" ]] || continue
            name=$(basename "$dir")
            in_config=false
            for cn in "${config_names[@]}"; do
                if [[ "$cn" == "$name" ]]; then
                    in_config=true
                    break
                fi
            done
            if [[ "$in_config" == false ]]; then
                cert_pem="$dir/cert.pem"
                if [[ -f "$cert_pem" ]]; then
                    cert_sans=$(openssl x509 -in "$cert_pem" -noout -text \
                        | grep -A1 "Subject Alternative Name" \
                        | tail -1 \
                        | sed 's/DNS://g; s/[[:space:]]//g' \
                        | tr ',' '\n' \
                        | sort)
                    cert_sans_display=$(echo "$cert_sans" | paste -sd, - | sed 's/,/, /g')

                    expiry_str=$(openssl x509 -in "$cert_pem" -noout -enddate | cut -d= -f2)
                    expiry_display=$(date -u -d "$expiry_str" "+%Y-%m-%d")
                    expiry_epoch=$(date -d "$expiry_str" "+%s")
                    now_epoch=$(date "+%s")
                    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

                    echo "$name [NOT IN CONFIG]"
                    echo "  Domains: $cert_sans_display"
                    echo "  Expires: $expiry_display ($days_left days)"
                    echo ""
                fi
            fi
        done
    fi
