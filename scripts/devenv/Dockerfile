# Development image for Claude Code for Unraid.
#
# Everything `make check` needs, pinned:
#   - base image by digest (Dependabot keeps the digest current)
#   - shellcheck, shfmt, bats-core and actionlint by release version and SHA256
#
# To update a pinned tool: change the version and the SHA256 below. Get the
# SHA256 from the project's published checksum file when it has one
# (actionlint_<ver>_checksums.txt, shfmt sha256sums.txt), otherwise download the
# artifact and run `sha256sum` on it. To update the base image digest:
#   docker pull php:8.3-cli-bookworm
#   docker inspect --format '{{index .RepoDigests 0}}' php:8.3-cli-bookworm
#
# PHP 8.3 matches Unraid 7.0 to 7.2; Unraid 7.3 ships PHP 8.4, so the code must
# avoid anything deprecated in 8.4 (php -l does not catch that; keep it simple).
FROM php:8.5-cli-bookworm@sha256:104890ada56869090c9cd0ec709fe205834d3e383b46d9995dc16cd6388a9302

ARG SHELLCHECK_VERSION=0.11.0
ARG SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
ARG SHFMT_VERSION=3.14.1
ARG SHFMT_SHA256=76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf
ARG BATS_VERSION=1.14.0
ARG BATS_SHA256=bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177
ARG ACTIONLINT_VERSION=1.7.12
ARG ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8

# Tools the plugin scripts also find on Unraid (bash, coreutils, util-linux,
# xz, curl, wget, gnupg for the CI-side release verification, xmllint for the
# plg lint). No jq on purpose: the box does not guarantee it, so tests must not
# depend on it either.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bash ca-certificates curl wget xz-utils gnupg libxml2-utils make git \
      util-linux procps file bsdextrautils python3; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    cd /tmp; \
    curl -fsSL --proto '=https' --tlsv1.2 -o shellcheck.tar.xz \
      "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz"; \
    echo "${SHELLCHECK_SHA256}  shellcheck.tar.xz" | sha256sum -c -; \
    tar -xJf shellcheck.tar.xz; \
    install -m 0755 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck; \
    rm -rf shellcheck.tar.xz "shellcheck-v${SHELLCHECK_VERSION}"; \
    \
    curl -fsSL --proto '=https' --tlsv1.2 -o shfmt \
      "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64"; \
    echo "${SHFMT_SHA256}  shfmt" | sha256sum -c -; \
    install -m 0755 shfmt /usr/local/bin/shfmt; \
    rm -f shfmt; \
    \
    curl -fsSL --proto '=https' --tlsv1.2 -o bats.tar.gz \
      "https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz"; \
    echo "${BATS_SHA256}  bats.tar.gz" | sha256sum -c -; \
    tar -xzf bats.tar.gz; \
    "bats-core-${BATS_VERSION}/install.sh" /usr/local; \
    rm -rf bats.tar.gz "bats-core-${BATS_VERSION}"; \
    \
    curl -fsSL --proto '=https' --tlsv1.2 -o actionlint.tar.gz \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"; \
    echo "${ACTIONLINT_SHA256}  actionlint.tar.gz" | sha256sum -c -; \
    tar -xzf actionlint.tar.gz actionlint; \
    install -m 0755 actionlint /usr/local/bin/actionlint; \
    rm -f actionlint.tar.gz actionlint; \
    \
    shellcheck --version; shfmt --version; bats --version; actionlint --version; php --version

# Slackware pkgtools (installpkg, upgradepkg, removepkg, makepkg, explodepkg)
# from the frozen 15.0 release tree, so the package can be installed exactly
# the way Unraid installs it. The scripts are bash and only need tar and xz.
# Verified 2026-10-22 against the Slackware Linux Project signing key
# (docs/SPIKE.md section 12); the sha256 below pins what was verified.
ARG PKGTOOLS_PKG=pkgtools-15.0-noarch-42.txz
ARG PKGTOOLS_SHA256=472e18ebf561ccc2fa734db8d19101220b5d790012d0688d92009d99e87595f5
RUN set -eux; \
    cd /tmp; \
    curl -fsSL --retry 3 -o pkgtools.txz \
      "https://mirrors.slackware.com/slackware/slackware64-15.0/slackware64/a/${PKGTOOLS_PKG}"; \
    echo "${PKGTOOLS_SHA256}  pkgtools.txz" | sha256sum -c -; \
    mkdir pkgtools; \
    tar -xJf pkgtools.txz -C pkgtools sbin/installpkg sbin/upgradepkg sbin/removepkg sbin/makepkg sbin/explodepkg; \
    install -m 0755 pkgtools/sbin/* /sbin/; \
    rm -rf pkgtools pkgtools.txz; \
    installpkg --help 2>&1 | head -n 2

# The repository is bind-mounted and may be owned by another uid.
RUN git config --system --add safe.directory '*'

# A writable HOME for whatever uid runs the container (CI runners are not root).
RUN mkdir -p /tmp/home && chmod 1777 /tmp/home
ENV HOME=/tmp/home
WORKDIR /work
CMD ["bash"]
