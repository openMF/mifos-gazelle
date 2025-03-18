#!/bin/bash

# Define a dictionary of JDK versions and their download URLs
declare -A jdk_versions
jdk_versions["17.0.2"]="https://download.java.net/java/GA/jdk17.0.2/dfd4a8d0985749f896bed50d7138ee7f/8/GPL/openjdk-17.0.2_linux-x64_bin.tar.gz"
jdk_versions["23"]="https://download.java.net/java/GA/jdk23/3c5b90190c68498b986a97f276efd28a/37/GPL/openjdk-23_linux-x64_bin.tar.gz"

# Check if the script is running on Ubuntu
if [[ "$(lsb_release -d | awk '{print $2}')" != "Ubuntu" ]]; then
  echo "This script is only for Ubuntu systems."
  exit 1
fi

# Check if the script is running on x86_64 architecture
if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
  echo "This script is only for x86_64 architectures."
  exit 1
fi

# Create a downloads directory if it doesn't exist
downloads_dir="$HOME/downloads"
mkdir -p "$downloads_dir"

# Iterate over the JDK versions dictionary
for jdk_version in "${!jdk_versions[@]}"; do
  jdk_url="${jdk_versions[$jdk_version]}"

  echo "Downloading OpenJDK ${jdk_version} from $jdk_url"

  # Download the JDK
  jdk_filename=$(basename "$jdk_url")  # Extract filename from URL

  wget -q -O "$downloads_dir/$jdk_filename" "$jdk_url"

  # Check if the download was successful
  if [[ $? -ne 0 ]]; then
    echo "Failed to download OpenJDK ${jdk_version}."
    continue
  fi

  echo "Downloaded OpenJDK ${jdk_version} to $downloads_dir/$jdk_filename"

  # Verify the file integrity
  if ! gzip -t "$downloads_dir/$jdk_filename"; then
    echo "Downloaded file is corrupted."
    continue
  fi

  # Extract the downloaded file to a temporary directory
  tmp_dir="$downloads_dir/jdk-${jdk_version}-tmp"
  mkdir -p "$tmp_dir"

  echo "Extracting OpenJDK ${jdk_version} to $tmp_dir"

  # Extract the downloaded file
  if ! tar -xzf "$downloads_dir/$jdk_filename" -C "$tmp_dir"; then
    echo "Failed to extract OpenJDK ${jdk_version}."
    continue
  fi

  echo "Extracted OpenJDK ${jdk_version} successfully"

  # Move the extracted JDK to your home directory
  mv "$tmp_dir/jdk-"* "$HOME"

  echo "Moved extracted JDK ${jdk_version} to $HOME"

  echo "OpenJDK ${jdk_version} has been downloaded and extracted to your home directory."
done

echo "All specified JDK versions have been processed."