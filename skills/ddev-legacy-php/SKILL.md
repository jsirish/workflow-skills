---
name: ddev-legacy-php
description: Enable EOL PHP versions (5.6–7.4) in DDEV v1.24+ on Apple Silicon (ARM64)
---

# DDEV Legacy PHP Setup

## Problem

DDEV v1.24+ removed end-of-life PHP versions (5.6, 7.0, 7.1, 7.2, 7.3, 7.4) from the default web container images. On Apple Silicon (ARM64) Macs, these versions also lack native ARM64 packages in the Ondřej Surý PPA, so even the built-in `install_php_extensions.sh` script will fail with `Unable to locate package` errors.

## Solution

Two files are needed in the project's `.ddev/` directory:

### 1. Force amd64 emulation

Create `.ddev/docker-compose.amd64.yaml`:

```yaml
services:
  web:
    platform: linux/amd64
```

This forces the web container to run under Rosetta/QEMU x86_64 emulation, giving access to the full x86 PHP package ecosystem.

### 2. Install the legacy PHP version

Create `.ddev/web-build/Dockerfile` (or append to it if one already exists):

```dockerfile
RUN /usr/local/bin/install_php_extensions.sh "php7.4" "${TARGETARCH}"
```

Replace `php7.4` with whichever legacy version is needed (e.g. `php7.2`, `php5.6`).

### 3. Restart DDEV

```bash
ddev restart
```

The first build will take several minutes as it pulls amd64 images. Verify with:

```bash
ddev exec php -v
```

## Steps to Apply

1. Check the project's `.ddev/config.yaml` for `php_version` — confirm it specifies the legacy version.
2. Create `.ddev/docker-compose.amd64.yaml` with the platform override shown above.
3. Create or append to `.ddev/web-build/Dockerfile` with the `install_php_extensions.sh` line, substituting the correct PHP version.
4. Run `ddev restart` and wait for the container build to complete.
5. Verify with `ddev exec php -v`.

## Tradeoffs

- **Performance**: Expect ~20–50% slower execution due to x86 emulation via Rosetta. Native ARM64 services (database, router) are unaffected.
- **Long-term**: This is a stopgap. Upgrading the codebase to PHP 8.1+ is the recommended path — at that point, delete both files to return to native ARM64 performance.

## When to Remove

When the project upgrades to a supported PHP version (8.1+):

1. Delete `.ddev/docker-compose.amd64.yaml`
2. Delete `.ddev/web-build/Dockerfile` (or remove the `install_php_extensions.sh` line)
3. Update `php_version` in `.ddev/config.yaml`
4. Run `ddev restart`

## Reference

- [DDEV Blog: AMD64 with Rosetta on macOS](https://ddev.com/blog/amd64-with-rosetta-on-macos/)
- [DDEV GitHub Issue #6835](https://github.com/ddev/ddev/issues/6835)
- [DDEV Docs: Customizing Images](https://docs.ddev.com/en/stable/users/extend/customizing-images/)
