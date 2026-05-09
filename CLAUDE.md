# CLAUDE.md — `zta-financial-institution-c4-ai-homelab`

> **Scope:** Project-level memory for the ZTA homelab tutorial-generation repo.
> **Audience for this file:** Claude Code, when run inside this repository.

## What this repo is

This repo is a **meta-prompt for LLMs**. Given a C4-style ZTA reference architecture markdown as input, it generates a progressive, hands-on Kubernetes home lab tutorial across **seven modules**, each mapped to a tenet of **NIST SP 800-207**.

It is **not** the tutorial itself — it is the prompt that produces the tutorial. Treat the prompt source files as the primary artefact; the rendered tutorials are downstream output.

## Companion repos (cross-reference, do not modify)

- `zta-financial-institution-c4-ai` — the C4+NIST 800-207 reference architecture this homelab implements.
- `zta-financial-institution-visual-glossary` — 73-term searchable visual glossary; reuse term names verbatim for consistency.
- `apac-regulations` — APAC regulatory constraints; reference when adding region-specific notes.

## Lab Environment Assumptions

- **Cluster:** Docker Desktop with Kubernetes enabled, namespace `zt-lab`, context `docker-desktop`.
- **Architecture:** Mixed `linux/amd64` and `linux/arm64` — every binary download or container image MUST be multi-arch or have explicit per-arch instructions. The OPA-Envoy `exec format error` on ARM64 is a recurring pain point; default download examples to `_arm64_static`.
- **Resource budget:** Full stack ~8–10 GB RAM. Provide a "lite" (<6 GB) toggle that drops Falco UI, Loki, and one mesh component.
- **Sample workload:** `orders-api` in namespace `zt-lab`, user `alice`. Keep these names consistent across modules.

## Toolchain (in order of introduction across the 7 modules)

| Module | Concept | Primary Tooling |
|---|---|---|
| 1 | Identity & RBAC | Keycloak / Dex (OIDC), Kubernetes RBAC |
| 2 | Workload Identity | SPIFFE / SPIRE |
| 3 | mTLS & Service Mesh | Istio (preferred) or Linkerd; cert-manager |
| 4 | Admission Policy | OPA / Gatekeeper, Kyverno |
| 5 | Network Policy | Cilium (eBPF), CNI NetworkPolicy |
| 6 | Runtime Detection | Falco (modern_ebpf driver), Falcosidekick |
| 7 | Observability | Prometheus, Grafana, Loki |

## Critical Known Issues to Bake Into the Tutorial

- **Falco on Docker Desktop:** the default `kmod` driver fails — `scap_init` errors. **Always set `driver.kind=modern_ebpf`** in Helm values. Document the eBPF / BTF requirements.
- **OPA-Envoy on ARM64:** the `_amd64` binary throws `exec format error`. Use `opa_envoy_linux_arm64_static`.
- **Pod Security Admission:** Falco needs `hostPID`, `hostNetwork`, host mounts. Restrictive PSA labels in the namespace will block it.
- **Helm chart drift:** Falcosidekick is now a subchart, not a separate install — pin chart versions and call out the upgrade path.

## Tutorial Module Structure (enforce this)

Every module MUST contain, in order:

1. **Concept** (≤200 words, plain English).
2. **NIST 800-207 mapping** — which tenet(s) this satisfies.
3. **Architecture diagram** — Mermaid or ASCII, with PDP/PEP labels.
4. **Prerequisites** — what previous modules must be working.
5. **Step-by-step commands** — copy-pasteable, with `--context $CTX` on every `kubectl`.
6. **Complete YAML manifests** — no `# ... rest omitted` placeholders.
7. **Verification checklist** — `kubectl get`/`logs` commands to prove it works.
8. **"Break it" exercises** — deliberately misconfigure and observe the failure mode.
9. **Troubleshooting** — top 3 known failure modes with fixes.
10. **Teardown** — how to remove cleanly before next module.

## Module Naming & File Conventions

- Bootstrap scripts: `bootstrap/0N-<component>.sh` or `bootstrap/0N-<component>.yaml`.
- Per-module directories: `modules/0N-<concept>/` with `README.md`, `manifests/`, `break-it/`.
- Always include a top-level `bootstrap.sh` that runs modules in order.

## What NOT to Do

- Don't introduce vendor-specific managed services (EKS, AKS, GKE) — this is a Docker Desktop home lab.
- Don't use `latest` image tags. Pin every version.
- Don't reproduce NIST 800-207 spec text verbatim — paraphrase and cite section numbers.
- Don't add cloud-specific IAM examples to the core flow (keep them in a clearly-marked "production translation" appendix).
- Don't suggest unsigned community plugins — official Anthropic marketplace + Context7 only.

## Verification Workflow When Editing the Prompt

1. Run the prompt against `zta-financial-institution-c4-ai/README.md` as input.
2. Confirm 7 modules emit, each meeting the structure above.
3. Spot-check the "break it" exercises actually break the right thing.
4. Confirm Falco and OPA-Envoy ARM64 caveats appear where expected.
