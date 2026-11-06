# shellcheck shell=sh
# ACME helpers shared by entrypoint.sh (the gateway's own *.<zone>) and
# scripts/fallback-certs.sh (one fallback *.<user>.<zone> per live user).
#
# Two CAs (phase-1.1-gateway-tls.md §6 in mesh-router-nameserver):
#   primary  GATEWAY_ACME_SERVER         (ZeroSSL on Yundera's gateways, with EAB:
#                                         GATEWAY_ACME_EAB_KID / GATEWAY_ACME_EAB_HMAC)
#   backup   GATEWAY_ACME_BACKUP_SERVER  (Let's Encrypt; empty = no backup)
# The backup is only asked when the primary has no valid certificate for the name, and
# at most GATEWAY_ACME_BACKUP_WEEKLY_MAX new certificates per 7 days: the Let's Encrypt
# bucket of the zone is the boxes' (50 new certificates per week per registered domain).
#
# Each CA keeps its own lego directory, GATEWAY_STATE_DIR/acme/<directory host>, with its
# own account and certificates; a certificate from one CA is never mistaken for another's.
# lego runs one at a time (flock): the two loops share the accounts.
#
# Expects from the caller: GATEWAY_STATE_DIR, LEGO_DNS (and the provider's own env),
# GATEWAY_ACME_SERVER, GATEWAY_ACME_EMAIL, GATEWAY_ACME_RENEW_DAYS.

GATEWAY_ACME_BACKUP_SERVER="${GATEWAY_ACME_BACKUP_SERVER:-}"
GATEWAY_ACME_BACKUP_WEEKLY_MAX="${GATEWAY_ACME_BACKUP_WEEKLY_MAX:-10}"
GATEWAY_ACME_EAB_KID="${GATEWAY_ACME_EAB_KID:-}"
GATEWAY_ACME_EAB_HMAC="${GATEWAY_ACME_EAB_HMAC:-}"
# extra lego global options, e.g. "--dns.resolvers 9.9.9.9:53" (tests: "--dns.propagation-wait 2s")
GATEWAY_ACME_LEGO_ARGS="${GATEWAY_ACME_LEGO_ARGS:-}"
# Bounds on one lego run. lego's own HTTP timeout is off by default: a CA that accepts a
# connection and never answers held a run for good (ZeroSSL, nsp1 2026-11-06), and with
# it the lock both loops share. Per ACME request, then for the whole run (TERM, KILL 30 s
# later). The run bound leaves room for the 2 min propagation wait and a slow CA.
GATEWAY_ACME_HTTP_TIMEOUT="${GATEWAY_ACME_HTTP_TIMEOUT:-60}"
GATEWAY_ACME_RUN_TIMEOUT="${GATEWAY_ACME_RUN_TIMEOUT:-900}"
ACME_LOCK="${GATEWAY_STATE_DIR}/acme/.lego.lock"
ACME_BACKUP_LOG="${GATEWAY_STATE_DIR}/acme/backup-orders"

# The lego directory of a CA: GATEWAY_STATE_DIR/acme/<directory host>.
acme_dir() {
    echo "${GATEWAY_STATE_DIR}/acme/$(echo "$1" | sed -e 's|^[a-z]*://||' -e 's|[/:].*$||')"
}

# Certificate and key lego writes for the wildcard *.<domain> in CA directory $1.
acme_crt() { echo "$1/certificates/_.$2.crt"; }
acme_key() { echo "$1/certificates/_.$2.key"; }

# 0 when CA directory $1 holds a certificate for *.$2 valid at least $3 more seconds.
acme_valid() {
    _crt="$(acme_crt "$1" "$2")"
    _re="$(echo "$2" | sed 's/\./\\./g')"
    [ -s "${_crt}" ] && [ -s "$(acme_key "$1" "$2")" ] \
        && openssl x509 -noout -checkend "$3" -in "${_crt}" >/dev/null 2>&1 \
        && openssl x509 -noout -ext subjectAltName -in "${_crt}" 2>/dev/null | grep -qiE "DNS:\*\.${_re}(,|\$)"
}

# SHA-256 fingerprint of a certificate file, empty when there is none.
acme_fingerprint() {
    openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null || true
}

# New certificates the backup issued in the last 7 days.
acme_backup_count() {
    [ -s "${ACME_BACKUP_LOG}" ] || { echo 0; return; }
    _since=$(( $(date +%s) - 604800 ))
    awk -v s="${_since}" '$1 >= s' "${ACME_BACKUP_LOG}" | wc -l | tr -d ' '
}

# After a run was killed: lego had no chance to remove its challenge TXT. With the
# cloudflare provider a leftover breaks the next order, since the CA hands the same
# pending challenge back and Cloudflare refuses an identical record. Delete exactly the
# records this run created (their IDs are in its output, $1). Other providers: nothing to
# do (the backend's acme-dns takes the same value again).
acme_cleanup_killed() {
    [ "${LEGO_DNS}" = "cloudflare" ] || return 0
    _cf_token="${CLOUDFLARE_DNS_API_TOKEN:-${CF_DNS_API_TOKEN:-}}"
    [ -n "${_cf_token}" ] || return 0
    # lego: "[INFO] cloudflare: new record for <zone>, ID <record id>"
    sed -n 's/.*cloudflare: new record for \([^,]*\), ID \([0-9a-f]*\).*/\1 \2/p' "$1" \
        | while read -r _zone _id; do
            _zid="$(curl -s -m 20 -H "Authorization: Bearer ${_cf_token}" \
                "https://api.cloudflare.com/client/v4/zones?name=${_zone}" \
                | grep -o '"id":"[0-9a-f]\{32\}"' | head -1 | cut -d'"' -f4)"
            if [ -n "${_zid}" ] && curl -s -m 20 -X DELETE -H "Authorization: Bearer ${_cf_token}" \
                "https://api.cloudflare.com/client/v4/zones/${_zid}/dns_records/${_id}" \
                | grep -q '"success":true'; then
                echo "acme: removed the challenge TXT ${_id} the killed run left in ${_zone}"
            else
                echo "WARNING: acme: could not remove the challenge TXT ${_id} in ${_zone}: delete it by hand, the next order fails while it exists"
            fi
        done
}

# One lego run (or renew) for *.$2 at CA $1; $3 = "primary" adds the EAB credential.
# 0 on success.
acme_lego() {
    _dir="$(acme_dir "$1")"
    mkdir -p "${_dir}"
    chmod 700 "${GATEWAY_STATE_DIR}/acme" "${_dir}"
    set -- "$1" "$2" "$3" "${_dir}"
    if [ -s "$(acme_crt "$4" "$2")" ]; then
        _cmd="renew --days ${GATEWAY_ACME_RENEW_DAYS}"
    else
        _cmd="run"
    fi
    # EAB through lego's environment (not argv: the HMAC would show in the process list),
    # for the primary only
    if [ "$3" = "primary" ] && [ -n "${GATEWAY_ACME_EAB_KID}" ] && [ -n "${GATEWAY_ACME_EAB_HMAC}" ]; then
        set -- "$@" true "${GATEWAY_ACME_EAB_KID}" "${GATEWAY_ACME_EAB_HMAC}"
    else
        set -- "$@" false "" ""
    fi
    _try=1
    _log="$(mktemp)"
    while :; do
        # lego's output streams to the container log as it runs, and is kept in _log to
        # recognise a forgotten account; the exit status goes through a file (a pipe's
        # status is tee's in sh)
        # GATEWAY_ACME_LEGO_ARGS comes after --http-timeout, so its own value wins.
        # shellcheck disable=SC2086 # _cmd and GATEWAY_ACME_LEGO_ARGS are word lists
        { LEGO_EAB="$5" LEGO_EAB_KID="$6" LEGO_EAB_HMAC="$7" flock "${ACME_LOCK}" \
            timeout -s TERM -k 30 "${GATEWAY_ACME_RUN_TIMEOUT}" \
            lego --accept-tos --path "$4" --server "$1" --dns "${LEGO_DNS}" \
            --http-timeout "${GATEWAY_ACME_HTTP_TIMEOUT}" ${GATEWAY_ACME_LEGO_ARGS} \
            --domains "*.$2" --email "${GATEWAY_ACME_EMAIL}" ${_cmd} 2>&1; echo $? > "${_log}.rc"; } | tee "${_log}"
        _rc="$(cat "${_log}.rc" 2>/dev/null || echo 1)"
        if [ "${_rc}" -eq 0 ]; then
            rm -f "${_log}" "${_log}.rc"
            return 0
        fi
        # killed by the run bound (busybox timeout: 128 + signal; coreutils: 124)
        if [ "${_rc}" -eq 124 ] || [ "${_rc}" -eq 143 ] || [ "${_rc}" -eq 137 ]; then
            echo "WARNING: acme: lego for *.$2 at $1 killed after ${GATEWAY_ACME_RUN_TIMEOUT}s (GATEWAY_ACME_RUN_TIMEOUT)"
            acme_cleanup_killed "${_log}"
        fi
        # The CA no longer knows the stored account (deactivated, EAB revoked, a test CA
        # restarted): set it aside and register a new one, once.
        if [ "${_try}" = 1 ] && grep -q "accountDoesNotExist" "${_log}"; then
            echo "acme: $1 forgot this gateway's account, registering a new one"
            mv "$4/accounts" "$4/accounts.lost-$(date +%s)" 2>/dev/null || true
            _try=2
            continue
        fi
        rm -f "${_log}" "${_log}.rc"
        return "${_rc}"
    done
}

# Order or renew *.$1 under the two-CA policy. 0 when a valid certificate exists
# afterwards (from either CA). Logs a line on every order.
acme_obtain() {
    _p="$(acme_dir "${GATEWAY_ACME_SERVER}")"
    _renew=$(( GATEWAY_ACME_RENEW_DAYS * 86400 ))
    if ! acme_valid "${_p}" "$1" "${_renew}"; then
        if acme_lego "${GATEWAY_ACME_SERVER}" "$1" primary; then
            echo "acme: *.$1 from ${GATEWAY_ACME_SERVER}, until $(openssl x509 -noout -enddate -in "$(acme_crt "${_p}" "$1")" | cut -d= -f2)"
        else
            echo "WARNING: acme: *.$1 order/renewal failed at ${GATEWAY_ACME_SERVER}"
        fi
    fi
    if [ -n "${GATEWAY_ACME_BACKUP_SERVER}" ] && ! acme_valid "${_p}" "$1" 0; then
        _b="$(acme_dir "${GATEWAY_ACME_BACKUP_SERVER}")"
        if ! acme_valid "${_b}" "$1" "${_renew}"; then
            _used="$(acme_backup_count)"
            if [ "${_used}" -ge "${GATEWAY_ACME_BACKUP_WEEKLY_MAX}" ]; then
                echo "WARNING: acme: *.$1 not ordered at the backup CA: ${_used} backup certificates in 7 days (GATEWAY_ACME_BACKUP_WEEKLY_MAX)"
            else
                _before="$(acme_fingerprint "$(acme_crt "${_b}" "$1")")"
                if acme_lego "${GATEWAY_ACME_BACKUP_SERVER}" "$1" backup; then
                    if [ "$(acme_fingerprint "$(acme_crt "${_b}" "$1")")" != "${_before}" ]; then
                        date +%s >> "${ACME_BACKUP_LOG}"
                    fi
                    echo "acme: *.$1 from the backup ${GATEWAY_ACME_BACKUP_SERVER} (primary failed)"
                else
                    echo "WARNING: acme: *.$1 order failed at the backup ${GATEWAY_ACME_BACKUP_SERVER} too"
                fi
            fi
        fi
    fi
    [ -n "$(acme_best "$1")" ]
}

# "<crt> <key>" of the certificate to serve for *.$1: the primary's while valid, else the
# backup's while valid, else nothing.
acme_best() {
    _p="$(acme_dir "${GATEWAY_ACME_SERVER}")"
    if acme_valid "${_p}" "$1" 0; then
        echo "$(acme_crt "${_p}" "$1") $(acme_key "${_p}" "$1")"
        return
    fi
    if [ -n "${GATEWAY_ACME_BACKUP_SERVER}" ]; then
        _b="$(acme_dir "${GATEWAY_ACME_BACKUP_SERVER}")"
        if acme_valid "${_b}" "$1" 0; then
            echo "$(acme_crt "${_b}" "$1") $(acme_key "${_b}" "$1")"
        fi
    fi
}
