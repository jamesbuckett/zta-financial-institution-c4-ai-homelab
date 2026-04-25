# 1. ConfigMap exists in the zta-system namespace.
kubectl --context docker-desktop -n zta-system get configmap zta-label-schema \
  -o jsonpath='{.metadata.name}{" "}{.metadata.labels.zta\.resource}{"\n"}'
# Expected: zta-label-schema true

# 2. Schema is parseable YAML and declares the three required labels.
kubectl --context docker-desktop -n zta-system get configmap zta-label-schema \
  -o jsonpath='{.data.schema\.yaml}' \
  | yq -r '.labels | to_entries | map(select(.value.required == true)) | .[].key'
# Expected (any order):
#   zta.resource
#   zta.data-class
#   zta.owner

# 3. The schema itself carries the resource label — it is a labelled resource.
kubectl --context docker-desktop -n zta-system get configmap zta-label-schema \
  -l zta.resource=true --no-headers | wc -l
# Expected: 1

