<!-- docs/adr/README.md -->
# Architecture Decision Records

One file per decision, numbered, never renumbered. A superseded ADR stays in
place with `Status: Superseded by ADR-NNNN`. Start from
[`0000-template.md`](0000-template.md).

| ADR | Title | Status |
|---|---|---|
| [0001](0001-documentation-site.md) | Documentation site: docs-as-code with MkDocs, no GitHub Wiki | Proposed |
| [0004](0004-replicated-local-r-libraries.md) | Keep R libraries on local disk and replicate their contents across hosts | Proposed |
| [0005](0005-bspm-dbus-service-not-sudo.md) | Researchers install R packages through bspm's D-Bus service, not sudo | Accepted |
| [0006](0006-versioned-releases-and-hotfix-register.md) | Versioned releases, a hotfix register and a host deployment ledger | Accepted |
| [0007](0007-os-updates-only-on-a-free-node.md) | OS updates and rstudio-server restarts only in the night window, on a free node | Proposed |

ADR-0002 and ADR-0003 are in review in their own pull request.
