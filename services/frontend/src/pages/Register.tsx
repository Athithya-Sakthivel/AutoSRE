import {
  useEffect,
  useRef,
  useState,
  type FormEvent
} from 'react'
import {
  Link,
  useNavigate
} from 'react-router'
import {
  ApiError,
  authApi,
  setToken
} from '../api'

function looksLikeEmail(
  value: string
): boolean {
  const email = value.trim()

  return (
    email.includes('@') &&
    email.includes('.')
  )
}

export default function Register() {
  const navigate =
    useNavigate()

  const abortControllerRef =
    useRef<AbortController | null>(
      null
    )

  const [username, setUsername] =
    useState('')

  const [email, setEmail] =
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

    const normalizedUsername =
      username.trim()

    const normalizedEmail =
      email.trim()

    if (
      !normalizedUsername ||
      !normalizedEmail ||
      !password
    ) {
      setError(
        'Username, email, and password are required.'
      )
      return
    }

    if (
      !looksLikeEmail(
        normalizedEmail
      )
    ) {
      setError(
        'Enter a valid email address.'
      )
      return
    }

    if (password.length < 8) {
      setError(
        'Password must be at least 8 characters.'
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
        await authApi.register(
          normalizedUsername,
          normalizedEmail,
          password,
          controller.signal
        )

      setToken(data.token)

      navigate('/tasks', {
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
        err.status === 409
      ) {
        setError(
          'That username or email is already registered.'
        )
      } else {
        setError(
          err instanceof Error
            ? err.message
            : 'Registration failed.'
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
      <h1>Register</h1>

      <form
        onSubmit={handleSubmit}
      >
        <label htmlFor="register-username">
          Username
        </label>

        <input
          id="register-username"
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
          required
          minLength={3}
          maxLength={100}
          disabled={isSubmitting}
        />

        <label htmlFor="register-email">
          Email
        </label>

        <input
          id="register-email"
          name="email"
          type="email"
          placeholder="Email"
          value={email}
          onChange={(event) =>
            setEmail(
              event.target.value
            )
          }
          autoComplete="email"
          required
          maxLength={254}
          disabled={isSubmitting}
        />

        <label htmlFor="register-password">
          Password
        </label>

        <input
          id="register-password"
          name="password"
          type="password"
          placeholder="Password"
          value={password}
          onChange={(event) =>
            setPassword(
              event.target.value
            )
          }
          autoComplete="new-password"
          required
          minLength={8}
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
            ? 'Creating account…'
            : 'Register'}
        </button>
      </form>

      <p className="auth-link">
        Already have an account?{' '}
        <Link to="/login">
          Login
        </Link>
      </p>
    </main>
  )
}