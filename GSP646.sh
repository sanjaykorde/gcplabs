#!/bin/bash

# ========== Prompt for Project ID and Region ==========
read -p "🆔 Enter your Google Cloud Project ID: " PROJECT_ID
export PROJECT_ID

read -p "🌎 Enter your desired region (e.g., us-west1): " REGIONNAME
export REGIONNAME

echo "✅ Using project: $PROJECT_ID"
echo "✅ Using region: $REGIONNAME"

# ========== Enable Required Services ==========
echo "🔧 Enabling required APIs..."
gcloud services enable cloudscheduler.googleapis.com cloudfunctions.googleapis.com \
  --project=$PROJECT_ID --quiet

# ========== Clone and Enter Working Directory ==========
echo "📦 Cloning cleanup repo..."
[ -d "gcf-automated-resource-cleanup" ] && rm -rf gcf-automated-resource-cleanup
git clone https://github.com/GoogleCloudPlatform/gcf-automated-resource-cleanup.git
cd gcf-automated-resource-cleanup/unused-ip

# ========== Reserve IP Addresses ==========
export USED_IP=used-ip-address
export UNUSED_IP=unused-ip-address

echo "🌐 Reserving static IPs..."
gcloud compute addresses create $USED_IP --project=$PROJECT_ID --region=$REGIONNAME --quiet &
gcloud compute addresses create $UNUSED_IP --project=$PROJECT_ID --region=$REGIONNAME --quiet &
wait

echo "📋 Fetching used IP address..."
export USED_IP_ADDRESS=$(gcloud compute addresses describe $USED_IP \
  --project=$PROJECT_ID --region=$REGIONNAME --format=json | jq -r '.address')

# ========== Create VM Using Reserved IP ==========
echo "🖥 Creating VM using reserved IP..."
gcloud compute instances create static-ip-instance \
  --zone=${REGIONNAME}-c \
  --machine-type=e2-medium \
  --subnet=default \
  --address=$USED_IP_ADDRESS \
  --project=$PROJECT_ID --quiet

# ========== Grant Permissions for Cloud Function ==========
echo "🔐 Granting Cloud Function access to Artifact Registry..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$PROJECT_ID@appspot.gserviceaccount.com" \
  --role="roles/artifactregistry.reader" \
  --quiet

# ========== Deploy Cloud Function ==========
echo "🚀 Deploying Cloud Function..."
gcloud functions deploy unused_ip_function \
  --gen2 \
  --trigger-http \
  --runtime=nodejs20 \
  --region=$REGIONNAME \
  --source=. \
  --project=$PROJECT_ID --quiet

echo "⏳ Waiting for Cloud Function to become ACTIVE..."
while true; do
  STATUS=$(gcloud functions describe unused_ip_function \
    --region=$REGIONNAME --project=$PROJECT_ID --format="value(state)")
  echo "🔄 Current function state: $STATUS"
  if [[ "$STATUS" == "ACTIVE" ]]; then
    echo "✅ Cloud Function is ready!"
    break
  fi
  sleep 5
done

export FUNCTION_URL=$(gcloud functions describe unused_ip_function \
  --region=$REGIONNAME --project=$PROJECT_ID --format=json | jq -r '.url')

# ========== Create App Engine and Scheduler ==========
echo "🏗 Creating App Engine app..."
gcloud app create --region=$REGIONNAME --project=$PROJECT_ID --quiet

echo "⏰ Creating Cloud Scheduler job..."
gcloud scheduler jobs create http unused-ip-job \
  --schedule="* 2 * * *" \
  --uri=$FUNCTION_URL \
  --location=$REGIONNAME \
  --project=$PROJECT_ID --quiet

echo "🚦 Triggering Cloud Scheduler job manually..."
gcloud scheduler jobs run unused-ip-job \
  --location=$REGIONNAME \
  --project=$PROJECT_ID --quiet

# ========== Final Output ==========
echo "📜 Final list of IP addresses:"
gcloud compute addresses list --filter="region:($REGIONNAME)" \
  --project=$PROJECT_ID
