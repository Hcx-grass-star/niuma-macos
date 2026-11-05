import { execFileSync } from 'node:child_process';
import { readFile, writeFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

/** 公钥写入应用；私钥只在发布机器的受限目录中读取，不复制到安装包。 */
const keyRoot = resolve(homedir(), 'Library/Application Support/niuma-release-keys');
/** 使用已锁定并由 SwiftPM 校验的 Sparkle 签名工具。 */
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
/** 签名绑定当前正式版本，避免不同发布版本的构建产物混用。 */
const { version } = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));

for (const argument of process.argv.slice(2)) {
  const file = resolve(argument);
  if (!basename(file).includes(version)) throw new Error('安装包文件名与当前版本不符，拒绝签名。');
  if (file.endsWith('.zip') && !basename(file).includes('tauri')) {
    const key = resolve(keyRoot, 'sparkle-ed25519.key');
    if ((await stat(key)).mode & 0o077) throw new Error('发布私钥权限必须为 600。');
    const tool = resolve(root, '.build/artifacts/sparkle/Sparkle/bin/sign_update');
    // ditto 的 ZIP 文件名可能未标 UTF-8；按包内身份匹配，避免终端替换中文名后误判。
    const infos = JSON.parse(execFileSync('python3', ['-c', `import zipfile,plistlib,sys,json
with zipfile.ZipFile(sys.argv[1]) as archive:
    infos = [plistlib.loads(archive.read(name)) for name in archive.namelist() if name.endswith('.app/Contents/Info.plist') and not name.startswith('__MACOSX/')]
print(json.dumps([info for info in infos if info.get('CFBundleIdentifier') == 'com.hcxgrassstar.niuma']))`, file], { encoding: 'utf8' }));
    if (infos.length !== 1) throw new Error('更新包必须包含唯一正式应用。');
    const info = infos[0];
    const publicKey = (await readFile(resolve(keyRoot, 'sparkle-ed25519.pub'), 'utf8')).trim();
    if (info.CFBundleIdentifier !== 'com.hcxgrassstar.niuma' || info.CFBundleShortVersionString !== version || info.SUPublicEDKey !== publicKey) throw new Error('应用身份、版本或更新公钥与发布配置不符。');
    const signature = execFileSync(tool, ['--ed-key-file', key, '-p', file], { encoding: 'utf8' }).trim();
    execFileSync(tool, ['--ed-key-file', key, '--verify', file, signature], { stdio: 'pipe' });
    await writeFile(file + '.update.json', JSON.stringify({ version, build: info.CFBundleVersion, length: (await stat(file)).size, signature }, null, 2) + '\n', 'utf8');
  } else if (/\.(exe|msi)$/.test(file) || file.endsWith('.app.tar.gz')) {
    const key = resolve(keyRoot, 'tauri.key');
    if ((await stat(key)).mode & 0o077) throw new Error('发布私钥权限必须为 600。');
    execFileSync(resolve(root, 'node_modules/.bin/tauri'), ['signer', 'sign', '--private-key-path', key, '--password', '', '--app-version', version, file], { stdio: 'pipe' });
  } else { throw new Error('不支持的更新包格式。'); }
  console.log('已签名并生成公开校验信息：' + basename(file));
}
