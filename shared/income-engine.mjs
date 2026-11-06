/**
 * 跨平台收入计算核心；只处理工资、排班和当前时间，不依赖窗口或系统托盘 API。
 */
import { isScheduledDate, scheduleInfo } from './holiday-calendar.mjs';

/** 将 HH:mm 转换为当天的分钟数。 */
export function minutesFromTime(value) {
  if (!/^\d{2}:\d{2}$/.test(value)) return Number.NaN;
  const [hour, minute] = value.split(':').map(Number);
  if (hour > 23 || minute > 59) return Number.NaN;
  return hour * 60 + minute;
}

/** 校验并展开班次内的休息区间。 */
export function normalizedSchedule(settings) {
  const start = minutesFromTime(settings.start);
  let end = minutesFromTime(settings.end);
  if (!Number.isFinite(start) || !Number.isFinite(end) || start === end) {
    throw new Error('上下班时间必须有效且不能相同。');
  }
  if (end < start) end += 1440;
  const rests = (settings.rests ?? []).map((rest) => {
    let restStart = minutesFromTime(rest.start);
    let restEnd = minutesFromTime(rest.end);
    if (!Number.isFinite(restStart) || !Number.isFinite(restEnd) || restStart === restEnd) {
      throw new Error('休息时段必须有效且不能相同。');
    }
    if (restStart < start) restStart += 1440;
    if (restEnd <= restStart) restEnd += 1440;
    if (restEnd > end || restStart < start) throw new Error('休息时段必须位于班次内。');
    return { start: restStart, end: restEnd };
  }).sort((a, b) => a.start - b.start);
  for (let index = 1; index < rests.length; index += 1) {
    if (rests[index - 1].end > rests[index].start) throw new Error('休息时段不能重叠。');
  }
  const paidMinutes = end - start - rests.reduce((sum, rest) => sum + rest.end - rest.start, 0);
  if (paidMinutes <= 0) throw new Error('扣除休息后，计薪时长必须大于 0。');
  return { start, end, rests, paidMinutes };
}

/** 验证跨平台设置对象，错误文本保持与原生版本一致。 */
export function validateSettings(settings) {
  if (!settings || !Number.isFinite(Number(settings.salary)) || Number(settings.salary) <= 0) {
    throw new Error('请输入大于 0、最多两位小数的工资。');
  }
  if (!/^\d+(\.\d{1,2})?$/.test(String(settings.salary))) {
    throw new Error('请输入大于 0、最多两位小数的工资。');
  }
  if (!Array.isArray(settings.weekdays) || settings.weekdays.length === 0) {
    throw new Error('请至少选择一个工作日。');
  }
  if (settings.mode === 'monthly' && settings.divisor === 'fixed' && Number(settings.fixedDays) <= 0) {
    throw new Error('请输入大于 0 的折算天数。');
  }
  normalizedSchedule(settings);
  return settings;
}

/** 统计某个月中符合排班的日期数量，星期编号使用 JavaScript 的 0 到 6。 */
export function workdaysInMonth(year, month, weekdaysOrSettings) {
  const last = new Date(year, month + 1, 0).getDate();
  const settings = Array.isArray(weekdaysOrSettings)
    ? { weekdays: weekdaysOrSettings, chinaHolidayEnabled: false }
    : weekdaysOrSettings;
  return scheduledDays(new Date(year, month, 1), last, settings);
}

/** 统计连续日期中的有效班次；启用年度安排时按日期应用覆盖规则。 */
function scheduledDays(firstDate, count, settings) {
  if (settings.chinaHolidayEnabled !== true) {
    let total = Math.floor(count / 7) * new Set(settings.weekdays).size;
    for (let offset = 0; offset < count % 7; offset += 1) {
      if (settings.weekdays.includes((firstDate.getDay() + offset) % 7)) total += 1;
    }
    return total;
  }
  let total = 0;
  for (let offset = 0; offset < count; offset += 1) {
    const date = new Date(firstDate); date.setDate(date.getDate() + offset);
    if (isScheduledDate(date, settings)) total += 1;
  }
  return total;
}

/** 根据班次开始日期计算一个完整班次的预估收入。 */
function dailyIncome(settings, date) {
  if (settings.mode === 'daily') return Number(settings.salary);
  const divisor = settings.divisor === 'fixed'
    ? Number(settings.fixedDays)
    : workdaysInMonth(date.getFullYear(), date.getMonth(), settings);
  return Number(settings.salary) / divisor;
}

/** 将某个排班日期展开为实际班次和休息区间。 */
function shiftForDate(date, schedule, settings) {
  if (!isScheduledDate(date, settings)) return null;
  const start = new Date(date);
  start.setMinutes(schedule.start);
  const end = new Date(date);
  end.setMinutes(schedule.end);
  const rests = schedule.rests.map((rest) => {
    const restStart = new Date(date);
    restStart.setMinutes(rest.start);
    const restEnd = new Date(date);
    restEnd.setMinutes(rest.end);
    return { start: restStart, end: restEnd };
  });
  return { date, start, end, rests };
}

/** 计算班次区间内扣除休息后的实际计薪毫秒数。 */
function paidMilliseconds(shift, lower, upper) {
  if (upper <= lower) return 0;
  const gross = upper.getTime() - lower.getTime();
  const unpaid = shift.rests.reduce((total, rest) => {
    const overlapStart = Math.max(lower.getTime(), rest.start.getTime());
    const overlapEnd = Math.min(upper.getTime(), rest.end.getTime());
    return total + Math.max(0, overlapEnd - overlapStart);
  }, 0);
  return Math.max(0, gross - unpaid);
}

/** 已完成班次按月汇总，仅展开跨年班和最近两天，回算本年预估收入。 */
export function yearToDateIncome(settings, now = new Date()) {
  return accruedIncome(settings, new Date(now.getFullYear(), 0, 1), now);
}

/** 按区间截断跨月班次；完整月份按排班汇总，只展开起始边界和最近两天。 */
function accruedIncome(settings, periodStart, now) {
  validateSettings(settings);
  const schedule = normalizedSchedule(settings);
  const yearStart = periodStart;
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const yesterday = new Date(today);
  yesterday.setDate(yesterday.getDate() - 1);
  let total = 0;
  for (let monthStart = new Date(periodStart); monthStart < yesterday;) {
    const monthEnd = new Date(monthStart.getFullYear(), monthStart.getMonth() + 1, 1);
    const days = monthEnd <= yesterday
      ? new Date(monthStart.getFullYear(), monthStart.getMonth() + 1, 0).getDate()
      : yesterday.getDate() - 1;
    const count = scheduledDays(monthStart, days, settings);
    if (count > 0) total += dailyIncome(settings, monthStart) * count;
    monthStart = monthEnd;
  }
  const priorYearDay = new Date(yearStart);
  priorYearDay.setDate(priorYearDay.getDate() - 1);
  for (const timestamp of new Set([priorYearDay.getTime(), yesterday.getTime(), today.getTime()])) {
    const shift = shiftForDate(new Date(timestamp), schedule, settings);
    if (!shift) continue;
    const lower = new Date(Math.max(shift.start.getTime(), yearStart.getTime()));
    const upper = new Date(Math.min(shift.end.getTime(), now.getTime()));
    const duration = shift.end.getTime() - shift.start.getTime()
      - shift.rests.reduce((sum, rest) => sum + rest.end.getTime() - rest.start.getTime(), 0);
    const paid = paidMilliseconds(shift, lower, upper);
    if (paid > 0 && duration > 0) total += dailyIncome(settings, shift.date) * paid / duration;
  }
  return total;
}

/** 根据当前时间计算收入快照；不依赖计时器累计，便于两个系统保持一致。 */
export function evaluateIncome(settings, now = new Date()) {
  if (!settings) return { phase: 'unconfigured', amount: null, yearToDateAmount: null, monthToDateAmount: null, progress: 0 };
  validateSettings(settings);
  const schedule = normalizedSchedule(settings);
  const yearToDateAmount = yearToDateIncome(settings, now);
  const monthToDateAmount = accruedIncome(settings, new Date(now.getFullYear(), now.getMonth(), 1), now);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const candidates = [-1, 0].map((offset) => {
    const date = new Date(today);
    date.setDate(date.getDate() + offset);
    if (!isScheduledDate(date, settings)) return null;
    const start = new Date(date);
    start.setMinutes(schedule.start);
    const end = new Date(date);
    end.setMinutes(schedule.end);
    return { date, start, end };
  }).filter(Boolean);
  const active = candidates.find((shift) => now >= shift.start && now < shift.end);
  if (!active) {
    const todayShift = candidates.find((shift) => shift.date.getTime() === today.getTime());
    const scheduleReason = scheduleInfo(today, settings).label;
    if (!todayShift) return { phase: 'off', amount: null, yearToDateAmount, monthToDateAmount, progress: 0, scheduleReason };
    const daily = dailyIncome(settings, todayShift.date);
    return now < todayShift.start
      ? { phase: 'before', amount: 0, yearToDateAmount, monthToDateAmount, progress: 0, scheduleReason }
      : { phase: 'finished', amount: daily, yearToDateAmount, monthToDateAmount, progress: 1, scheduleReason };
  }

  const elapsedMinutes = Math.max(0, (now - active.start) / 60000);
  const unpaidElapsed = schedule.rests.reduce((elapsed, rest) => {
    const restStart = new Date(active.date);
    restStart.setMinutes(rest.start);
    const restEnd = new Date(active.date);
    restEnd.setMinutes(rest.end);
    return elapsed + Math.max(0, Math.min(now, restEnd) - restStart) / 60000;
  }, 0);
  const paidElapsed = Math.max(0, elapsedMinutes - unpaidElapsed);
  const daily = dailyIncome(settings, active.date);
  return {
    phase: schedule.rests.some((rest) => {
      const start = new Date(active.date); start.setMinutes(rest.start);
      const end = new Date(active.date); end.setMinutes(rest.end);
      return now >= start && now < end;
    }) ? 'resting' : 'working',
    amount: daily * Math.max(0, Math.min(schedule.paidMinutes, paidElapsed)) / schedule.paidMinutes,
    yearToDateAmount, monthToDateAmount,
    progress: Math.max(0, Math.min(1, paidElapsed / schedule.paidMinutes)),
    scheduleReason: scheduleInfo(active.date, settings).label,
  };
}


/** 兼容旧托盘开关，缺少新字段时保留此前的当前收入展示选择。 */
export function menuBarContent(settings) {
  return settings?.trayContent ?? (settings?.trayIncome === true ? 'current' : 'icon');
}

/** 从同一快照选择托盘金额；隐藏金额优先于内容选择，休息日仍可显示本月累计。 */
export function menuBarPresentation(settings, snapshot) {
  const content = menuBarContent(settings);
  const label = content === 'month' ? '本月预估已赚' : '当前班次已赚';
  const amount = settings?.hidden === true || content === 'icon' ? null : content === 'month' ? snapshot.monthToDateAmount : snapshot.amount;
  return { content, label, amount: amount ?? null };
}

/** 有界枚举后续排班边界，供非计薪状态停止秒级轮询。 */
export function nextIncomeBoundary(settings, now = new Date()) {
  if (!settings) return null;
  const schedule = normalizedSchedule(settings);
  const candidates = [new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1).getTime()];
  for (let offset = -1; offset <= 7; offset += 1) {
    const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset);
    if (!isScheduledDate(day, settings)) continue;
    for (const minute of [schedule.start, schedule.end, ...schedule.rests.flatMap(r => [r.start, r.end])]) {
      const point = new Date(day); point.setMinutes(minute); candidates.push(point.getTime());
    }
  }
  return Math.min(...candidates.filter(t => t > now.getTime()));
}
