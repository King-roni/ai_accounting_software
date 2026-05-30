/* ============================================================
   Periods — run data + run-detail / step-up rendering
   Depends on shell.js (CB.icon). Exposes window.PER
   ============================================================ */
(function () {
  const icon = (n, w) => CB.icon(n, w);

  // run status -> [badge tone, icon, label]
  const STATUS = {
    CREATED:          ['neutral', 'plus',   'Created'],
    RUNNING:          ['info',    'loader', 'Running'],
    PAUSED:           ['neutral', 'pause',  'Paused'],
    REVIEW_HOLD:      ['warning', 'pause',  'Review hold'],
    AWAITING_APPROVAL:['warning', 'clock',  'Awaiting approval'],
    FINALIZING:       ['info',    'loader', 'Finalizing'],
    FINALIZED:        ['seal',    'seal',   'Finalized'],
    FAILED:           ['danger',  'stop',   'Failed'],
    CANCELLED:        ['neutral', 'x',      'Cancelled'],
    COMPENSATING:     ['warning', 'refresh','Compensating'],
    ABORTED:          ['danger',  'stop',   'Aborted'],
  };
  // phase status -> [color var, icon, label]
  const PHASE = {
    COMPLETED: ['var(--income-text)',        'check',  'Completed'],
    RUNNING:   ['var(--brand)',              'loader', 'Running'],
    PENDING:   ['var(--text-muted)',         'dot',    'Pending'],
    FAILED:    ['var(--expense-text)',       'stop',   'Failed'],
    SKIPPED:   ['var(--text-muted)',         'minus',  'Skipped'],
    HOLDING:   ['var(--badge-warning-text)', 'pause',  'Holding'],
  };
  const GATE_CHIP = { Advance: 'success', Hold: 'warning', 'Side-phase': 'info' };

  function P(name, status, opt, gate) { return { name, status, opt: !!opt, gate: gate || null }; }
  function G(label, pass, reason) { return { label, pass, reason }; }

  const OUT_DONE = [
    P('Ingestion','COMPLETED',0,'Advance'),
    P('Classification','COMPLETED',0,'Advance'),
    P('Out-filter','COMPLETED',0,'Advance'),
    P('Evidence discovery · email','COMPLETED',1,'Side-phase'),
    P('Evidence discovery · drive','COMPLETED',1,'Side-phase'),
    P('Matching','COMPLETED',0,'Advance'),
    P('Manual-upload hold','SKIPPED',1,null),
    P('Ledger preparation','COMPLETED',0,'Advance'),
    P('AI end-scan','COMPLETED',0,'Hold'),
    P('Human-review hold','HOLDING',1,'Hold'),
    P('Finalization','PENDING',0,null),
  ];
  const OUT_READY = OUT_DONE.map((p,i) => {
    if (p.name === 'Human-review hold') return P(p.name,'COMPLETED',1,'Advance');
    if (p.name === 'AI end-scan') return P(p.name,'COMPLETED',0,'Advance');
    return { ...p };
  });
  const IN_RUNNING = [
    P('Ingestion','COMPLETED',0,'Advance'),
    P('Classification','COMPLETED',0,'Advance'),
    P('In-filter','COMPLETED',0,'Advance'),
    P('Matching','RUNNING',0,null),
    P('Ledger preparation','PENDING',0,null),
    P('AI end-scan','PENDING',0,null),
    P('Human-review hold','PENDING',1,null),
    P('Finalization','PENDING',0,null),
  ];
  const ALL_DONE_OUT = OUT_DONE.map(p => p.name==='Finalization' ? P(p.name,'COMPLETED',0,'Advance') : (p.status==='HOLDING'?P(p.name,'COMPLETED',1,'Advance'):(p.status==='SKIPPED'?{...p}:P(p.name,'COMPLETED',p.opt,p.gate||'Advance'))));

  const GATES_DENIED = [
    G('Transactions processed', true,  '248 of 248 statement lines processed'),
    G('No unknown types',       true,  '0 UNKNOWN classifications remain'),
    G('VAT complete',           true,  'Input & output VAT reconciled'),
    G('Ledger entries complete',true,  '312 entries prepared and balanced'),
    G('Evidence satisfied',     false, '40 receipts still missing evidence'),
    G('No blocking issues',     false, '1 blocking review item is open'),
    G('Audit quiescent',        true,  'No pending audit events'),
    G('Approval recorded',      false, 'Awaiting human-review sign-off'),
    G('Step-up approval present',false,'Step-up authentication not yet provided'),
  ];
  const GATES_READY = [
    G('Transactions processed', true,  '64 of 64 adjustment lines processed'),
    G('No unknown types',       true,  '0 UNKNOWN classifications remain'),
    G('VAT complete',           true,  'Input & output VAT reconciled'),
    G('Ledger entries complete',true,  '88 entries prepared and balanced'),
    G('Evidence satisfied',     true,  'All evidence linked'),
    G('No blocking issues',     true,  'No open blocking items'),
    G('Audit quiescent',        true,  'No pending audit events'),
    G('Approval recorded',      true,  'Reviewer sign-off recorded · A. Kyriacou'),
    G('Step-up approval present',false,'Provide step-up authentication to seal'),
  ];

  const RUNS = {
    'may-out': { period:'May 2026', type:'OUT_MONTHLY', kind:'OUT', status:'REVIEW_HOLD',
      phases: OUT_DONE, gates: GATES_DENIED, money:'−€45,670.00', lines:248 },
    'may-in':  { period:'May 2026', type:'IN_MONTHLY', kind:'IN', status:'RUNNING',
      phases: IN_RUNNING, gates: null, money:'+€64,210.00', lines:96 },
    'mar-adj': { period:'March 2026', type:'OUT_ADJUSTMENT', kind:'OUT', status:'AWAITING_APPROVAL',
      phases: ALL_DONE_OUT, gates: GATES_READY, money:'−€2,140.00', lines:64, ready:true },
  };

  function statusBadge(status) {
    const [tone, ic, label] = STATUS[status];
    const cls = tone === 'seal' ? 'badge badge-seal' : `badge badge-${tone}`;
    const sp = (status === 'RUNNING' || status === 'FINALIZING') ? ' class="spin"' : '';
    return `<span class="${cls}"><span${sp} style="display:inline-flex">${icon(ic)}</span>${label}</span>`;
  }

  function phaseRow(p, i, total) {
    const [color, ic, label] = PHASE[p.status];
    const last = i === total - 1;
    const spin = p.status === 'RUNNING' ? ' spin' : '';
    return `<div class="phase ${p.status === 'RUNNING' ? 'active' : ''} ${p.opt ? 'opt' : ''}">
      <div class="phase-rail">
        <span class="phase-dot" style="--c:${color}"><span class="pi${spin}" style="color:${color}">${icon(ic)}</span></span>
        ${last ? '' : '<span class="phase-line"></span>'}
      </div>
      <div class="phase-main">
        <div class="phase-top">
          <span class="phase-name">${p.name}${p.opt ? '<span class="opt-tag">side-phase</span>' : ''}</span>
          ${p.gate ? `<span class="gate-chip gate-${GATE_CHIP[p.gate]}">${p.gate}</span>` : ''}
        </div>
        <span class="phase-status" style="color:${color}">${label}</span>
      </div>
    </div>`;
  }

  function renderRun(id) {
    const r = RUNS[id];
    const total = r.phases.length;
    const done = r.phases.filter(p => p.status === 'COMPLETED').length;
    const passCount = r.gates ? r.gates.filter(g => g.pass).length : 0;
    const allPass = r.gates ? passCount === r.gates.length : false;
    // A run whose ONLY failing gate is the step-up gate is finalize-eligible —
    // the step-up itself satisfies that final gate at the moment of sealing.
    const fails = r.gates ? r.gates.filter(g => !g.pass) : [];
    const stepUpEligible = fails.length === 1 && fails[0].label === 'Step-up approval present';
    const canFinalize = allPass || stepUpEligible;

    // header
    document.getElementById('runHeader').innerHTML = `
      <div>
        <div class="t-kpi-label" style="margin-bottom:7px;">Run detail · ${r.kind} run</div>
        <div style="font-size:20px;font-weight:600;letter-spacing:-.01em;">${r.period} · <span style="color:var(--text-secondary)">${r.type.replace(/_/g,' ').toLowerCase().replace(/\b\w/g,c=>c.toUpperCase())}</span></div>
        <div style="display:flex;align-items:center;gap:10px;margin-top:8px;">
          ${statusBadge(r.status)}
          <span class="t-meta mono">${r.lines} lines · ${r.money}</span>
        </div>
      </div>
      <button class="x-btn" onclick="PER.close()">${icon('x')}</button>`;

    // body
    let html = `
      <div class="rd-sec">
        <div class="rd-sec-head"><span>Phase plan</span><span class="t-meta mono">${done}/${total} complete</span></div>
        <div class="phases">${r.phases.map((p,i) => phaseRow(p,i,total)).join('')}</div>
      </div>`;

    if (r.gates) {
      html += `
      <div class="rd-sec">
        <div class="rd-sec-head"><span>Finalization readiness</span>
          <span class="badge ${canFinalize ? 'badge-success' : 'badge-danger'}">${icon(canFinalize?'check':'alertTri')}${passCount}/${r.gates.length} gates pass</span>
        </div>
        <div class="gates">${r.gates.map(g => `
          <div class="gate ${g.pass ? 'ok' : 'bad'}">
            <span class="gate-ic">${icon(g.pass ? 'check' : 'x')}</span>
            <div><div class="gate-label">${g.label}</div><div class="gate-reason">${g.reason}</div></div>
          </div>`).join('')}</div>
      </div>`;
    }
    document.getElementById('runBody').innerHTML = html;

    // footer / action
    const foot = document.getElementById('runFoot');
    if (!r.gates) {
      foot.innerHTML = `<button class="btn btn-secondary" onclick="PER.close()">Close</button>
        <button class="btn btn-secondary" disabled><span class="spin">${icon('loader')}</span>Run in progress…</button>`;
    } else if (canFinalize) {
      foot.innerHTML = `<button class="btn btn-secondary" onclick="PER.close()">Cancel</button>
        <button class="btn btn-primary" onclick="PER.stepUp()">${icon('shield')}Approve &amp; finalize</button>`;
    } else {
      const failList = fails;
      foot.innerHTML = `
        <div class="deny-note">
          <div class="deny-title">${icon('lock')} Can't finalize yet — ${failList.length} gate${failList.length>1?'s':''} failing</div>
          <ul>${failList.map(g => `<li>${g.label} — <span>${g.reason}</span></li>`).join('')}</ul>
        </div>
        <div style="display:flex;gap:9px;width:100%;justify-content:flex-end;">
          <button class="btn btn-secondary" onclick="PER.close()">Close</button>
          <button class="btn btn-primary" aria-disabled="true" title="Resolve the failing gates first">${icon('shield')}Approve &amp; finalize</button>
        </div>`;
    }

    document.getElementById('runScrim').classList.add('open');
    document.getElementById('runDrawer').classList.add('open');
  }

  window.PER = {
    open(id) { renderRun(id); },
    close() {
      document.getElementById('runScrim').classList.remove('open');
      document.getElementById('runDrawer').classList.remove('open');
      PER.closeStep();
    },
    stepUp() {
      document.getElementById('stepModal').classList.add('open');
      setTimeout(() => { const f = document.querySelector('#stepModal .otp input'); if (f) f.focus(); }, 80);
    },
    closeStep() { document.getElementById('stepModal').classList.remove('open'); },
    confirmStep() {
      const m = document.getElementById('stepModal');
      m.querySelector('.step-body').innerHTML = `
        <div class="step-success">
          <div class="step-seal">${icon('seal')}</div>
          <div style="font-size:17px;font-weight:600;margin-top:12px;">Period finalized</div>
          <div class="t-meta" style="margin-top:4px;text-align:center;max-width:280px;">March 2026 · OUT adjustment sealed with step-up authentication. A tamper-evident archive package has been written.</div>
          <button class="btn btn-primary" style="margin-top:18px;" onclick="PER.close()">Done</button>
        </div>`;
    },
    statusBadge,
    RUNS,
  };
})();