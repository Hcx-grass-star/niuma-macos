import assert from 'node:assert/strict';
import { checkForUpdate, compareVersions, shouldCheckAutomatically } from './update-check.mjs';

/** 通过真实本地 HTTP 响应验证更新判断、平台安装包筛选及失败边界。 */
export async function runUpdateTests(baseURL) {
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
  const request = (name, extra = {}) => checkForUpdate({ currentVersion: '0.2.0', platform: 'macos', endpoint: `${baseURL}/${name}`, ...extra });
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
  console.log('PASS: JS 更新版本、24小时限频、平台筛选与真实HTTP失败场景');
}
