#!/bin/sh
# Fallback certificates: one *.<user>.<zone> per live user (phase-1.1-gateway-tls.md §6 in
# mesh-router-nameserver), so this gateway can terminate a user's dot names while the box
# has no trusted certificate of its own (nginx/lua/sni_router.lua). Started by
# entrypoint.sh (GATEWAY_FALLBACK_CERTS=on), with its environment: GATEWAY_STATE_DIR,
# BACKEND_URL, GATEWAY_CERT_TOKEN, ACME_DOMAIN and the ACME settings of scripts/acme-lib.sh.
#
# Every FALLBACK_POLL seconds:
#   - GET ${BACKEND_URL}/gateway/fallback-labels: the live users (dormant zones publish no
#     challenge TXT and their dot names are asked by nobody);
#   - for each label without a certificate valid GATEWAY_ACME_RENEW_DAYS more: order or
#     renew it (acme_obtain: primary CA, then the backup), one at a time; a label whose
#     order failed waits (FALLBACK_RETRY_MIN, doubling up to FALLBACK_RETRY_MAX) before the
#     next try, so a failing CA is not hammered;
#   - install the certificate to serve into fallback/<label>.pem (chain + key, one file
#     replaced atomically), which nginx/lua/fallback_certs.lua serves by SNI;
#   - write fallback/index.json, {"labels":{"<label>":"<notAfter ISO>"}}, served at
#     /.well-known/mesh-gateway/fallback: the coverage the backend reads.
# A label no longer listed keeps its file until the certificate expires (a zone that
# flaps live/dormant must not cause a new order); expired files are removed.
set -u

FALLBACK_DIR="${GATEWAY_STATE_DIR}/fallback"
RETRY_DIR="${FALLBACK_DIR}/.retry"
FALLBACK_POLL="${FALLBACK_POLL:-60}"
FALLBACK_RETRY_MIN="${FALLBACK_RETRY_MIN:-600}"
FALLBACK_RETRY_MAX="${FALLBACK_RETRY_MAX:-21600}"
# nginx's workers (user nobody) read the files: root:nobody, 0750 / 0640
WORKER_GROUP="${FALLBACK_WORKER_GROUP:-nobody}"
mkdir -p "${FALLBACK_DIR}" "${RETRY_DIR}"
chgrp "${WORKER_GROUP}" "${FALLBACK_DIR}" && chmod 750 "${FALLBACK_DIR}"
chmod 700 "${RETRY_DIR}"
for _pem in "${FALLBACK_DIR}"/*.pem; do
    [ -e "${_pem}" ] && chgrp "${WORKER_GROUP}" "${_pem}" && chmod 640 "${_pem}"
done

. /usr/local/lib/mesh-acme.sh

log() { echo "fallback-certs: $*"; }

# The live labels, one per line (labels are [a-z0-9-], so a pattern is enough: no jq).
fetch_labels() {
    curl -sf --connect-timeout 5 --max-time 20 \
        -H "Authorization: Bearer ${GATEWAY_CERT_TOKEN}" \
        "${BACKEND_URL}/gateway/fallback-labels" \
        | grep -o '"label"[[:space:]]*:[[:space:]]*"[a-z0-9-]*"' | sed 's/.*"\([a-z0-9-]*\)"$/\1/' | sort -u
}

# 0 when the label's retry delay has passed (or there is none).
retry_due() {
    [ -s "${RETRY_DIR}/$1" ] || return 0
    [ "$(date +%s)" -ge "$(cut -d' ' -f1 "${RETRY_DIR}/$1")" ]
}

# Push the label's next try back, doubling the delay.
retry_later() {
    _prev=0
    [ -s "${RETRY_DIR}/$1" ] && _prev="$(cut -d' ' -f2 "${RETRY_DIR}/$1")"
    _delay=$(( _prev * 2 ))
    [ "${_delay}" -ge "${FALLBACK_RETRY_MIN}" ] || _delay="${FALLBACK_RETRY_MIN}"
    [ "${_delay}" -le "${FALLBACK_RETRY_MAX}" ] || _delay="${FALLBACK_RETRY_MAX}"
    echo "$(( $(date +%s) + _delay )) ${_delay}" > "${RETRY_DIR}/$1"
    log "$1: next try in ${_delay}s"
}

# fallback/<label>.pem = the certificate acme_best picks for *.<label>.<zone>, replaced only
# when it changed.
install_label() {
    set -- "$1" $(acme_best "$1.${ACME_DOMAIN}")
    [ -n "${2:-}" ] || return 1
    _pem="${FALLBACK_DIR}/$1.pem"
    if [ -s "${_pem}" ] && [ "$(acme_fingerprint "${_pem}")" = "$(acme_fingerprint "$2")" ]; then
        return 0
    fi
    umask 077
    cat "$2" "$3" > "${_pem}.new" && chgrp "${WORKER_GROUP}" "${_pem}.new" && chmod 640 "${_pem}.new" \
        && mv -f "${_pem}.new" "${_pem}" || return 1
    log "$1: serving *.$1.${ACME_DOMAIN} until $(openssl x509 -noout -enddate -in "$2" | cut -d= -f2) ($(openssl x509 -noout -issuer -in "$2" | sed 's/^issuer=//'))"
}

# notAfter of a PEM's first certificate as ISO 8601 UTC, empty when unreadable.
not_after_iso() {
    _end="$(openssl x509 -noout -enddate -in "$1" 2>/dev/null | cut -d= -f2)"
    [ -n "${_end}" ] && date -u -D '%b %d %H:%M:%S %Y GMT' -d "${_end}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# index.json from the files present (expired ones removed first).
write_index() {
    _out="${FALLBACK_DIR}/index.json.new"
    printf '{"labels":{' > "${_out}"
    _first=1
    for _pem in "${FALLBACK_DIR}"/*.pem; do
        [ -e "${_pem}" ] || continue
        _label="$(basename "${_pem}" .pem)"
        if ! openssl x509 -noout -checkend 0 -in "${_pem}" >/dev/null 2>&1; then
            rm -f "${_pem}"
            log "${_label}: expired fallback certificate removed"
            continue
        fi
        _na="$(not_after_iso "${_pem}")"
        [ -n "${_na}" ] || continue
        [ "${_first}" = 1 ] || printf ',' >> "${_out}"
        printf '"%s":"%s"' "${_label}" "${_na}" >> "${_out}"
        _first=0
    done
    printf '},"updatedAt":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${_out}"
    chmod 644 "${_out}"
    mv -f "${_out}" "${FALLBACK_DIR}/index.json"
}

RENEW_SECONDS=$(( GATEWAY_ACME_RENEW_DAYS * 86400 ))
log "every ${FALLBACK_POLL}s from ${BACKEND_URL}/gateway/fallback-labels, CA ${GATEWAY_ACME_SERVER}${GATEWAY_ACME_BACKUP_SERVER:+ (backup ${GATEWAY_ACME_BACKUP_SERVER})}"
sleep 15
while :; do
    if LABELS="$(fetch_labels)"; then
        for label in ${LABELS}; do
            domain="${label}.${ACME_DOMAIN}"
            # cheap path: the served certificate is far from renewal
            if [ -s "${FALLBACK_DIR}/${label}.pem" ] \
                && openssl x509 -noout -checkend "${RENEW_SECONDS}" -in "${FALLBACK_DIR}/${label}.pem" >/dev/null 2>&1 \
                && [ -n "$(acme_best "${domain}")" ]; then
                continue
            fi
            retry_due "${label}" || continue
            acme_obtain "${domain}" || true
            # a still-valid older certificate keeps serving while a renewal fails
            install_label "${label}" || log "${label}: no valid certificate to serve"
            BEST="$(acme_best "${domain}")"
            if [ -n "${BEST}" ] && openssl x509 -noout -checkend "${RENEW_SECONDS}" -in "${BEST%% *}" >/dev/null 2>&1; then
                rm -f "${RETRY_DIR}/${label}"
            else
                retry_later "${label}"
            fi
        done
    else
        log "WARNING: could not read the live labels from the backend, keeping the current certificates"
    fi
    write_index
    sleep "${FALLBACK_POLL}"
done
