#!/usr/bin/env bash

# Automated provisioning script for Ubuntu 22.04 (run as root)
# Usage (after hosting somewhere): curl -fsSL <url>/install.sh | bash
# Idempotent where reasonable; minimizes repeated apt operations.

set -euo pipefail
IFS=$'\n\t'

echo "[+] Starting provisioning..."

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "[FATAL] Must run as root." >&2
	exit 1
fi

source /etc/os-release || { echo "[FATAL] Cannot read /etc/os-release" >&2; exit 1; }
if [[ "${VERSION_ID}" != "22.04" ]]; then
	echo "[WARN] This script is tailored for Ubuntu 22.04; detected ${VERSION_ID}. Continuing anyway." >&2
fi

export DEBIAN_FRONTEND=noninteractive
# Use an array to avoid issues with custom IFS (space removed) so each arg stays separate
APT_GET=(apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[+] Updating apt package index..."
apt-get update -y

echo "[+] Upgrading existing packages (silent non-interactive)..."
"${APT_GET[@]}" upgrade

echo "[+] Installing base packages..."
"${APT_GET[@]}" install \
	ca-certificates curl gnupg lsb-release software-properties-common \
	zsh mosh postgresql-client ruby git jq pipx python3-venv python3-pip

# Ensure pipx path is available (root context)
if ! grep -q 'PIPX_BIN_DIR' /root/.zshrc 2>/dev/null || ! grep -q '.local/bin' /root/.zshrc 2>/dev/null; then
	mkdir -p /root/.config/pipx
	grep -q 'export PATH=~/.local/bin:$PATH' /root/.zshrc 2>/dev/null || echo 'export PATH=~/.local/bin:$PATH' >> /root/.zshrc
fi

echo "[+] Removing any legacy / conflicting Docker packages..."
REMOVE_PKGS=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
for pkg in "${REMOVE_PKGS[@]}"; do
	if dpkg -l | grep -q "^ii  ${pkg} "; then
		"${APT_GET[@]}" remove "$pkg" || true
	fi
done
"${APT_GET[@]}" autoremove

DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
if [[ ! -f $DOCKER_KEYRING ]]; then
	echo "[+] Adding Docker GPG key & repository..."
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_KEYRING"
	chmod a+r "$DOCKER_KEYRING"
	echo "deb [arch=$(dpkg --print-architecture) signed-by=$DOCKER_KEYRING] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
		> /etc/apt/sources.list.d/docker.list
else
	echo "[+] Docker keyring already present; skipping add."
fi

echo "[+] Updating apt indices (Docker repo)..."
apt-get update -y

echo "[+] Installing Docker engine components..."
"${APT_GET[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add docker group if missing (root can run docker but this is prep for future non-root use)
if ! getent group docker >/dev/null; then
	groupadd docker
fi
usermod -aG docker root || true

echo "[+] Installing CLI tools via pipx (linode-cli, boto3)..."
pipx install --include-deps linode-cli --upgrade || pipx upgrade linode-cli || true
pipx install boto3 --upgrade || pipx upgrade boto3 || true

echo "[+] Installing kubectl (latest stable)..."
if ! command -v kubectl >/dev/null; then
	KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
	curl -L --fail -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
	chmod +x /usr/local/bin/kubectl
else
	echo "[+] kubectl already installed; skipping."
fi

echo "[+] Installing doctl (preferring snap; fallback to tar)..."
DOCTL_VERSION=1.141.0
if ! command -v doctl >/dev/null; then
	if command -v snap >/dev/null; then
		snap install doctl || true
		# Connect typical interfaces (may silently fail in some contexts)
		snap connect doctl:kube-config || true
		snap connect doctl:ssh-keys :ssh-keys || true
		snap connect doctl:dot-docker || true
	else
		TMPD=$(mktemp -d)
		curl -fsSL -o "$TMPD/doctl.tgz" "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz"
		tar -xzf "$TMPD/doctl.tgz" -C "$TMPD"
		install -m 0755 "$TMPD/doctl" /usr/local/bin/doctl
		rm -rf "$TMPD"
	fi
else
	echo "[+] doctl already installed; skipping."
fi

echo "[+] Switching default shell to zsh (if not already)..."
CURRENT_SHELL="$(getent passwd root | cut -d: -f7)"
ZSH_PATH="$(command -v zsh)"
if [[ "$CURRENT_SHELL" != "$ZSH_PATH" ]]; then
	chsh -s "$ZSH_PATH" root || true
fi

echo "[+] Installing Oh My Zsh (non-interactive) if missing..."
if [[ ! -d /root/.oh-my-zsh ]]; then
	export RUNZSH=no CHSH=no KEEP_ZSHRC=yes
	# If ~/.zshrc doesn't exist create a minimal one before installer
	[[ -f /root/.zshrc ]] || echo '# ~/.zshrc (created by install script)' > /root/.zshrc
	curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | bash
else
	echo "[+] Oh My Zsh already installed; skipping."
fi

echo "[+] Ensuring ~/.kube directory exists..."
mkdir -p /root/.kube
chmod 700 /root/.kube

ZSHRC=/root/.zshrc
LKE_FUNC_NAME="lke-save()"
if ! grep -q "^${LKE_FUNC_NAME}" "$ZSHRC"; then
	echo "[+] Adding lke-save function to .zshrc..."
	cat >> "$ZSHRC" <<'EOF'

# Linode LKE kubeconfig merge helper
lke-save() {
	local label="$1"
	if [[ -z "$label" ]]; then
		echo "Usage: lke-save <cluster-label>" >&2
		return 1
	fi
	local id=$(linode-cli lke clusters-list --json | jq -r ".[] | select(.label == \"$label\") | .id")
	if [[ -z "$id" || "$id" == "null" ]]; then
		echo "Cluster not found: $label" >&2
		return 2
	fi
	mkdir -p ~/.kube
	linode-cli lke kubeconfig-view "$id" --text | sed 1d | base64 --decode > ~/.kube/$id.yaml
	KUBECONFIG=~/.kube/config:~/.kube/$id.yaml kubectl config view --flatten > /tmp/config && mv /tmp/config ~/.kube/config
	rm ~/.kube/$id.yaml
	chmod 600 ~/.kube/config
	kubectl config use-context "lke${id}-ctx" || true
	echo "Merged kubeconfig for cluster $label (id: $id)"
}
EOF
else
	echo "[+] lke-save function already present."
fi

echo "[+] Creating SSH key (ed25519) if absent..."
SSH_KEY_PATH=/root/.ssh/id_ed25519
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [[ ! -f ${SSH_KEY_PATH} ]]; then
	ssh-keygen -t ed25519 -N "" -f "$SSH_KEY_PATH" -C "root@$(hostname)" >/dev/null
else
	echo "[+] SSH key already exists at ${SSH_KEY_PATH}; not regenerating."
fi
chmod 600 ${SSH_KEY_PATH}
chmod 644 ${SSH_KEY_PATH}.pub

echo "[+] Summary:"
echo "  - Base packages installed"
echo "  - Docker installed ($(docker --version 2>/dev/null || echo 'not found'))"
echo "  - kubectl version: $(kubectl version --client --short 2>/dev/null || echo 'not found')"
echo "  - doctl version: $(doctl version 2>/dev/null | head -n1 || echo 'not found')"
echo "  - linode-cli version: $(linode-cli --version 2>/dev/null || echo 'not found')"
echo "  - Default shell set to: $(getent passwd root | cut -d: -f7)"

echo "[+] Public SSH key (add this to services that need it):"
echo "----- BEGIN PUBLIC KEY -----"
cat ${SSH_KEY_PATH}.pub
echo "----- END PUBLIC KEY -----"

echo "[+] Provisioning complete. Start a new shell or run: exec zsh"

exit 0
