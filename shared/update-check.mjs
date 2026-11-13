/** 主更新源使用静态托管，不占用 GitHub REST API 的匿名请求额度。 */
export const manifestEndpoint = 'https://hcx-grass-star.github.io/niuma-macos/latest.json';
/** 静态清单不可用时回退到本项目的公开正式发布接口。 */
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

/** 校验清单下载地址与其版本一致，防止将外部站点或其他版本当成正式安装包。 */
function manifestAsset(raw, tag, platform) {
  if (raw == null) return [];
  if (typeof raw !== 'string') throw new Error('发布信息无效，请稍后重试。');
  const url = new URL(raw);
  const prefix = `https://github.com/Hcx-grass-star/niuma-macos/releases/download/${tag}/`;
  const file = raw.slice(prefix.length);
  if (!raw.startsWith(prefix) || url.origin !== 'https://github.com' || url.username || url.password || url.port || url.search || url.hash || !file || /[/\\]/.test(decodeURIComponent(file))) throw new Error('发布信息无效，请稍后重试。');
  const name = file.toLowerCase();
  const supported = platform === 'macos' ? name.endsWith('.dmg') || (name.includes('macos') && name.endsWith('.zip')) : name.endsWith('.exe') || name.endsWith('.msi');
  if (!supported) throw new Error('发布信息无效，请稍后重试。');
  return [{ name: file }];
}

/** 将静态清单转换为已有正式发布判定，沿用版本、平台和纯文本说明规则。 */
function evaluateManifest(payload, currentVersion, platform) {
  if (!payload || typeof payload !== 'object') throw new Error('发布信息无效，请稍后重试。');
  const version = parseVersion(payload.version).join('.');
  const page = payload.url ?? `https://github.com/Hcx-grass-star/niuma-macos/releases/tag/v${version}`;
  if (typeof page !== 'string' || (payload.notes != null && typeof payload.notes !== 'string')) throw new Error('发布信息无效，请稍后重试。');
  const tag = new URL(page).pathname.split('/').at(-1);
  if (compareVersions(tag, version) !== 0) throw new Error('发布信息无效，请稍后重试。');
  const assets = [...manifestAsset(payload.macos, tag, 'macos'), ...manifestAsset(payload.windows, tag, 'windows')];
  return evaluateRelease({ tag_name: tag, html_url: page, body: payload.notes, assets, draft: false, prerelease: false }, currentVersion, platform);
}

/** 单个来源独立超时；所有网络与响应错误均转换为可展示消息。 */
async function requestUpdate(endpoint, currentVersion, platform, timeoutMs, isManifest) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(endpoint, { headers: { Accept: isManifest ? 'application/json' : 'application/vnd.github+json' }, credentials: 'omit', cache: 'no-store', signal: controller.signal });
    if (response.status === 404 && !isManifest) return { status: 'unpublished' };
    if ([403, 429].includes(response.status)) throw new Error('更新服务暂时受限，请稍后重试。');
    if (!response.ok) throw new Error('检查更新失败，请检查网络后重试。');
    const text = await response.text();
    if (text.length > 1_048_576) throw new Error('发布信息无效，请稍后重试。');
    return (isManifest ? evaluateManifest : evaluateRelease)(JSON.parse(text), currentVersion, platform);
  } catch (error) {
    if (error instanceof SyntaxError) throw new Error('发布信息无效，请稍后重试。');
    if (error instanceof TypeError || error.name === 'AbortError') throw new Error('检查更新失败，请检查网络后重试。');
    throw error;
  } finally { clearTimeout(timer); }
}

/** 静态源成功即结束；不可用或内容无效时只回退一次 API，双源失败保留错误。 */
export async function checkForUpdate({ currentVersion, platform, manifestEndpoint: primaryEndpoint = manifestEndpoint, endpoint = releaseEndpoint, timeoutMs = 10000 }) {
  parseVersion(currentVersion);
  if (primaryEndpoint != null) {
    try { return await requestUpdate(primaryEndpoint, currentVersion, platform, timeoutMs, true); }
    catch { /* 静态源失败允许使用现有 API，成功时绝不消耗 API 额度。 */ }
  }
  return requestUpdate(endpoint, currentVersion, platform, timeoutMs, false);
}
