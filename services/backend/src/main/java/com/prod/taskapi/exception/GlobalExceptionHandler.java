package com.prod.taskapi.exception;

import java.time.OffsetDateTime;
import java.util.HashMap;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class GlobalExceptionHandler {

  private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

  @ExceptionHandler(IllegalArgumentException.class)
  public ResponseEntity<Map<String, Object>> handleIllegalArgument(IllegalArgumentException ex) {
    log.warn("Bad request: {}", ex.getMessage());
    return buildError(HttpStatus.BAD_REQUEST, ex.getMessage());
  }

  @ExceptionHandler(BadCredentialsException.class)
  public ResponseEntity<Map<String, Object>> handleBadCredentials(BadCredentialsException ex) {
    log.warn("Authentication failed: {}", ex.getMessage());
    return buildError(HttpStatus.UNAUTHORIZED, "Invalid username or password");
  }

  @ExceptionHandler(MethodArgumentNotValidException.class)
  public ResponseEntity<Map<String, Object>> handleValidation(MethodArgumentNotValidException ex) {
    Map<String, String> errors = new HashMap<>();
    for (FieldError error : ex.getBindingResult().getFieldErrors()) {
      errors.put(error.getField(), error.getDefaultMessage());
    }
    log.warn("Validation failed: {}", errors);
    Map<String, Object> body = new HashMap<>();
    body.put("timestamp", OffsetDateTime.now());
    body.put("status", HttpStatus.BAD_REQUEST.value());
    body.put("error", "Validation Failed");
    body.put("details", errors);
    return ResponseEntity.badRequest().body(body);
  }

  @ExceptionHandler(Exception.class)
  public ResponseEntity<Map<String, Object>> handleGeneric(Exception ex) {
    log.error("Unexpected error", ex);
    return buildError(HttpStatus.INTERNAL_SERVER_ERROR, "Internal server error");
  }

  private ResponseEntity<Map<String, Object>> buildError(HttpStatus status, String message) {
    Map<String, Object> body = new HashMap<>();
    body.put("timestamp", OffsetDateTime.now());
    body.put("status", status.value());
    body.put("error", status.getReasonPhrase());
    body.put("message", message);
    return ResponseEntity.status(status).body(body);
  }
}
