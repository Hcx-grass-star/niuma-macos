import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** 本地更新测试的正式版本样例，不访问真实 GitHub 或工资配置。 */
const release = { tag_name: 'v0.3.0', body: '测试更新说明 <b>保持原文</b>', html_url: 'https://github.com/Hcx-grass-star/niuma-macos/releases/tag/v0.3.0', draft: false, prerelease: false, assets: [{ name: 'niuma-macOS-universal.zip' }, { name: 'niuma-windows-x64.exe' }] };
/** 静态源使用真实下载地址形状，与 API 使用相同版本和纯文本说明。 */
const manifest = { version: '0.3.0', notes: release.body, url: release.html_url, macos: 'https://github.com/Hcx-grass-star/niuma-macos/releases/download/v0.3.0/niuma-macOS-universal.zip', windows: 'https://github.com/Hcx-grass-star/niuma-macos/releases/download/v0.3.0/niuma-windows-x64.exe' };
/** 记录请求数，证明静态源成功时没有请求 GitHub API。 */
const counts = {};
/** 提供隔离的静态源、API 与失败响应，测试不访问公网或用户工资配置。 */
const server = createServer((request, response) => {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Content-Type', 'application/json');
  if (request.method === 'OPTIONS') { response.setHeader('Access-Control-Allow-Headers', 'Accept'); response.end(); return; }
  const path = request.url.slice(1);
  if (path === 'counts') { response.end(JSON.stringify(counts)); return; }
  counts[path] = (counts[path] ?? 0) + 1;
  const isManifest = path.startsWith('manifest-');
  const name = isManifest ? path.slice('manifest-'.length) : path;
  const payload = isManifest ? manifest : release;
  if (name === 'disconnect') { request.socket.destroy(); return; }
  if (name === 'slow') { const timer = setTimeout(() => response.end(JSON.stringify(payload)), 200); response.on('close', () => clearTimeout(timer)); return; }
  response.statusCode = ({ missing: 404, limited: 403, 'server-error': 500 })[name] ?? 200;
  if (name === 'invalid') { response.end('{broken'); return; }
  if (name === 'oversized') { response.end(JSON.stringify({ ...payload, notes: 'x'.repeat(1_048_577) })); return; }
  if (isManifest) {
    const changes = { 'mac-only': { windows: null }, 'windows-only': { macos: null }, 'unsafe-url': { macos: 'https://example.com/app.zip' }, 'unsafe-page': { url: 'https://example.com/releases/v0.3.0' }, 'wrong-tag': { macos: manifest.macos.replace('v0.3.0/', 'v0.4.0/') }, prerelease: { version: '0.3.0-beta' }, 'bad-notes': { notes: 123 } };
    response.end(JSON.stringify({ ...payload, ...changes[name] })); return;
  }
  const changes = { current: { tag_name: 'v0.2.0', html_url: release.html_url.replace('v0.3.0', 'v0.2.0') }, draft: { draft: true }, prerelease: { prerelease: true }, 'mac-only': { assets: [release.assets[0]] }, 'windows-only': { assets: [release.assets[1]] }, 'unsafe-url': { html_url: 'https://example.com/releases/v0.3.0' } };
  response.end(JSON.stringify({ ...release, ...changes[name] }));
});
await new Promise((resolveReady) => server.listen(0, '127.0.0.1', resolveReady));
/** 仅测试运行使用的本地接口地址。 */
const baseURL = `http://127.0.0.1:${server.address().port}`;
if (process.argv.includes('--serve')) {
  console.log(`更新验收接口：${baseURL}`);
} else {
  try {
    const { runUpdateTests } = await import('../shared/update-check.test.mjs');
    await runUpdateTests(baseURL, counts);
    const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
    const child = spawn('swift', ['run', '--disable-automatic-resolution', 'NiumaIntegrationTests'], { cwd: root, env: { ...process.env, NIUMA_UPDATE_TEST_URL: baseURL }, stdio: 'inherit' });
    const code = await new Promise((resolveExit, reject) => { child.once('error', reject); child.once('exit', resolveExit); });
    if (code !== 0) throw new Error(`Swift 集成验证退出码 ${code}`);
  } finally { server.closeAllConnections(); await new Promise((done) => server.close(done)); }
}
