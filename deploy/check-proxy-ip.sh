#!/usr/bin/env bash
# The spoofed-header test (Deploy Step 5, docs/deploy.md §10): does the API read the visitor's
# real address behind Caddy and Next.js, or can a visitor choose it?
#     deploy/check-proxy-ip.sh https://codetutor.duckdns.org
# Run it from your own computer, not the server. It asks for 6 new guests, each with a
# different made-up X-Forwarded-For. The API allows 5 new guests per hour per address, so if it
# ignores the made-up header, one of them gets 429. If all 6 get in, the header fooled it:
# TRUSTED_PROXY_HOPS is wrong. It uses up your address's guests for an hour.
set -euo pipefail

SITE="${1:-}"
if [ -z "$SITE" ]; then
    echo "usage: $0 https://<domain>" >&2
    exit 1
fi
SITE="${SITE%/}"

for i in 1 2 3 4 5 6; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H "X-Forwarded-For: 203.0.113.$i" "$SITE/api/guest")"
    echo "guest $i (pretending to be 203.0.113.$i): HTTP $code"
    case "$code" in
        200) ;;
        429)
            echo "PASS: the made-up header was ignored, the limit counted your real address"
            exit 0
            ;;
        503)
            echo "INCONCLUSIVE: the site-wide guest limit is full; try again in an hour" >&2
            exit 2
            ;;
        *)
            echo "ERROR: unexpected HTTP $code from $SITE/api/guest" >&2
            exit 2
            ;;
    esac
done
echo "FAIL: 6 guests in a row with made-up addresses; check TRUSTED_PROXY_HOPS and Caddy" >&2
exit 1
