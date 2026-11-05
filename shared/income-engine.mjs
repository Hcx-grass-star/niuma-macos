/**
 * 跨平台收入计算核心；只处理工资、排班和当前时间，不依赖窗口或系统托盘 API。
 */

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
export function workdaysInMonth(year, month, weekdays) {
  const last = new Date(year, month + 1, 0).getDate();
  let count = 0;
  for (let day = 1; day <= last; day += 1) {
    if (weekdays.includes(new Date(year, month, day).getDay())) count += 1;
  }
  return count;
}

/** 根据班次开始日期计算一个完整班次的预估收入。 */
function dailyIncome(settings, date) {
  if (settings.mode === 'daily') return Number(settings.salary);
  const divisor = settings.divisor === 'fixed'
    ? Number(settings.fixedDays)
    : workdaysInMonth(date.getFullYear(), date.getMonth(), settings.weekdays);
  return Number(settings.salary) / divisor;
}

/** 将某个排班日期展开为实际班次和休息区间。 */
function shiftForDate(date, schedule, settings) {
  if (!settings.weekdays.includes(date.getDay())) return null;
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

/** 按当前配置回算本年一月一日至指定时刻的预估收入。 */
export function yearToDateIncome(settings, now = new Date()) {
  validateSettings(settings);
  const schedule = normalizedSchedule(settings);
  const yearStart = new Date(now.getFullYear(), 0, 1);
  const firstDay = new Date(yearStart);
  firstDay.setDate(firstDay.getDate() - 1);
  const lastDay = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  let total = 0;
  for (let day = firstDay; day <= lastDay; day.setDate(day.getDate() + 1)) {
    const shift = shiftForDate(new Date(day), schedule, settings);
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
  if (!settings) return { phase: 'unconfigured', amount: null, progress: 0 };
  validateSettings(settings);
  const schedule = normalizedSchedule(settings);
  const yearToDateAmount = yearToDateIncome(settings, now);
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const candidates = [-1, 0].map((offset) => {
    const date = new Date(today);
    date.setDate(date.getDate() + offset);
    if (!settings.weekdays.includes(date.getDay())) return null;
    const start = new Date(date);
    start.setMinutes(schedule.start);
    const end = new Date(date);
    end.setMinutes(schedule.end);
    return { date, start, end };
  }).filter(Boolean);
  const active = candidates.find((shift) => now >= shift.start && now < shift.end);
  if (!active) {
    const todayShift = candidates.find((shift) => shift.date.getTime() === today.getTime());
    if (!todayShift) return { phase: 'off', amount: null, yearToDateAmount, progress: 0 };
    const daily = dailyIncome(settings, todayShift.date);
    return now < todayShift.start
      ? { phase: 'before', amount: 0, yearToDateAmount, progress: 0 }
      : { phase: 'finished', amount: daily, yearToDateAmount, progress: 1 };
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
    yearToDateAmount,
    progress: Math.max(0, Math.min(1, paidElapsed / schedule.paidMinutes)),
  };
}
