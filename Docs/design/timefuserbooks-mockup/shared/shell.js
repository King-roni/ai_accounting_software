/* ============================================================
   Shared app shell + icon set for TimeFuserBooks
   Usage:  <script src="shared/shell.js"></script>
           CB.renderShell({ active: 'dashboard' });
   Page must contain <main class="main" id="main"> ... </main>
   ============================================================ */
(function () {
  const I = {
    chart:'<path d="M3 3v18h18"/><path d="M7 14l3-3 3 3 4-5"/>',
    receipt:'<path d="M4 2v20l2-1 2 1 2-1 2 1 2-1 2 1V2l-2 1-2-1-2 1-2-1-2 1z"/><path d="M8 7h8M8 11h8M8 15h5"/>',
    invoice:'<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M9 13h6M9 17h4"/>',
    doc:'<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/>',
    link:'<path d="M9 17H7A5 5 0 0 1 7 7h2"/><path d="M15 7h2a5 5 0 0 1 0 10h-2"/><path d="M8 12h8"/>',
    ledger:'<path d="M4 4h16v16H4z"/><path d="M4 9h16M9 9v11"/>',
    review:'<path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>',
    period:'<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>',
    report:'<path d="M3 3v18h18"/><rect x="7" y="10" width="3" height="7"/><rect x="12" y="6" width="3" height="11"/><rect x="17" y="13" width="3" height="4"/>',
    sub:'<path d="M3 7a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M3 10h18"/>',
    team:'<circle cx="9" cy="8" r="3"/><path d="M3 20a6 6 0 0 1 12 0"/><path d="M16 5.5a3 3 0 0 1 0 5.8M22 20a6 6 0 0 0-4-5.6"/>',
    clients:'<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
    settings:'<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-2.7 1.1V21a2 2 0 1 1-4 0v-.2a1.6 1.6 0 0 0-2.7-1.1l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.6 1.6 0 0 0 4 15a1.6 1.6 0 0 0-1.5-1H2a2 2 0 1 1 0-4h.2A1.6 1.6 0 0 0 4 8.5a1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1A1.6 1.6 0 0 0 9 4.6h.1A1.6 1.6 0 0 0 10 3.1V3a2 2 0 1 1 4 0v.2a1.6 1.6 0 0 0 2.7 1.1l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8v.1a1.6 1.6 0 0 0 1.5 1h.2a2 2 0 1 1 0 4h-.2a1.6 1.6 0 0 0-1.3.9z"/>',
    help:'<circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.5 2.5 0 0 1 4.5 1.5c0 1.7-2.5 2-2.5 2.5"/><path d="M12 17h.01"/>',
    search:'<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
    bell:'<path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/>',
    sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    moon:'<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>',
    chevL:'<path d="m15 18-6-6 6-6"/>',
    chevR:'<path d="m9 18 6-6-6-6"/>',
    chevD:'<path d="m6 9 6 6 6-6"/>',
    panelLeft:'<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M9 3v18"/>',
    layers:'<path d="M12 2 2 7l10 5 10-5-10-5z"/><path d="M2 12l10 5 10-5M2 17l10 5 10-5"/>',
    x:'<path d="M18 6 6 18M6 6l12 12"/>',
    refresh:'<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>',
    arrowOut:'<path d="M7 17 17 7M8 7h9v9"/>',
    check:'<path d="M20 6 9 17l-5-5"/>',
    pause:'<rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/>',
    play:'<path d="M7 4v16l13-8z"/>',
    clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    stop:'<path d="M7.9 2h8.2L22 7.9v8.2L16.1 22H7.9L2 16.1V7.9z"/><path d="M12 8v4M12 16h.01"/>',
    seal:'<path d="m9 12 2 2 4-4"/><circle cx="12" cy="12" r="9"/>',
    minus:'<path d="M5 12h14"/>',
    lock:'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
    shield:'<path d="M12 2 4 5v6c0 5 3.5 8 8 10 4.5-2 8-5 8-10V5z"/><path d="m9 12 2 2 4-4"/>',
    fingerprint:'<path d="M12 11a2 2 0 0 0-2 2c0 3 1 5 1 5M12 6.5a6 6 0 0 1 6 6c0 3.5-1 5.5-1 5.5M12 6.5a6 6 0 0 0-6 6M16.6 8a8 8 0 0 1 1.4 4.5"/>',
    alertTri:'<path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/>',
    alertCirc:'<circle cx="12" cy="12" r="9"/><path d="M12 8v4M12 16h.01"/>',
    infoCirc:'<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
    snooze:'<circle cx="12" cy="13" r="8"/><path d="M9 4 5 8M19 8l-4-4M9.5 11h5l-5 4h5"/>',
    dot:'<circle cx="12" cy="12" r="3.5"/>',
    plus:'<path d="M12 5v14M5 12h14"/>',
    hash:'<path d="M4 9h16M4 15h16M10 3 8 21M16 3l-2 18"/>',
    upload:'<path d="M12 16V4M7 9l5-5 5 5"/><path d="M4 20h16"/>',
  };
  function svg(name, w) { return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"${w?` width="${w}" height="${w}"`:''}>${I[name]}</svg>`; }

  const PAGES = {
    dashboard: 'Dashboard.html', transactions: 'Transactions.html', invoices: 'Invoices.html',
    documents: 'Documents.html', matching: 'Matching.html', ledger: 'Ledger.html', reviews: 'Reviews.html',
    periods: 'Periods.html', reports: 'Reports.html', subscriptions: 'Subscriptions.html', team: 'Team.html', clients: 'Clients.html',
    settings: 'Settings.html', help: 'Help.html',
  };

  const NAV = [
    { group: null, items: [['dashboard','Dashboard','chart',null]] },
    { group: 'Workspace', items: [
      ['transactions','Transactions','receipt',null],
      ['invoices','Invoices','invoice',null],
      ['documents','Documents','doc',null],
      ['matching','Matching','link','12'],
      ['ledger','Ledger','ledger',null],
      ['reviews','Reviews','review','7','danger'],
      ['periods','Periods','period',null],
      ['reports','Reports','report',null],
    ]},
    { group: 'Organisation', items: [
      ['subscriptions','Subscriptions','sub',null],
      ['team','Team','team',null],
      ['clients','Clients','clients',null],
    ]},
  ];

  function setTheme(t) {
    document.documentElement.setAttribute('data-theme', t);
    const b = document.getElementById('themeBtn');
    if (b) b.innerHTML = svg(t === 'dark' ? 'sun' : 'moon');
    try { localStorage.setItem('cb-theme', t); } catch (e) {}
  }
  function initTheme() { try { const s = localStorage.getItem('cb-theme'); if (s) setTheme(s); } catch (e) {} }

  const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  let periodIdx = 4, periodYear = 2026; // May 2026

  function renderShell(opts) {
    opts = opts || {};
    const active = opts.active || 'dashboard';
    initTheme();

    // ---- topbar ----
    const topbar = document.createElement('div');
    topbar.className = 'topbar';
    topbar.innerHTML = `
      <a class="tb-logo" href="Dashboard.html" style="text-decoration:none;color:inherit;">
        <span class="mark">${svg('chart',16)}</span>
        <span class="word">TimeFuser<b>Books</b></span>
      </a>
      <span class="tb-div"></span>
      <div class="switcher" id="bizSwitcher" title="Switch business">
        <span class="av" style="background:var(--brand)">DT</span>
        <span><span class="nm">Demo Trading Ltd</span></span>
        <span class="caret">${svg('chevD')}</span>
      </div>
      <div class="period" title="Active period — re-scopes everything">
        <button id="periodPrev">${svg('chevL')}</button>
        <div class="val"><span class="m" id="periodVal">May 2026</span><span class="lbl">Active period</span></div>
        <button id="periodNext">${svg('chevR')}</button>
      </div>
      <span class="tb-spacer"></span>
      <div class="tb-search"><span>${svg('search')}</span><span class="ph">Search…</span><kbd>⌘K</kbd></div>
      <button class="tb-icon" title="Notifications">${svg('bell')}<span class="dot"></span></button>
      <div class="tb-lang"><button class="on">EN</button><button>Ελ</button></div>
      <button class="tb-icon" id="themeBtn" title="Theme" onclick="CB.toggleTheme()">${svg('moon')}</button>
      <span class="tb-div"></span>
      <div class="tb-user"><span class="uav">AK</span><span class="caret" style="color:var(--text-muted)">${svg('chevD')}</span></div>
    `;

    // ---- sidebar ----
    const sidebar = document.createElement('nav');
    sidebar.className = 'sidebar';
    sidebar.id = 'sidebar';
    let navHTML = '';
    NAV.forEach(sec => {
      if (sec.group) navHTML += `<div class="nav-group-label">${sec.group}</div>`;
      sec.items.forEach(([id, label, icon, count, danger]) => {
        const href = PAGES[id] || '#';
        navHTML += `<a class="nav-item${id === active ? ' active' : ''}${danger ? ' danger' : ''}" href="${href}" title="${label}">
          ${svg(icon)}<span class="nav-label">${label}</span>${count ? `<span class="nav-count">${count}</span>` : ''}</a>`;
      });
    });
    navHTML += `<div class="spacer"></div>`;
    navHTML += `<div class="nav-group-label">System</div>`;
    navHTML += `<a class="nav-item${active==='settings'?' active':''}" href="Settings.html">${svg('settings')}<span class="nav-label">Settings</span></a>`;
    navHTML += `<a class="nav-item${active==='help'?' active':''}" href="Help.html">${svg('help')}<span class="nav-label">Help</span></a>`;
    navHTML += `<button class="collapse-btn" onclick="CB.toggleSidebar()">${svg('panelLeft')}<span class="nav-label">Collapse</span></button>`;
    sidebar.innerHTML = navHTML;

    // ---- assemble ----
    const main = document.getElementById('main');
    const appBody = document.createElement('div');
    appBody.className = 'app-body';
    document.body.insertBefore(topbar, document.body.firstChild);
    document.body.insertBefore(appBody, main);
    appBody.appendChild(sidebar);
    appBody.appendChild(main);
    document.body.classList.add('app-shell');

    // ---- wire period switcher ----
    function paint() { document.getElementById('periodVal').textContent = `${MONTHS[periodIdx]} ${periodYear}`; }
    document.getElementById('periodPrev').onclick = () => { periodIdx--; if (periodIdx < 0) { periodIdx = 11; periodYear--; } paint(); };
    document.getElementById('periodNext').onclick = () => { periodIdx++; if (periodIdx > 11) { periodIdx = 0; periodYear++; } paint(); };
  }

  window.CB = {
    svg, renderShell,
    toggleTheme() { const cur = document.documentElement.getAttribute('data-theme'); setTheme(cur === 'dark' ? 'light' : 'dark'); },
    setTheme,
    toggleSidebar() { document.getElementById('sidebar').classList.toggle('collapsed'); },
    icon: svg,
  };
})();
