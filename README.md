# kubedok-deploy

Install, update, and operate [Kubedok](https://github.com/glikaj/kubedok) on
a server.

Production hosts clone or download only this repository. The application
source lives separately, so a server never needs the full source tree to run
or update Kubedok.

## Install

On a fresh Debian or Ubuntu server:

```bash
git clone https://github.com/glikaj/kubedok-deploy.git kubedok
cd kubedok
sudo KUBEDOK_HOST=kubedok.example.com \
     KUBEDOK_LETSENCRYPT_EMAIL=admin@example.com \
     ./setup.sh
```

Clone rather than download a single file: `setup.sh` sources `scripts/common.sh`
and installs the `compose/` files, so it cannot run on its own. The clone is a
one-time bootstrap — everything afterwards runs from `/opt/kubedok`, and
`update.sh` fetches new releases over HTTPS without needing git. You can delete
the clone once the install finishes.

`KUBEDOK_LETSENCRYPT_EMAIL` is optional: without it, the Let's Encrypt account
is registered with no contact address. Without a domain, omit both variables:
it serves HTTP only, with a warning rather than a self-signed certificate.

`setup.sh` installs Docker if needed, generates secrets, pulls the release
images by digest, brings up PostgreSQL, the server, and nginx on private
networks, and obtains a Let's Encrypt certificate. It is idempotent — running
it again never regenerates a secret or touches the database, and keeps the
installed release and the saved settings. A variable given to a re-run
changes that setting and is saved, which is how the host and TLS mode change
later:

```bash
sudo KUBEDOK_HOST=new.example.com ./setup.sh
```

### Behind Cloudflare or another CDN

A proxied DNS record resolves to the CDN, not to your server, so `setup.sh`
stops rather than enable TLS it cannot verify. It names the CDN when it
detects one — the record is not wrong, it just points somewhere else.

Set the record to **DNS only** (grey cloud), run `setup.sh`, then switch it
back to **Proxied** with SSL mode **Full (strict)**. Afterwards, confirm
renewals still reach the origin through the proxy:

```bash
sudo kbd cert-renew --dry-run
```

That last step matters: certificates renew from a timer every 60 days, and a
proxy that rewrites `/.well-known/acme-challenge/` breaks renewal silently
until the certificate expires.

To install without grey-clouding first, pass
`KUBEDOK_TLS_SKIP_DNS_CHECK=true`. Never use Cloudflare's **Flexible** SSL
mode — it leaves edge-to-origin traffic unencrypted across the internet.

Full details, including how to use a Cloudflare Origin CA certificate
instead, are in
[infrastructure.md](https://github.com/glikaj/kubedok/blob/main/docs/infrastructure.md).

## Operate

Everything installs under `/opt/kubedok`, and `setup.sh` adds the `kbd`
command, which runs the install's scripts by name. `kbd help` lists them.

```bash
sudo kbd update --check  # is there an update?
sudo kbd update          # apply it
sudo kbd update --force  # install the current one again
sudo kbd status          # what is running
sudo kbd doctor          # diagnose a problem
sudo kbd logs server     # logs
sudo kbd backup          # back up
sudo kbd rollback        # undo an update
sudo kbd clean           # remove images updates left behind
sudo kbd config          # show the settings
```

Change a setting with `kbd config`. It checks the value, saves it in
`/opt/kubedok/config/kubedok.env`, and restarts only the containers that read
it:

```bash
sudo kbd config set LOG_LEVEL=debug
sudo kbd config unset LOG_LEVEL   # back to the default
```

The host and TLS mode change with a `setup.sh` re-run, and the release with
`kbd update`. An agent keeps its settings in `/opt/kubedok-agent/agent.env`:
edit it there, then run `kbd restart agent`.

Each release installs its own copy of the scripts, `update.sh` and `kbd`
included, in `/opt/kubedok/releases/<version>/scripts/`, and `current` points
at the release that is running. `/usr/local/bin/kbd` links through `current`,
so it always runs that release's scripts. After an update, `previous` points
at the release it replaced, which is where `kbd rollback` goes when it is not
given a version; `kbd rollback --list` shows what is on disk.

## Install an agent

Generate a registration token in the Kubedok UI, then on each Docker host you
want to manage:

```bash
git clone https://github.com/glikaj/kubedok-deploy.git kubedok
cd kubedok
sudo ./scripts/agent-install.sh --token <token> --api-url https://kubedok.example.com
```

On the control-plane host the agent is already installed alongside everything
else, so use `sudo kbd agent-install --token <token>` there instead.

Agents update independently of the control plane, so updating Kubedok does
not restart workloads everywhere at once.

## Layout

```text
setup.sh                    Installer. Idempotent, executable, not sourced.
update.sh                   Updater. Backs up, updates, smoke-tests, commits.
compose/                    One Compose project per component.
  postgres.yml              PostgreSQL. Publishes nothing.
  postgres.public.yml       Overlay that publishes 5432 for debugging.
  server.yml                NestJS API. Publishes nothing.
  nginx.yml                 UI and reverse proxy. The only published ports.
  agent.yml                 Host agent. Host network.
scripts/
  common.sh                 Shared library. Sourced by everything else.
  status.sh                 Containers, health, release, database.
  logs.sh                   Logs, one component or all.
  restart.sh                Restart, in dependency order.
  config.sh                 Show and change settings; restarts what reads them.
  doctor.sh                 Docker, DNS, ports, disk, memory, TLS, isolation.
  backup.sh                 Database dump plus secrets and configuration.
  restore.sh                Guarded restore. Takes a safety backup first.
  rollback.sh               Return to the previous release.
  clean.sh                  Remove images and leftovers updates no longer need.
  cert-renew.sh             Issue and renew certificates; install the timer.
  agent-install.sh          Install the agent on any Docker host.
  agent-update.sh           Update one agent, independently.
  uninstall.sh              Remove containers. Keeps data unless --purge-data.
  kbd                       The kbd command: runs the scripts above by name.
releases/
  release.schema.json       The manifest contract.
  example.json              Documented example. Not a real release.
  <version>.json            One per release, published by release.sh.
channels/
  stable.json               Points at the current stable release.
tests/
  integration.sh            End-to-end test of all of the above.
  cert-probe.sh             TLS paths through the real nginx image.
```

## Architecture

```text
Internet :80/:443
        │
        ▼
   kubedok-nginx ──────┐
                       │  kubedok-proxy network
                       ▼
                 kubedok-server ──────┐
                                      │  kubedok-postgres network
                                      ▼
                               kubedok-postgres
```

Only nginx publishes ports. The server and PostgreSQL are reachable
exclusively over private Docker networks; nginx has no route to the database,
and `doctor.sh` asserts that rather than assuming it.

## Design notes

**Digests, not tags.** Every image reference in a release manifest is
`repo@sha256:…`. A tag can be repointed after publication; a digest cannot.
Two servers installing "1.2.3" a month apart get identical bytes.

**The manifest is a promise.** `release.sh` publishes it only after every
image it names, built for it or kept from the release before, has been
verified pullable.

**`current` is the commit point.** `update.sh` stages the new release tree
outside `releases/`, updates the server, waits for health, updates nginx, and
smoke-tests through the proxy. Only then does the tree move into `releases/`,
`previous` move to the release being replaced, and the `current` symlink move.
A failure before that leaves the previous containers running, or puts them
back, and discards the staged tree, so `releases/` only ever holds releases
that installed and `rollback.sh` never goes to one that failed. A rollback
clears `previous`, so a second one does not roll forward again.

**Secrets are generated once, on the host.** Containers never generate one.
Losing `jwt-secret` logs everyone out; losing `registry-encryption-key` makes
stored registry credentials and certificates permanently undecryptable, so
`backup.sh` includes them and `restore.sh` puts them back.

**The server sees the install, read-only.** `server.yml` mounts the install
root into the server at the same path, read-only, for Server → Maintenance in
the UI: it lists every file of the install and reads `config/kubedok.env`, the
current `release.json`, the web app's certificate and certbot's renewal
settings for it. Of everything else, secrets and backups included, it reads
only names, sizes and dates. The server already holds the three secrets and
the live database. The mount gives the container read access to more, none of
which it opens: the TLS private keys, current and archived; certbot's account
key; `compose.env`, which carries an agent's registration token while one is
being installed; and the backups, which hold earlier database dumps and
secrets. It is read-only because the server runs as root and the scripts in
the root run as root on the host: a writable mount would turn a compromised
server into root on the host. A filesystem mounted separately under the root,
such as `backups/` on its own disk, is read-only inside the container only
where Docker makes read-only binds recursive (Engine 25 and later, kernel 5.12
and later). Files outside the root (the renewal timer's systemd units, an
agent's `/opt/kubedok-agent`) stay out of its view.

**Rollback is not a database rollback.** Rolling an image back does not revert
a migration. Migrations are expand/contract, and a destructive change never
ships in the same release as the code that needs it. If a schema is genuinely
incompatible, restore a backup instead.

**No outbound calls from a request path.** The application never asks Docker
Hub or GitHub about updates. `update.sh` owns update discovery, so an
air-gapped control plane still works. The one exception is opt-in: ordering a
certificate from Let's Encrypt or Google Trust Services in Settings talks to
that CA over HTTPS, when an operator asks and when its renewals are due. The
server needs outbound HTTPS for that, and nothing more — no extra containers,
ports or networks. Without it, everything else works and ordering says it
cannot reach the CA.

## Releases

Releases are cut in the application repository by `scripts/release.sh`, or by
its release workflow, which runs the same script for a pushed `vX.Y.Z` tag. It
builds only the images whose sources changed since they were built, keeps the
others' digests, and commits a manifest to this repository's `releases/`,
pointing `channels/stable.json` at it. The agent has a version of its own
(`agentVersion` in the manifest), PostgreSQL is built only on request, and
publishing a version again replaces its manifest. This repository is never
tagged.

`KUBEDOK_RELEASE` accepts a channel name (`stable`) or an exact version
(`1.2.3`).

See [the release process](https://github.com/glikaj/kubedok/blob/main/docs/release-process.md)
for the manifest contract.

## Testing

```bash
./tests/integration.sh
```

Exercises install, backup, update, rollback, restore, and uninstall against a
real Docker daemon, including the guards that must refuse unsafe operations —
a PostgreSQL major-version change, a tag-pinned manifest, a too-large version
jump.

Two synthetic releases are pushed to a throwaway local registry so the
manifests carry genuine digests, exactly like production, and they are served
over `file://` so the test needs no network. It requires the four `:dev`
images, which are built from the application repository.

```bash
./tests/cert-probe.sh
```

Covers what the suite above cannot, because it installs with
`KUBEDOK_TLS=off`: everything that changes once a hostname and a certificate
are involved. It runs the real nginx image twice — in the pre-issuance state
and then with a certificate in place — and asserts that the ACME pre-flight
in `cert-renew.sh` passes on a correctly wired install and blames the right
layer when the webroot or the public route is broken, that nginx's health
check stays healthy once port 80 only redirects, that the scripts still
reach the API over loopback through that redirect, and that the challenge
path is served over HTTPS too. Let's Encrypt is never contacted. Set
`KUBEDOK_TEST_NGINX_IMAGE` to run it against a released image instead of
`kubedok-nginx:dev`.

## Documentation

- [Infrastructure](https://github.com/glikaj/kubedok/blob/main/docs/infrastructure.md)
  — topology, environment variables, operations
- [Release process](https://github.com/glikaj/kubedok/blob/main/docs/release-process.md)
  — versioning and the manifest contract

## License

[MIT](LICENSE). The deployment tooling in this repository is MIT-licensed;
the Kubedok application it installs is distributed as container images under
its own terms.
