(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const login = $('login'), list = $('list'), detail = $('detail'), back = $('back');
  const status = $('connection'), toast = $('toast'), logout = $('logout');
  let ws = null, selected = null, reconnectMs = 1000, reconnectTimer = null;
  let openedOnce = false, manuallyLoggedOut = false;
  const textInput = $('text');

  function showToast(message) {
    toast.textContent = message;
    toast.classList.add('show');
    setTimeout(() => toast.classList.remove('show'), 1800);
  }
  function showList() {
    detail.classList.add('hidden'); list.classList.remove('hidden'); back.classList.add('hidden'); selected = null;
  }
  function send(value) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return showToast('连接不可用');
    ws.send(JSON.stringify(value));
  }
  function command(type, extra = {}) {
    if (!selected) return;
    send(Object.assign({type, pane_id: selected.pane_id, pane_ref: selected.pane_ref}, extra));
  }
  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function render(panes) {
    const fragment = document.createDocumentFragment();
    for (const groupStatus of ['blocked', 'working', 'idle', 'done', 'unknown']) {
      const members = panes.filter(p => p.agent_status === groupStatus);
      if (!members.length) continue;
      const group = element('section', 'group');
      group.appendChild(element('h2', '', `${groupStatus} · ${members.length}`));
      for (const pane of members) {
        const button = element('button', 'pane'); button.type = 'button';
        const title = element('strong'); title.appendChild(element('span', `status-dot ${groupStatus}`));
        title.appendChild(document.createTextNode(pane.title));
        button.appendChild(title); button.appendChild(element('small', '', pane.cwd || pane.workspace_id));
        button.addEventListener('click', () => openPane(pane)); group.appendChild(button);
      }
      fragment.appendChild(group);
    }
    list.replaceChildren(fragment);
  }
  function openPane(pane) {
    selected = pane; list.classList.add('hidden'); detail.classList.remove('hidden'); back.classList.remove('hidden');
    $('detail-agent').textContent = `${pane.title} · ${pane.agent_status}`;
    $('detail-meta').textContent = pane.cwd || pane.workspace_id;
    $('output').textContent = '读取中…';
    send({type: 'subscribe', pane_id: pane.pane_id, pane_ref: pane.pane_ref, lines: 160});
  }
  function connect() {
    if (manuallyLoggedOut || (ws && ws.readyState < WebSocket.CLOSING)) return;
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    ws = new WebSocket(`${scheme}://${location.host}/ws`);
    ws.addEventListener('open', () => {
      openedOnce = true; reconnectMs = 1000; status.textContent = '在线'; status.className = 'online';
      login.classList.add('hidden'); logout.classList.remove('hidden');
      if (!selected) list.classList.remove('hidden');
    });
    ws.addEventListener('message', event => {
      let message; try { message = JSON.parse(event.data); } catch (_) { return; }
      if (message.type === 'snapshot') {
        render(message.panes);
        if (selected) {
          const fresh = message.panes.find(p => p.pane_id === selected.pane_id && p.pane_ref === selected.pane_ref);
          if (!fresh) { showToast('Pane 已变化，请重新选择'); showList(); }
          else selected = fresh;
        }
      } else if (message.type === 'output' && selected && message.pane_id === selected.pane_id) {
        const output = $('output'), nearBottom = output.scrollHeight - output.scrollTop - output.clientHeight < 80;
        output.textContent = message.text; if (nearBottom) output.scrollTop = output.scrollHeight;
      } else if (message.type === 'error') showToast(message.error);
    });
    ws.addEventListener('close', event => {
      ws = null; status.textContent = '离线'; status.className = 'offline';
      logout.classList.add('hidden');
      if (!openedOnce || event.code === 1008) login.classList.remove('hidden');
      if (!window.HerdrReconnectPolicy.shouldReconnect({
        manuallyLoggedOut, closeCode: event.code,
      })) {
        if (event.code === 1008) openedOnce = false;
        return;
      }
      reconnectTimer = setTimeout(connect, reconnectMs);
      reconnectMs = Math.min(reconnectMs * 2, 15000);
    });
  }

  $('login-form').addEventListener('submit', async event => {
    event.preventDefault(); const token = $('token').value; $('login-error').textContent = '';
    try {
      const response = await fetch('/api/session', {method: 'POST', headers: {Authorization: `Bearer ${token}`}});
      $('token').value = '';
      if (!response.ok) throw new Error('token 无效');
      manuallyLoggedOut = false;
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
      if (ws) ws.close(); else connect();
    } catch (error) { $('login-error').textContent = error.message; }
  });
  logout.addEventListener('click', async () => {
    try {
      const response = await fetch('/api/logout', {method: 'POST'});
      if (!response.ok) throw new Error('注销失败');
      manuallyLoggedOut = true; openedOnce = false; selected = null;
      if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
      if (ws) ws.close();
      detail.classList.add('hidden'); list.classList.add('hidden'); back.classList.add('hidden');
      logout.classList.add('hidden'); login.classList.remove('hidden');
      status.textContent = '离线'; status.className = 'offline';
    } catch (error) { showToast(error.message); }
  });
  back.addEventListener('click', showList);
  $('send-form').addEventListener('submit', event => {
    event.preventDefault(); const text = textInput.value;
    if (!text || text.split('\n').length > 20) return showToast('请输入不超过 20 行的文字');
    command('send_text', {text}); textInput.value = '';
  });
  $('enter').addEventListener('click', () => command('send_keys', {keys: ['Enter']}));
  const popups = [
    {toggle: $('ctrl-menu-toggle'), popup: $('ctrl-popup')},
    {toggle: $('arrow-toggle'), popup: $('arrow-popup')},
  ];
  function closePopups() {
    for (const item of popups) {
      item.popup.classList.add('hidden');
      item.toggle.setAttribute('aria-expanded', 'false');
    }
  }
  function togglePopup(item) {
    const opening = item.popup.classList.contains('hidden');
    closePopups();
    if (opening) {
      item.popup.classList.remove('hidden');
      item.toggle.setAttribute('aria-expanded', 'true');
    }
  }
  detail.addEventListener('click', event => {
    const button = event.target.closest('button');
    if (!button) return;
    if (button.dataset.key) {
      command('send_keys', {keys: [button.dataset.key]});
      closePopups();
    } else if (button.dataset.text) {
      command('send_text', {text: button.dataset.text});
    } else if (button.dataset.action) {
      command('action', {action: button.dataset.action});
    } else if (button.id === 'ctrl-menu-toggle') {
      togglePopup(popups[0]);
    } else if (button.id === 'arrow-toggle') {
      togglePopup(popups[1]);
    }
  });
  document.addEventListener('click', event => {
    if (!event.target.closest('.popup-toggle')) closePopups();
  });
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
  connect();
})();
