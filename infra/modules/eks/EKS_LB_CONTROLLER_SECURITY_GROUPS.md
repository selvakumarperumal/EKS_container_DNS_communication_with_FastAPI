# EKS Load Balancer Controller — Security Group Tag & Auto-Management

This document explains the purpose of the `kubernetes.io/cluster/<cluster-name>` tag on the
node security group and how the **AWS Load Balancer Controller** automatically manages security
group rules for load balancer traffic.

---

## Table of Contents

- [1. The Tag — What It Is](#1-the-tag--what-it-is)
- [2. Why the Tag Is Required](#2-why-the-tag-is-required)
- [3. Tag Value — "owned" vs "shared"](#3-tag-value--owned-vs-shared)
- [4. How the Controller Works (Step by Step)](#4-how-the-controller-works-step-by-step)
- [5. Security Group Lifecycle](#5-security-group-lifecycle)
- [6. Security Model — Why This Is Secure](#6-security-model--why-this-is-secure)
- [7. Security Controls You Can Apply](#7-security-controls-you-can-apply)
- [8. Companion Tags](#8-companion-tags)
- [9. Common Misconceptions](#9-common-misconceptions)
- [10. Troubleshooting](#10-troubleshooting)

---

## 1. The Tag — What It Is

```hcl
"kubernetes.io/cluster/${var.cluster_name}" = "owned"
```

This is an **AWS resource tag** applied to cloud resources (security groups, subnets, etc.) to
associate them with a specific EKS cluster. It is a well-known tag convention defined by the
Kubernetes cloud-provider interface.

| Part                                          | Description                                                  |
| --------------------------------------------- | ------------------------------------------------------------ |
| `kubernetes.io/cluster/`                      | A standard prefix recognized by Kubernetes and AWS services  |
| `<cluster-name>`                              | Your EKS cluster name — makes the tag cluster-specific       |
| `"owned"` or `"shared"`                       | Indicates the relationship between the resource and cluster  |

---

## 2. Why the Tag Is Required

The **AWS Load Balancer Controller** runs as a pod inside the EKS cluster. When it needs to
provision a load balancer, it must discover the correct AWS resources. It does this by **querying
the AWS API for resources with specific tags** — it does NOT receive resource IDs directly.

**Without this tag:**

- The controller **cannot find** the node security group.
- Load balancer provisioning **fails**.
- Target registration and health checks **break**.
- `Service` (type: LoadBalancer) and `Ingress` resources remain in a **pending** state.

---

## 3. Tag Value — "owned" vs "shared"

| Value       | Meaning                                                                                  | When to Use                                               |
| ----------- | ---------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| **`owned`** | This resource is **exclusively dedicated** to this cluster. The controller can freely add, modify, and remove security group rules on it. | The security group (or subnet) is used by only one cluster. |
| **`shared`**| This resource is **shared** across multiple clusters or other workloads. The controller will use it but **be cautious** about removing rules. | Multiple EKS clusters or non-EKS workloads share the same resource. |

**In this project**, we use `"owned"` because the node security group is dedicated to a single
EKS cluster.

---

## 4. How the Controller Works (Step by Step)

When you create a Kubernetes Service or Ingress, the following happens **automatically**:

```
 ┌──────────────────────────────────────────────────────────────────┐
 │  Step 1: You apply a Kubernetes manifest                        │
 │                                                                  │
 │    kubectl apply -f service.yaml                                │
 │                                                                  │
 │    apiVersion: v1                                                │
 │    kind: Service                                                 │
 │    metadata:                                                     │
 │      name: my-app                                                │
 │      annotations:                                                │
 │        service.beta.kubernetes.io/aws-load-balancer-type: external│
 │    spec:                                                         │
 │      type: LoadBalancer                                          │
 │      ports:                                                      │
 │        - port: 80                                                │
 │          targetPort: 8000                                        │
 └──────────────────────┬───────────────────────────────────────────┘
                        │
                        ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │  Step 2: Controller detects the new Service                     │
 │                                                                  │
 │  The AWS Load Balancer Controller (running as a pod in your     │
 │  cluster) watches the Kubernetes API for Service/Ingress events.│
 └──────────────────────┬───────────────────────────────────────────┘
                        │
                        ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │  Step 3: Controller discovers AWS resources via tags            │
 │                                                                  │
 │  It queries the AWS API:                                        │
 │    "Find security groups tagged with                            │
 │     kubernetes.io/cluster/<my-cluster> = owned"                 │
 │                                                                  │
 │    "Find subnets tagged with                                    │
 │     kubernetes.io/role/elb = 1"                                 │
 └──────────────────────┬───────────────────────────────────────────┘
                        │
                        ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │  Step 4: Controller creates load balancer resources             │
 │                                                                  │
 │  a) Creates a NEW security group for the load balancer (LB-SG) │
 │  b) Creates the ALB/NLB in the discovered subnets              │
 │  c) Attaches LB-SG to the load balancer                        │
 │  d) Adds inbound rule to YOUR node SG:                         │
 │       "Allow traffic from LB-SG on target port"                │
 └──────────────────────┬───────────────────────────────────────────┘
                        │
                        ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │  Step 5: Traffic flows                                          │
 │                                                                  │
 │  Internet → ALB/NLB (LB-SG) → Worker Nodes (Node-SG) → Pod    │
 └─────────────────────────────────────────────────────────────────┘
```

When you **delete** the Service (`kubectl delete -f service.yaml`), the controller
**automatically reverses** all of the above — removes the inbound rules, deletes the LB
security group, and terminates the load balancer.

---

## 5. Security Group Lifecycle

Three security groups are involved in the EKS + Load Balancer setup:

| Security Group         | Created By        | Managed By                | Lifecycle                         |
| ---------------------- | ----------------- | ------------------------- | --------------------------------- |
| **Cluster SG**         | You (Terraform)   | You (Terraform)           | Lives as long as the cluster      |
| **Node SG**            | You (Terraform)   | You + Controller adds inbound rules | Base rules are yours; LB rules are auto-managed |
| **Load Balancer SG**   | Controller (auto) | Controller (auto)         | Created/deleted with each Service |

### What YOU define in Terraform (static, permanent)

```hcl
# Node security group — your base rules
resource "aws_security_group" "node" {
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]    # Allow all outbound traffic
  }

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}
```

### What the CONTROLLER adds automatically (dynamic, temporary)

```
Inbound rule added to Node SG:
  ┌─────────────┬───────────┬──────────┬──────────────────┐
  │ Type        │ Port      │ Protocol │ Source            │
  ├─────────────┼───────────┼──────────┼──────────────────┤
  │ Custom TCP  │ 8000      │ TCP      │ sg-xxxxx (LB-SG) │
  └─────────────┴───────────┴──────────┴──────────────────┘
  ↑ Created when Service is applied
  ↑ Deleted when Service is removed
```

---

## 6. Security Model — Why This Is Secure

### Traffic is NOT open to the world

```
❌ What it does NOT do:    Allow 0.0.0.0/0 → Node SG (open to everyone)
✅ What it ACTUALLY does:  Allow LB-SG    → Node SG on a specific port only
```

### Principle of least privilege

The auto-created rules follow the principle of least privilege:

1. **Source restriction** — Only the LB security group can reach the nodes (not the internet).
2. **Port restriction** — Only the specific target port is opened (e.g., 8000), not all ports.
3. **Protocol restriction** — Only TCP (not UDP or all protocols).
4. **Lifecycle restriction** — Rules exist only while the Service/Ingress exists. Deleted
   Services = deleted rules.

### Traffic flow (locked down at every layer)

```
Internet
    │
    │ (Only port 80/443 allowed by LB-SG)
    ▼
┌──────────────────────┐
│  Load Balancer (ALB) │ ← Has its own SG (LB-SG)
│  SG: LB-SG           │ ← Only allows inbound on configured ports
└──────────┬───────────┘
           │
           │ (Only target port allowed, source: LB-SG)
           ▼
┌──────────────────────┐
│  Worker Nodes        │ ← Node-SG only accepts from LB-SG
│  SG: Node-SG         │ ← Internet CANNOT reach nodes directly
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Pod (your app)      │ ← Receives traffic on targetPort
│  port: 8000          │
└──────────────────────┘
```

**No one can reach your nodes directly — they MUST go through the load balancer.**

### Why this is MORE secure than manual rules

| Manual Approach                                    | Controller Approach                                |
| -------------------------------------------------- | -------------------------------------------------- |
| You write broad rules that stay forever             | Rules are created **only when needed**              |
| Forgotten rules pile up over time                   | Rules are **auto-deleted** when Service is removed  |
| Human error in port/CIDR configuration              | Controller creates **precise, minimal** rules       |
| Hard to audit what goes where                       | Every rule maps to a `kubectl get svc` resource     |
| Must remember to clean up after decommissioning     | Cleanup is **automatic**                            |

---

## 7. Security Controls You Can Apply

Even though the controller auto-manages rules, you still have full control via **annotations**
on your Kubernetes manifest:

### Restrict access to specific IP ranges

```yaml
metadata:
  annotations:
    # Only allow traffic from your office IP
    service.beta.kubernetes.io/aws-load-balancer-inbound-cidrs: "203.0.113.50/32"
```

### Use HTTPS with an ACM certificate

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "arn:aws:acm:region:account:certificate/cert-id"
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
```

### Make the LB internal (not internet-facing)

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
```

### Use a specific security group for the LB

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-security-groups: "sg-xxxxxxxxx"
```

---

## 8. Companion Tags

The `kubernetes.io/cluster` tag works alongside other tags on different resources:

### On subnets (required for LB subnet discovery)

| Tag                                             | Applied To       | Purpose                                  |
| ----------------------------------------------- | ---------------- | ---------------------------------------- |
| `kubernetes.io/cluster/<name>` = `"owned"`      | Subnets          | Associates subnets with the cluster      |
| `kubernetes.io/role/elb` = `"1"`                | Public subnets   | Marks subnets for **public-facing** LBs  |
| `kubernetes.io/role/internal-elb` = `"1"`       | Private subnets  | Marks subnets for **internal** LBs       |

### On security groups (required for SG discovery)

| Tag                                             | Applied To       | Purpose                                         |
| ----------------------------------------------- | ---------------- | ------------------------------------------------ |
| `kubernetes.io/cluster/<name>` = `"owned"`      | Node SG          | Lets the controller discover and manage node SG  |

---

## 9. Common Misconceptions

| Misconception                                              | Reality                                                    |
| ---------------------------------------------------------- | ---------------------------------------------------------- |
| "owned" means anyone can access my nodes                   | No — it only lets the **controller** manage rules on the SG |
| I need to create the LB security group in Terraform        | No — the controller creates and manages it automatically    |
| I need to write ingress rules for LB traffic in Terraform  | No — the controller adds them dynamically at runtime        |
| Auto-managed rules are less secure                         | They are actually **more secure** — precise, minimal, and auto-cleaned |
| If I use "shared", the controller won't work               | It works, but is more cautious about removing rules         |

---

## 10. Troubleshooting

### Load balancer stuck in "Pending" state

```bash
# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Common causes:
# - Missing kubernetes.io/cluster/<name> tag on subnets or SG
# - Missing kubernetes.io/role/elb tag on subnets
# - Controller IAM role lacks required permissions
```

### Unexpected security group rules in AWS Console

If you see inbound rules on the node security group that aren't in your Terraform code,
they were likely **added by the controller**. This is expected behavior — the controller
dynamically manages rules based on active Services/Ingresses.

```bash
# Check which Services exist
kubectl get svc --all-namespaces

# Each LoadBalancer Service = a set of auto-managed SG rules
```

### Terraform plan shows "drift" on security group

Since the controller modifies the node SG at runtime, `terraform plan` may detect changes
it didn't make. You can handle this by adding a `lifecycle` block:

```hcl
resource "aws_security_group" "node" {
  # ... your config ...

  lifecycle {
    # Ignore changes to ingress rules managed by the LB controller
    ignore_changes = [ingress]
  }
}
```

---

## References

- [AWS Load Balancer Controller Documentation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [EKS Subnet Tagging Requirements](https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html)
- [Kubernetes Service Annotations for AWS](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/)
