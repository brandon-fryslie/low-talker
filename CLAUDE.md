<!-- BEGIN LIT INTEGRATION -->
## lit Agent-Native Workflow

This repository uses `lit` for agent-native issue tracking.

Start by running `lit quickstart` to load the workflow instructions. It prints how tickets are found, created, updated, and closed here, so running it first means the rest of your work follows the conventions this repo expects. It's a quick, read-only command — no need to check in before running it.

<!-- END LIT INTEGRATION -->

## Logging out or restarting is never a requirement

No change, install, upgrade, or verification may require logging out and back in, or restarting — on this Mac, on a test Mac, or on a user's Mac. Never ask for one, never write one into a handoff, ticket, doc, or installer, and never count on one that happens anyway.

Done correctly, nothing here needs one. If a step seems to need a logout, we have broken a macOS rule: entitlements, input method registration or placement, or Info.plist / package manifest configuration. Fix that violation. A check that only passes after a logout or restart has failed.
