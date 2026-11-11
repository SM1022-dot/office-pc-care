// GET    /api/data            - all PCs (first, previous, latest report, IT label). Needs DASHBOARD_PASSWORD.
// POST   /api/data?pc=NAME    - save IT label for one PC: {"label":"Rakib - Desk 12","team":"BD"}
// DELETE /api/data?pc=NAME    - remove one PC from the dashboard.
import { PC_NAME, redis, storeReady, parse, passwordOk, noStore } from './_store.js';

function clean(v, max) { return String(v == null ? '' : v).replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, max); }

export default async function handler(req, res) {
  noStore(res);
  if (!passwordOk(req)) {
    await new Promise((r) => setTimeout(r, 800));
    res.status(401).json({ error: 'wrong password' });
    return;
  }
  if (!storeReady()) { res.status(503).json({ error: 'dashboard storage is not set up yet' }); return; }
  try {
    const pcParam = String((req.query && req.query.pc) || '').toUpperCase();
    if (req.method === 'DELETE') {
      if (!PC_NAME.test(pcParam)) { res.status(400).json({ error: 'invalid pc name' }); return; }
      const k = 'pc:' + pcParam;
      await redis([['DEL', k + ':first', k + ':previous', k + ':latest', k + ':label'], ['SREM', 'pcs', pcParam]]);
      res.status(200).json({ ok: true });
      return;
    }
    if (req.method === 'POST') {
      if (!PC_NAME.test(pcParam)) { res.status(400).json({ error: 'invalid pc name' }); return; }
      let body = req.body;
      if (typeof body === 'string') { try { body = JSON.parse(body); } catch { body = {}; } }
      const label = { label: clean(body && body.label, 80), team: clean(body && body.team, 20), note: clean(body && body.note, 300), updated: new Date().toISOString() };
      await redis([['SET', 'pc:' + pcParam + ':label', JSON.stringify(label)]]);
      res.status(200).json({ ok: true, label });
      return;
    }
    if (req.method !== 'GET') { res.status(405).json({ error: 'GET, POST or DELETE only' }); return; }

    const [names] = await redis([['SMEMBERS', 'pcs']]);
    const list = (names || []).filter((n) => PC_NAME.test(n)).sort();
    let pcs = [];
    if (list.length) {
      const keys = [];
      for (const n of list) keys.push('pc:' + n + ':first', 'pc:' + n + ':previous', 'pc:' + n + ':latest', 'pc:' + n + ':label');
      const [values] = await redis([['MGET', ...keys]]);
      pcs = list.map((n, i) => ({
        pc: n,
        first: parse(values[i * 4]),
        previous: parse(values[i * 4 + 1]),
        latest: parse(values[i * 4 + 2]),
        label: parse(values[i * 4 + 3]) || {},
      }));
    }
    res.status(200).json({ generated: new Date().toISOString(), pcs });
  } catch (e) {
    res.status(500).json({ error: 'store read failed' });
  }
}
