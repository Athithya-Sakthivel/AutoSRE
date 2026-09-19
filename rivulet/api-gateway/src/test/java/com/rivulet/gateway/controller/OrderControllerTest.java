package com.rivulet.gateway.controller;

import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.rivulet.gateway.service.OrderService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(OrderController.class)
class OrderControllerTest {

    @Autowired private MockMvc mockMvc;

    @MockitoBean private OrderService orderService;

    @Test
    void checkout_validRequest_returns202WithEventId() throws Exception {
        String eventId = "01928a3b-4c5d-7e6f-8a9b-0c1d2e3f4a5b";
        when(orderService.processCheckout(anyString(), anyString(), anyInt(), anyString()))
                .thenReturn(eventId);

        mockMvc.perform(
                        post("/orders/00000000-0000-0000-0000-000000000001/checkout")
                                .contentType(MediaType.APPLICATION_JSON)
                                .header("X-Request-ID", "req-123")
                                .content("{\"sku\":\"TEST-SKU\",\"quantity\":1}"))
                .andExpect(status().isAccepted())
                .andExpect(jsonPath("$.eventId").value(eventId));
    }

    @Test
    void checkout_missingUserId_returns400() throws Exception {
        mockMvc.perform(
                        post("/orders/ /checkout")
                                .contentType(MediaType.APPLICATION_JSON)
                                .content("{\"sku\":\"TEST-SKU\",\"quantity\":1}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("userId is required"));
    }

    @Test
    void checkout_missingRequestBody_returns400() throws Exception {
        mockMvc.perform(
                        post("/orders/00000000-0000-0000-0000-000000000001/checkout")
                                .contentType(MediaType.APPLICATION_JSON))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("request body is required"));
    }

    @Test
    void checkout_missingSku_returns400() throws Exception {
        mockMvc.perform(
                        post("/orders/00000000-0000-0000-0000-000000000001/checkout")
                                .contentType(MediaType.APPLICATION_JSON)
                                .content("{\"quantity\":1}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("sku is required"));
    }

    @Test
    void checkout_zeroQuantity_returns400() throws Exception {
        mockMvc.perform(
                        post("/orders/00000000-0000-0000-0000-000000000001/checkout")
                                .contentType(MediaType.APPLICATION_JSON)
                                .content("{\"sku\":\"TEST-SKU\",\"quantity\":0}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("quantity must be > 0"));
    }

    @Test
    void checkout_duplicateRequest_returns409() throws Exception {
        when(orderService.processCheckout(anyString(), anyString(), anyInt(), anyString()))
                .thenThrow(new IllegalStateException("Duplicate request"));

        mockMvc.perform(
                        post("/orders/00000000-0000-0000-0000-000000000001/checkout")
                                .contentType(MediaType.APPLICATION_JSON)
                                .header("X-Request-ID", "req-dup")
                                .content("{\"sku\":\"TEST-SKU\",\"quantity\":1}"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("Duplicate request"));
    }

    @Test
    void checkout_insufficientInventory_returns409() throws Exception {
        when(orderService.processCheckout(anyString(), anyString(), anyInt(), anyString()))
                .thenThrow(new IllegalStateException("Insufficient inventory for SKU: TEST-SKU"));

        mockMvc.perform(
                        post("/orders/00000000-0000-0000-0000-000000000001/checkout")
                                .contentType(MediaType.APPLICATION_JSON)
                                .content("{\"sku\":\"TEST-SKU\",\"quantity\":999}"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.error").value("Insufficient inventory for SKU: TEST-SKU"));
    }

    @Test
    void checkout_invalidUserId_returns400() throws Exception {
        when(orderService.processCheckout(anyString(), anyString(), anyInt(), anyString()))
                .thenThrow(new IllegalArgumentException("userId must be a valid UUID"));

        mockMvc.perform(
                        post("/orders/not-a-uuid/checkout")
                                .contentType(MediaType.APPLICATION_JSON)
                                .content("{\"sku\":\"TEST-SKU\",\"quantity\":1}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("userId must be a valid UUID"));
    }
}
