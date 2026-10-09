const WARNING_LABELS = {
  missing_falcon_app: (labels) => labels.app && `No ${labels.app} set`,
  done_without_dev_point: (labels) => labels.points && `Done without ${labels.points}`,
};
const AUTH_STATUSES = [401, 403];
const AUTH_ERROR_TEXT = 'Jira token invalid or missing — open Clean macOS Settings → Jira';
const ISSUE_KEY_PATTERN = /^[A-Z][A-Z0-9_]*-\d+$/;
const BOARD_DONE_LIMIT = 20;
const BOARD_COLUMN_WIDTH = 'w-[272px]';
const TOAST_MS = 3000;
const OPTION_SEARCH_MIN = 9;
const NOW = new Date();
const CURRENT_MONTH = `${NOW.getFullYear()}-${String(NOW.getMonth() + 1).padStart(2, '0')}`;
const STATUS_ORDER = ['Doing', 'To Do', 'Waiting To Test', 'Test Staging', 'Waiting For Review', 'Reviewing', 'Review Done', 'QA/QC', 'Waiting To Live', 'Testing Production', 'Done', 'Archived'];
const STATUS_TONES = { 'To Do': 'todo', Doing: 'progress', Done: 'done', done: 'done', Archived: 'archived' };
const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const SHORT_MONTHS = MONTH_NAMES.map((name) => name.slice(0, 3));
const VIEWS = [
  { id: 'table', label: 'Table', icon: 'table-2' },
  { id: 'board', label: 'Board', icon: 'square-kanban' },
];
const SMART_LISTS = [
  { id: 'sprint', icon: 'timer', tone: 'sprint', match: (i) => Boolean(i.sprint) && i.sprint === currentSprintName() },
  { id: 'doing', label: 'Doing', icon: 'circle-dot', tone: 'progress', match: (i) => i.status === 'Doing' },
  { id: 'all', label: 'All tasks', icon: 'list', tone: 'todo', match: () => true },
  { id: 'done', label: 'Done', icon: 'circle-check', tone: 'done', match: (i) => i.isDone },
];
const EMPTY_LIST_TEXT = {
  doing: 'Nothing in Doing right now.',
  all: 'No tasks for this assignee.',
  done: 'No done tasks yet.',
};
const TONE_BADGE = {
  todo: 'bg-todo-bg text-todo-text',
  progress: 'bg-progress-bg text-progress-text',
  review: 'bg-review-bg text-review-text',
  done: 'bg-done-bg text-done-text',
  warn: 'bg-warn-bg text-warn-text',
  archived: 'text-muted ring-1 ring-inset ring-border-strong',
};
const TONE_ICON = { todo: 'text-muted', progress: 'text-progress', review: 'text-review', done: 'text-done', archived: 'text-muted' };
const TONE_COUNT = { progress: 'text-progress-text', review: 'text-review-text', done: 'text-done-text', warn: 'font-medium text-warn-text' };
const TONE_TILE = {
  sprint: 'bg-primary/10 text-link',
  progress: 'bg-progress-bg text-progress-text',
  warn: 'bg-warn-bg text-warn-text',
  todo: 'bg-todo-bg text-todo-text',
  done: 'bg-done-bg text-done-text',
};
const COLUMN_ICON = { 'To Do': 'circle', Doing: 'circle-dot', Done: 'circle-check' };
const COLUMN_DEFS = {
  key: { label: 'Key' },
  summary: { label: 'Task', grow: true },
  status: { label: 'Status' },
  assignees: { label: 'Assignee' },
  falconApp: { labelKey: 'app' },
  devPoint: { labelKey: 'points', isShort: true, right: true },
  sprint: { label: 'Sprint' },
  updated: { label: 'Updated' },
};
const TABLE_COLUMNS = Object.keys(COLUMN_DEFS);
const DESC_FIRST_SORT = ['devPoint', 'updated'];
const DEFAULT_SORT = { key: 'status', dir: 1 };
const FILTER_LABELS = { assignee: 'Assignee', status: 'Status', sprint: 'Sprint', month: 'Month' };
const FILTER_VALUE = {
  assignee: (i) => (i.assignees.length ? i.assignees.map((a) => a.name) : ['(none)']),
  status: (i) => i.status,
  app: (i) => i.falconApp || '(none)',
  sprint: (i) => i.sprint || '(none)',
  month: (i) => issueMonth(i),
};
const FILTER_NAMES = Object.keys(FILTER_VALUE);
const noNegation = () => Object.fromEntries(FILTER_NAMES.map((name) => [name, false]));
const TREE_INDENT_PX = 20;
const DROP_CLASSES = 'rounded-2xl data-[drop=true]:outline-2 data-[drop=true]:outline-offset-2 data-[drop=true]:outline-dashed data-[drop=true]:outline-primary';

const state = {
  issues: [],
  kpi: {},
  kpiSyncedAt: '',
  kpiError: '',
  meta: { columns: [], sprints: [], labels: {} },
  phase: 'loading',
  loadError: '',
  view: 'table',
  list: 'all',
  query: '',
  status: [],
  app: [],
  sprint: [],
  month: [CURRENT_MONTH],
  assignee: null,
  negate: noNegation(),
  expanded: new Map(),
  hideDone: false,
  sort: DEFAULT_SORT,
  panelKey: null,
  detail: null,
  calendarMonth: null,
};

const $ = (selector) => document.querySelector(selector);

const api = {
  async call(method, path, body) {
    const options = { method };
    if (body !== undefined) {
      options.headers = { 'Content-Type': 'application/json', 'X-Jira-Desk': '1' };
      options.body = JSON.stringify(body);
    }
    const response = await fetch(path, options);
    const data = await response.json();
    if (!response.ok) throw Object.assign(new Error(data.error || `HTTP ${response.status}`), { status: response.status });
    return data;
  },
  issues: () => api.call('GET', '/api/issues'),
  meta: () => api.call('GET', '/api/meta'),
  kpi: () => api.call('GET', '/api/kpi'),
  issue: (key) => api.call('GET', `/api/issues/${key}`),
  update: (key, changes) => api.call('PATCH', `/api/issues/${key}`, changes),
  transition: (key, id) => api.call('POST', `/api/issues/${key}/transition`, { id }),
  move: (key, column) => api.call('POST', `/api/issues/${key}/move`, { column }),
  comment: (key, body) => api.call('POST', `/api/issues/${key}/comment`, { body }),
  users: (query) => api.call('GET', `/api/users?q=${encodeURIComponent(query)}`),
  editComment: (key, id, body) => api.call('PUT', `/api/issues/${key}/comment/${id}`, { body }),
  deleteComment: (key, id) => api.call('DELETE', `/api/issues/${key}/comment/${id}`),
  render: (markup, issueKey) => api.call('POST', '/api/render', { markup, issueKey }),
  async upload(key, file, name) {
    const response = await fetch(`/api/issues/${key}/attachments?name=${encodeURIComponent(name)}`, { method: 'POST', body: await file.arrayBuffer() });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
    return data;
  },
};

function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

const TOAST_BASE = $('#toast').className;

function showToast(message, isError = false) {
  const toast = $('#toast');
  toast.innerHTML = isError ? `${icon('circle-alert')}<span>${esc(message)}</span>` : esc(message);
  toast.className = `${TOAST_BASE} ${isError ? 'border border-border bg-surface-overlay text-danger-text' : 'bg-foreground text-background'}`;
  toast.hidden = false;
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => { toast.hidden = true; }, TOAST_MS);
}

const icon = (name, cls = 'size-4') => `<i data-lucide="${name}" class="${cls} shrink-0" aria-hidden="true"></i>`;
const shortSprint = (sprint) => (sprint ? sprint.replace('Falcon ', '') : '');
const formatDate = (iso) => (iso ? `${SHORT_MONTHS[Number(iso.slice(5, 7)) - 1]} ${Number(iso.slice(8, 10))}` : '');
const formatLongDate = (iso) => (iso ? `${formatDate(iso)}, ${iso.slice(0, 4)}` : '');
const todayIso = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const isLoading = () => state.phase === 'loading';
const isError = () => state.phase === 'error';
const labels = () => state.meta.labels || {};
const initials = (text) => text.split(/\s+/).map((word) => word[0]).join('').toUpperCase();
const pointsShort = () => initials(labels().points);
const sumDevPoints = (issues) => issues.reduce((sum, i) => sum + Number(i.devPoint || 0), 0);
const dash = '<span class="text-muted">—</span>';
const skeleton = (width, extra = '') => `<span class="block h-3 ${width} animate-pulse rounded-full bg-foreground/5 motion-reduce:animate-none ${extra}"></span>`;

function currentSprintName() {
  return state.meta.sprints.find((s) => s.state === 'active')?.name || '';
}

function listLabel(list) {
  return list.id === 'sprint' ? shortSprint(currentSprintName()) || 'Current sprint' : list.label;
}

const currentList = () => SMART_LISTS.find((list) => list.id === state.list);
const listIssues = (list) => scopedIssues().filter(list.match);
const statusTone = (status) => STATUS_TONES[status] || 'review';

function badge(label, tone) {
  return `<span class="inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-medium ${TONE_BADGE[tone]}"><span class="size-1.5 rounded-full bg-current"></span>${esc(label)}</span>`;
}

const statusBadge = (status) => badge(status, statusTone(status));
const appTag = (app) => `<span data-app="${esc(app)}" class="inline-flex whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium">${esc(app)}</span>`;
const issueAppTag = (issue) => (labels().app && issue.falconApp ? appTag(issue.falconApp) : '');
const pointsTag = (issue, cls = '') => (labels().points && issue.devPoint ? `<span class="${cls}">${esc(pointsShort())} ${esc(issue.devPoint)}</span>` : '');
const myName = () => state.meta.me?.name || '';
const filterValues = (name, issue) => [].concat(FILTER_VALUE[name](issue));
const matchesFilter = (name, issue) => !state[name]?.length || filterValues(name, issue).some((value) => state[name].includes(value)) !== state.negate[name];
const inAssigneeScope = (issue) => matchesFilter('assignee', issue);
const scopedIssues = () => state.issues.filter(inAssigneeScope);
const avatar = (user, size = 'size-6') => `<img src="${esc(user.avatar)}" alt="${esc(user.displayName)}" title="${esc(user.displayName)}" loading="lazy" class="${size} shrink-0 rounded-full bg-foreground/5 ring-2 ring-surface">`;
const personLabel = (user) => `<span class="inline-flex items-center gap-1.5">${avatar(user, 'size-5')}${esc(user.displayName)}</span>`;

function avatarStack(users, max = 3) {
  if (!users.length) return dash;
  const extra = users.length > max ? `<span class="grid size-6 shrink-0 place-items-center rounded-full bg-secondary text-[11px] font-medium tabular-nums text-muted ring-2 ring-surface">+${users.length - max}</span>` : '';
  return `<span class="flex -space-x-1.5">${users.slice(0, max).map((user) => avatar(user)).join('')}${extra}</span>`;
}

let issueIndex = { source: null, byKey: new Map() };
function findIssue(key) {
  if (issueIndex.source !== state.issues) issueIndex = { source: state.issues, byKey: new Map(state.issues.map((i) => [i.key, i])) };
  return issueIndex.byKey.get(key);
}

function warningTexts(issue) {
  return issue.warnings.map((w) => WARNING_LABELS[w]?.(labels())).filter(Boolean);
}

function warnMark(issue) {
  const texts = warningTexts(issue);
  if (!texts.length) return '';
  const label = texts.join('. ');
  return `<span class="inline-flex shrink-0 text-warn" title="${esc(label)}">${icon('triangle-alert')}<span class="sr-only">${esc(label)}</span></span>`;
}

function hasActiveFilters() {
  const isDefaultAssignee = state.assignee === null || (state.assignee.length === 1 && state.assignee[0] === myName());
  const hasValues = (name) => state[name]?.length > 0;
  const isDefaultMonth = state.month.length === 1 && state.month[0] === CURRENT_MONTH && !state.negate.month;
  return Boolean(state.query || state.hideDone || !isDefaultAssignee || !isDefaultMonth || ['status', 'app', 'sprint'].some(hasValues) || FILTER_NAMES.some((name) => hasValues(name) && state.negate[name]));
}

function matchesFilters(issue) {
  const query = state.query.trim().toLowerCase();
  if (!currentList().match(issue)) return false;
  if (query && !`${issue.key} ${issue.summary}`.toLowerCase().includes(query)) return false;
  if (!FILTER_NAMES.every((name) => matchesFilter(name, issue))) return false;
  if (state.hideDone && issue.isDone) return false;
  return true;
}

function sortValue(issue, key) {
  if (key === 'status') {
    const rank = STATUS_ORDER.indexOf(issue.status);
    return rank < 0 ? STATUS_ORDER.length : rank;
  }
  if (key === 'devPoint') return Number(issue.devPoint || 0);
  if (key === 'assignees') return issue.assignees[0]?.displayName || '';
  return issue[key] ?? '';
}

function compareIssues(a, b) {
  const { key, dir } = state.sort;
  const left = sortValue(a, key);
  const right = sortValue(b, key);
  const diff = typeof left === 'number' ? left - right : String(left).localeCompare(String(right), undefined, { numeric: true });
  return dir * diff || b.updated.localeCompare(a.updated);
}

function visibleIssues() {
  return state.issues.filter(matchesFilters).sort(compareIssues);
}

function nextSort(key) {
  const firstDir = DESC_FIRST_SORT.includes(key) ? -1 : 1;
  if (state.sort.key !== key) return { key, dir: firstDir };
  if (state.sort.dir === firstDir) return { key, dir: -firstDir };
  return DEFAULT_SORT;
}

function columnLabel(key) {
  const def = COLUMN_DEFS[key];
  if (!def.labelKey) return def.label;
  const text = labels()[def.labelKey];
  return def.isShort ? initials(text) : text;
}

const isColumnShown = (key) => !COLUMN_DEFS[key].labelKey || Boolean(labels()[COLUMN_DEFS[key].labelKey]);
const tableColumns = () => TABLE_COLUMNS.filter(isColumnShown);

function sortHeader(key) {
  const def = COLUMN_DEFS[key];
  const isSorted = state.sort.key === key;
  const arrow = isSorted ? (state.sort.dir > 0 ? 'arrow-up' : 'arrow-down') : 'arrow-up-down';
  const ariaSort = isSorted ? ` aria-sort="${state.sort.dir > 0 ? 'ascending' : 'descending'}"` : '';
  return `<th scope="col" class="p-0 ${def.grow ? 'w-full' : 'w-px'}"${ariaSort}>
    <button type="button" data-sort="${key}" class="flex h-11 w-full cursor-pointer items-center gap-1 whitespace-nowrap px-4 text-xs font-medium outline-hidden transition-colors hover:text-foreground ${def.right ? 'flex-row-reverse' : ''} ${isSorted ? 'text-foreground' : 'text-muted'}">${esc(columnLabel(key))}${icon(arrow, 'size-3.5')}</button>
  </th>`;
}

const isExpanded = (key, kids) => (state.expanded.has(key) ? state.expanded.get(key) : kids.some((kid) => !kid.isDone));

function childrenByParent(issues) {
  const keys = new Set(issues.map((i) => i.key));
  const children = new Map();
  for (const issue of issues) {
    if (keys.has(issue.parentKey)) children.set(issue.parentKey, [...(children.get(issue.parentKey) || []), issue]);
  }
  return { keys, children };
}

function treeRows(issues) {
  const { keys, children } = childrenByParent(issues);
  const rows = [];
  const visited = new Set();
  const walk = (issue, depth, isShown) => {
    if (visited.has(issue.key)) return;
    visited.add(issue.key);
    const kids = children.get(issue.key) || [];
    if (isShown) rows.push({ issue, depth, kids });
    kids.forEach((kid) => walk(kid, depth + 1, isShown && isExpanded(issue.key, kids)));
  };
  issues.filter((i) => !keys.has(i.parentKey)).forEach((i) => walk(i, 0, true));
  issues.forEach((i) => walk(i, 0, true));
  return rows;
}

function treeToggle({ issue, depth, kids }) {
  const indent = depth ? `<span class="shrink-0" style="width:${depth * TREE_INDENT_PX}px"></span>` : '';
  if (!kids.length) return `${indent}<span class="size-5 shrink-0"></span>`;
  const isOpen = isExpanded(issue.key, kids);
  return `${indent}<button type="button" data-toggle="${issue.key}" aria-expanded="${isOpen}" aria-label="${isOpen ? 'Collapse' : 'Expand'} ${issue.key}" class="grid size-5 shrink-0 cursor-pointer place-items-center rounded-md text-muted outline-hidden hover:bg-foreground/10 hover:text-foreground">${icon('chevron-right', `size-4 transition-transform ${isOpen ? 'rotate-90' : ''}`)}</button>`;
}

function childCounts(kids) {
  if (!kids.length) return '';
  const bugs = kids.filter((kid) => kid.isBug).length;
  const others = kids.length - bugs;
  const pill = (count, iconName, cls, label) => (count ? `<span title="${count} ${label}" class="inline-flex shrink-0 items-center gap-1 rounded-full px-1.5 py-0.5 text-xs font-medium tabular-nums ${cls}">${icon(iconName, 'size-3')}${count}</span>` : '');
  return pill(bugs, 'bug', 'bg-danger-text/10 text-danger-text', 'linked bugs') + pill(others, 'list-tree', 'bg-foreground/5 text-muted', 'sub-tasks');
}

function parentRef(issue) {
  const parent = issue.parentKey && findIssue(issue.parentKey);
  if (!parent) return '';
  return `<button type="button" data-issue="${parent.key}" title="Parent: ${esc(parent.summary)}" class="inline-flex shrink-0 cursor-pointer items-center gap-1 rounded-md px-1.5 py-0.5 text-xs tabular-nums text-muted outline-hidden hover:bg-foreground/5 hover:text-foreground">${icon('corner-left-up', 'size-3')}${parent.key}</button>`;
}

const rowExtras = (row) => `${warnMark(row.issue)}${childCounts(row.kids)}${row.depth ? '' : parentRef(row.issue)}`;

const appCell = (issue) => (issue.falconApp ? appTag(issue.falconApp) : badge('None', 'warn'));
const devPointCell = (issue) => (issue.devPoint ? `<span class="tabular-nums">${esc(issue.devPoint)}</span>` : dash);

const CELL_RENDERERS = {
  key: (i) => `<td class="whitespace-nowrap px-4 py-3 text-sm tabular-nums text-muted">${i.key}</td>`,
  summary: (i, row) => `<td class="max-w-0 px-4 py-3"><div class="flex min-w-0 items-center gap-1.5">${treeToggle(row)}<span class="truncate font-medium ${row.depth ? 'text-foreground/85' : 'text-foreground'}" title="${esc(i.summary)}">${esc(i.summary)}</span>${rowExtras(row)}</div></td>`,
  status: (i) => `<td class="whitespace-nowrap px-4 py-3">${statusBadge(i.status)}</td>`,
  assignees: (i) => `<td class="whitespace-nowrap px-4 py-3">${avatarStack(i.assignees)}</td>`,
  falconApp: (i) => `<td class="whitespace-nowrap px-4 py-3">${appCell(i)}</td>`,
  devPoint: (i) => `<td class="whitespace-nowrap px-4 py-3 text-right">${devPointCell(i)}</td>`,
  sprint: (i) => `<td class="whitespace-nowrap px-4 py-3 text-sm text-muted">${esc(shortSprint(i.sprint)) || '—'}</td>`,
  updated: (i) => `<td class="whitespace-nowrap px-4 py-3 text-sm tabular-nums text-muted">${formatDate(i.updated)}</td>`,
};

function mobileRow(row) {
  const { issue } = row;
  return `<li class="flex items-start pl-3"><span class="flex pt-3.5">${treeToggle(row)}</span><div data-issue="${issue.key}" class="flex min-w-0 flex-1 cursor-pointer flex-col gap-1.5 py-3 pr-4 pl-1.5 transition-colors hover:bg-surface-hover">
    <span class="flex min-w-0 items-start gap-1.5"><span class="line-clamp-2 min-w-0 flex-1 text-sm font-medium text-pretty text-foreground">${esc(issue.summary)}</span>${rowExtras(row)}</span>
    <span class="flex items-center justify-between gap-3"><span class="flex min-w-0 items-center gap-1.5 text-xs tabular-nums text-muted"><span>${issue.key}</span>${issueAppTag(issue)}${pointsTag(issue)}</span><span class="flex shrink-0 items-center gap-2">${issue.assignees.length ? avatarStack(issue.assignees, 2) : ''}${statusBadge(issue.status)}</span></span>
  </div></li>`;
}

function tableHtml(issues) {
  const tree = treeRows(issues);
  const columns = tableColumns();
  const rows = tree.map((row) => `<tr data-issue="${row.issue.key}" ${state.panelKey === row.issue.key ? 'aria-selected="true"' : ''} class="cursor-pointer border-t border-border text-sm transition-colors hover:bg-surface-hover aria-selected:bg-secondary">${columns.map((key) => CELL_RENDERERS[key](row.issue, row)).join('')}</tr>`).join('');
  return `<table class="hidden w-full sm:table"><thead><tr>${columns.map(sortHeader).join('')}</tr></thead><tbody>${rows}</tbody></table>
    <ul class="divide-y divide-border sm:hidden">${tree.map(mobileRow).join('')}</ul>`;
}

function tableSkeleton() {
  const widths = { key: 'w-16', status: 'w-16', assignees: 'w-8', falconApp: 'w-10', devPoint: 'w-4', sprint: 'w-14', updated: 'w-12' };
  const cellWidth = (key, row) => (key === 'summary' ? ['w-3/5', 'w-2/5', 'w-1/2', 'w-2/3'][row % 4] : widths[key]);
  const columns = tableColumns();
  const rows = [0, 1, 2, 3, 4, 5, 6, 7].map((row) => `<tr class="border-t border-border">${columns.map((key) => `<td class="px-4 py-4">${skeleton(cellWidth(key, row), key === 'devPoint' ? 'ml-auto' : '')}</td>`).join('')}</tr>`).join('');
  const head = columns.map((key) => `<th scope="col" class="h-11 px-4 text-left text-xs font-medium text-muted ${COLUMN_DEFS[key].grow ? 'w-full' : 'w-px'} ${COLUMN_DEFS[key].right ? 'text-right' : ''}">${esc(columnLabel(key))}</th>`).join('');
  const mobile = [0, 1, 2, 3, 4, 5].map((row) => `<li class="flex flex-col gap-2 px-4 py-3.5">${skeleton(['w-4/5', 'w-3/5', 'w-2/3'][row % 3])}${skeleton('w-1/3')}</li>`).join('');
  return `<table class="hidden w-full sm:table" aria-busy="true"><thead><tr>${head}</tr></thead><tbody>${rows}</tbody></table>
    <ul class="divide-y divide-border sm:hidden" aria-busy="true">${mobile}</ul><span class="sr-only" role="status">Loading tasks</span>`;
}

function emptyListText() {
  if (state.list !== 'sprint') return EMPTY_LIST_TEXT[state.list];
  const sprint = currentSprintName();
  return sprint ? `No tasks in ${esc(sprint)} yet.` : 'No active sprint.';
}

function emptyBlock() {
  if (!listIssues(currentList()).length) return `<p class="py-10 text-center text-sm text-muted">${emptyListText()}</p>`;
  return `<p class="py-10 text-center text-sm text-muted">No tasks match these filters. <button type="button" data-clear class="inline cursor-pointer font-medium text-foreground underline-offset-4 outline-hidden hover:underline">Clear filters</button></p>`;
}

function errorBlock() {
  return `<div role="alert" class="flex flex-col items-center gap-3 py-10 text-center">
    <div><p class="text-sm font-medium text-danger-text">Can't load your tasks</p><p class="mt-1 text-sm text-muted">${esc(state.loadError)}</p></div>
    <button type="button" data-retry class="inline-flex min-h-10 cursor-pointer items-center justify-center gap-2 rounded-xl border border-border-strong bg-surface px-4 py-2 text-sm font-medium text-foreground outline-hidden transition-colors hover:bg-button-hover">${icon('rotate-cw')}Try again</button>
  </div>`;
}

const surfaceCard = (body) => `<div class="overflow-hidden rounded-2xl border border-border bg-surface">${body}</div>`;

function tableView(issues) {
  if (isError()) return surfaceCard(errorBlock());
  if (isLoading()) return surfaceCard(tableSkeleton());
  return surfaceCard(issues.length ? tableHtml(issues) : emptyBlock());
}

function boardCard(issue) {
  return `<li draggable="true" data-drag="${issue.key}" data-issue="${issue.key}" class="cursor-grab select-none rounded-2xl border border-border bg-surface p-4 transition-colors hover:border-border-strong">
    <div class="flex items-center gap-1.5 text-xs tabular-nums text-muted"><span>${issue.key}</span>${warnMark(issue)}${pointsTag(issue, 'ml-auto')}</div>
    <p class="mt-1.5 line-clamp-2 text-sm font-medium text-pretty text-foreground">${esc(issue.summary)}</p>
    <div class="mt-2 flex min-h-6 flex-wrap items-center gap-1.5">${issueAppTag(issue)}${parentRef(issue)}<span class="ml-auto">${issue.assignees.length ? avatarStack(issue.assignees, 2) : ''}</span></div>
  </li>`;
}

function boardColumn(column, issues) {
  const inColumn = issues.filter((issue) => column.statusIds.includes(issue.statusId));
  const isDoneColumn = inColumn.every((issue) => issue.isDone);
  const shown = isDoneColumn ? inColumn.slice(0, BOARD_DONE_LIMIT) : inColumn;
  const hidden = inColumn.length - shown.length;
  const tone = statusTone(column.name);
  return `<section data-col="${esc(column.name)}" class="${BOARD_COLUMN_WIDTH} shrink-0 ${DROP_CLASSES}">
    <header class="mb-3 flex items-center gap-2 px-1">${icon(COLUMN_ICON[column.name] || 'circle-ellipsis', `size-4 ${TONE_ICON[tone]}`)}<h2 class="min-w-0 truncate text-sm font-semibold text-foreground">${esc(column.name)}</h2><span class="text-xs font-medium tabular-nums ${TONE_COUNT[tone] || 'text-muted'}">${inColumn.length}</span></header>
    ${inColumn.length ? `<ul class="flex flex-col gap-3">${shown.map(boardCard).join('')}</ul>` : '<p class="grid h-24 place-items-center rounded-2xl border border-dashed border-foreground/15 text-sm text-muted">No tasks</p>'}
    ${hidden ? `<p class="mt-3 px-1 text-sm text-muted">${hidden} more in Table</p>` : ''}
  </section>`;
}

function boardSkeleton() {
  return [0, 1, 2, 3, 4].map((col) => `<section class="${BOARD_COLUMN_WIDTH} shrink-0"><header class="mb-3 flex h-5 items-center gap-2 px-1">${skeleton('w-24')}</header><ul class="flex flex-col gap-3">${[0, 1].slice(0, col % 2 ? 1 : 2).map(() => `<li class="flex flex-col gap-2.5 rounded-2xl border border-border bg-surface p-4">${skeleton('w-14')}${skeleton('w-4/5')}${skeleton('w-1/3')}</li>`).join('')}</ul></section>`).join('');
}

function boardView(issues) {
  if (isError()) return surfaceCard(errorBlock());
  const columns = isLoading() ? boardSkeleton() : state.meta.columns.map((column) => boardColumn(column, issues)).join('');
  const empty = !isLoading() && !issues.length ? `<p class="mb-3 text-sm text-muted">${listIssues(currentList()).length ? 'No tasks match these filters.' : emptyListText()}</p>` : '';
  return `${empty}<div class="relative overflow-x-auto pb-2"><div class="flex w-max min-w-full items-start gap-4 p-0.5">${columns}</div></div>`;
}

const issueMonth = (issue) => state.kpi[issue.key]?.month || issue.updated.slice(0, 7);
const monthLabel = (month) => `${MONTH_NAMES[Number(month.slice(5)) - 1]} ${month.slice(0, 4)}`;

const VIEW_RENDERERS = { table: tableView, board: boardView };

function uniqueValues(values) {
  return [...new Set(values.filter(Boolean))];
}

function assigneeOptions(issues) {
  const users = new Map(issues.flatMap((i) => i.assignees).map((user) => [user.name, user]));
  const isMe = (user) => user.name === myName();
  const sorted = [...users.values()].sort((a, b) => isMe(b) - isMe(a) || a.displayName.localeCompare(b.displayName));
  return [...sorted.map((user) => ({ value: user.name, label: user.displayName, html: personLabel(user) })), { value: '(none)', label: 'Unassigned' }];
}

function monthOptions(issues) {
  const kpiCount = (month) => issues.filter((i) => state.kpi[i.key]?.month === month).length;
  const pill = (count) => (count ? `<span class="rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium tabular-nums text-link">KPI ${count}</span>` : '');
  return uniqueValues(issues.map(issueMonth)).sort().reverse().map((month) => ({
    value: month, label: monthLabel(month), html: `<span class="flex items-center gap-2">${esc(monthLabel(month))}${pill(kpiCount(month))}</span>`,
  }));
}

const FILTER_OPTIONS = {
  assignee: assigneeOptions,
  month: monthOptions,
  status: (issues) => uniqueValues(issues.map((i) => i.status)).sort((a, b) => sortValue({ status: a }, 'status') - sortValue({ status: b }, 'status')).map((v) => ({ value: v, label: v, html: statusBadge(v) })),
  app: (issues) => [...uniqueValues(issues.map((i) => i.falconApp)).sort().map((v) => ({ value: v, label: v, html: appTag(v) })), { value: '(none)', label: 'No app' }],
  sprint: (issues) => [...uniqueValues(issues.map((i) => i.sprint)).sort().reverse().map((v) => ({ value: v, label: shortSprint(v) })), { value: '(none)', label: 'No sprint' }],
};

function filterLabel(name) {
  const values = state[name];
  if (values === null) return 'Me';
  if (!values.length) return 'All';
  const first = FILTER_OPTIONS[name](state.issues).find((option) => option.value === values[0])?.label || values[0];
  return values.length > 1 ? `${first} +${values.length - 1}` : first;
}

const filterTitle = (name) => (name === 'app' ? labels().app : FILTER_LABELS[name]);

function filterButton(name) {
  const title = name === 'month' ? ` title="${state.kpiError ? 'KPI sheet not synced — months use the last update date' : `KPI sheet synced ${formatLongDate(state.kpiSyncedAt)}; tasks in the sheet stay in their KPI month`}"` : '';
  return `<button type="button" data-filter="${name}"${title} aria-haspopup="listbox" aria-expanded="false" class="group inline-flex h-10 w-fit shrink-0 cursor-pointer items-center gap-1.5 rounded-xl border border-border-strong bg-surface pr-3 pl-3.5 text-sm outline-hidden transition-colors focus-visible:border-focus aria-expanded:border-focus aria-expanded:ring-2 aria-expanded:ring-focus">
    <span class="text-muted">${esc(filterTitle(name))}${state[name]?.length && state.negate[name] ? ' <span class="font-medium text-danger-text">is not</span>' : ':'}</span><span class="font-medium text-foreground">${esc(filterLabel(name))}</span>${icon('chevron-down', 'size-4 text-muted transition-transform group-aria-expanded:rotate-180')}
  </button>`;
}

function chip(name, label) {
  const isActive = state[name];
  const cls = isActive ? 'bg-primary text-primary-foreground' : 'bg-foreground/5 text-foreground/80 hover:bg-foreground/10 hover:text-foreground';
  return `<button type="button" data-chip="${name}" aria-pressed="${isActive}" class="inline-flex h-9 shrink-0 cursor-pointer items-center gap-1.5 rounded-full px-3.5 text-sm font-medium outline-hidden transition-colors ${cls}">${label}</button>`;
}

function searchBox() {
  return `<label class="relative block shrink-0 lg:w-64">
    <span class="sr-only">Search tasks</span>
    <input id="search" type="search" value="${esc(state.query)}" placeholder="Search key or title" autocomplete="off"
      class="h-11 w-full rounded-xl border border-border-strong bg-surface pr-10 pl-4 text-base text-foreground outline-hidden transition-colors placeholder:text-muted focus:border-focus focus:ring-2 focus:ring-focus md:h-10 md:text-sm [&::-webkit-search-cancel-button]:appearance-none [&::-webkit-search-decoration]:appearance-none" />
    ${state.query ? `<button type="button" data-clear-search aria-label="Clear search" class="absolute inset-y-0 right-1 my-auto inline-flex size-8 cursor-pointer items-center justify-center rounded-lg text-muted outline-hidden hover:bg-foreground/5 hover:text-foreground">${icon('x')}</button>` : ''}
  </label>`;
}

function filterRow() {
  const clear = hasActiveFilters() ? '<button type="button" data-clear class="inline-flex h-9 shrink-0 cursor-pointer items-center rounded-lg px-3 text-sm font-medium text-muted outline-hidden transition-colors hover:bg-foreground/5 hover:text-foreground">Clear filters</button>' : '';
  const parts = [...FILTER_NAMES.filter(filterTitle).map(filterButton), chip('hideDone', 'Hide done'), clear];
  return `<div class="flex flex-col gap-3 lg:flex-row lg:items-center">
    ${searchBox()}
    <div class="relative min-w-0 flex-1 overflow-x-auto scrollbar-clean py-0.5"><div class="flex w-max items-center gap-2 px-px">${parts.join('')}</div></div>
  </div>`;
}

function navLink({ attr, label, iconName, isActive, count, countClass = '', tile = '' }) {
  const countHtml = count === undefined ? '' : `<span class="ml-auto shrink-0 text-xs tabular-nums ${countClass || (isActive ? 'text-foreground' : 'text-muted')}">${count}</span>`;
  return `<button type="button" ${attr} ${isActive ? 'aria-current="page"' : ''} class="flex h-10 w-full cursor-pointer items-center gap-2 rounded-xl px-1.5 text-left text-sm outline-hidden transition-colors ${isActive ? 'bg-secondary font-medium text-foreground' : 'text-foreground/70 hover:bg-item-hover hover:text-foreground'}"><span class="grid size-6 shrink-0 place-items-center rounded-md ${tile}">${icon(iconName)}</span><span class="min-w-0 truncate">${label}</span>${countHtml}</button>`;
}

function smartListLink(list) {
  const count = isLoading() || isError() ? undefined : listIssues(list).length;
  const countClass = count ? TONE_COUNT[list.tone] : '';
  return navLink({ attr: `data-list="${list.id}"`, label: esc(listLabel(list)), iconName: list.icon, isActive: state.list === list.id, count, countClass, tile: TONE_TILE[list.tone] });
}

function navHtml() {
  const views = VIEWS.map((view) => navLink({ attr: `data-view="${view.id}"`, label: view.label, iconName: view.icon, isActive: state.view === view.id })).join('');
  const groupLabel = (text) => `<p class="flex h-10 items-center px-3 text-xs font-medium uppercase tracking-wide text-muted">${text}</p>`;
  return `<div class="flex h-16 shrink-0 items-center gap-2.5 border-b border-border px-5">
      <img src="logo.png" alt="" class="size-9 shrink-0">
      <span class="text-sm font-semibold text-foreground">Jira Desk</span>
    </div>
    <nav class="flex flex-1 flex-col overflow-y-auto px-3 py-3" aria-label="Main">
      <div class="flex flex-col gap-1">${groupLabel('Lists')}${SMART_LISTS.map(smartListLink).join('')}</div>
      <div class="mt-4 flex flex-col gap-1">${groupLabel('Views')}${views}</div>
    </nav>`;
}

function sprintProgress() {
  const issues = listIssues(SMART_LISTS[0]);
  const done = issues.filter((i) => i.isDone);
  return { done: done.length, total: issues.length, donePoints: sumDevPoints(done), totalPoints: sumDevPoints(issues) };
}

function sprintProgressHtml() {
  const p = sprintProgress();
  if (!p.total) return '';
  const percent = Math.round((p.done / p.total) * 100);
  const points = labels().points ? ` · <span class="font-medium text-done-text">${p.donePoints}</span>/${p.totalPoints} ${esc(pointsShort())}` : '';
  return `<span class="hidden shrink-0 items-center gap-2 sm:flex">
    <span role="progressbar" aria-label="Sprint tasks done" aria-valuenow="${percent}" aria-valuemin="0" aria-valuemax="100" class="h-1.5 w-20 overflow-hidden rounded-full bg-done-bg"><span class="block h-full rounded-full bg-done" style="width:${percent}%"></span></span>
    <span class="text-sm tabular-nums text-muted"><span class="font-medium text-done-text">${p.done}</span>/${p.total} done${points}</span>
  </span>`;
}

function headerMeta(issues) {
  if (isLoading()) return skeleton('w-28');
  if (isError()) return '';
  const tasks = `${issues.length} ${issues.length === 1 ? 'task' : 'tasks'}`;
  return `<span class="min-w-0 truncate text-sm tabular-nums text-muted">${tasks}</span>${state.list === 'sprint' ? sprintProgressHtml() : ''}`;
}

function headerHtml(issues) {
  return `<header class="flex h-16 shrink-0 items-center gap-3 border-b border-border bg-surface px-4 sm:px-6">
    <button type="button" data-open-drawer aria-label="Open menu" class="-ml-1 inline-flex size-9 shrink-0 cursor-pointer items-center justify-center rounded-lg text-muted outline-hidden hover:bg-foreground/5 hover:text-foreground lg:hidden">${icon('menu')}</button>
    <h1 class="shrink-0 text-base font-semibold text-foreground">${esc(listLabel(currentList()))}</h1>
    ${headerMeta(issues)}
    <span class="ml-auto"></span>
    <button type="button" data-retry aria-label="Refresh from Jira" class="inline-flex h-9 shrink-0 cursor-pointer items-center gap-2 rounded-lg px-3 text-sm font-medium text-muted outline-hidden transition-colors hover:bg-foreground/5 hover:text-foreground">${icon('refresh-cw')}<span class="hidden sm:inline">Refresh</span></button>
  </header>`;
}

function layoutHtml(issues) {
  return `<div class="flex min-h-screen">
    <aside class="sticky top-0 hidden h-screen w-60 shrink-0 flex-col bg-surface lg:flex">${navHtml()}</aside>
    <div class="flex min-w-0 flex-1 flex-col">${headerHtml(issues)}
      <div class="flex flex-1 flex-col gap-4 p-4 sm:p-6">${filterRow()}<div class="min-w-0">${VIEW_RENDERERS[state.view](issues)}</div></div>
    </div>
  </div>`;
}

function authPage() {
  return `<div role="alert" class="grid min-h-screen place-items-center p-6"><div class="flex max-w-md flex-col items-center gap-4 text-center">
    ${icon('key-round', 'size-8 text-muted')}
    <div><p class="text-base font-semibold text-foreground">${esc(AUTH_ERROR_TEXT)}</p><p class="mt-1 text-sm text-muted">${esc(state.loadError)}</p></div>
    <button type="button" data-retry class="${buttonSecondary} gap-2">${icon('rotate-cw')}Try again</button>
  </div></div>`;
}

function render() {
  const active = document.activeElement;
  const caret = active?.id === 'search' ? active.selectionStart : null;
  $('#app').innerHTML = state.phase === 'auth' ? authPage() : layoutHtml(visibleIssues());
  $('#drawer').innerHTML = navHtml();
  if (caret === null) return;
  const search = $('#search');
  search.focus();
  search.setSelectionRange(caret, caret);
}

function replaceIssue(detail) {
  state.issues = state.issues.map((i) => (i.key === detail.key ? { ...i, ...detail } : i));
  render();
}

async function loadAll() {
  if (!state.issues.length) {
    state.phase = 'loading';
    render();
  }
  try {
    const kpi = api.kpi().then((data) => ({ data, error: '' }), (error) => ({ data: { issues: {}, syncedAt: '' }, error: error.message }));
    const [issues, meta, kpiResult] = await Promise.all([api.issues(), api.meta(), kpi]);
    Object.assign(state, { issues, meta, kpi: kpiResult.data.issues, kpiSyncedAt: kpiResult.data.syncedAt, kpiError: kpiResult.error, phase: 'ready' });
    state.assignee ??= [meta.me.name];
  } catch (error) {
    state.loadError = error.message;
    if (AUTH_STATUSES.includes(error.status)) state.phase = 'auth';
    else if (state.issues.length) showToast(`Cannot load: ${error.message}`, true);
    else state.phase = 'error';
  }
  render();
}

const buttonSecondary = 'inline-flex min-h-10 cursor-pointer items-center justify-center rounded-xl border border-border-strong bg-surface px-4 py-2 text-sm font-medium text-foreground outline-hidden transition-colors hover:bg-button-hover';
const buttonPrimary = 'inline-flex min-h-10 cursor-pointer items-center justify-center rounded-xl bg-primary px-4 py-2 text-sm font-medium text-primary-foreground outline-hidden transition-colors hover:bg-primary-hover disabled:cursor-not-allowed disabled:opacity-50';
const textareaClass = 'block w-full resize-y rounded-xl border border-border-strong bg-surface px-3 py-2.5 text-base text-foreground outline-hidden transition-colors placeholder:text-muted focus:border-focus focus:ring-2 focus:ring-focus md:text-sm';
const iconButton = 'inline-flex size-8 cursor-pointer items-center justify-center rounded-lg text-muted outline-hidden hover:bg-foreground/5 hover:text-foreground';

function selectTrigger(name, content, isPlaceholder = false) {
  return `<button type="button" data-field="${name}" aria-haspopup="listbox" aria-expanded="false" class="group flex h-11 w-full cursor-pointer items-center justify-between gap-2 rounded-xl border border-border-strong bg-surface px-3 text-left text-base outline-hidden transition-colors focus-visible:border-focus aria-expanded:border-focus aria-expanded:ring-2 aria-expanded:ring-focus md:h-10 md:text-sm">
    <span class="flex min-w-0 truncate ${isPlaceholder ? 'text-muted' : 'text-foreground'}">${content}</span>${icon(name === 'dueDate' ? 'calendar' : 'chevron-down', 'size-4 text-muted transition-transform group-aria-expanded:rotate-180')}
  </button>`;
}

function detailRow(label, value) {
  return `<div class="grid gap-1 @sm:grid-cols-[7rem_minmax(0,1fr)] @sm:items-baseline @sm:gap-4">
    <dt class="text-sm text-muted @sm:self-center">${label}</dt><dd class="min-w-0 text-sm font-medium text-foreground">${value}</dd>
  </div>`;
}

function warningBanner(d) {
  const texts = warningTexts(d);
  if (!texts.length) return '';
  return `<div role="status" class="flex gap-3 rounded-2xl bg-warn-bg p-4">${icon('triangle-alert', 'mt-0.5 size-5 text-warn-text')}<div class="min-w-0"><p class="text-sm font-medium text-warn-text">${texts.map(esc).join(' · ')}</p></div></div>`;
}

const PEOPLE_SEARCH_DELAY_MS = 250;
let peopleSearchTimer;

function peopleEditor(field, users) {
  const chips = users.map((u) => `<span class="inline-flex items-center gap-1.5 rounded-full bg-foreground/5 py-0.5 pr-1 pl-0.5 text-sm font-medium">${avatar(u, 'size-5')}${esc(u.displayName)}<button type="button" data-remove-person="${field}" data-name="${esc(u.name)}" aria-label="Remove ${esc(u.displayName)}" title="Remove" class="inline-flex size-5 cursor-pointer items-center justify-center rounded-full text-muted hover:bg-foreground/10 hover:text-foreground">${icon('x', 'size-3')}</button></span>`).join('');
  return `<div class="flex flex-wrap items-center gap-1.5">${chips}<div class="relative">
    <input type="text" data-person-search="${field}" placeholder="+ Add" autocomplete="off" aria-label="Add person" class="h-7 w-24 rounded-full border border-dashed border-border-strong bg-transparent px-2.5 text-sm font-normal text-foreground outline-hidden transition-all placeholder:text-muted focus:w-48 focus:border-solid focus:border-focus" />
    <ul data-person-results="${field}" hidden class="absolute top-8 left-0 z-30 max-h-64 w-72 overflow-y-auto rounded-xl border border-border bg-surface p-1 shadow-lg"></ul>
  </div></div>`;
}

function personNames(field) {
  return (state.detail?.[field] || []).map((u) => u.name);
}

function savePeople(field, names) {
  return saveField(field, [...new Set(names)]);
}

function searchPeople(input) {
  const field = input.dataset.personSearch;
  const list = document.querySelector(`[data-person-results="${field}"]`);
  const query = input.value.trim();
  clearTimeout(peopleSearchTimer);
  if (!query) { list.hidden = true; return; }
  peopleSearchTimer = setTimeout(async () => {
    try {
      const taken = new Set(personNames(field));
      const users = (await api.users(query)).filter((u) => !taken.has(u.name));
      list.innerHTML = users.length
        ? users.map((u) => `<li><button type="button" data-add-person="${field}" data-name="${esc(u.name)}" class="flex w-full cursor-pointer items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm hover:bg-item-hover data-active:bg-item-hover data-active:ring-1 data-active:ring-focus">${avatar(u, 'size-6')}<span class="min-w-0 truncate">${esc(u.displayName)}</span><span class="ml-auto truncate text-xs text-muted">${esc(u.name)}</span></button></li>`).join('')
        : '<li class="px-2 py-1.5 text-sm text-muted">No matching people</li>';
      list.hidden = false;
      setActiveOption(list, 0);
    } catch (error) {
      showToast(error.message, true);
    }
  }, PEOPLE_SEARCH_DELAY_MS);
}

const MENTION_PATTERN = /@([\p{L}\p{N}._-]+)$/u;
let mentionTimer;

function searchMention(textarea) {
  const list = $('#mention-results');
  const match = textarea.value.slice(0, textarea.selectionStart).match(MENTION_PATTERN);
  clearTimeout(mentionTimer);
  if (!match) { list.hidden = true; return; }
  mentionTimer = setTimeout(async () => {
    try {
      const users = await api.users(match[1]);
      list.innerHTML = users.length
        ? users.map((u) => `<li><button type="button" data-mention="${esc(u.name)}" data-display="${esc(u.displayName)}" class="flex w-full cursor-pointer items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm hover:bg-item-hover data-active:bg-item-hover data-active:ring-1 data-active:ring-focus">${avatar(u, 'size-6')}<span class="min-w-0 truncate">${esc(u.displayName)}</span><span class="ml-auto truncate text-xs text-muted">${esc(u.name)}</span></button></li>`).join('')
        : '<li class="px-2 py-1.5 text-sm text-muted">No matching people</li>';
      list.hidden = false;
      setActiveOption(list, 0);
    } catch (error) {
      showToast(error.message, true);
    }
  }, PEOPLE_SEARCH_DELAY_MS);
}

function insertMention(name, displayName) {
  const textarea = $('#comment-input');
  const label = `@${displayName || name}`;
  compose.mentions.set(label, name);
  const before = textarea.value.slice(0, textarea.selectionStart).replace(MENTION_PATTERN, `${label} `);
  textarea.value = before + textarea.value.slice(textarea.selectionStart);
  textarea.setSelectionRange(before.length, before.length);
  $('#mention-results').hidden = true;
  updateCommentButton();
  textarea.focus();
}

function setActiveOption(list, index) {
  const options = [...list.querySelectorAll('button')];
  options.forEach((option, i) => option.toggleAttribute('data-active', i === index));
  options[index]?.scrollIntoView({ block: 'nearest' });
}

function handleOptionKeys(event, list) {
  if (!list || list.hidden) return false;
  if (event.key === 'Escape') {
    event.preventDefault();
    list.hidden = true;
    return true;
  }
  const options = [...list.querySelectorAll('button')];
  if (!options.length) return false;
  const current = options.findIndex((option) => option.hasAttribute('data-active'));
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault();
    const step = event.key === 'ArrowDown' ? 1 : -1;
    setActiveOption(list, (current + step + options.length) % options.length);
    return true;
  }
  if (event.key === 'Enter' || event.key === 'Tab') {
    event.preventDefault();
    (options[current] || options[0]).click();
    return true;
  }
  return false;
}

function closePeopleResults(except) {
  document.querySelectorAll('[data-person-results]').forEach((list) => { if (list !== except) list.hidden = true; });
}

const extraInputClass = 'h-10 w-full rounded-xl border border-border-strong bg-surface px-3 text-sm font-normal text-foreground outline-hidden transition-colors placeholder:text-muted focus:border-focus focus:ring-2 focus:ring-focus';

function extraFieldInput(f) {
  const attrs = `data-extra="${f.id}" data-kind="${f.kind}" aria-label="${esc(f.name)}" class="${extraInputClass}"`;
  const value = esc(f.value ?? '');
  if (f.kind === 'option') {
    return `<select ${attrs}><option value="">None</option>${f.options.map((o) => `<option value="${esc(o)}" ${o === f.value ? 'selected' : ''}>${esc(o)}</option>`).join('')}</select>`;
  }
  if (f.kind === 'users') return f.value.length ? `<span class="flex flex-wrap gap-x-3 gap-y-1.5">${f.value.map(personLabel).join('')}</span>` : dash;
  if (f.kind === 'url') {
    const open = f.value ? `<a href="${value}" target="_blank" rel="noopener" title="Open link" aria-label="Open ${esc(f.name)}" class="${iconButton} shrink-0">${icon('external-link')}</a>` : '';
    return `<span class="flex items-center gap-1"><input type="url" ${attrs} value="${value}" placeholder="https://…" />${open}</span>`;
  }
  const type = { number: 'number', date: 'date' }[f.kind] || 'text';
  return `<input type="${type}" ${type === 'number' ? 'step="any"' : ''} ${attrs} value="${value}" />`;
}

function extraFieldValue(kind, raw) {
  if (kind === 'option') return raw ? { value: raw } : null;
  if (kind === 'number') return raw === '' ? null : Number(raw);
  return raw || null;
}

function extraFieldsHtml(d) {
  const fields = d.extraFields || [];
  if (!fields.length) return '';
  return `<section class="border-t border-border pt-5"><h3 class="text-sm font-semibold text-foreground">More fields</h3>
    <dl class="@container mt-3 flex flex-col gap-3">${fields.map((f) => detailRow(esc(f.name), extraFieldInput(f))).join('')}</dl></section>`;
}

function propsHtml(d) {
  return `<dl class="@container flex flex-col gap-3">
    ${detailRow('Status', selectTrigger('status', statusBadge(d.status)))}
    ${labels().app ? detailRow(esc(labels().app), selectTrigger('falconApp', d.falconApp ? appTag(d.falconApp) : 'Choose app', !d.falconApp)) : ''}
    ${labels().points ? detailRow(esc(labels().points), selectTrigger('devPoint', esc(d.devPoint || 'Choose points'), !d.devPoint)) : ''}
    ${detailRow('Priority', selectTrigger('priority', esc(d.priority || 'Choose priority'), !d.priority))}
    ${detailRow('Sprint', selectTrigger('sprintId', esc(d.sprint || 'No sprint'), !d.sprint))}
    ${detailRow('Due date', selectTrigger('dueDate', d.dueDate ? formatLongDate(d.dueDate) : 'Pick a date', !d.dueDate))}
    ${detailRow('Merge request', `<input type="url" data-input="mergeRequest" value="${esc(d.mergeRequest || '')}" placeholder="https://…/merge_requests/…" aria-label="Merge request" class="h-11 w-full rounded-xl border border-border-strong bg-surface px-3 text-base font-normal text-foreground outline-hidden transition-colors placeholder:text-muted focus:border-focus focus:ring-2 focus:ring-focus md:h-10 md:text-sm" />`)}
    ${detailRow('Assignees', peopleEditor('assignees', d.assignees))}
    ${d.reviewers ? detailRow('Reviewers', peopleEditor('reviewers', d.reviewers)) : ''}
    ${detailRow('Reporter', d.reporter ? personLabel(d.reporter) : dash)}
    ${detailRow('Created', `<span class="tabular-nums">${formatLongDate(d.created)}</span> <span class="font-normal text-muted">· updated ${formatDate(d.updated)}</span>`)}
  </dl>`;
}

function linkedItem(issue) {
  return `<li><button type="button" data-issue="${issue.key}" class="flex w-full cursor-pointer items-center gap-2 rounded-xl px-2 py-2 text-left text-sm outline-hidden transition-colors hover:bg-item-hover">${icon(issue.isBug ? 'bug' : 'square-check', `size-4 ${issue.isBug ? 'text-danger-text' : 'text-muted'}`)}<span class="shrink-0 tabular-nums text-muted">${issue.key}</span><span class="min-w-0 flex-1 truncate text-foreground">${esc(issue.summary)}</span>${statusBadge(issue.status)}</button></li>`;
}

function linkedHtml(d) {
  const parent = d.parentKey && findIssue(d.parentKey);
  const kids = state.issues.filter((i) => i.parentKey === d.key).sort(compareIssues);
  if (!parent && !kids.length) return '';
  const group = (title, items) => (items.length ? `<div><h3 class="text-sm font-semibold text-foreground">${title}</h3><ul class="-mx-2 mt-1">${items.map(linkedItem).join('')}</ul></div>` : '');
  return `<section class="flex flex-col gap-4 border-t border-border pt-5">${group('Parent', parent ? [parent] : [])}${group(`Linked bugs & sub-tasks <span class="font-normal tabular-nums text-muted">${kids.length}</span>`, kids)}</section>`;
}

const WIKI_FORMATS = {
  bold: { wrap: ['*', '*'], icon: 'bold', title: 'Bold (⌘B)' },
  italic: { wrap: ['_', '_'], icon: 'italic', title: 'Italic (⌘I)' },
  underline: { wrap: ['+', '+'], icon: 'underline', title: 'Underline (⌘U)' },
  strike: { wrap: ['-', '-'], icon: 'strikethrough', title: 'Strikethrough' },
  heading: { line: 'h3. ', icon: 'heading', title: 'Heading' },
  bullet: { line: '* ', icon: 'list', title: 'Bulleted list' },
  numbered: { line: '# ', icon: 'list-ordered', title: 'Numbered list' },
  code: { wrap: ['{{', '}}'], icon: 'code', title: 'Inline code' },
  codeblock: { wrap: ['{code}\n', '\n{code}'], icon: 'square-code', title: 'Code block' },
  quote: { wrap: ['{quote}', '{quote}'], icon: 'quote', title: 'Quote' },
  link: { link: true, icon: 'link', title: 'Link' },
};
const WIKI_SHORTCUTS = { b: 'bold', i: 'italic', u: 'underline' };
const editorTextareaClass = textareaClass.replace('rounded-xl', 'rounded-b-xl rounded-t-none');

function formatToolbar(targetId) {
  const buttons = Object.entries(WIKI_FORMATS).map(([key, f]) => `<button type="button" data-format="${key}" data-target="${targetId}" title="${f.title}" aria-label="${f.title}" class="inline-flex size-7 cursor-pointer items-center justify-center rounded-md text-muted outline-hidden hover:bg-foreground/10 hover:text-foreground">${icon(f.icon, 'size-3.5')}</button>`).join('');
  return `<div role="toolbar" aria-label="Formatting" class="flex flex-wrap items-center gap-0.5 rounded-t-xl border border-b-0 border-border-strong bg-foreground/[0.03] p-1">${buttons}
    <button type="button" data-preview="${targetId}" aria-pressed="false" class="ml-auto inline-flex h-7 cursor-pointer items-center gap-1 rounded-md px-2 text-xs font-medium text-muted outline-hidden hover:bg-foreground/10 hover:text-foreground aria-pressed:bg-foreground/10 aria-pressed:text-foreground">${icon('eye', 'size-3.5')}Preview</button></div>
    <div id="${targetId}-preview" hidden class="rich min-h-24 rounded-b-xl border border-border-strong bg-surface px-3 py-2.5 text-sm"></div>`;
}

function applyWikiFormat(textarea, key) {
  const format = WIKI_FORMATS[key];
  const { selectionStart: start, selectionEnd: end, value } = textarea;
  const selected = value.slice(start, end);
  if (format.line) {
    const lineStart = value.lastIndexOf('\n', start - 1) + 1;
    const block = value.slice(lineStart, end).split('\n').map((line) => format.line + line).join('\n');
    textarea.setRangeText(block, lineStart, end, 'end');
  } else if (format.link) {
    const label = selected || 'link text';
    textarea.setRangeText(`[${label}|https://]`, start, end, 'end');
    const urlStart = start + label.length + 2;
    textarea.setSelectionRange(urlStart, urlStart + 'https://'.length);
  } else {
    const [open, close] = format.wrap;
    const inner = selected || 'text';
    textarea.setRangeText(open + inner + close, start, end, 'end');
    textarea.setSelectionRange(start + open.length, start + open.length + inner.length);
  }
  textarea.focus();
  textarea.dispatchEvent(new Event('input', { bubbles: true }));
}

async function togglePreview(button) {
  const textarea = document.getElementById(button.dataset.preview);
  const preview = document.getElementById(`${button.dataset.preview}-preview`);
  const showing = button.getAttribute('aria-pressed') === 'true';
  button.setAttribute('aria-pressed', String(!showing));
  textarea.closest('label').hidden = !showing;
  preview.hidden = showing;
  if (showing) return textarea.focus();
  preview.innerHTML = '<p class="text-muted">Rendering…</p>';
  try {
    const markup = textarea.id === 'comment-input' ? composeBody() : textarea.value;
    const { html } = await api.render(markup, state.detail?.key || '');
    preview.innerHTML = html || '<p class="text-muted">Nothing to preview.</p>';
  } catch (error) {
    preview.innerHTML = `<p class="text-danger-text">${esc(error.message)}</p>`;
  }
}

const BYTE_UNITS = ['B', 'KB', 'MB', 'GB'];
const fileSize = (bytes) => {
  let size = bytes;
  let unit = 0;
  while (size >= 1024 && unit < BYTE_UNITS.length - 1) { size /= 1024; unit += 1; }
  return `${unit ? size.toFixed(size < 10 ? 2 : 1) : size} ${BYTE_UNITS[unit]}`;
};

function attachmentCard(a) {
  const isImage = (a.mimeType || '').startsWith('image/');
  const preview = isImage
    ? `<img src="${esc(a.thumbnail || a.file)}" alt="" loading="lazy" class="size-full object-cover" />`
    : `<span class="flex size-full items-center justify-center text-muted">${icon('file-text', 'size-8')}</span>`;
  const open = isImage
    ? `<button type="button" data-lightbox="${esc(a.file)}" data-name="${esc(a.filename)}" aria-label="View ${esc(a.filename)}" class="block h-24 w-full cursor-zoom-in overflow-hidden bg-foreground/5">${preview}</button>`
    : `<a href="${esc(a.url)}" target="_blank" rel="noopener" aria-label="Open ${esc(a.filename)}" class="block h-24 w-full overflow-hidden bg-foreground/5">${preview}</a>`;
  return `<li class="overflow-hidden rounded-xl border border-border bg-surface">${open}
    <div class="px-2 py-1.5"><a href="${esc(a.url)}" target="_blank" rel="noopener" title="${esc(a.filename)}" class="block truncate text-xs font-medium text-link hover:underline">${esc(a.filename)}</a>
    <p class="truncate text-[11px] text-muted">${esc(a.created)} · ${fileSize(a.size)}</p></div></li>`;
}

function attachmentsHtml(d) {
  const items = d.attachments || [];
  return `<section class="border-t border-border pt-5">
    <h3 class="text-sm font-semibold text-foreground">Attachments <span class="font-normal tabular-nums text-muted">${items.length || ''}</span></h3>
    <div data-dropzone class="mt-2 rounded-xl border border-dashed border-border-strong p-3 transition-colors data-[drag-over]:border-focus data-[drag-over]:bg-focus/5">
      <p class="flex items-center justify-center gap-2 text-sm text-muted">${icon('cloud-upload', 'size-4')}Drop files to attach, or <button type="button" data-action="browse-attachment" class="cursor-pointer text-link hover:underline">browse</button>.</p>
      <input type="file" id="attachment-file" multiple hidden />
      <div id="attachment-upload" role="status" hidden class="mt-2 flex items-center justify-center gap-2 text-xs font-medium text-muted"><span class="size-3.5 shrink-0 animate-spin rounded-full border-2 border-foreground/20 border-t-primary"></span><span data-upload-text></span></div>
      ${items.length ? `<ul class="mt-3 grid grid-cols-[repeat(auto-fill,minmax(8.5rem,1fr))] gap-2">${items.map(attachmentCard).join('')}</ul>` : ''}
    </div>
  </section>`;
}

async function uploadAttachments(files) {
  const key = state.detail?.key;
  const list = [...files];
  if (!key || !list.length) return;
  const status = $('#attachment-upload');
  try {
    for (const [index, file] of list.entries()) {
      status.hidden = false;
      status.querySelector('[data-upload-text]').textContent = `Uploading ${index + 1}/${list.length} · ${file.name}…`;
      await api.upload(key, file, file.name);
    }
    const detail = await api.issue(key);
    if (state.detail?.key === key) renderPanel(detail);
    showToast(`${key}: ${list.length} file(s) attached`);
  } catch (error) {
    showToast(error.message, true);
    if ($('#attachment-upload')) $('#attachment-upload').hidden = true;
  }
}

function openLightbox(src, name) {
  const box = $('#lightbox');
  box.querySelector('img').src = src;
  box.querySelector('[data-lightbox-name]').textContent = name;
  box.hidden = false;
}

function closeLightbox() {
  const box = $('#lightbox');
  box.hidden = true;
  box.querySelector('img').removeAttribute('src');
}

function descriptionHtml(d) {
  return `<section class="border-t border-border pt-5">
    <div class="flex items-center justify-between gap-3"><h3 class="text-sm font-semibold text-foreground">Description</h3><button type="button" data-action="edit-description" class="inline-flex h-8 cursor-pointer items-center gap-1.5 rounded-lg px-2.5 text-sm font-medium text-muted outline-hidden transition-colors hover:bg-foreground/5 hover:text-foreground">${icon('pencil', 'size-3.5')}Edit</button></div>
    <div id="description-view" class="rich mt-2 text-sm leading-6 text-foreground">${d.descriptionHtml || '<p class="text-muted">No description.</p>'}</div>
    <div id="description-edit" class="mt-2" hidden>
      ${formatToolbar('description-input')}<label class="block"><span class="sr-only">Description (Jira wiki markup)</span><textarea id="description-input" rows="12" class="${editorTextareaClass} font-mono">${esc(d.descriptionRaw)}</textarea></label>
      <div class="mt-3 flex justify-end gap-2"><button type="button" data-action="cancel-description" class="${buttonSecondary}">Cancel</button><button type="button" data-action="save-description" class="${buttonPrimary}">Save</button></div>
    </div>
  </section>`;
}

function commentBubble(c) {
  const who = c.authorUser || { name: '', displayName: c.author || '', avatar: '' };
  const isMine = who.name === myName();
  const actions = isMine ? `<div class="mt-0.5 flex gap-3 px-1 text-xs text-muted opacity-0 transition-opacity group-hover:opacity-100 focus-within:opacity-100">
      <button type="button" data-edit-comment="${esc(c.id)}" class="cursor-pointer hover:text-foreground">Edit</button>
      <button type="button" data-delete-comment="${esc(c.id)}" class="cursor-pointer hover:text-danger-text data-[confirm]:font-semibold data-[confirm]:text-danger-text data-[confirm]:opacity-100">Delete</button></div>` : '';
  return `<div class="group flex items-start gap-2 py-1.5 ${isMine ? 'flex-row-reverse' : ''}">${avatar(who, 'size-7')}
    <div class="flex min-w-0 max-w-[85%] flex-col ${isMine ? 'items-end' : 'items-start'}" data-comment="${esc(c.id)}">
      <p class="px-1 text-xs text-muted">${isMine ? '' : `<span class="font-medium text-foreground">${esc(who.displayName)}</span> · `}${esc(c.created)}</p>
      <div data-comment-body class="rich mt-0.5 max-w-full overflow-x-auto rounded-2xl px-3 py-2 text-sm ${isMine ? 'rounded-tr-md bg-primary/15' : 'rounded-tl-md bg-foreground/5'}">${c.bodyHtml}</div>
      ${actions}
    </div></div>`;
}

const COMMENT_DELETE_CONFIRM_MS = 4000;

function startEditComment(id) {
  const comment = state.detail?.comments.find((c) => String(c.id) === id);
  const container = document.querySelector(`[data-comment="${CSS.escape(id)}"]`);
  if (!comment || !container) return;
  container.classList.add('w-full');
  container.querySelector('[data-comment-body]').outerHTML = `<div class="mt-0.5 w-full" data-comment-editor="${esc(id)}">
    <textarea rows="4" data-comment-edit-input class="${textareaClass}">${esc(comment.bodyRaw || '')}</textarea>
    <div class="mt-2 flex justify-end gap-2"><button type="button" data-cancel-comment-edit class="${buttonSecondary}">Cancel</button><button type="button" data-save-comment="${esc(id)}" class="${buttonPrimary}">Save</button></div></div>`;
  container.querySelector('[data-edit-comment]')?.parentElement.remove();
  container.querySelector('[data-comment-edit-input]').focus();
}

function saveCommentEdit(id) {
  const key = state.detail.key;
  const body = document.querySelector(`[data-comment-editor="${CSS.escape(id)}"] textarea`).value;
  return runWrite(() => api.editComment(key, id, body), `${key}: comment updated`);
}

function deleteCommentWithConfirm(button) {
  if (!button.hasAttribute('data-confirm')) {
    button.setAttribute('data-confirm', '');
    button.textContent = 'Confirm delete';
    setTimeout(() => {
      if (!button.isConnected) return;
      button.removeAttribute('data-confirm');
      button.textContent = 'Delete';
    }, COMMENT_DELETE_CONFIRM_MS);
    return;
  }
  const key = state.detail.key;
  return runWrite(() => api.deleteComment(key, button.dataset.deleteComment), `${key}: comment deleted`);
}

const COMMENT_IMAGE_MARKUP = (filename) => `!${filename}|thumbnail!`;

function uniqueAttachmentName(file) {
  const ext = (file.name.match(/\.[^.]+$/) || ['.png'])[0];
  const base = (file.name.replace(/\.[^.]+$/, '') || 'image').replace(/[^\p{L}\p{N}_-]+/gu, '-');
  return `${base}-${Date.now()}${ext}`;
}

const compose = { key: null, mentions: new Map(), images: [], uploading: false };

function resetCompose(key) {
  Object.assign(compose, { key, mentions: new Map(), images: [], uploading: false });
}

function composeBody() {
  let text = $('#comment-input')?.value || '';
  for (const [label, name] of compose.mentions) text = text.split(label).join(`[~${name}]`);
  const images = compose.images.map((image) => COMMENT_IMAGE_MARKUP(image.filename));
  if (!images.length) return text;
  const separator = text.trim() && !text.endsWith('\n') ? '\n' : '';
  return `${text}${separator}${images.join('\n')}`;
}

function updateCommentButton() {
  const button = $('[data-action="add-comment"]');
  if (button) button.disabled = compose.uploading || !($('#comment-input').value.trim() || compose.images.length);
}

function renderComposeImages() {
  const box = $('#comment-images');
  if (!box) return;
  box.innerHTML = compose.images.map((image, index) => `<div class="group relative size-16 overflow-hidden rounded-lg border border-border bg-foreground/5" title="${esc(image.filename)}">
    ${image.preview ? `<img src="${esc(image.preview)}" alt="" class="size-full object-cover" />` : `<span class="flex size-full items-center justify-center text-muted">${icon('image')}</span>`}
    <button type="button" data-remove-image="${index}" aria-label="Remove ${esc(image.filename)}" title="Remove" class="absolute top-0.5 right-0.5 inline-flex size-5 cursor-pointer items-center justify-center rounded-full bg-black/60 text-white opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100">${icon('x', 'size-3')}</button>
  </div>`).join('');
  box.hidden = !compose.images.length;
  updateCommentButton();
}

function setUploadProgress(text) {
  const status = $('#comment-upload');
  if (!status) return;
  status.hidden = !text;
  status.querySelector('[data-upload-text]').textContent = text || '';
  compose.uploading = Boolean(text);
  updateCommentButton();
}

async function uploadCommentImages(files) {
  const key = state.detail?.key;
  const images = [...files].filter((f) => f.type.startsWith('image/'));
  if (!key || !images.length) return;
  try {
    for (const [index, file] of images.entries()) {
      setUploadProgress(`Uploading ${index + 1}/${images.length} · ${file.name || 'pasted image'}…`);
      const saved = await api.upload(key, file, uniqueAttachmentName(file));
      if (compose.key === key) compose.images.push({ filename: saved.filename, preview: saved.thumbnail || saved.file });
      renderComposeImages();
    }
    showToast('Image attached — send the comment to post it');
  } catch (error) {
    showToast(error.message, true);
  } finally {
    setUploadProgress('');
  }
}

function commentsHtml(d) {
  const comments = d.comments.length
    ? `<div class="mt-2 flex flex-col">${d.comments.map(commentBubble).join('')}</div>`
    : '<p class="py-2 text-sm text-muted">No comments yet.</p>';
  return `<section class="border-t border-border pt-5">
    <h3 class="text-sm font-semibold text-foreground">Comments <span class="font-normal tabular-nums text-muted">${d.comments.length || ''}</span></h3>
    ${comments}
    <div class="relative mt-2">${formatToolbar('comment-input')}<label class="block"><span class="sr-only">Add a comment</span><textarea id="comment-input" rows="3" placeholder="Add a comment — type @ to mention someone" class="${editorTextareaClass}"></textarea></label>
      <div id="comment-upload" role="status" hidden class="mt-2 flex items-center gap-2 rounded-lg bg-foreground/5 px-3 py-2 text-xs font-medium text-muted"><span class="size-3.5 shrink-0 animate-spin rounded-full border-2 border-foreground/20 border-t-primary"></span><span data-upload-text></span></div>
      <div id="comment-images" hidden class="mt-2 flex flex-wrap gap-2"></div>
      <ul id="mention-results" hidden class="absolute bottom-full left-0 z-30 mb-1 max-h-64 w-72 overflow-y-auto rounded-xl border border-border bg-surface p-1 shadow-lg"></ul></div>
    <div class="mt-3 flex items-center justify-end gap-2">
      <input type="file" id="comment-file" accept="image/*" multiple hidden />
      <button type="button" data-action="attach-image" aria-label="Attach image" title="Attach image (or paste into the box)" class="${iconButton} mr-auto">${icon('image-plus')}</button>
      <button type="button" data-action="add-comment" disabled class="${buttonPrimary}">Comment</button></div>
  </section>`;
}

function panelTopBar(key, type = '', url = '') {
  const link = url ? `<a href="${esc(url)}" target="_blank" rel="noopener" aria-label="Open in Jira" title="Open in Jira" class="ml-auto ${iconButton}">${icon('external-link')}</a>` : '<span class="ml-auto"></span>';
  return `<div class="flex items-center gap-2 text-sm text-muted"><span class="tabular-nums">${esc(key)}</span>${type ? `<span>·</span><span>${esc(type)}</span>` : ''}
    ${link}<button type="button" data-close-panel aria-label="Close" title="Close" class="${iconButton}">${icon('x')}</button></div>`;
}

function panelHtml(d) {
  return `<div class="border-b border-border px-6 pt-4 pb-4">${panelTopBar(d.key, d.type, d.url)}
      <h2 class="-ml-2.25 mt-1"><textarea data-input="summary" aria-label="Title" class="block w-full resize-none [field-sizing:content] rounded-lg border border-transparent bg-transparent px-2 py-1 text-lg leading-7 font-semibold text-pretty text-foreground outline-hidden transition-colors hover:bg-foreground/5 focus:border-focus focus:ring-2 focus:ring-focus">${esc(d.summary)}</textarea></h2>
    </div>
    <div class="flex-1 overflow-y-auto px-6 py-6"><div class="flex flex-col gap-6">${warningBanner(d)}${propsHtml(d)}${extraFieldsHtml(d)}${linkedHtml(d)}${descriptionHtml(d)}${attachmentsHtml(d)}${commentsHtml(d)}</div></div>`;
}

function panelSkeleton(key) {
  return `<div class="border-b border-border px-6 pt-4 pb-4">${panelTopBar(key)}</div>
    <div class="flex flex-col gap-4 px-6 py-6" aria-busy="true">${skeleton('w-4/5', 'h-4')}${[0, 1, 2, 3, 4, 5].map(() => `<div class="flex items-center gap-4">${skeleton('w-20')}<span class="h-10 flex-1 animate-pulse rounded-xl bg-foreground/5"></span></div>`).join('')}<span class="sr-only" role="status">Loading ${esc(key)}</span></div>`;
}

function panelError(key, message) {
  return `<div class="border-b border-border px-6 pt-4 pb-4">${panelTopBar(key)}</div>
    <div role="alert" class="px-6 py-6"><p class="text-sm font-medium text-danger-text">Cannot load ${esc(key)}</p><p class="mt-1 text-sm text-muted">${esc(message)}</p></div>`;
}

function renderPanel(detail) {
  const draft = compose.key === detail.key ? ($('#comment-input')?.value || '') : '';
  if (compose.key !== detail.key) resetCompose(detail.key);
  state.detail = detail;
  $('#panel').innerHTML = panelHtml(detail);
  if (draft) $('#comment-input').value = draft;
  renderComposeImages();
}

function setPanelOpen(isOpen) {
  $('#panel-root').dataset.open = String(isOpen);
}

async function openPanel(key) {
  closePop();
  state.panelKey = key;
  state.detail = null;
  $('#panel').innerHTML = panelSkeleton(key);
  setPanelOpen(true);
  history.replaceState(null, '', `#${key}`);
  render();
  $('#panel').focus({ preventScroll: true });
  try {
    const detail = await api.issue(key);
    if (state.panelKey === key) renderPanel(detail);
  } catch (error) {
    if (state.panelKey === key) $('#panel').innerHTML = panelError(key, error.message);
  }
}

function closePanel() {
  closePop();
  state.panelKey = null;
  state.detail = null;
  setPanelOpen(false);
  history.replaceState(null, '', location.pathname + location.search);
  render();
}

async function runWrite(action, successMessage) {
  try {
    const detail = await action();
    if (state.detail?.key === detail.key) renderPanel(detail);
    replaceIssue(detail);
    showToast(successMessage);
  } catch (error) {
    showToast(error.message, true);
    if (state.detail) renderPanel(state.detail);
  }
}

function saveField(field, value) {
  const key = state.detail.key;
  return runWrite(() => api.update(key, { [field]: value }), `${key}: saved`);
}

function transitionTo(id) {
  const key = state.detail.key;
  return runWrite(() => api.transition(key, id), `${key}: status changed`);
}

function addComment() {
  const body = composeBody();
  const key = state.detail.key;
  return runWrite(async () => {
    const detail = await api.comment(key, body);
    resetCompose(key);
    $('#comment-input').value = '';
    return detail;
  }, `${key}: comment added`);
}

function toggleDescriptionEdit(isEditing) {
  $('#description-view').hidden = isEditing;
  $('#description-edit').hidden = !isEditing;
  if (isEditing) $('#description-input').focus();
}

const PANEL_ACTIONS = {
  'edit-description': () => toggleDescriptionEdit(true),
  'attach-image': () => $('#comment-file').click(),
  'browse-attachment': () => $('#attachment-file').click(),
  'cancel-description': () => renderPanel(state.detail),
  'save-description': () => saveField('description', $('#description-input').value),
  'add-comment': addComment,
};

const pop = $('#pop');
let popAnchor = null;
let popPick = null;
let popFilter = null;

function placePop(anchor) {
  const rect = anchor.getBoundingClientRect();
  pop.style.minWidth = `${Math.max(rect.width, 224)}px`;
  const height = pop.offsetHeight;
  const below = rect.bottom + 8 + height <= window.innerHeight - 8;
  const top = below ? rect.bottom + 8 : Math.max(8, rect.top - 8 - height);
  const left = Math.min(rect.left, window.innerWidth - pop.offsetWidth - 8);
  Object.assign(pop.style, { top: `${top}px`, left: `${Math.max(8, left)}px`, transformOrigin: below ? 'top left' : 'bottom left' });
}

function openPop(anchor, html, onPick) {
  closePop();
  popAnchor = anchor;
  popPick = onPick;
  anchor.setAttribute('aria-expanded', 'true');
  pop.innerHTML = html;
  pop.hidden = false;
  pop.dataset.state = 'closed';
  placePop(anchor);
  requestAnimationFrame(() => { pop.dataset.state = 'open'; });
}

function closePop() {
  if (!popAnchor) return;
  popAnchor.setAttribute('aria-expanded', 'false');
  popAnchor = null;
  pop.dataset.state = 'closed';
  setTimeout(() => { if (!popAnchor) pop.hidden = true; }, 100);
}

function optionSearch() {
  return `<div class="relative -mx-1 -mt-1 mb-1 border-b border-border">${icon('search', 'pointer-events-none absolute inset-y-0 left-4 my-auto size-4 text-muted')}<input data-option-search type="text" placeholder="Search" aria-label="Search options" class="h-11 w-full bg-transparent pr-3 pl-11 text-sm text-foreground outline-hidden placeholder:text-muted" /></div>`;
}

function checkbox(isChecked) {
  return `<span class="grid size-4 shrink-0 place-items-center rounded border ${isChecked ? 'border-primary bg-primary text-primary-foreground' : 'border-border-strong'}">${isChecked ? icon('check', 'size-3') : ''}</span>`;
}

function optionList(options, current) {
  const search = options.length >= OPTION_SEARCH_MIN ? optionSearch() : '';
  const isMulti = Array.isArray(current);
  return `${search}<div class="flex max-h-76 flex-col overflow-y-auto">${options.map((option) => {
    const isSelected = isMulti ? (option.value ? current.includes(option.value) : !current.length) : option.value === current;
    if (isMulti) return `<button type="button" role="option" aria-selected="${isSelected}" data-pick="${esc(option.value)}" data-label="${esc(option.label)}" class="flex h-10 w-full shrink-0 cursor-pointer items-center gap-2.5 rounded-xl px-3 text-left text-sm text-foreground outline-hidden hover:bg-item-hover focus-visible:bg-item-hover">
      ${checkbox(isSelected)}<span class="flex min-w-0 flex-1 truncate">${option.html || esc(option.label)}</span>${option.hint !== undefined ? `<span class="text-xs tabular-nums text-muted">${option.hint}</span>` : ''}
    </button>`;
    return `<button type="button" role="option" aria-selected="${isSelected}" data-pick="${esc(option.value)}" data-label="${esc(option.label)}" class="flex h-10 w-full shrink-0 cursor-pointer items-center gap-2.5 rounded-xl px-3 text-left text-sm text-foreground outline-hidden hover:bg-item-hover focus-visible:bg-item-hover ${isSelected ? 'font-medium' : ''}">
      <span class="flex min-w-0 flex-1 truncate">${option.html || esc(option.label)}</span>${option.hint !== undefined ? `<span class="text-xs tabular-nums text-muted">${option.hint}</span>` : ''}${isSelected ? icon('check', 'size-4 text-foreground') : '<span class="size-4"></span>'}
    </button>`;
  }).join('')}</div>`;
}

function negateToggle(name) {
  const segment = (isNot, label) => `<button type="button" data-negate="${isNot}" aria-pressed="${state.negate[name] === isNot}" class="h-8 flex-1 cursor-pointer rounded-lg text-sm font-medium text-muted outline-hidden transition-colors hover:text-foreground aria-pressed:bg-surface aria-pressed:text-foreground aria-pressed:shadow-sm">${label}</button>`;
  return `<div class="mb-1 flex gap-1 rounded-xl bg-foreground/5 p-1">${segment(false, 'is')}${segment(true, 'is not')}</div>`;
}

function filterPopHtml(name) {
  const source = name === 'assignee' ? state.issues : scopedIssues();
  const count = (value) => source.filter((issue) => filterValues(name, issue).includes(value)).length;
  const options = [{ value: '', label: 'All', hint: source.length }, ...FILTER_OPTIONS[name](source).map((option) => ({ ...option, hint: count(option.value) }))];
  return negateToggle(name) + optionList(options, state[name]);
}

function toggleFilterValue(name, value) {
  const values = state[name] || [];
  if (!value) return [];
  return values.includes(value) ? values.filter((v) => v !== value) : [...values, value];
}

function openFilter(anchor, name) {
  popFilter = name;
  openPop(anchor, filterPopHtml(name), null);
}

function refreshFilterPop(name) {
  const query = pop.querySelector('[data-option-search]')?.value || '';
  render();
  popAnchor = document.querySelector(`[data-filter="${name}"]`);
  popAnchor.setAttribute('aria-expanded', 'true');
  pop.innerHTML = filterPopHtml(name);
  const search = pop.querySelector('[data-option-search]');
  if (search && query) {
    search.value = query;
    search.dispatchEvent(new Event('input', { bubbles: true }));
  }
}

function setNegate(name, isNot) {
  state.negate[name] = isNot;
  refreshFilterPop(name);
}

function pickFilterValue(name, value) {
  state[name] = toggleFilterValue(name, value);
  refreshFilterPop(name);
}

function withCurrent(values, current) {
  return current && !values.includes(current) ? [current, ...values] : values;
}

function statusOptions(d) {
  const others = d.transitions.filter((t) => t.toId !== d.statusId);
  return [{ value: '', label: d.status, html: statusBadge(d.status) }, ...others.map((t) => ({ value: t.id, label: t.name, html: statusBadge(t.name) }))];
}

function sprintOptions(d) {
  const sprints = [...state.meta.sprints];
  if (d.sprintId && !sprints.some((s) => s.id === d.sprintId)) sprints.unshift({ id: d.sprintId, name: d.sprint });
  return [{ value: '', label: 'No sprint' }, ...sprints.map((s) => ({ value: String(s.id), label: s.name }))];
}

const FIELD_CHOICES = {
  status: { options: statusOptions, current: () => '' },
  falconApp: {
    options: (d) => [{ value: '', label: 'No app' }, ...withCurrent(d.options.falconApp, d.falconApp).map((v) => ({ value: v, label: v, html: appTag(v) }))],
    current: (d) => d.falconApp || '',
  },
  devPoint: {
    options: (d) => [{ value: '', label: 'No points' }, ...withCurrent(d.options.devPoint, d.devPoint).map((v) => ({ value: v, label: v }))],
    current: (d) => d.devPoint || '',
  },
  priority: {
    options: (d) => withCurrent(d.options.priority, d.priority).map((v) => ({ value: v, label: v })),
    current: (d) => d.priority || '',
  },
  sprintId: { options: sprintOptions, current: (d) => (d.sprintId ? String(d.sprintId) : '') },
};

function pickField(name, value) {
  if (name === 'status') return value && transitionTo(value);
  return value !== FIELD_CHOICES[name].current(state.detail) && saveField(name, value);
}

function openField(anchor, name) {
  const d = state.detail;
  if (!d) return;
  if (name === 'dueDate') return openCalendar(anchor, d.dueDate);
  const choice = FIELD_CHOICES[name];
  openPop(anchor, optionList(choice.options(d), choice.current(d)), (value) => pickField(name, value));
}

function calendarDayButton(date, month, selected) {
  const iso = date.toISOString().slice(0, 10);
  const isSelected = iso === selected;
  const isToday = iso === todayIso();
  const isOther = date.getUTCMonth() !== month;
  const cls = isSelected ? 'bg-primary text-primary-foreground' : `hover:bg-item-hover ${isOther ? 'text-muted' : 'text-foreground'}`;
  const dot = isToday ? `<span class="absolute bottom-1.5 size-1 rounded-full ${isSelected ? 'bg-primary-foreground' : 'bg-foreground'}"></span>` : '';
  return `<button type="button" data-pick="${iso}" class="relative grid size-10 cursor-pointer place-items-center rounded-xl text-sm tabular-nums outline-hidden ${cls} ${isToday ? 'font-semibold' : ''}">${date.getUTCDate()}${dot}</button>`;
}

function calendarHtml(selected) {
  const { year, month } = state.calendarMonth;
  const offset = (new Date(Date.UTC(year, month, 1)).getUTCDay() + 6) % 7;
  const cells = Array.from({ length: 42 }, (_, index) => new Date(Date.UTC(year, month, 1 - offset + index)));
  const weekdays = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'].map((day) => `<span class="grid h-8 place-items-center text-xs font-medium text-muted">${day}</span>`).join('');
  const clear = selected ? `<div class="mt-1 border-t border-border pt-1"><button type="button" data-pick="" class="flex h-10 w-full cursor-pointer items-center gap-2.5 rounded-xl px-3 text-sm text-foreground outline-hidden hover:bg-item-hover">${icon('calendar-x', 'size-4 text-muted')}Clear due date</button></div>` : '';
  return `<div class="p-2"><div class="mb-1 flex items-center justify-between pl-2"><span class="text-sm font-semibold text-foreground">${MONTH_NAMES[month]} ${year}</span>
    <span class="flex gap-0.5"><button type="button" data-cal="-1" aria-label="Previous month" class="${iconButton}">${icon('chevron-left')}</button><button type="button" data-cal="1" aria-label="Next month" class="${iconButton}">${icon('chevron-right')}</button></span></div>
    <div class="grid grid-cols-7 gap-y-1">${weekdays}${cells.map((date) => calendarDayButton(date, month, selected)).join('')}</div></div>${clear}`;
}

function openCalendar(anchor, selected) {
  const base = selected || todayIso();
  state.calendarMonth = { year: Number(base.slice(0, 4)), month: Number(base.slice(5, 7)) - 1 };
  openPop(anchor, calendarHtml(selected), (value) => value !== (selected || '') && saveField('dueDate', value));
}

function shiftCalendar(step) {
  const next = new Date(Date.UTC(state.calendarMonth.year, state.calendarMonth.month + step, 1));
  state.calendarMonth = { year: next.getUTCFullYear(), month: next.getUTCMonth() };
  pop.innerHTML = calendarHtml(state.detail?.dueDate);
}

function handlePopClick(target) {
  const cal = target.closest('[data-cal]');
  if (cal) return shiftCalendar(Number(cal.dataset.cal));
  const negate = target.closest('[data-negate]');
  if (negate) return setNegate(popFilter, negate.dataset.negate === 'true');
  const pick = target.closest('[data-pick]');
  if (!pick) return;
  if (!popPick) return pickFilterValue(popFilter, pick.dataset.pick);
  const onPick = popPick;
  closePop();
  onPick(pick.dataset.pick);
}

function setDrawerOpen(isOpen) {
  $('#drawer-root').dataset.open = String(isOpen);
}

const CLICK_ACTIONS = [
  ['[data-sort]', (el) => { state.sort = nextSort(el.dataset.sort); render(); }],
  ['[data-close-panel]', closePanel],
  ['[data-close-drawer]', () => setDrawerOpen(false)],
  ['[data-open-drawer]', () => setDrawerOpen(true)],
  ['[data-list]', (el) => { state.list = el.dataset.list; setDrawerOpen(false); render(); }],
  ['[data-view]', (el) => { state.view = el.dataset.view; setDrawerOpen(false); render(); }],
  ['[data-chip]', (el) => { state[el.dataset.chip] = !state[el.dataset.chip]; render(); }],
  ['[data-clear-search]', () => { state.query = ''; render(); $('#search').focus(); }],
  ['[data-clear]', () => { Object.assign(state, { query: '', status: [], app: [], sprint: [], month: [CURRENT_MONTH], hideDone: false, assignee: [myName()], negate: noNegation() }); render(); }],
  ['[data-toggle]', (el) => { state.expanded.set(el.dataset.toggle, el.getAttribute('aria-expanded') !== 'true'); render(); }],
  ['[data-retry]', loadAll],
  ['[data-action]', (el) => PANEL_ACTIONS[el.dataset.action]?.()],
  ['[data-issue]', (el) => openPanel(el.dataset.issue)],
  ['[data-remove-person]', (el) => savePeople(el.dataset.removePerson, personNames(el.dataset.removePerson).filter((n) => n !== el.dataset.name))],
  ['[data-mention]', (el) => insertMention(el.dataset.mention, el.dataset.display)],
  ['[data-edit-comment]', (el) => startEditComment(el.dataset.editComment)],
  ['[data-save-comment]', (el) => saveCommentEdit(el.dataset.saveComment)],
  ['[data-cancel-comment-edit]', () => renderPanel(state.detail)],
  ['[data-delete-comment]', (el) => deleteCommentWithConfirm(el)],
  ['[data-remove-image]', (el) => { compose.images.splice(Number(el.dataset.removeImage), 1); renderComposeImages(); }],
  ['[data-lightbox]', (el) => openLightbox(el.dataset.lightbox, el.dataset.name)],
  ['[data-close-lightbox]', closeLightbox],
  ['[data-format]', (el) => applyWikiFormat(document.getElementById(el.dataset.target), el.dataset.format)],
  ['[data-preview]', (el) => togglePreview(el)],
  ['[data-add-person]', (el) => savePeople(el.dataset.addPerson, [...personNames(el.dataset.addPerson), el.dataset.name])],
];

function handleClick(event) {
  const target = event.target;
  const imageLink = target.closest('.rich a[file-preview-type="image"]');
  if (imageLink) {
    event.preventDefault();
    const path = decodeURIComponent(new URL(imageLink.href).pathname);
    return openLightbox(`/api/file?path=${encodeURIComponent(path)}`, imageLink.getAttribute('file-preview-title') || '');
  }
  if (!pop.hidden && pop.contains(target)) return handlePopClick(target);
  const opener = target.closest('[data-filter], [data-field]');
  if (opener) {
    if (opener === popAnchor) return closePop();
    return opener.dataset.filter ? openFilter(opener, opener.dataset.filter) : openField(opener, opener.dataset.field);
  }
  closePop();
  closePeopleResults(target.closest('[data-person-results]'));
  if (!target.closest('#mention-results') && $('#mention-results')) $('#mention-results').hidden = true;
  for (const [selector, run] of CLICK_ACTIONS) {
    const el = target.closest(selector);
    if (el) return run(el);
  }
}

function handleInput(event) {
  const target = event.target;
  if (target.matches('[data-option-search]')) {
    const query = target.value.trim().toLowerCase();
    for (const option of pop.querySelectorAll('[data-pick]')) option.hidden = !option.dataset.label.toLowerCase().includes(query);
  } else if (target.id === 'search') {
    state.query = target.value;
    render();
  } else if (target.matches('[data-person-search]')) {
    searchPeople(target);
  } else if (target.id === 'comment-input') {
    updateCommentButton();
    searchMention(target);
  }
}

function handleChange(event) {
  if (event.target.id === 'attachment-file') {
    uploadAttachments(event.target.files);
    event.target.value = '';
    return;
  }
  if (event.target.id === 'comment-file') {
    uploadCommentImages(event.target.files);
    event.target.value = '';
    return;
  }
  const extra = event.target.dataset.extra;
  if (extra && state.detail) return saveField('raw', { [extra]: extraFieldValue(event.target.dataset.kind, event.target.value) });
  const field = event.target.dataset.input;
  if (!field || !state.detail) return;
  const value = event.target.value;
  if (value !== (state.detail[field] ?? '')) saveField(field, value);
}

function handleKeydown(event) {
  if (event.target.id === 'comment-input' && handleOptionKeys(event, $('#mention-results'))) return;
  if (event.target.matches?.('[data-person-search]')
    && handleOptionKeys(event, document.querySelector(`[data-person-results="${event.target.dataset.personSearch}"]`))) return;
  const shortcut = (event.metaKey || event.ctrlKey) && WIKI_SHORTCUTS[event.key.toLowerCase()];
  if (shortcut && ['description-input', 'comment-input'].includes(event.target.id)) {
    event.preventDefault();
    return applyWikiFormat(event.target, shortcut);
  }
  if (event.key === 'Enter' && event.target.dataset?.input === 'summary') {
    event.preventDefault();
    return event.target.blur();
  }
  if (event.key !== 'Escape') return;
  if (!$('#lightbox').hidden) return closeLightbox();
  if (popAnchor) {
    const anchor = popAnchor;
    closePop();
    return anchor.focus();
  }
  if ($('#drawer-root').dataset.open === 'true') return setDrawerOpen(false);
  if (state.panelKey) closePanel();
}

function setDropTarget(column) {
  document.querySelectorAll('[data-drop="true"]').forEach((el) => el !== column && delete el.dataset.drop);
  if (column) column.dataset.drop = 'true';
}

function bindBoardDrag() {
  document.addEventListener('dragstart', (event) => {
    const card = event.target.closest?.('[data-drag]');
    if (card) event.dataTransfer.setData('text/plain', card.dataset.drag);
  });
  document.addEventListener('dragover', (event) => {
    const column = event.target.closest?.('[data-col]');
    if (column) event.preventDefault();
    setDropTarget(column);
  });
  document.addEventListener('dragend', () => setDropTarget(null));
  document.addEventListener('drop', (event) => {
    const column = event.target.closest?.('[data-col]');
    const key = event.dataTransfer.getData('text/plain');
    setDropTarget(null);
    if (!column || !key) return;
    event.preventDefault();
    const name = column.dataset.col;
    const target = state.meta.columns.find((c) => c.name === name);
    const issue = state.issues.find((i) => i.key === key);
    if (target && issue && target.statusIds.includes(issue.statusId)) return;
    showToast(`Moving ${key}…`);
    runWrite(() => api.move(key, name), `${key} → ${name}`);
  });
}

const PANEL_WIDTH_KEY = 'jira.panelWidth';
const PANEL_DEFAULT_WIDTH = 448;
const PANEL_MIN_WIDTH = 360;
const LIST_MIN_WIDTH = 320;
const SMALL_SCREEN_WIDTH = 640;
let panelWidth = PANEL_DEFAULT_WIDTH;

function applyPanelWidth(width) {
  if (window.innerWidth < SMALL_SCREEN_WIDTH) {
    $('#panel').style.width = '';
    return;
  }
  panelWidth = Math.round(Math.min(Math.max(width, PANEL_MIN_WIDTH), Math.max(PANEL_MIN_WIDTH, window.innerWidth - LIST_MIN_WIDTH)));
  $('#panel').style.width = `${panelWidth}px`;
  $('#panel-resizer').style.right = `${panelWidth - 4}px`;
}

function savePanelWidth() {
  try { localStorage.setItem(PANEL_WIDTH_KEY, String(panelWidth)); } catch {}
}

function bindPanelResize() {
  let saved = 0;
  try { saved = Number(localStorage.getItem(PANEL_WIDTH_KEY)) || 0; } catch {}
  applyPanelWidth(saved || PANEL_DEFAULT_WIDTH);
  const resizer = $('#panel-resizer');
  resizer.addEventListener('pointerdown', (event) => {
    event.preventDefault();
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
    const move = (e) => applyPanelWidth(window.innerWidth - e.clientX);
    addEventListener('pointermove', move);
    addEventListener('pointerup', () => {
      removeEventListener('pointermove', move);
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
      savePanelWidth();
    }, { once: true });
  });
  resizer.addEventListener('dblclick', () => { applyPanelWidth(PANEL_DEFAULT_WIDTH); savePanelWidth(); });
  addEventListener('resize', () => applyPanelWidth(panelWidth));
}

function bindEvents() {
  document.addEventListener('click', handleClick);
  document.addEventListener('input', handleInput);
  document.addEventListener('change', handleChange);
  const hasFiles = (event) => event.dataTransfer?.types?.includes('Files');
  document.addEventListener('dragover', (event) => {
    if (!hasFiles(event)) return;
    event.preventDefault();
    document.querySelectorAll('[data-dropzone]').forEach((zone) => zone.toggleAttribute('data-drag-over', zone.contains(event.target)));
  });
  document.addEventListener('dragleave', (event) => {
    if (hasFiles(event) && !event.relatedTarget) document.querySelectorAll('[data-dropzone]').forEach((zone) => zone.removeAttribute('data-drag-over'));
  });
  document.addEventListener('drop', (event) => {
    if (!hasFiles(event)) return;
    event.preventDefault();
    document.querySelectorAll('[data-dropzone]').forEach((zone) => zone.removeAttribute('data-drag-over'));
    if (event.target.closest?.('[data-dropzone]')) uploadAttachments(event.dataTransfer.files);
    else if (event.target.id === 'comment-input') uploadCommentImages(event.dataTransfer.files);
  });
  document.addEventListener('paste', (event) => {
    if (event.target.id !== 'comment-input' || !event.clipboardData?.files.length) return;
    event.preventDefault();
    uploadCommentImages(event.clipboardData.files);
  });
  document.addEventListener('keydown', handleKeydown);
  addEventListener('resize', () => popAnchor && placePop(popAnchor));
  bindBoardDrag();
  bindPanelResize();
  new MutationObserver(() => { if (window.lucide && document.querySelector('i[data-lucide]')) lucide.createIcons(); })
    .observe(document.body, { childList: true, subtree: true });
}

bindEvents();
loadAll().then(() => {
  const key = location.hash.slice(1);
  if (ISSUE_KEY_PATTERN.test(key)) openPanel(key);
});
