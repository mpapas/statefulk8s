
awsAccount="YOUR AWS ACCOUNT NUMBER"
eksclusterName="YOUR EKS CLUSTER NAME"
regionCode="YOUR REGION CODE"
tags="Owner=XYZ,Environment=Dev" # specify your own tags
efsSecurityGroupName="YOUR SECURITY GROUP NAME FOR EFS"

# Make sure you have a default VPC or a VPC to use

# Install eksctl in CloudShell (if not already available). 
# Follow instructions here: https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
eksctl version

# Create EKS cluster using eksctl
eksctl create cluster \
    --name $eksclusterName \
    --tags $tags \
    --region $regionCode \
    --with-oidc \
    --version 1.25 \
    --vpc-public-subnets subnet-08990971a46c01534,subnet-0e59a43676579bb67,subnet-0b11c218a97a43909 \
    --node-type t3.large \
    --nodes-min 2 \
    --auto-kubeconfig \
    --asg-access \
    --nodes-max 10

# update kubeconfig
aws eks update-kubeconfig --region $regionCode --name $eksclusterName

# EFS CSI driver:  https://docs.aws.amazon.com/eks/latest/userguide/efs-csi.html

# Create an IAM policy that allows the CSI driver's service account to make calls to AWS APIs on your behalf.
# grab example (if you don't have one already)
# curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-efs-csi-driver/master/docs/iam-policy-example.json

aws iam create-policy \
    --policy-name AmazonEKS_EFS_CSI_Driver_Policy \
    --policy-document file://iam-policy-example.json

# Create the IAM role and K8S service account
eksctl create iamserviceaccount \
    --cluster $eksclusterName \
    --namespace kube-system \
    --name efs-csi-controller-sa \
    --attach-policy-arn arn:aws:iam::$awsAccount:policy/AmazonEKS_EFS_CSI_Driver_Policy \
    --approve \
    --region $regionCode

# install the EFS driver (https://github.com/kubernetes-sigs/aws-efs-csi-driver)

# To deploy the driver using Helm:
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update
helm upgrade -i aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --namespace kube-system \
    --set image.repository=602401143452.dkr.ecr.us-east-2.amazonaws.com/eks/aws-efs-csi-driver \
    --set controller.serviceAccount.create=false \
    --set controller.serviceAccount.name=efs-csi-controller-sa

# to verify that the aws-efs-csi-driver is running
kubectl get pod -n kube-system -l "app.kubernetes.io/name=aws-efs-csi-driver,app.kubernetes.io/instance=aws-efs-csi-driver"

# Create an EFS file system

# retrive the VPC ID that the cluster is in
vpc_id=$(aws eks describe-cluster \
    --name $eksclusterName \
    --query "cluster.resourcesVpcConfig.vpcId" \
    --output text)

# retrive the CIDR range for the cluster's VPC
cidr_range=$(aws ec2 describe-vpcs \
    --vpc-ids $vpc_id \
    --query "Vpcs[].CidrBlock" \
    --output text \
    --region $regionCode)

# create a security group with an inbound rule that allows inbound NFS traffic for your EFS mount points
security_group_id=$(aws ec2 create-security-group \
    --group-name $efsSecurityGroupName \
    --description "EFS security group" \
    --vpc-id $vpc_id \
    --output text)

# create an inbound rule that allows inbound NFS traffic from the CIDR for your cluster's VPC
aws ec2 authorize-security-group-ingress \
    --group-id $security_group_id \
    --protocol tcp \
    --port 2049 \
    --cidr $cidr_range

# create a file system
file_system_id=$(aws efs create-file-system \
    --region $regionCode \
    --performance-mode generalPurpose \
    --query 'FileSystemId' \
    --output text)
echo $file_system_id

# create mount targets. 

# To determine the IDs of the subnets in your VPC and which AZ the subnet is in

subnetIds=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc_id" --query 'Subnets[*].SubnetId' --output text)
echo $subnetIds

# Add mount targets for the subnets that your nodes are in
for subnetId in $subnetIds;
  do 
	echo "Creating mount target on subnet: $subnetId";
    aws efs create-mount-target \
    --file-system-id $file_system_id \
    --subnet-id $subnetId \
    --security-groups $security_group_id
  done;

# Enable control plane logging
eksctl utils update-cluster-logging \
  --enable-types api,scheduler,controllerManager \
  --region $regionCode \
  --cluster $eksclusterName \
  --approve

# Set up Container Insights for metrics and workload logging using the CloudWatch agent
#   https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/deploy-container-insights-EKS.html

# Follow the directions for attaching the IAM CloudWatchAgentServerPolicy to the worker nodes from here:
#   https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-prerequisites.html

# Follow the directions from the Quick Start setup for Container Insights
#   https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html
ClusterName=$eksclusterName
RegionName=$regionCode
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f - 

# Check CloudWatch Log groups. The following log groups should be present:
#  /aws/containerinsights/Cluster_Name/application
#  /aws/containerinsights/Cluster_Name/host
#  /aws/containerinsights/Cluster_Name/dataplane

# modify the volumeHandle in the efs-pv.yaml with the [FileSystemId]
echo "Before creating the PV, make sure to modify the volumeHandle in the efs-pv.yaml with the FileSystemId: $file_system_id"

# manually create a PV and PVC

# deploy the storage class, pv, and pvc
kubectl apply -f efs-sc.yaml

kubectl apply -f efs-pv.yaml
kubectl get pv -w

kubectl apply -f efs-pvc.yaml
kubectl get pvc -w

# proceed only if the PVC status is Bound

# deploy workload


###################################################
# Clean up (uncomment)
###################################################

# # delete the cluster
# eksctl delete cluster \
#     --name $eksclusterName \
#     --region $regionCode

# # delete the filesystem
# # file_system_id="fs-0b1c7c64a5faa2767"
# # vpc_id="vpc-0511903bfc6a6585a"

# # delete the mount targets
# mountTargets=$(aws efs describe-mount-targets --file-system-id $file_system_id --query 'MountTargets[*].MountTargetId' --output text);
# for mt in $mountTargets;
#   do 
# 	echo "Deleting mount target: $mt";
# 	aws efs delete-mount-target --mount-target-id $mt;
#   done;

# # delete the file system
# aws efs delete-file-system \
#     --file-system-id $file_system_id \
#     --region $regionCode

# # delete the security group
# aws ec2 delete-security-group \
#     --group-name $efsSecurityGroupName \
#     --region $regionCode
