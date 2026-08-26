package com.prod.taskapi.integration;

import com.prod.taskapi.dto.LoginRequest;
import com.prod.taskapi.dto.RegisterRequest;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.*;

import static org.assertj.core.api.Assertions.assertThat;

class AuthIntegrationTest extends BaseIntegrationTest {

    @Autowired
    private TestRestTemplate restTemplate;

    @Test
    void registerAndLoginShouldReturnJwt() {
        // Register
        RegisterRequest registerRequest = new RegisterRequest("testuser", "test@example.com", "password123");
        ResponseEntity<String> registerResponse = restTemplate.postForEntity(
                "/api/v1/auth/register", registerRequest, String.class);

        assertThat(registerResponse.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        assertThat(registerResponse.getBody()).contains("token");

        // Login
        LoginRequest loginRequest = new LoginRequest("testuser", "password123");
        ResponseEntity<String> loginResponse = restTemplate.postForEntity(
                "/api/v1/auth/login", loginRequest, String.class);

        assertThat(loginResponse.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(loginResponse.getBody()).contains("token");
    }

    @Test
    void registerWithDuplicateUsernameShouldFail() {
        RegisterRequest first = new RegisterRequest("duplicate", "dup@example.com", "password123");
        restTemplate.postForEntity("/api/v1/auth/register", first, String.class);

        RegisterRequest duplicate = new RegisterRequest("duplicate", "another@example.com", "password123");
        ResponseEntity<String> response = restTemplate.postForEntity(
                "/api/v1/auth/register", duplicate, String.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
    }
}