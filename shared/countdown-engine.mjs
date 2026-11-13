import { isScheduledDate } from './holiday-calendar.mjs';
/** 删除已启用且到期的固定事件；无变化时复用原配置，避免周期写入。 */
export function removeCompletedCountdowns(preferences, now = new Date()) {
  const events = preferences.events.filter(event => !(event.enabled && event.type === 'fixed' && event.targetAt <= now.getTime()));
  if (events.length === preferences.events.length) return preferences;
  const removedPrimary = preferences.events.some(e => e.id === preferences.menuCountdownID) && !events.some(e => e.id === preferences.menuCountdownID);
  return { ...preferences, events, menuCountdownID: removedPrimary ? null : preferences.menuCountdownID };
}
/** 与 Swift 保持一致的纯时间核心；不创建定时器、不访问存储。 */
export function validateCountdowns(events) {
  if (!Array.isArray(events) || events.length > 20 || new Set(events.map(e => e.id)).size !== events.length) throw new Error('最多添加 20 条倒计时，且标识不能重复。');
  for (const event of events) {
    if (typeof event.id !== 'string' || !event.id || typeof event.title !== 'string' || !event.title.trim() || [...event.title].length > 32 || /[\r\n]/.test(event.title)) throw new Error('倒计时标题须为 1–32 个字符，且不能换行。');
    if (!['fixed', 'nextWorkEnd'].includes(event.type) || typeof event.enabled !== 'boolean') throw new Error('倒计时规则无效。');
    if (event.type === 'fixed' && (!Number.isFinite(event.targetAt) || event.targetAt < 0 || event.targetAt > 253402214400000)) throw new Error('请选择有效的目标时间（1970–9999 年）。');
  }
}
/** 严格解释排班时间，拒绝夏令时跳时和重复时刻。 */
function localEnd(day, minute) {
  const target = new Date(day.getFullYear(), day.getMonth(), day.getDate() + Math.floor(minute / 1440), Math.floor(minute % 1440 / 60), minute % 60);
  if (target.getHours() !== Math.floor(minute % 1440 / 60) || target.getMinutes() !== minute % 60) throw new Error('下班时间涉及不存在的本地时刻，请调整作息。');
  for (const offset of [-120, -60, -30, 30, 60, 120]) {
    const other = new Date(target.getTime() + offset * 60000);
    if (other.getFullYear() === target.getFullYear() && other.getMonth() === target.getMonth() && other.getDate() === target.getDate() && other.getHours() === target.getHours() && other.getMinutes() === target.getMinutes()) throw new Error('下班时间涉及重复的本地时刻，请调整作息。');
  }
  return target.getTime();
}
/** 有界枚举昨日到下周，跨夜班以班次开始日判断是否上班。 */
function nextWorkEnd(settings, now) {
  if (!settings) return null;
  const start = Number(settings.start.slice(0, 2)) * 60 + Number(settings.start.slice(3));
  let end = Number(settings.end.slice(0, 2)) * 60 + Number(settings.end.slice(3));
  if (end < start) end += 1440;
  for (let offset = -1; offset <= 366; offset += 1) {
    const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset);
    if (!isScheduledDate(day, settings)) continue;
    const target = localEnd(day, end);
    if (target > now.getTime()) return target;
  }
  return null;
}
/** 过滤关闭项，重新求差值，不依赖应用持续运行。 */
export function evaluateCountdowns(events, settings, now = new Date()) {
  let nextEnd = null;
  let unavailableReason = null;
  if (events.some(e => e.enabled && e.type === 'nextWorkEnd')) {
    try { nextEnd = nextWorkEnd(settings, now); }
    catch (error) { unavailableReason = error.message; }
  }
  return events.filter(e => e.enabled).map(event => {
    const targetAt = event.type === 'fixed' ? event.targetAt : nextEnd;
    const remainingSeconds = targetAt == null ? 0 : Math.max(0, Math.ceil((targetAt - now.getTime()) / 1000));
    return { ...event, targetAt, remainingSeconds, unavailableReason: event.type === 'nextWorkEnd' ? unavailableReason : null, phase: targetAt == null ? 'unavailable' : remainingSeconds > 0 ? 'pending' : 'arrived' };
  }).sort((a, b) => Number(a.phase !== 'pending') - Number(b.phase !== 'pending') || (a.targetAt ?? Infinity) - (b.targetAt ?? Infinity) || a.id.localeCompare(b.id));
}
/** 展示分钟或秒，始终使用等宽数字格式。 */
export function countdownText(snapshot) {
  if (snapshot.phase !== 'pending') return snapshot.phase === 'arrived' ? '已到达' : snapshot.unavailableReason ?? '请先设置作息';
  const seconds = snapshot.remainingSeconds;
  const clock = `${String(Math.floor(seconds % 86400 / 3600)).padStart(2, '0')}:${String(Math.floor(seconds % 3600 / 60)).padStart(2, '0')}`;
  return seconds >= 86400 ? `${Math.floor(seconds / 86400)}天 ${clock}` : `${clock}:${String(seconds % 60).padStart(2, '0')}`;
}
/** 菜单栏按剩余天数向上取整，临近一天时显示时分秒。 */
export function menuCountdownText(snapshot) {
  return `${snapshot.title} ${snapshot.phase === 'pending' && snapshot.remainingSeconds >= 86400 ? `${Math.ceil(snapshot.remainingSeconds / 86400)}天` : countdownText(snapshot)}`;
}
/** 可见输出按需刷新，隐藏固定目标只在到期唤醒；始终复用统一任务。 */
export function nextRefreshDelay(snapshots, panelVisible, menuID, incomeActive) {
  if (incomeActive) return 1;
  const delays = snapshots.filter(s => s.phase === 'pending' && (panelVisible || s.id === menuID)).map(s => s.remainingSeconds <= 86400 ? 1 : Math.min(60, s.remainingSeconds - 86400));
  delays.push(...snapshots.filter(s => s.phase === 'pending' && s.type === 'fixed').map(s => s.remainingSeconds));
  return delays.length ? Math.min(...delays) : null;
}
