#!/bin/sh
set -e

SSL_DIR="/etc/nginx/ssl"
mkdir -p "$SSL_DIR"

if [ ! -f "$SSL_DIR/server.crt" ] || [ ! -f "$SSL_DIR/server.key" ]; then
    DOMAIN="${SSL_DOMAIN:-hayamimi.local}"
    EXTRA_IP="${SSL_IP:-127.0.0.1}"
    SAN="DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1"
    if [ "$EXTRA_IP" != "127.0.0.1" ]; then
        SAN="$SAN,IP:$EXTRA_IP"
    fi
    echo "=== 自己署名証明書を自動生成します (Domain: $DOMAIN, SAN: $SAN) ==="
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_DIR/server.key" \
        -out "$SSL_DIR/server.crt" \
        -subj "/CN=$DOMAIN/O=Hayamimi/C=JP" \
        -addext "subjectAltName=$SAN"
    echo "証明書生成完了: $SSL_DIR/server.crt"
fi

exec nginx -g "daemon off;"
