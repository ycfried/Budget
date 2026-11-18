// Auth-card-cleanup (owner, Nov 4, 2026, wife's-phone sign-in screen
// + two-step sign-up correction): the sign-in card carries no
// heading, subtitle, lead-in, or card-numbers note; the password eye
// sits inside the field; Sign in + Create account share one row;
// the Name field lives only in a separate name step that Create
// account reaches after Email/Password validation, and only that
// step calls signUp. Static tests only — no live data, no network,
// no auth behavior change beyond the step split.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const html = readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');

const authCard = html.slice(html.indexOf('id="view-auth"'), html.indexOf('id="view-household"'));
assert.ok(authCard.length > 0, 'view-auth card found');
const signinPanel = html.slice(html.indexOf('id="authSigninPanel"'), html.indexOf('id="authNamePanel"'));
const namePanel = html.slice(html.indexOf('id="authNamePanel"'), html.indexOf('id="view-household"'));

test('sign-in card has no heading, subtitle, lead-in, or card-numbers note', () => {
  assert.equal(authCard.includes('<h1>OnBudget</h1>'), false, 'card heading deleted');
  assert.equal(authCard.includes('Sign in to your household budget.'), false, 'subtitle deleted');
  assert.equal(authCard.includes('New to OnBudget?'), false, 'lead-in deleted');
  assert.equal(authCard.includes('Card numbers are never shown'), false, 'card-numbers note deleted');
});

test('sign-in card order: Email, Password, button row, Forgot password, message', () => {
  const order = ['id="authEmail"', 'id="authPassword"', 'id="signInBtn"', 'id="signUpBtn"', 'id="forgotPasswordBtn"', 'id="authMsg"'];
  let prev = -1;
  for (const id of order) {
    const at = authCard.indexOf(id);
    assert.ok(at > prev, `${id} follows the previous element`);
    prev = at;
  }
  assert.ok(authCard.includes('Forgot Password?'), 'Forgot password recovery path kept, Title Cased');
});

test('Sign in and Create account share one row with nothing between them', () => {
  const row = authCard.match(/<div class="btn-row auth-btn-row">([\s\S]*?)<\/div>/);
  assert.ok(row, 'shared auth button row found');
  assert.ok(row[1].includes('id="signInBtn"'), 'Sign in in the row');
  assert.ok(row[1].includes('id="signUpBtn"'), 'Create account in the row');
  assert.match(row[1], /btn-primary[^>]*>Sign In/, 'Sign In is primary');
  // The row's CSS makes the two buttons equal width, side by side
  // (the selector is shared with the household naming step's row).
  assert.match(css, /#view-auth \.auth-btn-row[^{]*\{[^}]*display: flex[^}]*\}/);
  assert.match(css, /#view-auth \.auth-btn-row \.btn[^{]*\{[^}]*flex: 1 1 0[^}]*\}/);
});

test('password eye sits inside the field; both inputs the same width', () => {
  // The toggle is an icon button (SVG, no Show/Hide text) inside a
  // relatively positioned wrapper, with the input padded for it.
  assert.match(authCard, /id="togglePasswordBtn" class="auth-eye-btn"[^>]*><svg[^>]*viewBox="0 0 24 24"/);
  assert.equal(authCard.includes('>Show</button>'), false, 'no Show text on the sign-in toggle');
  assert.match(css, /#view-auth \.password-row \{[^}]*position: relative[^}]*\}/);
  assert.match(css, /#view-auth \.password-row input \{[^}]*width: 100%[^}]*padding-right: 48px[^}]*\}/);
  assert.match(css, /#view-auth \.password-row \.auth-eye-btn \{[^}]*position: absolute[^}]*width: 40px[^}]*height: 40px[^}]*\}/);
  // The generic flex row (change-password sheet's text toggle) is
  // untouched by the scoped auth rules.
  assert.match(css, /body\.live \.password-row \{ display: flex;/);
  // The toggle still flips type + aria-label + aria-pressed.
  assert.match(js, /togglePasswordBtn.*addEventListener\('click'/);
  assert.match(js, /input\.type = showing \? 'text' : 'password'/);
  assert.match(js, /setAttribute\('aria-label', showing \? 'Hide Password' : 'Show Password'\)/);
  assert.match(js, /eyeSlashSvg : eyeOpenSvg/);
});

test('name step: Back returns with fields intact, only the step calls signUp', () => {
  const backFn = js.slice(js.indexOf("$('authNameBackBtn')"), js.indexOf("$('authNameCreateBtn')"));
  assert.match(backFn, /showAuthPanel\('signin'\)/);
  assert.equal(backFn.includes("authEmail').value = ''"), false, 'Back never clears Email');
  assert.equal(backFn.includes("authPassword').value = ''"), false, 'Back never clears Password');
  const confirmFn = js.slice(js.indexOf("$('authNameCreateBtn').addEventListener('click'"), js.indexOf("$('signOutBtn').addEventListener('click'"));
  assert.match(confirmFn, /supabase\.auth\.signUp\(\{\s*email: signEmail\.value\.trim\(\), password: signPw\.value,\s*options: \{ data: \{ full_name: signName\.value\.trim\(\) \} \}/);
});

test('sign-in never shows the name step', () => {
  // Slice just the sign-in handler body (up to the eye-icon constants
  // that follow it), not the auth-panel helper defined later.
  const signInFn = js.slice(js.indexOf("$('signInBtn').addEventListener('click'"), js.indexOf('const eyeOpenSvg'));
  assert.equal(signInFn.includes('authNamePanel'), false, 'sign-in never touches the name panel');
  assert.equal(signInFn.includes('showAuthPanel'), false, 'sign-in never switches auth panels');
  assert.match(signInFn, /supabase\.auth\.signInWithPassword/);
});
