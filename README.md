# Onenew node distribution

Public distribution files only. This repository does not contain the panel application, database, machine tokens or GitHub credentials.

`get.timi.baby` is a Cloudflare Worker custom domain. It proxies fixed public native-release asset names and serves the included installer without redirecting clients to GitHub.

## Deployment

Authenticate Wrangler with your own Cloudflare account, then run `npx wrangler deploy` from this directory. The account must control the `timi.baby` zone. Custom Domain deployment manages DNS and TLS; do not point `get.timi.baby` at an unrelated server.

After deployment check:

```bash
curl -fsS https://get.timi.baby/health
curl -fsS https://get.timi.baby/install | head -n 5
curl -fsS https://get.timi.baby/releases/node-v0.1.10/SHA256SUMS-amd64
```

Future generated panel commands can use `bash <(curl -fsSL https://get.timi.baby/install)` and `/upgrade`, supplying the existing machine binding and Token over stdin. These URLs are not live merely because repository files exist. Do not switch the panel command generator before verifying deployment. Alpine requires Bash and curl installed, and the command must be run from Bash.

The install script validates HTTPS, binary checksums, the existing service identity and panel authentication before changing a running node. Upgrade accepts the same binding arguments as install and automatically adds `--upgrade`. No credentials are stored by the Worker.

## Source privacy migration gate

Keep `chinahch/onenew` accessible until the native release import succeeds, future cross-repository publication is configured, and panel upgrade/restore no longer downloads anonymous source archives. A public panel image would expose the PHP source and is not a privacy solution. Repository privacy and Cloudflare deployment have not been changed by creating these files.

## Tests

`node --test test/worker.test.mjs`

The native installer is derived from the Onenew MIT-licensed installer. Native binary dependencies retain their own licenses and corresponding source requirements; retain existing notices and source access when publishing binaries.
