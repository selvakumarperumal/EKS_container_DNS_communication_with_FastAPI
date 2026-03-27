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
- [11. The Request Flow in EKS — End-to-End Deep Dive](#11-the-request-flow-in-eks--end-to-end-deep-dive)

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

## 11. The Request Flow in EKS — End-to-End Deep Dive

This section traces a **single HTTP request** from a user's browser all the way to your
application pod running inside EKS, explaining **every component** it passes through.

### High-Level Overview

```
 User (Browser)
      │
      │  ① DNS Resolution
      ▼
 Route 53 / DNS
      │
      │  ② Returns NLB DNS name (IP address)
      ▼
 AWS NLB (Network Load Balancer)
      │
      │  ③ Forwards to Worker Node on NodePort
      ▼
 EKS Worker Node (NodePort)
      │
      │  ④ kube-proxy routes to Istio Ingress Gateway Pod
      ▼
 Istio Ingress Gateway (Pod)
      │
      │  ⑤ VirtualService rules route to app
      ▼
 Application Pod (e.g., web-app-v1)
```

---

### Step ① — DNS Resolution

```
User types: https://myapp.com
                │
                ▼
        ┌──────────────┐
        │   DNS Server  │
        │  (Route 53)   │
        └──────┬───────┘
               │
               │  DNS query: "What is the IP of myapp.com?"
               │
               │  Answer: CNAME → a]b1234567890.elb.ap-south-1.amazonaws.com
               │          (which resolves to NLB IP addresses)
               │
               ▼
        User's browser now knows the NLB IP address
```

**What happens here:**

- You configure a DNS record (e.g., in **Route 53** or any DNS provider) that points
  `myapp.com` to the **AWS NLB's DNS name**.
- The NLB DNS name is auto-generated by AWS when the Load Balancer Controller creates the NLB.
- Route 53 returns the NLB's IP addresses to the browser.

**Example Route 53 record:**

```
Type:  A (Alias)
Name:  myapp.com
Value: a]b1234567890.elb.ap-south-1.amazonaws.com  (NLB DNS)
```

**Or using Terraform (ExternalDNS):**

```hcl
resource "aws_route53_record" "app" {
  zone_id = var.hosted_zone_id
  name    = "myapp.com"
  type    = "A"

  alias {
    name                   = kubernetes_service.app.status[0].load_balancer[0].ingress[0].hostname
    zone_id                = var.nlb_zone_id
    evaluate_target_health = true
  }
}
```

---

### Step ② — Traffic Hits the AWS NLB

```
        User's browser
              │
              │  TCP connection to NLB IP on port 80/443
              ▼
    ┌─────────────────────────────────┐
    │     AWS Network Load Balancer    │
    │                                  │
    │  • Operates at Layer 4 (TCP)     │
    │  • Does NOT inspect HTTP headers │
    │  • Passes raw TCP packets        │
    │  • Has its own Security Group    │
    │    (auto-created by controller)  │
    │                                  │
    │  Listener: Port 80  → Target    │
    │  Listener: Port 443 → Target    │
    │                                  │
    │  Target Group:                   │
    │    Worker Node IPs on NodePort   │
    │    (e.g., 10.0.1.5:31080)       │
    │    (e.g., 10.0.2.8:31080)       │
    └──────────────┬──────────────────┘
                   │
                   ▼
         Selected Worker Node
```

**What happens here:**

- The NLB receives the TCP connection from the user.
- It selects a **healthy worker node** from its **Target Group** using a load balancing algorithm.
- Each target is a worker node IP + NodePort (e.g., `10.0.1.5:31080`).
- The NLB forwards the **raw TCP packets** to the selected node — it does not terminate
  TLS or inspect HTTP (unless configured otherwise).

**Security at this layer:**

| Security Layer     | What It Does                                                |
| ------------------ | ----------------------------------------------------------- |
| **LB Security Group** | Only allows inbound on port 80/443 from the internet     |
| **NLB Target Health**  | Only sends traffic to nodes that pass health checks      |
| **Subnet ACLs**        | Network ACLs on the public subnet filter unwanted traffic|

---

### Step ③ — Traffic Arrives at the Worker Node (NodePort)

```
    NLB
     │
     │  Packet arrives at Worker Node on NodePort 31080
     ▼
┌─────────────────────────────────────────────────────────┐
│                   EKS Worker Node                       │
│                                                          │
│  ┌─────────────────────────────────┐                    │
│  │        Node Security Group       │                    │
│  │                                  │                    │
│  │  Inbound Rule (auto-created):   │                    │
│  │  Allow TCP 31080 from LB-SG     │                    │
│  │                                  │                    │
│  │  ↑ This rule was created by the  │                    │
│  │    LB Controller because the SG  │                    │
│  │    has "owned" tag               │                    │
│  └─────────────────────────────────┘                    │
│                                                          │
│  The packet is accepted on NodePort 31080               │
│  and handed to kube-proxy                                │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
                  kube-proxy
```

**What happens here:**

- The worker node receives the packet on a **NodePort** (a high port in the 30000–32767 range).
- The **Node Security Group** (the one with your `"owned"` tag) has an inbound rule that
  allows this traffic — this rule was **auto-created by the Load Balancer Controller**.
- The packet is accepted by the Linux kernel and handed off to **kube-proxy**.

**What is a NodePort?**

```
A NodePort is a port that Kubernetes opens on EVERY worker node. Any traffic arriving
at any node on this port is treated as traffic for the corresponding Service.

Normal port range:       1–29999     (used by system services)
NodePort range:          30000–32767 (reserved for Kubernetes)

Example:
  Service "istio-ingressgateway" → NodePort 31080
  This means port 31080 is open on ALL worker nodes, all pointing to the same Service.
```

---

### Step ④ — kube-proxy Routes to the Istio Ingress Gateway Pod

```
┌─────────────────────────────────────────────────────────┐
│                   EKS Worker Node                       │
│                                                          │
│  ┌──────────────────────────────────────────┐           │
│  │              kube-proxy                   │           │
│  │                                           │           │
│  │  Maintains iptables/IPVS rules that map:  │           │
│  │                                           │           │
│  │  NodePort 31080                           │           │
│  │      ↓                                    │           │
│  │  Service: istio-ingressgateway            │           │
│  │      ↓                                    │           │
│  │  Endpoints:                               │           │
│  │    • 10.0.1.15:8080 (Gateway Pod 1)      │           │
│  │    • 10.0.2.22:8080 (Gateway Pod 2)      │           │
│  │                                           │           │
│  │  Selects one pod (round-robin/random)     │           │
│  └──────────────────┬───────────────────────┘           │
│                     │                                    │
│                     │  NAT: rewrites destination to      │
│                     │  pod IP (e.g., 10.0.1.15:8080)    │
│                     ▼                                    │
│            Istio Ingress Gateway Pod                     │
└─────────────────────────────────────────────────────────┘
```

**What happens here:**

- **kube-proxy** is a Kubernetes component running on every node. It maintains network rules
  (iptables or IPVS) that map Services to their backing pods.
- When traffic arrives on **NodePort 31080**, kube-proxy looks up which Service owns that port
  → `istio-ingressgateway`.
- It retrieves the **Endpoints** (pod IPs) for that Service.
- It performs **DNAT (Destination NAT)** — rewriting the packet's destination from
  `<node-ip>:31080` to `<pod-ip>:8080`.
- The packet is delivered to one of the **Istio Ingress Gateway pods**.

**What is kube-proxy?**

```
kube-proxy is NOT a traditional proxy that terminates connections. It is a network
rules manager that programs the Linux kernel's packet forwarding tables.

It runs on every node and watches the Kubernetes API for Service/Endpoint changes.
When a new Service is created, kube-proxy instantly updates the routing rules on
every node so that traffic finds the right pods.

Think of it as a "traffic director" built into each node's networking stack.
```

**Key point:** The traffic may land on Node A but get routed to a pod running on Node B.
Kube-proxy handles this cross-node routing transparently using the cluster's pod network
(CNI plugin, e.g., AWS VPC CNI).

---

### Step ⑤ — Istio Ingress Gateway Applies VirtualService Rules

```
┌──────────────────────────────────────────────────────────────┐
│              Istio Ingress Gateway Pod                        │
│              (Envoy Proxy)                                    │
│                                                               │
│  Receives HTTP request:                                       │
│    Host: myapp.com                                            │
│    Path: /api/v1/users                                        │
│    Method: GET                                                │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Step A: Check Gateway resource                      │    │
│  │                                                       │    │
│  │  Gateway says: "I accept traffic on port 80 for      │    │
│  │  hosts: myapp.com"                                    │    │
│  │                                                       │    │
│  │  ✅ Match! Proceed to VirtualService routing.        │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Step B: Check VirtualService rules                   │    │
│  │                                                       │    │
│  │  Rule 1: /api/v1/*  → route to web-app-v1 (port 80) │    │
│  │  Rule 2: /api/v2/*  → route to web-app-v2 (port 80) │    │
│  │  Rule 3: /static/*  → route to cdn-svc (port 80)    │    │
│  │                                                       │    │
│  │  Request path: /api/v1/users                          │    │
│  │  ✅ Matches Rule 1 → Forward to web-app-v1          │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                               │
│  Envoy forwards the request to:                               │
│    web-app-v1.default.svc.cluster.local:80                   │
│    (resolved to pod IP: 10.0.1.30:8000)                      │
└──────────────────────┬───────────────────────────────────────┘
                       │
                       ▼
              Application Pod (web-app-v1)
```

**What happens here:**

- The **Istio Ingress Gateway** is essentially an **Envoy proxy** configured by Istio.
- It first checks the **Gateway** resource to confirm it should accept this traffic
  (based on host, port, and protocol).
- Then it evaluates the **VirtualService** rules to determine where to route the request.
- VirtualService rules can match on: host, path, headers, query parameters, HTTP method, etc.
- Once a match is found, Envoy forwards the request to the destination **Kubernetes Service**,
  which resolves to the actual **pod IP**.

**Example Gateway manifest:**

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: main-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway    # Selects the Istio Ingress Gateway pods
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "myapp.com"        # Accept traffic for this domain
        - "*.myapp.com"      # Accept traffic for subdomains too
```

**Example VirtualService manifest:**

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: myapp-routing
spec:
  hosts:
    - "myapp.com"
  gateways:
    - istio-system/main-gateway   # Attach to the Gateway above
  http:
    # Route 1: API v1 traffic → web-app-v1 service
    - match:
        - uri:
            prefix: /api/v1
      route:
        - destination:
            host: web-app-v1.default.svc.cluster.local
            port:
              number: 80

    # Route 2: API v2 traffic → web-app-v2 service (canary)
    - match:
        - uri:
            prefix: /api/v2
      route:
        - destination:
            host: web-app-v2.default.svc.cluster.local
            port:
              number: 80
          weight: 90       # 90% to v2
        - destination:
            host: web-app-v3.default.svc.cluster.local
            port:
              number: 80
          weight: 10       # 10% to v3 (canary)

    # Route 3: Catch-all → default frontend
    - route:
        - destination:
            host: frontend.default.svc.cluster.local
            port:
              number: 80
```

**Istio Ingress Gateway capabilities:**

| Feature                 | Description                                                |
| ----------------------- | ---------------------------------------------------------- |
| **Path-based routing**  | Route `/api` to backend, `/` to frontend                   |
| **Host-based routing**  | Route `api.myapp.com` vs `admin.myapp.com` to different services |
| **Traffic splitting**   | Send 90% to v1, 10% to v2 (canary deployments)            |
| **Header-based routing**| Route based on custom headers (e.g., `x-version: beta`)   |
| **Fault injection**     | Inject delays or errors for chaos testing                  |
| **Rate limiting**       | Limit requests per second per client                       |
| **mTLS**                | Mutual TLS between services (automatic with Istio)         |
| **Retries & timeouts**  | Automatic retry with configurable backoff                  |

---

### Step ⑥ — Request Reaches the Application Pod

```
┌──────────────────────────────────────────────────────────┐
│              Application Pod (web-app-v1)                 │
│                                                           │
│  ┌─────────────────────────┐  ┌───────────────────────┐  │
│  │    Istio Sidecar Proxy   │  │   Your App Container  │  │
│  │    (Envoy)               │  │   (FastAPI / uvicorn) │  │
│  │                          │  │                       │  │
│  │  • Intercepts inbound    │  │  Listening on :8000   │  │
│  │    traffic               │  │                       │  │
│  │  • Enforces mTLS         │──│  GET /api/v1/users    │  │
│  │  • Collects metrics      │  │                       │  │
│  │  • Distributed tracing   │  │  Response: 200 OK     │  │
│  │                          │  │  {"users": [...]}     │  │
│  └─────────────────────────┘  └───────────────────────┘  │
│                                                           │
│  Pod IP: 10.0.1.30                                        │
│  Container Port: 8000                                     │
└──────────────────────────────────────────────────────────┘
```

**What happens here:**

- If Istio sidecar injection is enabled, the request first hits the **Envoy sidecar proxy**
  in the same pod. This proxy:
  - Terminates **mTLS** (mutual TLS) — verifying the caller's identity.
  - Collects **metrics** (request count, latency, error rate) for observability.
  - Adds **tracing headers** for distributed tracing (Jaeger, Zipkin).
- The sidecar then forwards the request to `localhost:8000`, where your **FastAPI** application
  is listening.
- Your app processes the request and returns a response.
- The response travels back through the **exact same path in reverse**.

---

### Complete End-to-End Diagram with Security Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│                        THE INTERNET                                 │
│                                                                     │
│  User: GET https://myapp.com/api/v1/users                          │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
              ① DNS resolves myapp.com → NLB IP
                           │
┌──────────────────────────▼──────────────────────────────────────────┐
│  AWS NETWORK LOAD BALANCER                                          │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ Security: LB-SG (auto-created by controller)                 │   │
│  │ Allows: Inbound TCP 80/443 from 0.0.0.0/0 (or restricted)  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│  Forwards to Target Group: Worker Nodes on NodePort 31080          │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
              ② NLB selects healthy worker node
                           │
┌──────────────────────────▼──────────────────────────────────────────┐
│  EKS WORKER NODE                                                    │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ Security: Node-SG (tagged "owned")                           │   │
│  │ Allows: TCP 31080 from LB-SG only (auto-created rule)       │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ③ Packet arrives on NodePort 31080                                │
│                                                                     │
│  ┌────────────────────────────────────────┐                        │
│  │ kube-proxy                             │                        │
│  │ ④ DNAT: rewrite dest to pod IP:8080   │                        │
│  │    (Istio Ingress Gateway pod)         │                        │
│  └───────────────────┬────────────────────┘                        │
│                      │                                              │
│  ┌───────────────────▼────────────────────┐                        │
│  │ ISTIO INGRESS GATEWAY POD              │                        │
│  │ ⑤ Gateway: accept myapp.com on :80    │                        │
│  │    VirtualService: /api/v1/* → v1 svc  │                        │
│  └───────────────────┬────────────────────┘                        │
│                      │                                              │
│  ┌───────────────────▼────────────────────┐                        │
│  │ APPLICATION POD (web-app-v1)           │                        │
│  │ ⑥ Sidecar → FastAPI (:8000)           │                        │
│  │    Processes request, returns response  │                        │
│  └────────────────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────────┘
```

---

### Summary: What Each Component Does

| Hop | Component                 | Layer   | Responsibility                                              | Security                              |
| --- | ------------------------- | ------- | ----------------------------------------------------------- | ------------------------------------- |
| ①  | **DNS (Route 53)**        | L7      | Resolves `myapp.com` to NLB IP address                      | DNSSEC (optional)                     |
| ②  | **AWS NLB**               | L4      | Load balances TCP traffic across worker nodes               | LB-SG, health checks, subnet ACLs    |
| ③  | **NodePort**              | L4      | Opens a port on every node for the Service                  | Node-SG inbound rule (auto-managed)  |
| ④  | **kube-proxy**            | L3/L4   | NATs traffic from NodePort to the correct pod IP            | iptables/IPVS rules, network policy  |
| ⑤  | **Istio Ingress Gateway** | L7      | HTTP routing via Gateway + VirtualService rules             | mTLS, rate limiting, auth policies   |
| ⑥  | **Application Pod**       | L7      | Processes the business logic and returns a response         | Istio sidecar (mTLS, metrics, tracing)|

---

### Key Takeaways

1. **The NLB does NOT know about HTTP.** It only forwards raw TCP packets. All HTTP-level
   decisions (path routing, host matching, headers) happen at the **Istio Ingress Gateway**.

2. **kube-proxy is invisible but critical.** Without it, traffic arriving on NodePort cannot
   find the pods. It maintains the routing table on every node automatically.

3. **The Istio Ingress Gateway is the "smart router."** It's where all your traffic management
   rules (path-based routing, canary, retries, fault injection) are applied.

4. **Every layer has its own security.** LB-SG → Node-SG → Network Policy → Istio mTLS.
   Defense in depth means compromising one layer doesn't expose everything.

5. **The `"owned"` tag enables step ③.** Without the tag on the node security group, the
   Load Balancer Controller cannot create the inbound rule that allows NLB traffic to reach
   the NodePort. This is where our Terraform tag connects to the entire flow.

---

## References

- [AWS Load Balancer Controller Documentation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [EKS Subnet Tagging Requirements](https://docs.aws.amazon.com/eks/latest/userguide/network_reqs.html)
- [Kubernetes Service Annotations for AWS](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/annotations/)
- [Istio Ingress Gateway Documentation](https://istio.io/latest/docs/tasks/traffic-management/ingress/)
- [Istio VirtualService Reference](https://istio.io/latest/docs/reference/config/networking/virtual-service/)
- [Kubernetes kube-proxy Documentation](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-proxy/)

