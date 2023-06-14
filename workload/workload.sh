# apply the configmap
kubectl apply -f statefulapp-configmap.yaml

# deploy the writer pod
kubectl apply -f writer-fs.yaml

# deploy the reader pod
kubectl apply -f reader-fs.yaml

# expose and access reader to a service load balancer
kubectl create -f loadbalancer.yaml
kubectl get svc --watch

# add downloader pod to use some bandwidth
kubectl apply -f downloader-fs.yaml

# scale up the writer pod
kubectl scale deployment writer --replicas=40
