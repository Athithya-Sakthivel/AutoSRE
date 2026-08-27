import {
  useEffect,
  useRef,
  useState,
  type FormEvent
} from 'react'
import {
  Link,
  useLocation,
  useNavigate
} from 'react-router'
import {
  ApiError,
  authApi,
  setToken
} from '../api'

interface LoginLocationState {
  from?: unknown
}

function getSafeDestination(
  value: unknown
): string {
  if (
    typeof value === 'string' &&
    value.startsWith('/') &&
    !value.startsWith('//')
  ) {
    return value
  }

  return '/tasks'
}

export default function Login() {
  const navigate =
    useNavigate()

  const location =
    useLocation()

  const abortControllerRef =
    useRef<AbortController | null>(
      null
    )

  const locationState =
    location.state as
      | LoginLocationState
      | null

  const destination =
    getSafeDestination(
      locationState?.from
    )

  const [username, setUsername] =
    useState('')

  const [password, setPassword] =
    useState('')

  const [error, setError] =
    useState('')

  const [isSubmitting, setIsSubmitting] =
    useState(false)

  useEffect(() => {
    return () => {
      abortControllerRef.current?.abort()
    }
  }, [])

  async function handleSubmit(
    event: FormEvent<HTMLFormElement>
  ): Promise<void> {
    event.preventDefault()
    setError('')

    if (
      !username.trim() ||
      !password
    ) {
      setError(
        'Username and password are required.'
      )
      return
    }

    setIsSubmitting(true)

    const controller =
      new AbortController()

    abortControllerRef.current =
      controller

    try {
      const data =
        await authApi.login(
          username,
          password,
          controller.signal
        )

      setToken(data.token)

      navigate(destination, {
        replace: true
      })
    } catch (err: unknown) {
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
        setError(
          'Invalid username or password.'
        )
      } else {
        setError(
          err instanceof Error
            ? err.message
            : 'Login failed.'
        )
      }
    } finally {
      if (
        abortControllerRef.current ===
        controller
      ) {
        abortControllerRef.current =
          null
      }

      setIsSubmitting(false)
    }
  }

  return (
    <main className="auth-page">
      <h1>Login</h1>

      <form
        onSubmit={handleSubmit}
      >
        <label htmlFor="login-username">
          Username
        </label>

        <input
          id="login-username"
          name="username"
          type="text"
          placeholder="Username"
          value={username}
          onChange={(event) =>
            setUsername(
              event.target.value
            )
          }
          autoComplete="username"
          autoFocus
          required
          disabled={isSubmitting}
        />

        <label htmlFor="login-password">
          Password
        </label>

        <input
          id="login-password"
          name="password"
          type="password"
          placeholder="Password"
          value={password}
          onChange={(event) =>
            setPassword(
              event.target.value
            )
          }
          autoComplete="current-password"
          required
          disabled={isSubmitting}
        />

        {error && (
          <p
            className="error"
            role="alert"
          >
            {error}
          </p>
        )}

        <button
          type="submit"
          disabled={isSubmitting}
        >
          {isSubmitting
            ? 'Logging in…'
            : 'Login'}
        </button>
      </form>

      <p className="auth-link">
        Don&apos;t have an account?{' '}
        <Link to="/register">
          Register
        </Link>
      </p>
    </main>
  )
}