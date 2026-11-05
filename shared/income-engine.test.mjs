import assert from 'node:assert/strict';
import { evaluateIncome, normalizedSchedule, validateSettings, menuBarContent, menuBarPresentation } from './income-engine.mjs';
import { holidayDataStatus, scheduleInfo } from './holiday-calendar.mjs';

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

/** 以显示精度比较年度金额，覆盖计算误差之外的业务边界。 */
function annualAmount(config, now) {
  return Number(evaluateIncome(config, now).yearToDateAmount?.toFixed(2));
}

/** 验证年初截断、跨年休息、闰年、月薪折算与修改配置后的回算。 */
function testAnnualBoundaries() {
  const daily = settings({ mode: 'daily', salary: 800 });
  for (const [hour, minute, expected] of [[0, 0, 0], [12, 0, 300], [12, 30, 300], [18, 0, 800]]) {
    assert.equal(annualAmount(daily, new Date(2026, 0, 1, hour, minute)), expected);
  }
  const everyDay = settings({ weekdays: [0, 1, 2, 3, 4, 5, 6], salary: 31000 });
  assert.equal(annualAmount(everyDay, new Date(2026, 1, 1, 14)), 31553.57);
  assert.equal(annualAmount({ ...everyDay, mode: 'daily', salary: 800 }, new Date(2024, 2, 1, 9)), 48000);
  const overnight = { ...everyDay, start: '22:00', end: '06:00', rests: [] };
  assert.equal(annualAmount(overnight, new Date(2026, 0, 1)), 0);
  const snapshot = evaluateIncome(overnight, new Date(2026, 0, 1, 2));
  assert.equal(snapshot.amount, 500);
  assert.equal(snapshot.yearToDateAmount, 250);
  assert.equal(annualAmount({ ...overnight, rests: [{ start: '00:00', end: '01:00' }] }, new Date(2026, 0, 1, 0, 30)), 0);
  assert.equal(annualAmount(settings({ salary: 22000, divisor: 'fixed' }), new Date(2026, 0, 2, 14)), 1500);
  assert.equal(annualAmount(settings({ salary: 42000 }), localDate(4, 14)), 425000);
  assert.equal(evaluateIncome(null).yearToDateAmount, null);
}

/** 验证 2026 官方安排覆盖放假日、补班日和月薪自动折算，并验证 2027 缺失回退。 */
function testChinaHolidaySchedule() {
  const enabled = settings({ chinaHolidayEnabled: true });
  assert.equal(scheduleInfo(new Date(2026, 0, 1), enabled).kind, 'holiday');
  assert.equal(evaluateIncome(enabled, new Date(2026, 0, 1, 14)).phase, 'off');
  assert.equal(scheduleInfo(new Date(2026, 0, 4), enabled).kind, 'makeup');
  assert.equal(evaluateIncome(enabled, new Date(2026, 0, 4, 14)).phase, 'working');
  assert.equal(evaluateIncome(enabled, new Date(2026, 0, 4, 14)).amount, 500);
  assert.equal(evaluateIncome(enabled, new Date(2026, 1, 16, 14)).phase, 'off');
  assert.equal(evaluateIncome(enabled, new Date(2026, 0, 5, 14)).amount, 500);
  assert.equal(holidayDataStatus(2027, true).available, false);
  assert.equal(scheduleInfo(new Date(2027, 0, 1), enabled).kind, 'missing');
  assert.equal(evaluateIncome(enabled, new Date(2027, 0, 1, 14)).phase, 'working');
  assert.equal(evaluateIncome({ ...enabled, chinaHolidayEnabled: false }, new Date(2026, 0, 1, 14)).phase, 'working');
}

/** 验证本月区间截断、菜单栏指标切换、休息日累计与旧开关兼容。 */
function testMonthIncome() {
  const config = settings();
  const snapshot = evaluateIncome(config, localDate(4, 14));
  assert.equal(snapshot.monthToDateAmount, 2500);
  assert.equal(evaluateIncome(config, localDate(4, 12)).monthToDateAmount, 2375);
  assert.equal(evaluateIncome(config, localDate(4, 12, 30)).monthToDateAmount, 2375);
  assert.equal(evaluateIncome(config, localDate(4, 18)).monthToDateAmount, 3000);
  assert.equal(evaluateIncome(settings({ salary: 42000 }), localDate(4, 14)).monthToDateAmount, 5000);
  assert.equal(evaluateIncome(settings({ mode: 'daily', salary: 800 }), localDate(4, 14)).monthToDateAmount, 2000);
  assert.equal(evaluateIncome(settings({ divisor: 'fixed' }), localDate(4, 14)).monthToDateAmount.toFixed(2), '2386.36');
  assert.equal(menuBarPresentation({ ...config, trayContent: 'month' }, snapshot).amount, 2500);
  assert.equal(menuBarPresentation({ ...config, trayContent: 'current' }, snapshot).amount, 500);
  assert.equal(menuBarPresentation({ ...config, trayContent: 'icon' }, snapshot).amount, null);
  assert.equal(menuBarPresentation({ ...config, trayContent: 'month', hidden: true }, snapshot).amount, null);
  assert.equal(menuBarContent({ trayIncome: true }), 'current');
  assert.equal(menuBarContent({ trayIncome: false }), 'icon');
  const off = evaluateIncome(config, localDate(8, 14));
  assert.equal(menuBarPresentation({ ...config, trayContent: 'month' }, off).amount, 5000);
  assert.equal(menuBarPresentation({ ...config, trayContent: 'current' }, off).amount, null);
  const night = settings({ weekdays: [0, 1, 2, 3, 4, 5, 6], salary: 31000, start: '22:00', end: '06:00', rests: [] });
  assert.equal(evaluateIncome(night, new Date(2026, 1, 1, 2)).monthToDateAmount, 250);
  assert.equal(evaluateIncome(night, new Date(2026, 1, 1)).monthToDateAmount, 0);
  assert.equal(evaluateIncome(night, new Date(2026, 0, 1, 2)).monthToDateAmount, 250);
  const leap = settings({ mode: 'daily', salary: 800, weekdays: [0, 1, 2, 3, 4, 5, 6] });
  assert.equal(evaluateIncome(leap, new Date(2024, 1, 29, 18)).monthToDateAmount, 23200);
  assert.equal(evaluateIncome(settings({ chinaHolidayEnabled: true }), new Date(2026, 0, 4, 14)).monthToDateAmount, 500);
  assert.equal(evaluateIncome(null).monthToDateAmount, null);
}

/** 验证核心计算在 Tauri 前端和 macOS 迁移前保持可重复。 */
function run() {
  assert.equal(evaluateIncome(settings(), localDate(4, 14)).monthToDateAmount, 2500);
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
  testAnnualBoundaries();
  testChinaHolidaySchedule();
  testMonthIncome();
  console.log('跨平台收入核心测试通过。');
}

run();
