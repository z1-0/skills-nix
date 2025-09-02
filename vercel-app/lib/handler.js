export function withGet(handler) {
  return async (req, res) => {
    if (req.method !== 'GET') {
      return res.status(405).json({ error: 'Method not allowed' });
    }
    try {
      await handler(req, res);
    } catch (error) {
      console.error('Handler error:', error);
      res.status(500).json({ error: error.message || 'Internal error' });
    }
  };
}
