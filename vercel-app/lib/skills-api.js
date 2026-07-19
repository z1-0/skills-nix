import { getVercelOidcToken } from '@vercel/oidc';

export const SKILLS_SH_API = 'https://skills.sh/api/v1';
export const REQUEST_TIMEOUT_MS = 30000;

export async function fetchSkills(path, query = '', timeoutMs = REQUEST_TIMEOUT_MS) {
  const token = await getVercelOidcToken();
  const url = `${SKILLS_SH_API}/${path}${query ? `?${query}` : ''}`;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${token}` },
      signal: controller.signal,
    });
    return res;
  } finally {
    clearTimeout(timeout);
  }
}
