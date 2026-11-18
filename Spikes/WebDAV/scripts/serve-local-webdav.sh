#!/bin/bash
# Local WebDAV test server for the WebDAV spike (M0 Task 13).
#
# Runs the macOS system Apache (/usr/sbin/httpd) with mod_dav as the current
# user. It listens on 127.0.0.1 only; configuration, data and logs live in a
# new directory under $TMPDIR and are removed by `stop`. Nothing under
# /etc/apache2 is read or changed, and no sudo is needed.
#
# The account below is a fake test account for this local server only.
#
#   serve-local-webdav.sh start   start the server, print the env exports
#   serve-local-webdav.sh env     print the env exports again
#   serve-local-webdav.sh stop    stop the server and delete its directory
set -euo pipefail

PORT="${WEBDAV_SPIKE_PORT:-18080}"
SPIKE_USER="eros-spike"
SPIKE_PASSWORD="not-a-real-password"
BASIC_REALM="eros-spike"
DIGEST_REALM="eros-spike-digest"
HTTPD=/usr/sbin/httpd
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"
# Real path: the deny-all <Directory /> disables FollowSymLinks, and /var is a symlink on macOS.
TMP_BASE="$(cd "$TMP_BASE" && pwd -P)"
STATE_FILE="$TMP_BASE/eros-webdav-spike.state"

print_env() {
  local root="$1"
  cat <<EOF
export WEBDAV_SPIKE_URL=http://127.0.0.1:$PORT/dav/
export WEBDAV_SPIKE_DIGEST_URL=http://127.0.0.1:$PORT/dav-digest/
export WEBDAV_SPIKE_USER=$SPIKE_USER
export WEBDAV_SPIKE_PASSWORD=$SPIKE_PASSWORD
export WEBDAV_SPIKE_DATA=$root/data
export WEBDAV_SPIKE_ACCESS_LOG=$root/logs/access.log
EOF
}

# Set while `start` runs; the EXIT trap removes it (and stops httpd) if start does not finish.
START_ROOT=""

abort_start() {
  local status=$?
  if [[ -n "$START_ROOT" ]]; then
    if [[ -f "$START_ROOT/var/httpd.pid" ]]; then
      kill "$(cat "$START_ROOT/var/httpd.pid")" 2>/dev/null || true
      sleep 0.3
    fi
    cat "$START_ROOT/logs/error.log" >&2 2>/dev/null || true
    case "$START_ROOT" in
      "$TMP_BASE"/eros-webdav-spike.*) rm -rf "$START_ROOT" ;;
    esac
    rm -f "$STATE_FILE"
    echo "start failed; removed $START_ROOT" >&2
  fi
  exit "$status"
}

start() {
  if [[ -f "$STATE_FILE" ]]; then
    echo "state file $STATE_FILE exists; run '$0 stop' first" >&2
    exit 1
  fi
  START_ROOT="$(mktemp -d "$TMP_BASE/eros-webdav-spike.XXXXXX")"
  trap abort_start EXIT
  local root="$START_ROOT"
  mkdir -p "$root/data" "$root/empty" "$root/logs" "$root/var"

  /usr/sbin/htpasswd -bc "$root/htpasswd" "$SPIKE_USER" "$SPIKE_PASSWORD" 2>/dev/null
  # htdigest only prompts interactively; the file format is user:realm:MD5(user:realm:password).
  printf '%s:%s:%s\n' "$SPIKE_USER" "$DIGEST_REALM" \
    "$(md5 -q -s "$SPIKE_USER:$DIGEST_REALM:$SPIKE_PASSWORD")" >"$root/htdigest"

  cat >"$root/httpd.conf" <<EOF
ServerRoot "/usr"
Listen 127.0.0.1:$PORT
ServerName 127.0.0.1
PidFile "$root/var/httpd.pid"
DefaultRuntimeDir "$root/var"
Mutex file:$root/var default
ErrorLog "$root/logs/error.log"
LogLevel warn

LoadModule mpm_prefork_module libexec/apache2/mod_mpm_prefork.so
LoadModule unixd_module libexec/apache2/mod_unixd.so
LoadModule authn_core_module libexec/apache2/mod_authn_core.so
LoadModule authn_file_module libexec/apache2/mod_authn_file.so
LoadModule authz_core_module libexec/apache2/mod_authz_core.so
LoadModule authz_user_module libexec/apache2/mod_authz_user.so
LoadModule auth_basic_module libexec/apache2/mod_auth_basic.so
LoadModule auth_digest_module libexec/apache2/mod_auth_digest.so
LoadModule dav_module libexec/apache2/mod_dav.so
LoadModule dav_fs_module libexec/apache2/mod_dav_fs.so
LoadModule alias_module libexec/apache2/mod_alias.so
LoadModule mime_module libexec/apache2/mod_mime.so
LoadModule setenvif_module libexec/apache2/mod_setenvif.so
LoadModule log_config_module libexec/apache2/mod_log_config.so

AddType application/json .json
AddType text/plain .txt
DavLockDB "$root/var/DavLock"

# Request log for documenting what each client sends. Only the scheme of the
# Authorization header is logged, never its value.
SetEnvIf Authorization "^Basic " AUTH_SCHEME=Basic
SetEnvIf Authorization "^Digest " AUTH_SCHEME=Digest
LogFormat "%>s %m \"%U\" query=\"%q\" depth=\"%{Depth}i\" ctype=\"%{Content-Type}i\" accept=\"%{Accept}i\" acharset=\"%{Accept-Charset}i\" aenc=\"%{Accept-Encoding}i\" clen=\"%{Content-Length}i\" auth=\"%{AUTH_SCHEME}e\" ua=\"%{User-Agent}i\" line=\"%r\"" spike
CustomLog "$root/logs/access.log" spike

# Nothing outside the WebDAV directory is served: an empty document root and a
# deny-all default for the whole file system.
DocumentRoot "$root/empty"
<Directory />
  Options None
  AllowOverride None
  Require all denied
</Directory>

Alias /dav-digest "$root/data"
Alias /dav "$root/data"
<Directory "$root/data">
  Dav On
  Options None
  AllowOverride None
  Require all granted
</Directory>
<Location "/dav">
  AuthType Basic
  AuthName "$BASIC_REALM"
  AuthBasicProvider file
  AuthUserFile "$root/htpasswd"
  Require valid-user
</Location>
<Location "/dav-digest">
  AuthType Digest
  AuthName "$DIGEST_REALM"
  AuthDigestProvider file
  AuthUserFile "$root/htdigest"
  Require valid-user
</Location>
EOF

  if ! "$HTTPD" -t -f "$root/httpd.conf" >/dev/null 2>&1; then
    "$HTTPD" -t -f "$root/httpd.conf" >&2 || true
    exit 1
  fi
  "$HTTPD" -f "$root/httpd.conf" -k start
  echo "$root" >"$STATE_FILE"

  for _ in $(seq 1 50); do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then
      trap - EXIT
      START_ROOT=""
      echo "WebDAV server running at http://127.0.0.1:$PORT/dav/ (data $root/data)" >&2
      print_env "$root"
      return 0
    fi
    sleep 0.1
  done
  echo "server did not come up" >&2
  exit 1
}

stop() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "not running (no $STATE_FILE)" >&2
    return 0
  fi
  local root pid
  root="$(cat "$STATE_FILE")"
  if [[ -f "$root/var/httpd.pid" ]]; then
    pid="$(cat "$root/var/httpd.pid")"
    "$HTTPD" -f "$root/httpd.conf" -k stop || kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  case "$root" in
    "$TMP_BASE"/eros-webdav-spike.*) rm -rf "$root" ;;
    *) echo "refusing to delete unexpected path $root" >&2 ;;
  esac
  rm -f "$STATE_FILE"
  echo "WebDAV server stopped; removed $root" >&2
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  env)
    [[ -f "$STATE_FILE" ]] || { echo "not running" >&2; exit 1; }
    print_env "$(cat "$STATE_FILE")"
    ;;
  *)
    echo "usage: $0 start|env|stop" >&2
    exit 64
    ;;
esac
