import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
const workflow = await readFile(new URL('../../../.github/workflows/midscene.yml', import.meta.url), 'utf8');
function job(name) {
  const start = workflow.indexOf(`\n  ${name}:\n`);
  assert.ok(start >= 0, `Missing job ${name}`);
  const end = workflow.slice(start + 1).search(/\n  [\w-]+:\n/);
  return workflow.slice(start, end < 0 ? undefined : start + 1 + end);
}
function runs(name, changes = {}) {
  const expression = job(name).match(/^    if: >-\n((?:      .+\n)+)/m)[1].replace(/needs\.([\w-]+)\./g, 'needs["$1"].').replace(/outputs\.([\w-]+)/g, 'outputs["$1"]');
  const context = { github: { repository: 'driceroland/Search', ref: 'refs/heads/main', event_name: 'push' }, inputs: { report_source_run_id: '', publish_pages: true }, vars: { MIDSCENE_DESKTOP_ENABLED: 'true', MIDSCENE_PUBLISH_REPO: '' }, needs: { validation: { outputs: { 'upstream-repository': 'driceroland/Search' } }, visual: { result: 'success' }, reports: { result: 'success', outputs: { 'report-artifact-name': 'midscene-combined-1' } }, 'prepare-pages': { result: 'success', outputs: { 'pages-artifact-name': 'pages-1' } }, 'deploy-report': { result: 'success' } }, ...changes };
  return Boolean(Function('github', 'inputs', 'vars', 'needs', 'always', 'cancelled', `return (${expression});`)(context.github, context.inputs, context.vars, context.needs, () => true, () => context.cancelled ?? false));
}
test('PR code never receives model credentials or publication permissions', () => {
  for (const name of ['build', 'visual', 'reports', 'prepare-pages', 'available-results', 'report-results']) assert.equal(runs(name, { github: { repository: 'driceroland/Search', ref: 'refs/pull/1/merge', event_name: 'pull_request' } }), false);
});
test('models require upstream main or explicit fork dispatch; configuration fails closed', () => {
  assert.equal(runs('visual'), true);
  for (const [repository, event_name, ref, expected] of [['driceroland/Search', 'push', 'refs/heads/topic', false], ['driceroland/Search', 'workflow_dispatch', 'refs/tags/main', false], ['quanru/Search', 'push', 'refs/heads/main', false], ['quanru/Search', 'workflow_dispatch', 'refs/heads/topic', true]]) assert.equal(runs('visual', { github: { repository, event_name, ref } }), expected);
  assert.equal(runs('visual', { needs: { validation: { outputs: { 'upstream-repository': '' } } } }), false);
});
test('report rebuild skips models but retains aggregation and independent results', () => {
  const inputs = { report_source_run_id: '12', publish_pages: false };
  assert.equal(runs('visual', { inputs }), false);
  for (const name of ['reports', 'available-results', 'report-results']) assert.equal(runs(name, { inputs }), true);
  assert.equal(runs('prepare-pages', { inputs, github: { repository: 'driceroland/Search', ref: 'refs/heads/main', event_name: 'workflow_dispatch' } }), false);
});
test('fork Pages requires manual dispatch and an exact repository match', () => {
  const github = { repository: 'quanru/Search', ref: 'refs/heads/topic', event_name: 'workflow_dispatch' };
  assert.equal(runs('prepare-pages', { github }), false);
  assert.equal(runs('prepare-pages', { github, vars: { MIDSCENE_PUBLISH_REPO: 'quanru/Search' } }), true);
  assert.equal(runs('prepare-pages', { github: { ...github, event_name: 'push' }, vars: { MIDSCENE_PUBLISH_REPO: 'quanru/Search' } }), false);
});
test('publication failure or approval cannot block the earlier read-only Summary', () => {
  assert.match(job('available-results'), /needs: \[visual, reports\]/);
  assert.doesNotMatch(job('available-results'), /environment:|pages: write|id-token: write|needs:.*deploy/);
  assert.doesNotMatch(job('reports'), /environment:|pages: write|configure-pages/);
  assert.doesNotMatch(job('report-results'), /pages: write|id-token: write/);
  assert.match(job('report-results'), /needs.deploy-report.result == 'success' && needs.deploy-report.outputs.page-url/);
});
test('partial reports are uploaded before completeness becomes a failure', () => {
  assert.ok(job('reports').indexOf('id: upload-report') < job('reports').indexOf('Require complete native reports'));
  assert.match(job('reports'), /include-hidden-files: true/);
  assert.match(job('reports'), /steps.source-run.outputs.source_attempt \|\| github.run_attempt/);
  assert.match(job('visual'), /name: midscene-shard-\$\{\{ matrix.shard \}\}-\$\{\{ github.run_attempt \}\}/);
});
test('optional publication never changes repository Pages settings', () => {
  assert.match(job('prepare-pages'), /enablement: false/);
  assert.match(job('prepare-pages'), /trusted-report-runs.mjs find-previous/);
  assert.match(job('reports'), /trusted-report-runs.mjs validate-source/);
});
test('only the final results job renders case tables; visual shards do not duplicate run Summaries', () => {
  assert.doesNotMatch(job('visual'), /GITHUB_STEP_SUMMARY|summary-only|Add shard results/);
  assert.match(job('report-results'), /--summary-only/);
});

test('all visual shards consume one secret-free app build from this attempt', () => {
  assert.equal(runs('build'), true);
  assert.equal(runs('build', { inputs: { report_source_run_id: '12' } }), false);
  assert.doesNotMatch(job('build'), /secrets\.|MIDSCENE_MODEL_/);
  assert.doesNotMatch(job('visual'), /build.sh/);
  assert.match(job('visual'), /needs: \[validation, desktop-capability, build\]/);
  assert.match(job('build'), /name: search-midscene-app-\$\{\{ github.run_attempt \}\}/);
  assert.match(job('visual'), /name: search-midscene-app-\$\{\{ github.run_attempt \}\}/);
});

test('a failed case keeps its generated Summary table while the final job stays red', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'search-failed-summary-'));
  try {
    await writeFile(path.join(root, 'npm'), '#!/bin/sh\nprintf "| Case | Report | Screenshot |\\n| failed case | retained report | retained screenshot |\\n" > "$MIDSCENE_SUMMARY_PATH"\nexit 1\n', { mode: 0o755 });
    const summary = path.join(root, 'job-summary.md');
    const script = job('report-results').split('      - name: Write the consolidated run Summary')[1].split('        run: |\n')[1].replace(/^          /gm, '');
    const result = spawnSync('bash', ['-e', '-c', script], { encoding: 'utf8', env: { ...process.env, PATH: `${root}:${process.env.PATH}`, RUNNER_TEMP: root, GITHUB_STEP_SUMMARY: summary, GITHUB_SERVER_URL: 'https://github.test', GITHUB_REPOSITORY: 'fixture/Search', GITHUB_RUN_ID: '1', GITHUB_RUN_ATTEMPT: '1', PAGE_URL: 'https://pages.test', REPORT_SOURCE_RUN_ID: '', REPORTS_DIR: 'reports', PRODUCER_RESULT: 'failure', REPORT_RESULT: 'failure', PUBLICATION_RESULT: 'success' } });
    assert.equal(result.status, 1);
    assert.match(await readFile(summary, 'utf8'), /failed case.*retained report.*retained screenshot/);
    assert.doesNotMatch(await readFile(summary, 'utf8'), /Summary unavailable/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
