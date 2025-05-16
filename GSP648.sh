#!/bin/bash
set -euo pipefail

# ========== GCP SETUP ==========

# Get Project ID
PROJECT_ID=$(gcloud config get-value project)
echo "Project ID: $PROJECT_ID"

# Get or prompt for Region
REGION=$(gcloud config get-value compute/region)
if [ -z "$REGION" ]; then
  read -p "Enter GCP region (e.g. us-central1): " REGION
  gcloud config set compute/region "$REGION" --quiet
fi

# Get or prompt for Zone
ZONE=$(gcloud config get-value compute/zone)
if [ -z "$ZONE" ]; then
  read -p "Enter GCP zone (e.g. us-central1-a): " ZONE
  gcloud config set compute/zone "$ZONE" --quiet
fi

echo "Region: $REGION"
echo "Zone: $ZONE"

# ========== ENABLE APIS ==========

echo "Enabling required APIs..."
gcloud services enable compute.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudscheduler.googleapis.com \
  appengine.googleapis.com \
  artifactregistry.googleapis.com --quiet

# ========== CREATE TEST RESOURCES ==========

echo "Creating test disks in parallel..."
gcloud compute disks create orphaned-disk --size=500GB --zone="$ZONE" --quiet &
gcloud compute disks create unused-disk --size=500GB --zone="$ZONE" --quiet &
wait

echo "Creating VM instance..."
gcloud compute instances create disk-instance \
  --zone="$ZONE" \
  --machine-type=e2-micro \
  --boot-disk-size=10GB \
  --quiet

echo "Attaching one disk to VM..."
gcloud compute instances attach-disk disk-instance \
  --disk=orphaned-disk \
  --zone="$ZONE" \
  --quiet

# Instead of fixed sleep, you could wait for instance/disk status if needed
sleep 5

echo "Detaching orphaned disk from VM..."
gcloud compute instances detach-disk disk-instance \
  --disk=orphaned-disk \
  --zone="$ZONE" \
  --quiet

# ========== SETUP FUNCTION ==========

WORKDIR="$HOME/unattached-pd"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit 1

# Create main.py
cat > main.py <<EOF
import googleapiclient.discovery
import datetime

def delete_unattached_pds(request):
    project = '$PROJECT_ID'
    zone = '$ZONE'

    compute = googleapiclient.discovery.build('compute', 'v1')
    disks = compute.disks().list(project=project, zone=zone).execute()

    if 'items' not in disks:
        return 'No disks found.'

    deleted = []
    for disk in disks['items']:
        if 'users' not in disk:
            disk_name = disk['name']
            compute.disks().delete(project=project, zone=zone, disk=disk_name).execute()
            deleted.append(disk_name)

    return f'Deleted disks: {deleted}' if deleted else 'No unattached disks found.'
EOF

# Create requirements.txt
echo "google-api-python-client" > requirements.txt

# ========== INIT APP ENGINE FIRST ==========

echo "Checking if App Engine app exists..."
if ! gcloud app describe --project="$PROJECT_ID" &>/dev/null; then
  gcloud app create --region="$REGION" --quiet
else
  echo "App Engine already exists."
fi

# ========== DEPLOY FUNCTION ==========

echo "Deploying Cloud Function..."
gcloud functions deploy delete_unattached_pds \
  --gen2 \
  --runtime=python39 \
  --region="$REGION" \
  --trigger-http \
  --allow-unauthenticated \
  --source="$WORKDIR" \
  --quiet

echo "Waiting for Cloud Function to become ACTIVE..."
while true; do
  STATUS=$(gcloud functions describe delete_unattached_pds --region="$REGION" --format="value(state)")
  echo "Current function state: $STATUS"
  if [[ "$STATUS" == "ACTIVE" ]]; then
    break
  fi
  sleep 5
done

# Wait a moment to ensure URL is ready
sleep 3

# Fetch URL
echo "Fetching Cloud Function URL..."
FUNCTION_URL=$(gcloud functions describe delete_unattached_pds --region="$REGION" --format="value(serviceConfig.uri)")
echo "Function URL: $FUNCTION_URL"

# ========== SCHEDULER JOB ==========

echo "Creating Cloud Scheduler job..."
# Delete job first if it exists to avoid error (optional)
if gcloud scheduler jobs describe unattached-pd-job --location="$REGION" &>/dev/null; then
  gcloud scheduler jobs delete unattached-pd-job --location="$REGION" --quiet
fi

gcloud scheduler jobs create http unattached-pd-job \
  --schedule="0 2 * * *" \
  --uri="$FUNCTION_URL" \
  --http-method=GET \
  --location="$REGION" \
  --quiet

# ========== MANUAL TEST ==========

sleep 5
echo "Running job manually..."
gcloud scheduler jobs run unattached-pd-job --location="$REGION" --quiet

# ========== VERIFY ==========

echo "Listing remaining disks..."
gcloud compute disks list --quiet
