package com.prod.taskapi.service;

import com.prod.taskapi.dto.TaskRequest;
import com.prod.taskapi.dto.TaskResponse;
import com.prod.taskapi.entity.Status;
import com.prod.taskapi.entity.Task;
import com.prod.taskapi.repository.TaskRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
public class TaskService {

    private static final Logger log = LoggerFactory.getLogger(TaskService.class);

    private final TaskRepository taskRepository;

    public TaskService(TaskRepository taskRepository) {
        this.taskRepository = taskRepository;
    }

    @Transactional
    public TaskResponse createTask(TaskRequest request, Long userId) {
        log.info("Create task userId={} title={}", userId, request.title());

        Task task = new Task(
                request.title(),
                request.description(),
                request.status() != null ? request.status() : Status.PENDING,
                userId
        );
        Task saved = taskRepository.save(task);

        log.info("Task created taskId={} userId={}", saved.getId(), userId);
        return toResponse(saved);
    }

    @Transactional(readOnly = true)
    public List<TaskResponse> getTasks(Long userId) {
        log.info("Fetch tasks userId={}", userId);
        return taskRepository.findByUserId(userId).stream()
                .map(this::toResponse)
                .toList();
    }

    @Transactional(readOnly = true)
    public TaskResponse getTask(Long taskId, Long userId) {
        log.info("Fetch task taskId={} userId={}", taskId, userId);
        Task task = taskRepository.findByIdAndUserId(taskId, userId)
                .orElseThrow(() -> {
                    log.warn("Task not found taskId={} userId={}", taskId, userId);
                    return new IllegalArgumentException("Task not found");
                });
        return toResponse(task);
    }

    @Transactional
    public TaskResponse updateTask(Long taskId, TaskRequest request, Long userId) {
        log.info("Update task taskId={} userId={}", taskId, userId);

        Task task = taskRepository.findByIdAndUserId(taskId, userId)
                .orElseThrow(() -> {
                    log.warn("Task not found for update taskId={} userId={}", taskId, userId);
                    return new IllegalArgumentException("Task not found");
                });

        if (request.title() != null) {
            task.setTitle(request.title());
        }
        if (request.description() != null) {
            task.setDescription(request.description());
        }
        if (request.status() != null) {
            task.setStatus(request.status());
        }

        Task updated = taskRepository.save(task);
        log.info("Task updated taskId={} userId={}", updated.getId(), userId);
        return toResponse(updated);
    }

    @Transactional
    public void deleteTask(Long taskId, Long userId) {
        log.info("Delete task taskId={} userId={}", taskId, userId);
        taskRepository.deleteByIdAndUserId(taskId, userId);
        log.info("Task deleted taskId={} userId={}", taskId, userId);
    }

    private TaskResponse toResponse(Task task) {
        return new TaskResponse(
                task.getId(),
                task.getTitle(),
                task.getDescription(),
                task.getStatus(),
                task.getUserId(),
                task.getCreatedAt(),
                task.getUpdatedAt()
        );
    }
}