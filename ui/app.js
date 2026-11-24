const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const content = document.querySelector("#content");
const dialog = document.querySelector("#details");
const number = new Intl.NumberFormat("zh-CN");
const date = new Intl.DateTimeFormat("zh-CN", {
  month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
});
const fullDate = new Intl.DateTimeFormat("zh-CN", {
  year: "numeric", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
});
const status = {
  localLive: "本地统计", calibrated: "官方校准", partiallyCalibrated: "部分校准",
  stale: "数据可能已过期", unavailable: "暂无数据",
};
const styles = { aurora: "极光卡片", orbit: "环形仪表" };
let style = "aurora";
let view = "overview";
let state = { snapshot: null, message: null, refreshing: true };
let selection = null;
let selectedDay = null;
let hasModelRows = false;

function escape(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;").replaceAll("'", "&#39;");
}

function compact(value) {
  const magnitude = Math.abs(value);
  if (magnitude < 10_000) return String(value);
  const large = magnitude >= 100_000_000;
  const tenths = Math.round(magnitude / (large ? 10_000_000 : 1000));
  return `${value < 0 ? "-" : ""}${(tenths / 10).toFixed(1)}${large ? "亿" : "万"}`;
}

function percentage(value) {
  if (value == null) return "—";
  if (value > 0 && value < 0.1) return "<0.1%";
  return `${Number(value.toFixed(1))}%`;
}

const time = (value, full = false) => (full ? fullDate : date).format(value * 1000);
const shortDay = (value) => value.slice(5).split("-").map(Number).join("/");
const shortDate = (value) => {
  const local = new Date(value * 1000);
  return `${local.getMonth() + 1}/${local.getDate()}`;
};
const remainingQuota = (quota) => quota ? Math.max(0, Math.min(100, 100 - quota.usedPercent)) : 0;
const cycles = (snapshot) => [snapshot.currentCycle, ...snapshot.cycleHistory].filter(Boolean);

function countdown(resetsAt, clock) {
  const seconds = resetsAt - clock;
  if (seconds <= 0) return "重置时间已过，等待新额度";
  if (seconds < 60) return "即将重置";
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);
  if (days) return `${days} 天${hours % 24 ? ` ${hours % 24} 小时` : ""}后重置`;
  return hours ? `${hours} 小时后重置` : `${minutes} 分钟后重置`;
}

function usageMetrics(usage) {
  const values = [["输入", usage.inputTokens], ["其中缓存", usage.cachedInputTokens], ["输出", usage.outputTokens]];
  return `<div class="metrics">${values.map(([label, value]) => `
    <div class="metric" title="${number.format(value)} Token"><span>${label}</span><strong>${compact(value)}</strong></div>`).join("")}</div>`;
}

function models(usage, collapsible) {
  if (!usage?.length) return "";
  const list = `<div class="model-list">${usage.map((entry) => `
    <details name="model" data-disclosure="${escape(entry.model ?? "")}">
      <summary><span>${escape(entry.model ?? "未知模型")}</span>
        <strong>${compact(entry.usage.inputTokens + entry.usage.outputTokens)}</strong><i class="chevron" aria-hidden="true"></i></summary>
      ${usageMetrics(entry.usage)}
    </details>`).join("")}</div>`;
  return collapsible ? `<details class="models" data-disclosure="models"><summary>按模型<i class="chevron" aria-hidden="true"></i></summary>${list}</details>` : list;
}

function dashboardHeader(snapshot) {
  const quota = snapshot?.quota;
  const stale = quota && Math.abs(Date.now() / 1000 - quota.fetchedAt) > 600;
  const warning = stale ? "额度为上次记录" : snapshot?.quotaRefreshFailed ? "暂时无法获取额度"
    : snapshot?.status === "stale" ? "部分用量未能更新" : "";
  return `<header class="dashboard-header">
    <span class="terminal" aria-hidden="true">&gt;_</span>
    <div><h1>Codex Usage</h1>
      <p class="subtitle${warning ? " warning" : ""}">${state.refreshing ? "正在刷新…" : warning || "本机用量"}</p></div>
    <details class="style-menu" data-disclosure="style">
      <summary class="icon-button" aria-label="界面样式" title="界面样式"><span class="palette" aria-hidden="true"></span></summary>
      <div class="style-options" role="group" aria-label="界面样式">
        ${Object.entries(styles).map(([key, label]) => `<button type="button" data-style="${key}" aria-pressed="${key === style}">${label}</button>`).join("")}
      </div>
    </details>
    <button type="button" class="icon-button refresh" data-action="refresh" aria-label="刷新用量" title="刷新" ${state.refreshing ? "disabled" : ""}>
      <span ${state.refreshing ? 'class="spinner"' : ""} aria-hidden="true">${state.refreshing ? "" : "↻"}</span>
    </button>
  </header>`;
}

function quotaCard(quota) {
  const remaining = remainingQuota(quota);
  const amount = quota ? `${Math.round(remaining)}<small>%</small>` : "—";
  const reset = `<div class="reset"><strong>${quota ? countdown(quota.resetsAt, Date.now() / 1000) : "暂无重置时间"}</strong>
    <small>${quota ? time(quota.resetsAt) : "等待官方数据"}</small></div>`;
  const used = `<p class="used">${quota ? `已使用 ${Math.round(100 - remaining)}%` : "暂无额度数据"}</p>`;
  if (style === "orbit") {
    return `<section class="quota-orbit">
      <div class="ring" data-progress="${remaining}"><div><p class="amount">${amount}</p><small>剩余额度</small></div></div>
      <div><h2>周额度剩余</h2>${reset}${used}</div>
    </section>`;
  }
  const segments = Array.from({ length: 25 }, (_, index) =>
    `<span><i data-progress="${Math.max(0, Math.min(100, remaining * 25 - index * 100))}"></i></span>`).join("");
  return `<section class="card quota-card">
    <div class="quota-heading">
      <div><h2>周额度剩余</h2><p class="amount">${amount}</p></div>
      ${reset}
    </div>
    <div class="segments" aria-hidden="true">${segments}</div>
    ${used}
  </section>`;
}

function dayQuota(day) {
  const segments = day.quotaSegments ?? [];
  if (segments.length > 2) return `<strong>${segments.length} 段</strong><small>按重置分段</small>`;
  if (segments.length) return `<span class="quota-parts">${segments.map((part) => `<span>
    <strong>${escape(percentage(part.consumedPercent ?? part.recordedConsumedPercent))}</strong>
    <small>${part.startsWithReset ? "重置后" : "重置前"}</small>
    ${part.consumedPercent == null && part.recordedConsumedPercent != null ? '<small class="warning">已记录</small>' : ""}
  </span>`).join("")}</span>`;
  return `<strong>${escape(percentage(day.quotaConsumedPercent ?? day.recordedQuotaConsumedPercent))}</strong>
    ${day.quotaConsumedPercent == null && day.recordedQuotaConsumedPercent != null ? '<small class="warning">已记录 · 记录不完整</small>' : ""}`;
}

function cycleSummary(cycle) {
  return `<section class="cycle-summary">
    <div><h2>当前周期 Token</h2><small>${status[cycle?.status] ?? "暂无数据"}</small></div>
    <div><strong>${cycle ? compact(cycle.displayedTokens) : "—"}</strong>
      <small>额度已用 ${escape(percentage(cycle?.quotaUsedPercent))}</small></div>
  </section>`;
}

function overview(snapshot) {
  const footer = `<footer class="footer">
    <span>${snapshot?.quota ? "额度更新于 " + time(snapshot.quota.fetchedAt) : "等待官方额度"}</span>
    <button type="button" data-action="exit" aria-label="退出 Codex Usage">退出</button>
  </footer>`;
  if (!snapshot) {
    const loading = state.refreshing ? "正在读取本机用量…" : state.message || "暂时没有可显示的用量数据";
    return `${dashboardHeader(null)}<p class="empty" role="status">${escape(loading)}</p>${footer}`;
  }
  const { today, currentCycle, quota } = snapshot;
  const hasModels = Boolean(today.modelUsage?.length);
  const separateCycle = hasModels || style === "orbit";
  return `${dashboardHeader(snapshot)}
    <div class="overview-scroll" data-scroll>
      ${state.message ? `<p class="notice" role="status">${escape(state.message)}
        ${state.message.startsWith("未找到 Codex Home") ? '<button type="button" data-action="choose">重新选择</button>' : ""}</p>` : ""}
      ${quotaCard(quota)}
      <section class="card today">
        <div class="today-heading">
          <div><h2>今日 Token</h2><p class="today-value" title="${number.format(today.displayedTokens)} Token">${compact(today.displayedTokens)}</p></div>
          <button class="today-quota" type="button" data-day="${escape(today.day)}">
            <span>当日额度消耗</span>${dayQuota(today)}
          </button>
        </div>
        ${usageMetrics(today.localUsage)}
        ${models(today.modelUsage, true)}
        ${!separateCycle ? cycleSummary(currentCycle) : ""}
      </section>
      ${separateCycle ? `<div class="card current-cycle">${cycleSummary(currentCycle)}</div>` : ""}
    </div>
    <nav class="navigation" aria-label="用量页面">
      <button type="button" data-view="trend"><i class="bars-icon" aria-hidden="true"></i>最近 7 天<i class="chevron" aria-hidden="true"></i></button>
      <button type="button" data-view="history"><i class="history-icon" aria-hidden="true">◷</i>历史周期<i class="chevron" aria-hidden="true"></i></button>
    </nav>
    ${footer}`;
}

function subpageHeader(title, summary) {
  return `<header class="subpage-header">
    <button type="button" class="icon-button back" data-view="overview" aria-label="返回概览" title="返回概览"><i class="chevron" aria-hidden="true"></i></button>
    <h1>${title}</h1><span>${summary}</span>
  </header>`;
}

function trend({ today, recentDays }) {
  const days = recentDays;
  const largest = Math.max(1, ...days.map((day) => day.displayedTokens));
  const total = days.reduce((sum, day) => sum + day.displayedTokens, 0);
  const active = selectedDay ?? today.day;
  return `${subpageHeader("最近 7 天", days.length ? `${shortDay(days[0].day)} – ${shortDay(days.at(-1).day)}` : "")}
    ${days.length ? `
      <section class="trend-summary"><span>合计 <strong>${compact(total)}</strong></span><span>日均 <b>${compact(Math.trunc(total / days.length))}</b></span></section>
      <div class="table-label day-columns"><span>日期</span><span>Token</span><span>额度消耗 <button type="button" data-action="explanation" aria-label="额度消耗说明" title="额度消耗说明">ⓘ</button></span></div>
      <div class="rows" data-scroll>${[...days].reverse().map((day) => {
        const segments = day.quotaSegments ?? [];
        const partial = segments.some((part) => part.consumedPercent == null && part.recordedConsumedPercent != null)
          || (day.quotaConsumedPercent == null && day.recordedQuotaConsumedPercent != null);
        return `<button type="button" class="day-columns row ${day.day === active ? "active" : ""}" data-day="${escape(day.day)}">
          <span>${shortDay(day.day)}${day.day === today.day ? " 今天" : ""}${day.status === "localLive" ? "<small>本地统计</small>" : ""}</span>
          <span title="${number.format(day.displayedTokens)} Token"><strong>${compact(day.displayedTokens)}</strong>
            <span class="row-bar"><i data-progress="${100 * day.displayedTokens / largest}"></i></span></span>
          <span>${segments.length ? `分 ${segments.length} 段` : escape(percentage(day.quotaConsumedPercent ?? day.recordedQuotaConsumedPercent))}
            ${partial ? '<small class="warning">记录不完整</small>' : ""}</span>
          <i class="chevron" aria-hidden="true"></i>
        </button>`;
      }).join("")}</div>
      <p class="hint">ⓘ 点按日期查看当日详情</p>` : '<p class="empty">暂无趋势数据</p>'}`;
}

function history(snapshot) {
  const entries = cycles(snapshot);
  const summary = snapshot.currentCycle ? `当前 + 最近 ${entries.length - 1} 个` : `最近 ${entries.length} 个`;
  return `${subpageHeader("历史周期", entries.length ? summary : "")}
    ${entries.length ? `
      <div class="table-label cycle-columns"><span>周期</span><span>Token</span><span>额度已用</span></div>
      <div class="rows" data-scroll>${entries.map((cycle) => {
        const current = cycle === snapshot.currentCycle;
        return `<button type="button" class="cycle-columns row ${current ? "active" : ""}" data-cycle="${cycle.startsAt}">
          <span>${shortDate(cycle.startsAt)} – ${shortDate(cycle.endsAt)} ${current ? '<em>当前</em>' : ""}
            <small>${status[cycle.status]}${cycle.boundaryIsEstimated ? " · 边界估算" : ""}</small></span>
          <strong title="${number.format(cycle.displayedTokens)} Token">${compact(cycle.displayedTokens)}</strong>
          <span>${escape(percentage(cycle.quotaUsedPercent ?? cycle.lastRecordedQuota?.usedPercent))}
            ${cycle.lastRecordedQuota && cycle.quotaUsedPercent == null ? '<small class="warning">记录不完整</small>' : ""}</span>
          <i class="chevron" aria-hidden="true"></i>
        </button>`;
      }).join("")}</div>
      <p class="hint">点按周期查看详情 · — 表示额度记录不足</p>` : '<p class="empty">暂无周期历史</p>'}`;
}

function consumption(complete, recorded) {
  if (complete != null) return `额度消耗 ${escape(percentage(complete))}`;
  if (recorded != null) return `已记录消耗 ${escape(percentage(recorded))} · 记录不完整`;
  return "额度记录不足";
}

function dayDetail(day) {
  return `<section class="detail-section">
    <h3>${number.format(day.displayedTokens)} Token · ${status[day.status]}</h3>
    <p>本机记录 ${number.format(day.localUsage.inputTokens + day.localUsage.outputTokens)} Token</p>
    ${usageMetrics(day.localUsage)}${models(day.modelUsage, false)}
  </section>
  <section class="detail-section">
    <h3>当日额度消耗</h3>
    ${day.quotaSegments?.length ? day.quotaSegments.map((part) => `
      <div class="detail-row"><strong>${consumption(part.consumedPercent, part.recordedConsumedPercent)}</strong>
        <small>${time(part.startsAt)} 至 ${time(part.endsAt)}${part.startsWithReset ? " · 周期重置" : ""}</small></div>`).join("")
      : `<p>${consumption(day.quotaConsumedPercent, day.recordedQuotaConsumedPercent)}</p>`}
  </section>`;
}

function cycleDetail(cycle) {
  const used = cycle.quotaUsedPercent != null ? `额度已用 ${escape(percentage(cycle.quotaUsedPercent))}` :
    cycle.lastRecordedQuota ? `最后记录 ${escape(percentage(cycle.lastRecordedQuota.usedPercent))} · 记录不完整` : "额度记录不足";
  return `<section class="detail-section">
    <h3>${number.format(cycle.displayedTokens)} Token · ${status[cycle.status]}</h3>
    <p>${time(cycle.startsAt, true)} 至 ${time(cycle.endsAt, true)}</p>
    <p>${used}</p>${usageMetrics(cycle.usage)}
  </section>
  ${cycle.dailyUsage?.length ? `<section class="detail-section">
    <h3>周期内每日用量</h3>
    ${cycle.dailyUsage.map((day) => `<div class="detail-row split">
      <span>${escape(day.day)}<small>${consumption(day.quotaConsumedPercent, day.recordedQuotaConsumedPercent)}</small></span>
      <span><strong>${compact(day.displayedTokens)}</strong><small>${status[day.status]}</small></span>
    </div>`).join("")}</section>` : ""}`;
}

function showDetail() {
  const snapshot = state.snapshot;
  if (!selection || !snapshot) return;
  const heading = document.querySelector("#detail-title");
  const body = document.querySelector("#detail-content");
  if (selection.kind === "explanation") {
    heading.textContent = "额度消耗说明";
    body.innerHTML = '<p>每段按各自周期额度计算；Token 为全天总量。</p><p>已记录消耗仅包含可确认的增量。</p>';
  } else if (selection.kind === "day") {
    const day = [snapshot.today, ...snapshot.recentDays].find((entry) => entry.day === selection.key);
    if (!day) return;
    heading.textContent = day.day;
    body.innerHTML = dayDetail(day);
  } else {
    const cycle = cycles(snapshot).find((entry) => entry.startsAt === Number(selection.key));
    if (!cycle) return;
    heading.textContent = cycle === snapshot.currentCycle ? "当前周期详情" : "历史周期详情";
    body.innerHTML = cycleDetail(cycle);
  }
  if (!dialog.open) dialog.showModal();
}

function render() {
  const snapshot = state.snapshot;
  const needsModelSpace = view === "overview" && Boolean(snapshot?.today.modelUsage?.length);
  if (needsModelSpace !== hasModelRows) {
    hasModelRows = needsModelSpace;
    invoke("resize_usage_panel", { hasModelRows }).catch(onError);
  }
  const disclosed = new Set([...content.querySelectorAll("details[open]")].map((item) => item.dataset.disclosure));
  const scroll = content.querySelector("[data-scroll]")?.scrollTop ?? 0;
  document.documentElement.dataset.style = style;
  document.documentElement.classList.toggle("low", Boolean(snapshot?.quota) && remainingQuota(snapshot.quota) <= 10);
  content.className = view;
  content.innerHTML = !snapshot || view === "overview" ? overview(snapshot) : { trend, history }[view](snapshot);
  for (const item of content.querySelectorAll("details")) item.open = disclosed.has(item.dataset.disclosure);
  for (const item of content.querySelectorAll("[data-progress]")) item.style.setProperty("--progress", item.dataset.progress + "%");
  const scrollArea = content.querySelector("[data-scroll]");
  if (scrollArea) scrollArea.scrollTop = scroll;
}

function onError() {
  state = { ...state, message: "无法读取用量。", refreshing: false };
  render();
}

content.addEventListener("click", (event) => {
  const button = event.target.closest("button");
  if (!button) return;
  const { view: page, style: chosenStyle, day, cycle, action } = button.dataset;
  if (page) {
    view = page;
    const scroller = content.querySelector("[data-scroll]");
    if (scroller) scroller.scrollTop = 0;
    render();
  } else if (chosenStyle) {
    style = chosenStyle;
    localStorage.setItem("interfaceStyle", style);
    content.querySelector(".style-menu").open = false;
    render();
  } else if (day || cycle || action === "explanation") {
    if (day && view === "trend") {
      selectedDay = day;
      render();
    }
    selection = day ? { kind: "day", key: day } : cycle ? { kind: "cycle", key: cycle } : { kind: "explanation" };
    showDetail();
  } else {
    const command = { refresh: "refresh_usage", choose: "select_codex_home", exit: "exit_usage" }[action];
    if (command) {
      if (action === "refresh") button.disabled = true;
      invoke(command).catch(onError);
    }
  }
});
document.addEventListener("click", (event) => {
  const menu = content.querySelector(".style-menu");
  if (menu?.open && !menu.contains(event.target)) menu.open = false;
});
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape" || dialog.open) return;
  const menu = content.querySelector(".style-menu");
  if (menu?.open) menu.open = false;
  else if (view !== "overview") {
    view = "overview";
    render();
  } else invoke("hide_usage").catch(onError);
});
dialog.addEventListener("close", () => { selection = null; });
dialog.addEventListener("click", (event) => { if (event.target === dialog) dialog.close(); });

try {
  const saved = localStorage.getItem("interfaceStyle") ?? await invoke("legacy_interface_style");
  if (Object.hasOwn(styles, saved)) style = saved;
  await listen("usage-snapshot", ({ payload }) => { state = payload; render(); });
  state = await invoke("current_usage");
  render();
} catch {
  onError();
}
