# Custom setup scripts

Advanced mode lets you run your own shell script inside the guest while Sandfort
builds a trusted baseline. It is the extension point for everything the built-in
tool options do not cover.

This document explains exactly when the script runs, the rules it must follow,
worked examples, and the things a script must never do.

## When it runs, and what happens if it fails

The script is embedded in the cloud-init seed and executed once, inside the
guest, during baseline creation or **Rebuild**. In order:

1. The distribution updates itself and installs the baseline packages.
2. Sandfort verifies every selected tool and the desktop.
3. Security settings are applied: SSH disabled and masked, firewall, SELinux or
   AppArmor, automatic security updates.
4. **Your script runs, as root.**
5. Package caches are cleaned and journals compacted.
6. The completion marker is written and the VM powers itself off.

Two consequences follow from that ordering, and both surprise people:

- **A non-zero exit fails the entire setup.** The finalizer runs under
  `set -Eeuo pipefail` with an `ERR` trap, so if your script returns an error,
  no baseline is created at all. The VM stays on with a diagnostic login instead.
  This is deliberate: a baseline is meant to be trustworthy, and one where setup
  half-finished is not. Do not click **Finish Setup** after a failure.
- **Everything before step 4 is already available.** Git, curl, and jq are
  installed and verified, along with Python and Node.js if you selected them, so
  your script can rely on them.

The script never runs on your Mac. It runs only in the guest.

## Rules

| Rule | Why |
| --- | --- |
| Start with a shebang, normally `#!/usr/bin/env bash` | It is executed by path, not sourced |
| Use `set -euo pipefail` | Your script is a separate process; the finalizer's options do not apply inside it |
| Never prompt for input | Setup is unattended. A prompt waits forever and the VM never powers off |
| Keep it under 64 KiB | Sandfort rejects anything larger before starting |
| No passwords, tokens, or keys | The script is stored in app state and written into the seed image |
| Exit non-zero only when you mean it | That aborts the whole baseline |

Setup runs with NAT network access, so a script can download what it needs. Note
the asymmetry: clean instances default to **offline**, so anything you want
available later should be installed or cached now, not fetched at run time.

Changing the script does not alter an existing baseline. Choose **Rebuild** to
apply it.

## Installing packages across profiles

Sandfort's four profiles use three package managers, so detect rather than
assume. Every example below builds on this helper:

```bash
#!/usr/bin/env bash
set -euo pipefail

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "$@"
  elif command -v dnf5 >/dev/null 2>&1; then
    dnf5 -y install "$@"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "$@"
  else
    echo "No supported package manager found." >&2
    return 1
  fi
}
```

Package names are not consistent between distributions. The ones used below were
checked against the official Ubuntu 24.04, Debian 13, Fedora 44, and openSUSE
Leap 16 repository indexes on 2026-08-03:

| Tool | Ubuntu | Debian | Fedora | openSUSE Leap |
| --- | --- | --- | --- | --- |
| Go | `golang-go` | `golang-go` | `golang` | `go` |
| Rust compiler | `rustc` | `rustc` | `rust` | `rust` |
| fd | `fd-find` | `fd-find` | `fd-find` | `fd` |
| ShellCheck | `shellcheck` | `shellcheck` | `ShellCheck` | `ShellCheck` |
| dconf CLI | `dconf-cli` | `dconf-cli` | `dconf` | `dconf` |
| gsettings | `libglib2.0-bin` | `libglib2.0-bin` | `glib2` | `glib2-tools` |
| pipx | `pipx` | `pipx` | `pipx` | `python313-pipx` |

`podman`, `zsh`, `tmux`, `ripgrep`, `bat`, `htop`, `tree`, `unzip`, `make`, and
`gcc` are spelled the same on all four.

Some tools also install under a different **binary** name than you expect, which
is why the examples probe for both rather than assuming.

## Scenarios

Each example is a complete script. They have been checked for package
availability only; none has been run through a full baseline build, so treat
them as starting points and read every line before using one.

### 1. Cache dependencies for offline work

The most useful one, because it exploits how Sandfort works: setup has network
access and clean instances do not. Warming caches during setup lets an offline
instance still install.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Runs as root, so populate the sandfort user's caches as that user.
sudo -u sandfort bash <<'USER_SETUP'
set -euo pipefail
mkdir -p ~/offline

# npm: download tarballs into the user cache without installing.
if command -v npm >/dev/null 2>&1; then
  npm cache add typescript eslint prettier || true
fi

# pip: keep wheels on disk for later offline installs.
if command -v python3 >/dev/null 2>&1; then
  python3 -m pip download --dest ~/offline/wheels requests rich || true
fi
USER_SETUP

echo "Offline caches prepared."
```

Afterwards, in an offline instance, `pip install --no-index --find-links
~/offline/wheels requests` should succeed. Note the finalizer cleans the
*system* package-manager caches after your script, but not files under
`/home/sandfort`.

The `|| true` matters: a transient network failure while warming an optional
cache should not destroy an otherwise good baseline. Use it for genuinely
optional steps, and omit it where failure should stop the build.

### 2. Extra language toolchains

```bash
#!/usr/bin/env bash
set -euo pipefail

install_packages() { :; }  # paste the helper from above

if command -v zypper >/dev/null 2>&1; then
  go_pkg=go rust_pkg=rust
elif command -v dnf5 >/dev/null 2>&1; then
  go_pkg=golang rust_pkg=rust
else
  go_pkg=golang-go rust_pkg=rustc
fi

install_packages "$go_pkg" "$rust_pkg" cargo make gcc

go version
cargo --version
```

Ending with the version commands is intentional: if a package silently did not
provide what you expected, setup fails now rather than producing a baseline that
looks fine and is not.

For a specific Go or Rust version, install `rustup` or the upstream tarball
instead — but do it here, during setup, while the network is available.

### 3. Rootless containers

For running untrusted images inside the sandbox.

```bash
#!/usr/bin/env bash
set -euo pipefail

install_packages() { :; }  # paste the helper from above
install_packages podman

# Subordinate ID ranges are what make rootless containers work.
grep -q '^sandfort:' /etc/subuid || usermod --add-subuids 100000-165535 sandfort
grep -q '^sandfort:' /etc/subgid || usermod --add-subgids 100000-165535 sandfort

sudo -u sandfort podman info >/dev/null
echo "Rootless podman ready."
```

A container inside the sandbox is a second boundary of its own quality. It is
not a Sandfort guarantee, and it does not make the guest safe to trust.

### 4. Terminal working environment

```bash
#!/usr/bin/env bash
set -euo pipefail

install_packages() { :; }  # paste the helper from above

if command -v zypper >/dev/null 2>&1; then fd_pkg=fd; else fd_pkg=fd-find; fi
install_packages zsh tmux ripgrep bat htop tree "$fd_pkg"

# Debian and Ubuntu install these under different binary names.
sudo -u sandfort bash <<'USER_SETUP'
set -euo pipefail
mkdir -p ~/.local/bin
command -v fd  >/dev/null 2>&1 || ln -sf "$(command -v fdfind)" ~/.local/bin/fd
command -v bat >/dev/null 2>&1 || ln -sf "$(command -v batcat)" ~/.local/bin/bat
cat > ~/.tmux.conf <<'CONF'
set -g mouse on
set -g history-limit 10000
CONF
USER_SETUP

chsh -s /bin/zsh sandfort
```

### 5. Timezone, locale, and desktop settings

The non-obvious part: the script runs as root, but GNOME settings belong to the
`sandfort` user, so they must be written as that user.

```bash
#!/usr/bin/env bash
set -euo pipefail

timedatectl set-timezone Europe/Berlin

sudo -u sandfort dbus-run-session -- bash <<'USER_SETUP'
set -euo pipefail
gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false
USER_SETUP
```

Disabling the screen lock is a reasonable convenience in a disposable guest that
holds nothing valuable. It would not be on a machine that does.

### 6. Make the sandbox look like a sandbox

Cheap insurance against acting on the wrong window.

```bash
#!/usr/bin/env bash
set -euo pipefail

sudo -u sandfort dbus-run-session -- bash <<'USER_SETUP'
set -euo pipefail
gsettings set org.gnome.desktop.background primary-color '#7a1f1f'
gsettings set org.gnome.desktop.background color-shading-type 'solid'
gsettings set org.gnome.desktop.background picture-uri ''
gsettings set org.gnome.desktop.background picture-uri-dark ''
USER_SETUP
```

### 7. An extra browser

Every profile's desktop already provides Firefox, though how varies: openSUSE
installs and verifies `MozillaFirefox` explicitly, Debian gets `firefox-esr` from
its GNOME task, Fedora gets it from the Workstation environment, and on Ubuntu
the `firefox` package is a transitional one that installs the Firefox snap. Only
the openSUSE profile verifies the browser during setup; the other three rely on
their desktop metapackage.

If you also want Chromium:

```bash
#!/usr/bin/env bash
set -euo pipefail

install_packages() { :; }  # paste the helper from above

if command -v apt-get >/dev/null 2>&1 && ! command -v zypper >/dev/null 2>&1; then
  # On Ubuntu, chromium-browser is only a transitional package that pulls in
  # the Chromium snap, which does not install cleanly during unattended setup.
  # Debian packages Chromium normally.
  if grep -qi ubuntu /etc/os-release; then
    echo "Skipping Chromium on Ubuntu; use the preinstalled Firefox." >&2
    exit 0
  fi
fi

install_packages chromium
```

## What a script must never do

These would quietly remove the guarantees the rest of Sandfort works to provide:

- **Do not re-enable or unmask SSH.** Every profile disables and masks it
  deliberately, and the setup verification would have failed if it were running.
- **Do not disable the firewall, SELinux, or AppArmor.**
- **Do not install remote-access, tunnelling, or reverse-shell tooling.** A
  sandbox reachable from outside is not a sandbox.
- **Do not paste code from the material you are investigating.** This script runs
  as root while the *trusted* baseline is built, before any isolation is being
  relied upon. Untrusted code belongs in an instance, never here.
- **Do not embed secrets.** The text is stored in app state and written into the
  seed image.
- **Do not depend on the system package cache surviving.** It is cleaned right
  after your script runs.

## Troubleshooting

- Everything your script prints goes to `/var/log/sandfort-setup.log` in the
  guest. Turn on **Show detailed setup output** to watch it live in UTM.
- If setup fails, the VM stays on and enables a diagnostic login rather than
  powering off. Log in there and read the log; the failing command is the last
  thing in it.
- After failing, do not click **Finish Setup**. Fix the script and choose
  **Rebuild**.
- Test a long script in an existing instance first, where a mistake costs
  seconds instead of a 20–45 minute rebuild. Remember an instance is not root by
  default: use `sudo`.
- If setup never finishes and nothing is happening, suspect an interactive
  prompt waiting for input that will never come.
