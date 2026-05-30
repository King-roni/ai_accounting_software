/* ============================================================
   Invoices — data, detail drawer, multi-step create flow
   Depends on shell.js (CB.icon). Exposes window.INV
   ============================================================ */
(function () {
  const icon = CB.icon;

  const LIFE = {
    DRAFT:['Draft','neutral'], SENT:['Sent','info'], PAYMENT_EXPECTED:['Payment expected','info'],
    PARTIALLY_PAID:['Partially paid','warning'], PAID:['Paid','success'], OVERPAID:['Overpaid','warning'],
    REFUNDED:['Refunded','neutral'], WRITTEN_OFF:['Written off','danger'], CREDITED:['Credited','neutral'],
    CONVERTED_TO_TAX_INVOICE:['Converted to tax','info'], FINALIZED:['Finalized','seal'], EXPIRED_UNCONVERTED:['Expired','danger'],
  };
  const GROUPS = {
    all:    () => true,
    drafts: s => s === 'DRAFT',
    awaiting: s => ['SENT','PAYMENT_EXPECTED','PARTIALLY_PAID'].includes(s),
    settled:  s => ['PAID','OVERPAID','FINALIZED','REFUNDED'].includes(s),
    closed:   s => ['WRITTEN_OFF','CREDITED','CONVERTED_TO_TAX_INVOICE','EXPIRED_UNCONVERTED'].includes(s),
  };

  // Cyprus VAT treatments -> rate %
  const VAT = {
    'Domestic standard 19%':19, 'Domestic reduced 9%':9, 'Domestic reduced 5%':5,
    'Domestic zero-rated':0, 'EU reverse charge':0, 'Import / acquisition':0,
    'Non-EU service':0, 'Outside scope':0, 'Exempt':0, 'No VAT':0,
  };
  const VAT_TREATMENTS = Object.keys(VAT);

  const L = (desc, qty, unit, treat) => ({ desc, qty, unit, treat, rate: VAT[treat] });

  // lifecycle, type PRO_FORMA|TAX
  const DATA = [
    { num:'INV-2026-0148', client:'Lefkara Retail Ltd', type:'TAX', issue:'2026-05-21', supply:'2026-05-21', due:'2026-06-20', status:'PAID',
      lines:[L('Consulting retainer — May',1,4000,'Domestic standard 19%'), L('Onboarding setup',1,1000,'Domestic standard 19%')] },
    { num:null, client:'Aphrodite Café', type:'PRO_FORMA', issue:null, supply:null, due:null, status:'DRAFT', clientPending:true,
      lines:[L('Espresso machine service',1,1200,'Domestic standard 19%')] },
    { num:'PF-2026-0061', client:'Nicosia Holdings', type:'PRO_FORMA', issue:'2026-05-18', supply:'2026-05-25', due:'2026-06-01', status:'SENT',
      lines:[L('Property advisory',1,3400,'Exempt')] },
    { num:'INV-2026-0147', client:'Coral Bay Hotels', type:'TAX', issue:'2026-05-15', supply:'2026-05-15', due:'2026-06-14', status:'PARTIALLY_PAID',
      lines:[L('Quarterly bookkeeping',1,9000,'Domestic standard 19%'), L('Reduced-rate training',1,2000,'Domestic reduced 9%')] },
    { num:'INV-2026-0146', client:'Larnaca Logistics', type:'TAX', issue:'2026-05-12', supply:'2026-05-12', due:'2026-05-26', status:'PAYMENT_EXPECTED',
      lines:[L('Customs filing assistance',1,1940,'Domestic standard 19%')] },
    { num:'INV-2026-0145', client:'Paphos Marine', type:'TAX', issue:'2026-05-08', supply:'2026-05-08', due:'2026-06-07', status:'FINALIZED',
      lines:[L('Annual audit prep',1,7000,'Domestic standard 19%'), L('EU advisory',1,1000,'EU reverse charge')] },
    { num:'INV-2026-0144', client:'Troodos Foods', type:'TAX', issue:'2026-04-30', supply:'2026-04-30', due:'2026-05-30', status:'OVERPAID',
      lines:[L('Monthly bookkeeping',1,1378,'Domestic standard 19%')] },
    { num:'INV-2026-0143', client:'Limassol Tech', type:'TAX', issue:'2026-04-22', supply:'2026-04-22', due:'2026-05-22', status:'WRITTEN_OFF',
      lines:[L('Setup & migration',1,4200,'Domestic zero-rated')] },
    { num:'PF-2026-0058', client:'Kyrenia Estates', type:'PRO_FORMA', issue:'2026-04-20', supply:'2026-04-27', due:'2026-05-04', status:'CONVERTED_TO_TAX_INVOICE',
      lines:[L('Valuation services',1,2000,'Exempt')] },
    { num:'INV-2026-0142', client:'Famagusta Imports', type:'TAX', issue:'2026-04-18', supply:'2026-04-18', due:'2026-05-18', status:'REFUNDED',
      lines:[L('Import VAT advisory',1,807,'Import / acquisition')] },
    { num:'CN-2026-0009', client:'Limassol Tech', type:'TAX', issue:'2026-04-15', supply:'2026-04-15', due:null, status:'CREDITED',
      lines:[L('Credit — over-billed hours',1,-500,'Domestic standard 19%')] },
    { num:'PF-2026-0055', client:'Akamas Resorts', type:'PRO_FORMA', issue:'2026-03-30', supply:'2026-04-06', due:'2026-04-13', status:'EXPIRED_UNCONVERTED',
      lines:[L('Event consulting',1,1750,'Outside scope')] },
    { num:'INV-2026-0141', client:'Lefkara Retail Ltd', type:'TAX', issue:'2026-04-10', supply:'2026-04-10', due:'2026-05-10', status:'PAID',
      lines:[L('Monthly retainer',1,2773,'Domestic standard 19%')] },
  ];

  const money = a => (a < 0 ? '−' : '') + '€' + Math.abs(a).toLocaleString('en-IE',{minimumFractionDigits:2,maximumFractionDigits:2});
  function totals(inv) {
    let sub = 0, vat = 0;
    inv.lines.forEach(l => { const n = l.qty * l.unit; sub += n; vat += n * l.rate / 100; });
    return { sub, vat, total: sub + vat };
  }
  function statusBadge(s) {
    const [label, tone] = LIFE[s];
    const cls = tone === 'seal' ? 'badge badge-seal' : `badge badge-${tone}`;
    const ic = tone === 'seal' ? icon('seal') : '';
    return `<span class="${cls}">${ic}${label}</span>`;
  }
  const typeBadge = t => t === 'PRO_FORMA'
    ? '<span class="badge badge-neutral">Pro-forma</span>'
    : '<span class="badge badge-info">Tax</span>';

  // ---- status-gated actions ----
  function actionsFor(inv) {
    const s = inv.status, pf = inv.type === 'PRO_FORMA';
    const a = [];
    if (s === 'DRAFT') {
      a.push({ label:'Allocate number', kind:'primary', denied: !!inv.clientPending, reason:'Invoice is still a draft pending client confirmation' });
      a.push({ label:'Mark sent', kind:'secondary', denied:true, reason:'Allocate an invoice number first' });
    } else if (s === 'SENT' || s === 'PAYMENT_EXPECTED' || s === 'PARTIALLY_PAID') {
      a.push({ label:'Mark paid', kind:'primary' });
      if (pf) a.push({ label:'Convert to tax invoice', kind:'secondary' });
      a.push({ label:'Write off', kind:'ghost' });
    } else if (s === 'PAID' || s === 'OVERPAID') {
      a.push({ label:'Issue credit note', kind:'secondary' });
    } else if (s === 'FINALIZED') {
      a.push({ label:'Edit', kind:'secondary', denied:true, reason:'Locked — invoice is finalized for its period' });
    }
    a.push({ label:'Preview PDF data', kind:'ghost' });
    return a;
  }

  // ---- detail drawer ----
  function openDetail(i) {
    const inv = DATA[i], t = totals(inv);
    document.getElementById('invHead').innerHTML = `
      <div>
        <div style="display:flex;align-items:center;gap:9px;margin-bottom:7px;">
          ${typeBadge(inv.type)} ${statusBadge(inv.status)}
        </div>
        <div style="font-size:20px;font-weight:600;letter-spacing:-.01em;">${inv.num || 'Draft invoice'}</div>
        <div class="t-meta" style="margin-top:3px;">${inv.client}</div>
      </div>
      <button class="x-btn" onclick="INV.close()">${icon('x')}</button>`;

    const date = d => d || '—';
    document.getElementById('invBody').innerHTML = `
      <div class="kv-grid" style="margin-bottom:22px;">
        <div><div class="k">Issue date</div><div class="vv mono">${date(inv.issue)}</div></div>
        <div><div class="k">Supply date</div><div class="vv mono">${date(inv.supply)}</div></div>
        <div><div class="k">Due date</div><div class="vv mono">${date(inv.due)}</div></div>
        <div><div class="k">Currency</div><div class="vv mono">EUR</div></div>
      </div>

      <div class="money-block">
        <div class="mb"><span>Subtotal</span><span class="mono">${money(t.sub)}</span></div>
        <div class="mb"><span>VAT</span><span class="mono">${money(t.vat)}</span></div>
        <div class="mb total"><span>Total</span><span class="mono">${money(t.total)}</span></div>
      </div>

      <div class="dl-sec">
        <h4>Line items</h4>
        <div class="li-tbl">
          <div class="li-h"><span>Description</span><span class="r">Qty</span><span class="r">Unit</span><span>VAT treatment</span><span class="r">VAT</span><span class="r">Total</span></div>
          ${inv.lines.map(l => {
            const n = l.qty * l.unit, v = n * l.rate / 100;
            return `<div class="li-r">
              <span class="li-desc">${l.desc}</span>
              <span class="r mono">${l.qty}</span>
              <span class="r mono">${money(l.unit)}</span>
              <span class="li-treat">${l.treat}${l.rate ? ` · ${l.rate}%` : ''}</span>
              <span class="r mono">${money(v)}</span>
              <span class="r mono">${money(n + v)}</span>
            </div>`;
          }).join('')}
        </div>
      </div>`;

    // actions
    const acts = actionsFor(inv);
    const denied = acts.find(x => x.denied);
    document.getElementById('invFoot').innerHTML = `
      ${denied ? `<div class="deny-note"><div class="deny-title">${icon('lock')} ${acts.filter(x=>x.denied).length === 1 ? "Can't do that yet" : 'Some actions blocked'}</div>
        <ul>${acts.filter(x=>x.denied).map(x => `<li><b>${x.label}</b> — <span>${x.reason}</span></li>`).join('')}</ul></div>` : ''}
      <div style="display:flex;gap:8px;flex-wrap:wrap;width:100%;justify-content:flex-end;">
        ${acts.map(x => x.denied
          ? `<button class="btn btn-${x.kind === 'primary' ? 'primary' : 'secondary'}" aria-disabled="true" title="${x.reason}">${x.label}</button>`
          : `<button class="btn btn-${x.kind}">${x.label}</button>`).join('')}
      </div>`;
    document.getElementById('invScrim').classList.add('open');
    document.getElementById('invDrawer').classList.add('open');
  }

  // ---- create flow ----
  let step = 0, draft;
  const CLIENTS = ['Lefkara Retail Ltd','Coral Bay Hotels','Nicosia Holdings','Larnaca Logistics','Paphos Marine','Aphrodite Café'];
  function newDraft() { return { client:'', type:'TAX', issue:'2026-05-30', supply:'2026-05-30', due:'2026-06-29', currency:'EUR', lines:[L('',1,0,'Domestic standard 19%')] }; }

  function openCreate() { step = 0; draft = newDraft(); renderCreate(); document.getElementById('createScrim').classList.add('open'); document.getElementById('createDrawer').classList.add('open'); }
  function closeCreate() { document.getElementById('createScrim').classList.remove('open'); document.getElementById('createDrawer').classList.remove('open'); }

  const STEPS = ['Client & type','Dates','Line items','Review'];
  function renderCreate() {
    document.getElementById('createSteps').innerHTML = STEPS.map((s, i) =>
      `<div class="cstep ${i === step ? 'on' : ''} ${i < step ? 'done' : ''}"><span class="cn">${i < step ? icon('check') : i + 1}</span>${s}</div>`).join('<span class="cstep-line"></span>');

    let body = '';
    if (step === 0) {
      body = `
        <label class="input-label">Client</label>
        <div class="field" style="width:100%;margin-bottom:16px;">
          <select id="cClient">${['<option value="">Select a client…</option>'].concat(CLIENTS.map(c => `<option ${draft.client===c?'selected':''}>${c}</option>`)).join('')}</select>
          <span>${icon('chevD')}</span>
        </div>
        <label class="input-label">Invoice type</label>
        <div class="radio-cards">
          <label class="rc ${draft.type==='TAX'?'on':''}"><input type="radio" name="ctype" value="TAX" ${draft.type==='TAX'?'checked':''}><div><div class="rc-t">Tax invoice</div><div class="rc-m">Final, VAT-bearing, numbered on issue</div></div></label>
          <label class="rc ${draft.type==='PRO_FORMA'?'on':''}"><input type="radio" name="ctype" value="PRO_FORMA" ${draft.type==='PRO_FORMA'?'checked':''}><div><div class="rc-t">Pro-forma</div><div class="rc-m">Quote / preview — convert to tax later</div></div></label>
        </div>`;
    } else if (step === 1) {
      body = `
        <div class="kv-grid" style="gap:16px;">
          <div><label class="input-label">Issue date</label><div class="field" style="width:100%;"><input type="date" id="cIssue" value="${draft.issue}"></div></div>
          <div><label class="input-label">Supply date</label><div class="field" style="width:100%;"><input type="date" id="cSupply" value="${draft.supply}"></div></div>
          <div><label class="input-label">Due date</label><div class="field" style="width:100%;"><input type="date" id="cDue" value="${draft.due}"></div></div>
          <div><label class="input-label">Currency</label><div class="field" style="width:100%;"><select id="cCur"><option>EUR</option><option>GBP</option><option>USD</option></select><span>${icon('chevD')}</span></div></div>
        </div>`;
    } else if (step === 2) {
      body = `
        <div class="le-head"><span>Line items</span><button class="btn btn-tertiary btn-sm" onclick="INV.addLine()">${icon('plus')}Add line</button></div>
        <div id="lineEditor">${draft.lines.map((l, i) => lineRow(l, i)).join('')}</div>`;
    } else {
      const t = totals(draft);
      body = `
        <div class="review-head">${typeBadge(draft.type)} <span class="t-meta">${draft.client || 'No client'}</span></div>
        <div class="kv-grid" style="margin:16px 0 20px;">
          <div><div class="k">Issue</div><div class="vv mono">${draft.issue}</div></div>
          <div><div class="k">Due</div><div class="vv mono">${draft.due}</div></div>
        </div>
        <div class="li-tbl" style="margin-bottom:18px;">
          <div class="li-h"><span>Description</span><span class="r">Qty</span><span class="r">Unit</span><span>VAT</span><span class="r">Total</span></div>
          ${draft.lines.map(l => { const n = l.qty*l.unit, v = n*l.rate/100; return `<div class="li-r" style="grid-template-columns:2fr .5fr .8fr 1.4fr .9fr;"><span class="li-desc">${l.desc||'—'}</span><span class="r mono">${l.qty}</span><span class="r mono">${money(l.unit)}</span><span class="li-treat">${l.rate?l.rate+'%':l.treat}</span><span class="r mono">${money(n+v)}</span></div>`; }).join('')}
        </div>
        <div class="money-block computed">
          <div class="mb"><span>Subtotal</span><span class="mono">${money(t.sub)}</span></div>
          <div class="mb"><span>VAT</span><span class="mono">${money(t.vat)}</span></div>
          <div class="mb total"><span>Total</span><span class="mono">${money(t.total)}</span></div>
          <div class="computed-note">${icon('lock')} Totals are computed server-side and read-only</div>
        </div>`;
    }
    document.getElementById('createBody').innerHTML = body;
    wireStep();

    document.getElementById('createFoot').innerHTML = `
      <button class="btn btn-ghost" onclick="${step === 0 ? 'INV.closeCreate()' : 'INV.back()'}">${step === 0 ? 'Cancel' : 'Back'}</button>
      ${step < STEPS.length - 1
        ? `<button class="btn btn-primary" onclick="INV.next()">Continue ${icon('chevR')}</button>`
        : `<button class="btn btn-primary" onclick="INV.createDone()">${icon('check')}Create ${draft.type === 'TAX' ? 'tax invoice' : 'pro-forma'}</button>`}`;
  }

  function lineRow(l, i) {
    return `<div class="le-row">
      <input class="le-in" placeholder="Description" value="${l.desc}" oninput="INV.setLine(${i},'desc',this.value)">
      <input class="le-in r" type="number" value="${l.qty}" oninput="INV.setLine(${i},'qty',this.value)" style="width:54px;">
      <input class="le-in r" type="number" value="${l.unit}" oninput="INV.setLine(${i},'unit',this.value)" style="width:84px;">
      <div class="field le-sel"><select onchange="INV.setLine(${i},'treat',this.value)">${VAT_TREATMENTS.map(v => `<option ${v===l.treat?'selected':''}>${v}</option>`).join('')}</select><span>${icon('chevD')}</span></div>
      <span class="le-tot mono">${money(l.qty * l.unit * (1 + l.rate / 100))}</span>
      <button class="le-del" onclick="INV.delLine(${i})" ${draft.lines.length <= 1 ? 'disabled' : ''}>${icon('x')}</button>
    </div>`;
  }

  function wireStep() {
    if (step === 0) {
      const cs = document.getElementById('cClient'); if (cs) cs.onchange = e => draft.client = e.target.value;
      document.querySelectorAll('input[name=ctype]').forEach(r => r.onchange = e => { draft.type = e.target.value; renderCreate(); });
    } else if (step === 1) {
      ['Issue','Supply','Due'].forEach(f => { const el = document.getElementById('c' + f); if (el) el.onchange = e => draft[f.toLowerCase()] = e.target.value; });
      const cu = document.getElementById('cCur'); if (cu) cu.onchange = e => draft.currency = e.target.value;
    }
  }

  window.INV = {
    DATA, GROUPS, totals, statusBadge, typeBadge, money,
    openDetail, close() { document.getElementById('invScrim').classList.remove('open'); document.getElementById('invDrawer').classList.remove('open'); },
    openCreate, closeCreate,
    next() { if (step < STEPS.length - 1) { step++; renderCreate(); } },
    back() { if (step > 0) { step--; renderCreate(); } },
    addLine() { draft.lines.push(L('', 1, 0, 'Domestic standard 19%')); renderCreate(); },
    delLine(i) { draft.lines.splice(i, 1); renderCreate(); },
    setLine(i, k, v) {
      const l = draft.lines[i];
      if (k === 'qty' || k === 'unit') l[k] = parseFloat(v) || 0;
      else l[k] = v;
      if (k === 'treat') l.rate = VAT[v];
      // live-update just the total cell to avoid losing focus, full re-render only for treat
      if (k === 'treat') renderCreate();
      else { const rows = document.querySelectorAll('.le-row'); if (rows[i]) rows[i].querySelector('.le-tot').textContent = money(l.qty * l.unit * (1 + l.rate / 100)); }
    },
    createDone() {
      document.getElementById('createBody').innerHTML = `<div class="step-success" style="padding:50px 0;">
        <div class="step-seal">${icon('check')}</div>
        <div style="font-size:17px;font-weight:600;margin-top:14px;">${draft.type === 'TAX' ? 'Tax invoice' : 'Pro-forma'} created</div>
        <div class="t-meta" style="margin-top:5px;text-align:center;max-width:280px;">Saved as a draft for ${draft.client || 'unnamed client'}. Allocate a number to issue it.</div>
      </div>`;
      document.getElementById('createFoot').innerHTML = `<button class="btn btn-primary" style="margin-left:auto;" onclick="INV.closeCreate()">Done</button>`;
      document.getElementById('createSteps').style.opacity = '.4';
    },
  };
})();