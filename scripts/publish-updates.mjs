import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { compareVersions } from '../shared/update-check.mjs';

/** 发布侧凭本机 gh 登录写入公开清单；客户端不携带任何凭据。 */
const repository = 'Hcx-grass-star/niuma-macos';
/** 此分支只托管静态文件，与代码分支及安装包分离。 */
const feedBranch = 'codex/update-feed';

/** 仅从已发布正式 Release 和真实上传资产生成清单，拒绝伪造下载地址。 */
export function createManifest(release) {
  const tag = release.tag_name;
  compareVersions(tag, tag);
  const page = `https://github.com/${repository}/releases/tag/${tag}`;
  if (release.draft !== false || release.prerelease !== false || release.html_url !== page || !Array.isArray(release.assets) || (release.body != null && typeof release.body !== 'string')) throw new Error('只能发布已上线的正式 Release。');
  const manifest = { version: tag.replace(/^v/, ''), notes: (release.body ?? '暂无更新说明。').slice(0, 4000), url: page };
  for (const asset of release.assets) {
    if (typeof asset.name !== 'string') continue;
    const name = asset.name.toLowerCase();
    const platform = name.endsWith('.dmg') || (name.includes('macos') && name.endsWith('.zip')) ? 'macos' : name.endsWith('.exe') || name.endsWith('.msi') ? 'windows' : null;
    if (!platform || manifest[platform]) continue;
    const expected = `https://github.com/${repository}/releases/download/${tag}/${encodeURIComponent(asset.name)}`;
    if (asset.state !== 'uploaded' || !(asset.size > 0) || asset.browser_download_url !== expected) throw new Error('安装包尚未完整上传或不属于本版本。');
    manifest[platform] = asset.browser_download_url;
  }
  if (!manifest.macos && !manifest.windows) throw new Error('正式 Release 尚无支持的平台安装包。');
  return manifest;
}

/** Sparkle 使用真实包内构建号与 EdDSA 签名，说明强制按纯文本呈现。 */
export function createAppcast(release, asset, metadata) {
  const manifest = createManifest(release);
  if (metadata.version !== manifest.version || metadata.length !== asset.size || !/^\d+(?:\.\d+){0,2}$/.test(metadata.build) || typeof metadata.signature !== 'string' || Buffer.from(metadata.signature, 'base64').length !== 64) throw new Error('原生更新签名元数据无效。');
  const escape = (value) => String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  const notes = manifest.notes.replaceAll(']]>', ']]]]><![CDATA[>');
  return `<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>牛马上班</title><link>${escape(manifest.url)}</link><item><title>${escape(manifest.version)}</title><description sparkle:format="plain-text"><![CDATA[${notes}]]></description><pubDate>${escape(new Date(release.published_at).toUTCString())}</pubDate><sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion><enclosure url="${escape(asset.browser_download_url)}" sparkle:version="${escape(metadata.build)}" sparkle:shortVersionString="${escape(manifest.version)}" length="${asset.size}" type="application/octet-stream" sparkle:edSignature="${escape(metadata.signature)}"/></item></channel></rss>\n`;
}

/** 根据安装器类型和芯片匹配 Tauri 更新包，不把原生 Swift ZIP 发给 Tauri。 */
export function tauriTargets(name) {
  if (name.endsWith('.exe')) return ['windows-x86_64-nsis', 'windows-x86_64'];
  if (name.endsWith('.msi')) return ['windows-x86_64-msi'];
  if (!name.endsWith('.app.tar.gz')) return [];
  if (name.includes('universal')) return ['darwin-aarch64', 'darwin-x86_64'];
  if (name.includes('aarch64')) return ['darwin-aarch64'];
  if (name.includes('x86_64')) return ['darwin-x86_64'];
  throw new Error('Tauri macOS 更新包缺少明确架构。');
}

/** 接收发布者已上传的公开签名，客户端使用内置公钥验证实际安装内容。 */
export function createTauriFeed(release, signedAssets) {
  const manifest = createManifest(release);
  const platforms = {};
  for (const { asset, signature } of signedAssets) {
    const expected = `https://github.com/${repository}/releases/download/${release.tag_name}/${encodeURIComponent(asset.name)}`;
    if (asset.browser_download_url !== expected || asset.state !== 'uploaded' || !(asset.size > 0) || typeof signature !== 'string' || !signature.trim()) throw new Error('Tauri 更新包或签名无效。');
    for (const target of tauriTargets(asset.name)) platforms[target] = { url: expected, signature: signature.trim() };
  }
  return { version: manifest.version, notes: manifest.notes, pub_date: release.published_at, platforms };
}

/** gh 使用发布者已有认证；JSON 经标准输入传递，避免 shell 展开说明文本。 */
function github(path, body, method = 'PUT') {
  const args = ['api', `repos/${repository}/${path}`];
  if (body) args.push('--method', method, '--input', '-');
  return JSON.parse(execFileSync('gh', args, { encoding: 'utf8', input: body ? JSON.stringify(body) : undefined, maxBuffer: 5 * 1024 * 1024 }));
}

/** 只读取本次正式发布中的小型公开签名附件，不访问任意外部下载地址。 */
function publicAsset(release, name) {
  const asset = release.assets.find((item) => item.name === name && item.state === 'uploaded' && item.size > 0 && item.size < 1024 * 1024);
  if (!asset) throw new Error('缺少已上传的更新校验附件：' + name);
  return execFileSync('gh', ['api', `repos/${repository}/releases/assets/${asset.id}`, '-H', 'Accept: application/octet-stream'], { encoding: 'utf8', maxBuffer: 1024 * 1024 });
}

/** 发布后同步清单；预览不写入远端，版本检查及 SHA 条件写入防止回退与覆盖竞争。 */
function publish() {
  const args = process.argv.slice(2);
  if (args.some((arg) => arg !== '--dry-run')) throw new Error('用法：node scripts/publish-updates.mjs [--dry-run]');
  const release = github('releases/latest');
  const manifest = createManifest(release);
  const content = JSON.stringify(manifest, null, 2) + '\n';
  if (args.includes('--dry-run')) { process.stdout.write(content); return; }
  const head = github(`git/ref/heads/${feedBranch}`).object.sha;
  const base = github(`git/commits/${head}`).tree.sha;
  const existing = github(`contents/latest.json?ref=${head}`);
  const previous = JSON.parse(Buffer.from(existing.content, 'base64').toString('utf8'));
  if (compareVersions(previous.version, manifest.version) > 0) throw new Error('拒绝将更新清单回退到旧版本。');
  const files = { 'latest.json': content };
  const native = release.assets.find((asset) => asset.name.endsWith('.zip') && asset.name.toLowerCase().includes('macos') && !asset.name.toLowerCase().includes('tauri'));
  if (native && compareVersions(manifest.version, '0.3.0') >= 0) files['appcast.xml'] = createAppcast(release, native, JSON.parse(publicAsset(release, native.name + '.update.json')));
  const signedAssets = release.assets.filter((asset) => tauriTargets(asset.name).length > 0).map((asset) => ({ asset, signature: publicAsset(release, asset.name + '.sig') }));
  if (signedAssets.length) files['tauri-updater.json'] = JSON.stringify(createTauriFeed(release, signedAssets), null, 2) + '\n';
  const tree = github('git/trees', { base_tree: base, tree: Object.entries(files).map(([path, content]) => ({ path, content, mode: '100644', type: 'blob' })) }, 'POST');
  if (tree.sha === base) { console.log(`清单已是 ${manifest.version}，无需重复发布。`); return; }
  const commit = github('git/commits', { message: `updates: publish ${manifest.version}`, tree: tree.sha, parents: [head] }, 'POST');
  github(`git/refs/heads/${feedBranch}`, { sha: commit.sha, force: false }, 'PATCH');
  console.log(`已同步版本清单及签名更新源 ${manifest.version}；等待 GitHub Pages 部署后验证。`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) publish();
