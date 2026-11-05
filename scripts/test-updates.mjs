import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** 本地更新测试的正式版本样例，不访问真实 GitHub 或工资配置。 */
const release = { tag_name: 'v0.3.0', body: '测试更新说明 <b>保持原文</b>', html_url: 'https://github.com/Hcx-grass-star/niuma-macos/releases/tag/v0.3.0', draft: false, prerelease: false, assets: [{ name: 'niuma-macOS-universal.zip' }, { name: 'niuma-windows-x64.exe' }] };
/** 提供隔离的 GitHub 形状 HTTP 响应，供 Swift、Node 与浏览器验收复用。 */
const server = createServer((request, response) => {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Content-Type', 'application/json');
  if (request.method === 'OPTIONS') { response.setHeader('Access-Control-Allow-Headers', 'Accept'); response.end(); return; }
  const name = request.url.slice(1);
  if (name === 'disconnect') { request.socket.destroy(); return; }
  if (name === 'slow') { const timer = setTimeout(() => response.end(JSON.stringify(release)), 200); response.on('close', () => clearTimeout(timer)); return; }
  response.statusCode = ({ missing: 404, limited: 403, 'server-error': 500 })[name] ?? 200;
  if (name === 'invalid') { response.end('{broken'); return; }
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
    await runUpdateTests(baseURL);
    const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
    const child = spawn('swift', ['run', '--disable-automatic-resolution', 'NiumaIntegrationTests'], { cwd: root, env: { ...process.env, NIUMA_UPDATE_TEST_URL: baseURL }, stdio: 'inherit' });
    const code = await new Promise((resolveExit, reject) => { child.once('error', reject); child.once('exit', resolveExit); });
    if (code !== 0) throw new Error(`Swift 集成验证退出码 ${code}`);
  } finally { server.closeAllConnections(); await new Promise((done) => server.close(done)); }
}
