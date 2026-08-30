import http from 'k6/http';
import { check } from 'k6';

type JsonObject = Record<string, unknown>;

const DEFAULT_QPS = 50;
const DEFAULT_P95_MS = 200;
const DEFAULT_ERROR_RATE = 0.01;
const DEFAULT_PREALLOCATED_VUS = 25;

const REQUESTS_PER_ITERATION = 3;
const PASSWORD = 'Test@12345';

/**
 * Read a positive numeric environment variable.
 *
 * Fail fast on invalid CI configuration instead of silently turning a typo
 * into an unexpected load profile.
 */
function positiveNumber(name: string, fallback: number): number {
  const raw = __ENV[name];

  const value =
    raw === undefined || raw === ''
      ? fallback
      : Number(raw);

  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(
      `${name} must be a finite number greater than 0; got: ${raw}`,
    );
  }

  return value;
}

/**
 * Read a rate threshold constrained to the valid [0, 1] interval.
 *
 * k6 thresholds use rates as fractions, so `0.01` means 1%.
 */
function errorRate(name: string, fallback: number): number {
  const value = Number(__ENV[name] ?? fallback);

  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw new Error(
      `${name} must be a number between 0 and 1; got: ${__ENV[name]}`,
    );
  }

  return value;
}

const QPS = positiveNumber('QPS', DEFAULT_QPS);
const P95_THRESHOLD = positiveNumber(
  'P95_THRESHOLD',
  DEFAULT_P95_MS,
);

const ERROR_RATE_THRESHOLD = errorRate(
  'ERROR_RATE_THRESHOLD',
  DEFAULT_ERROR_RATE,
);

const PREALLOCATED_VUS = Number(
  __ENV.PREALLOCATED_VUS ?? DEFAULT_PREALLOCATED_VUS,
);

if (
  !Number.isInteger(PREALLOCATED_VUS) ||
  PREALLOCATED_VUS < 1
) {
  throw new Error(
    `PREALLOCATED_VUS must be an integer greater than 0; got: ${__ENV.PREALLOCATED_VUS}`,
  );
}

// Strip trailing slashes so URL construction below cannot accidentally produce
// `//api/...` when an operator supplies a URL ending in `/`.
const BASE_URL = (
  __ENV.BACKEND_CANARY_URL || 'http://backend:8080'
).replace(/\/+$/, '');

/**
 * One iteration performs exactly three HTTP requests:
 *   1. register
 *   2. list tasks
 *   3. create task
 *
 * Therefore a 50-request/sec target requires approximately
 * 50 / 3 = 16.67 iterations/sec.
 *
 * `constant-arrival-rate` controls iteration arrival rate, not VU count.
 * This is why the original script's `QPS -> ramping-vus target` mapping
 * was incorrect.
 */
const iterationsPerMinute = Math.max(
  1,
  Math.round(
    (QPS * 60) / REQUESTS_PER_ITERATION,
  ),
);

// Tell k6 which response statuses are expected for each HTTP request.
// Unexpected HTTP statuses then contribute to the built-in
// `http_req_failed` metric instead of being silently treated as transport success.
const expected201 = http.expectedStatuses(201);
const expected200 = http.expectedStatuses(200);

export const options = {
  // Keep bodies because functional checks inspect the registration response.
  discardResponseBodies: false,

  scenarios: {
    backend_load: {
      /**
       * Open-model arrival-rate executor:
       * the test attempts to start a controlled number of iterations per unit time,
       * independent of how long previous requests take.
       *
       * This is the correct semantic model when QPS is the desired load parameter.
       */
      executor: 'constant-arrival-rate',

      rate: iterationsPerMinute,
      timeUnit: '1m',

      // Make duration configurable from the pipeline while retaining
      // a safe default for local execution.
      duration: __ENV.DURATION || '2m',

      /**
       * k6 starts with this many reusable VUs available.
       *
       * If the system becomes slower, an arrival-rate scenario may require
       * additional VUs to preserve the requested arrival rate.
       */
      preAllocatedVUs: PREALLOCATED_VUS,

      // Give in-flight iterations a short period to finish at shutdown.
      gracefulStop: __ENV.GRACEFUL_STOP || '10s',
    },
  },

  thresholds: {
    // Performance SLO.
    http_req_duration: [`p(95)<${P95_THRESHOLD}`],

    // Transport/HTTP failure SLO.
    http_req_failed: [`rate<${ERROR_RATE_THRESHOLD}`],

    // Every iteration contains checks for the critical business path.
    checks: ['rate>0.99'],

    /**
     * If k6 cannot allocate enough VUs to maintain the requested arrival rate,
     * iterations are dropped. For this canary test that should be a hard failure,
     * because otherwise the test may generate less load than intended.
     */
    dropped_iterations: ['count==0'],
  },
};

export default function (): void {
  // Every iteration gets a unique account to prevent registration collisions.
  const identity =
    `loaduser_${Date.now()}_` +
    `${__VU}_${__ITER}_` +
    `${Math.random().toString(36).slice(2, 8)}`;

  const email = `${identity}@example.com`;

  const registerRes = http.post(
    `${BASE_URL}/api/v1/auth/register`,
    JSON.stringify({
      username: identity,
      email,
      password: PASSWORD,
    }),
    {
      headers: {
        'Content-Type': 'application/json',
      },

      // Expected business response from the application contract.
      responseCallback: expected201,

      // Tags make the resulting k6 metrics easier to analyze per endpoint.
      tags: {
        endpoint: 'auth_register',
      },
    },
  );

  const registered = check(registerRes, {
    'register status is 201': (response) =>
      response.status === 201,
  });

  // No useful authenticated work can happen without a successful registration.
  if (!registered) {
    return;
  }

  let payload: JsonObject;

  try {
    const parsed = registerRes.json();

    // Defensively validate that the decoded JSON is an object before accessing
    // a property. A malformed response must fail the iteration rather than
    // causing an unsafe cast/runtime error.
    payload =
      parsed !== null &&
      typeof parsed === 'object'
        ? (parsed as JsonObject)
        : {};
  } catch {
    payload = {};
  }

  const token =
    typeof payload.token === 'string'
      ? payload.token
      : undefined;

  check(registerRes, {
    'register response contains a token': () =>
      Boolean(token),
  });

  // Registration may succeed while returning an unexpected response shape.
  // Treat that as an iteration failure instead of sending `Bearer undefined`.
  if (!token) {
    return;
  }

  const authHeaders = {
    Authorization: `Bearer ${token}`,
  };

  const tasksRes = http.get(
    `${BASE_URL}/api/v1/tasks`,
    {
      headers: authHeaders,
      responseCallback: expected200,
      tags: {
        endpoint: 'tasks_list',
      },
    },
  );

  check(tasksRes, {
    'tasks status is 200': (response) =>
      response.status === 200,
  });

  const createTaskRes = http.post(
    `${BASE_URL}/api/v1/tasks`,
    JSON.stringify({
      title: `Load Test Task ${__VU}-${__ITER}`,
      description: 'Created by k6 canary validation',
    }),
    {
      headers: {
        'Content-Type': 'application/json',
        ...authHeaders,
      },

      responseCallback: expected201,

      tags: {
        endpoint: 'tasks_create',
      },
    },
  );

  check(createTaskRes, {
    'create task status is 201': (response) =>
      response.status === 201,
  });

  // Deliberately no `sleep()` here.
  //
  // In an arrival-rate scenario, sleeping would not represent "realistic user
  // think time" in the same way it does in a closed VU model; the executor itself
  // determines when iterations should arrive. Removing the sleep keeps the
  // configured throughput model explicit and predictable.
}
