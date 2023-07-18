#!/bin/bash

# The script takes three arguments
# 1. (p) project_id where composer is deployed
# 2. (l) location where composer is deployed 
# 3. (e) environment id of the composer

# The script estimates the min workers and max workers based on the metrics. 
# Make sure it is valid/aplies for you installation (by deploying in lower environments))
# The script downloads the the airflow.cfg. Copies the relevant information to new environment
usage()
{
    echo "usage: script.sh options:<p|l|e>"
}
project=''
location=''
environment=''
while getopts p:l:e: flag
do
    case "${flag}" in
        p) project=${OPTARG};;
        l) location=${OPTARG};;
        e) environment=${OPTARG};;
        *) usage
           exit;;
    esac
done

[[ $project == "" || $location == "" || $environment == ""  ]] && { usage; exit 1; }

export PROJECT_ID=$project
export location=$location
export environment_name=$environment
export existing_config='composer.properties'

rm $existing_config
touch $existing_config
db_machine_type=`gcloud composer environments describe composer-1-airflow-1 --location northamerica-northeast1 --format json | jq .config.databaseConfig.machineType | tr -d '"'`
echo "db_machine_type=$db_machine_type" >> $existing_config
worker_machine_type=`gcloud composer environments describe composer-1-airflow-1 --location northamerica-northeast1 --format json | jq .config.nodeConfig.machineType | cut -d "/"  -f6 |  tr -d '"'`
echo "worker_machine_type=$worker_machine_type" >> $existing_config

envsubst < query_task_template.json > query_task.json
TOKEN=`gcloud auth print-access-token`
curl -d @query_task.json -H "Authorization: Bearer $TOKEN" \
--header "Content-Type: application/json" -X POST \
https://monitoring.googleapis.com/v3/projects/$PROJECT_ID/timeSeries:query | jq .timeSeriesData | jq -r ".[] | .pointData" | jq -r ".[].values[0].int64Value" > task_counts.txt
total=0

while read -r line
do
    ((total += line)) 
done < task_counts.txt

airflow_config=`gcloud composer environments describe composer-1-airflow-1 --location northamerica-northeast1 --format json | jq .config.dagGcsPrefix | tr -d '"' | cut -d "/" -f3`

gsutil cp gs://$airflow_config/airflow.cfg .
worker_concurrency=`gsutil cat gs://$airflow_config/airflow.cfg | grep worker_concurrency | cut -d "=" -f2`
min_workers=$(($total/$worker_concurrency))
echo "min_workers=$(($total/$worker_concurrency))" >> $existing_config
max_workers=`gcloud composer environments describe composer-1-airflow-1 --location northamerica-northeast1 --format json | jq .config.nodeCount`

if [[ $(($max_workers)) -lt $min_workers ]]
then
max_workers=$(($min_workers+1))
fi

echo "max_workers=$max_workers" >> $existing_config
