import assert from 'node:assert/strict';
import { emptyCheer, projectedEarned, settleCheer, shouldAutoWood, validateCheer, wishTotal } from './cheer-engine.mjs';

/** 构造打气核心测试使用的日薪配置。 */
function settings() {
  return { mode: 'daily', salary: 800, weekdays: [0, 1, 2, 3, 4, 5, 6], start: '09:00', end: '18:00', rests: [{ start: '12:00', end: '13:00' }], divisor: 'schedule', fixedDays: 22, chinaHolidayEnabled: false };
}

/** 固定本地时间，避免测试依赖当前日期。 */
function local(day, hour, minute = 0) { return new Date(2026, 10, day, hour, minute); }

/** 验证愿望的创建起点、累计进度和隐私前的原始金额。 */
function testWishProgress() {
  const base = emptyCheer();
  const saved = settleCheer(base, settings(), local(4, 9));
  saved.wishes = [{ id: 'wish', name: '休息日', target: 100, seed: 0, baseline: 0 }];
  validateCheer(saved);
  assert.equal(Math.round(wishTotal(saved, saved.wishes[0], settings(), local(4, 10))), 100);
  assert.equal(Math.round(projectedEarned(saved, settings(), local(4, 12, 30))), 300);
}

/** 验证自动木鱼只在工作、可见且未离开时生效。 */
function testWoodPolicy() {
  assert.equal(shouldAutoWood(true, 'working', true, false), true);
  assert.equal(shouldAutoWood(true, 'resting', true, false), false);
  assert.equal(shouldAutoWood(true, 'working', false, false), false);
  assert.equal(shouldAutoWood(true, 'working', true, true), false);
}

testWishProgress();
testWoodPolicy();
console.log('打气核心测试通过。');
