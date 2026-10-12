set +H; kubectl port-forward -n rivulet svc/postgres 5432:5432 >/dev/null 2>&1 & p=$!;
trap 'kill "$p" 2>/dev/null' EXIT; until PGPASSWORD=app psql -h 127.0.0.1 -U app -d app -c 'SELECT 1' >/dev/null 2>&1;
do sleep 1; done; PGPASSWORD=app psql -h 127.0.0.1 -U app -d app -v ON_ERROR_STOP=1 -c "DO \$\$ DECLARE t record;
BEGIN FOR t IN SELECT schemaname, tablename FROM pg_tables WHERE schemaname <> 'information_schema' AND schemaname NOT LIKE 'pg_%' LOOP EXECUTE format('TRUNCATE TABLE %I.%I RESTART IDENTITY CASCADE', t.schemaname, t.tablename); END LOOP; END \$\$;"
