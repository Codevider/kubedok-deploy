# kubedok-deploy

Install, update, and operate [Kubedok](https://github.com/Codevider/kubedok) on
a server.

Production hosts clone or download only this repository. The application
source lives separately, so a server never needs the full source tree to run
or update Kubedok.

## Install

On a fresh Debian or Ubuntu server:

```bash
git clone https://github.com/Codevider/kubedok-deploy.git kubedok
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

To start a new install from a backup, on another server for example, give
`setup.sh` the archive `kbd backup` made. The database is loaded before the
server first starts, with the backup's encryption key:

```bash
sudo KUBEDOK_RESTORE_FROM=/path/to/kubedok-20260115T103000Z.tar.gz ./setup.sh
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
[infrastructure.md](https://github.com/Codevider/kubedok/blob/main/docs/infrastructure.md).

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
git clone https://github.com/Codevider/kubedok-deploy.git kubedok
cd kubedok
sudo ./scripts/agent-install.sh --token <token> --api-url https://kubedok.example.com
```

On the control-plane host the agent is already installed alongside everything
else, so use `sudo kbd agent-install --token <token>` there instead.

Agents update independently of the control plane, so updating Kubedok does
not restart workloads everywhere at once.

## Move from the single-container image

Installs of the old single-container image (`approxx/kubedok-server` 0.0.x,
with PostgreSQL, the API and nginx in one container) move to the current
release with `migrate-from-monolith.sh`, run on the same server from a clone:

```bash
git clone https://github.com/Codevider/kubedok-deploy.git kubedok
cd kubedok
sudo ./migrate-from-monolith.sh --check     # report, change nothing
sudo ./migrate-from-monolith.sh --dry-run   # rehearse on a copy of the data
sudo ./migrate-from-monolith.sh             # migrate
```

A dump and restore alone would not do: from 1.4.9 on, releases ship their
database migrations squashed into one, under the name of the first migration
the old image applied, so a restored old database looks current and never gets
the schema changes made since. The script brings the data forward on a
scratch copy with the 1.4.8 server image, which still ships them one by one,
and converts what those releases changed the meaning of: a load balancer's
certificate, and nightly host clean-up, which stays off on the migrated hosts.
It checks the result against a fresh database of the target release, then
installs it with `setup.sh`, which loads it before the server first starts.

The encryption key the stored registry passwords and certificates need comes
over from the running API. The JWT secret is made new (`--keep-jwt-secret`
keeps it); sign-ins stay valid either way. When the old install still uses the
image's built-in key, `--check` says so, and `--rotate-encryption-key`
re-encrypts the stored values under a new one. The new install listens where
the old container was published, over plain HTTP as before, unless
`KUBEDOK_HOST`, `KUBEDOK_TLS` or `KUBEDOK_HTTP_PORT` say otherwise. Its nginx
also publishes an HTTPS port, 443 unless `KUBEDOK_HTTPS_PORT` says otherwise,
even without TLS; `--check` says when something on the host, such as a proxy
in front of the old install, already holds it.

Kubedok is down for the few minutes it runs; containers on the managed hosts
keep running. The old container is stopped, its restart policy set to `no`,
and its volume left alone. If anything fails after the stop, it is started
again.

The 0.0.x docs started the old container with
`docker run -d --rm --name kubedok-server -p 80:80 approxx/kubedok-server`.
That puts its data on an anonymous volume, which Docker deletes with the
container whenever it stops: a crash, a Docker restart or a reboot is enough.
`--check` warns about it, and prints the command that makes
`kubedok-monolith-data`, a container that only holds that volume and keeps it
safe until the migration. The migration makes that container itself before it
stops anything. If it has to go back, it starts `kubedok-server` again on that
data, without `--rm`. An old container that survives being stopped but is
named like one of the new install's containers is renamed `kubedok-monolith`.

The 0.0.x docs' example of a persistent volume called it
`kubedok_postgres_data`, which is the name of the new install's database
volume. Move that data to a volume of another name first, while Kubedok can be
down for a minute. Start the container again with the same options it had, its
port and any `-e` settings:

```bash
image="$(docker container inspect -f '{{.Image}}' kubedok-server)"
docker stop kubedok-server && docker rm kubedok-server
docker volume create kubedok_monolith_data
docker run --rm -v kubedok_postgres_data:/from:ro -v kubedok_monolith_data:/to --entrypoint cp "$image" -a /from/. /to/
docker run -d --name kubedok-server --restart unless-stopped -p 80:80 \
  -v kubedok_monolith_data:/var/lib/postgresql/data "$image"
```

Once it serves as before, remove the old volume with
`docker volume rm kubedok_postgres_data`, and run the migration. Deploys, rollouts or agent commands in flight hold it back, unless
`--force` records them as cancelled. What 0.0.x left only looking unfinished
holds nothing back, and is closed in the move: a command whose result it
recorded and then wrote over (a race fixed since), one never answered long
after its timeout, and a deployment or operation untouched for an hour.

The old agents reconnect to the new install by themselves, and their
containers keep running, but they cannot deploy. On each managed host, move
the agent to the release's, as the same host:

```bash
git clone https://github.com/Codevider/kubedok-deploy.git kubedok
cd kubedok
sudo ./scripts/agent-install.sh --adopt
```

`--adopt` copies the agent's state, the identity it registered with, into the
layout `agent-install.sh` makes, so the host keeps its placements and history,
and `kbd agent-update` updates it from then on. Never register a host again
with a new token instead: that makes a second host, and deleting the first
deletes the stacks that ran only there. The new agent gets its overlay and
DNS records from the server as soon as it connects, with no deploy.

Then redeploy each service once, in the order the migration prints. Containers
the old agent started find each other by Docker network aliases, which
containers made since do not have: they find each other through the agent's
DNS forwarder. A container still running as 0.0.x started it can lose a
service redeployed before it. An Alpine-based one does: under the `ndots:0`
Docker sets, musl never tries the search domain for a bare name. So the
services that connect to others go
first, then the ones they connect to, for example `api, worker, then mongo`.
`--check` works the order out from each service's `dependsOn` and the sibling
names in its environment (`mongodb://mongo:27017`). It also warns about a
database image that keeps its data in no volume of its own, since its next
deploy starts it empty, and one on `latest` or no tag, since its next deploy
may pull a newer major version than the one that wrote its data. `--adopt`
warns when a container on the host keeps data in an anonymous volume.

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

See [the release process](https://github.com/Codevider/kubedok/blob/main/docs/release-process.md)
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
./tests/monolith-migration.sh
```

Moves a real 0.0.11 single-container install to the stable release. The old
install holds data made through its own API, and a real 0.0.11 agent, in a
Docker-in-Docker host, runs its services: MongoDB on a named volume, two
services that reach it by name, one on glibc and one on musl, and a web
service on a host port. It checks that `--check` and `--dry-run` change
nothing, and that a migration failing after the stop puts the old install
back. Then it migrates, checks that the old agent takes the overlay the new
server sends it, adopts the agent, checks that the new one serves DNS with no
deploy, and redeploys every service in the order `--check` gives, with
MongoDB keeping its data and both of its users reaching it throughout. Last it
deploys an HTTPS load balancer whose certificate came over from the old
install. Unlike the suite above it pulls the real images, so it needs network
access; it takes about 20 minutes.

The old container is started as the 0.0.x docs had it: `--rm`, named
`kubedok-server`, its data on an anonymous volume. So the migration that fails
has to start it again from the container that holds that volume, and the one
that succeeds has to keep the volume when the container goes. With
`KUBEDOK_TEST_OLD_STYLE=kept`, the old container keeps that name but survives
being stopped, with a named volume and a restart policy, so it is renamed
`kubedok-monolith` instead.

To try a release before it is published, set `KUBEDOK_TEST_MANIFEST` to its
manifest. If its images are on a local registry, published on
`localhost:PORT`, name that registry's container in `KUBEDOK_TEST_REGISTRY`:
the agent host reaches it at the same address.

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

- [Infrastructure](https://github.com/Codevider/kubedok/blob/main/docs/infrastructure.md)
  — topology, environment variables, operations
- [Release process](https://github.com/Codevider/kubedok/blob/main/docs/release-process.md)
  — versioning and the manifest contract

## License

[MIT](LICENSE). The deployment tooling in this repository is MIT-licensed;
the Kubedok application it installs is distributed as container images under
its own terms.
