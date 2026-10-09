import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { assemble } from './report.mjs';
import { collect } from './collect.mjs';
async function fixture(fn) {
  const root = await mkdtemp(path.join(tmpdir(), 'search-report-'));
  try {
    const dir = path.join(root, 'shard'); await mkdir(dir);
    const cases = await collect();
    for (const c of cases) {
      await writeFile(path.join(dir, `${c.id}.html`), 'native placeholder');
      await writeFile(path.join(dir, `${c.id}.png`), 'png placeholder');
    }
    await writeFile(path.join(dir, 'results.json'), JSON.stringify(cases.map(c => ({ id: c.id, status: 'passed', report: `${c.id}.html`, screenshot: `${c.id}.png` }))));
    await fn(root, dir);
  } finally { await rm(root, { recursive: true, force: true }); }
}
const opts = root => ({ directory: root, baseUrl: 'https://example.test/runs/123/2', summary: path.join(root, 'summary.md') });
const merge = async ({ outputDir }) => {
  const mergedReportPath = path.join(outputDir, 'native.html');
  await mkdir(path.dirname(mergedReportPath), { recursive: true }); await writeFile(mergedReportPath, 'merged');
  return { mergedReportPath };
};
test('complete table links to exact reports and screenshots', () => fixture(async root => {
  assert.equal(await assemble({ ...opts(root), merge }), true);
  const summary = await readFile(opts(root).summary, 'utf8');
  assert.match(summary, /https:\/\/example.test\/runs\/123\/2\/shard\/bookmarks-import.html/);
  assert.match(summary, /width="160"/);
  assert.match(summary, /<summary>Appendix: passed cases \(3\)<\/summary>/);
}));
test('failed merge keeps per-case files and deletes partial output', () => fixture(async (root, dir) => {
  assert.equal(await assemble({ ...opts(root), merge: async args => { await merge(args); throw new Error('merge failed'); } }), false);
  await access(path.join(dir, 'bookmarks-import.html'));
  await assert.rejects(access(path.join(root, 'native.html')));
  assert.match(await readFile(opts(root).summary, 'utf8'), /Individual reports remain/);
}));
test('incomplete rerun removes old merge and reports missing cases', () => fixture(async (root, dir) => {
  await assemble({ ...opts(root), merge });
  await writeFile(path.join(dir, 'results.json'), '[]');
  for (const c of await collect()) {
    await rm(path.join(dir, `${c.id}.html`));
    await rm(path.join(dir, `${c.id}.png`));
  }
  assert.equal(await assemble({ ...opts(root), merge }), false);
  await assert.rejects(access(path.join(root, 'native.html')));
  assert.match(await readFile(opts(root).summary, 'utf8'), /Missing/);
}));
test('unknown shards fail rather than silently running nothing', async () => {
  await assert.rejects(collect('typo'), /No cases/);
});
test('missing metadata still links retained reports without reporting false passes', () => fixture(async (root, dir) => {
  await rm(path.join(dir, 'results.json'));
  assert.equal(await assemble({ ...opts(root), merge }), false);
  await access(path.join(root, 'native.html'));
  const summary = await readFile(opts(root).summary, 'utf8');
  assert.match(summary, /shard\/bookmarks-import.html/);
  assert.match(summary, /0 passed/);
  assert.match(summary, /Missing/);
}));
test('SDK auto-report copies do not create ambiguous case artifacts', () => fixture(async (root, dir) => {
  await mkdir(path.join(dir, 'report'));
  await writeFile(path.join(dir, 'report/bookmarks-import.html'), 'SDK automatic report');
  assert.equal(await assemble({ ...opts(root), merge }), true);
}));
test('complete native framework inventories take priority over standalone reports when merging', () => fixture(async (root, dir) => {
  const framework = path.join(dir, 'framework/native-run/index.html');
  await mkdir(path.dirname(framework), { recursive: true });
  const cases = (await collect()).map(c => ({ name: c.id, status: 'success', attempts: [{ steps: [] }] }));
  await writeFile(framework, `<script type="midscene_test_run_dump">${JSON.stringify({ projects: [{ documents: [{ cases }] }] })}</script>`);
  let selected;
  assert.equal(await assemble({ ...opts(root), merge: async args => {
    selected = args.htmlPaths;
    return merge(args);
  } }), true);
  assert.deepEqual(selected, [framework]);
  await access(path.join(dir, 'bookmarks-import.html'));
  await writeFile(framework, `<script type="midscene_test_run_dump">${JSON.stringify({ projects: [{ documents: [{ cases: cases.slice(0, 1) }] }] })}</script>`);
  assert.equal(await assemble({ ...opts(root), merge: async args => {
    selected = args.htmlPaths;
    return merge(args);
  } }), true);
  assert.deepEqual(new Set(selected), new Set(cases.map(c => path.join(dir, `${c.name}.html`))));
}));
test('shard summaries use their manifest and preserve existing report files', () => fixture(async (root, dir) => {
  const cases = await collect('navigation');
  await writeFile(path.join(dir, 'results.json'), JSON.stringify(cases.map(c => ({ id: c.id, status: 'passed' }))));
  await writeFile(path.join(root, 'native.html'), 'retained');
  assert.equal(await assemble({ ...opts(root), shard: 'navigation', mergeReports: false, merge: () => { throw new Error('must not merge'); } }), true);
  assert.equal(await readFile(path.join(root, 'native.html'), 'utf8'), 'retained');
  const summary = await readFile(opts(root).summary, 'utf8');
  assert.match(summary, /1 passed/);
  assert.doesNotMatch(summary, /Import exported bookmarks/);
}));
test('SDK native standalone HTML merges without a model or desktop', () => fixture(async (root, dir) => {
  const { Agent, mergeReportFiles } = await import('@midscene/core');
  const agent = new Agent({ interfaceType: 'static', actionSpace: () => [], destroy: async () => {} }, { generateReport: false });
  try {
    // Record a synthetic log using the SDK rather than inventing its HTML schema.
    await agent.recordToReport('Synthetic harness entry', { content: 'No model call', screenshots: [{ base64: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aC9sAAAAASUVORK5CYII=' }] });
    const html = agent.reportHTMLString({ inlineScreenshots: true });
    for (const c of await collect()) await writeFile(path.join(dir, `${c.id}.html`), html);
    assert.equal(await assemble({ ...opts(root), merge: mergeReportFiles }), true);
    const merged = await readFile(path.join(root, 'native.html'), 'utf8');
    assert.match(merged, /Synthetic harness entry/);
  } finally { await agent.destroy(); }
}));
test('read-only publication Summary preserves the combined native report and uses the deployed URL', () => fixture(async root => {
  assert.equal(await assemble({ ...opts(root), baseUrl: '', merge }), true);
  assert.match(await readFile(opts(root).summary, 'utf8'), /Native Midscene Test report included/);
  assert.equal(await assemble({ ...opts(root), mergeReports: false, publicationResult: 'success', merge: () => { throw new Error('must not merge'); } }), true);
  assert.match(await readFile(opts(root).summary, 'utf8'), /https:\/\/example.test\/runs\/123\/2\/native.html/);
  assert.equal(await readFile(path.join(root, 'native.html'), 'utf8'), 'merged');
}));
