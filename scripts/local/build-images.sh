export REGISTRY="ghcr.io"
export USERNAME="athithya-sakthivel"
export BACKEND_IMAGE="task-api-backend"
export FRONTEND_IMAGE="task-api-frontend"

echo "$GIT_PAT" | docker login "$REGISTRY" -u "$USERNAME" --password-stdin

# backend java code changes not undetected
docker build --no-cache -t "$REGISTRY/$USERNAME/$BACKEND_IMAGE:v2" \
  -f services/backend/Dockerfile services/backend

docker build --no-cache -t "$REGISTRY/$USERNAME/$FRONTEND_IMAGE:v2" \
  -f services/frontend/Dockerfile services/frontend

docker push "$REGISTRY/$USERNAME/$BACKEND_IMAGE:v2"

docker push "$REGISTRY/$USERNAME/$FRONTEND_IMAGE:v2"
