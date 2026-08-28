import http from "k6/http";
import { check, sleep } from "k6";

const baseUrl = (__ENV.K6_BASE_URL || "").replace(/\/+$/, "");
const endpoint = __ENV.K6_ENDPOINT || "/actuator/health/readiness";

export const options = {
  vus: 5,
  duration: "30s",
  discardResponseBodies: true,
  noConnectionReuse: false,
  thresholds: {
    checks: ["rate==1"],
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<500"],
  },
};

export default function () {
  if (!baseUrl) {
    throw new Error("K6_BASE_URL is required");
  }

  const response = http.get(`${baseUrl}${endpoint}`, {
    timeout: "10s",
    tags: {
      test: "backend-canary-readiness",
    },
  });

  check(response, {
    "health endpoint returns 2xx": (res) =>
      res.status >= 200 && res.status < 300,
  });

  sleep(1);
}
