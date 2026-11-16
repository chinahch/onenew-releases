#!/usr/bin/env bash
set -euo pipefail
umask 077
# BEGIN shared source downloader
# Shared source downloader. This function is embedded into standalone entry scripts.
onenew_download_source() {
  local revision="$1" output="$2" stage="$3" token_file="${4:-${HOME}/.config/onenew/github.token}"
  local token='' config='' mode='' result=0
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || return 1
  if [ -e "$token_file" ] || [ -L "$token_file" ]; then
    [ -f "$token_file" ] && [ ! -L "$token_file" ] || { echo 'GitHub credential must be a regular private file.' >&2; return 1; }
    mode=$(stat -c '%a' "$token_file") || return 1
    { [ "$mode" = 600 ] || [ "$mode" = 400 ]; } && [ "$(stat -c '%u' "$token_file")" = "$(id -u)" ] || { echo 'GitHub credential must belong to the current user with mode 600 or 400.' >&2; return 1; }
    [ "$(wc -c < "$token_file")" -le 16384 ] || return 1
    token=$(cat -- "$token_file")
    [[ ${#token} -ge 16 && ${#token} -le 16384 && "$token" != *[!A-Za-z0-9_.-]* ]] || { echo 'Invalid GitHub credential file.' >&2; return 1; }
    config=$(mktemp "$stage/onenew-auth.XXXXXXXX.curl") || return 1
    chmod 600 "$config"
    printf 'user = "x-access-token:%s"\n' "$token" > "$config"
    unset token
    # Basic credentials are scoped to api.github.com. curl strips them on the
    # cross-host codeload redirect; never use location-trusted or an auth header.
    curl --disable --config "$config" --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 180 \
      "https://api.github.com/repos/chinahch/onenew/tarball/$revision" -o "$output" || result=$?
    rm -f -- "$config"
  else
    curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 180 \
      "https://github.com/chinahch/onenew/archive/$revision.tar.gz" -o "$output" || result=$?
  fi
  if [ "$result" -ne 0 ]; then
    echo 'Source download failed. For a private source repository, save its read-only GitHub credential in ~/.config/onenew/github.token (mode 600), then retry. Existing deployment data was not changed.' >&2
    return "$result"
  fi
}
# END shared source downloader
revision='' package='' target='/opt/onenew' port='7001' public_host='' 
while (($#)); do
  case "$1" in
    --revision|--package|--target|--port|--public-host) (($# >= 2)) || { echo 'Missing argument' >&2; exit 1; }; key="$1"; value="$2"; shift 2; case "$key" in --revision) revision="$value";; --package) package="$value";; --target) target="$value";; --port) port="$value";; --public-host) public_host="$value";; esac;;
    *) echo 'Unknown argument' >&2; exit 1;;
  esac
done
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'A full lowercase source revision is required.' >&2; exit 1; }
[[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || { echo 'Invalid public port.' >&2; exit 1; }
port=$((10#$port))
[[ -z "$public_host" || "$public_host" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { echo 'Public host must be an IPv4 address or hostname without a scheme.' >&2; exit 1; }
for command in docker curl tar mktemp realpath; do command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 1; }; done
docker compose version >/dev/null
[[ -f "$package" && ! -L "$package" ]] || { echo 'Package must be a regular file.' >&2; exit 1; }
package=$(realpath -- "$package")
[[ "$target" = /* && ! -L "$target" ]] || { echo 'Target must be an absolute, new directory.' >&2; exit 1; }
if [[ -e "$target" ]] && { [[ ! -d "$target" ]] || [[ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]]; }; then echo 'Target already contains files; refusing to overwrite.' >&2; exit 1; fi
parent=$(dirname -- "$target")
[[ -d "$parent" ]] || { echo 'Create the target parent directory first.' >&2; exit 1; }
work=$(mktemp -d "$parent/.onenew-restore.XXXXXXXX")
# Only this fresh private staging directory is cleaned. An unsuccessful restore never touches target.
cleanup() { unset password; [[ -n "$work" && -d "$work" ]] && rm -rf -- "$work"; }
trap cleanup EXIT
suffix="${work##*.}"
project="onenew-restored-${suffix,,}"
image="$project:$revision"
[[ "$project" =~ ^onenew-restored-[a-z0-9]{8}$ ]] || { echo 'Invalid private restore project.' >&2; exit 1; }
[[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ]] || { echo 'Restore project already exists; refusing to replace containers.' >&2; exit 1; }
if docker image inspect "$image" >/dev/null 2>&1; then echo 'Restore image already exists; refusing to replace it.' >&2; exit 1; fi
onenew_download_source "$revision" "$work/source.tar.gz" "$work"
mkdir "$work/source" "$work/data"
tar -xzf "$work/source.tar.gz" --strip-components=1 -C "$work/source"
[[ -f "$work/source/Dockerfile" && -f "$work/source/customizations/onenew/migration/core/restore.php" ]] || { echo 'Source revision lacks migration support.' >&2; exit 1; }
docker build --build-arg "ONENEW_REVISION=$revision" -t "$image" "$work/source"
IFS= read -r -s -p 'Migration password: ' password </dev/tty
printf '\n' >/dev/tty
# Password is transmitted only over protected stdin, never an argument or environment variable.
printf '%s\n' "$password" | docker run --rm -i --network none --read-only --tmpfs /tmp:rw,noexec,nosuid --entrypoint php --mount "type=bind,source=$package,target=/package.onm,readonly" --mount "type=bind,source=$work/data,target=/restore" "$image" /opt/onenew/migration/core/restore.php /package.onm /restore/restored "$revision"
unset password
# Restored files remain data: do not source .env or execute package scripts.
restored="$work/data/restored"
[[ -f "$restored/.env" && -d "$restored/data/database" ]] || { echo 'Required restored data is missing.' >&2; exit 1; }
cp -- "$restored/.env" "$work/source/.env"
mkdir -p "$work/source/data/database" "$work/source/data/redis" "$work/source/plugins" "$work/source/storage/theme" "$work/source/storage/logs"
cp -a -- "$restored/data/database/." "$work/source/data/database/"
for path in plugins storage/theme; do
  if [[ -d "$restored/$path" ]]; then cp -a -- "$restored/$path/." "$work/source/$path/"; fi
done
# The archived source is trusted for this exact revision; package .env is excluded from Compose interpolation.
printf 'ONENEW_REVISION=%s\n' "$revision" > "$work/source/.env.compose.restore"
template="$work/source/compose.onenew.sample.yaml"
[[ $(grep -c '^name: onenew$' "$template") == 1 && $(grep -c '^    image: onenew:local$' "$template") == 1 ]] || { echo 'Unexpected trusted Compose template; refusing to deploy.' >&2; exit 1; }
binding='      - "${ONENEW_BIND_IP:-127.0.0.1}:${ONENEW_PORT:-7001}:7001"'
[[ $(grep -Fxc -- "$binding" "$template") == 1 ]] || { echo 'Unexpected Compose port binding.' >&2; exit 1; }
version_arg='        ONENEW_REVISION: "${ONENEW_REVISION:-local}"'
[[ $(grep -Fxc -- "$version_arg" "$template") == 1 ]] || { echo 'Unexpected Compose build revision.' >&2; exit 1; }
sed -e '/ONENEW_REVISION:/c\        ONENEW_REVISION: "'"$revision"'"' -e '/ONENEW_BIND_IP/c\      - "0.0.0.0:'"$port"':7001"' -e "s/^name: onenew$/name: $project/" -e "s/^    image: onenew:local$/    image: $image/" "$template" > "$work/source/compose.yaml"
[[ ! -e "$target" ]] || rmdir -- "$target"
mv -T -n -- "$work/source" "$target"
[[ ! -e "$work/source" ]] || { echo 'Target changed concurrently; refusing to overwrite.' >&2; exit 1; }
cd -- "$target"
ONENEW_REVISION="$revision" docker compose --project-name "$project" --env-file .env.compose.restore -f compose.yaml up -d --build --wait
ONENEW_REVISION="$revision" docker compose --project-name "$project" --env-file .env.compose.restore -f compose.yaml exec -T onenew php artisan onenew:migration-assets
# Resolve the host through a physical default interface, avoiding WARP/tunnel egress.
if [[ -z "$public_host" ]] && command -v ip >/dev/null; then
  iface=$(ip -4 route show table main default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1);exit}}')
  case "$iface" in ''|*warp*|*WARP*|wg*|tun*|tap*|docker*|br-*|veth*|cni*|tailscale*) ;;
    *) candidate=$(curl -4 --noproxy '*' --interface "$iface" --fail --silent --connect-timeout 3 --max-time 5 https://api.ipify.org || true)
       if [[ "$candidate" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then public_host="$candidate"; fi;;
  esac
fi
printf '\nRestored to %s. Public listener: 0.0.0.0:%s\n' "$target" "$port"
# Read the restored admin route using the same fallback as routes/web.php. Works with older source revisions too.
ONENEW_REVISION="$revision" docker compose --project-name "$project" --env-file .env.compose.restore -f compose.yaml exec -T onenew php /dev/stdin "$public_host" "$port" <<'PHP'
<?php
require '/www/vendor/autoload.php';
$app = require '/www/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$path = (string) admin_setting('secure_path', admin_setting('frontend_admin_path', hash('crc32b', config('app.key'))));
$path = implode('/', array_map('rawurlencode', explode('/', trim($path, '/'))));
$host = $argv[1] ?: 'YOUR_PUBLIC_IP';
printf("User URL: http://%s:%s/\nAdmin URL: http://%s:%s/%s\n", $host, $argv[2], $host, $argv[2], $path);
PHP
printf 'Allow TCP %s in the server firewall/security group. Verify login and subscriptions before switching DNS/proxy/tunnel. Keep the old server for rollback.\n' "$port"
