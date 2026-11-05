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

/** gh 使用发布者已有认证；JSON 经标准输入传递，避免 shell 展开说明文本。 */
function github(path, body) {
  const args = ['api', `repos/${repository}/${path}`];
  if (body) args.push('--method', 'PUT', '--input', '-');
  return JSON.parse(execFileSync('gh', args, { encoding: 'utf8', input: body ? JSON.stringify(body) : undefined, maxBuffer: 5 * 1024 * 1024 }));
}

/** 发布后同步清单；预览不写入远端，版本检查及 SHA 条件写入防止回退与覆盖竞争。 */
function publish() {
  const args = process.argv.slice(2);
  if (args.some((arg) => arg !== '--dry-run')) throw new Error('用法：node scripts/publish-updates.mjs [--dry-run]');
  const manifest = createManifest(github('releases/latest'));
  const content = JSON.stringify(manifest, null, 2) + '\n';
  if (args.includes('--dry-run')) { process.stdout.write(content); return; }
  const existing = github(`contents/latest.json?ref=${encodeURIComponent(feedBranch)}`);
  const previous = JSON.parse(Buffer.from(existing.content, 'base64').toString('utf8'));
  if (compareVersions(previous.version, manifest.version) > 0) throw new Error('拒绝将更新清单回退到旧版本。');
  if (Buffer.from(existing.content, 'base64').toString('utf8') === content) { console.log(`清单已是 ${manifest.version}，无需重复发布。`); return; }
  github('contents/latest.json', { message: `updates: publish ${manifest.version}`, branch: feedBranch, sha: existing.sha, content: Buffer.from(content, 'utf8').toString('base64') });
  console.log(`已同步静态清单 ${manifest.version}；等待 GitHub Pages 部署后验证 latest.json。`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) publish();
