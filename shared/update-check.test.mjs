import assert from 'node:assert/strict';
import { checkForUpdate, compareVersions, shouldCheckAutomatically } from './update-check.mjs';
import { createManifest, createAppcast, createTauriFeed, tauriTargets } from '../scripts/publish-updates.mjs';

/** 通过真实本地 HTTP 响应验证更新判断、平台安装包筛选及失败边界。 */
export async function runUpdateTests(baseURL, counts) {
  assert.equal(compareVersions('v0.10.0', '0.2.0'), 1);
  assert.equal(compareVersions('0.2.0', '0.2.0'), 0);
  assert.equal(compareVersions('0.1.9', '0.2.0'), -1);
  assert.throws(() => compareVersions('1.2.3-beta', '0.2.0'));
  assert.throws(() => compareVersions('1.02.3', '0.2.0'));
  const now = Date.UTC(2026, 10, 5);
  assert.equal(shouldCheckAutomatically(true, null, now), true);
  assert.equal(shouldCheckAutomatically(false, null, now), false);
  assert.equal(shouldCheckAutomatically(true, now - 86400000 + 1, now), false);
  assert.equal(shouldCheckAutomatically(true, now - 86400000, now), true);
  assert.equal(shouldCheckAutomatically(true, now + 1000, now), false);
  const request = (name, extra = {}) => checkForUpdate({ currentVersion: '0.2.0', platform: 'macos', manifestEndpoint: null, endpoint: `${baseURL}/${name}`, ...extra });
  const available = await request('available');
  assert.equal(available.status, 'available');
  assert.equal(available.release.version, '0.3.0');
  assert.equal(available.release.notes, '测试更新说明 <b>保持原文</b>');
  assert.equal((await request('available', { currentVersion: '0.3.0' })).status, 'upToDate');
  assert.equal((await request('available', { currentVersion: '0.4.0' })).status, 'upToDate');
  assert.equal((await request('available', { platform: 'windows' })).status, 'available');
  assert.equal((await request('mac-only', { platform: 'windows' })).status, 'unavailable');
  assert.equal((await request('windows-only')).status, 'unavailable');
  for (const name of ['missing', 'draft', 'prerelease']) assert.equal((await request(name)).status, 'unpublished');
  for (const name of ['limited', 'server-error', 'invalid', 'unsafe-url']) await assert.rejects(request(name));
  await assert.rejects(request('slow', { timeoutMs: 30 }));
  await assert.rejects(request('disconnect'));
  const staticRequest = (name, fallback = 'limited', extra = {}) => request(fallback, { manifestEndpoint: `${baseURL}/manifest-${name}`, ...extra });
  const before = counts.limited ?? 0;
  const staticResult = await staticRequest('available');
  assert.equal(staticResult.status, 'available');
  assert.equal(staticResult.release.version, '0.3.0');
  assert.equal(staticResult.release.notes, releaseNotes);
  assert.equal(counts.limited ?? 0, before, '静态源成功时不得请求 API');
  assert.equal((await staticRequest('available', 'limited', { currentVersion: '0.3.0' })).status, 'upToDate');
  assert.equal((await staticRequest('available', 'limited', { currentVersion: '0.4.0' })).status, 'upToDate');
  assert.equal((await staticRequest('available', 'limited', { platform: 'windows' })).status, 'available');
  assert.equal((await staticRequest('windows-only')).status, 'unavailable');
  assert.equal((await staticRequest('mac-only', 'limited', { platform: 'windows' })).status, 'unavailable');
  for (const name of ['missing', 'limited', 'invalid', 'unsafe-url', 'unsafe-page', 'wrong-tag', 'prerelease', 'bad-notes', 'oversized', 'disconnect', 'slow']) {
    const apiBefore = counts.available ?? 0;
    assert.equal((await staticRequest(name, 'available', { timeoutMs: name === 'slow' ? 30 : 2000 })).status, 'available');
    assert.equal(counts.available, apiBefore + 1, `${name} 应只回退一次 API`);
  }
  await assert.rejects(staticRequest('missing', 'limited'), /更新服务暂时受限/);
  await assert.rejects(staticRequest('invalid', 'invalid'), /发布信息无效/);
  await assert.rejects(staticRequest('disconnect', 'disconnect'));
  const asset = { name: 'niuma-macOS-universal.zip', state: 'uploaded', size: 123, browser_download_url: 'https://github.com/Hcx-grass-star/niuma-macos/releases/download/v0.3.0/niuma-macOS-universal.zip' };
  const official = { tag_name: 'v0.3.0', draft: false, prerelease: false, html_url: 'https://github.com/Hcx-grass-star/niuma-macos/releases/tag/v0.3.0', body: releaseNotes, assets: [asset] };
  assert.equal(createManifest(official).macos, asset.browser_download_url);
  assert.equal(createManifest(official).windows, undefined);
  for (const changes of [{ draft: true }, { prerelease: true }, { tag_name: 'v0.3.0-beta' }, { assets: [] }, { assets: [{ ...asset, state: 'starter' }] }, { assets: [{ ...asset, browser_download_url: 'https://example.com/app.zip' }] }]) assert.throws(() => createManifest({ ...official, ...changes }));
  const signatureMetadata = { version: '0.3.0', build: '4', length: asset.size, signature: Buffer.alloc(64, 1).toString('base64') };
  const appcast = createAppcast({ ...official, published_at: '2026-11-05T00:00:00Z' }, asset, signatureMetadata);
  assert.match(appcast, /sparkle:version="4"/);
  assert.match(appcast, /sparkle:shortVersionString="0.3.0"/);
  assert.match(appcast, /sparkle:format="plain-text"/);
  assert.throws(() => createAppcast(official, asset, { ...signatureMetadata, length: 999 }));
  assert.throws(() => createAppcast(official, asset, { ...signatureMetadata, version: '0.2.1' }));
  const installer = { ...asset, name: 'niuma-0.3.0-x64-setup.exe', browser_download_url: 'https://github.com/Hcx-grass-star/niuma-macos/releases/download/v0.3.0/niuma-0.3.0-x64-setup.exe' };
  const feed = createTauriFeed(official, [{ asset: installer, signature: 'public-signature-fixture' }]);
  assert.equal(feed.platforms['windows-x86_64-nsis'].url, installer.browser_download_url);
  assert.equal(feed.platforms['windows-x86_64'].signature, 'public-signature-fixture');
  assert.deepEqual(tauriTargets('niuma-0.3.0-macOS-universal.app.tar.gz'), ['darwin-aarch64', 'darwin-x86_64']);
  assert.deepEqual(tauriTargets('niuma-0.3.0-macOS-universal.zip'), [], 'Tauri 不能安装原生 Swift ZIP');
  assert.throws(() => createTauriFeed(official, [{ asset: installer, signature: '' }]));
  console.log('PASS: JS 静态源优先、API限流隔离、失败回退、平台筛选与双源错误（真实HTTP）');
}

/** 静态源说明必须与现有 API 的纯文本展示保持一致。 */
const releaseNotes = '测试更新说明 <b>保持原文</b>';
