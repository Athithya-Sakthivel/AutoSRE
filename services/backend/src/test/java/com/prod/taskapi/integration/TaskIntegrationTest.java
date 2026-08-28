package com.prod.taskapi.integration;

import static org.assertj.core.api.Assertions.assertThat;

import com.prod.taskapi.dto.LoginRequest;
import com.prod.taskapi.dto.RegisterRequest;
import com.prod.taskapi.dto.TaskRequest;
import com.prod.taskapi.entity.Status;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.*;

class TaskIntegrationTest extends BaseIntegrationTest {

  @Autowired private TestRestTemplate restTemplate;

  private String jwtToken;

  @BeforeEach
  void setUp() {
    // Register a user and get token
    RegisterRequest registerRequest =
        new RegisterRequest("taskuser", "task@example.com", "password123");
    restTemplate.postForEntity("/api/v1/auth/register", registerRequest, String.class);

    LoginRequest loginRequest = new LoginRequest("taskuser", "password123");
    ResponseEntity<String> loginResponse =
        restTemplate.postForEntity("/api/v1/auth/login", loginRequest, String.class);
    // Extract token from JSON (simplified; use ObjectMapper in real test)
    jwtToken = loginResponse.getBody().replaceAll(".*\"token\":\"([^\"]+)\".*", "$1");
  }

  @Test
  void createAndGetTask() {
    HttpHeaders headers = new HttpHeaders();
    headers.setBearerAuth(jwtToken);
    headers.setContentType(MediaType.APPLICATION_JSON);

    TaskRequest taskRequest = new TaskRequest("Test Task", "Description", Status.PENDING);
    HttpEntity<TaskRequest> request = new HttpEntity<>(taskRequest, headers);

    ResponseEntity<String> createResponse =
        restTemplate.postForEntity("/api/v1/tasks", request, String.class);
    assertThat(createResponse.getStatusCode()).isEqualTo(HttpStatus.CREATED);

    // Get tasks
    HttpEntity<Void> getRequest = new HttpEntity<>(headers);
    ResponseEntity<String> getResponse =
        restTemplate.exchange("/api/v1/tasks", HttpMethod.GET, getRequest, String.class);
    assertThat(getResponse.getStatusCode()).isEqualTo(HttpStatus.OK);
    assertThat(getResponse.getBody()).contains("Test Task");
  }
}
