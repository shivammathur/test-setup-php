import http from 'k6/http';
import { check } from 'k6';

export const options = {
  thresholds: {
    checks: ['rate>0.99'],
    http_req_failed: ['rate<0.01'],
  },
};

const target = __ENV.K6_TARGET || 'http://127.0.0.1:8091/';
const needle = __ENV.K6_NEEDLE || 'CakePHP benchmark';

export default function () {
  const res = http.get(target);

  check(res, {
    'is status 200': (r) => r.status === 200,
    'contains expected body text': (r) => r.body.includes(needle),
  });
}
