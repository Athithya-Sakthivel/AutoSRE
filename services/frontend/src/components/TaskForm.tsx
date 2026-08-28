import { useEffect, useRef, useState, type FormEvent } from "react";
import { useNavigate } from "react-router";
import { ApiError, setToken, taskApi } from "../api";
import type { Task } from "../types";

interface TaskFormProps {
  onCreated: (task: Task) => void;
}

export default function TaskForm({ onCreated }: TaskFormProps) {
  const navigate = useNavigate();

  const abortControllerRef = useRef<AbortController | null>(null);

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [error, setError] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);

  useEffect(() => {
    return () => {
      abortControllerRef.current?.abort();
    };
  }, []);

  async function handleSubmit(
    event: FormEvent<HTMLFormElement>,
  ): Promise<void> {
    event.preventDefault();
    setError("");

    const normalizedTitle = title.trim();

    const normalizedDescription = description.trim();

    if (!normalizedTitle) {
      setError("Task title is required.");
      return;
    }

    setIsSubmitting(true);

    const controller = new AbortController();

    abortControllerRef.current = controller;

    try {
      const task = await taskApi.create(
        normalizedTitle,
        normalizedDescription,
        controller.signal,
      );

      onCreated(task);

      setTitle("");
      setDescription("");
    } catch (err: unknown) {
      if (err instanceof DOMException && err.name === "AbortError") {
        return;
      }

      if (err instanceof ApiError && err.status === 401) {
        setToken(null);
        navigate("/login", {
          replace: true,
        });
        return;
      }

      setError(err instanceof Error ? err.message : "Failed to create task.");
    } finally {
      if (abortControllerRef.current === controller) {
        abortControllerRef.current = null;
      }

      setIsSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="task-form">
      <label htmlFor="task-title">Title</label>

      <input
        id="task-title"
        name="title"
        type="text"
        placeholder="Task title"
        value={title}
        onChange={(event) => setTitle(event.target.value)}
        maxLength={255}
        required
        autoComplete="off"
        disabled={isSubmitting}
      />

      <label htmlFor="task-description">Description</label>

      <textarea
        id="task-description"
        name="description"
        placeholder="Description"
        value={description}
        onChange={(event) => setDescription(event.target.value)}
        rows={4}
        maxLength={2000}
        disabled={isSubmitting}
      />

      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}

      <button type="submit" disabled={isSubmitting}>
        {isSubmitting ? "Creating…" : "Create task"}
      </button>
    </form>
  );
}
