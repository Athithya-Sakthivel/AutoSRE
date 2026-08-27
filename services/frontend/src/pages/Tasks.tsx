import {
  useCallback,
  useEffect,
  useState
} from 'react'
import {
  useNavigate
} from 'react-router'
import {
  ApiError,
  setToken,
  taskApi
} from '../api'
import TaskForm from '../components/TaskForm'
import type { Task } from '../types'

export default function Tasks() {
  const navigate =
    useNavigate()

  const [tasks, setTasks] =
    useState<Task[]>([])

  const [error, setError] =
    useState('')

  const [isLoading, setIsLoading] =
    useState(true)

  const handleUnauthorized =
    useCallback((): void => {
      setToken(null)

      navigate('/login', {
        replace: true
      })
    }, [navigate])

  const loadTasks =
    useCallback(
      async (
        signal?: AbortSignal
      ): Promise<void> => {
        setError('')
        setIsLoading(true)

        try {
          const data =
            await taskApi.list(
              signal
            )

          setTasks(data)
        } catch (
          err: unknown
        ) {
          if (
            err instanceof DOMException &&
            err.name === 'AbortError'
          ) {
            return
          }

          if (
            err instanceof ApiError &&
            err.status === 401
          ) {
            handleUnauthorized()
            return
          }

          setError(
            err instanceof Error
              ? err.message
              : 'Failed to load tasks.'
          )
        } finally {
          if (!signal?.aborted) {
            setIsLoading(false)
          }
        }
      },
      [handleUnauthorized]
    )

  useEffect(() => {
    const controller =
      new AbortController()

    void loadTasks(
      controller.signal
    )

    return () => {
      controller.abort()
    }
  }, [loadTasks])

  function handleTaskCreated(
    task: Task
  ): void {
    setTasks(
      (previousTasks) => [
        ...previousTasks,
        task
      ]
    )
  }

  function handleLogout(): void {
    setToken(null)

    navigate('/login', {
      replace: true
    })
  }

  return (
    <main className="tasks-page">
      <header className="tasks-header">
        <div>
          <h1>Tasks</h1>

          <p
            className="muted"
            aria-live="polite"
          >
            {tasks.length}{' '}
            {tasks.length === 1
              ? 'task'
              : 'tasks'}
          </p>
        </div>

        <button
          type="button"
          className="secondary-button"
          onClick={handleLogout}
        >
          Logout
        </button>
      </header>

      <TaskForm
        onCreated={
          handleTaskCreated
        }
      />

      {error && (
        <div
          className="error-banner"
          role="alert"
        >
          <span>{error}</span>

          <button
            type="button"
            className="link-button"
            onClick={() =>
              void loadTasks()
            }
          >
            Retry
          </button>
        </div>
      )}

      {isLoading ? (
        <p
          className="muted"
          aria-live="polite"
        >
          Loading tasks…
        </p>
      ) : tasks.length === 0 ? (
        <p className="empty-state">
          No tasks yet. Create your
          first task above.
        </p>
      ) : (
        <ul className="task-list">
          {tasks.map((task) => (
            <li
              key={task.id}
              className="task-item"
            >
              <div className="task-main">
                <strong>
                  {task.title}
                </strong>

                {task.description && (
                  <p className="task-description">
                    {task.description}
                  </p>
                )}

                <time
                  dateTime={
                    task.createdAt
                  }
                  className="muted"
                >
                  {formatDate(
                    task.createdAt
                  )}
                </time>
              </div>

              <span
                className={`status ${task.status.toLowerCase()}`}
              >
                {formatStatus(
                  task.status
                )}
              </span>
            </li>
          ))}
        </ul>
      )}
    </main>
  )
}

function formatDate(
  value: string
): string {
  const date = new Date(value)

  if (
    Number.isNaN(
      date.getTime()
    )
  ) {
    return 'Unknown date'
  }

  return date.toLocaleString()
}

function formatStatus(
  status: Task['status']
): string {
  return status
    .toLowerCase()
    .replace(/_/g, ' ')
    .replace(
      /\b\w/g,
      (character) =>
        character.toUpperCase()
    )
}