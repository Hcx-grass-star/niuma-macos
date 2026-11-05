import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { evaluateIncome } from '../shared/income-engine.mjs';

/** 使用上海本地时区比较 Swift 与 JS 的月初、跨月、跨年及节假日结果。 */
process.env.TZ = 'Asia/Shanghai';
const root = fileURLToPath(new URL('../', import.meta.url));
const result = spawnSync('swift', ['run', '--disable-automatic-resolution', 'NiumaIntegrationTests', '--month-fixtures'], { cwd: root, encoding: 'utf8' });
assert.equal(result.status, 0, result.stderr);
const swiftRows = JSON.parse(result.stdout);
const points = [[2026, 1, 4, 14], [2026, 2, 1, 2], [2026, 11, 4, 14], [2026, 12, 31, 23], [2027, 1, 1, 2], [2024, 3, 1, 0]];
let checked = 0;
for (let profile = 0; profile < 4; profile += 1) {
  const settings = { mode: 'monthly', salary: 21000, weekdays: [1, 2, 3, 4, 5], start: '09:00', end: '18:00', rests: [{ start: '12:00', end: '13:00' }], divisor: 'schedule', fixedDays: 22 };
  if (profile === 1) Object.assign(settings, { salary: 31000, weekdays: [0, 1, 2, 3, 4, 5, 6], start: '22:00', end: '06:00', rests: [] });
  if (profile === 2) settings.chinaHolidayEnabled = true;
  if (profile === 3) settings.divisor = 'fixed';
  for (const [index, point] of points.entries()) {
    const snapshot = evaluateIncome(settings, new Date(point[0], point[1] - 1, point[2], point[3]));
    const expected = swiftRows.find((row) => row.id === `${profile}:${index}`);
    assert.ok(expected);
    assert.ok(Math.abs(snapshot.monthToDateAmount - expected.month) < 0.000001, `本月结果不同 ${profile}:${index}`);
    assert.ok(Math.abs(snapshot.yearToDateAmount - expected.year) < 0.000001, `本年结果不同 ${profile}:${index}`);
    checked += 1;
  }
}
assert.equal(checked, swiftRows.length);
console.log(`PASS: Swift / JS ${checked} 组受控配置与时间的本月和本年结果一致。`);
