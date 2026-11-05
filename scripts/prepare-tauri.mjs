import { execFileSync } from 'node:child_process';
import { mkdir, copyFile, chmod } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import './sync-frontend-core.mjs';

/** 仅 macOS 正式打包需要共享安装助手；Windows 由原生安装器负责覆盖旧版。 */
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
if (process.platform === 'darwin') {
  const flags = ['--package-path', root, '-c', 'release', '--arch', 'arm64', '--arch', 'x86_64'];
  execFileSync('swift', ['build', ...flags, '--disable-automatic-resolution', '--product', 'NiumaInstaller'], { stdio: 'inherit' });
  const binary = execFileSync('swift', ['build', ...flags, '--show-bin-path'], { encoding: 'utf8' }).trim();
  const target = resolve(root, 'build/NiumaInstaller');
  await mkdir(resolve(root, 'build'), { recursive: true });
  await copyFile(resolve(binary, 'NiumaInstaller'), target);
  await chmod(target, 0o755);
  execFileSync('codesign', ['--force', '--sign', process.env.DEVELOPER_ID_APP ?? '-', '--identifier', 'com.hcxgrassstar.niuma.installer', target], { stdio: 'inherit' });
}
