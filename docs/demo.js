'use strict';
// Curated illustrations, deliberately not presented as model-generated runtime output.
// This bundle does not call a provider, read files, persist inputs or collect keys.
(() => {
  const samples = {
    coding: {
      title: 'A CSV parser, with clear boundaries', profile: 'Coding task',
      original: 'Write exactly two numbered acceptance criteria for a CSV parser fix. It must support quoted commas and preserve blank rows. No implementation code or new dependencies.',
      drafts: [
        'Define acceptance criteria for the CSV parser fix.\n\nReturn exactly two numbered items: one for quoted commas and one for preserving blank rows. Include a concrete input and expected result in each. Do not write implementation code or add dependencies.',
        'Return exactly two numbered acceptance criteria for a CSV parser fix:\n\n1. Quoted commas: give a concrete CSV input and the expected parsed fields.\n2. Blank rows: give a concrete CSV input and the expected row sequence, including blank rows.\n\nDo not include implementation code or add dependencies.'
      ],
      answer: '1. Quoted commas: Given name,address\n"Smith, John","123 Main St, Apt 4", the parser returns two rows of two fields. The second row contains Smith, John and 123 Main St, Apt 4, with the quoted commas preserved inside each value.\n\n2. Blank rows: Given a,b followed by a blank line and then c,d (with no trailing newline), the parser returns three rows in order: ["a", "b"], [], ["c", "d"].',
      change: 'The refined version makes the two requested cases explicit and asks for concrete examples. The count, blank-row requirement and limits remain intact.'
    },
    investigation: {
      title: 'An HTTP 404, investigated before changing code', profile: 'Investigation',
      original: 'This app worked recently and now returns 404. Look at recent changes first. Find the cause with evidence before suggesting a fix. Do not change the code yet.',
      drafts: [
        'Investigate the new HTTP 404 in this previously working app. Start with recent commits and configuration changes. Compare the failing request with the provider contract. Report evidence and remaining unknowns before recommending a fix. Do not modify code.',
        'Investigate the HTTP 404; do not change code.\n\nStart with recent commits and configuration changes. Trace the failing request: provider, endpoint and model ID. Compare these with the documented API contract and available diagnostics.\n\nReport the evidence-supported cause, remaining unknowns and a proposed fix. Distinguish confirmed findings from hypotheses.'
      ],
      answer: 'Cause: not yet established. This sample has no repository history or response diagnostics attached.\n\nStart by comparing recent request/configuration changes with the last working version. Inspect the endpoint and model ID in the failing request, with secrets removed. Verify them against the provider contract.\n\nA 404 alone is insufficient to choose a fix. Keep the code unchanged until that evidence is available.',
      change: 'The refined version orders the investigation and distinguishes evidence from hypotheses. It keeps the prohibition on changing code.'
    },
    general: {
      title: 'A project update with no invented details', profile: 'General task',
      original: 'Turn these notes into a short project update: parser fix ready for review; release date not agreed; next step is review. Use three bullets. Do not invent dates or progress.',
      drafts: [
        'Write a short project update from these notes: the parser fix is ready for review; no release date has been agreed; the next step is review. Use exactly three bullets. Add no dates or unsupported progress claims.',
        'Write exactly three short bullets for a project update using only these facts:\n\n- The parser fix is ready for review.\n- A release date has not been agreed.\n- The next step is review.\n\nDo not invent dates or progress.'
      ],
      answer: '• The parser fix is ready for review.\n• A release date has not been agreed.\n• Next step: review the fix.',
      change: 'The refined version separates the supplied facts from the output rules. No additional scope, dates or progress are introduced.'
    }
  };
  const $ = id => document.getElementById(id);
  let view = 'refine', comparing = false;
  const sample = () => samples[$('sample').value];
  const status = text => { $('status').textContent = text; };
  function paragraph(text, className) { const element = document.createElement('span'); element.className = className; element.textContent = text; return element; }
  function renderModels() {
    const answer = $('model-role').value === 'answer';
    $('model-results').replaceChildren();
    const rows = answer ? [['claude-opus-5-5','35 / 36','Current'],['claude-sonnet-5-5','33 / 36','Candidate']] : [['claude-sonnet-5-5','36 / 36','Current'],['claude-opus-5-5','34 / 36','Candidate']];
    for (const values of rows) { const row = document.createElement('tr'); for (const value of values) { const cell = document.createElement('td'); cell.textContent = value; row.append(cell); } $('model-results').append(row); }
    $('comparison-caption').textContent = `Recorded ${answer ? 'answer' : 'refinement'} comparison · exact-output and constraint checks`;
    $('decision-reason').textContent = answer ? 'The candidate was cheaper and faster, but passed fewer strict checks. Lower cost alone did not qualify it for adoption.' : 'The candidate passed fewer downstream checks with the answer model held fixed. The existing refinement default was retained.';
    $('comparison-cost').textContent = answer ? '73 requests · 36 paired tasks · ~$0.05225 estimated total run cost' : '181 requests · 36 paired tasks, downstream answers and original controls · ~$0.33233 estimated total run cost';
  }
  function render() {
    const data = sample();
    $('session-title').textContent = data.title; $('original').textContent = data.original; $('profile').textContent = data.profile;
    for (const button of document.querySelectorAll('[data-view]')) button.setAttribute('aria-pressed', String(button.dataset.view === view));
    $('workflow-panel').hidden = view === 'models'; $('models-panel').hidden = view !== 'models';
    $('revision-controls').hidden = view !== 'review'; $('source-controls').hidden = view !== 'answer';
    $('output').classList.toggle('placeholder', view === 'refine'); $('output').replaceChildren();
    $('compare').setAttribute('aria-pressed', String(comparing)); $('compare').textContent = comparing ? 'Show draft only' : 'Compare with original';
    if (view === 'refine') {
      $('output-title').textContent = 'A clearer starting point'; $('revision-label').textContent = 'Ready to explore';
      const title = document.createElement('strong'); title.textContent = 'More clarity. Same intent.';
      const body = document.createElement('p'); body.textContent = 'Explore two curated refinements of this request, then compare the wording before using it.';
      $('output').append(title,body); $('next').textContent = 'Explore refinement →';
      $('action-note').textContent = 'Illustrative outputs; no generation';
    } else if (view === 'review') {
      $('output-title').textContent = comparing ? 'Original → selected revision' : 'Selected refined prompt'; $('revision-label').textContent = `Revision ${Number($('revision').value) + 1} of 2`;
      if (comparing) $('output').append(paragraph('ORIGINAL', 'compare-label'), paragraph(data.original,'compare-original'),paragraph('REFINED', 'compare-label'),paragraph(data.drafts[Number($('revision').value)],'compare-draft'));
      else $('output').textContent = data.drafts[Number($('revision').value)];
      $('next').textContent = 'Explore answer →'; $('action-note').textContent = data.change;
    } else if (view === 'answer') {
      const original = $('answer-source').value === 'original';
      $('output-title').textContent = 'Illustrative task answer'; $('revision-label').textContent = 'Curated example';
      $('output').textContent = data.answer;
      $('next').textContent = 'Explore model decisions →';
      $('action-note').textContent = `${original ? 'Original request' : 'Selected draft'} selected. This curated answer illustrates the constraints; changing the source does not run a comparison.`;
    } else renderModels();
  }
  function show(nextView) { view = nextView; render(); status(view === 'models' ? 'Recorded evidence shown. No paid evaluation or default change is possible here.' : `${view === 'refine' ? 'Original request' : view === 'review' ? 'Sample revisions' : 'Sample answer'} shown. No provider request was made.`); }
  document.querySelectorAll('[data-view]').forEach(button => button.addEventListener('click',() => show(button.dataset.view)));
  $('next').addEventListener('click',()=>show(view === 'refine' ? 'review' : view === 'review' ? 'answer' : 'models'));
  $('sample').addEventListener('change',()=>{ comparing = false; $('revision').value = '1'; $('answer-source').value = 'draft'; render(); status('Scenario changed. All text is bundled sample content.'); });
  $('revision').addEventListener('change',render); $('answer-source').addEventListener('change',render); $('model-role').addEventListener('change',renderModels);
  $('compare').addEventListener('click',()=>{ comparing = !comparing; render(); });
  $('reset').addEventListener('click',()=>{ $('sample').value = 'coding'; $('revision').value = '1'; $('answer-source').value = 'draft'; $('model-role').value = 'answer'; comparing = false; show('refine'); });
  render();
})();
