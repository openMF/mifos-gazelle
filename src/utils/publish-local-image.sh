#!/usr/bin/env bash
# publish local image to k3s kubernetes 
# Author:  Tom Daly 
# Date :   Oct 2024 

IMAGE_NAME=$1
IMAGE_TAG=$2 

function set_user {
  # set the k8s_user 
  k8s_user=`who am i | cut -d " " -f1`
  echo "k8s_user = $k8s_user"
}

## set env variables to enable navigating an finding things 
SCRIPTS_DIR="$( cd $(dirname "$0") ; pwd )"
BASE_DIR="$( cd $(dirname "$0")/../../.. ; pwd )"

printf "\n\n******************************************\n"
printf "      --  publish local image to k3s  -- \n"  
printf "*************** << START  >> *******************\n\n" 

# ensure we are running as root and set the user 
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit 1
fi
set_user

printf "==> export docker image using docker save --output %s %s \n" 
tarfile="/tmp/$IMAGE_NAME.tar" 
rm -f $tarfile  # remove any old ones lying around 
su - $k8s_user -c "docker save --output $tarfile $IMAGE_NAME:$IMAGE_TAG" 
printf "==> import image using: k3s ctr images import %s  \n" $tarfile
k3s ctr images import "$tarfile"  
printf "==> cleaning up , removing tarfile etc\n"
rm -f $tarfile
#docker image rm $tagged_image >> $LOGFILE 2>&1

printf "\n ** images appear to have imported ok\n"
printf "      You can check they exist by running.. \n"
printf "      sudo k3s ctr images list | grep $IMAGE_NAME \n"


