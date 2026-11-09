# OnBudget — native iOS clone

Exact clone of the live web app at **v66**, screen by screen and
function by function, built on the same live backend (same Supabase,
Edge Functions/RPCs, auth, Plaid/Gmail flows). Later live web updates
become native v2.

## Layout

```
ios-clone/
├── OnBudget/                  # App target sources (SwiftUI)
│   ├── OnBudgetApp.swift      # @main entry point
│   ├── ContentView.swift      # Placeholder — replaced screen by screen
│   └── Assets.xcassets/       # AppIcon set + AccentColor (#2f6bff)
├── OnBudgetKit/               # Shared Swift package
│   ├── Package.swift
│   └── Sources/OnBudgetKit/   # DesignTokens, TitleCase, Toast, Configuration
├── OnBudgetTests/             # Xcode unit-test target (smoke tests)
├── OnBudget.xcodeproj/        # App target OnBudget, test target OnBudgetTests
├── Assets/source-logo.jpg     # Original circular logo (icon source)
├── scripts/
│   ├── macos_simulator_test.sh  # Build + test in simulator (CI + local Mac)
│   └── validate_project.py      # Project-graph validation (no build)
├── PROGRESS.md                # Milestone checklist
└── .gitignore                 # CloudResults/ etc.
.github/workflows/ios-clone-simulator.yml   # CI workflow (repo root)
```

## Branch rules

- `ios-clone-v66` is the clone branch. Work happens on sub-branches
  (`ios-clone-v66/<area>`) and merges into it.
- **Never touch `main`.** Never touch web files, SQL migrations, or
  Edge Functions from this tree. Never touch the old
  `ios-native-rebuild` branch.
- Every push to `ios-clone-v66*` that touches `ios-clone/**` is
  evaluated by CI, but the simulator job only runs when the head
  commit message starts with:

  ```
  ci(ios-clone): approved cloud build
  ```

  Use that prefix only when the change is ready for a cloud build.
  Ordinary work-in-progress commits use any other message and skip CI.

## How to build

### Via CI (the only path from a Linux machine)

1. Push a commit whose message starts with
   `ci(ios-clone): approved cloud build` to `ios-clone-v66` or a
   `ios-clone-v66/*` sub-branch.
2. The workflow `OnBudget iOS clone simulator proof` runs on
   `macos-15-intel`: validates the project graph, runs `swift test`
   on the OnBudgetKit package, builds the app for an iPhone 16
   simulator (iOS 18.5 when available), and runs the Xcode smoke tests.
3. The run must be green before the branch is merged into
   `ios-clone-v66`.

### On a Mac (local)

```sh
# Xcode 16.4 preferred; iOS 18.5 simulator runtime preferred.
ONBUDGET_LOCAL_RUN=1 bash ios-clone/scripts/macos_simulator_test.sh
```

Or open `ios-clone/OnBudget.xcodeproj` in Xcode and run the `OnBudget`
scheme. No signing is configured — the project disables code signing
(`CODE_SIGNING_ALLOWED = NO`), so builds are simulator-only until
signing is set up for distribution.

## Design tokens

All colours live in `OnBudgetKit/Sources/OnBudgetKit/DesignTokens.swift`
and are the single source of truth — screens must use them, never
hard-coded hex values. Title Case rules live in `TitleCase.swift`
(minor words lower unless first; exceptions "Sign In" and
"Mark as Charity"). Toast behaviour is specced in `Toast.swift`
(brand-blue bottom toasts, floating clear of the tab bar; soft-red
for errors).

## Secrets

There are none in this repo. `Configuration.swift` holds only the
Supabase URL and the **publishable anon key** — client keys designed
to ship, already public in the web app's `config.js`. The service-role
key must NEVER appear here, in the repo, or in chat.
