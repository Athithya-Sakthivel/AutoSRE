cd /workspace/rivulet/api-gateway

./mvnw -DskipTests clean compile

# Format check (Google Java Format via Spotless)
./mvnw spotless:apply

./mvnw -DskipTests spotless:check
