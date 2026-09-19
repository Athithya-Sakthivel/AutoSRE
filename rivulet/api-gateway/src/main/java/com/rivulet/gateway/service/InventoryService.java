package com.rivulet.gateway.service;

import java.util.Optional;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * Read-only inventory service.
 *
 * <p>The API gateway performs a pre-flight availability check only. The Go worker remains
 * responsible for the authoritative atomic inventory deduction inside its database transaction.
 */
@Service
public class InventoryService {

    private static final String STOCK_QUERY = "SELECT quantity FROM inventory WHERE sku = ?";

    private final JdbcTemplate jdbcTemplate;

    public InventoryService(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    /**
     * Retrieves the current stock level for a SKU.
     *
     * @param sku product SKU
     * @return stock quantity when the SKU exists; empty when it does not exist
     * @throws org.springframework.dao.DataAccessException when the database operation itself fails
     */
    public Optional<Integer> getStockLevel(String sku) {
        if (sku == null || sku.isBlank()) {
            return Optional.empty();
        }

        try {
            Integer quantity = jdbcTemplate.queryForObject(STOCK_QUERY, Integer.class, sku);
            return Optional.ofNullable(quantity);
        } catch (EmptyResultDataAccessException e) {
            return Optional.empty();
        }
    }

    /**
     * Performs a pre-flight inventory availability check.
     *
     * <p>The check is deliberately non-authoritative because another order may consume stock
     * between this read and the worker's transactional update.
     *
     * @param sku product SKU
     * @param requestedQuantity quantity requested
     * @return {@code true} only when a valid positive quantity is requested and enough stock is
     *     currently visible
     */
    public boolean hasSufficientInventory(String sku, int requestedQuantity) {
        if (sku == null || sku.isBlank() || requestedQuantity <= 0) {
            return false;
        }

        return getStockLevel(sku)
                .map(currentQuantity -> currentQuantity >= requestedQuantity)
                .orElse(false);
    }
}
