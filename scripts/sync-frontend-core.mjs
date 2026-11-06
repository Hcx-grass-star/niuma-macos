import { copyFile, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** 将唯一共享核心复制到 Tauri 的前端资源目录，兼容 macOS 与 Windows。 */
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
/** 从同一份年度 JSON 生成普通 ES 模块，兼容不支持 JSON 模块的 WebView。 */
const holidayJSON = await readFile(resolve(root, 'shared/china-holidays.json'), 'utf8');
const holidayData = JSON.parse(holidayJSON);
await writeFile(resolve(root, 'shared/holiday-data.mjs'), '/** 由 sync:frontend 从 china-holidays.json 生成，请修改原始 JSON。 */\nexport default ' + JSON.stringify(holidayData, null, 2) + ';\n', 'utf8');
await copyFile(resolve(root, 'shared/holiday-data.mjs'), resolve(root, 'frontend/holiday-data.mjs'));
await copyFile(resolve(root, 'shared/china-holidays.json'), resolve(root, 'Sources/NiumaCore/Resources/china-holidays.json'));
await copyFile(resolve(root, 'shared/countdown-engine.mjs'), resolve(root, 'frontend/countdown-engine.mjs'));
await copyFile(resolve(root, 'shared/income-engine.mjs'), resolve(root, 'frontend/income-engine.mjs'));
await copyFile(resolve(root, 'shared/holiday-calendar.mjs'), resolve(root, 'frontend/holiday-calendar.mjs'));
await copyFile(resolve(root, 'shared/china-holidays.json'), resolve(root, 'frontend/china-holidays.json'));
await copyFile(resolve(root, 'shared/update-check.mjs'), resolve(root, 'frontend/update-check.mjs'));
/** 浏览器预览版本来自项目清单；Tauri 正式运行使用应用包的真实版本。 */
const { version } = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'));
await writeFile(resolve(root, 'frontend/app-version.json'), JSON.stringify({ version }) + '\n', 'utf8');
