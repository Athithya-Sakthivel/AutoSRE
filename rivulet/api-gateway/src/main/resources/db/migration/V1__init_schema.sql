-- =============================================================================
-- V1__init_schema.sql — Initial schema for Rivulet platform
-- =============================================================================
-- Ownership:
--   - Java API Gateway owns DDL through Flyway.
--   - Go ingestion worker has no DDL permissions.
--   - Go worker performs DML only.
--
-- Idempotency:
--   - orders.event_id is the database-level deduplication key.
--   - The worker must insert the order and perform its business-side effects
--     in the same database transaction for exactly-once business semantics.
--
-- Compatibility:
--   - Uses PostgreSQL UUID support available without requiring pgcrypto.
--   - Does not impose application-specific order-status values because those
--     values are owned by the worker/business workflow.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Inventory
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS inventory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sku TEXT NOT NULL,
    quantity INT NOT NULL DEFAULT 0,
    version INT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_inventory_sku UNIQUE (sku),
    CONSTRAINT chk_inventory_sku_nonblank CHECK (length(btrim(sku)) > 0),
    CONSTRAINT chk_inventory_quantity_nonnegative CHECK (quantity >= 0),
    CONSTRAINT chk_inventory_version_positive CHECK (version > 0)
);

-- -----------------------------------------------------------------------------
-- Orders
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id TEXT NOT NULL,
    user_id UUID NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_orders_event_id UNIQUE (event_id),
    CONSTRAINT chk_orders_event_id_nonblank CHECK (length(btrim(event_id)) > 0),
    CONSTRAINT chk_orders_status_nonblank CHECK (length(btrim(status)) > 0)
);

-- -----------------------------------------------------------------------------
-- Lookup indexes
-- -----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_orders_user_id
    ON orders (user_id);

CREATE INDEX IF NOT EXISTS idx_orders_status
    ON orders (status);

-- -----------------------------------------------------------------------------
-- Automatic updated_at maintenance
--
-- The Go worker can continue issuing ordinary UPDATE statements without
-- needing to remember to update updated_at explicitly.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rivulet_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_inventory_updated_at ON inventory;

CREATE TRIGGER trg_inventory_updated_at
BEFORE UPDATE ON inventory
FOR EACH ROW
EXECUTE FUNCTION rivulet_set_updated_at();

DROP TRIGGER IF EXISTS trg_orders_updated_at ON orders;

CREATE TRIGGER trg_orders_updated_at
BEFORE UPDATE ON orders
FOR EACH ROW
EXECUTE FUNCTION rivulet_set_updated_at();

-- -----------------------------------------------------------------------------
-- Deterministic E2E seed inventory
-- -----------------------------------------------------------------------------

INSERT INTO inventory (sku, quantity)
VALUES
    ('TEST-SKU-E2E', 100),
    ('LAPTOP-PRO-16', 50),
    ('WIRELESS-MOUSE', 200)
ON CONFLICT (sku) DO NOTHING;
