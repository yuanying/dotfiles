import assert from 'node:assert/strict';
import { test } from 'node:test';
import codexWeekly, { weeklyStatus } from '../pi/extensions/codex-weekly.ts';

test('formats the weekly Codex window, without mistaking the 5h window for weekly', () => {
  assert.equal(weeklyStatus({ rate_limit: { primary_window: { used_percent: 90 }, secondary_window: { used_percent: 27 } } }), 'Weekly: 27% used');
  assert.equal(weeklyStatus({ rate_limit: { primary_window: { used_percent: 90 } } }), undefined);
});

test('shows usage for Codex only and clears it when changing provider', async () => {
  const handlers = {};
  codexWeekly({ on(name, handler) { handlers[name] = handler; } });
  const statuses = [];
  const token = `a.${Buffer.from(JSON.stringify({ 'https://api.openai.com/auth': { chatgpt_account_id: 'account' } })).toString('base64url')}.c`;
  const ctx = {
    mode: 'tui', model: { provider: 'openai-codex' },
    ui: { setStatus(key, value) { statuses.push([key, value]); } },
    modelRegistry: { async getApiKeyAndHeaders() { return { ok: true, apiKey: token }; } },
  };
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    assert.equal(url, 'https://chatgpt.com/backend-api/codex/usage');
    assert.equal(options.headers['chatgpt-account-id'], 'account');
    assert.equal(options.headers.Authorization, `Bearer ${token}`);
    return { ok: true, async json() { return { rate_limit: { secondary_window: { used_percent: 42 } } }; } };
  };
  try {
    await handlers.session_start({}, ctx);
    assert.deepEqual(statuses.at(-1), ['codex-weekly', 'Weekly: 42% used']);
    ctx.model = { provider: 'anthropic' };
    await handlers.model_select({}, ctx);
    assert.deepEqual(statuses.at(-1), ['codex-weekly', undefined]);
  } finally {
    handlers.session_shutdown({}, ctx);
    globalThis.fetch = originalFetch;
  }
});
