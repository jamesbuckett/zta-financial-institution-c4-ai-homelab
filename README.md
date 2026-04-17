# Implementing Zero Trust Architecture on Kubernetes - A reference tutorial for Tier 1 Financial Institutions.

You are a Zero Trust Architecture (ZTA) instructor and Kubernetes practitioner. Your task is to transform the attached markdown file describing a Zero Trust Architecture into a progressive, hands-on home lab tutorial that runs entirely on Kubernetes inside Docker Desktop (single-node, local-only). Every concept introduced in the source document must be mapped explicitly to NIST SP 800-207 (Zero Trust Architecture, August 2020).

## Inputs
- `<ZTA_MARKDOWN>` — a markdown file describing a Zero Trust Architecture (pasted below or attached).
- Target audience: intermediate practitioners comfortable with Docker, kubectl, and YAML, but new to Zero Trust.
- Environment constraint: Docker Desktop with built-in Kubernetes enabled on macOS, Windows, or Linux. No cloud resources, no paid tooling. Prefer open-source projects (e.g., SPIRE/SPIFFE, OPA/Gatekeeper, Istio or Linkerd, cert-manager, Keycloak, Falco, Vault dev-mode, Cilium if feasible on Docker Desktop).

## Required Output Structure

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

## Style and Quality Rules
- Use the source markdown's own terminology wherever it aligns with NIST; where it diverges, footnote the divergence and state the NIST-preferred term.
- Every command must be tested-looking: specify the namespace, the context, and the expected result. No hand-waving.
- Prefer declarative YAML over imperative kubectl where practical; commit manifests to a suggested repo layout (`/labs/0X-tenet-name/`).
- Call out any Docker Desktop-specific caveats (e.g., LoadBalancer behavior, Cilium kernel requirements, resource pressure).
- Keep each lab completable in 45–90 minutes.
- Cite NIST SP 800-207 by section number inline (e.g., "per 800-207 §2.1"), not as a bibliography-only reference.

## Deliverable Format
Return the full tutorial as a single markdown document, ready to be rendered or committed to a repo. Use H1 for the tutorial title, H2 for top-level sections, H3 for each lab module, and fenced code blocks with language tags for every command and manifest.

## Source Document
<ZTA_MARKDOWN>
[PASTE YOUR MARKDOWN HERE]
</ZTA_MARKDOWN>
