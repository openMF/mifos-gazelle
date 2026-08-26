#!/bin/bash
# Downloads and installs a specified OpenJDK (Eclipse Temurin) version on
# Ubuntu, via wget, from the Adoptium API's stable "latest" endpoint:
#   https://api.adoptium.net/v3/binary/latest/<version>/ga/linux/<arch>/jdk/hotspot/normal/eclipse
# This always resolves to the latest available build for the requested major
# version, so it doesn't rely on hardcoded/guessed patch versions or hashes.
#
# Usage:
#   install-jdk.sh [jdk_version]
#
# Examples:
#   install-jdk.sh 21
#   install-jdk.sh          # prompts for the version if not given

set -euo pipefail

script_name="$(basename "$0")"

usage() {
  echo "Usage: $script_name [jdk_version]"
  echo "  jdk_version   Numeric major JDK version to install, e.g. 8, 11, 17, 21, 23"
  echo
  echo "Examples:"
  echo "  $script_name 21"
  echo "  $script_name            # prompts for version"
}

# Check if the script is running on Ubuntu
if ! command -v lsb_release >/dev/null 2>&1 || [[ "$(lsb_release -is)" != "Ubuntu" ]]; then
  echo "This script is only for Ubuntu systems."
  exit 1
fi

# Map dpkg architecture to the Adoptium API's architecture names
case "$(dpkg --print-architecture)" in
  amd64) adoptium_arch="x64" ;;
  arm64) adoptium_arch="aarch64" ;;
  *)
    echo "Unsupported architecture: $(dpkg --print-architecture). Only amd64 and arm64 are supported."
    exit 1
    ;;
esac

jdk_version="${1:-}"

if [[ -z "$jdk_version" ]]; then
  read -rp "Enter the JDK version to install (e.g. 21): " jdk_version
fi

if [[ -z "$jdk_version" ]]; then
  echo "No JDK version supplied."
  usage
  exit 1
fi

if [[ ! "$jdk_version" =~ ^[0-9]+$ ]]; then
  echo "JDK version must be numeric (e.g. 8, 11, 17, 21), got '$jdk_version'."
  exit 1
fi

downloads_dir="$HOME/downloads"
install_dir="$HOME/java"
mkdir -p "$downloads_dir" "$install_dir"

jdk_url="https://api.adoptium.net/v3/binary/latest/${jdk_version}/ga/linux/${adoptium_arch}/jdk/hotspot/normal/eclipse"
jdk_archive="$downloads_dir/openjdk-${jdk_version}-${adoptium_arch}.tar.gz"

echo "Downloading latest OpenJDK ${jdk_version} (${adoptium_arch}) from Adoptium..."
if ! wget -q --content-disposition -O "$jdk_archive" "$jdk_url"; then
  echo "Failed to download OpenJDK ${jdk_version}. Check that ${jdk_version} is a valid, currently supported major version."
  rm -f "$jdk_archive"
  exit 1
fi

echo "Downloaded to $jdk_archive"

tmp_dir="$downloads_dir/jdk-${jdk_version}-tmp"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir"

echo "Extracting OpenJDK ${jdk_version}..."
if ! tar -xzf "$jdk_archive" -C "$tmp_dir"; then
  echo "Failed to extract OpenJDK ${jdk_version}."
  rm -rf "$tmp_dir"
  exit 1
fi

extracted_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
if [[ -z "$extracted_dir" ]]; then
  echo "Failed to find the extracted JDK directory."
  rm -rf "$tmp_dir"
  exit 1
fi

target_dir="$install_dir/$(basename "$extracted_dir")"
rm -rf "$target_dir"
mv "$extracted_dir" "$target_dir"
rm -rf "$tmp_dir"

echo "Installed OpenJDK ${jdk_version} to $target_dir"

# Point JAVA_HOME/PATH at this install via a dedicated, idempotent rc snippet
env_file="$HOME/.jdk-env"
{
  echo "# Written by install-jdk.sh - sets the active JDK"
  echo "export JAVA_HOME=\"$target_dir\""
  echo "export PATH=\"\$JAVA_HOME/bin:\$PATH\""
} > "$env_file"

marker="# Added by install-jdk.sh"
rc_file="$HOME/.bashrc"
if ! grep -qF "$marker" "$rc_file" 2>/dev/null; then
  {
    echo ""
    echo "$marker"
    echo "[ -f \"$env_file\" ] && source \"$env_file\""
  } >> "$rc_file"
fi

echo
echo "OpenJDK ${jdk_version} installed successfully:"
"$target_dir/bin/java" -version
echo
echo "JAVA_HOME has been set to $target_dir in $env_file (sourced from $rc_file)."
echo "Run 'source $rc_file' or open a new shell to pick it up."
