#!/bin/bash

# ========== Setup ==========
read -p "🆔 Enter your Google Cloud Project ID: " PROJECT_ID
export PROJECT_ID

read -p "🌎 Enter your desired region (e.g., us-west1): " REGIONNAME
export REGIONNAME

echo "✅ Using project: $PROJECT_ID"
echo "✅ Using region: $REGIONNAME"

# ========== Enable Required Services ==========
echo "🔧 Enabling required APIs..."
gcloud services enable cloudscheduler.googleapis.com cloudfunctions.googleapis.com --quiet

# ========== Clone and Enter Working Directory ==========
echo "📦 Cloning cleanup repo..."
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
export USED_IP_ADDRESS=$(
