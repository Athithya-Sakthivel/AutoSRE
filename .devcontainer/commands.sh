python3 --version && which python3
az version --query '"azure-cli"' -o tsv
tofu version | head -1
kubectl version --client 2>&1 | head -1
java --version
mvn --version
go version
kind version
helm version --short
k6 version
cloudflared --version 2>&1 | head -1
node --version && npm --version
pytest --version
pre-commit --version


export TAG=$(date -u +%Y.%m.%d)
echo "$GIT_PAT" | docker login ghcr.io -u athithya-sakthivel --password-stdin
docker tag $(docker ps --format '{{.Image}}' | grep '^vsc-autosre-' | head -1) ghcr.io/athithya-sakthivel/autosre-devcontainer:$TAG
docker push ghcr.io/athithya-sakthivel/autosre-devcontainer:$TAG
docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/athithya-sakthivel/autosre-devcontainer:$TAG


go install mvdan.cc/gofumpt@v0.8.0
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.13.2
go install golang.org/x/vuln/cmd/govulncheck@v1.1.4
