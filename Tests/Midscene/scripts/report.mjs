import { mkdir, readdir, readFile, rm, writeFile, appendFile, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { collect } from './collect.mjs';
import { artifactUrl, evidenceFor, renderSummary } from './summary.mjs';
export async function assemble({ directory, baseUrl = '', summary, merge, shard, runUrl = '', producerResult = 'success', mergeReports = true, reportResult, publicationResult, sourceRunId }) {
  await mkdir(directory, { recursive: true });
  const native = path.join(directory, 'native');
  if (mergeReports) {
    await rm(native, { recursive: true, force: true });
    await rm(`${native}.html`, { force: true });
  }
  const expected = await collect(shard);
  const names = new Set(expected.flatMap(c => [`${c.id}.html`, `${c.id}.png`]));
  const artifacts = new Map(), results = new Map(), models = new Set();
  const frameworkReports = [], issues = [];
  async function walk(dir) {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) { if (!['report', 'native'].includes(entry.name)) await walk(file); continue; }
      if (names.has(entry.name)) artifacts.set(entry.name, [...(artifacts.get(entry.name) ?? []), file]);
      if (entry.name === 'index.html' && file.includes(`${path.sep}framework${path.sep}`)) frameworkReports.push(file);
      if (entry.name === 'results.json' && !file.includes(`${path.sep}framework${path.sep}`)) {
        try {
          for (const result of JSON.parse(await readFile(file, 'utf8'))) {
            if (!expected.some(c => c.id === result.id)) { issues.push(`Unexpected case: ${result.id}`); continue; }
            if (results.has(result.id)) { issues.push(`Duplicate case result: ${result.id}`); results.set(result.id, null); }
            else results.set(result.id, result);
          }
        } catch { issues.push(`Unreadable case results: ${path.relative(directory, file)}`); }
      }
      if (entry.name === 'model.json') {
        try {
          const metadata = JSON.parse(await readFile(file, 'utf8'));
          if (typeof metadata.modelName === 'string') models.add(`${metadata.modelName}${typeof metadata.modelFamily === 'string' && metadata.modelFamily ? ` (${metadata.modelFamily})` : ''}`);
        } catch { issues.push(`Unreadable model metadata: ${path.relative(directory, file)}`); }
      }
    }
  }
  await walk(directory);
  function unique(name) {
    const files = artifacts.get(name) ?? [];
    if (files.length > 1) { issues.push(`Ambiguous ${name}; original reports are retained and none was selected`); return null; }
    return files[0] ?? null;
  }
  const cases = [], htmlPaths = [], matchedFrameworks = [];
  for (const c of expected) {
    const result = results.get(c.id);
    const standalone = unique(`${c.id}.html`), png = unique(`${c.id}.png`);
    const matches = [];
    for (const file of frameworkReports) {
      try {
        const evidence = await evidenceFor(file, c.id, result?.status === 'passed', directory);
        if (evidence) matches.push(evidence);
      } catch { issues.push(`Unreadable native framework report: ${path.relative(directory, file)}`); }
    }
    if (matches.length > 1) issues.push(`Ambiguous native framework case: ${c.id}`);
    const evidence = matches.length === 1 ? matches[0] : undefined;
    if (evidence) matchedFrameworks.push(evidence.report);
    const report = evidence?.report ?? standalone, screenshot = evidence?.screenshot ?? png;
    let status = result?.status ?? 'missing', reason = result?.reason || evidence?.reason || '';
    if (status === 'passed' && evidence && evidence.status !== 'success') { status = 'incomplete'; reason = 'Case metadata differs from the native framework result'; }
    if (status === 'passed' && (!report || !screenshot)) { status = 'incomplete'; reason = 'Native report or screenshot missing'; }
    if (status === 'missing' && !reason) reason = 'No case result was recorded; inspect shard setup and job logs';
    if (status !== 'passed' && !reason) reason = status === 'not-run' ? 'Case was not run' : 'Midscene case failed; inspect the native report and shard logs';
    const reportUrl = baseUrl && report ? `${artifactUrl(baseUrl, directory, report)}${evidence?.stepId ? `#${new URLSearchParams({ 'runner-step': evidence.stepId })}` : ''}` : undefined;
    const screenshotUrl = baseUrl && screenshot ? artifactUrl(baseUrl, directory, screenshot) : undefined;
    cases.push({ ...c, status, reason, reportUrl, screenshotUrl, durationMs: result?.durationMs ?? evidence?.durationMs });
    if (standalone ?? report) htmlPaths.push(standalone ?? report);
  }
  let merged;
  if (mergeReports) {
    try {
      if (!htmlPaths.length) throw new Error('No native HTML reports');
      const selectedReports = matchedFrameworks.length === expected.length ? matchedFrameworks : htmlPaths;
      merged = await merge({ htmlPaths: [...new Set(selectedReports)], outputDir: directory, outputName: 'native', overwrite: true });
      await access(merged.mergedReportPath);
    } catch {
      merged = undefined;
      issues.push('Native report merge failed. Individual reports remain available.');
      await rm(native, { recursive: true, force: true });
      await rm(`${native}.html`, { force: true });
    }
  }
  let retainedNative;
  if (!mergeReports) {
    for (const candidate of [path.join(native, 'index.html'), `${native}.html`]) {
      try { await access(candidate); retainedNative = candidate; break; } catch {}
    }
  }
  const nativeReport = merged?.mergedReportPath ?? retainedNative ?? (!mergeReports && frameworkReports.length === 1 ? frameworkReports[0] : undefined);
  const markdown = renderSummary({ cases, models: [...models].sort(), runUrl, producerResult, issues, nativeReportAvailable: Boolean(nativeReport), reportResult, publicationResult, sourceRunId, nativeReportUrl: baseUrl && nativeReport ? artifactUrl(baseUrl, directory, nativeReport) : undefined });
  await (summary === process.env.GITHUB_STEP_SUMMARY ? appendFile : writeFile)(summary, markdown);
  return cases.length > 0 && cases.every(c => c.status === 'passed') && !issues.length && producerResult === 'success';
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { mergeReportFiles } = await import('@midscene/core');
  const ok = await assemble({ directory: path.resolve(process.argv.slice(2).find(value => !value.startsWith('--')) ?? 'midscene_run'), baseUrl: process.env.MIDSCENE_REPORT_URL ?? '', summary: process.env.MIDSCENE_SUMMARY_PATH ?? process.env.GITHUB_STEP_SUMMARY ?? 'summary.md', merge: mergeReportFiles, shard: process.env.MIDSCENE_SHARD, runUrl: process.env.MIDSCENE_RUN_URL, producerResult: process.env.MIDSCENE_PRODUCER_RESULT ?? 'success', reportResult: process.env.MIDSCENE_REPORT_RESULT, publicationResult: process.env.MIDSCENE_PUBLICATION_RESULT, sourceRunId: process.env.MIDSCENE_SOURCE_RUN_ID, mergeReports: !process.argv.includes('--summary-only') });
  if (!ok) process.exitCode = 1;
}
