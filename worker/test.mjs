// Local contract tests only: env.AI is a fixture; no cloud requests or credentials.
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const source = await readFile(new URL('./index.js', import.meta.url), 'utf8');
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const env = { WORKER_SECRET: 'local-test-only', AI: { run: async (model, body) => {
  assert.equal(model, '@cf/qwen/qwen3-30b-a3b-fp8');
  assert.equal(body.stream, false);
  return { choices: [{ message: { content: '你好 hello' }, finish_reason: 'stop' }] };
} } };
const req = (body, token = 'local-test-only') => new Request('https://example.invalid', {
  method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(body),
});
assert.equal((await worker.fetch(req({}, 'wrong'), env)).status, 401);
assert.equal((await worker.fetch(req({}), env)).status, 400);
const response = await worker.fetch(req({ messages: [
  { role: 'system', content: 'Edit dictation' }, { role: 'user', content: '你好 hello' },
] }), env);
assert.equal(response.status, 200);
assert.deepEqual(await response.json(), { response: '你好 hello' });
assert.equal((await worker.fetch(req({ text: 'x'.repeat(65000) }), env)).status, 413);
console.log('Worker contract tests passed (authentication, validation, Qwen response, size limit).');
