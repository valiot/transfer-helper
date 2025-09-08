# transfer-helper

Simple one-shot provisioning script for a fresh Ubuntu 22.04 (root) environment. Installs Docker Engine, kubectl, doctl, linode-cli, boto3, Oh My Zsh, and supporting CLI tools. Also generates an Ed25519 SSH key and prints its public part.

## Quick Start (run as root)

```bash
curl -fsSL https://raw.githubusercontent.com/valiot/transfer-helper/refs/heads/main/install.sh | bash
```

If you are not root, prepend `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/valiot/transfer-helper/refs/heads/main/install.sh | sudo bash
```

## What It Does

- Updates and upgrades existing apt packages
- Installs: zsh, mosh, postgresql-client, ruby, git, jq, pipx, python tooling
- Removes legacy Docker-related packages, adds Docker’s official repo, installs Docker Engine + Buildx + Compose plugin
- Installs kubectl (latest stable)
- Installs DigitalOcean `doctl` (via snap if available, else tarball) and connects common interfaces
- Installs `linode-cli` and `boto3` via pipx
- Installs Oh My Zsh (non-interactive) and sets zsh as default shell for root
- Adds a helper function `lke-save` to merge Linode LKE kubeconfigs
- Creates `~/.kube` and ensures secure permissions
- Generates an Ed25519 SSH key at `/root/.ssh/id_ed25519` if absent and prints the public key
- Provides a summary of versions at the end

## Idempotency

Re-running the script is safe: it skips steps already completed (e.g., existing Docker keyring, kubectl, doctl, Oh My Zsh, SSH key, and `lke-save` function).

## After Installation

- Start a new shell or run: `exec zsh`
- Copy the printed public SSH key to any services that require it
- Use `lke-save <cluster-label>` to merge an LKE cluster kubeconfig into your main kubeconfig

## Notes

- Script assumes Ubuntu 22.04; a warning is shown if a different version is detected.
- Must run as root (or via sudo) because it installs system packages and modifies root’s shell.

## License

MIT
