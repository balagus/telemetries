# Building your own images

If your organisation only permits images from an internal registry, you do
not have to wait for that registry to carry an upstream `grafana/*` image at
the version you want. Build your own: take a base image you are already
allowed to use, copy in the binary that
[`bare-metal/install.sh`](../bare-metal/README.md) fetched, and push the
result to your own registry.

You end up back on containers, but with the version choice under your control
rather than the registry's refresh schedule.

```bash
./bare-metal/install.sh                 # fetch the binaries first

BASE_IMAGE=registry.example.com/base/ubi9-minimal:9.5 \
REGISTRY=registry.example.com/observability \
./images/build.sh --push
```

Then run the existing Compose stack on those images:

```bash
REGISTRY=registry.example.com/observability \
  docker compose -f docker-compose.yml -f images/docker-compose.images.yml up -d
```

## Base image requirements

**It must be glibc-based.** Loki, Tempo and Mimir are statically linked and
would run on anything, including `scratch`. **Alloy is not** — it is
dynamically linked against glibc ≥ 2.14. On a musl base (Alpine) it fails at
startup with:

```
exec /usr/local/bin/telemetry-service: no such file or directory
```

which is the dynamic loader missing, not the binary. `build.sh` warns if
`BASE_IMAGE` looks musl-based, but it cannot detect every case — a base whose
name gives nothing away will get through.

Any Debian, Ubuntu, or RHEL/UBI base works. Beyond glibc the base needs:

- **`ca-certificates`**, if the backends reach object storage over HTTPS.
  Nothing is installed at build time on purpose: package installs need
  repository access, which is usually blocked in exactly the environments
  this is meant for. If your base lacks CA certificates, add them in your own
  layer where you do have repository access.
- **a shell**, used once at build time for `mkdir`/`chown`. Every
  general-purpose base has one; a `distroless` base does not.

## What gets built

| Component | Dockerfile | Contents |
|---|---|---|
| loki, tempo, mimir, alloy | [`Dockerfile`](Dockerfile) | one static/dynamic binary |
| grafana | [`Dockerfile.grafana`](Dockerfile.grafana) | the whole tree — Grafana needs its web assets |

Images are tagged `${REGISTRY}/${IMAGE_PREFIX}<component>:<version>`, with the
version read from `bare-metal/defaults.sh` — so tags always match the binaries
that were actually installed. `./images/build.sh --list` shows the tags
without building.

Containers run as UID/GID `10001` by default (`RUN_UID` / `RUN_GID`). A
numeric UID needs no `/etc/passwd` entry, so this works on a minimal base
with no user-management tools. The data directories are created and chowned
at build time, which is what lets Docker hand an empty named volume to a
non-root process.

## Drop-in with the existing Compose file

The images set an `ENTRYPOINT` matching the upstream ones, so
[`docker-compose.images.yml`](docker-compose.images.yml) only overrides
`image:` — ports, volumes, environment and dependency order are all inherited
from `docker-compose.yml`. Config is **not** baked into the images; it stays
mounted from `config/`, exactly as before, so a config change does not force
a rebuild.

The entrypoint binary is installed as `/usr/local/bin/telemetry-service`
rather than under its own name. An exec-form `ENTRYPOINT` cannot expand a
build argument, and a fixed path keeps the entrypoint shell-free so Compose's
arguments pass through untouched. It shows up under that name in `ps`.

MinIO is deliberately not overridden — it is third-party, not built here, and
only provides object storage locally. In a restricted environment you would
point the backends at your existing object storage (`STORAGE_BACKEND=s3`) and
drop the `minio` and `minio-init` services entirely.

## Podman

`DOCKER=podman ./images/build.sh` works; the Dockerfiles use nothing
Docker-specific.

## Kubernetes

These images work unmodified. Mount `config/` as ConfigMaps at the paths in
`docker-compose.yml`, and supply the same environment variables — the full
list is in `bare-metal/defaults.sh`, and
`./bare-metal/stack.sh check-config` verifies none are missing.

For anything beyond a single replica per component, prefer the upstream Helm
charts, which run these components distributed rather than as one process
each. See [`../docs/best-practices.md`](../docs/best-practices.md).

## Verification status

The Dockerfiles and build script have **not been built or run** — the
environment this was developed in has no Docker daemon. What was verified:

- The binaries' linkage, which is what drives the base-image requirement:
  Loki/Tempo/Mimir static, Alloy dynamic against glibc ≥ 2.14.
- The Compose override resolves correctly, with and without a `REGISTRY` set,
  and swaps exactly the five services.
- The argv produced by `ENTRYPOINT` plus Compose's `command:` matches the
  flags the bare-metal launcher uses, which are known to work.

Build them once before relying on them.
