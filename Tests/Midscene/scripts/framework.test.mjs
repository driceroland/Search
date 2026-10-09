import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, access, rm } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { runTestProject } from '@midscene/test/config';

test('native framework executes YAML and tears down a failed case without secrets', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'search-framework-'));
  const marker = path.join(root, 'cleanup.txt');
  try {
    await writeFile(path.join(root, 'case.yaml'), 'cases:\n  - name: failure-cleanup\n    steps:\n      - fixture.open: {}\n      - fixture.fail: {}\n');
    await writeFile(path.join(root, 'midscene.config.mjs'), `
      import { defineTestProject, defineProjectSetup } from ${JSON.stringify(import.meta.resolve('@midscene/test/config'))};
      import { defineNode, z } from ${JSON.stringify(import.meta.resolve('@midscene/test'))};
      import { writeFile } from 'node:fs/promises';
      export default defineTestProject({
        test: { maxConcurrency: 1, testTimeout: 1000 },
        projects: [{name:'harness', setup:defineProjectSetup({name:'fixture', setup:async()=>({})}), files:{include:['case.yaml']}, retry:0}],
        nodes: [
          defineNode({name:'fixture.open', inputSchema:z.strictObject({}), execute({onTeardown}) {onTeardown(()=>writeFile(${JSON.stringify(marker)}, 'cleaned'));}}),
          defineNode({name:'fixture.fail', inputSchema:z.strictObject({}), execute() {throw new Error('expected harness failure');}})
        ]
      });
    `);
    const result = await runTestProject({ cwd: root, projectRoot: root, configPath: path.join(root, 'midscene.config.mjs'), resultDir: path.join(root, 'output') });
    assert.equal(result.exitCode, 1);
    assert.equal(result.cases[0].status, 'failed');
    assert.match(result.cases[0].run.steps[1].error.message, /expected harness failure/);
    assert.equal(await readFile(marker, 'utf8'), 'cleaned');
    await access(result.reportPath);
    assert.equal(JSON.parse(await readFile(result.summaryPath, 'utf8')).summary.failed, 1);
  } finally { await rm(root, { recursive: true, force: true }); }
});
