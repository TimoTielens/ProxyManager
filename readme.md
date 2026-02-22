# NPMplus + CrowdSec — Docker Compose Stack

A self-hosted reverse proxy setup combining **Nginx Proxy Manager Plus (NPMplus)** with **CrowdSec** for threat intelligence and an **nginx bouncer** to block malicious IPs automatically.

---

## Stack Overview

| Service | Image | Purpose |
|---|---|---|
| `npmplus` | `zoeyvid/npmplus` | Reverse proxy + SSL (Let's Encrypt) |
| `crowdsec` | `crowdsecurity/crowdsec` | Security engine, log analysis & threat sharing |
| `cs-bouncer` | `crowdsecurity/cs-nginx-bouncer` | Blocks IPs flagged by CrowdSec |

All services communicate over an internal Docker network called `proxy`.

---

## Project Structure

```
.
├── docker-compose.yml
├── .env                  # Your local config (not committed to git)
├── .env.example          # Template
└── deploy.sh             # One-shot bootstrap script
```

---

## Quick Start

### 1. Clone / copy these files

```bash
git clone <your-repo> npmplus-crowdsec
cd npmplus-crowdsec
```

### 2. Configure your environment

```bash
cp .env.example .env
```

Edit `.env` and set your timezone at a minimum:

```ini
TZ=Europe/Amsterdam
```

### 3. Run the deploy script

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Start CrowdSec and wait until it is healthy.
2. Register a new bouncer (`npmplus-bouncer`) and inject its API key into `.env`.
3. Start the full stack with `docker compose up -d`.
4. Print the admin URL and default credentials.

### 4. Log in to NPMplus

Open `http://<your-server-ip>:81` in your browser.

| Field | Default value |
|---|---|
| Email | `admin@example.com` |
| Password | `changeme` |

> ⚠️ **Change the password immediately** after your first login.

---

## Manual Deployment (without the script)

If you prefer to run things step by step:

```bash
# 1. Start CrowdSec
docker compose up -d crowdsec

# 2. Wait ~10 seconds, then register a bouncer
docker exec crowdsec cscli bouncers add npmplus-bouncer

# 3. Copy the printed key into .env
#    CROWDSEC_BOUNCER_KEY=<key>

# 4. Start the rest
docker compose up -d
```

---

## Managing CrowdSec

All CrowdSec management is done via `cscli` inside the container.

```bash
# View active decisions (bans)
docker exec crowdsec cscli decisions list

# Manually ban an IP
docker exec crowdsec cscli decisions add --ip 1.2.3.4

# Remove a ban
docker exec crowdsec cscli decisions delete --ip 1.2.3.4

# List registered bouncers
docker exec crowdsec cscli bouncers list

# List installed collections
docker exec crowdsec cscli collections list

# Install an additional collection (e.g. Linux base)
docker exec crowdsec cscli collections install crowdsecurity/linux
docker compose restart crowdsec
```

---

## Adding Proxy Hosts in NPMplus

1. Log in to the admin UI at port `81`.
2. Go to **Proxy Hosts → Add Proxy Host**.
3. Enter your domain name, forward hostname (e.g. a container name on the `proxy` network), and port.
4. On the **SSL** tab, request a Let's Encrypt certificate and enable **Force SSL**.
5. Save — NPMplus will handle certificate issuance automatically.

For containers you want to proxy, make sure they are attached to the `proxy` network:

```yaml
# In your other service's docker-compose.yml
networks:
  proxy:
    external: true
```

---

## Updating the Stack

```bash
docker compose pull
docker compose up -d --remove-orphans
```

---

## Volumes

| Volume | Contents |
|---|---|
| `npm_data` | NPMplus database, configs, logs |
| `npm_letsencrypt` | Let's Encrypt certificates |
| `crowdsec_data` | CrowdSec decisions database |
| `crowdsec_config` | CrowdSec parsers, scenarios, collections |
| `cs_bouncer_config` | nginx bouncer configuration |

---

## Ports

| Port | Service | Purpose |
|---|---|---|
| `80` | NPMplus | HTTP (redirected to HTTPS) |
| `443` | NPMplus | HTTPS |
| `81` | NPMplus | Admin web UI |

CrowdSec and the bouncer do **not** expose any ports to the host.

---

## Security Notes

- The admin UI (port `81`) should be firewalled or restricted to trusted IPs in production.
- CrowdSec participates in the community threat-sharing network by default. You can opt out in `/etc/crowdsec/config.yaml` inside the container.
- The `.env` file contains secrets — add it to `.gitignore` and never commit it.

```bash
echo ".env" >> .gitignore
```

---

## Troubleshooting

**CrowdSec not blocking IPs?**
```bash
docker logs crowdsec
docker exec crowdsec cscli decisions list
```

**NPMplus can't reach CrowdSec API?**
Ensure both services are on the same Docker network (`proxy`) and the bouncer key in `.env` is correct.

**Let's Encrypt certificate errors?**
Make sure ports `80` and `443` are open on your firewall and your domain's DNS points to your server's public IP.
