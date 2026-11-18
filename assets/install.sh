#!/usr/bin/env bash
# Native binary installation; no Docker is used on the node server.
set -Eeuo pipefail
umask 077
VERSION=onenew-v0.1.14
RELEASE=node-v0.1.14
BASE="https://get.timi.baby/releases/$RELEASE"
ROOT=/etc/caddy
PANEL= TOKEN= MACHINE= CHECK=0 UPGRADE=0
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-only) CHECK=1; shift ;;
    --upgrade) UPGRADE=1; shift ;;
    --mode) [ "${2:-}" = machine ] || fail 'Only machine mode is supported'; shift 2 ;;
    --panel) [ "$#" -ge 2 ] || fail 'Missing panel'; PANEL="$2"; shift 2 ;;
    --token) [ "$#" -ge 2 ] || fail 'Missing token'; TOKEN="$2"; shift 2 ;;
    --token-stdin) [ -z "$TOKEN" ] || fail 'Conflicting token options'; IFS= read -r TOKEN || fail 'Token stdin missing'; shift ;;
    --machine-id) [ "$#" -ge 2 ] || fail 'Missing machine ID'; MACHINE="$2"; shift 2 ;;
    *) fail 'Unknown installation argument' ;;
  esac
done
# Supplied bindings are validated before network activity; a bare upgrade
# resolves missing values with the verified helper, never shell-sources files.
if [ -n "$PANEL" ] || [ "$UPGRADE" -eq 0 ]; then
  [[ "$PANEL" =~ ^https://[^/@[:space:]\?#]+(:[0-9]+)?(/[^[:space:]\?#]*)?$ ]] || fail 'A valid HTTPS panel URL is required'
fi
if [ -n "$MACHINE" ] || [ "$UPGRADE" -eq 0 ]; then
  [[ "$MACHINE" =~ ^[1-9][0-9]*$ ]] || fail 'A positive machine ID is required'
fi
[ -n "$TOKEN" ] || [ "$UPGRADE" -eq 1 ] || fail 'A machine token is required'
[ "$(id -u)" -eq 0 ] || [ "$CHECK" -eq 1 ] || fail 'Run as root or sudo'
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) fail 'Unsupported architecture' ;;
esac
# Never install a second agent over an unknown live caddy/php-fpm/XB instance.
if [ "$CHECK" -eq 0 ] && [ "$UPGRADE" -eq 0 ]; then
  for path in "$ROOT" /etc/php-fpm/config.yml /etc/xboard-node/config.yml \
    /etc/systemd/system/caddy.service /lib/systemd/system/caddy.service \
    /usr/lib/systemd/system/caddy.service /etc/init.d/caddy \
    /usr/local/bin/caddy /usr/local/bin/caddyctl /usr/local/bin/caddy-updater \
    /etc/systemd/system/caddy-updater.service /etc/init.d/caddy-updater; do
    { [ ! -e "$path" ] && [ ! -L "$path" ]; } || fail 'Existing caddy service, binary or node configuration found. Back it up and migrate the old service before installing; nothing was replaced.'
  done
  if command -v caddy >/dev/null 2>&1; then
    fail 'A caddy executable already exists in PATH; refusing to shadow or replace it'
  fi
fi
for tool in curl tar sha256sum install cp cmp mktemp awk grep chmod wc; do command -v "$tool" >/dev/null || fail "Missing dependency: $tool"; done
if command -v rc-service >/dev/null && command -v supervise-daemon >/dev/null; then MANAGER=openrc
elif command -v systemctl >/dev/null; then MANAGER=systemd
else fail 'systemd or OpenRC with supervise-daemon is required'; fi
manager_running() {
  if [ "$MANAGER" = systemd ]; then systemctl is-active --quiet caddy.service; else rc-service caddy status >/dev/null 2>&1; fi
}
# The OS manager is authoritative for service state. caddyctl may report
# unknown on OpenRC; still require the exact machine binding and HEALTH=ok.
machine_healthy() {
  manager_running || return 1
  /usr/local/bin/caddyctl instance list --output text 2>/dev/null |
    awk -v panel="${PANEL%/}" -v target="machine_id=$MACHINE" \
      'NR > 1 && $2 == "machine" && $3 == panel && $4 == target && $6 == "ok" { found=1 } END { exit !found }'
}

if [ "$UPGRADE" -eq 1 ]; then
  # Upgrade only known Onenew services; do not change node configuration or certificates.
  for path in "$ROOT/config.yml" "$ROOT/credentials.env" /usr/local/bin/caddy /usr/local/bin/caddyctl; do
    [ -f "$path" ] && [ ! -L "$path" ] || fail 'Upgrade requires a complete native Onenew installation with regular files'
  done
  [ ! -L "$ROOT" ] || fail 'Upgrade refuses a symlinked configuration directory'
  command -v flock >/dev/null || fail 'Missing dependency: flock (install util-linux)'
  [ ! -L "$ROOT/updater.lock" ] || fail 'Assistant lock is a symlink'
  exec 9>"$ROOT/updater.lock"
  flock -n 9 || fail 'Upgrade assistant or another installer holds the upgrade lock'
  LOCKED=1
  # Once bootstrapped, panel upgrades are serialized by the assistant. Refuse
  # concurrent manual replacement rather than interrupt an active transaction.
  if [ -f /usr/local/bin/caddy-updater ]; then
    if { [ "$MANAGER" = systemd ] && systemctl is-active --quiet caddy-updater.service; } ||
       { [ "$MANAGER" = openrc ] && rc-service caddy-updater status >/dev/null 2>&1; }; then
      fail 'Upgrade assistant is running; use the panel remote upgrade action'
    fi
    [ ! -e "$ROOT/updater/journal.json" ] || fail 'Assistant has a pending recovery/result journal; start it and resolve the task first'
  fi
  for path in /etc/php-fpm/config.yml /etc/xboard-node/config.yml; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail 'Conflicting node service found; upgrade refused'
  done
  if [ "$MANAGER" = systemd ]; then
    [ ! -e /etc/init.d/caddy ] && [ ! -L /etc/init.d/caddy ] || fail 'Conflicting OpenRC caddy service found'
    [ -f /etc/systemd/system/caddy.service ] && [ ! -L /etc/systemd/system/caddy.service ] || fail 'Native Onenew systemd service missing'
    property() { systemctl show "--property=$1" --value caddy.service; }
    [ "$(property Description)" = 'Onenew Native Node' ] && \
      [ "$(property FragmentPath)" = /etc/systemd/system/caddy.service ] && \
      [ "$(property WorkingDirectory)" = "$ROOT" ] || fail 'Unknown caddy systemd service; nothing was replaced'
    DROPINS=$(property DropInPaths)
    { [ -z "$DROPINS" ] || [ "$DROPINS" = /run/systemd/system/service.d/zzz-lxc-service.conf ]; } && \
      [ -z "$(property Environment)" ] || fail 'Custom systemd drop-ins or Environment overrides are not supported for upgrade'
    [ "$(property EnvironmentFiles)" = "$ROOT/credentials.env (ignore_errors=no)" ] || fail 'Systemd credentials binding does not match the native installation'
    EXEC=$(property ExecStart)
    [[ "$EXEC" == '{ path=/usr/local/bin/caddy ; argv[]=/usr/local/bin/caddy -c /etc/caddy/config.yml ; ignore_errors=no ;'* ]] && \
      [ "$(printf '%s' "$EXEC" | grep -o 'argv\[\]=' | wc -l)" -eq 1 ] || fail 'Systemd ExecStart does not match the native installation'
    for hook in ExecStartPre ExecStartPost ExecStop ExecStopPost ExecReload; do
      [ -z "$(property "$hook")" ] || fail 'Custom systemd execution hooks are not supported for upgrade'
    done
  else
    [ ! -e /etc/systemd/system/caddy.service ] && [ ! -L /etc/systemd/system/caddy.service ] || fail 'Conflicting systemd caddy service found'
    [ -f /etc/init.d/caddy ] && [ ! -L /etc/init.d/caddy ] && [ -x /etc/init.d/caddy ] || fail 'Native Onenew OpenRC service missing'
    grep -Fxq 'description="Onenew Native Node"' /etc/init.d/caddy && \
      grep -Fxq 'command="/usr/local/bin/caddy"' /etc/init.d/caddy && \
      grep -Fxq 'command_args="-c /etc/caddy/config.yml"' /etc/init.d/caddy && \
      grep -Fxq 'supervisor="supervise-daemon"' /etc/init.d/caddy || fail 'Unknown OpenRC caddy service; nothing was replaced'
    rc-service caddy status >/dev/null 2>&1 || fail 'Existing OpenRC caddy service must be running before upgrade'
  fi
  OLD_VERSION=$(/usr/local/bin/caddy -v 2>/dev/null) || fail 'Cannot identify installed native binary'
  [[ "$OLD_VERSION" == 'caddy onenew-v'*' (built '* ]] || fail 'Installed caddy is not an Onenew native node'
fi
# Assistant targets must never redirect writes outside the managed installation.
for path in /usr/local/bin/caddy-updater /etc/systemd/system/caddy-updater.service /etc/init.d/caddy-updater; do
  [ ! -L "$path" ] || fail 'Upgrade assistant target is a symlink'
done
STAGE=$(mktemp -d)
trap 'if [ "${LOCKED:-0}" -eq 1 ]; then flock -u 9 >/dev/null 2>&1 || true; fi; rm -rf -- "$STAGE"' EXIT
UPDATER="caddy-updater-linux-$ARCH"
curl --proto '=https' --tlsv1.2 -fsSL --retry 2 "$BASE/$UPDATER" -o "$STAGE/$UPDATER"
curl --proto '=https' --tlsv1.2 -fsSL --retry 2 "$BASE/SHA256SUMS-updater-$ARCH" -o "$STAGE/updater-sums"
SUM=$(awk -v file="$UPDATER" '$2 == file && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $1 }' "$STAGE/updater-sums")
[[ "$SUM" =~ ^[0-9a-f]{64}$ ]] || fail 'Missing or ambiguous assistant checksum'
(cd "$STAGE"; printf '%s  %s\n' "$SUM" "$UPDATER" | sha256sum -c - >/dev/null) || fail 'Assistant checksum mismatch; nothing was installed'
chmod 755 "$STAGE/$UPDATER"
if [ "$UPGRADE" -eq 1 ]; then
  [ -n "$PANEL" ] || PANEL=$("$STAGE/$UPDATER" binding --root "$ROOT" --field panel) || fail 'Cannot resolve saved panel binding'
  [ -n "$MACHINE" ] || MACHINE=$("$STAGE/$UPDATER" binding --root "$ROOT" --field machine) || fail 'Cannot resolve saved machine binding'
  [ -n "$TOKEN" ] || TOKEN=$("$STAGE/$UPDATER" binding --root "$ROOT" --field token) || fail 'Cannot resolve saved machine credential'
fi
[[ "$PANEL" =~ ^https://[^/@[:space:]\?#]+(:[0-9]+)?(/[^[:space:]\?#]*)?$ ]] || fail 'A valid HTTPS panel URL is required'
[[ "$MACHINE" =~ ^[1-9][0-9]*$ ]] || fail 'A positive machine ID is required'
[ -n "$TOKEN" ] || fail 'A machine token is required'

install_updater() {
  # Core replacement and health/rollback have completed. Explicitly unlock
  # before launching the daemon; OpenRC children may inherit descriptor 9.
  if [ "${LOCKED:-0}" -eq 1 ]; then flock -u 9; exec 9>&-; LOCKED=0; fi
  # Updating the helper is independent from caddy, and requires no credentials
  # in service arguments or shell environment files.
  local candidate
  candidate=$(mktemp /usr/local/bin/.caddy-updater.XXXXXXXX)
  install -m 755 "$STAGE/$UPDATER" "$candidate"
  mv -f "$candidate" /usr/local/bin/caddy-updater
  if [ "$MANAGER" = systemd ]; then
    cat > /etc/systemd/system/caddy-updater.service <<'UNIT'
[Unit]
Description=Onenew Native Upgrade Assistant
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/caddy-updater run --root /etc/caddy --manager systemd
Restart=always
RestartSec=10
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable caddy-updater.service
    systemctl restart caddy-updater.service
    systemctl is-active --quiet caddy-updater.service || fail 'Upgrade assistant failed to start'
  else
    cat > /etc/init.d/caddy-updater <<'UNIT'
#!/sbin/openrc-run
description="Onenew Native Upgrade Assistant"
command="/usr/local/bin/caddy-updater"
command_args="run --root /etc/caddy --manager openrc"
supervisor="supervise-daemon"
respawn_delay=10
respawn_max=0
output_log="/var/log/caddy-updater.log"
error_log="/var/log/caddy-updater.err"
depend() { need net; }
UNIT
    chmod 755 /etc/init.d/caddy-updater
    rc-update add caddy-updater default
    rc-service caddy-updater restart
    rc-service caddy-updater status >/dev/null || fail 'Upgrade assistant failed to start'
  fi
}
PACKAGE="onenew-node-linux-$ARCH.tar.gz"
curl --proto '=https' --tlsv1.2 -fsSL --retry 2 "$BASE/$PACKAGE" -o "$STAGE/$PACKAGE"
curl --proto '=https' --tlsv1.2 -fsSL --retry 2 "$BASE/SHA256SUMS-$ARCH" -o "$STAGE/SHA256SUMS"
SUM=$(awk -v file="$PACKAGE" '$2 == file && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 { print $1 }' "$STAGE/SHA256SUMS")
[[ "$SUM" =~ ^[0-9a-f]{64}$ ]] || fail 'Missing or ambiguous package checksum'
(cd "$STAGE"; printf '%s  %s\n' "$SUM" "$PACKAGE" | sha256sum -c - >/dev/null) || fail 'Package checksum mismatch; nothing was installed'
# Extract only named executable streams, never arbitrary archive paths.
tar -tzf "$STAGE/$PACKAGE" > "$STAGE/list"
[ "$(wc -l < "$STAGE/list")" -eq 2 ] && grep -qx caddy "$STAGE/list" && grep -qx caddyctl "$STAGE/list" || fail 'Unexpected package contents'
for binary in caddy caddyctl; do
  tar -xzOf "$STAGE/$PACKAGE" "$binary" > "$STAGE/$binary"
  chmod 755 "$STAGE/$binary"
done
OBSERVED=$("$STAGE/caddy" -v)
[[ "$OBSERVED" == "caddy $VERSION (built "* ]] || fail 'Unexpected node version'
if [ "$CHECK" -eq 1 ]; then printf 'Verified %s (%s); no service or configuration changed.\n' "$VERSION" "$ARCH"; exit 0; fi
# Never rotate local credentials or stop a working service until the panel
# has accepted exactly this machine ID and token. A CLI-only token rewrite
# cannot detect stale or mistyped tokens, and previously caused outage loops.
[[ ${#TOKEN} -ge 16 && ${#TOKEN} -le 256 && "$TOKEN" != *[!A-Za-z0-9_+./=~-]* ]] || fail 'Machine token contains unsupported characters'
printf '{"machine_id":%s,"token":"%s"}' "$MACHINE" "$TOKEN" > "$STAGE/auth-request.json"
AUTH_STATUS=$(curl --proto '=https' --tlsv1.2 -sS --max-time 15 \
  --request POST --header 'Content-Type: application/json' \
  --data-binary @"$STAGE/auth-request.json" \
  --output "$STAGE/auth-response.json" --write-out '%{http_code}' \
  "${PANEL%/}/api/v2/server/machine/nodes") || fail 'Panel authentication request failed; existing service untouched'
if [ "$AUTH_STATUS" != 200 ] || ! grep -Eq '"nodes"[[:space:]]*:' "$STAGE/auth-response.json"; then
  fail "Panel machine authentication rejected (HTTP $AUTH_STATUS); existing service untouched"
fi
rm -f -- "$STAGE/auth-request.json" "$STAGE/auth-response.json"
if [ "$UPGRADE" -eq 1 ]; then
  # Validate identity and rotate only the referenced credential on a private copy.
  cp -p "$ROOT/config.yml" "$STAGE/config.yml"
  cp -p "$ROOT/credentials.env" "$STAGE/credentials.env"
  CADDY_MACHINE_TOKEN="$TOKEN" "$STAGE/caddyctl" machine-token \
    --config "$STAGE/config.yml" --credentials "$STAGE/credentials.env" \
    --panel-url "${PANEL%/}" --machine-id "$MACHINE" >/dev/null 2>&1 || fail 'Upgrade panel/machine binding or private credential validation failed; existing service preserved'
  unset TOKEN
  cmp -s "$ROOT/config.yml" "$STAGE/config.yml" || fail 'Candidate CLI changed configuration; upgrade refused'
  # No long-lived backups. Previous binaries are moved on the same filesystem.
  cp -p "$ROOT/credentials.env" "$STAGE/credentials.previous"
  ROLLBACK=$(mktemp -d /usr/local/bin/.onenew-rollback.XXXXXXXX)
  chmod 700 "$ROLLBACK"
  manager_stop() {
    if [ "$MANAGER" = systemd ]; then systemctl stop caddy.service; else rc-service caddy stop; fi
  }
  manager_start() {
    if [ "$MANAGER" = systemd ]; then systemctl start caddy.service; else rc-service caddy start; fi
  }
  rollback_upgrade() {
    local reason="${1:-unexpected failure}"
    trap - ERR INT TERM
    set +e
    printf 'ERROR: Upgrade failed (%s); restoring previous version...\n' "$reason" >&2
    manager_stop >/dev/null 2>&1
    if [ -f "$ROLLBACK/caddy" ]; then
      rm -f /usr/local/bin/caddy
      mv "$ROLLBACK/caddy" /usr/local/bin/caddy
    fi
    if [ -f "$ROLLBACK/caddyctl" ]; then
      rm -f /usr/local/bin/caddyctl
      mv "$ROLLBACK/caddyctl" /usr/local/bin/caddyctl
    fi
    install -m 600 "$STAGE/credentials.previous" "$ROOT/credentials.env"
    manager_start >/dev/null 2>&1
    local restored=0
    # A transient systemd "active" result is insufficient: wait for the
    # previous machine to authenticate and report healthy before cleanup.
    for attempt in {1..15}; do
      if machine_healthy; then restored=1; break; fi
      sleep 2
    done
    if [ "$restored" -eq 1 ] && [ -f /usr/local/bin/caddy ] && [ -f /usr/local/bin/caddyctl ]; then
      rm -rf -- "$ROLLBACK"
      printf 'ERROR: Previous version verified healthy; temporary rollback files removed.\n' >&2
    else
      printf 'ERROR: Previous files restored but service is NOT healthy; emergency files retained at %s\n' "$ROLLBACK" >&2
    fi
    exit 1
  }
  trap 'rollback_upgrade "unexpected command error at line $LINENO"' ERR
  trap 'rollback_upgrade "interrupted"' INT TERM
  manager_stop
  mv /usr/local/bin/caddy "$ROLLBACK/caddy"
  mv /usr/local/bin/caddyctl "$ROLLBACK/caddyctl"
  install -m 755 "$STAGE/caddy" /usr/local/bin/caddy
  install -m 755 "$STAGE/caddyctl" /usr/local/bin/caddyctl
  install -m 600 "$STAGE/credentials.env" "$ROOT/credentials.env"
  manager_start
  HEALTHY=0
  CONSECUTIVE=0
  for attempt in {1..30}; do
    sleep 2
    if machine_healthy; then
      CONSECUTIVE=$((CONSECUTIVE + 1))
      if [ "$CONSECUTIVE" -ge 2 ]; then HEALTHY=1; break; fi
    else
      CONSECUTIVE=0
    fi
  done
  if [ "$HEALTHY" -ne 1 ]; then
    printf 'Diagnostic: manager=%s, service=' "$MANAGER" >&2
    if manager_running; then printf 'running\n' >&2; else printf 'not-running\n' >&2; fi
    /usr/local/bin/caddyctl instance list --output text 2>/dev/null | \
      awk -v panel="${PANEL%/}" -v target="machine_id=$MACHINE" '$2 == "machine" && $3 == panel && $4 == target {printf "Diagnostic: matching machine health=%s\\n", $6; found=1} END {if(!found) print "Diagnostic: matching machine not found"}' >&2 || true
    rollback_upgrade "matching machine health not stable within 60 seconds"
  fi
  trap - ERR INT TERM
  rm -rf -- "$ROLLBACK"
  # Remove only old installer-created directories with the expected file structure.
  for old in "$ROOT".upgrade-backup.*; do
    if [ -d "$old" ] && [ ! -L "$old" ] && [ -f "$old/caddy" ] && [ -f "$old/caddyctl" ] && [ -f "$old/config/credentials.env" ]; then
      rm -rf -- "$old"
    fi
  done
  install_updater
  printf 'Upgraded %s (%s); node configuration preserved and old installer backups cleaned.\n' "$VERSION" "$MANAGER"
  exit 0
fi
mkdir -p "$ROOT" /usr/local/bin
chmod 700 "$ROOT"
"$STAGE/caddyctl" config init --mode machine --panel-url "${PANEL%/}" --token "$TOKEN" --machine-id "$MACHINE" --kernel singbox --health-port 65530 --version "$VERSION" --output "$ROOT/config.yml" --credentials-out "$ROOT/credentials.env" --meta "$ROOT/install-meta.json" --install-root "$ROOT" >/dev/null
unset TOKEN
chmod 600 "$ROOT/config.yml" "$ROOT/credentials.env" "$ROOT/install-meta.json"
install -m 755 "$STAGE/caddy" /usr/local/bin/caddy
install -m 755 "$STAGE/caddyctl" /usr/local/bin/caddyctl
if [ "$MANAGER" = systemd ]; then
  cat > /etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Onenew Native Node
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=/etc/caddy
EnvironmentFile=/etc/caddy/credentials.env
ExecStart=/usr/local/bin/caddy -c /etc/caddy/config.yml
Restart=always
RestartSec=5
LimitNOFILE=1048576
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now caddy.service
  sleep 3
  systemctl is-active --quiet caddy.service || fail 'Node failed to start; inspect journalctl -u caddy'
  # A systemd process can briefly be active while machine discovery is
  # failing with HTTP 403. Verify the configured machine after installation.
  READY=0
  for attempt in {1..30}; do
    if machine_healthy; then
      READY=1; break
    fi
    sleep 2
  done
  [ "$READY" -eq 1 ] || fail 'Node did not reach healthy machine state after install; inspect journalctl -u caddy'
else
  cat > /etc/init.d/caddy <<'UNIT'
#!/sbin/openrc-run
description="Onenew Native Node"
command="/usr/local/bin/caddy"
command_args="-c /etc/caddy/config.yml"
directory="/etc/caddy"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
output_log="/var/log/caddy.log"
error_log="/var/log/caddy.err"
start_pre() {
  set -a
  . /etc/caddy/credentials.env
  set +a
}
depend() { need net; }
UNIT
  chmod 755 /etc/init.d/caddy
  rc-update add caddy default
  rc-service caddy start
  sleep 3
  rc-service caddy status || fail 'Node failed to start; inspect /var/log/caddy.err'
  READY=0
  for attempt in {1..30}; do
    if machine_healthy; then
      READY=1; break
    fi
    sleep 2
  done
  [ "$READY" -eq 1 ] || fail 'Node did not reach healthy machine state after install; inspect /var/log/caddy.err'
fi
install_updater
printf 'Installed %s. Configuration: /etc/caddy. Management: caddyctl\n' "$VERSION"
