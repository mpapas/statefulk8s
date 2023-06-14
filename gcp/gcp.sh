
projectId="YOUR PROJECT ID"
gkecluster="YOUR GKE CLUSTER NAME"
region="YOUR REGION"
labels="owner=XYZ,env=dev" # customize your own labels

# Enable APIs - open this link in the browser to access the GCP console
# https://console.cloud.google.com/flows/enableapi?apiid=compute.googleapis.com,container.googleapis.com,file.googleapis.com&_ga=2.223431326.486155707.1684700308-538179219.1684700235

# Open a Cloud Shell instance

# Create GKE cluster
gcloud beta container --project $projectId \
  clusters create $gkecluster \
  --region $region \
  --no-enable-basic-auth \
  --cluster-version "1.25.8-gke.500" \
  --release-channel "regular" \
  --machine-type "e2-standard-2" \
  --image-type "COS_CONTAINERD" \
  --disk-type "pd-balanced" \
  --disk-size "100" \
  --metadata disable-legacy-endpoints=true \
  --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" \
  --num-nodes "1" \
  --logging=SYSTEM,WORKLOAD,API_SERVER,SCHEDULER,CONTROLLER_MANAGER \
  --monitoring=SYSTEM,API_SERVER,SCHEDULER,CONTROLLER_MANAGER \
  --enable-ip-alias \
  --network "projects/$projectId/global/networks/default" \
  --subnetwork "projects/$projectId/regions/$region/subnetworks/default" \
  --no-enable-intra-node-visibility \
  --default-max-pods-per-node "110" \
  --enable-autoscaling --min-nodes "0" --max-nodes "10" \
  --location-policy "BALANCED" \
  --no-enable-master-authorized-networks \
  --addons HorizontalPodAutoscaling,HttpLoadBalancing,GcePersistentDiskCsiDriver,GcpFilestoreCsiDriver \
  --enable-autoupgrade \
  --enable-autorepair \
  --max-surge-upgrade 1 \
  --max-unavailable-upgrade 0 \
  --labels $labels \
  --enable-shielded-nodes

# get credentials for the cluster
gcloud container clusters get-credentials $gkecluster --region $region

# create StorageClass resource
kubectl create -f filestore-storageclass.yaml

# verify storage class is created
kubectl get sc

# create PVC
kubectl create -f pvc.yaml

# verify PVC is created and bound
kubectl get pvc -w

# verify the newly created Filestore instance is ready
gcloud filestore instances list

# deploy the workload
