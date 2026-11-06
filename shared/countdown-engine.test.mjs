import assert from 'node:assert/strict';
import { nextIncomeBoundary } from './income-engine.mjs';
import { evaluateCountdowns, validateCountdowns, nextRefreshDelay, menuCountdownText } from './countdown-engine.mjs';

/** 经过 JSON 保存重载，验证倒计时配置与计算的完整链路。 */
function restored(events) { return JSON.parse(JSON.stringify(events)); }
const schedule = { weekdays: [1, 2, 3, 4, 5], start: '09:00', end: '18:00' };
const now = new Date(2026, 10, 6, 17);
const events = restored([{ id: 'a', title: '离职', type: 'fixed', targetAt: new Date(2026, 10, 8, 18).getTime(), enabled: true },
  { id: 'b', title: '下班', type: 'nextWorkEnd', enabled: true }]);
validateCountdowns(events);
let snapshots = evaluateCountdowns(events, schedule, now);
assert.equal(snapshots[0].id, 'b');
assert.equal(snapshots[0].remainingSeconds, 3600);
assert.equal(menuCountdownText(snapshots[0]), '下班 01:00:00');
assert.equal(nextRefreshDelay(snapshots, true, 'a', false), 1);
assert.equal(nextRefreshDelay(snapshots, false, null, false), null);
assert.equal(nextRefreshDelay(snapshots, false, 'a', false), 60);
assert.equal(evaluateCountdowns(events, schedule, new Date(2026, 10, 6, 18))[0].targetAt, new Date(2026, 10, 8, 18).getTime());
assert.equal(evaluateCountdowns(events.filter(e => e.id === 'b'), schedule, new Date(2026, 10, 7, 12))[0].targetAt, new Date(2026, 10, 9, 18).getTime());
assert.equal(evaluateCountdowns(events.filter(e => e.id === 'b'), { ...schedule, start: '22:00', end: '06:00' }, new Date(2026, 10, 7, 2))[0].targetAt, new Date(2026, 10, 7, 6).getTime());
assert.equal(evaluateCountdowns(events, null, now).find(s => s.id === 'b').phase, 'unavailable');
snapshots = evaluateCountdowns(events.filter(e => e.id === 'a'), null, new Date(2026, 10, 8, 18));
assert.equal(snapshots[0].phase, 'arrived');
assert.equal(nextRefreshDelay(snapshots, false, 'a', false), null);
assert.throws(() => validateCountdowns([{ ...events[0], title: ' ' }]), /标题/);
assert.throws(() => validateCountdowns([{ ...events[0], targetAt: Number.NaN }]), /时间/);
console.log('PASS: 倒计时保存重载、周末、跨夜、到达、刷新策略和无效配置');

// 日期与边界不依赖墙上时钟；离线退出后重算即可恢复。
const fixed = [events[0]];
assert.equal(evaluateCountdowns(fixed, null, new Date(events[0].targetAt - 1000))[0].remainingSeconds, 1);
assert.equal(evaluateCountdowns(fixed, null, new Date(events[0].targetAt + 1000))[0].remainingSeconds, 0);
assert.equal(evaluateCountdowns([{ ...events[0], enabled: false }], null, now).length, 0);
assert.throws(() => validateCountdowns(Array.from({length:21}, (_, i) => ({ ...events[0], id:String(i) }))), /20/);
assert.throws(() => validateCountdowns([events[0],events[0]]), /标识/);
const priorTZ = process.env.TZ;
try {
  process.env.TZ = 'America/New_York';
  const results = evaluateCountdowns(events, { ...schedule, weekdays:[0,1,2,3,4,5,6], start:'00:30', end:'01:30' }, new Date(2026,10,1,0));
  assert.equal(results.find(s => s.id === 'b').phase,'unavailable');
  assert.match(results.find(s => s.id === 'b').unavailableReason,/重复/);
  assert.equal(results.find(s => s.id === 'a').phase,'pending');
} finally { if (priorTZ == null) delete process.env.TZ; else process.env.TZ = priorTZ; }
console.log('PASS: 数量上限、重复标识、关闭项、时间校正和夏令时故障隔离');

assert.equal(nextIncomeBoundary({ ...schedule, rests:[{start:'12:00',end:'13:00'}] }, now), new Date(2026,10,6,18).getTime());
assert.equal(nextIncomeBoundary({ ...schedule, rests:[] }, new Date(2026,10,7,12)), new Date(2026,10,8,0).getTime());

const holidayNow = new Date(2026, 0, 1, 10);
const holidayEnd = evaluateCountdowns([events[1]], { ...schedule, chinaHolidayEnabled:true }, holidayNow)[0];
assert.equal(holidayEnd.targetAt, new Date(2026,0,4,18).getTime());
console.log('PASS: 下班倒计时跳过元旦长假并识别周日补班');
