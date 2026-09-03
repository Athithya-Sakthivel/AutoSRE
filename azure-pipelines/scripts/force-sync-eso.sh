# force sync externalsecrets incase of task-api ns deletion
kubectl delete secret backend-secrets -n task-api --ignore-not-found=true
kubectl annotate externalsecret backend-secrets -n task-api \
  force-sync="$(date +%s)" --overwrite
sleep 5
kubectl get secret backend-secrets -n task-api
