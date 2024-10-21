#!/bin/bash

# Check if the script is running on Ubuntu
if [[ "$(lsb_release -d | awk '{print $2}')" != "Ubuntu" ]]; then
  echo "This script is only for Ubuntu systems."
  exit 1
fi

# Create a temporary directory for downloads
tmp_dir="/tmp/k9s_download"
mkdir -p "$tmp_dir"

# Download k9s tar.gz 
url="https://github.com/derailed/k9s/releases/download/v0.32.5/k9s_Linux_amd64.tar.gz" 


# Download URL with version and filename
download_url="https://github.com/derailed/k9s/releases/download/v0.32.5/k9s_Linux_amd64.tar.gz"

# Attempt to get the latest version (optional)
# Uncomment these lines if you want to dynamically fetch the version
# latest_version=$(curl -sL https://github.com/derailed/k9s/releases/latest | grep -Eo '<title[^>]*>([^<]*)</title>' | head -n 1 | cut -d 'v' -f2)
# download_url="https://github.com/derailed/k9s/releases/download/v${latest_version}/k9s_Linux_amd64.tar.gz"

# Download the k9s executable (fallback to static URL)
curl -L "$download_url" -o "$tmp_dir/k9s.tar.gz"

# Extract the k9s executable (assuming it's a tar archive)
tar -xzf "$tmp_dir/k9s.tar.gz" -C "$tmp_dir"

# Move k9s to the user's bin directory (assuming it's named k9s after extraction)
mkdir -p "$HOME/local/bin"
mv "$tmp_dir/k9s" "$HOME/bin"

# Echo the path to add to bashrc
echo "To use k9s, add the following line to your .bashrc:"
echo "export PATH=\$HOME/local/bin:\$PATH"

# Clean up the temporary directory
rm -rf "$tmp_dir"
