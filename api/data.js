// GET    /api/data            - all PCs (first, previous, latest report). Needs DASHBOARD_PASSWORD.
// DELETE /api/data?pc=NAME    - remove one PC from the dashboard.
import { PC_NAME, redis, storeReady, parse, passwordOk, noStore } from './_store.js';

export default async function handler(req, res) {
  noStore(res);
  if (!passwordOk(req)) {
    await new Promise((r) => setTimeout(r, 800));
    res.status(401).json({ error: 'wrong password' });
    return;
  }
  if (!storeReady()) { res.status(503).json({ error: 'dashboard storage is not set up yet' }); return; }
  try {
    if (req.method === 'DELETE') {
      const pc = String((req.query && req.query.pc) || '').toUpperCase();
      if (!PC_NAME.test(pc)) { res.status(400).json({ error: 'invalid pc name' }); return; }
      const k = 'pc:' + pc;
      await redis([['DEL', k + ':first', k + ':previous', k + ':latest'], ['SREM', 'pcs', pc]]);
      res.status(200).json({ ok: true });
      return;
    }
    if (req.method !== 'GET') { res.status(405).json({ error: 'GET or DELETE only' }); return; }

    const [names] = await redis([['SMEMBERS', 'pcs']]);
    const list = (names || []).filter((n) => PC_NAME.test(n)).sort();
    let pcs = [];
    if (list.length) {
      const keys = [];
      for (const n of list) keys.push('pc:' + n + ':first', 'pc:' + n + ':previous', 'pc:' + n + ':latest');
      const [values] = await redis([['MGET', ...keys]]);
      pcs = list.map((n, i) => ({
        pc: n,
        first: parse(values[i * 3]),
        previous: parse(values[i * 3 + 1]),
        latest: parse(values[i * 3 + 2]),
      }));
    }
    res.status(200).json({ generated: new Date().toISOString(), pcs });
  } catch (e) {
    res.status(500).json({ error: 'store read failed' });
  }
}
