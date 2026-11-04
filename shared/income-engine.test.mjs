import assert from 'node:assert/strict';
import { evaluateIncome, normalizedSchedule, validateSettings } from './income-engine.mjs';

/** 创建跨平台测试使用的默认工资设置。 */
function settings(overrides = {}) {
  return {
    mode: 'monthly', salary: 21000, weekdays: [1, 2, 3, 4, 5],
    start: '09:00', end: '18:00', rests: [{ start: '12:00', end: '13:00' }],
    divisor: 'schedule', fixedDays: 22, ...overrides,
  };
}

/** 构造本地时间，避免测试依赖运行机器的当前时刻。 */
function localDate(day, hour, minute = 0) {
  return new Date(2026, 10, day, hour, minute, 0, 0);
}

/** 验证核心计算在 Tauri 前端和 macOS 迁移前保持可重复。 */
function run() {
  assert.equal(evaluateIncome(settings(), localDate(4, 12)).phase, 'resting');
  assert.equal(evaluateIncome(settings(), localDate(4, 12)).amount, 375);
  assert.equal(evaluateIncome(settings(), localDate(4, 12, 30)).amount, 375);
  assert.equal(Math.round(evaluateIncome(settings(), localDate(4, 14)).amount * 100) / 100, 500);
  assert.equal(Math.round(evaluateIncome(settings(), localDate(4, 14)).yearToDateAmount * 100) / 100, 212500);
  assert.equal(evaluateIncome(settings(), localDate(4, 8)).amount, 0);
  assert.equal(evaluateIncome(settings(), localDate(4, 20)).amount, 1000);
  const offDay = evaluateIncome(settings(), localDate(8, 14));
  assert.equal(offDay.phase, 'off');
  assert.equal(Math.round(offDay.yearToDateAmount * 100) / 100, 215000);
  assert.throws(() => validateSettings(settings({ weekdays: [] })), /至少选择一个工作日/);
  assert.throws(() => normalizedSchedule(settings({ rests: [{ start: '08:00', end: '09:30' }] })), /位于班次内/);
  console.log('跨平台收入核心测试通过。');
}

run();
