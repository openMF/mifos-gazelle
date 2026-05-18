# OpenSPP Integration Design (GAZ-195)

**Status:** Design Phase  
**Date:** May 18, 2026  
**Author:** Anshika Chaubey  
**Parent Issue:** GAZ-270 (Integrate Demo Creator and Demo Runtime)

---

## 1. Executive Summary

This document proposes integrating **OpenSPP** (Social Safety Net Platform) as a new DPG (Digital Public Good) into Mifos Gazelle, following the same pattern established for Demo Creator/Runtime integration (GAZ-270). The integration prioritizes **resource efficiency** by sharing infrastructure layers, keeping total deployment footprint within acceptable limits.

---

## 2. What is OpenSPP?

**OpenSPP** is an open-source platform for managing social safety net programs. Key characteristics:

- **Architecture:** Built on Odoo ERP as a foundation
- **Design:** Modular, extensible, customizable
- **Integration:** Exposes core functionality via REST APIs
- **Use Cases:** Beneficiary registration, program enrollment, benefit processing, data interoperability
- **Reference:** https://docs.openspp.org/

### Core Components
- **Functional Layer:** Program modules (customizable per requirements)
- **User Engagement Layer:** Web & mobile UIs
- **Data Layer:** Database + API layer
- **Non-Functional:** Security, privacy, monitoring, scalability

---

## 3. Resource Requirements Analysis

### Current Mifos Gazelle Footprint
| Component | RAM | Disk | Notes |
|-----------|-----|------|-------|
| Infrastructure (Kafka, Redis, MySQL, ES, MongoDB, MinIO, NGINX) | ~6GB | ~30GB | Shared |
| MifosX | ~4GB | ~10GB | |
| Payment Hub EE | ~3GB | ~5GB | |
| Mojaloop vNext | ~3GB | ~5GB | |
| **Total (Current)** | **~16GB** | **~50GB** | Baseline requirement |

### OpenSPP Requirements (Production)
- **App Server:** 32GB RAM, 100GB disk
- **Database (PostgreSQL):** 32GB RAM, 250GB+ disk
- **Supporting Services:** Keycloak, APISIX, Redis, MinIO, monitoring

### OpenSPP for Testing/Dev (Lightweight)
- **Minimal Deployment:** ~4-8GB RAM, ~20GB disk
- **Key Insight:** Can share infrastructure with Mifos

---

## 4. Proposed Integration Approach

### 4.1 Shared Infrastructure Strategy

Rather than deploying OpenSPP independently with full infrastructure, **reuse Mifos Gazelle's existing shared services:**

| Service | Current Use | OpenSPP Reuse |
|---------|------------|----------------|
| PostgreSQL | MifosX, PHEE | ✅ Yes (separate schema) |
| Redis | Caching/queuing | ✅ Yes (separate keyspace) |
| MinIO | Object storage | ✅ Yes (separate bucket) |
| Elasticsearch | Logging/monitoring | ✅ Yes (separate index) |
| NGINX | Ingress | ✅ Yes (new routes) |
| Kafka | Event streaming | ✅ Yes (new topics) |

### 4.2 Deployment Model

Follow the same pattern as existing DPGs (mifosx, phee, vnext):

```
Current Deployment Flow:
  run.sh → deployer.sh → [infra.sh, mifosx.sh, phee.sh, vnext.sh]

Proposed Addition:
  run.sh → deployer.sh → [infra.sh, mifosx.sh, phee.sh, vnext.sh, openspp.sh]
```

### 4.3 Implementation Structure

```
mifos-gazelle/
├── src/deployer/
│   ├── openspp.sh          # NEW: OpenSPP deployment logic
│   ├── core.sh             # Shared K8s utilities
│   └── deployer.sh         # Update to include openspp
├── repos/
│   └── openspp/            # NEW: OpenSPP deployment manifests/Helm (submodule)
├── config/
│   └── config.ini          # Update: Add [openspp] section
└── src/deployer/helm/
    └── openspp/            # NEW: Helm charts for OpenSPP
```

### 4.4 Configuration (config.ini)

```ini
[openspp]
enabled = true
namespace = openspp
repo = https://github.com/OpenSPP/openspp-helm
branch = main
docker_repo = ghcr.io/openspp
version = latest
domain_suffix = mifos.gazelle.test
```

---

## 5. Resource Estimate (Integrated)

| Layer | RAM | Disk |
|-------|-----|------|
| Shared Infrastructure | ~6GB | ~30GB |
| MifosX | ~4GB | ~10GB |
| PHEE | ~3GB | ~5GB |
| Mojaloop vNext | ~3GB | ~5GB |
| **OpenSPP (lightweight)** | **~3GB** | **~10GB** |
| **Total (Integrated)** | **~19GB** | **~60GB** |

**Justification:** Resource increase (~3GB RAM, ~10GB disk) is **minimal and justified** because:
1. Shared infrastructure eliminates duplication
2. OpenSPP lightweight mode is sufficient for demo/dev
3. PostgreSQL schema separation prevents conflicts
4. Can be disabled via config if resources constrained

---

## 6. Deployment Steps (Implementation Order)

### Phase 1: Setup (This Issue)
- [ ] Finalize OpenSPP architecture design
- [ ] Identify OpenSPP Helm chart or create custom one
- [ ] Confirm PostgreSQL schema naming convention
- [ ] Document database initialization requirements

### Phase 2: Implementation
- [ ] Create `src/deployer/openspp.sh`
- [ ] Add Helm charts for OpenSPP (or use upstream)
- [ ] Update `src/deployer/deployer.sh` to include openspp step
- [ ] Update `config/config.ini` with [openspp] section
- [ ] Create OpenSPP namespace + RBAC

### Phase 3: Testing & Validation
- [ ] Test deployment: `./run.sh -u $USER -m deploy -a openspp`
- [ ] Test full stack: `./run.sh -u $USER -m deploy -a all`
- [ ] Verify resource usage stays under limits
- [ ] Test data interoperability (OpenSPP ↔ Mifos)

### Phase 4: Documentation
- [ ] Update README with OpenSPP section
- [ ] Add OpenSPP to MIFOS-GAZELLE-README.md
- [ ] Document API endpoints & integration points
- [ ] Create troubleshooting guide

---

## 7. Integration with GAZ-270 (Demo Tools)

This issue follows the same integration pattern as **GAZ-270** (Demo Creator/Runtime):

- **Principle:** New components are deployed as Kubernetes services
- **Mechanism:** Bash orchestration scripts + Helm charts
- **Configuration:** Centralized in `config/config.ini`
- **Reuse:** Share infrastructure, minimize duplication

By completing this issue, we establish a **repeatable pattern** for adding DPGs to Mifos Gazelle.

---

## 8. Dependencies & Constraints

**Hard Constraints:**
- PostgreSQL schema isolation required
- NGINX routing rules for OpenSPP domain
- Kubernetes RBAC for openspp namespace

**Soft Constraints:**
- Resource usage must not exceed 3GB RAM, 10GB disk
- Deployment should complete within 15-20 minutes (current target)
- Must support macOS (Colima) and Linux (k3s)

**Known Dependencies:**
- OpenSPP upstream docs: https://docs.openspp.org/
- OpenSPP GitHub: https://github.com/OpenSPP
- Helm chart availability (may need custom)

---

## 9. Open Questions

1. **Helm Chart Source:** Does OpenSPP provide official Helm charts, or do we create custom ones?
2. **PostgreSQL Initialization:** What's the schema/database naming convention?
3. **API Gateway:** Should OpenSPP integrate with APISIX, or use direct routes?
4. **Authentication:** Should OpenSPP share Keycloak with other DPGs, or run independently?
5. **Demo Data:** Should OpenSPP include pre-loaded demo data (like vnext)?

---

## 10. Success Criteria

- [ ] Design document reviewed and approved by team
- [ ] OpenSPP deployment script tested locally or on CI
- [ ] Full stack deployment works: `./run.sh -u $USER -m deploy -a all`
- [ ] Resource usage documented and verified
- [ ] PR merged with comprehensive documentation
- [ ] Integration follows GAZ-270 pattern (repeatable for future DPGs)

---

## 11. References

- [OpenSPP Architecture Docs](https://docs.openspp.org/technical_reference/architecture.html)
- [OpenSPP GitHub](https://github.com/OpenSPP)
- [Mifos Gazelle CLAUDE.md](./CLAUDE.md)
- [Parent Issue: GAZ-270](https://mifosforge.jira.com/browse/GAZ-270)
- [Current Baseline Requirements](./docs/MIFOS-GAZELLE-README.md)

---

## 12. Next Steps

1. **Review:** Share this design with team (via Jira comment)
2. **Feedback:** Incorporate suggestions from David Higgins & team
3. **Approval:** Finalize architecture before implementation
4. **Implementation:** Begin Phase 2 once approved

**Ready for feedback!** ✅
