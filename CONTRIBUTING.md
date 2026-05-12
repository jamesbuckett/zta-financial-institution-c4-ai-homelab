# Contributing

Thanks for your interest in improving this repo. It is a **meta-prompt for LLMs** — the source artefact is the prompt that generates the tutorial, not the tutorial itself. Keep that distinction in mind when proposing changes.

## Ways to contribute

| Type | Example |
|---|---|
| Prompt clarity | Tighten wording in `README.md` so the generated tutorial is more consistent. |
| NIST 800-207 mapping | Improve the tenet-to-component mapping accuracy. |
| Lab content | Fix a broken command, manifest, or version pin in a generated module. |
| Toolchain | Track upstream changes (Helm chart renames, ARM64 binary names, CRD versions). |
| Known-issue notes | Add a documented workaround for a reproducible Docker Desktop / OS quirk. |
| Companion-repo sync | Reconcile terms with `zta-financial-institution-visual-glossary`. |

## Before you open a PR

1. **Read `CLAUDE.md`** — it captures the non-obvious project conventions (module structure, ARM64 caveats, Falco driver, etc.). PRs that contradict it will be asked to align.
2. **Match the existing prompt structure** — every lab module must keep the 10-section structure (Concept → Teardown). Don't reorder or drop sections.
3. **Pin versions** — no `latest` image tags, no unpinned Helm charts.
4. **Multi-arch** — assume mixed `linux/amd64` and `linux/arm64`. Call out per-arch differences explicitly.
5. **Cite, don't quote** — paraphrase NIST SP 800-207 and cite by section (e.g. `§2.1`); do not paste spec text verbatim.

## PR checklist

- [ ] Change is scoped — one logical concern per PR.
- [ ] Affected modules still emit the full 10-section structure when the prompt is run.
- [ ] Commands include `--context $CTX` and target namespace `zt-lab` where applicable.
- [ ] No vendor-managed services (EKS/AKS/GKE) added to the core flow.
- [ ] No secrets, tokens, or real hostnames in examples — use `${VAR}` placeholders.
- [ ] Commit messages are descriptive (what + why, not just what).

## Issues

When filing an issue, please include:

- Docker Desktop version and host OS/arch (`uname -m`).
- Kubernetes context (`kubectl config current-context`).
- The exact command and full error output.
- Which lab module the issue belongs to (`Lab 1`–`Lab 7`, Capstone, or Bootstrap).

## Out of scope

- Cloud-specific IAM examples in the core flow (keep them in the "production translation" appendix only).
- Unsigned third-party MCP servers or plugins.
- Changes that take a lab past the 45–90 minute completion budget without a strong justification.

## License

By contributing you agree your contributions are licensed under the [MIT License](LICENSE).
