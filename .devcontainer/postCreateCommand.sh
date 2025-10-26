#!/usr/bin/env bash
set -euo pipefail

echo "▶️ Running postCreateCommand.sh..."

# Install system packages
echo "📦 Installing system packages..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  curl \
  iputils-ping \
  net-tools \
  netcat-openbsd \
  traceroute \
  dnsutils \
  tcpdump

# --- Add GITHUB_USER to ~/.bashrc from git remote owner (owner/repo) ---
# Prefer extracting the owner from the remote URL (works for SSH and HTTPS forms).
if git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$PWD" remote get-url origin >/dev/null 2>&1; then
    url=$(git -C "$PWD" remote get-url origin)
    owner=""

    # SSH form: git@github.com:owner/repo.git
    if [[ "$url" =~ ^git@[^:]+:([^/]+)/([^/]+)(\.git)?$ ]]; then
      owner="${BASH_REMATCH[1]}"
    # HTTPS form: https://github.com/owner/repo.git or https://github.com/owner/repo
    elif [[ "$url" =~ ^https?://[^/]+/([^/]+)/([^/]+)(\.git)?$ ]]; then
      owner="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$owner" ]]; then
      # Ensure we don't append duplicate lines. If an export exists, replace it.
      if grep -q '^export GITHUB_USER=' ~/.bashrc 2>/dev/null; then
        sed -i".bak" -E "s/^export GITHUB_USER=.*/export GITHUB_USER=\"${owner}\"/" ~/.bashrc || true
      else
        echo "export GITHUB_USER=\"${owner}\"" >> ~/.bashrc
      fi

      # Export for current script/session as well
      export GITHUB_USER="${owner}"
      echo "📌 Set GITHUB_USER=${owner} (written to ~/.bashrc)"
    else
      echo "⚠️  Could not parse GitHub owner from remote URL: ${url}"
    fi
  else
    echo "⚠️  No git remote 'origin' found; skipping GITHUB_USER setup"
  fi
else
  echo "⚠️  Not inside a git repository; skipping GITHUB_USER setup"
fi

# Install and configure chezmoi
echo "🏠 Installing and configuring chezmoi..."
CHEZMOI_USER="${GITHUB_USER}"
if [[ "$CHEZMOI_USER" != "unknown" && -n "$CHEZMOI_USER" ]]; then
  # Check if the dotfiles repository exists
  if curl -fsL "https://github.com/${CHEZMOI_USER}/dotfiles" >/dev/null 2>&1; then
    sh -c "cd '$HOME' && $(curl -fsLS get.chezmoi.io/lb)" -- init -S "$HOME/.dotfiles" --apply "$CHEZMOI_USER"
  else
    echo "⚠️  Repository https://github.com/${CHEZMOI_USER}/dotfiles not found, skipping chezmoi setup"
  fi
else
  echo "⚠️  GITHUB_USER not set or is 'unknown', skipping chezmoi setup"
fi

# Ensure mise is active for this and future shells
if ! grep -q 'mise activate bash' ~/.bashrc; then
  echo 'eval "$(mise activate bash)"' >> ~/.bashrc
fi
eval "$(mise activate bash)"

# Trust and install mise tools
echo "🔧 Setting up mise tools..."
mise trust --yes .
mise install --yes

# Install minijinja-cli
echo "🦀 Installing minijinja-cli..."
cargo install --locked minijinja-cli

echo "✅ postCreateCommand.sh completed successfully!"
