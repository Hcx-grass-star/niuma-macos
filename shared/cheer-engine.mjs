import { earnedBetween } from './income-engine.mjs';

/** 打气功能的独立存储版本，避免修改工资配置格式。 */
export const CHEER_VERSION = 1;

/** 创建首次使用的打气配置，不生成示例愿望或收入。 */
export function emptyCheer() {
  return { version: CHEER_VERSION, wishes: [], reportsEnabled: false, notificationsEnabled: true, autoWood: false, sound: false, earned: 0, checkpoint: null, work: null, timeZone: null };
}

/** 判断两份工资规则是否会改变区间收入结果。 */
export function sameIncomeRules(left, right) {
  if (!left || !right) return left === right;
  return JSON.stringify({ mode: left.mode, salary: left.salary, weekdays: [...left.weekdays].sort(), start: left.start, end: left.end, rests: left.rests, divisor: left.divisor, fixedDays: left.fixedDays, chinaHolidayEnabled: left.chinaHolidayEnabled })
    === JSON.stringify({ mode: right.mode, salary: right.salary, weekdays: [...right.weekdays].sort(), start: right.start, end: right.end, rests: right.rests, divisor: right.divisor, fixedDays: right.fixedDays, chinaHolidayEnabled: right.chinaHolidayEnabled });
}

/** 校验金额精度，拒绝 NaN、负数和超过两位小数的输入。 */
function validMoney(value, positive = false) {
  const amount = Number(value);
  return Number.isFinite(amount) && amount >= 0 && amount <= 99999999 && (!positive || amount > 0) && /^\d+(\.\d{1,2})?$/.test(String(value));
}

/** 校验打气配置，错误文本不包含用户工资或隐私数据。 */
export function validateCheer(value) {
  if (!value || value.version !== CHEER_VERSION || !Array.isArray(value.wishes) || value.wishes.length > 3 || value.earned < 0) throw new Error('打气配置格式无效。');
  const ids = new Set();
  for (const wish of value.wishes) {
    if (!wish.id || ids.has(wish.id) || !String(wish.name ?? '').trim() || [...wish.name].length > 20 || /[\r\n]/.test(wish.name)
      || !validMoney(wish.target, true) || !validMoney(wish.seed) || !Number.isFinite(Number(wish.baseline)) || wish.baseline < 0 || wish.baseline > value.earned) {
      throw new Error('愿望名称须为1–20字；目标须大于0，已有金额不能为负，金额最多两位小数且不超过99,999,999元。');
    }
    ids.add(wish.id);
  }
  return value;
}

/** 读取存储中的累计值并补算到当前时刻，但不在每秒刷新时写盘。 */
export function projectedEarned(value, settings, now = new Date()) {
  if (!value?.wishes?.length || !value.checkpoint || !value.work || !sameIncomeRules(value.work, settings) || value.timeZone !== Intl.DateTimeFormat().resolvedOptions().timeZone) return Number(value?.earned ?? 0);
  return Number(value.earned ?? 0) + earnedBetween(value.work, new Date(value.checkpoint), now);
}

/** 在工资规则生效点结算旧配置，并建立新的检查点。 */
export function settleCheer(value, settings, now = new Date()) {
  const next = structuredClone(value ?? emptyCheer());
  if (next.wishes.length && next.checkpoint && next.work && sameIncomeRules(next.work, settings) && next.timeZone === Intl.DateTimeFormat().resolvedOptions().timeZone && now > new Date(next.checkpoint)) {
    next.earned = Number(next.earned) + earnedBetween(next.work, new Date(next.checkpoint), now);
  }
  next.checkpoint = now.toISOString();
  next.work = settings ? structuredClone(settings) : null;
  next.timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  validateCheer(next);
  return next;
}

/** 返回愿望当前累计金额；每个愿望独立展示同一份新增收入。 */
export function wishTotal(value, wish, settings, now = new Date()) {
  return Math.max(0, Number(wish.seed) + projectedEarned(value, settings, now) - Number(wish.baseline));
}

/** 返回是否允许自动敲击木鱼。 */
export function shouldAutoWood(enabled, phase, visible, away) {
  return enabled && phase === 'working' && visible && !away;
}
