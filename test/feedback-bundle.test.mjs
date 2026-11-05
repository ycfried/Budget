import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const html = fs.readFileSync(new URL('../live.html', import.meta.url), 'utf8');
const js = fs.readFileSync(new URL('../live.js', import.meta.url), 'utf8');
const css = fs.readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
const sql = fs.readFileSync(new URL('../supabase/feedback-allowance-set.sql', import.meta.url), 'utf8');
const kindSql = fs.readFileSync(new URL('../supabase/merged-audit-kind-constraint.sql', import.meta.url), 'utf8');

// 1. Loading screen, full screen, Title Case, no footer while loading.
test('loading view fills the viewport, says Loading Your Household, footer hidden', () => {
  assert.match(html, /<section id="view-loading" class="loading-screen"/, 'loading section is not a card');
  assert.ok(!html.includes('Loading your budget'), 'old budget wording gone');
  assert.ok(html.includes('Loading Your Household'), 'Title Case household wording');
  assert.match(css, /body\.live \.loading-screen \{[^}]*min-height: calc\(100dvh - 60px\)[^}]*border: 0; border-radius: 0; box-shadow: none/, 'full-screen, no card chrome');
  assert.match(css, /body\.live\.is-loading footer\.foot/, 'footer hidden via is-loading class');
  assert.match(css, /body\.live:has\(#view-loading:not\(\.hidden\)\) footer\.foot \{ display: none; \}/, 'footer hidden before JS runs too');
  assert.match(js, /document\.body\.classList\.toggle\('is-loading', view === 'loading'\)/);
});

// 2. Empty pages: boot keeps loading until refresh finishes.
test('boot keeps loading visible until refresh finishes, then shows the app', () => {
  const boot = js.slice(js.indexOf('async function boot()'));
  assert.match(boot, /await show\('loading'\);[\s\S]*?try \{ await refresh\(\); \} catch/);
  assert.match(boot, /await show\('app'\);[\s\S]*?showView\(currentView\);/);
  assert.match(boot, /if \(!anyVisible\) showView\('week'\)/, 'empty-page fallback to Home');
});

// 3. Past weeks From/To: equal, compact, no overlap; widths reasoned.
test('history From/To are equal, compact, and cannot paint over each other', () => {
  assert.match(css, /#section-history-filter \.form-row-2 label \{ display: block; width: 100%; min-width: 0; overflow: hidden;/);
  assert.match(css, /#section-history-filter \.form-row-2 input \{ width: 100%; min-width: 0; box-sizing: border-box;[^}]*padding: 10px 8px; font-size: 15px;/);
  assert.match(css, /@media \(max-width: 360px\) \{\s*#section-history-filter \.form-row-2 \{ grid-template-columns: 1fr; \}/);
  // Width reasoning (not a rendered proof — real-phone proving owed):
  // 390px viewport: card = 390 - 32 (page) - 32 (card padding) = 326;
  // each field = (326 - 12 gap) / 2 = 157px, a full tap target.
  // 320px viewport: each field would be (320 - 64 - 12) / 2 = 122px,
  // below a readable iOS date input, hence the <=360px stack above.
  const fieldAt = (vp) => (vp - 32 - 32 - 12) / 2;
  assert.equal(fieldAt(390), 157);
  assert.equal(fieldAt(320), 122);
  assert.ok(fieldAt(320) < 140, '320px side-by-side cannot fit a readable date input, so it stacks');
});

// 4. Home buttons: SUPERSEDED by home-hero-fix (owner, Nov 4, later
// the same evening). Profile is no longer primary blue — it is white
// with a dark icon and a light grey border (much lighter, maybe not
// blue at all). The sync button is still primary blue, but the old
// row-scoped rule lost to the pale #view-app .btn rule (see the
// specificity note in styles.css), so it is now set by an
// ancestor-independent #view-app .hero-sync-btn rule AND the button
// no longer carries the plain `btn` class.
test('profile button is white with dark icon and light grey border; sync is primary blue via an ID-strength rule', () => {
  assert.match(css, /body\.live \.profile-btn \{ background: #fff; border: 1px solid #e5e7eb; color: #0f172a; box-shadow: none; \}/);
  assert.match(css, /body\.live #view-app \.hero-sync-btn \{ background: #2f6bff; color: #fff; border: 0; box-shadow: none; \}/);
  assert.match(css, /\.hero-number-row \.hero-sync-btn \{[^}]*width: 44px; height: 44px;[^}]*border-radius: 50%/);
});

// 5. Hero kicker: date range only.
test('hero kicker shows only the date range, no This week prefix', () => {
  assert.ok(html.includes('<div class="kicker"><span id="weekLabel">'));
  assert.equal(html.includes('This week · <span id="weekLabel">'), false);
});

// 6. New-account hero + prepared SQL (NOT applied).
test('new sign-up shows Set Your Weekly Allowance, not a figure, until set', () => {
  assert.ok(html.includes('id="heroSetAllowanceBtn"'));
  assert.ok(html.includes('>Set Your Weekly Allowance</button>'));
  assert.match(js, /if \(!allowanceExplicitlySet\) \{[\s\S]*?heroFig\.classList\.add\('hidden'\)/);
  assert.match(js, /heroSetBtn\.classList\.toggle\('hidden', !isAdminHero\)/);
  assert.match(js, /allowance_set_at/);
  assert.match(sql, /PREPARED FOR OWNER-APPROVED APPLY/);
  assert.match(sql, /add column if not exists allowance_set_at timestamptz/);
  assert.match(sql, /set allowance_set_at = created_at/);
  assert.match(sql, /trg_stamp_allowance_set_at/);
  assert.equal(sql.includes('NOT APPLIED') || sql.includes('NOT APPLIED BY THIS BRANCH'), true);
});

// 7 + A + sign-in fill: pages stretch to the viewport.
test('Home, Your Household and sign-in pages fill the viewport', () => {
  assert.match(css, /body\.live main \{ padding: 24px 16px 0; min-height: calc\(100dvh - 60px\); display: flex; flex-direction: column; \}/);
  assert.match(css, /body\.live #view-app \{ flex: 1 1 auto; display: flex; flex-direction: column; \}/);
  assert.match(css, /body\.live #view-auth, body\.live #view-household \{ flex: 0 0 auto; display: block; \}/, 'auth pages are natural height, not stretched (final little things)');
  assert.ok(html.includes('class="auth-brand"'), 'logo on top of sign-in and sign-up pages');
  assert.ok(html.includes('class="auth-foot"'), 'useful bottom line under the auth card');
  assert.match(css, /#householdChoicePanel > label \{ margin-top: 28px; display: block; \}/, 'join section breathes below Create');
});

// 8 + 12 + A: Title Case in the sign-up / household flow.
test('sign-up and household headers and buttons are refined Title Case (minor words lower)', () => {
  for (const s of ['Your Household', 'Or Join a Household', 'Name Your Household', 'Household Name',
    'Create Household', 'Join As Member', 'Choose Your Name', 'Sign In', 'Create Account', 'Forgot Password?']) {
    assert.ok(html.includes(s), `Title Case present: ${s}`);
  }
  assert.equal(html.includes('Create household (I am the owner / admin)'), false, 'parentheses removed from Create');
  assert.equal(html.includes('Name your household'), false);
  assert.equal(html.includes('Your household</h1>'), false);
});

// 9. Household name required, no default fallback.
test('household name is required: no optional sentence, blank refused client-side', () => {
  assert.equal(html.includes('Optional — leave it blank to keep the default.'), false);
  assert.match(js, /if \(!rawName\) \{[\s\S]*?Enter a household name\./);
  assert.match(js, /const args = \{ p_name: name \};/);
});

// 10. Repo kind-constraint SQL corrected (file only, live already has it).
test('merged-audit kind SQL uses the valid alter-table drop', () => {
  assert.ok(kindSql.includes('alter table transactions drop constraint if exists transactions_kind_check;'));
  assert.equal(kindSql.includes('drop constraint if exists transactions_kind_check on transactions;'), false);
});

// 11 + C: red error pop-ups, exact join text, platform-wide error red.
test('error messages are red: toasts, inline error boxes, exact join text', () => {
  assert.match(css, /body\.live \.toast\.error \{ background: #fef2f2; color: #dc2626; border: 1px solid #fecaca; font-weight: 600; \}/);
  assert.match(css, /body\.live \.result\.error \{ background: #fef2f2; color: #dc2626; border: 1px solid #fecaca; \}/);
  assert.match(css, /body\.live \.toast \{[^}]*background: #2f6bff/, 'success/info toasts stay brand blue');
  // Design item 2 (owner, Nov 5): the join failure stays in the
  // INLINE soft-red box, not a toast.
  assert.match(js, /setResultMsg\('householdMsg', 'Check the invite code and try again', true\)/);
  assert.equal(js.includes('or ask the household owner to share it again from Settings'), false, 'join extra clause gone');
});

// D: sign-in error wording. Design item 2 (owner, Nov 5): the failure
// stays in the INLINE soft-red box, not a toast.
test('sign-in failure says Incorrect email or password in the inline red box', () => {
  assert.match(js, /setResultMsg\('authMsg', 'Incorrect email or password', true\)/);
});

// E: eye icon centred (input bottom margin removed in the auth row).
test('password eye icon centres: auth password input has no bottom margin offset', () => {
  assert.match(css, /#view-auth \.password-row input \{ width: 100%; box-sizing: border-box; margin: 0; padding-right: 48px; \}/);
  assert.match(css, /#view-auth \.password-row \.auth-eye-btn \{[^}]*top: 50%; transform: translateY\(-50%\)/);
});

// F: Forgot Password is a tapable underlined brand-blue link, not grey.
test('Forgot Password is underlined brand blue #2f6bff, not grey', () => {
  assert.match(css, /#forgotPasswordBtn \{ color: #2f6bff !important; text-decoration: underline; text-underline-offset: 3px; font-weight: 600; \}/);
});

// Pins bumped together.
test('pins bumped together to v48/v58', () => {
  assert.ok(html.includes('styles.css?v=48'));
  assert.ok(html.includes('live.js?v=58'));});