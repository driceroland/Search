import { mkdir, readdir, copyFile, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
async function copyTree(source, target) {
  await mkdir(target, { recursive: true });
  for (const entry of await readdir(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name), to = path.join(target, entry.name);
    if (entry.isDirectory()) await copyTree(from, to);
    else if (entry.isFile()) await copyFile(from, to);
    else throw new Error(`Unsupported Pages asset: ${entry.name}`);
  }
}
async function bytes(directory) {
  let total = 0;
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    total += entry.isDirectory() ? await bytes(file) : (await stat(file)).size;
  }
  return total;
}
export async function preparePagesSite({ site, reports, runId, attempt, previous, maxSiteBytes = 900 * 1024 * 1024 }) {
  if (!/^\d+$/.test(runId) || !/^[1-9]\d*$/.test(attempt)) throw new Error('Run ID and attempt must be numeric');
  await rm(site, { recursive: true, force: true });
  const runs = path.join(site, 'runs');
  await mkdir(runs, { recursive: true });
  const oldRuns = previous && path.join(previous, 'runs');
  if (oldRuns) {
    let entries;
    try { entries = await readdir(oldRuns, { withFileTypes: true }); } catch (error) { if (error.code !== 'ENOENT') throw error; entries = []; }
    for (const entry of entries) if (entry.isDirectory() && /^\d+$/.test(entry.name) && entry.name !== runId) await copyTree(path.join(oldRuns, entry.name), path.join(runs, entry.name));
  }
  const current = path.join(runs, runId, attempt);
  await copyTree(reports, current);
  let ids = (await readdir(runs)).sort((a, b) => BigInt(a) < BigInt(b) ? -1 : 1);
  for (const id of ids.slice(0, -3)) await rm(path.join(runs, id), { recursive: true });
  ids = ids.slice(-3);
  while (await bytes(site) > maxSiteBytes - 10_000 && ids.length > 1) await rm(path.join(runs, ids.shift()), { recursive: true });
  let native;
  for (const candidate of ['native/index.html', 'native.html']) {
    try { if ((await stat(path.join(current, candidate))).isFile()) { native = candidate; break; } } catch {}
  }
  await writeFile(path.join(site, 'index.html'), `<!doctype html><html lang="en"><meta charset="utf-8"><title>Midscene reports</title><h1>Midscene reports</h1>${native ? `<p><a href="runs/${runId}/${attempt}/${native}">Latest native report</a></p>` : '<p>Native merging was incomplete; original reports are retained.</p>'}<p>Case links are available in the workflow Summary and downloadable artifact.</p></html>`);
  if (await bytes(site) > maxSiteBytes) throw new Error('Pages site exceeds the size limit');
  return { runIds: ids };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const options = {};
  for (let i = 2; i < process.argv.length; i += 2) {
    if (!process.argv[i].startsWith('--') || process.argv[i + 1] === undefined) throw new Error('Invalid Pages arguments');
    options[process.argv[i].slice(2)] = process.argv[i + 1];
  }
  await preparePagesSite({ site: options.site, reports: options.reports, runId: options['run-id'], attempt: options.attempt, previous: options.previous });
}
