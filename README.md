# Snappier Server — Docker

A ready-to-run Docker setup for [Snappier Server](https://snappierserver.app),
an IPTV DVR / recording server. Pre-built Linux images are published to GitHub
Container Registry for Intel/AMD (`amd64`) and ARM (`arm64`) — no building
required.

---

## Install (5 minutes)

### 1. Install Docker on your Linux host

If you don't already have it: <https://docs.docker.com/engine/install/>

Docker Compose v2 is included with modern Docker installs.

### 2. Get the files

```bash
git clone https://github.com/rydizz214/snappier-server-docker.git
cd snappier-server-docker
cp example.env .env
```

### 3. Start it

```bash
docker compose pull
docker compose up -d
```

That's it. Your recordings will be saved to a new `data/` folder right next
to `docker-compose.yml`.

---

## Open the Web UI

On the **same machine** running Docker:

- Go to **<http://localhost:7429>** in a browser.

From a **different machine** (phone, laptop, another server):

The web UI isn't exposed to your network by default, for security. You have
two options:

- **Easy:** SSH into the Docker host and use `localhost:7429` there.
- **Better:** Put a reverse proxy (Nginx, Caddy, Cloudflare Tunnel) in front
  of the container and point it at `127.0.0.1:7429`.

---

## Find your API token

Snappier creates an API token the first time it starts. The easiest place to
see it is in the container's logs:

```bash
docker logs snappier-server | grep -i token
```

(It's also stored in `data/config.json`, and visible in the Web UI's
**Dashboard → Settings** once you can reach the UI.)

---

## What you get out of the box

Everything below is already in the image — no extra setup needed:

- **FFmpeg** (built from the latest source with x264/x265/fdk-aac/vpx/opus).
  **You do NOT need to install FFmpeg on the host** — it's inside the
  container.
- **Recording optimisations:** smart HLS playback, catch-up (timeshift)
  extension, automatic retry if a remux fails.
- **Notifications:** a webhook that fires on every recording event. Plug in
  Pushover keys to get push notifications on your phone (see below).
- **Background helpers** that keep metadata tidy, monitor health, and cache
  provider data.

---

## Common things you'll want to set

Edit `.env` and uncomment / fill in these:

| If you want…                          | Set this in `.env`                                          |
|---------------------------------------|-------------------------------------------------------------|
| Your own timezone                     | `TZ=America/New_York` *(or any IANA zone)*                  |
| A different web port                  | `HOST_PORT=8080` *(default is 7429)*                        |
| Your IPTV provider's EPG (TV guide)   | `EPG_URLS_JSON=[{...}]` *(see comments in example.env)*     |
| Push notifications on your phone      | `PUSHOVER_USER_KEY=…` and `PUSHOVER_APP_TOKEN=…`            |
| Posters & descriptions in notifications | `TMDB_API_KEY=…` *(free key from themoviedb.org; enriches notification messages only — Snappier still records fine without it)* |

After any change to `.env`, restart:

```bash
docker compose up -d
```

---

## Add a VPN (optional)

If you want all IPTV traffic routed through a VPN, Snappier supports 40+ VPN
providers via [gluetun](https://github.com/qdm12/gluetun) (NordVPN, Mullvad,
ProtonVPN, PIA, Surfshark, AirVPN, and more).

1. Add your VPN settings to `.env`. Example for Mullvad over WireGuard:

   ```env
   VPN_SERVICE_PROVIDER=mullvad
   VPN_TYPE=wireguard
   WIREGUARD_PRIVATE_KEY=<paste-your-key>
   SERVER_COUNTRIES=Sweden
   ```

   The exact variable names for your provider are in the
   [gluetun wiki](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers).

2. Start with the VPN turned on:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d
   ```

---

## Where are my files?

Everything lives under `data/` beside `docker-compose.yml`:

```
data/
├── Recordings/     # Scheduled + live recordings
├── Movies/         # VOD movies
├── TVSeries/       # VOD series
├── PVR/            # Timer / PVR state
├── epg/            # Cached TV guide data
├── logs/           # All server + wrapper logs
└── config.json     # Snappier's own config (includes your API token)
```

Want them somewhere else? Set `DATA_DIR=/some/other/path` in `.env`.

---

## Basic commands cheat sheet

```bash
docker compose up -d           # start (detached)
docker compose down            # stop and remove containers
docker compose pull            # download the latest image
docker compose restart         # quick restart
docker compose logs -f         # follow the logs
docker logs -f snappier-server # just the Snappier container's logs
```

---

## Troubleshooting

<details>
<summary>I can't reach http://localhost:7429 from another device</summary>

The port is locked to `127.0.0.1` (localhost only) for security. Either:

- Use a reverse proxy (Nginx, Caddy, Cloudflare Tunnel) — recommended, gives
  you HTTPS too.
- Or edit `docker-compose.yml` and change `"127.0.0.1:${HOST_PORT:-7429}:8000"`
  to just `"${HOST_PORT:-7429}:8000"` to expose on all interfaces. **Only do
  this on a trusted network** — Snappier's built-in TLS is off by default.

</details>

<details>
<summary>Where's my API token?</summary>

Quickest:

```bash
docker logs snappier-server | grep -i token
```

Also visible in `data/config.json` and the Web UI's **Dashboard → Settings**.

</details>

<details>
<summary>Something broke — how do I reset?</summary>

```bash
docker compose down
docker compose pull
docker compose up -d
```

If you want to nuke the data too, delete the `data/` folder. **This wipes
your recordings** — don't do it unless you mean it.

</details>

---

## Advanced

<details>
<summary>Build the image yourself instead of pulling from GHCR</summary>

```bash
docker compose build
docker compose up -d
```

The Dockerfile handles both `amd64` and `arm64` automatically via Docker's
`TARGETARCH`. The FFmpeg build stage pulls the latest upstream stable release
at build time.

</details>

<details>
<summary>Use your host's FFmpeg instead of the built-in one</summary>

The built-in FFmpeg is fully featured and works on both Intel and ARM. Only
override it if you need hardware acceleration (NVENC, QuickSync) or a
vendor-patched FFmpeg. **x86-64 hosts only.**

```bash
docker compose -f docker-compose.yml -f docker-compose.host-ffmpeg.yml up -d
```

</details>

<details>
<summary>Turn on VPN + host FFmpeg at the same time</summary>

```env
# in .env
COMPOSE_FILE=docker-compose.yml:docker-compose.vpn.yml:docker-compose.host-ffmpeg.yml
```

Then just `docker compose up -d`.

</details>

<details>
<summary>Full variable reference</summary>

See [`example.env`](example.env) — every supported variable is documented
inline.

</details>

---

## License

See upstream Snappier Server licensing at <https://snappierserver.app>. This
repository contains only the Docker packaging, wrappers, and helper scripts.
