# Native rebuild safeguards

Work only on ios-native-rebuild. All changes must remain under ios/. Preserve
existing web files, supabase/, .github/workflows/, repository/Pages settings and
deployment integrations. Never push/merge/open a PR to main.

No production endpoints, data, authentication or integration credentials. No
staging connection without explicit owner approval. No paid service, Apple
submission, signing/capability registration, or CI activation. Cloud build proposal
stays Markdown under ios/docs/. Do not reinterpret this as permission to deploy.

Read full root HANDOFF.md and FINAL PDF, honoring later documented owner decisions.
Flag unresolved financial/API contradictions. Do not implement a budget/refund/
week-close/Extra Fund engine in Swift. Use fixed synthetic response fixtures.
Mock receipts must never be presented as completed real mutations.

Use existing checkout (no worktree unless requested). Run Swift core tests, parse
Apple-target Swift where possible, review changed-file scope and run
python3 ios/scripts/check_safety.py before every push. Never print secret values.
Use explicit HEAD:refs/heads/ios-native-rebuild push ref, without force.
Update ios/PROGRESS.md with actual checks and remaining blockers; Linux tests are
not proof of a SwiftUI/Xcode/simulator/device build. No delegation is required.
