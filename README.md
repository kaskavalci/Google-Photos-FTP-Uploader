# Google Photos FTP Uploader

Manage photos from a **Sony A7** (or other FTP-capable camera): camera → FTP → server → Google Photos, with optional NFS backup. Deploy via git and environment variables; no manual config editing beyond a one-time Google Photos auth step.

**Audience:** Newcomers who want to set this up on a headless server (e.g. Raspberry Pi) and configure everything with env vars.

---

## Prerequisites

- Docker (and Portainer if you use it)
- Google Cloud project with **Photos Library API** enabled and **OAuth 2.0 Desktop** credentials
- Server with a known LAN IP (static or DHCP-reserved)

---

## Quick start

1. Clone this repo on the server.
2. Create host directories (see [Host directories](#host-directories)).
3. Set environment variables (see [Environment variables](#environment-variables)); use the example file as a template.
4. Copy and fill the Google Photos config from `config.hjson.template` (see [Google Photos config](#google-photos-config)).
5. Build the image and deploy the stack (see [Deploy](#deploy)).
6. Run **first-time Google Photos auth** once (see [First-time setup: Google Photos authentication](#first-time-setup-google-photos-authentication)).
7. Create an SFTPGo user and configure the Sony A7 for FTP (see [SFTPGo](#sftpgo) and [Sony A7 FTP](#sony-a7-ftp)).

---

## Host directories

Create these paths **before** deploying the stack (otherwise volume mounts will fail):

```bash
sudo mkdir -p /mnt/ssd/nfs/docker_data/{sftpgo_config,photo_inbox,photo_organized,processor_config}
sudo mkdir -p /mnt/nas/photos
sudo chown -R 1000:1000 /mnt/ssd/nfs/docker_data
```

If you use different paths, set `DOCKER_DATA_PATH` and/or `NFS_PHOTOS_PATH` in your env (see below) and create the corresponding directories.

---

## Environment variables

Set these when deploying the stack (e.g. in Portainer’s stack env, or in a `.env` file). Use **placeholder values** in any committed file; put real values only in `.env` or Portainer.

| Variable | Description | Example |
| -------- | ----------- | ------- |
| `SERVER_LAN_IP` | Server’s LAN IP (used for FTP passive mode) | `192.168.1.10` |
| `GPHOTOS_CLI_TOKENSTORE_KEY` | Passphrase for the encrypted Google Photos token file | `your-secret-passphrase` |
| `TZ` | Timezone for logs | `Europe/Istanbul` |
| `NFS_PHOTOS_PATH` | Host path where NFS is mounted (optional backup) | `/mnt/nas/photos` |
| `DOCKER_DATA_PATH` | Base dir for sftpgo_config, photo_inbox, photo_organized, processor_config | `/mnt/ssd/nfs/docker_data` (default) |
| `PROCESSOR_IMAGE` | Optional: processor image. Default: `ghcr.io/kaskavalci/google-photos-ftp-uploader:latest` (CI-built). Override to use a local or custom image. | `ghcr.io/kaskavalci/google-photos-ftp-uploader:latest` |
| `NOTIFY_WEBHOOK_URL` | Optional: webhook URL for failure notifications (e.g. Home Assistant) | `http://192.168.1.20:8123/api/webhook/your-id` |

Copy `portainer.env.example` to `.env` or paste its variables into Portainer, then replace placeholders with your values. **Do not commit `.env` or real credentials.**

---

## Google Photos config

1. Copy the template into the processor config dir:
   ```bash
   cp config.hjson.template /mnt/ssd/nfs/docker_data/processor_config/config.hjson
   ```
   (Use your actual `DOCKER_DATA_PATH` if different.)

2. Edit `processor_config/config.hjson` and set:
   - **ClientID** and **ClientSecret** — from [Google Cloud Console](https://console.cloud.google.com/) → APIs & Services → Credentials → create OAuth 2.0 Client ID (Desktop app). Enable the Photos Library API for the project.
   - **Account** — the Google account email (e.g. `you@gmail.com`) that will own the uploaded photos.

The rest of the template (`SourceFolder`, `Album`, `IncludePatterns`, etc.) is preconfigured for this stack; leave as-is unless you want to customize. **Do not put real ClientID, ClientSecret, or email in the repo or in README.**

---

## Home Assistant (optional)

To get a push notification when the photo processor fails (e.g. config missing or auth expired):

1. In Home Assistant: **Settings → Automations & Scenes → Webhooks** → Add webhook. Copy the webhook URL.
2. Create an automation: trigger = that webhook; action = notify your phone (or `notify.notify`). Use `{{ trigger.json.title }}` and `{{ trigger.json.message }}` for title and body so the failure details appear.
3. Set `NOTIFY_WEBHOOK_URL` in your stack env to that URL. Use your **Home Assistant server IP** (e.g. `http://192.168.1.20:8123/api/webhook/your-id`), not `homeassistant.local`, so the container can resolve it.

The processor sends a POST with `{"title":"GPhotos", "message":"...", "source":"photo-processor"}` on fatal errors.

---

## Deploy

By default the stack uses the processor image built by CI and published to [GitHub Container Registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry): `ghcr.io/kaskavalci/google-photos-ftp-uploader:latest`. No local build needed — deploy the stack and the host will pull the image.

To build and use a local image instead, set `PROCESSOR_IMAGE=local-photo-processor:latest` and run `docker build -t local-photo-processor:latest .` from the repo root before deploying.

Deploy the stack (e.g. in Portainer: Stacks → Add stack → paste contents of `stack.yaml` → add the environment variables from the example file → Deploy).

### CI

The workflow in `.github/workflows/build-processor.yml` builds the processor image on every push to `main` (or `master`) and pushes it to GitHub Container Registry. The stack defaults to that image (`ghcr.io/kaskavalci/google-photos-ftp-uploader:latest`). The image is public for public repos.

---

## SFTPGo

After the first deploy:

1. Open `http://<SERVER_IP>:8080` and create the admin account.
2. Go to Users → Add. Set **Username** (e.g. `camera`) and **Password**.
3. The user’s home directory will map to `…/photo_inbox/<username>` under your `DOCKER_DATA_PATH`.

---

## Sony A7 FTP

On the camera, set up FTP transfer:

- **Server:** Your server’s LAN IP
- **Port:** **2121** (this stack uses 2121 so SFTPGo can run as non-root; do not use 21)
- **Username / Password:** The SFTPGo user you created
- **Directory:** `/` (SFTPGo maps this to the user’s home)

---

## First-time setup: Google Photos authentication

The server (e.g. Raspberry Pi) usually has no browser. gphotos-uploader-cli does **not** support headless auth; you must complete OAuth once in a browser. Two ways to do it:

### Option A: SSH port forward (recommended)

The auth flow runs in a one-off container on the server. You use your **laptop** and forward port 12345 over SSH so the OAuth callback reaches the container.

1. **On the server:** Ensure `processor_config/config.hjson` exists and has the correct ClientID, ClientSecret, and Account. Then run the auth container (replace `user` and paths if needed). Use the same image as the stack (default: `ghcr.io/kaskavalci/google-photos-ftp-uploader:latest`), or your `PROCESSOR_IMAGE` value if set.
   ```bash
   docker run -it --rm \
     -v "${DOCKER_DATA_PATH:-/mnt/ssd/nfs/docker_data}/processor_config:/config" \
     -p 12345:12345 \
     -e GPHOTOS_CLI_TOKENSTORE_KEY="${GPHOTOS_CLI_TOKENSTORE_KEY}" \
     ghcr.io/kaskavalci/google-photos-ftp-uploader:latest \
     gphotos-uploader-cli auth --config /config --port 12345 --local-bind-address 0.0.0.0
   ```
   Leave this running.

2. **On your laptop:** Open an SSH tunnel to the server (use your server IP and SSH user):
   ```bash
   ssh -L 12345:localhost:12345 user@<SERVER_IP>
   ```
   Keep this SSH session open.

3. **On your laptop:** In a browser, open **http://localhost:12345** (do **not** use the server’s IP). Sign in with the Google account from your config and complete the OAuth flow. The redirect goes through the tunnel to the container, which then writes the token into `processor_config`.

4. Stop the auth container on the server (Ctrl+C). Start or restart the stack so the processor uses the new token.

You do not need to expose port 12345 on the LAN; only SSH is required.

### Option B: Auth on your computer, then copy the token

If you prefer not to use a port or SSH tunnel:

1. On a **Mac or PC with a browser:** Create a directory and copy `config.hjson` into it (with your real ClientID, ClientSecret, Account). Run the same Docker image (or install gphotos-uploader-cli) with that directory as config, run `gphotos-uploader-cli auth` (or `init`) and complete OAuth locally.
2. Copy the **entire** config directory (including the `tokens/` folder) to the server’s `processor_config` (e.g. `scp -r ./config/* user@server:/path/to/processor_config/`). Ensure `config.hjson` on the server has `SourceFolder: /data/photos` for the container.
3. Deploy or start the stack on the server; it will use the copied token.

---

## Optional NFS backup

If you use an NFS share for long-term backup, mount it at `NFS_PHOTOS_PATH`. The watcher can use a `.mounted` marker file on the share to detect when NFS is available; if the file is not visible (e.g. NAS offline), it skips the NFS sync and keeps files on the SSD until the next cycle.

---

## Testing the pipeline

Upload a test image via FTP (using the SFTPGo user and port 2121), then wait a couple of minutes and check Google Photos. If you have a script in `scripts/deployment/`, you can use it; otherwise use any FTP client or the camera’s FTP transfer to drop a file into the inbox.

---

## Troubleshooting

- **Camera connects but no files appear:** Use port **2121** (not 21). Ensure passive mode ports (50000–50100) are available; with `network_mode: host` they should be. Check `docker logs photo-sftpgo`.
- **Files in inbox but not processed:** Check `docker logs photo-processor`. The watcher waits ~1 minute for files to be stable before processing. Ensure `processor_config/config.hjson` has `SourceFolder: /data/photos`.
- **Google Photos upload fails:** Re-run the auth step (Option A or B). Ensure `GPHOTOS_CLI_TOKENSTORE_KEY` is set in the container env. If the error mentions “invalid source folder”, set `SourceFolder` to `/data/photos` in `config.hjson`.
- **NFS sync never runs:** Verify the NFS mount on the host (`df -h <NFS_PHOTOS_PATH>`) and that the share is reachable.
