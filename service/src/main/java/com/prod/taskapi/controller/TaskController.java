package com.prod.taskapi.controller;

import com.prod.taskapi.dto.TaskRequest;
import com.prod.taskapi.dto.TaskResponse;
import com.prod.taskapi.service.TaskService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1/tasks")
public class TaskController {

    private final TaskService taskService;

    public TaskController(TaskService taskService) {
        this.taskService = taskService;
    }

    @PostMapping
    public ResponseEntity<TaskResponse> createTask(@Valid @RequestBody TaskRequest request,
                                                   Authentication authentication) {
        Long userId = getUserId(authentication);
        TaskResponse response = taskService.createTask(request, userId);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    @GetMapping
    public ResponseEntity<List<TaskResponse>> getTasks(Authentication authentication) {
        Long userId = getUserId(authentication);
        List<TaskResponse> tasks = taskService.getTasks(userId);
        return ResponseEntity.ok(tasks);
    }

    @GetMapping("/{taskId}")
    public ResponseEntity<TaskResponse> getTask(@PathVariable Long taskId,
                                                Authentication authentication) {
        Long userId = getUserId(authentication);
        TaskResponse task = taskService.getTask(taskId, userId);
        return ResponseEntity.ok(task);
    }

    @PutMapping("/{taskId}")
    public ResponseEntity<TaskResponse> updateTask(@PathVariable Long taskId,
                                                   @Valid @RequestBody TaskRequest request,
                                                   Authentication authentication) {
        Long userId = getUserId(authentication);
        TaskResponse updated = taskService.updateTask(taskId, request, userId);
        return ResponseEntity.ok(updated);
    }

    @DeleteMapping("/{taskId}")
    public ResponseEntity<Void> deleteTask(@PathVariable Long taskId,
                                           Authentication authentication) {
        Long userId = getUserId(authentication);
        taskService.deleteTask(taskId, userId);
        return ResponseEntity.noContent().build();
    }

    private Long getUserId(Authentication authentication) {
        // The userId is stored in the JWT token and placed into the Authentication
        // details by JwtAuthenticationFilter.
        Object details = authentication.getDetails();
        if (details instanceof Long userId) {
            return userId;
        }
        throw new IllegalStateException("User ID not found in authentication details");
    }
}