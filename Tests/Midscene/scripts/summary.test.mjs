import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { renderSummary, evidenceFor } from './summary.mjs';
test('Rome layout places attention first and collapses passes with exact screenshot links and duration', () => {
  const markdown = renderSummary({ product: 'Search', models: ['fixture-model (fixture-family)'], runUrl: 'https://github.test/actions/runs/12', nativeReportUrl: 'https://reports.test/native.html', cases: [
    { id: 'pass', title: 'Passed case', shard: 'import', status: 'passed', durationMs: 61000 },
    { id: 'fail', title: 'Failed | <case>', shard: 'navigation', status: 'failed', reason: 'Visible result absent', durationMs: 2500, reportUrl: 'https://reports.test/framework/index.html#runner-step=actual%3Astep', screenshotUrl: 'https://reports.test/screenshots/fail.png' },
    { id: 'missing', title: 'Missing case', shard: 'import', status: 'missing' },
  ] });
  assert.ok(markdown.indexOf('Failed \\| &lt;case&gt;') < markdown.indexOf('<details>'));
  assert.ok(markdown.indexOf('Missing case') < markdown.indexOf('<details>'));
  assert.ok(markdown.indexOf('Passed case') > markdown.indexOf('<details>'));
  assert.match(markdown, /Shard \| Case \| Report \| Screenshot \| Status \/ reason \| Duration/);
  assert.match(markdown, /width="160"/);
  assert.match(markdown, /href="https:\/\/reports.test\/framework\/index.html#runner-step=actual%3Astep"/);
  assert.match(markdown, /1m 1s/);
  assert.match(markdown, /fixture-model \(fixture-family\)/);
  assert.match(markdown, /actions\/runs\/12#artifacts/);
});
test('framework evidence selects the failed step screenshot; standalone exports get no invented runner-step', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'search-summary-'));
  try {
    const screenshot = path.join(root, 'screenshots/failure.png');
    await mkdir(path.dirname(screenshot)); await writeFile(screenshot, 'fixture');
    const file = path.join(root, 'index.html');
    const steps = [
      { id: 'recorded-first', status: 'success', agentDetails: [{ executionId: 'before' }] },
      { id: 'recorded-failure', status: 'failed', error: { message: 'Visible result absent' }, agentDetails: [{ executionId: 'failed' }] },
      { id: 'recorded-last', status: 'success', agentDetails: [{ executionId: 'after' }] },
    ];
    const run = { projects: [{ documents: [{ cases: [{ name: 'case', status: 'failed', attempts: [{ durationMs: 1200, steps }] }] }] }] };
    const dump = { executions: [{ id: 'failed', tasks: [{ uiContext: { screenshot: { path: './screenshots/failure.png' } } }] }] };
    await writeFile(file, `<script type="midscene_test_run_dump">${JSON.stringify(run)}</script><script type="midscene_web_dump">${JSON.stringify(dump)}</script>`);
    const evidence = await evidenceFor(file, 'case', false, root);
    assert.equal(evidence.stepId, 'recorded-failure');
    assert.equal(evidence.screenshot, screenshot);
    assert.equal(evidence.reason, 'Visible result absent');
    assert.equal(evidence.durationMs, 1200);
    await writeFile(file, `<script type="midscene_web_dump">${JSON.stringify(dump)}</script>`);
    assert.equal(await evidenceFor(file, 'case', false, root), null);
  } finally { await rm(root, { recursive: true, force: true }); }
});
test('producer and merge failures remain attention items even with passed case records', () => {
  const markdown = renderSummary({ cases: [{ title: 'Case', shard: 'import', status: 'passed' }], producerResult: 'failure', issues: ['Native merge unavailable'] });
  assert.match(markdown, /failure captured/);
  assert.match(markdown, /2 need attention/);
  assert.match(markdown, /Native merge unavailable/);
  assert.match(markdown, /Workflow failure/);
});
test('empty inventories cannot render an all-passed message', () => {
  const markdown = renderSummary({ cases: [] });
  assert.match(markdown, /failure captured/);
  assert.match(markdown, /No cases were reported/);
  assert.doesNotMatch(markdown, /All 0 cases passed/);
});
test('results remain available without Pages and publication failure does not erase passed cases', () => {
  for (const publicationResult of ['skipped', 'failure', 'cancelled']) {
    const markdown = renderSummary({ cases: [{ title: 'Case', shard: 'import', status: 'passed' }], runUrl: 'https://github.test/repo/actions/runs/12', nativeReportAvailable: true, publicationResult });
    assert.match(markdown, /1 passed/);
    assert.match(markdown, /Native Midscene Test report included in the artifact/);
    assert.ok(markdown.includes(`Pages publication: **${publicationResult}**`));
    assert.match(markdown, /runs\/12#artifacts/);
    assert.doesNotMatch(markdown, /https:\/\/.*github.io/);
  }
});
test('rebuild Summary links source artifacts and reports aggregation failure separately', () => {
  const markdown = renderSummary({ cases: [], runUrl: 'https://github.test/repo/actions/runs/12', sourceRunId: '10', reportResult: 'failure', publicationResult: 'skipped' });
  assert.match(markdown, /runs\/10#artifacts/);
  assert.match(markdown, /no new model calls/);
  assert.match(markdown, /Report aggregation: \*\*failure\*\*/);
});
test('unpublished results contain counts and artifact links, never empty case tables or screenshot placeholders', () => {
  const markdown = renderSummary({ runUrl: 'https://github.test/runs/12', cases: [{ title: 'Passed', shard: 'import', status: 'passed' }, { title: 'Missing case', shard: 'navigation', status: 'missing', reason: 'No result recorded' }], publicationResult: 'pending' });
  assert.match(markdown, /2 total · 1 passed/);
  assert.match(markdown, /runs\/12#artifacts/);
  assert.match(markdown, /Missing case: Missing/);
  assert.doesNotMatch(markdown, /\| Shard|<details>|<img|\[Report\]/);
});
test('published case tables have an explicit report link and clickable thumbnail', () => {
  const markdown = renderSummary({ cases: [{ title: 'Case', shard: 'import', status: 'passed', reportUrl: 'https://reports.test/case.html#runner-step=step', screenshotUrl: 'https://reports.test/step.jpeg' }] });
  assert.match(markdown, /### Shard results/);
  assert.match(markdown, /\| Case \| Report \| Screenshot \|/);
  assert.match(markdown, /\[Report\]\(https:\/\/reports.test\/case.html#runner-step=step\)/);
  assert.match(markdown, /<img src="https:\/\/reports.test\/step.jpeg"/);
});
