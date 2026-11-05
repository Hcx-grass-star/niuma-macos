import { copyFile, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** 将唯一共享核心复制到 Tauri 的前端资源目录，兼容 macOS 与 Windows。 */
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await copyFile(resolve(root, 'shared/income-engine.mjs'), resolve(root, 'frontend/income-engine.mjs'));
await copyFile(resolve(root, 'shared/update-check.mjs'), resolve(root, 'frontend/update-check.mjs'));
/** 浏览器预览版本来自项目清单；Tauri 正式运行使用应用包的真实版本。 */
const { version } = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
await writeFile(resolve(root, 'frontend/app-version.json'), JSON.stringify({ version }) + '\n', 'utf8');
