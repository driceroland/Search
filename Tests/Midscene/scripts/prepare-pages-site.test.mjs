import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, access, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { preparePagesSite } from './prepare-pages-site.mjs';
async function fixture(fn) {
  const root = await mkdtemp(path.join(tmpdir(), 'search-pages-'));
  const reports = path.join(root, 'reports'), previous = path.join(root, 'previous'), site = path.join(root, 'site');
  await mkdir(path.join(reports, 'native'), { recursive: true });
  await writeFile(path.join(reports, 'native/index.html'), 'native report');
  try { await fn({ root, reports, previous, site }); } finally { await rm(root, { recursive: true, force: true }); }
}
test('retains three trusted run histories and replaces the entire rerun instead of retaining stale assets', () => fixture(async args => {
  for (const id of ['1', '2', '3', '4']) { await mkdir(path.join(args.previous, 'runs', id), { recursive: true }); await writeFile(path.join(args.previous, 'runs', id, 'stale'), 'old'); }
  await preparePagesSite({ ...args, runId: '4', attempt: '2' });
  await assert.rejects(access(path.join(args.site, 'runs/1')));
  await assert.rejects(access(path.join(args.site, 'runs/4/stale')));
  assert.equal(await readFile(path.join(args.site, 'runs/4/2/native/index.html'), 'utf8'), 'native report');
  assert.match(await readFile(path.join(args.site, 'index.html'), 'utf8'), /runs\/4\/2\/native\/index.html/);
}));
test('partial merges publish the retained originals without a fabricated native report link', () => fixture(async args => {
  await rm(path.join(args.reports, 'native'), { recursive: true });
  await writeFile(path.join(args.reports, 'original.html'), 'original');
  await preparePagesSite({ ...args, runId: '4', attempt: '1' });
  await access(path.join(args.site, 'runs/4/1/original.html'));
  assert.doesNotMatch(await readFile(path.join(args.site, 'index.html'), 'utf8'), /href=/);
}));
test('unsafe IDs, symlinked assets and oversized sites fail rather than publishing', () => fixture(async args => {
  await assert.rejects(preparePagesSite({ ...args, runId: '../bad', attempt: '1' }), /numeric/);
  await assert.rejects(preparePagesSite({ ...args, runId: '4', attempt: '1', maxSiteBytes: 1 }), /size limit/);
  await symlink(path.join(args.reports, 'native/index.html'), path.join(args.reports, 'link.html'));
  await assert.rejects(preparePagesSite({ ...args, runId: '4', attempt: '1' }), /Unsupported/);
}));
