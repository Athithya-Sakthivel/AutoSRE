package com.prod.taskapi.dto;

import com.prod.taskapi.entity.Status;
import java.time.OffsetDateTime;

public record TaskResponse(
        Long id,
        String title,
        String description,
        Status status,
        Long userId,
        OffsetDateTime createdAt,
        OffsetDateTime updatedAt
) {}