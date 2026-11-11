// Shared helpers for the PC report store: Upstash Redis over its REST API (no SDK needed).
// Vercel's Upstash integration adds KV_REST_API_URL / KV_REST_API_TOKEN (or UPSTASH_REDIS_REST_*).
import { createHash, timingSafeEqual } from 'node:crypto';

export const PC_NAME = /^[A-Za-z0-9._-]{1,40}$/;

function config() {
  const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL || '';
  const token = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN || '';
  return url && token ? { url: url.replace(/\/$/, ''), token } : null;
}

export function storeReady() { return !!config(); }

// Runs several Redis commands in one request. Returns the list of results.
export async function redis(commands) {
  const c = config();
  if (!c) throw new Error('store not configured');
  const r = await fetch(c.url + '/pipeline', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + c.token, 'Content-Type': 'application/json' },
    body: JSON.stringify(commands),
  });
  if (!r.ok) throw new Error('store error ' + r.status);
  const out = await r.json();
  return out.map((x) => {
    if (x.error) throw new Error('store error: ' + x.error);
    return x.result;
  });
}

export function parse(text) {
  if (!text) return null;
  try { return JSON.parse(text); } catch { return null; }
}

export function passwordOk(req) {
  const expected = process.env.DASHBOARD_PASSWORD || '';
  const header = String(req.headers.authorization || '');
  const given = header.startsWith('Bearer ') ? header.slice(7) : '';
  if (!expected || !given) return false;
  const a = createHash('sha256').update(given).digest();
  const b = createHash('sha256').update(expected).digest();
  return timingSafeEqual(a, b);
}

export function noStore(res) {
  res.setHeader('Cache-Control', 'no-store, max-age=0');
  res.setHeader('X-Robots-Tag', 'noindex, nofollow');
}
