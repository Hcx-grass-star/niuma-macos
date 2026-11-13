import holidayData from './holiday-data.mjs';

/** 将本地日期格式化为年度安排使用的 ISO 日期键。 */
export function dateKey(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

/** 返回指定年份的内置年度安排；未发布或未内置时返回空。 */
export function annualHolidaySchedule(year) { return holidayData[String(year)] ?? null; }

/** 返回日期的全国安排及可见说明，不开启时只保留每周排班依据。 */
export function scheduleInfo(date, settings) {
  if (settings?.chinaHolidayEnabled !== true) return { kind: 'weekly', label: '按每周排班' };
  const annual = annualHolidaySchedule(date.getFullYear());
  if (!annual) return { kind: 'missing', label: `${date.getFullYear()} 年安排缺失，按每周排班` };
  return annual.days[dateKey(date)] ?? { kind: 'weekly', label: '按每周排班' };
}

/** 判断日期是否创建班次：全国安排覆盖每周排班，未覆盖日期沿用每周排班。 */
export function isScheduledDate(date, settings) {
  const info = scheduleInfo(date, settings);
  if (info.kind === 'holiday') return false;
  if (info.kind === 'makeup') return true;
  return settings.weekdays.includes(date.getDay());
}

/** 返回开关开启后当前年份是否有可用年度数据。 */
export function holidayDataStatus(year, enabled) {
  if (!enabled) return { available: true, message: '' };
  const annual = annualHolidaySchedule(year);
  return annual
    ? { available: true, message: `已内置${year}年全国节假日及调休安排` }
    : { available: false, message: `${year}年全国安排尚未内置，将按每周排班计算` };
}
