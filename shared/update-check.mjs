/** 本项目唯一的公开正式版本来源；请求中不包含工资与排班。 */
export const releaseEndpoint = 'https://api.github.com/repos/Hcx-grass-star/niuma-macos/releases/latest';

/** 解析正式版本号，拒绝预发布、前导零和超出精确整数范围的版本段。 */
function parseVersion(raw) {
  if (typeof raw !== 'string' || !/^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(raw)) throw new Error('发布信息无效，请稍后重试。');
  const values = raw.replace(/^v/, '').split('.').map(Number);
  if (!values.every(Number.isSafeInteger)) throw new Error('发布信息无效，请稍后重试。');
  return values;
}

/** 按主、次、修订版本逐段比较，返回 -1、0 或 1。 */
export function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  for (let index = 0; index < 3; index += 1) if (a[index] !== b[index]) return a[index] > b[index] ? 1 : -1;
  return 0;
}

/** 自动检查按尝试时间限频，手动检查由调用方显式绕过本规则。 */
export function shouldCheckAutomatically(enabled, lastAttempt, now = Date.now()) {
  return enabled && (lastAttempt == null || (Number.isFinite(lastAttempt) && now - lastAttempt >= 86400000));
}

/** 验证正式发布页及当前平台安装包，避免引导用户下载其他程序或降级。 */
function evaluateRelease(payload, currentVersion, platform) {
  if (!payload || typeof payload.draft !== 'boolean' || typeof payload.prerelease !== 'boolean') throw new Error('发布信息无效，请稍后重试。');
  if (payload.draft || payload.prerelease) return { status: 'unpublished' };
  parseVersion(payload.tag_name);
  const expectedURL = `https://github.com/Hcx-grass-star/niuma-macos/releases/tag/${payload.tag_name}`;
  if (payload.html_url !== expectedURL || !Array.isArray(payload.assets)) throw new Error('发布信息无效，请稍后重试。');
  if (compareVersions(payload.tag_name, currentVersion) <= 0) return { status: 'upToDate' };
  const supported = payload.assets.some(({ name }) => {
    if (typeof name !== 'string') return false;
    const file = name.toLowerCase();
    if (platform === 'macos') return file.endsWith('.dmg') || (file.includes('macos') && file.endsWith('.zip'));
    return platform === 'windows' && (file.endsWith('.exe') || file.endsWith('.msi'));
  });
  if (!supported) return { status: 'unavailable' };
  if (payload.body != null && typeof payload.body !== 'string') throw new Error('发布信息无效，请稍后重试。');
  return { status: 'available', release: { version: payload.tag_name.replace(/^v/, ''), notes: (payload.body ?? '暂无更新说明。').slice(0, 4000), url: expectedURL } };
}

/** 读取版本元数据并返回更新状态；失败不改动任何工资数据。 */
export async function checkForUpdate({ currentVersion, platform, endpoint = releaseEndpoint, timeoutMs = 10000 }) {
  parseVersion(currentVersion);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(endpoint, { headers: { Accept: 'application/vnd.github+json' }, credentials: 'omit', cache: 'no-store', signal: controller.signal });
    if (response.status === 404) return { status: 'unpublished' };
    if ([403, 429].includes(response.status)) throw new Error('更新服务暂时受限，请稍后重试。');
    if (!response.ok) throw new Error('检查更新失败，请检查网络后重试。');
    const text = await response.text();
    if (text.length > 1_048_576) throw new Error('发布信息无效，请稍后重试。');
    return evaluateRelease(JSON.parse(text), currentVersion, platform);
  } catch (error) {
    if (error instanceof SyntaxError) throw new Error('发布信息无效，请稍后重试。');
    if (error instanceof TypeError || error.name === 'AbortError') throw new Error('检查更新失败，请检查网络后重试。');
    throw error;
  } finally { clearTimeout(timer); }
}
