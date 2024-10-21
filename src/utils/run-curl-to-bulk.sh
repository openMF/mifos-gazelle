#!/bin/bash

# Define the URL and query parameters
URL="https://bulk-connector.local/batchtransactions"
QUERY_PARAMS="type=CSV"

# Define the headers
HEADERS=(
  "-H 'Platform-TenantId: gorilla'"
  "-H 'X-CorrelationID: 41a7ef46-78a1-44d8-8ec0-df549533ef26'"
  "-H 'purpose: Integartion test'"
  "-H 'filename: ph-ee-bulk-demo-6.csv'"
  "-H 'X-Registering-Institution-ID: SocialWelfare'"
  "-H 'type: CSV'"
  "-H 'X-SIGNATURE: dcMwt2QhsMstCf0k03CRnEOyFKXwxaOMbx3+n+LYgiuv+ko4VANtLjVvTjOxg40862H0bfo250vDahEwarTdea6BJx5RfvC5Mh1elrZM+SFx/yuxpROfGnN/vuox7doySo0Xpnqm5Zcuutb3Aw3i81HnhOf3UQfntY7G8kq+/qTd4Hv0Vrr9sOEP4g/ugwFbI0EflIagjerwN2scZkQ98JgGfUfFFm8fg98H5D9FqNhe33N8p+Y6nc1A/Y6Ok9A6pYsFEWODDqe48h/WIimQKix52PWTToYXhQw3Il6ezTM2qxiQFcGU7oMC/blanYJH9/H0/74J+rBz/Vn+0kIfAg=='"
  "-H 'Accept: */*'"
  "-H 'Content-Type: multipart/form-data'"
)

# Define the file to upload
FILE_PATH="/home/azureuser/mifos-gazelle/repos/ph_template/PostmanCollections/ph-ee-bulk-demo-6.csv"

# Execute the curl command
curl -v -k -X POST "${URL}?${QUERY_PARAMS}" \
  "${HEADERS[@]}" \
  -F "data=@${FILE_PATH};filename=ph-ee-bulk-demo-6.csv"

