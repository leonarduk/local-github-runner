# A self-hosted GitHub Actions runner, as an ephemeral container.
#
# Exists because this repo is private and its GitHub-hosted Actions minutes
# are exhausted -- every workflow run has failed in seconds, with no logs,
# since the repo's first commit ("The job was not started because recent
# account payments have failed or your spending limit needs to be
# increased"). Self-hosted runners do not consume Actions minutes, so CI can
# tell us something again without waiting on a billing change.
#
# One container serves exactly one job and then exits (--ephemeral), so no
# state carries between jobs. See runner/README.md for the security
# reasoning and for why this must not be pointed at a public repository.

FROM ubuntu:24.04

# Pinned deliberately. A runner auto-updates itself at job start unless
# --disableupdate is passed, so this is the floor rather than a hard ceiling
# -- but pinning keeps `docker build` reproducible and makes the checksum
# below meaningful. Bump both together; the SHAs come from the release notes
# at https://github.com/actions/runner/releases.
ARG RUNNER_VERSION=2.337.0
ARG RUNNER_SHA256_AMD64=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613
ARG RUNNER_SHA256_ARM64=9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393

# Set by BuildKit; "amd64" or "arm64".
ARG TARGETARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive \
    # actions/setup-python and friends cache downloaded toolchains here. It
    # must exist and be writable by the runner user, or setup-python fails
    # on a self-hosted runner in a way it never does on a GitHub-hosted one.
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    # Makes the runner handle SIGTERM itself -- finishing or cancelling the
    # current job cleanly -- instead of dying where it stands. Without it,
    # `docker stop` during a job leaves the job hung until GitHub times it
    # out. entrypoint.sh forwards the signal here.
    RUNNER_MANUALLY_TRAP_SIG=1

# ca-certificates/curl/tar: fetching the runner and the registration token.
# git: every checkout. jq: parsing the token response. sudo: the repo's own
# ci.yml installs actionlint with `sudo mv` -- a GitHub-hosted runner has
# passwordless sudo, so a self-hosted one must too or that step breaks.
# The python3 packages are a fallback: setup-python normally downloads its
# own build into the tool cache, but a workflow that skips setup-python
# still finds a usable interpreter.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        sudo \
        tar \
        unzip \
        zstd \
        python3 \
        python3-pip \
        python3-venv \
 && rm -rf /var/lib/apt/lists/*

# The runner refuses to configure or run as root, by design.
RUN useradd --create-home --shell /bin/bash runner \
 && echo 'runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/runner \
 && chmod 0440 /etc/sudoers.d/runner \
 && mkdir -p "${RUNNER_TOOL_CACHE}" /home/runner/actions-runner \
 && chown -R runner:runner "${RUNNER_TOOL_CACHE}" /home/runner

WORKDIR /home/runner/actions-runner

# Download, verify, unpack. The checksum check is the point of this layer:
# without it a corrupted or substituted tarball is executed unnoticed.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) arch=x64;   sha="${RUNNER_SHA256_AMD64}" ;; \
      arm64) arch=arm64; sha="${RUNNER_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${arch}-${RUNNER_VERSION}.tar.gz"; \
    curl -fsSL --retry 5 --retry-delay 5 -o runner.tar.gz "${url}"; \
    echo "${sha}  runner.tar.gz" | sha256sum -c -; \
    tar xzf runner.tar.gz; \
    rm runner.tar.gz; \
    ./bin/installdependencies.sh; \
    chown -R runner:runner /home/runner/actions-runner

COPY --chown=runner:runner entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER runner

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
