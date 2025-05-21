#!/bin/bash
# for JDK 9 and above see https://jdk.java.net/archive/
# for JDK 8 use temurin or redhat or openlogic 
# e.g. https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u402-b06/OpenJDK8U-jdk_x64_linux_hotspot_8u402b06.tar.gz
# https://download.java.net/java/GA/jdk11/9/GPL/openjdk-11.0.2_linux-x64_bin.tar.gz

# Define an array of desired JDK versions (not used for URL construction)
#jdk_versions=( "17.0.2" "8u422-b05" "11.0.1")
jdk_versions=( "13.0.2" ) 

# Define an array containing base download URLs 
jdk_base_urls=(
  "https://download.java.net/java/GA/jdk"  # Base URL for Oracle JDK
  "https://github.com/adoptium/temurin8-binaries/releases/download/" # Base URL for Adoptium JDK
  "https://download.java.net/java/GA/jdk11/13/GPL/"
)

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

for (( i=0; i<${#jdk_versions[@]}; i++ )); do

  # Extract version from the array (not used for URL construction)
  jdk_version="${jdk_versions[$i]}"

  # Construct the complete download URL based on version and base URL
  jdk_url="${jdk_base_urls[$i]}${jdk_version}"  # Add version to base URL

  # Check if the URL contains a version string (redundant for this script)
  # Removed redundant check

  echo "Downloading OpenJDK ${jdk_version} from $jdk_url"

  # Download the JDK
  jdk_filename=$(basename "$jdk_url")  # Extract filename from URL

  curl -L "$jdk_url" -o "$downloads_dir/$jdk_filename"

  # Check if the download was successful
  if [[ $? -ne 0 ]]; then
    echo "Failed to download OpenJDK ${jdk_version}."
    continue
  fi

  echo "Downloaded OpenJDK ${jdk_version} to $downloads_dir/$jdk_filename"

  # Check if the file is a .tar.gz file
  if [[ ! "$jdk_filename" =~ \.tar\.gz$ ]]; then
    echo "The downloaded file for OpenJDK ${jdk_version} is not a .tar.gz file."
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
  mv "$tmp_dir/jdk-${jdk_version}" "$HOME"

  echo "Moved extracted JDK ${jdk_version} to $HOME"

  echo "OpenJDK ${jdk_version} has been downloaded and extracted to your home directory."
done

echo "All specified JDK versions have been processed."