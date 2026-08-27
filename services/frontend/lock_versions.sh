cd /workspace/services/frontend

set -eux

docker build \
  -t task-api-frontend-lockgen:local \
  -f- . <<'EOF'
FROM docker.io/library/node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43
WORKDIR /app
COPY package.json ./
RUN npm install --package-lock-only
EOF

cid="$(docker create task-api-frontend-lockgen:local)"
docker cp "$cid:/app/package-lock.json" ./package-lock.json
docker rm "$cid"

ls -lh package.json package-lock.json
