import { fetchSkills } from '../lib/skills-api.js';
import { withGet } from '../lib/handler.js';

function parseRawQuery(url) {
  const idx = url.indexOf('?');
  if (idx === -1) return '';
  return url.slice(idx + 1);
}

function validatePath(segments) {
  for (const seg of segments) {
    if (seg === '..' || seg.includes('/') || seg === '' || seg.startsWith('.')) {
      return false;
    }
  }
  return true;
}

function forwardHeaders(res, upstreamRes, names) {
  for (const name of names) {
    const val = upstreamRes.headers.get(name);
    if (val) res.setHeader(name, val);
  }
}

export default withGet(async (req, res) => {
  const raw = req.query.path;
  if (!raw || raw.length === 0) {
    return res.status(400).json({ error: 'Path is required. Usage: /api/skills' });
  }
  const segments = (Array.isArray(raw) ? raw : [raw]).flatMap(s => s.split('/')).filter(Boolean);

  if (!validatePath(segments)) {
    return res.status(400).json({ error: 'Invalid path segments' });
  }

  const path = segments.join('/');
  const qs = parseRawQuery(req.url);

  try {
    const upstreamRes = await fetchSkills(path, qs);

    forwardHeaders(res, upstreamRes, [
      'X-RateLimit-Limit',
      'X-RateLimit-Remaining',
      'X-RateLimit-Reset',
    ]);

    const body = upstreamRes.status === 204 ? null : await upstreamRes.json();
    res.status(upstreamRes.status).json(body);
  } catch (error) {
    if (error.name === 'AbortError') {
      return res.status(504).json({ error: 'Upstream request timed out' });
    }
    throw error;
  }
});
