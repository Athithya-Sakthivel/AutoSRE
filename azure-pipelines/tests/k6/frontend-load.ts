```typescript
import http from 'k6/http';
import { check } from 'k6';

const DEFAULT_QPS = 30;
const DEFAULT_P95_MS = 300;
const DEFAULT_ERROR_RATE = 0.02;
const DEFAULT_PREALLOCATED_VUS = 10;
const REQUESTS_PER_ITERATION = 1;

function positiveNumber(name: string, fallback: number): number {
  const raw = __ENV[name];
  const value = raw === undefined || raw === '' ? fallback : Number(raw);

  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(
      `${name} must be a finite number greater than 0; got: ${raw}`,
    );
  }

  return value;
}

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
const P95_THRESHOLD = positiveNumber('P95_THRESHOLD', DEFAULT_P95_MS);
const ERROR_RATE_THRESHOLD = errorRate(
  'ERROR_RATE_THRESHOLD',
  DEFAULT_ERROR_RATE,
);

const PREALLOCATED_VUS = Number(
  __ENV.PREALLOCATED_VUS ?? DEFAULT_PREALLOCATED_VUS,
);

if (!Number.isInteger(PREALLOCATED_VUS) || PREALLOCATED_VUS < 1) {
  throw new Error(
    `PREALLOCATED_VUS must be an integer greater than 0; got: ${__ENV.PREALLOCATED_VUS}`,
  );
}

const BASE_URL = (
  __ENV.FRONTEND_CANARY_URL || 'http://frontend:8080'
).replace(/\/+$/, '');

const iterationsPerMinute = Math.max(
  1,
  Math.round((QPS * 60) / REQUESTS_PER_ITERATION),
);

const expected200 = http.expectedStatuses(200);

export const options = {
  discardResponseBodies: false,

  scenarios: {
    frontend_load: {
      executor: 'constant-arrival-rate',
      rate: iterationsPerMinute,
      timeUnit: '1m',
      duration: __ENV.DURATION || '2m',
      preAllocatedVUs: PREALLOCATED_VUS,
      gracefulStop: __ENV.GRACEFUL_STOP || '10s',
    },
  },

  thresholds: {
    http_req_duration: [`p(95)<${P95_THRESHOLD}`],
    http_req_failed: [`rate<${ERROR_RATE_THRESHOLD}`],
    checks: ['rate>0.99'],
    dropped_iterations: ['count==0'],
  },
};

export default function (): void {
  const response = http.get(`${BASE_URL}/`, {
    responseCallback: expected200,
    tags: {
      endpoint: 'frontend_root',
    },
  });

  check(response, {
    'root status is 200': (res) => res.status === 200,
    'root contains Task API title': (res) =>
      typeof res.body === 'string' && res.body.includes('Task API'),
  });
}
```
