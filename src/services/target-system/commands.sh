

if ! az extension show --name application-insights >/dev/null 2>&1; then
  az extension add --name application-insights --only-show-errors
fi


az group delete --name rg-target-system-12 --yes --no-wait

bash services/target-system/local_testing.sh


TOKEN=$(az account get-access-token \
  --resource https://api.loganalytics.io \
  --query accessToken -o tsv)
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  -g rg-target-system-12 \
  -n law-target-system \
  --query customerId -o tsv)
curl -s \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://api.loganalytics.io/v1/workspaces/${WORKSPACE_ID}/query" \
  -d '{
    "query":"AppTraces | where TimeGenerated > ago(1h) | take 10"
  }' | jq


# 1. Build the image
docker build -t target-system services/target-system

# 2. Start the container in detached mode
docker run -d -p 8000:8000 --name target-system-test target-system

# 3. Wait for the server to be healthy
sleep 3

# 4. Activate virtualenv and run pytest
source services/target-system/.venv_target_system/bin/activate
python -m pytest services/target-system/tests/ -v

# 5. Curl battle tests
echo "===== CURL TESTS ====="
curl -s http://localhost:8000/health | python -m json.tool
curl -s -X POST http://localhost:8000/api/process | python -m json.tool
curl -s -X POST 'http://localhost:8000/chaos/oom' | python -m json.tool
curl -s -X POST http://localhost:8000/api/process
echo ""
curl -s -X POST http://localhost:8000/chaos/reset | python -m json.tool
curl -s -X POST http://localhost:8000/api/process | python -m json.tool
echo "===== DONE ====="

# 6. Cleanup
docker stop target-system-test
docker rm target-system-test
