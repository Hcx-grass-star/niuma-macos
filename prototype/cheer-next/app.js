// 演示状态只驻留当前页面，不读取或写入正式工资配置。
const state = {
  // 今日示例已赚以分计，所有模拟计薪事件只累计一次。
  earned: 31250,
  // 默认愿望从本班开始累计；已有金额代表用户手动补入的预算。
  wishes: [{id: 1, name: '一副降噪耳机', target: 329900, seed: 240000, anchor: 0}],
  // 当前展示页面决定自动木鱼是否可以运行。
  tab: 'home',
  // 金额隐藏同时覆盖战报、菜单栏和愿望金额及进度。
  private: false,
  // 工作状态仅由场景模拟设置，不代表系统真实状态。
  phase: 'working',
  // 一次模拟离开只对应一个返回事件。
  locked: false,
  // 离开期间固定场景，防止返回前改变计薪口径。
  scenario: null,
  // 最近一条战报会被新战报覆盖，不建立历史库。
  report: null,
  // 木鱼计数是趣味值，与工资完全独立。
  merit: 0,
  // 编辑中的愿望标识；null 表示新建。
  editing: null,
  // 自增愿望标识不依赖集合长度，删除后不会重复。
  nextId: 2,
};
// 场景按日薪500元、8小时计薪折算，跨午休仅计10分钟。
const scenarios = {
  work: {minutes: 15, paid: 15, phase: 'working', label: '工作中返回'},
  lunch: {minutes: 20, paid: 10, phase: 'working', label: '跨午休返回（11:50–12:10，12:00 起不计薪）'},
  off: {minutes: 30, paid: 0, phase: 'finished', label: '下班后返回'},
  short: {minutes: .5, paid: .5, phase: 'working', label: '短暂返回'},
};
// 自动敲击调度句柄；每次切换条件先清除，避免重复计时。
let autoTimer = null;
// 音频上下文仅在用户主动启用音效并敲击时创建。
let audioContext = null;
// 复用格式化器，保持金额显示一致。
const formatter = new Intl.NumberFormat('zh-CN', {minimumFractionDigits: 2, maximumFractionDigits: 2});
// 根据文档标识取得唯一元素。
function el(id) { return document.getElementById(id); }
// 将整数分格式化，隐私模式不向 DOM 写入金额。
function money(cents) { return state.private ? '••••' : '¥' + formatter.format(cents / 100); }
// 计算愿望独立的预估收入进度，不将同一份工资分摊成余额。
function wishTotal(wish) { return Math.max(0, wish.seed + state.earned - wish.anchor); }
// 修改当前可见页并同步导航与自动敲击条件。
function navigate(tab) {
  state.tab = tab;
  document.querySelectorAll('.view').forEach(view => { view.hidden = view.id !== tab; });
  document.querySelectorAll('[data-tab]').forEach(button => {
    if (button.dataset.tab === tab) button.setAttribute('aria-current', 'page');
    else button.removeAttribute('aria-current');
  });
  syncAuto();
}
// 重绘所有金额入口，防止隐私切换漏掉衍生进度或旧战报。
function render() {
  el('income').textContent = money(state.earned);
  el('month').textContent = money(400000 + state.earned);
  el('year').textContent = money(10400000 + state.earned);
  el('tray-amount').textContent = money(state.earned);
  el('phase').textContent = state.phase === 'working' ? '● 工作中' : '○ 已下班';
  document.querySelector('.home-note').textContent = state.phase === 'working' ? '工作时刻演示 · 原版下班倒计时将继续保留' : '今天辛苦了，收工之后好好休息。';
  el('privacy').textContent = state.private ? '显示金额' : '隐藏金额';
  el('privacy').setAttribute('aria-pressed', String(state.private));
  el('home-wish-name').textContent = state.wishes[0]?.name || '给努力一个小目标';
  const wish = state.wishes[0];
  el('home-wish-detail').textContent = wish ? state.private ? '愿望进度已隐藏' : `${money(wishTotal(wish))} / ${money(wish.target)}` : '添加第一个愿望';
  el('home-wish-bar').style.width = wish && !state.private ? Math.min(100, wishTotal(wish) / wish.target * 100) + '%' : '0%';
  renderWishes();
  renderReport();
  syncAuto();
}
// 使用 textContent 写入用户名称，避免将愿望内容当成页面代码。
function renderWishes() {
  const list = el('wish-list');
  list.replaceChildren();
  if (!state.wishes.length) { const empty = document.createElement('p'); empty.textContent = '先放一个小愿望在这里吧。'; list.append(empty); }
  state.wishes.forEach(wish => {
    const total = wishTotal(wish);
    const done = total >= wish.target;
    const item = document.createElement('div');
    item.className = 'wish-item';
    item.innerHTML = '<div class="row"><h3></h3><span class="badge"></span></div><div class="wish-numbers"></div><div class="track"><span></span></div><div class="wish-actions"><span></span><div><button class="edit">编辑</button> · <button class="delete">删除</button></div></div>';
    item.querySelector('h3').textContent = '✦ ' + wish.name;
    item.querySelector('.badge').textContent = state.private ? '进度隐藏' : done ? '已达成 ✓' : Math.floor(total / wish.target * 100) + '%';
    item.querySelector('.wish-numbers').textContent = `${money(total)} / ${money(wish.target)}`;
    item.querySelector('.track span').style.width = state.private ? '0%' : Math.min(100, total / wish.target * 100) + '%';
    item.querySelector('.wish-actions>span').textContent = state.private ? '金额已隐藏' : done ? '预估目标达成，奖励由你决定' : '还差 ' + money(wish.target - total);
    item.querySelector('.edit').addEventListener('click', () => openWish(wish.id));
    item.querySelector('.delete').addEventListener('click', () => { state.wishes = state.wishes.filter(value => value.id !== wish.id); render(); });
    list.append(item);
  });
  el('add-wish').disabled = state.wishes.length >= 3;
  el('add-wish').setAttribute('aria-label', state.wishes.length >= 3 ? '最多三个愿望' : '新增愿望');
}
// 战报仅呈现已生成结果，短暂离开和下班不会伪造正收益。
function renderReport() {
  const report = state.report;
  if (!report) return;
  el('report-heading').textContent = '欢迎回来，辛苦了';
  el('report-amount').textContent = state.private ? '••••' : '+' + money(report.cents);
  el('report-description').textContent = `离开 ${report.minutes} 分钟，预估收入又增加了一点。`;
  el('report-meta').textContent = `计薪 ${report.paid} 分钟 · ${report.label}`;
  el('report-summary').textContent = '最近一次离开，预估增加 ' + money(report.cents);
}
// 完成一次两步离开演示；战报是收入的解释，不进行第二次累计。
function toggleLock() {
  if (!state.locked) {
    state.scenario = scenarios[el('scenario').value];
    state.locked = true;
    el('lock').textContent = '模拟解锁返回';
    el('scenario').disabled = true;
    el('advance').disabled = true;
    el('toast').hidden = true;
    el('demo-status').textContent = '已模拟离开。点击「模拟解锁返回」，一次性快进所选时长。';
  } else {
    const scene = state.scenario;
    const cents = Math.round(scene.paid * 6250 / 60);
    state.earned += cents;
    state.phase = scene.phase;
    state.locked = false;
    el('lock').textContent = '模拟锁屏离开';
    el('scenario').disabled = false;
    el('advance').disabled = false;
    if (el('reports-enabled').checked && scene.minutes >= 2 && cents > 0) {
      state.report = {...scene, cents};
      navigate('report');
      el('toast').hidden = !el('notifications').checked;
      el('demo-status').textContent = `${scene.label}：已生成一条战报，收入只累计一次。`;
    } else {
      el('demo-status').textContent = cents === 0 ? '这段时间没有计薪，不生成新战报；已有战报保留。' : '未生成新战报（短于 2 分钟或战报已关闭）；计薪部分仍计入收入。';
    }
  }
  render();
}
// 新建从当前收入建立起点；编辑不重置已有累计。
function openWish(id = null) {
  if (state.private) { el('demo-status').textContent = '请先显示金额，再添加或编辑愿望。'; return; }
  state.editing = id;
  const wish = state.wishes.find(value => value.id === id);
  el('form-title').textContent = wish ? '编辑这个小盼头' : '添加一个小盼头';
  el('wish-name').value = wish?.name || '';
  el('wish-target').value = wish ? wish.target / 100 : 1000;
  el('wish-seed').value = wish ? wish.seed / 100 : 0;
  el('form-error').textContent = '';
  el('wish-dialog').showModal();
}
// 校验愿望输入，并用同一业务口径即时更新首页和愿望页。
function saveWish(event) {
  event.preventDefault();
  const name = el('wish-name').value.trim();
  const target = Math.round(Number(el('wish-target').value) * 100);
  const seed = Math.round(Number(el('wish-seed').value) * 100);
  if (!name || !Number.isFinite(target) || target <= 0 || !Number.isFinite(seed) || seed < 0) { el('form-error').textContent = '请填写名称、正数目标和非负已有金额。'; return; }
  const existing = state.wishes.find(wish => wish.id === state.editing);
  if (existing) Object.assign(existing, {name, target, seed});
  else if (state.wishes.length < 3) state.wishes.push({id: state.nextId++, name, target, seed, anchor: state.earned});
  el('wish-dialog').close();
  render();
}
// 一次短促木鱼反馈；音效需要用户开启，不读取麦克风或系统声音。
function strike() {
  state.merit += 1;
  el('merit').textContent = state.merit;
  el('merit-pop').textContent = '功德 +1';
  el('wood-hit').classList.remove('hit');
  el('merit-pop').classList.remove('pop');
  void el('wood-hit').offsetWidth;
  el('wood-hit').classList.add('hit');
  el('merit-pop').classList.add('pop');
  if (el('sound').checked) {
    try {
      audioContext ||= new AudioContext();
      void audioContext.resume();
      const oscillator = audioContext.createOscillator();
      const gain = audioContext.createGain();
      oscillator.type = 'sine';
      oscillator.frequency.setValueAtTime(680, audioContext.currentTime);
      oscillator.frequency.exponentialRampToValueAtTime(260, audioContext.currentTime + .12);
      gain.gain.setValueAtTime(.13, audioContext.currentTime);
      gain.gain.exponentialRampToValueAtTime(.001, audioContext.currentTime + .15);
      oscillator.connect(gain).connect(audioContext.destination);
      oscillator.start(); oscillator.stop(audioContext.currentTime + .16);
    } catch { el('wood-hint').textContent = '当前浏览器无法播放音效，仍可继续敲击。'; }
  }
}
// 自动敲击随页面、工作状态与可见性停止，不在后台维持循环。
function syncAuto() {
  clearInterval(autoTimer);
  autoTimer = null;
  const active = el('auto-wood').checked && state.phase === 'working' && state.tab === 'wood' && !document.hidden && !el('panel').hidden && !state.locked;
  if (active) autoTimer = setInterval(strike, 1500);
  el('wood-hint').textContent = active ? '上班自动敲击中 · 每 1.5 秒一下' : el('auto-wood').checked ? '自动敲击已暂停 · 仅在工作中打开此页时运行' : '点击木鱼或聚焦后按空格敲击';
}
// 事件统一绑定到演示控件，不调用正式应用或系统锁屏接口。
document.querySelectorAll('[data-tab]').forEach(button => button.addEventListener('click', () => navigate(button.dataset.tab)));
document.querySelectorAll('[data-jump]').forEach(button => button.addEventListener('click', () => navigate(button.dataset.jump)));
el('privacy').addEventListener('click', () => { state.private = !state.private; el('demo-status').textContent = state.private ? '金额与愿望进度已隐藏。' : '金额已恢复显示。'; render(); });
el('theme').addEventListener('click', () => document.documentElement.classList.toggle('dark'));
el('lock').addEventListener('click', toggleLock);
el('advance').addEventListener('click', () => { state.earned += 3125; state.phase = 'working'; render(); el('demo-status').textContent = `已快进计薪 30 分钟，预估收入增加 ${money(3125)}；各愿望独立更新。`; });
el('reset').addEventListener('click', () => location.reload());
el('add-wish').addEventListener('click', () => openWish());
el('cancel-wish').addEventListener('click', () => el('wish-dialog').close());
el('wish-form').addEventListener('submit', saveWish);
el('wood-hit').addEventListener('click', strike);
el('auto-wood').addEventListener('change', syncAuto);
el('toast-close').addEventListener('click', () => { el('toast').hidden = true; });
el('tray').addEventListener('click', () => { el('panel').hidden = !el('panel').hidden; syncAuto(); });
document.addEventListener('visibilitychange', syncAuto);
render();
