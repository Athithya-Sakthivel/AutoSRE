import type {
  JwtResponse,
  Task,
  TaskStatus
} from './types'

const API_BASE = '/api/v1'
const TOKEN_KEY = 'task-api.token'

let token = readStoredToken()

export class ApiError extends Error {
  readonly status: number
  readonly code:
    | 'HTTP_ERROR'
    | 'NETWORK_ERROR'
    | 'INVALID_RESPONSE'

  constructor(
    message: string,
    status: number,
    code:
      | 'HTTP_ERROR'
      | 'NETWORK_ERROR'
      | 'INVALID_RESPONSE' = 'HTTP_ERROR'
  ) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.code = code
  }
}

export function getToken(): string | null {
  return token
}

export function setToken(
  nextToken: string | null
): void {
  token = nextToken

  try {
    if (nextToken) {
      window.localStorage.setItem(
        TOKEN_KEY,
        nextToken
      )
    } else {
      window.localStorage.removeItem(TOKEN_KEY)
    }
  } catch {
    // Storage can be unavailable in hardened/private
    // browser contexts.
  }
}

function readStoredToken(): string | null {
  if (typeof window === 'undefined') {
    return null
  }

  try {
    return window.localStorage.getItem(
      TOKEN_KEY
    )
  } catch {
    return null
  }
}

if (typeof window !== 'undefined') {
  window.addEventListener(
    'storage',
    (event) => {
      if (event.key === TOKEN_KEY) {
        token = event.newValue
      }
    }
  )
}

function isRecord(
  value: unknown
): value is Record<string, unknown> {
  return (
    typeof value === 'object' &&
    value !== null
  )
}

function isTaskStatus(
  value: unknown
): value is TaskStatus {
  return (
    value === 'PENDING' ||
    value === 'IN_PROGRESS' ||
    value === 'COMPLETED' ||
    value === 'CANCELLED'
  )
}

function parseJwtResponse(
  value: unknown
): JwtResponse {
  if (
    !isRecord(value) ||
    typeof value.token !== 'string' ||
    !value.token.trim()
  ) {
    throw new ApiError(
      'The server returned an invalid authentication response.',
      200,
      'INVALID_RESPONSE'
    )
  }

  return {
    token: value.token,
    ...(typeof value.type === 'string'
      ? { type: value.type }
      : {}),
    ...(typeof value.username === 'string'
      ? { username: value.username }
      : {}),
    ...(typeof value.role === 'string'
      ? { role: value.role }
      : {})
  }
}

function parseTask(
  value: unknown
): Task {
  if (!isRecord(value)) {
    throw new ApiError(
      'The server returned an invalid task.',
      200,
      'INVALID_RESPONSE'
    )
  }

  const {
    id,
    title,
    description,
    status,
    userId,
    createdAt,
    updatedAt
  } = value

  if (
    typeof id !== 'number' ||
    !Number.isSafeInteger(id) ||
    typeof title !== 'string' ||
    !isTaskStatus(status) ||
    typeof userId !== 'number' ||
    !Number.isSafeInteger(userId) ||
    typeof createdAt !== 'string' ||
    typeof updatedAt !== 'string'
  ) {
    throw new ApiError(
      'The server returned an invalid task.',
      200,
      'INVALID_RESPONSE'
    )
  }

  if (
    description !== null &&
    typeof description !== 'string'
  ) {
    throw new ApiError(
      'The server returned an invalid task.',
      200,
      'INVALID_RESPONSE'
    )
  }

  return {
    id,
    title,
    description,
    status,
    userId,
    createdAt,
    updatedAt
  }
}

function parseTaskList(
  value: unknown
): Task[] {
  if (!Array.isArray(value)) {
    throw new ApiError(
      'The server returned an invalid task list.',
      200,
      'INVALID_RESPONSE'
    )
  }

  return value.map(parseTask)
}

async function parseErrorMessage(
  response: Response
): Promise<string> {
  const text = await response.text()

  const fallback =
    response.statusText ||
    `Request failed with status ${response.status}`

  if (!text.trim()) {
    return fallback
  }

  try {
    const data: unknown =
      JSON.parse(text)

    if (isRecord(data)) {
      if (
        typeof data.message === 'string' &&
        data.message.trim()
      ) {
        return data.message
      }

      if (
        typeof data.error === 'string' &&
        data.error.trim()
      ) {
        return data.error
      }
    }
  } catch {
    // Fall through to bounded plain-text handling.
  }

  return (
    text.trim().slice(0, 500) ||
    fallback
  )
}

interface RequestOptions
  extends Omit<RequestInit, 'body'> {
  body?: unknown
}

async function apiRequest<T>(
  path: string,
  options: RequestOptions = {},
  parse: (value: unknown) => T
): Promise<T> {
  const headers = new Headers(
    options.headers
  )

  headers.set(
    'Accept',
    'application/json'
  )

  const body = options.body

  if (body !== undefined) {
    headers.set(
      'Content-Type',
      'application/json'
    )
  }

  const currentToken = getToken()

  if (currentToken) {
    headers.set(
      'Authorization',
      `Bearer ${currentToken}`
    )
  }

  let response: Response

  try {
    response = await fetch(
      `${API_BASE}${path}`,
      {
        ...options,
        headers,
        body:
          body === undefined
            ? undefined
            : JSON.stringify(body)
      }
    )
  } catch (error: unknown) {
    if (
      error instanceof DOMException &&
      error.name === 'AbortError'
    ) {
      throw error
    }

    throw new ApiError(
      'Unable to connect to the server. Please check your connection.',
      0,
      'NETWORK_ERROR'
    )
  }

  if (!response.ok) {
    throw new ApiError(
      await parseErrorMessage(response),
      response.status,
      'HTTP_ERROR'
    )
  }

  if (response.status === 204) {
    return parse(undefined)
  }

  const contentType =
    response.headers
      .get('content-type')
      ?.toLowerCase() ?? ''

  if (
    !contentType.includes(
      'application/json'
    )
  ) {
    throw new ApiError(
      'The server returned an unexpected response format.',
      response.status,
      'INVALID_RESPONSE'
    )
  }

  let data: unknown

  try {
    data = await response.json()
  } catch {
    throw new ApiError(
      'The server returned invalid JSON.',
      response.status,
      'INVALID_RESPONSE'
    )
  }

  return parse(data)
}

export const authApi = {
  login: (
    username: string,
    password: string,
    signal?: AbortSignal
  ) =>
    apiRequest(
      '/auth/login',
      {
        method: 'POST',
        body: {
          username: username.trim(),
          password
        },
        signal
      },
      parseJwtResponse
    ),

  register: (
    username: string,
    email: string,
    password: string,
    signal?: AbortSignal
  ) =>
    apiRequest(
      '/auth/register',
      {
        method: 'POST',
        body: {
          username: username.trim(),
          email: email.trim(),
          password
        },
        signal
      },
      parseJwtResponse
    )
}

export const taskApi = {
  list: (
    signal?: AbortSignal
  ) =>
    apiRequest(
      '/tasks',
      { signal },
      parseTaskList
    ),

  create: (
    title: string,
    description: string,
    signal?: AbortSignal
  ) =>
    apiRequest(
      '/tasks',
      {
        method: 'POST',
        body: {
          title: title.trim(),
          description:
            description.trim() || null,
          status: 'PENDING'
        },
        signal
      },
      parseTask
    )
}