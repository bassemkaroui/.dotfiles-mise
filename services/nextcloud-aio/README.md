# Nextcloud AIO — the `nextcloud` profile

A Nextcloud server on this machine, reachable **only from your tailnet** at
`https://<node>.<tailnet>.ts.net`. [Nextcloud All-in-One](https://github.com/nextcloud/all-in-one)
runs one *mastercontainer* that creates, updates and backs up every other Nextcloud container
itself; `tailscale serve` publishes it with a certificate Tailscale issues.

| File | Role |
| --- | --- |
| `compose.yaml` | the mastercontainer only — admin interface on `127.0.0.1:8080`, Nextcloud on `127.0.0.1:11000` |
| `settings.toml` | the settings that live in AIO's web interface, recorded (office suite, optional containers) |
| `mise/tasks/install/nextcloud-aio` | starts the mastercontainer, publishes it, prints the first-run checklist |
| `mise/tasks/lib/nextcloud_aio.py` | reads AIO's state read-only — only the recorded keys, never its passphrase or secrets |
| `mise/config.nextcloud.toml` | four `[doctor.checks]`: running, published, settings match, backup set |

What the repo cannot declare — the domain, the containers, the office suite, backups — is set once
in AIO's interface, **recorded** in `settings.toml`, and **checked** by `mise doctor project`.
AIO offers no file or variable for those, and its configuration also holds secrets it generates,
so writing it ourselves was rejected.

## Before the first deploy (once)

- The machine is on your tailnet: `tailscale status` shows it (else `sudo tailscale up`).
- In the Tailscale admin console → **DNS**: **MagicDNS** on and **HTTPS Certificates** enabled.
  The task checks this and skips with a hint otherwise.
- Docker is running and your session is in the `docker` group (`id -nG | grep -w docker`). On a
  fresh machine `install:docker` adds you, which takes effect at your next login.

## Deploy

```bash
mise run setup:profiles            # tick docker, tailscale and nextcloud
mise bootstrap dotfiles apply      # links config.nextcloud.toml (the doctor checks)
mise run install:nextcloud-aio     # from a terminal: it asks for sudo once, for tailscale serve
```

`mise bootstrap --yes` does the same, since the task is the last member of the bootstrap chain.
The task pulls the AIO image, starts the mastercontainer, runs
`sudo tailscale serve --bg --yes http://127.0.0.1:11000`, and prints the checklist from
`settings.toml` with your domain filled in:

1. Open <https://127.0.0.1:8080> on this machine and accept the self-signed certificate.
2. Save the **passphrase** it shows in 1Password: it is the only way back into this interface.
3. Log in and submit the domain: this machine's `*.ts.net` name, as printed. Domain validation is
   skipped (`SKIP_DOMAIN_VALIDATION`), because a tailnet name does not resolve inside the
   container; the doctor check compares what you entered with Tailscale's name instead.
4. Optional containers: follow the checklist. Items marked **(CHANGE)** differ from AIO's
   defaults, so those are the boxes you actually click. Talk is **off**: no calls wanted, and it is
   the only container that would publish a port on every interface (3478).
5. Office suite: **Euro-Office**, which is also AIO's default. HaRP stays off: it only serves
   Nextcloud's external apps (the AI features) and needs Docker-socket access.
6. Timezone: this machine's.
7. Leave **"Install Nextcloud Hub <newer>"** unticked: you get the major the AIO image ships,
   the one AIO has tested. The interface can upgrade to the newer major later, and majors
   never go back down. (`installLatestMajor` in `settings.toml` records this.)
8. **Download and start containers.** Save the initial admin password it shows.

Then confirm:

```bash
mise run install:nextcloud-aio     # now reports "Nextcloud: https://…" and nothing else to do
mise doctor project                # nextcloud-aio-* PASS, except backup (deferred, see below)
```

Clients (desktop, Android/iOS) on any tailnet device use `https://<node>.<tailnet>.ts.net` as the
server address.

## Day to day

- **Updates** happen from AIO's interface: the mastercontainer first, then the containers; a
  newer Nextcloud major has its own upgrade action there. A bootstrap never pulls, recreates or
  updates anything.
- **Euro-Office**: open a document from another tailnet device once after the first start. It
  reaches Nextcloud through the `*.ts.net` name in both directions, and that path is only proven
  end to end by actually editing a file.
- **Health**: `mise doctor project`. It shows a check's exit status but not its output; for the
  actual differences run `python3 ~/.dotfiles-mise/mise/tasks/lib/nextcloud_aio.py check`.
- **Changing a setting**: change it in AIO, then record it in `settings.toml`. Until you do, the
  settings check reports the difference.
- **Changing `compose.yaml`** is not picked up automatically. Stop the containers in AIO's
  interface, run `docker compose -f ~/.dotfiles-mise/services/nextcloud-aio/compose.yaml up -d
  --force-recreate`, then start them again from the interface. **Never add `--remove-orphans`**:
  AIO puts its own containers in the same compose project, so compose would delete them as orphans.

## Backups (not configured yet)

Deferred on 2026-09-27; `nextcloud-aio-backup` fails until a target is set. In AIO's interface,
under backups, choose a host path on a drive that is **not** this machine's disk, or a remote borg
repository. AIO then shows a backup password once; it goes in 1Password next to the passphrase.
Restoring on a new machine means the deploy steps up to the interface, then **restore** instead of
a new instance. It needs only the archive and that password.

## Removal

Deselecting the profile leaves Nextcloud running: `mise bootstrap unapply nextcloud` has nothing
to remove, because this profile only declares health checks. To remove it for real, in this order
(upstream's, plus the serve step):

1. Stop the containers from AIO's interface.
2. `docker stop nextcloud-aio-mastercontainer`, then remove the `nextcloud-aio-*` containers:
   `docker ps -aq --filter name=nextcloud-aio | xargs -r docker rm`. Upstream says
   `docker container prune`, but that also deletes every *other* stopped container on the machine.
3. `sudo tailscale serve --https=443 off`
4. `docker network rm nextcloud-aio`
5. Only if you mean it, since this **deletes every file and the database**: remove the
   `nextcloud_aio_*` volumes (`docker volume ls`).
