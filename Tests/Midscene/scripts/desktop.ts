import { spawn, execFileSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, rm, writeFile, readFile, access } from 'node:fs/promises';
import { createServer } from 'node:http';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { agentForComputer } from '@midscene/computer';
export type DesktopAgent = Awaited<ReturnType<typeof agentForComputer>>;
export async function openCase(id: string, onTeardown: (cleanup: () => Promise<void>) => void, signal: AbortSignal): Promise<DesktopAgent> {
  if (process.platform !== 'darwin') throw new Error('Search E2E requires macOS');
  if (process.env.MIDSCENE_DESKTOP_ENABLED !== '1') throw new Error('Set MIDSCENE_DESKTOP_ENABLED=1 on a dedicated test desktop');
  for (const key of ['MIDSCENE_MODEL_API_KEY', 'MIDSCENE_MODEL_NAME', 'MIDSCENE_MODEL_BASE_URL', 'MIDSCENE_MODEL_FAMILY']) {
    if (!process.env[key]) throw new Error(`Missing ${key}`);
  }
  const app = path.resolve(process.env.SEARCH_E2E_APP ?? (process.arch === 'x64' ? '../../build/intel/Search.app' : '../../build/Search.app'));
  await access(path.join(app, 'Contents/MacOS/Search'));
  const out = path.resolve('midscene_run');
  await mkdir(out, { recursive: true });
  // Darwin Unix socket paths have a 104-byte limit, including the terminator.
  const world = `midscene-${randomUUID().replaceAll('-', '').slice(0, 16)}`;
  const bundle = `com.officecommun.search.${world}`;
  const suite = `com.officecommun.search.test.${world}`;
  const support = path.join(homedir(), 'Library/Application Support', `Search (${world})`);
  if (Buffer.byteLength(path.join(support, 'bench.sock')) >= 104) {
    throw new Error('Test support path exceeds the macOS Unix socket limit');
  }
  const work = await mkdtemp(path.join(tmpdir(), 'search-midscene-'));
  const copy = path.join(work, 'Search.app');
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'");
    if (req.url === '/feed') { res.end('{}'); return; }
    res.end('<!doctype html><title>E2E Orchard</title><style>body{font:24px system-ui;padding:60px}</style><h1>E2E Orchard</h1><p>amber apple, amber pear, amber plum</p>');
  });
  let child: ReturnType<typeof spawn> | undefined;
  let agent: Awaited<ReturnType<typeof agentForComputer>> | undefined;
  onTeardown(async () => {
    try {
      if (agent) {
        const publicationErrors: unknown[] = [];
        // Only the owned test world's data; retain evidence of case isolation.
        let bookmarks: unknown;
        try { bookmarks = JSON.parse(await readFile(path.join(support, 'bookmarks.json'), 'utf8')); } catch {}
        try {
          await writeFile(path.join(out, `${id}-runtime.json`), JSON.stringify({ pid: child?.pid, world, bookmarks }, null, 2));
        } catch (error) { publicationErrors.push(error); }
        try {
          await writeFile(path.join(out, `${id}.png`), Buffer.from((await agent.interface.screenshotBase64()).replace(/^data:image\/\w+;base64,/, ''), 'base64'));
        } catch (error) { publicationErrors.push(error); }
        // Publish native HTML even if the final screenshot capture fails.
        try {
          await writeFile(path.join(out, `${id}.html`), agent.reportHTMLString({ inlineScreenshots: true }));
        } catch (error) { publicationErrors.push(error); }
        if (publicationErrors.length) throw new AggregateError(publicationErrors, 'Case artifact publication failed');
      }
    } finally {
      await agent?.destroy().catch(() => undefined);
      if (child?.pid && child.exitCode === null) {
        const exited = once(child, 'exit'); child.kill('SIGTERM');
        const timer = setTimeout(() => child?.kill('SIGKILL'), 5000);
        await exited; clearTimeout(timer);
      }
      await new Promise<void>(resolve => server.close(() => resolve()));
      await rm(work, { recursive: true, force: true });
      await rm(support, { recursive: true, force: true });
      await rm(path.join(homedir(), 'Library/Saved Application State', `${bundle}.savedState`), { recursive: true, force: true });
      for (const folder of ['WebKit', 'Caches', 'HTTPStorages']) await rm(path.join(homedir(), 'Library', folder, bundle), { recursive: true, force: true });
      for (const domain of [suite, bundle]) {
        try { execFileSync('defaults', ['delete', domain], { stdio: 'ignore' }); } catch {}
      }
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('Missing fixture server');
  const base = `http://127.0.0.1:${address.port}`;
  const fixture = path.join(work, 'e2e-bookmarks.html');
  await writeFile(fixture, `<!DOCTYPE NETSCAPE-Bookmark-file-1><TITLE>Bookmarks</TITLE><DL><p><DT><H3>E2E Reading</H3><DL><p><DT><A HREF="${base}/orchard">E2E Orchard</A><DT><A HREF="${base}/harbor">E2E Harbor</A></DL><p></DL><p>`);
  await cp(app, copy, { recursive: true });
  execFileSync('/usr/libexec/PlistBuddy', ['-c', `Set :CFBundleIdentifier ${bundle}`, path.join(copy, 'Contents/Info.plist')]);
  execFileSync('codesign', ['--force', '--deep', '--sign', '-', copy], { stdio: 'pipe' });
  execFileSync('defaults', ['write', suite, 'welcomed', '-bool', 'true']);
  execFileSync('defaults', ['write', suite, 'bench', '-bool', 'true']);
  const appEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('MIDSCENE_')));
  child = spawn(path.join(copy, 'Contents/MacOS/Search'), ['-AppleLanguages', '(en)', '-AppleLocale', 'en_US'], {
    env: { ...appEnv, SEARCH_PROBE: world, SEARCH_E2E_VISIBLE: '1', SEARCH_FEED: `${base}/feed` }, stdio: 'ignore',
  });
  let launchError: Error | undefined;
  child.on('error', error => { launchError = error; });
  let ready = false;
  for (let attempt = 0; attempt < 150; attempt++) {
    if (launchError) throw launchError;
    if (child.exitCode !== null || signal.aborted) throw new Error('Search exited before readiness');
    try { await access(path.join(support, 'bench.sock')); ready = true; break; } catch { await delay(100); }
  }
  if (!ready) throw new Error('Search did not initialize its isolated probe');
  // Target the launched PID; never let AppleScript launch an unconfigured app.
  let focused = false;
  for (let attempt = 0; attempt < 30; attempt++) {
    try {
      const pid = execFileSync('osascript', ['-e', `tell application "System Events"
        tell (first process whose unix id is ${child.pid})
          set frontmost to true
          perform action "AXRaise" of window 1
        end tell
        return unix id of first process whose frontmost is true
      end tell`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
      if (pid === String(child.pid)) { focused = true; break; }
    } catch {}
    await delay(100);
  }
  if (!focused) throw new Error('Could not bring the owned Search test window to the foreground');
  agent = await agentForComputer({ generateReport: true, reportFileName: id, autoPrintReportMsg: false, replanningCycleLimit: 20,
    aiContexts: { default: `You are testing Search, a native macOS browser with English menus. Operate only its test window and file chooser. The bookmarks fixture path is ${fixture}. The local Orchard URL is ${base}/orchard. Never navigate to external websites, quit or relaunch apps, or use Dock or Spotlight. If the test window is unavailable, report failure.` } });
  return agent;
}
