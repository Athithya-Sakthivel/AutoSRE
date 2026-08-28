package com.prod.taskapi.dto;

import com.prod.taskapi.entity.Status;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record TaskRequest(
    @NotBlank(message = "Title is required")
        @Size(max = 255, message = "Title must not exceed 255 characters")
        String title,
    @Size(max = 5000, message = "Description must not exceed 5000 characters") String description,
    Status status) {
  public TaskRequest {
    if (status == null) {
      status = Status.PENDING;
    }
  }
}
