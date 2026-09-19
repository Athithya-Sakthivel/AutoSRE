cd /workspace/rivulet/api-gateway

./mvnw -DskipTests clean compile

# Format check (Google Java Format via Spotless)
./mvnw -DskipTests spotless:check

pre-commit run --all-files
