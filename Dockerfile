# A self-hosted GitHub Actions runner, as an ephemeral container.
#
# Exists because these repos are private and their GitHub-hosted Actions
# minutes are exhausted -- every workflow run failed in seconds, with no
# logs ("The job was not started because recent account payments have failed
# or your spending limit needs to be increased"). Self-hosted runners do not
# consume Actions minutes, so CI can tell us something again without waiting
# on a billing change.
#
# One container serves exactly one job and then exits (--ephemeral), so no
# state carries between jobs. See README.md for the security
# reasoning and for why this must not be pointed at a public repository.

FROM ubuntu:24.04

# So that a failure partway through a piped RUN command (e.g. `curl | sha256sum -c`)
# fails the build instead of being masked by the pipe's last exit status.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

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
# git: every checkout. jq: parsing the token response. sudo: workflows here
# install tools with `sudo mv` -- a GitHub-hosted runner has passwordless
# sudo, so a self-hosted one must too or those steps break.
# The python3 packages are a fallback: setup-python normally downloads its
# own build into the tool cache, but a workflow that skips setup-python
# still finds a usable interpreter.
#
# procps is named even though the base image already pulls it in
# transitively. entrypoint.sh deregisters by signalling Runner.Listener with
# pkill, so a future base-image change that dropped the transitive dependency
# would silently reintroduce the leaked-runner bug rather than fail the
# build. Naming it makes that dependency real.
#
# uuid-runtime provides uuidgen, which workflows use to generate unique
# heredoc delimiters when writing multi-line values to $GITHUB_OUTPUT. It is
# present on a GitHub-hosted ubuntu-latest and absent from ubuntu:24.04.
# Versions intentionally unpinned: these come from Ubuntu's rolling package
# mirror, and a version pinned today is routinely gone from the mirror by the
# time this image is rebuilt, breaking the build instead of reproducing it.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        procps \
        sudo \
        tar \
        unzip \
        uuid-runtime \
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
 && chown -R runner:runner "${RUNNER_TOOL_CACHE}" /home/runner \
 # GitHub-hosted runners let the runner user write to /usr/local/bin
 # without sudo -- it is how `download-actionlint.bash ... /usr/local/bin`
 # and similar job-time tool installs work there un-sudoed. This image
 # did not, which is why that class of step kept failing here with
 # "Permission denied" even with passwordless sudo already available:
 # workflows copied from a GitHub-hosted runner do not think to add
 # `sudo`. chown alone is enough -- the directory's existing 0755 already
 # grants the owner write, and root's own installs elsewhere in this
 # file are unaffected since root can write here regardless of owner.
 && chown runner:runner /usr/local/bin

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

# The GitHub CLI. A GitHub-hosted ubuntu-latest ships gh preinstalled, so any
# workflow that shells out to it works there and fails here -- exactly the
# class of difference this image exists to erase. Ubuntu 24.04's own package
# is too old for the `--json` flags these workflows use, so take it from the
# release instead.
#
# Pinned and checksummed for the same reason as the runner tarball above, and
# to retire the workarounds it replaces: consumer repos had begun curling gh
# release tarballs at job time with no checksum verification, a lower bar than
# this file holds itself to everywhere else. Those steps are guarded on gh
# already being on PATH, so they turn into no-ops once this lands and can be
# removed at leisure.
#
# SHAs come from the gh_<version>_checksums.txt asset on
# https://github.com/cli/cli/releases. Bump all three together.
ARG GH_VERSION=2.100.0
ARG GH_SHA256_AMD64=e4d4bb4498e8d007abe545b6568926793ace1b6447da598294a610018cb164be
ARG GH_SHA256_ARM64=ea4e7a581a32ccad6cc7923cb1576ac5859ba4b9a16ab22eb8f8a96e78e2e961

WORKDIR /tmp
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) sha="${GH_SHA256_AMD64}" ;; \
      arm64) sha="${GH_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    dir="gh_${GH_VERSION}_linux_${TARGETARCH}"; \
    url="https://github.com/cli/cli/releases/download/v${GH_VERSION}/${dir}.tar.gz"; \
    curl -fsSL --retry 5 --retry-delay 5 -o gh.tar.gz "${url}"; \
    echo "${sha}  gh.tar.gz" | sha256sum -c -; \
    tar xzf gh.tar.gz; \
    install -m 0755 "${dir}/bin/gh" /usr/local/bin/gh; \
    rm -rf gh.tar.gz "${dir}"; \
    gh --version

# Maven. A JDK itself is not baked in -- it comes from actions/setup-java at
# job time, into the writable RUNNER_TOOL_CACHE, the same as
# actions/setup-python supplies Python interpreters. But setup-java installs
# a JDK, not Maven: GitHub-hosted runners ship Maven separately, pre-installed
# alongside the JDK toolchain, so a workflow that never calls out to install
# it fails here exactly like the gh gap above -- `mvn: command not found`.
#
# The distribution is a pure-Java tarball, identical on every architecture,
# so there is one checksum rather than one per arch. It cannot be sanity
# checked by running `mvn -version` in this layer the way `gh --version`
# checks the CLI above: mvn is a wrapper script that execs java, and no JDK
# exists in the image at build time. Checking the extracted script is
# executable is the closest available substitute.
#
# SHA512 comes from the .sha512 file alongside the release at
# https://dlcdn.apache.org/maven/maven-3/. Bump both together.
ARG MAVEN_VERSION=3.9.16
ARG MAVEN_SHA512=831a8591fe20c8243b1dbe7d71e3244f31d1665b0804b2e825e38cbbe5ce0cafb8338851f90780735568773e0a6cd07bbec107cda0b896b008b861075358b6f6

RUN set -eux;\
    url="https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz";\
    curl -fsSL --retry 5 --retry-delay 5 -o maven.tar.gz "${url}";\
    echo "${MAVEN_SHA512}  maven.tar.gz" | sha512sum -c -;\
    tar xzf maven.tar.gz -C /opt;\
    rm maven.tar.gz;\
    ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn;\
    test -x "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn"

COPY --chown=runner:runner entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# The gh/Maven installs above left WORKDIR at /tmp. entrypoint.sh invokes
# ./config.sh and ./run.sh with relative paths, so it needs to start in the
# directory those actually live in -- without this, every container fails
# immediately with "./config.sh: No such file or directory" and crash-loops
# forever without ever registering as a runner.
WORKDIR /home/runner/actions-runner

USER runner

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
