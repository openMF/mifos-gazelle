#!/bin/bash

# Variables
ELASTICSEARCH_HOST="elasticsearch.mifos.gazelle.test"  # Replace with your Elasticsearch host
ELASTIC_PASSWORD="elasticSearchPas42"      # Replace with your Elasticsearch password
INDEX_NAME="my_index"                      # Name of the index to create

# Step 1: Create an Index
echo "Creating index '$INDEX_NAME'..."
curl -u elastic:$ELASTIC_PASSWORD -X PUT "http://$ELASTICSEARCH_HOST/$INDEX_NAME" -H "Content-Type: application/json" -d'
{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 1
  }
}'

# Check if the index was created successfully
if [ $? -eq 0 ]; then
  echo "Index '$INDEX_NAME' created successfully."
else
  echo "Failed to create index '$INDEX_NAME'."
  exit 1
fi

# Step 2: Add Sample Data
echo "Adding sample data to '$INDEX_NAME'..."
curl -u elastic:$ELASTIC_PASSWORD -X POST "http://$ELASTICSEARCH_HOST/$INDEX_NAME/_doc/1" -H "Content-Type: application/json" -d'
{
  "name": "John Doe",
  "age": 30,
  "city": "New York"
}'

curl -u elastic:$ELASTIC_PASSWORD -X POST "http://$ELASTICSEARCH_HOST/$INDEX_NAME/_doc/2" -H "Content-Type: application/json" -d'
{
  "name": "Jane Smith",
  "age": 25,
  "city": "Los Angeles"
}'

# Check if the data was added successfully
if [ $? -eq 0 ]; then
  echo "Sample data added to '$INDEX_NAME' successfully."
else
  echo "Failed to add sample data to '$INDEX_NAME'."
  exit 1
fi

# Step 3: Query the Data
echo "Querying data from '$INDEX_NAME'..."
curl -u elastic:$ELASTIC_PASSWORD -X GET "http://$ELASTICSEARCH_HOST/$INDEX_NAME/_search"

# Check if the query was successful
if [ $? -eq 0 ]; then
  echo "Data queried successfully."
else
  echo "Failed to query data from '$INDEX_NAME'."
  exit 1
fi
