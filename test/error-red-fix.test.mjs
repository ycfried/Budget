// Error-red fix (owner, Nov 4, 2026, ~11:09 PM): the sign-in red
// error pop-up went off the screen a little, the red was too heavy
// and dark, and other errors (e.g. "Enter a valid email address.")
// still showed in a pale blue box. Static tests only — no live
// data, no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const reset = readFileSync(new URL('../reset.html', import.meta.url), 'utf8');

test('error toast fits the viewport: 16px margins both sides, padding inside the width', () => {
  assert.match(css, /body\.live \.toast \{[^}]*left: 16px; right: 16px;/);
  assert.match(css, /body\.live \.toast \{[^}]*box-sizing: border-box; max-width: calc\(100vw - 32px\);/);
  assert.match(css, /body\.live \.toast \{[^}]*overflow-wrap: break-word;/);
});

test('error toast is the LIGHTER red, not the old solid dark bar', () => {
  assert.match(css, /body\.live \.toast\.error \{ background: #fef2f2; color: #dc2626; border: 1px solid #fecaca; font-weight: 600; \}/);
  assert.doesNotMatch(css, /body\.live \.toast\.error \{ background: #dc2626; color: #fff/);
  assert.match(css, /body\.live \.toast \{[^}]*background: #2f6bff/, 'success/info toasts stay brand blue');
});

test('inline .result.error uses the exact same lighter red as the error toast', () => {
  assert.match(css, /body\.live \.result\.error \{ background: #fef2f2; color: #dc2626; border: 1px solid #fecaca; \}/);
  assert.match(reset, /#msg\.error \{ background: #fef2f2; color: #dc2626; border: 1px solid #fecaca; \}/, 'reset page error matches too');
});

test('setResultMsg is the only way .result text is set, toggling .error on failures only', () => {
  assert.match(js, /function setResultMsg\(id, text, isError\) \{[\s\S]*?el\.classList\.toggle\('error', !!isError && !!text\);/);
  assert.equal(js.includes("$('authMsg').textContent"), false, 'no bare authMsg assignment');
  assert.equal(js.includes("$('authNameMsg').textContent"), false, 'no bare authNameMsg assignment');
  assert.equal(js.includes("$('householdMsg').textContent"), false, 'no bare householdMsg assignment');
  assert.equal(js.includes("$('householdNameMsg').textContent"), false, 'no bare householdNameMsg assignment');
  assert.equal(js.includes("$('emailMsg').textContent"), false, 'no bare emailMsg assignment');
  assert.equal(js.includes("msg.textContent"), false, 'no bare csvMsg assignment');
});

test('converted failures now use the lighter red error style', () => {
  // Forgot-password invalid email (the owner's circled example).
  assert.match(js, /setResultMsg\('authMsg', 'Enter a valid email address\.', true\)/);
  // Sign-up validation (all four messages go through fail()).
  assert.match(js, /const fail = \(msg, field\) => \{ setResultMsg\('authMsg', msg, true\);/);
  // Household join guards.
  assert.match(js, /setResultMsg\('householdMsg', 'Sign in first\.', true\)/);
  assert.match(js, /setResultMsg\('householdMsg', 'Enter the invite code from the household owner\.', true\)/);
  // Household create result and name-step create result carry the error flag on failure.
  assert.match(js, /setResultMsg\('householdNameMsg', data[\s\S]*?: 'Could not create household\. Try again\.', !data\)/);
  assert.match(js, /setResultMsg\('authNameMsg', error \? 'Could not create the account\. Try again\.'[\s\S]*?, !!error\)/);
  // Email connect / check failures.
  assert.match(js, /setResultMsg\('emailMsg', `Could not start the email connection:[\s\S]*?, true\)/);
  // NEW-R4-C1 (Nov 9, 2026): the check message + error flag now come
  // from emailCheckMessage (filterState.mjs); the handler still
  // routes failures through setResultMsg with the error flag.
  assert.match(js, /const \{ text, isError \} = emailCheckMessage\(out\);/);
  assert.match(js, /setResultMsg\('emailMsg', text, isError\)/);
  // CSV failures.
  assert.match(js, /setResultMsg\('csvMsg', 'No file reached the app from the picker\.[\s\S]*?, true\)/);
  assert.match(js, /setResultMsg\('csvMsg', `Could not read this file \([\s\S]*?, true\)/);
  // CSV admin gate is a refusal, so it is an error toast now.
  assert.match(js, /showToast\('Only the admin can import transactions\.', true\)/);
});

test('success/info messages stay blue: they are set with isError false', () => {
  assert.match(js, /setResultMsg\('authMsg', 'Signed in\.', false\)/);
  assert.match(js, /setResultMsg\('authMsg', 'If an account exists for that email, a password-reset link was sent to it\.', false\)/);
  assert.match(js, /setResultMsg\('householdMsg', 'Joined\. Loading shared budget…', false\)/);
  assert.match(js, /setResultMsg\('authMsg', 'Your account was deleted\.', false\)/);
});

test('weekError and inline field errors were already red text and are unchanged', () => {
  assert.match(html, /<p id="weekError" class="result error hidden"><\/p>/);
  assert.match(html, /<p id="manualFormError" class="error hidden" role="alert"><\/p>/);
  assert.match(html, /<p id="charityFormError" class="error hidden" role="alert"><\/p>/);
  assert.match(css, /body\.live \.error \{ color: #dc2626; \}/);
});

test('sign-in button row has the standard 14px gap from the password field', () => {
  assert.match(css, /#view-auth #authSigninPanel \.auth-btn-row \{ margin-top: 14px; \}/);
  // The name step and household name step already get the 14px gap
  // from their input's bottom margin, so they get no extra margin.
  assert.doesNotMatch(css, /#authNamePanel \.auth-btn-row \{ margin-top/);
  assert.doesNotMatch(css, /#householdNamePanel \.auth-btn-row \{ margin-top/);
});

test('pins bumped to v52/v62', () => {
  assert.match(html, /styles\.css\?v=53/);
  assert.match(html, /live\.js\?v=64/);
});
