# Package a telemetry backend binary onto a base image you are allowed to use.
#
# This exists for the common corporate rule of "images may only come from the
# internal registry". Rather than wait for that registry to carry an upstream
# grafana/* image at the version you want, you build your own: take an
# approved base, copy in the binary that bare-metal/install.sh already
# fetched, and push the result to your own registry.
#
# Build from the REPOSITORY ROOT (the binaries live under bare-metal/bin):
#
#   ./images/build.sh                       # all components
#   ./images/build.sh loki tempo            # just these
#
# or by hand:
#
#   docker build -f images/Dockerfile \
#     --build-arg COMPONENT=loki \
#     --build-arg BASE_IMAGE=registry.example.com/base/ubi9-minimal:9.5 \
#     -t registry.example.com/telemetry/loki:3.3.2 .
#
# Base image requirements:
#   * glibc. Loki, Tempo and Mimir are statically linked and would run on
#     anything, but Alloy is dynamically linked against glibc >= 2.14. A musl
#     base (Alpine) fails at startup with a misleading "no such file or
#     directory" — that is the loader missing, not the binary.
#   * ca-certificates, if the backends talk to object storage over HTTPS.
#     Nothing is installed here: package installs need repository access that
#     is usually blocked in exactly the environments this is aimed at.
#   * a shell, used once at build time for mkdir/chown.
#
# Any Debian, Ubuntu, or RHEL/UBI base satisfies all three.

ARG BASE_IMAGE=docker.io/library/debian:12-slim
FROM ${BASE_IMAGE}

# Which binary from bare-metal/bin to package. Also used for labelling.
ARG COMPONENT
ARG COMPONENT_VERSION=unknown

# Non-root by default. A numeric UID needs no /etc/passwd entry, so this works
# on a minimal base with no user-management tools.
ARG RUN_UID=10001
ARG RUN_GID=10001

LABEL org.opencontainers.image.title="telemetry-${COMPONENT}" \
      org.opencontainers.image.version="${COMPONENT_VERSION}" \
      org.opencontainers.image.description="Upstream ${COMPONENT} binary on a locally approved base image" \
      org.opencontainers.image.source="https://github.com/balagus/telemetries"

# The entrypoint path is fixed rather than named after the component, because
# an exec-form ENTRYPOINT cannot expand a build argument. This keeps the
# entrypoint shell-free, so the arguments in docker-compose.yml are passed
# through untouched and the upstream images stay drop-in replaceable.
COPY --chmod=0755 bare-metal/bin/${COMPONENT} /usr/local/bin/telemetry-service

# Data directories, matching the paths docker-compose.yml mounts volumes on.
# Docker chowns an empty named volume to match the directory it covers, so
# creating them here is what lets the container run as non-root.
RUN mkdir -p /loki /var/tempo /data /var/lib/alloy/data /var/lib/grafana \
 && chown -R ${RUN_UID}:${RUN_GID} /loki /var/tempo /data /var/lib/alloy /var/lib/grafana

USER ${RUN_UID}:${RUN_GID}

ENTRYPOINT ["/usr/local/bin/telemetry-service"]
