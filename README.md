# Zero Trust Architecture on a Kubernetes Home Lab

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![NIST SP 800-207](https://img.shields.io/badge/NIST-SP%20800--207-004A87)](https://doi.org/10.6028/NIST.SP.800-207)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.29%2B-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Docker Desktop](https://img.shields.io/badge/Docker%20Desktop-4.30%2B-2496ED?logo=docker&logoColor=white)](https://www.docker.com/products/docker-desktop/)
[![Helm](https://img.shields.io/badge/Helm-3.14%2B-0F1689?logo=helm&logoColor=white)](https://helm.sh/)
[![Architecture](https://img.shields.io/badge/Architecture-C4%20%2B%20CALM-6E40C9)](https://c4model.com/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Last commit](https://img.shields.io/github/last-commit/jamesbuckett/zta-financial-institution-c4-ai-homelab)](https://github.com/jamesbuckett/zta-financial-institution-c4-ai-homelab/commits/main)
[![Stars](https://img.shields.io/github/stars/jamesbuckett/zta-financial-institution-c4-ai-homelab?style=social)](https://github.com/jamesbuckett/zta-financial-institution-c4-ai-homelab/stargazers)

> **A meta-prompt for LLMs.** Paste in a C4-style Zero Trust reference architecture and the prompt returns a progressive, hands-on Kubernetes home lab — seven modules, one per [NIST SP 800-207](https://doi.org/10.6028/NIST.SP.800-207) tenet, runnable on a single-node Docker Desktop cluster.

This repository is **not** the tutorial itself. [The prompt](#the-prompt) is the primary artefact. A reference render of what the prompt produces is committed at [`index.html`](index.html) (~440 KB, single file, no build) so you can preview the output without running the prompt.

![Hero of the rendered tutorial — title, lede, outcomes box, and doc-meta row at desktop width](screenshots/desktop.png)

> _Captured from `index.html` at 1440×900. Mid- and end-of-page slices, plus mobile and tablet captures, live in [`screenshots/`](screenshots/)._

## Repository contents

| Path | Purpose |
|---|---|
| [`README.md`](README.md) | This file. The meta-prompt is the bottom section, [§ The Prompt](#the-prompt). |
| [`index.html`](index.html) | Reference render of the tutorial output (~8 000 lines, single-file, embedded SVG, no JS framework). |
| [`zta-architecture.md`](zta-architecture.md) | Sample input — a C4-style ZTA reference architecture (ARB submission `ZTA-2026-001`). |
| [`screenshot.mjs`](screenshot.mjs) | Playwright script that renders `index.html` at mobile / tablet / desktop. |
| [`screenshots/`](screenshots/) | Generated PNG captures (top / mid / end slices per breakpoint). |
| [`files/zta-homelab/`](files/zta-homelab/) | Scaffolded repo layout the generated tutorial expects (`bootstrap/`, `labs/`, `install.sh`, `teardown.sh`). |
| [`CLAUDE.md`](CLAUDE.md) | Project memory — lab environment assumptions, ARM64 caveats, Falco driver, module structure rules. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to propose prompt-clarity, mapping, or lab-content changes. |
| [`LICENSE`](LICENSE) | MIT. |

## Using the prompt

1. **Pick an input.** Either use [`zta-architecture.md`](zta-architecture.md) as-is or supply your own C4-style ZTA markdown.
2. **Open [§ The Prompt](#the-prompt)** below, paste it into Claude, GPT-4, or Gemini, and attach the markdown (or paste it into the `<ZTA_MARKDOWN>` block at the end).
3. **Run.** The LLM emits a single markdown tutorial: Executive Overview → Lab Environment Setup → seven NIST-tenet labs → Capstone → Mapping Appendix → Cleanup.

Every lab module is required to keep a 10-section structure (Concept → Teardown). Constraints, ARM64 caveats, and version pins live in [`CLAUDE.md`](CLAUDE.md).

## Regenerating screenshots

```bash
npm install        # one-time: pulls Playwright
node screenshot.mjs
```

Captures **mobile (375)**, **tablet (768)**, and **desktop (1440)**. The rendered page is ~120 000 CSS pixels tall, so each viewport produces three slices — `*.png` (top), `*-mid.png`, `*-end.png` — instead of one fullPage capture (Chrome's `Page.captureScreenshot` allocation cannot raster that height at `deviceScaleFactor: 2`).

To screenshot a different page: `node screenshot.mjs <path-or-url>`. See `node screenshot.mjs --help` for details.

## Companion repos

| Repo | Relation |
|---|---|
| [`zta-financial-institution-c4-ai`](https://github.com/jamesbuckett/zta-financial-institution-c4-ai) | C4 + NIST 800-207 reference architecture — the canonical input the prompt is tuned for. |
| [`zta-financial-institution-visual-glossary`](https://github.com/jamesbuckett/zta-financial-institution-visual-glossary) | 73-term searchable visual glossary; rendered-tutorial term names match this verbatim. |
| [`apac-regulations`](https://github.com/jamesbuckett/apac-regulations) | APAC regulatory constraints referenced in the production-translation appendix. |

## License

[MIT](LICENSE) © 2026 James Buckett.

---

## The Prompt

You are a Zero Trust Architecture (ZTA) instructor and Kubernetes practitioner. Your task is to transform the attached markdown file describing a Zero Trust Architecture into a progressive, hands-on home lab tutorial that runs entirely on Kubernetes inside Docker Desktop (single-node, local-only). Every concept introduced in the source document must be mapped explicitly to NIST SP 800-207 (Zero Trust Architecture, August 2020).

### Inputs
- `<ZTA_MARKDOWN>` — a markdown file describing a Zero Trust Architecture (pasted below or attached).
- Target audience: intermediate practitioners comfortable with Docker, kubectl, and YAML, but new to Zero Trust.
- Environment constraint: Docker Desktop with built-in Kubernetes enabled on macOS, Windows, or Linux. No cloud resources, no paid tooling. Prefer open-source projects (e.g., SPIRE/SPIFFE, OPA/Gatekeeper, Istio or Linkerd, cert-manager, Keycloak, Falco, Vault dev-mode, Cilium if feasible on Docker Desktop).

### Required Output Structure

**1. Executive Overview**
- One-paragraph summary of the source ZTA document.
- A table that maps each major section of the source document to the relevant NIST 800-207 tenet(s) (Section 2.1, tenets 1–7), logical components (Section 3.1: PE, PA, PEP, plus supporting components like CDM, threat intel, SIEM, PKI, ID management, data access policy), and deployment variant(s) (Section 3.2: device-agent/gateway, enclave-based, resource-portal, application sandboxing).

**2. Lab Environment Setup**
- Prerequisites checklist (Docker Desktop version, resource allocation — suggest 6 CPU / 8 GB RAM minimum, enabling Kubernetes, kubectl, helm, kustomize).
- A single bootstrap script or manifest bundle that creates namespaces, installs cert-manager, an identity provider (Keycloak), a service mesh (Istio ambient or sidecar, or Linkerd), OPA/Gatekeeper, SPIRE, and a sample microservice app (e.g., a 3-tier "bookstore": frontend, API, database).
- Verification commands with expected output snippets.

**3. Progressive Lab Modules**

Produce **7 lab modules**, one per NIST 800-207 tenet, in this order:

- **Lab 1 — "All data sources and computing services are resources"** (Tenet 1): Deploy the sample app; enumerate every pod, service, and data store as a discrete resource; label them accordingly.
- **Lab 2 — "All communication is secured regardless of network location"** (Tenet 2): Enable mTLS mesh-wide; prove east-west encryption with a packet capture from a debug pod; demonstrate that "inside the cluster" is not trusted.
- **Lab 3 — "Access to individual enterprise resources is granted on a per-session basis"** (Tenet 3): Issue short-lived SPIFFE SVIDs and OAuth2 access tokens via Keycloak; show token expiry forcing re-authentication.
- **Lab 4 — "Access is determined by dynamic policy"** (Tenet 4): Write OPA/Rego or Istio AuthorizationPolicy rules that factor in identity, workload identity (SPIFFE ID), request attributes, and a simulated device posture signal injected as a header or label.
- **Lab 5 — "The enterprise monitors and measures the integrity and security posture of all owned and associated assets"** (Tenet 5): Deploy Falco and a lightweight CDM stand-in; trigger a policy violation (e.g., shell in a container) and show the detection feeding back into policy.
- **Lab 6 — "All resource authentication and authorization are dynamic and strictly enforced before access is allowed"** (Tenet 6): Implement a full PE → PA → PEP decision loop; demonstrate a denied request, change posture, show it permitted; include a sequence diagram.
- **Lab 7 — "The enterprise collects as much information as possible about the current state of assets, network infrastructure, and communications and uses it to improve its security posture"** (Tenet 7): Wire logs, traces, and metrics (Prometheus, Loki or OpenSearch, Tempo/Jaeger) into a dashboard; show how telemetry refines a policy in Lab 4.

For **each module**, provide:
- **NIST 800-207 mapping block** — explicit citation of tenet number, relevant logical component (PE/PA/PEP/etc.), and which deployment variant the lab illustrates.
- **Learning objectives** (3–5 bullets).
- **Concept primer** (approx. 200 words tying the source markdown's language to NIST terminology).
- **Step-by-step instructions** with copy-pasteable commands and complete YAML manifests (no placeholders like "…"; every manifest must be runnable).
- **Validation steps** — exact commands and expected outputs that prove the tenet is enforced.
- **Break-it exercise** — a deliberate misconfiguration the learner applies, then observes the failure mode, then repairs.
- **Reflection questions** (3) linking what they saw back to the source document and to 800-207.

**4. Capstone Lab**
- Combine all seven tenets into one end-to-end scenario: an external user authenticates, a workload requests data, the PE evaluates identity + device + behavioral signals, the PEP enforces, and telemetry closes the loop. Include an architecture diagram (ASCII or Mermaid) that labels every NIST 800-207 logical component present in the cluster.

**5. Mapping Appendix**
- A full matrix: rows = sections/paragraphs of the source markdown, columns = NIST 800-207 tenets (1–7), logical components, and deployment variants. Mark each cell as Primary, Secondary, or N/A, with a one-sentence justification for each Primary mapping.

**6. Cleanup and Next Steps**
- Teardown commands.
- Suggested extensions (e.g., swap Keycloak for Dex, add Cilium network policies, introduce a second cluster to simulate enclave-based deployment from 800-207 §3.2.2).

### Style and Quality Rules
- Use the source markdown's own terminology wherever it aligns with NIST; where it diverges, footnote the divergence and state the NIST-preferred term.
- Every command must be tested-looking: specify the namespace, the context, and the expected result. No hand-waving.
- Prefer declarative YAML over imperative kubectl where practical; commit manifests to a suggested repo layout (`/labs/0X-tenet-name/`).
- Call out any Docker Desktop-specific caveats (e.g., LoadBalancer behavior, Cilium kernel requirements, resource pressure).
- Keep each lab completable in 45–90 minutes.
- Cite NIST SP 800-207 by section number inline (e.g., "per 800-207 §2.1"), not as a bibliography-only reference.

### Deliverable Format
Return the full tutorial as a single markdown document, ready to be rendered or committed to a repo. Use H1 for the tutorial title, H2 for top-level sections, H3 for each lab module, and fenced code blocks with language tags for every command and manifest.

### Source Document
```
<ZTA_MARKDOWN>
[PASTE YOUR MARKDOWN HERE]
</ZTA_MARKDOWN>
```
