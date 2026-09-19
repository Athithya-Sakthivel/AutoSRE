package com.rivulet.gateway.controller;

import com.rivulet.gateway.service.InventoryService;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Read-only inventory API.
 *
 * <p>Provides direct visibility into current stock levels for a given SKU. Authoritative inventory
 * mutation is performed by the asynchronous ingestion worker inside its database transaction.
 */
@RestController
@RequestMapping("/inventory")
public final class InventoryController {

    private final InventoryService inventoryService;

    public InventoryController(InventoryService inventoryService) {
        this.inventoryService =
                Objects.requireNonNull(inventoryService, "inventoryService must not be null");
    }

    /**
     * Returns the current stock level for a SKU.
     *
     * @param sku inventory SKU
     * @return current quantity or a not-found response
     */
    @GetMapping("/{sku}")
    public ResponseEntity<?> getStock(@PathVariable String sku) {
        if (sku == null || sku.isBlank()) {
            return ResponseEntity.badRequest().body(Map.of("error", "sku is required"));
        }

        Optional<Integer> stockLevel = inventoryService.getStockLevel(sku);

        if (stockLevel.isEmpty()) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND)
                    .body(Map.of("error", "SKU not found"));
        }

        return ResponseEntity.ok(Map.of("sku", sku, "quantity", stockLevel.get()));
    }
}
