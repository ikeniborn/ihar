/*
 * The console window's behaviour (LLD 13.2).
 *
 * Everything here reads the broker's own routes: the sidebar from /api/sidebar, a tab's
 * bytes from /ws/<sid>, a chain from /api/thread, a project's enforcement from
 * /api/check. Nothing is fetched from the network, and nothing is stored — reloading the
 * page rebuilds the view from the broker, and the terminal's scrollback is replayed by
 * the supervisor that owns it.
 */

'use strict';

const state = {
  projects: [],
  tabs: new Map(),      // sid -> {term, socket, label}
  active: null,
  statuses: new Map(),  // ihar_id -> last status, to notify on a change
  notify: false,
};

const el = (id) => document.getElementById(id);

async function api(path, options) {
  const response = await fetch(path, Object.assign({ credentials: 'same-origin' }, options));
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return response.json();
}

/* ------------------------------------------------------------------ sidebar */

function sessionRow(project, session) {
  const row = document.createElement('div');
  row.className = 'session';
  row.dataset.status = session.status || 'unknown';
  row.innerHTML = '<span class="dot"></span>';

  const body = document.createElement('div');
  const name = document.createElement('span');
  name.className = 'name';
  name.textContent = session.title || session.vendor_session_id || session.ihar_id;
  const meta = document.createElement('span');
  meta.className = 'meta';
  meta.textContent = [session.vendor, session.profile, session.status,
                      session.git_branch].filter(Boolean).join(' · ');
  body.append(name, meta);

  const actions = document.createElement('div');
  actions.className = 'actions';
  if (session.tab) {
    actions.append(button('open', () => {
      if (state.tabs.has(session.tab.sid)) select(session.tab.sid);
      else if (session.tab.kind === 'acp') attachChat(session.tab.sid, session.vendor, session.tab.caveats);
      else attach(session.tab.sid, session.vendor);
    }));
  }
  actions.append(
    button('history', () => showHistory(project, session)),
    button('rename', () => rename(project, session)),
    button('switch', () => askSwitch(project, session)),
  );
  body.append(actions);
  row.append(body);
  return row;
}

function button(label, onClick) {
  const element = document.createElement('button');
  element.textContent = label;
  element.addEventListener('click', (event) => { event.stopPropagation(); onClick(); });
  return element;
}

function drawSidebar(view) {
  state.projects = view.projects || [];
  const container = el('projects');
  container.replaceChildren();
  for (const project of state.projects) {
    const block = document.createElement('div');
    block.className = 'project';
    const heading = document.createElement('h2');
    heading.textContent = project.project_root.split('/').pop() || project.project_root;
    heading.title = project.project_root;
    heading.append(
      button('launch', () => askLaunch(project)),
      button('check', () => showCheck(project)),
    );
    block.append(heading);
    if (project.error) {
      const problem = document.createElement('div');
      problem.className = 'error';
      problem.textContent = `unreadable: ${project.error}`;
      block.append(problem);
    }
    for (const session of project.sessions || []) {
      block.append(sessionRow(project, session));
      announce(session);
    }
    container.append(block);
  }
  el('reach').textContent = `${state.projects.length} project state(s) in reach`;
}

/* A session that starts waiting for a human is the one thing worth interrupting for. */
function announce(session) {
  const previous = state.statuses.get(session.ihar_id);
  state.statuses.set(session.ihar_id, session.status);
  if (!state.notify || previous === session.status) return;
  if (session.status !== 'waiting-approval' && session.status !== 'stopped') return;
  const what = session.status === 'waiting-approval' ? 'is waiting for you' : 'has stopped';
  new Notification(`${session.title || session.vendor} ${what}`,
                   { body: session.vendor_session_id || '', tag: session.ihar_id });
}

async function refresh(force) {
  try {
    drawSidebar(await api(`/api/sidebar${force ? '?refresh=1' : ''}`));
  } catch (error) {
    el('reach').textContent = String(error);
  }
}

/* --------------------------------------------------------------------- tabs */

function select(sid) {
  state.active = sid;
  for (const [id, tab] of state.tabs) {
    tab.element.hidden = id !== sid;
  }
  for (const node of el('tabs').children) {
    node.setAttribute('aria-selected', String(node.dataset.sid === sid));
  }
  el('empty').hidden = state.tabs.size > 0;
  const tab = state.tabs.get(sid);
  if (tab && tab.term) { tab.term.focus(); fit(tab); }
}

function fit(tab) {
  /* xterm ships no fitting in its core bundle; one measured cell is enough for it. */
  const probe = tab.element.querySelector('.xterm-char-measure-element') ||
                tab.element.querySelector('.xterm-rows > div');
  const rect = tab.element.getBoundingClientRect();
  const cell = probe ? probe.getBoundingClientRect() : { width: 9, height: 17 };
  const cols = Math.max(20, Math.floor(rect.width / (cell.width || 9)) - 1);
  const rows = Math.max(6, Math.floor(rect.height / (cell.height || 17)) - 1);
  tab.term.resize(cols, rows);
  if (tab.socket && tab.socket.readyState === WebSocket.OPEN) {
    tab.socket.send(JSON.stringify({ type: 'resize', cols, rows }));
  }
}

/* ------------------------------------------------------------------- chat */

function chatRow(className, who, text) {
  const row = document.createElement('div');
  row.className = `row ${className}`;
  const label = document.createElement('div');
  label.className = 'who';
  label.textContent = who;
  const body = document.createElement('div');
  body.className = 'text';
  body.textContent = text;
  row.append(label, body);
  return row;
}

function chatEvent(tab, event) {
  const log = tab.element.querySelector('.log');
  if (event.type === 'update') {
    const update = event.update || {};
    const text = (update.content && update.content.text) || update.title || '';
    if (update.sessionUpdate === 'user_message_chunk') log.append(chatRow('user', 'you', text));
    else if (update.sessionUpdate === 'agent_message_chunk') log.append(chatRow('agent', tab.label, text));
    else if (update.sessionUpdate === 'agent_thought_chunk') log.append(chatRow('thought', 'thinking', text));
    else if (update.sessionUpdate === 'tool_call' || update.sessionUpdate === 'tool_call_update') {
      log.append(chatRow('tool', `tool · ${update.status || ''}`, update.title || update.toolCallId || ''));
    }
  } else if (event.type === 'permission') {
    const row = chatRow('permission', 'permission', (event.tool_call || {}).title || 'the agent asks to act');
    const options = document.createElement('div');
    options.className = 'options';
    for (const option of event.options || []) {
      options.append(button(option.name || option.optionId, () => {
        send(tab, { type: 'permission', request_id: event.request_id, option_id: option.optionId });
        options.replaceChildren(Object.assign(document.createElement('span'),
                                              { textContent: `answered: ${option.name}` }));
      }));
    }
    row.append(options);
    log.append(row);
  } else if (event.type === 'refused') {
    log.append(chatRow('refused', 'refused', `the agent asked for ${event.method}, which this console does not offer`));
  } else if (event.type === 'error' || event.type === 'agent-stderr') {
    log.append(chatRow('error', event.type, event.text || ''));
  } else if (event.type === 'exit') {
    log.append(chatRow('error', 'exit', `the agent exited with code ${event.code}`));
  } else if (event.type === 'turn-end') {
    log.append(chatRow('tool', 'turn', `ended: ${event.stop_reason || 'unknown'}`));
  }
  log.scrollTop = log.scrollHeight;
}

function send(tab, message) {
  if (tab.socket && tab.socket.readyState === WebSocket.OPEN) {
    tab.socket.send(JSON.stringify({ type: 'input', data: JSON.stringify(message) }));
  }
}

function attachChat(sid, label, caveats) {
  if (state.tabs.has(sid)) { select(sid); return; }

  const element = document.createElement('div');
  element.className = 'chat';
  const notice = document.createElement('p');
  notice.className = 'caveats';
  notice.innerHTML = 'This tab is an experimental ACP chat, not the agent\'s own interface. ' +
    'It does not carry:';
  const list = document.createElement('ul');
  for (const caveat of caveats || []) {
    const item = document.createElement('li');
    item.textContent = caveat;
    list.append(item);
  }
  notice.append(list);

  const log = document.createElement('div');
  log.className = 'log';
  const form = document.createElement('form');
  const input = document.createElement('textarea');
  input.placeholder = 'Message the agent…';
  const stop = button('cancel', () => send(state.tabs.get(sid), { type: 'cancel' }));
  form.append(input, stop);
  element.append(notice, log, form);
  el('terminal').append(element);

  const socket = new WebSocket(`ws://${location.host}/ws/${sid}`);
  socket.binaryType = 'arraybuffer';
  const tab = { socket, element, label, kind: 'acp' };
  state.tabs.set(sid, tab);

  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    send(tab, { type: 'prompt', text });
    input.value = '';
  });

  socket.addEventListener('message', (event) => {
    const payload = typeof event.data === 'string'
      ? event.data : new TextDecoder().decode(new Uint8Array(event.data));
    for (const line of payload.split('\n')) {
      if (!line.trim()) continue;
      try { chatEvent(tab, JSON.parse(line)); } catch (error) { /* a partial line */ }
    }
  });
  socket.addEventListener('close', () => {
    log.append(chatRow('error', 'detached', 'the conversation keeps running; reattach to follow it'));
  });

  const header = document.createElement('button');
  header.dataset.sid = sid;
  header.textContent = `${label} · chat`;
  header.addEventListener('click', () => select(sid));
  el('tabs').append(header);
  select(sid);
}

function attach(sid, label) {
  if (state.tabs.has(sid)) { select(sid); return; }

  const element = document.createElement('div');
  element.style.height = '100%';
  el('terminal').append(element);

  const term = new Terminal({
    convertEol: false,
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
    fontSize: 13,
    theme: { background: '#12131a', foreground: '#d6d9e3' },
  });
  term.open(element);

  const socket = new WebSocket(`ws://${location.host}/ws/${sid}`);
  socket.binaryType = 'arraybuffer';
  const tab = { term, socket, element, label };
  state.tabs.set(sid, tab);

  socket.addEventListener('message', (event) => {
    if (typeof event.data === 'string') {
      const message = JSON.parse(event.data);
      if (message.type === 'exit') {
        term.write(`\r\n\x1b[33m[ihar] the session exited with code ${message.code}\x1b[0m\r\n`);
      }
      return;
    }
    term.write(new Uint8Array(event.data));
  });
  socket.addEventListener('open', () => fit(tab));
  socket.addEventListener('close', () => {
    term.write('\r\n\x1b[90m[ihar] detached from this tab; the session keeps running\x1b[0m\r\n');
  });
  term.onData((data) => {
    if (socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ type: 'input', data }));
    }
  });

  const header = document.createElement('button');
  header.dataset.sid = sid;
  header.textContent = label;
  header.addEventListener('click', () => select(sid));
  el('tabs').append(header);
  select(sid);
}

async function launch(project, vendor, kind) {
  const response = await fetch('/api/tabs', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ project_root: project.project_root, vendor, kind }),
  });
  const tab = await response.json().catch(() => ({}));
  if (!response.ok) {
    alert(`the tab was refused: ${tab.error || response.status}`);
    return;
  }
  const label = `${vendor} · ${project.project_root.split('/').pop()}`;
  if (kind === 'acp') attachChat(tab.sid, label, tab.caveats);
  else attach(tab.sid, label);
  refresh(true);
}

/* ------------------------------------------------------------- side panels */

async function showHistory(project, session) {
  el('check').hidden = true;
  const pane = el('history');
  pane.hidden = false;
  el('history-title').textContent = `history · ${session.title || session.vendor}`;
  const items = el('history-items');
  items.replaceChildren(Object.assign(document.createElement('div'),
                                      { className: 'entry gap', textContent: 'reading…' }));
  let thread;
  try {
    thread = await api(`/api/thread/${project.state_id}/${session.ihar_id}`);
  } catch (error) {
    items.replaceChildren(Object.assign(document.createElement('div'),
                                        { className: 'entry gap', textContent: String(error) }));
    return;
  }
  items.replaceChildren();
  for (const item of thread.items || []) {
    const entry = document.createElement('div');
    if (item.kind === 'handoff') {
      entry.className = 'entry handoff';
      entry.textContent = `handoff → ${item.target_vendor || 'the other agent'}: ` +
        `${item.bytes || '?'} bytes, masking ${item.masking_level || 'off'}, ` +
        `history ${item.history_mode || 'summary'}. ${item.note}`;
    } else {
      entry.className = 'entry';
      const who = document.createElement('div');
      who.className = 'who';
      who.textContent = [item.role, item.vendor, item.at].filter(Boolean).join(' · ');
      const text = document.createElement('div');
      text.className = 'text';
      text.textContent = item.text || '';
      entry.append(who, text);
    }
    items.append(entry);
  }
  for (const gap of thread.gaps || []) {
    const entry = document.createElement('div');
    entry.className = 'entry gap';
    entry.textContent = `gap: ${gap.reason}`;
    items.append(entry);
  }
  if (thread.truncated) {
    const entry = document.createElement('div');
    entry.className = 'entry gap';
    entry.textContent = 'the projection was truncated; open the session to read the rest';
    items.append(entry);
  }
}

async function showCheck(project) {
  el('history').hidden = true;
  el('check').hidden = false;
  el('check-title').textContent = `check · ${project.project_root.split('/').pop()}`;
  const body = el('check-body');
  body.textContent = 'reading…';
  try {
    const report = await api(`/api/check/${project.state_id}`);
    body.textContent = report.text || JSON.stringify(report, null, 2);
  } catch (error) {
    body.textContent = String(error);
  }
}

/* ------------------------------------------------------------------ actions */

async function rename(project, session) {
  const title = prompt('New title for this session', session.title || '');
  if (!title) return;
  await api(`/api/sessions/${project.state_id}/${session.ihar_id}/name`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title }),
  }).catch((error) => alert(String(error)));
  refresh(true);
}

function askLaunch(project) {
  el('launch-project').textContent = project.project_root;
  const caveats = el('launch-caveats');
  const describe = () => {
    const chat = el('launch-kind').value === 'acp';
    caveats.hidden = !chat;
    caveats.textContent = chat
      ? 'A chat tab is experimental: it does not carry the profile\'s hook or sandbox ' +
        'guarantees, and a profile that refuses ACP will refuse it.'
      : '';
  };
  el('launch-kind').onchange = describe;
  describe();
  el('launch').returnValue = 'cancel';
  el('launch').showModal();
  el('launch').addEventListener('close', function once() {
    el('launch').removeEventListener('close', once);
    if (el('launch').returnValue === 'go') {
      launch(project, el('launch-vendor').value, el('launch-kind').value);
    }
  });
}

function askSwitch(project, session) {
  el('switch-session').textContent =
    `${session.title || session.vendor_session_id} runs on ${session.vendor}`;
  el('switch-vendor').value = session.vendor === 'claude' ? 'codex' : 'claude';
  el('switch').returnValue = 'cancel';
  el('switch').showModal();
  el('switch').addEventListener('close', async function once() {
    el('switch').removeEventListener('close', once);
    if (el('switch').returnValue !== 'go') return;
    const tab = await api(`/api/sessions/${project.state_id}/${session.ihar_id}/switch`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ to: el('switch-vendor').value,
                             history: el('switch-history').value }),
    }).catch((error) => { alert(String(error)); return null; });
    if (tab) {
      attach(tab.sid, `switch → ${el('switch-vendor').value}`);
      refresh(true);
    }
  });
}

/* --------------------------------------------------------------------- boot */

for (const node of document.querySelectorAll('[data-close]')) {
  node.addEventListener('click', () => { el(node.dataset.close).hidden = true; });
}
el('refresh').addEventListener('click', () => refresh(true));
window.addEventListener('resize', () => {
  const tab = state.tabs.get(state.active);
  if (tab && tab.term) fit(tab);
});

if ('Notification' in window) {
  if (Notification.permission === 'granted') {
    state.notify = true;
  } else if (Notification.permission !== 'denied') {
    Notification.requestPermission().then((answer) => { state.notify = answer === 'granted'; });
  }
}

refresh(true);
setInterval(refresh, 3000);
