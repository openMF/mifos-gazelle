#!/bin/bash

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



# Download and extract OpenJDK 17
jdk_17_url="https://download.java.net/java/GA/jdk17.0.2/dfd4a8d0985749f896bed50d7138ee7f/8/GPL/openjdk-17.0.2_linux-x64_bin.tar.gz"
jdk_17_filename="openjdk-17.0.2_linux-x64_bin.tar.gz"
curl -L "$jdk_17_url" -o "$downloads_dir/$jdk_17_filename"
echo "OpenJDK 17 has been downloaded and extracted to your home directory."

# Download and extract OpenJDK 18 
jdk_8_url="https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u422-b05/OpenJDK8U-jdk_x64_linux_hotspot_8u422b05.tar.gz"
jdk_8_filename="jdk8.tar.gz"
curl -L "$jdk_8_url" -o "$downloads_dir/$jdk_8_filename"
echo "tar -xzf $downloads_dir/$jdk_8_filename -C $HOME"
tar -xzf $downloads_dir/$jdk_8_filename -C "$HOME"

echo "OpenJDK 8 has been downloaded and extracted to your home directory."