import { copyFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** 将唯一共享核心复制到 Tauri 的前端资源目录，兼容 macOS 与 Windows。 */
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
await copyFile(resolve(root, 'shared/income-engine.mjs'), resolve(root, 'frontend/income-engine.mjs'));
