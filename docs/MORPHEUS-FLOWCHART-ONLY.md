# Morpheus Bug Fix Workflow - Visual Flowchart

> **🔒 Security Note**: As of 2026-05-23, all bug fixes now include a **mandatory security review** stage after the Fix step. The `security-review` skill scans for OWASP Top 10 vulnerabilities and blocks PR creation if CRITICAL or HIGH findings are detected.

## Main Decision Flow

```mermaid
flowchart TD
    Start([🐛 Bug Reported]) --> IsBug{Is this a<br/>bug fix?}
    
    IsBug -->|YES| Morpheus[🎯 START WITH MORPHEUS<br/>/morpheus-fix-bug-using-gitnexus]
    IsBug -->|NO<br/>Feature/Refactor| GSD[🏗️ USE GSD<br/>/gsd-plan-phase]
    
    Morpheus --> Orient[📍 Orient Stage<br/>Search codebase<br/>Analyze scope]
    
    Orient --> ScopeCheck{Scope<br/>Assessment}
    
    ScopeCheck -->|Single file/service<br/>Clear root cause| Continue[✅ Continue in Morpheus]
    ScopeCheck -->|Multi-service<br/>Complex/Sprawling| EscalateGSD[⚠️ ESCALATE TO GSD<br/>/gsd-debug]
    
    Continue --> Reproduce[🔬 Reproduce<br/>Create failing test]
    Reproduce --> Fix[🔧 Apply Fix<br/>Minimal change]
    Fix --> SecReview[🔒 Security Review<br/>MANDATORY<br/>Skill: security-review<br/>OWASP Top 10 scan]
    
    SecReview --> SecReviewPass{Security<br/>Pass?}
    SecReviewPass -->|FAIL<br/>CRITICAL/HIGH| FixSecVuln[Fix Security<br/>Vulnerabilities] --> SecReview
    SecReviewPass -->|PASS<br/>0 CRITICAL/HIGH| Verify[✓ Verify<br/>Tests + Impact]
    
    Verify --> TouchUI{Touches<br/>UI/Frontend?}
    Verify --> TouchSec{Touches<br/>Auth/Security?}
    
    TouchUI -->|YES| GStackQA[🎨 GStack /qa<br/>Browser validation<br/>Screenshots<br/>Accessibility]
    TouchUI -->|NO| SkipQA[Skip UI QA]
    
    TouchSec -->|YES| GStackCSO[🔒 GStack /cso<br/>Security audit<br/>OWASP scan<br/>Auth validation]
    TouchSec -->|NO| SkipCSO[Skip Security QA]
    
    GStackQA --> QAPass{QA Pass?}
    QAPass -->|YES| UpdateQA[Update .morpheus-qa.json]
    QAPass -->|NO| FixIssues[Fix QA Issues] --> GStackQA
    
    GStackCSO --> SecPass{Security Pass?}
    SecPass -->|YES| UpdateSec[Update .morpheus-qa.json]
    SecPass -->|NO| FixSec[Fix Security Issues] --> GStackCSO
    
    SkipQA --> CreatePR
    SkipCSO --> CreatePR
    UpdateQA --> CreatePR
    UpdateSec --> CreatePR
    
    CreatePR[📋 Create PR<br/>Telemetry + QA artifacts]
    CreatePR --> Done([✅ Done])
    
    EscalateGSD --> GSDPhases[🏗️ GSD Orchestration<br/>Break into phases]
    GSDPhases --> Phase1[Phase 1<br/>Morpheus session]
    Phase1 --> Phase2[Phase 2<br/>Morpheus session]
    Phase2 --> PhaseN[Phase N<br/>Morpheus session]
    PhaseN --> GSDIntegrate[Integrate all phases]
    GSDIntegrate --> IntegSecGate[🔒 Integration Security & QA Gate<br/>MANDATORY — runs on FULL combined diff<br/>security-review or GStack /cso<br/>+ verification-before-completion<br/>Writes .morpheus-integration-qa.json]
    IntegSecGate --> IntegSecPass{Gate<br/>Pass?}
    IntegSecPass -->|YES| GSDPullRequest[Create comprehensive PR]
    IntegSecPass -->|NO| FixIntegSec[Fix Integration<br/>Security Issues] --> IntegSecGate
    GSDPullRequest --> Done
    
    GSD --> GSDWork[🏗️ GSD Plans & Executes]
    GSDWork --> Done
    
    style Start fill:#e1f5ff
    style Morpheus fill:#90EE90
    style SecReview fill:#FF4500
    style FixSecVuln fill:#FF6B6B
    style GStackQA fill:#FFD700
    style GStackCSO fill:#FFD700
    style EscalateGSD fill:#FF6B6B
    style GSD fill:#FF6B6B
    style Done fill:#90EE90
    style IntegSecGate fill:#FF4500
    style FixIntegSec fill:#FF6B6B
```

---

## Simplified Flow (For Quick Reference)

```mermaid
flowchart LR
    Bug[🐛 Bug] --> Morpheus[Morpheus]
    Morpheus --> Simple{Simple?}
    Simple -->|Yes 80%| PR[Create PR]
    Simple -->|UI 12%| GStack[GStack /qa]
    Simple -->|Security 3%| CSO[GStack /cso]
    Simple -->|Complex 5%| GSD[GSD Debug]
    GStack --> PR
    CSO --> PR
    GSD --> PR
    
    style Morpheus fill:#90EE90
    style GStack fill:#FFD700
    style CSO fill:#FFD700
    style GSD fill:#FF6B6B
```

---

## Workflow by Bug Type

```mermaid
flowchart TD
    subgraph Backend["Backend Bug (80%)"]
        B1[Morpheus Orient] --> B2[Reproduce]
        B2 --> B3[Fix]
        B3 --> B3a[🔒 Security Review<br/>MANDATORY]
        B3a --> B4[Verify]
        B4 --> B5[PR]
    end
    
    subgraph Frontend["Frontend Bug (12%)"]
        F1[Morpheus Orient] --> F2[Reproduce]
        F2 --> F3[Fix]
        F3 --> F3a[🔒 Security Review<br/>MANDATORY]
        F3a --> F4[Verify]
        F4 --> F5[GStack /qa]
        F5 --> F6[PR]
    end
    
    subgraph Security["Security Bug (3%)"]
        S1[Morpheus Orient] --> S2[Reproduce]
        S2 --> S3[Fix]
        S3 --> S3a[🔒 Security Review<br/>MANDATORY]
        S3a --> S4[Verify]
        S4 --> S5[GStack /cso]
        S5 --> S6[PR]
    end
    
    subgraph Complex["Complex Bug (5%)"]
        C1[Morpheus Orient] --> C2[Escalate]
        C2 --> C3[GSD Phase 1]
        C3 --> C4[GSD Phase 2]
        C4 --> C5[GSD Phase N]
        C5 --> C5a[🔒 Integration Security & QA Gate<br/>Full combined diff — MANDATORY<br/>.morpheus-integration-qa.json]
        C5a --> C6[PR]
    end
    
    style Backend fill:#90EE90
    style Frontend fill:#FFD700
    style Security fill:#FF6347
    style Complex fill:#FF6B6B
```

---

## Time-Based Decision

```mermaid
flowchart TD
    Start[Bug Reported] --> Time{Estimate<br/>Fix Time}
    
    Time -->|< 5 min| M1[Morpheus Only<br/>2-3 min actual]
    Time -->|5-15 min| M2[Morpheus Only<br/>5-10 min actual]
    Time -->|15-30 min| M3[Morpheus + GStack<br/>10-20 min actual]
    Time -->|> 30 min| G1[Morpheus → GSD<br/>30-120 min actual]
    
    M1 --> Done1[✅]
    M2 --> Done2[✅]
    M3 --> Done3[✅]
    G1 --> Done4[✅]
    
    style M1 fill:#90EE90
    style M2 fill:#90EE90
    style M3 fill:#FFD700
    style G1 fill:#FF6B6B
```

---

## Integration Points

```mermaid
flowchart LR
    subgraph Core["Morpheus Core"]
        M1[Orient] --> M2[Reproduce]
        M2 --> M3[Fix]
        M3 --> M3a[🔒 Security Review<br/>MANDATORY]
        M3a --> M4[Verify]
    end
    
    M4 --> UI{UI<br/>Change?}
    M4 --> Sec{Security<br/>Change?}
    
    UI -->|Yes| QA[GStack /qa]
    UI -->|No| PR[Create PR]
    
    Sec -->|Yes| CSO[GStack /cso]
    Sec -->|No| PR
    
    QA --> PR
    CSO --> PR
    
    M1 -.->|Too Complex| GSD[GSD Orchestrator]
    GSD --> M1
    GSD --> IntegGate[🔒 Integration Security & QA Gate<br/>Runs ONCE after all phases integrate<br/>On full combined diff — MANDATORY]
    IntegGate --> PR
    
    style Core fill:#90EE90
    style QA fill:#FFD700
    style CSO fill:#FFD700
    style GSD fill:#FF6B6B
    style IntegGate fill:#FF4500
```

---

## Security Review Stage Details

**What happens in the Security Review stage?**

```mermaid
flowchart TD
    Fix[Code Fix Applied] --> SecReview[🔒 Security Review<br/>Skill: security-review]
    
    SecReview --> AST[AST Pattern Detection<br/>SQL injection<br/>Hardcoded secrets<br/>Weak crypto<br/>Command injection]
    SecReview --> Manual[Manual Code Review<br/>Auth checks<br/>Input validation<br/>Data exposure<br/>Crypto strength]
    
    AST --> Findings[Generate Findings<br/>.security-review-findings.json]
    Manual --> Findings
    
    Findings --> Classify[Classify by Severity<br/>CRITICAL / HIGH / MEDIUM / LOW]
    
    Classify --> Check{Any CRITICAL<br/>or HIGH?}
    
    Check -->|YES| Block[❌ BLOCK PROGRESSION<br/>Present findings<br/>Must fix before continuing]
    Check -->|NO| Pass[✅ PASS<br/>Record in .morpheus-qa.json<br/>Continue to Verify stage]
    
    Block --> FixVuln[Developer fixes vulnerabilities]
    FixVuln --> SecReview
    
    style SecReview fill:#FF4500
    style Block fill:#FF6B6B
    style Pass fill:#90EE90
```

**Key Points:**
- **Mandatory**: Runs after every fix, no exceptions
- **Blocking**: CRITICAL or HIGH findings prevent PR creation
- **OWASP Top 10**: Covers all major vulnerability categories
- **Structured Output**: JSON findings with severity, CWE, OWASP mapping, remediation
- **Integration**: Results recorded in `.morpheus-qa.json` and displayed in QA summary

---

## How to Use These Diagrams

### In GitHub / GitLab / Bitbucket
These platforms support Mermaid natively. Just paste the code block with the ` ```mermaid ` tag.

### In Confluence
1. Install the "Mermaid Diagrams for Confluence" plugin
2. Insert a Mermaid macro
3. Paste the diagram code

### In VS Code
1. Install the "Markdown Preview Mermaid Support" extension
2. Open this file in preview mode (Ctrl/Cmd + Shift + V)

### In Notion
1. Create a code block
2. Select "Mermaid" as the language
3. Paste the diagram code

### In Slack/Teams
Use a screenshot of the rendered diagram (GitHub renders it, take a screenshot)

### Online Renderer
Visit https://mermaid.live/ and paste any diagram to see it rendered and export as PNG/SVG

---

## Quick Copy-Paste Versions

### Version 1: Full Decision Tree (Use this for documentation)
Copy lines 5-66 from this file

### Version 2: Simplified (Use this for presentations)
Copy lines 70-84 from this file

### Version 3: By Bug Type (Use this for training)
Copy lines 88-116 from this file

### Version 4: Time-Based (Use this for planning)
Copy lines 120-137 from this file

### Version 5: Integration Points (Use this for architecture docs)
Copy lines 141-165 from this file
