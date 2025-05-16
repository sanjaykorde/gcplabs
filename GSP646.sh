# Get project ID
export PROJECT_ID=$(gcloud config list --format 'value(core.project)' 2>/dev/null)

# Region setup
REGIONNAME=$(gcloud config get-value compute/region 2>/dev/null)
if [ -z "$REGIONNAME" ]; then
  echo "No region set in gcloud config."
  read -p "Please enter your region (e.g., us-west1): " REGIONNAME
fi
export REGIONNAME

# Continue with rest of script...

gcloud services enable cloudscheduler.googleapis.com && \
git clone https://github.com/GoogleCloudPlatform/gcf-automated-resource-cleanup.git && \
cd gcf-automated-resource-cleanup/unused-ip && \
 && \
export USED_IP=used-ip-address && \
export UNUSED_IP=unused-ip-address && \
gcloud compute addresses create $USED_IP --project=$PROJECT_ID --region=$REGIONNAME && \
gcloud compute addresses create $UNUSED_IP --project=$PROJECT_ID --region=$REGIONNAME && \
export USED_IP_ADDRESS=$(gcloud compute addresses describe $USED_IP --region=$REGIONNAME --format=json | jq -r '.address') && \
gcloud compute instances create static-ip-instance --zone=$REGIONNAME-c --machine-type=e2-medium --subnet=default --address=$USED_IP_ADDRESS && \
gcloud services enable cloudfunctions.googleapis.com && \
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$PROJECT_ID@appspot.gserviceaccount.com" --role="roles/artifactregistry.reader" && \
gcloud functions deploy unused_ip_function --gen2 --trigger-http --runtime=nodejs20 --region=$REGIONNAME --source=.
export FUNCTION_URL=$(gcloud functions describe unused_ip_function --region=$REGIONNAME --format=json | jq -r '.url') && \
gcloud app create --region=$REGIONNAME && \
gcloud scheduler jobs create http unused-ip-job --schedule="* 2 * * *" --uri=$FUNCTION_URL --location=$REGIONNAME && \
gcloud scheduler jobs run unused-ip-job --location=$REGIONNAME && \
gcloud compute addresses list --filter="region:($REGIONNAME)"
