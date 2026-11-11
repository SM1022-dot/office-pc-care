// POST /api/report  - each office PC sends one report per day (Auto Care) or on demand (menu 9).
// Keys: pc:<NAME>:first (first ever), pc:<NAME>:previous (last different day), pc:<NAME>:latest; set "pcs".
import { PC_NAME, redis, storeReady, noStore } from './_store.js';

const MAX_BYTES = 400000;

export default async function handler(req, res) {
  noStore(res);
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  let body = req.body;
  try {
    if (typeof body === 'string') body = JSON.parse(body);
  } catch { res.status(400).json({ error: 'invalid JSON' }); return; }
  if (!body || typeof body !== 'object') { res.status(400).json({ error: 'missing report' }); return; }
  const text = JSON.stringify(body);
  if (text.length > MAX_BYTES) { res.status(413).json({ error: 'report too large' }); return; }
  const pc = String(body.pc || '');
  if (!PC_NAME.test(pc)) { res.status(400).json({ error: 'invalid pc name' }); return; }
  if (body.kind !== 'office-pc-care-report') { res.status(400).json({ error: 'unknown report kind' }); return; }
  if (!storeReady()) { res.status(503).json({ error: 'dashboard storage is not set up yet' }); return; }

  body.received = new Date().toISOString();
  const key = 'pc:' + pc.toUpperCase();
  const json = JSON.stringify(body);
  try {
    const [latestText] = await redis([['GET', key + ':latest']]);
    const cmds = [['SET', key + ':first', latestText || json, 'NX']];
    if (latestText) {
      try {
        const latest = JSON.parse(latestText);
        if (latest.reportDate && latest.reportDate !== body.reportDate) cmds.push(['SET', key + ':previous', latestText]);
      } catch {}
    }
    cmds.push(['SET', key + ':latest', json], ['SADD', 'pcs', pc.toUpperCase()]);
    await redis(cmds);
    res.status(200).json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: 'store failed' });
  }
}
