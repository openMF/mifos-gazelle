#!/bin/bash

# Check if the script is running on Ubuntu
if [[ "$(lsb_release -d | awk '{print $2}')" != "Ubuntu" ]]; then
  echo "This script is only for Ubuntu systems."
  exit 1
fi

# Detect system architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)
    ARCH_TYPE="amd64"
    ;;
  aarch64|arm64)
    ARCH_TYPE="arm64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Create a temporary directory for downloads
tmp_dir="/tmp/k9s_download"
mkdir -p "$tmp_dir"

# Fetch the latest k9s version
latest_version=$(curl -sL https://github.com/derailed/k9s/releases/latest | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
if [[ -z "$latest_version" ]]; then
  echo "Failed to fetch the latest k9s version."
  exit 1
fi

# Construct download URL based on architecture
download_url="https://github.com/derailed/k9s/releases/download/${latest_version}/k9s_Linux_${ARCH_TYPE}.tar.gz"

# Download the k9s tar.gz
curl -L "$download_url" -o "$tmp_dir/k9s.tar.gz"
if [[ $? -ne 0 ]]; then
  echo "Failed to download k9s from $download_url"
  exit 1
fi

# Extract the k9s executable
tar -xzf "$tmp_dir/k9s.tar.gz" -C "$tmp_dir"
if [[ $? -ne 0 ]]; then
  echo "Failed to extract k9s tarball"
  exit 1
fi

# Move k9s to the user's bin directory
mkdir -p "$HOME/local/bin"
mv "$tmp_dir/k9s" "$HOME/local/bin/k9s"
if [[ $? -ne 0 ]]; then
  echo "Failed to move k9s to $HOME/local/bin"
  exit 1
fi

# Ensure k9s is executable
chmod +x "$HOME/local/bin/k9s"

# Check if the PATH already includes $HOME/.local/bin
if [[ ":$PATH:" != *":$HOME/local/bin:"* ]]; then
  echo "To use k9s, add the following line to your ~/.bashrc or ~/.zshrc:"
  echo "export PATH=\$HOME/local/bin:\$PATH"
  echo "Then, run 'source ~/.bashrc' or 'source ~/.zshrc' to update your current session."
fi

# Clean up the temporary directory
rm -rf "$tmp_dir"

echo "k9s version $latest_version installed successfully!"