# Server core — provenance and ownership

> **License:** the upstream owner granted written permission (Nov 23, 2026)
> to use and redistribute this vendored code under the MIT license for this
> company's internal use. The entire repository is MIT (see the root
> LICENSE). This NOTICE exists only for provenance and attribution.

This directory is **our own** server code, vendored into this repository so we
own it end to end: we can fix bugs, patch security issues, and evolve it on
our schedule, independent of any upstream release cycle.

## Origin

Vendored (copied under its Apache-2.0 license, which explicitly permits
derivative works with attribution) from:

- Repository: https://github.com/aegra/aegra
- Path vendored: `libs/aegra-api/`
- Upstream commit: `2693066413dfafce3fd21bf581f10bd2495b8dd3`
- Upstream license: Apache-2.0 (see `LICENSE` in this directory)
- Design influences also credited in `docs/ARCHITECTURE.md`:
  - The LangSmith Agent Server study (`../agent-server-study/`) for the
    public API contract (50 paths / 64 operations) and feature map.
  - langhost's "stock API + open durable runtime" concept (not used as a
    dependency — deliberately, see ARCHITECTURE.md).

## Modification policy

Upstream is no longer a runtime dependency. Changes here are made directly in
this repo. The import package stays `aegra_api` to keep diffs against the
original readable; functionally this is our code now.

If we ever want to cherry-pick an upstream improvement, re-diff against
`libs/aegra-api/` at the commit above — then re-apply locally.
