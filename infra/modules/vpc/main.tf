terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

###############################################################################
# VPC MODULE — MAIN CONFIGURATION
# =============================================================================
# This module creates a production-grade VPC (Virtual Private Cloud) for EKS.
# A VPC is your private, isolated network within AWS — like your own data center.
#
# WHAT THIS MODULE CREATES:
# ────────────────────────────────────────────────────────────────────────
# 1. VPC                — The private network itself
# 2. Internet Gateway   — Allows public subnets to reach the internet
# 3. Public Subnets     — For load balancers and NAT Gateway
# 4. Private Subnets    — For EKS worker nodes (no direct internet)
# 5. Elastic IPs        — Static IPs for NAT Gateway
# 6. NAT Gateway        — Lets private subnets make outbound connections
# 7. Route Tables       — Network traffic routing rules
# 8. Network ACLs       — Stateless firewall at the subnet level
# 9. VPC Flow Logs      — Network traffic logging for security auditing
#
# NETWORK ARCHITECTURE:
# ────────────────────────────────────────────────────────────────────────
#
#   Internet
#      │
#      ▼
#  ┌───────────────┐
#  │ Internet GW   │  ← Public internet access point
#  └───────┬───────┘
#          │
#  ┌───────▼──────────────────────────────────────────┐
#  │ VPC (10.0.0.0/16)                                │
#  │                                                   │
#  │  ┌─── Public Subnets ──────────────────────────┐ │
#  │  │ 10.0.101.0/24 │ 10.0.102.0/24 │ 10.0.103.0 │ │
#  │  │    AZ-1       │     AZ-2      │    AZ-3    │ │
#  │  │  [NAT GW]     │  [ALB]        │   [ALB]    │ │
#  │  └───────┬───────────────────────────────────-─┘ │
#  │          │                                        │
#  │  ┌───────▼──── Private Subnets ────────────────┐ │
#  │  │ 10.0.1.0/24  │ 10.0.2.0/24  │ 10.0.3.0/24  │ │
#  │  │    AZ-1      │     AZ-2     │    AZ-3      │ │
#  │  │ [EKS Nodes]  │ [EKS Nodes]  │ [EKS Nodes]  │ │
#  │  └──────────────────────────────────────────────┘ │
#  └───────────────────────────────────────────────────┘
#
###############################################################################


# =============================================================================
# VPC (Virtual Private Cloud)
# =============================================================================
# The VPC is the top-level networking construct in AWS. It defines an isolated
# network where all other resources (subnets, instances, etc.) are placed.
#
# KEY SETTINGS:
# - cidr_block: The IP address range for the VPC (e.g., 10.0.0.0/16)
# - enable_dns_hostnames: Assigns DNS names to instances (required for EKS)
# - enable_dns_support: Enables DNS resolution within the VPC (required for EKS)
#
# WHY DNS IS REQUIRED:
# EKS uses DNS to resolve the API server endpoint and internal service
# discovery. Without DNS support, pods can't communicate with the control plane.
# =============================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-vpc" }
  )
}

# =============================================================================
# INTERNET GATEWAY
# =============================================================================
# An Internet Gateway (IGW) is a horizontally-scaled, redundant, and highly
# available VPC component that allows communication between your VPC and the
# internet. Think of it as the "front door" of your VPC.
#
# IMPORTANT: Only resources in PUBLIC subnets (via route table) can use the IGW.
# Private subnets access the internet through NAT Gateway instead.
#
# There is ALWAYS exactly 1 IGW per VPC. It supports both IPv4 and IPv6.
# =============================================================================
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-igw" })
}

# =============================================================================
# PUBLIC SUBNETS
# =============================================================================
# Public subnets have a route to the Internet Gateway, making resources
# within them directly accessible from the internet (if they have public IPs).
#
# We create 3 public subnets — one in each Availability Zone — for:
#   1. High availability (survives AZ failure)
#   2. Application Load Balancer (ALB) — requires at least 2 AZs
#   3. NAT Gateway placement
#
# count = length(var.public_subnets)
#   → Creates one resource per item in the list
#   → count.index gives 0, 1, 2 for three subnets
#
# map_public_ip_on_launch = true
#   → Instances launched here automatically get a public IP
#   → Required for the NAT Gateway and any public-facing services
# =============================================================================
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, var.public_subnet_tags, { Name = "${var.name_prefix}-public-subnet-${count.index}" })
}

# =============================================================================
# PRIVATE SUBNETS
# =============================================================================
# Private subnets have NO route to the Internet Gateway. Resources here
# cannot be reached from the internet directly.
#
# EKS worker nodes are placed in private subnets for security:
#   - They can't be reached from the internet
#   - They access the internet via NAT Gateway (outbound only)
#   - They communicate with the EKS API server via the private endpoint
#
# Note: map_public_ip_on_launch is NOT set (defaults to false)
#   → Instances here do NOT get public IPs (they don't need them)
# =============================================================================
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags              = merge(var.tags, var.private_subnet_tags, { Name = "${var.name_prefix}-private-subnet-${count.index}" })
}

# =============================================================================
# ELASTIC IP FOR NAT GATEWAY
# =============================================================================
# An Elastic IP (EIP) is a static IPv4 address. NAT Gateway needs an EIP
# because it must have a consistent public IP for outbound connections.
#
# WHY STATIC IP?
# If the NAT Gateway's IP changed, your external services (APIs, package
# registries) might reject the traffic. A static IP can be allowlisted in
# firewalls and security groups.
#
# COUNT LOGIC:
#   - If NAT is disabled → 0 EIPs
#   - If single NAT → 1 EIP (cost saving)
#   - If multi-AZ NAT → 1 EIP per public subnet (high availability)
#
# domain = "vpc" means the EIP is allocated for use in a VPC (not EC2-Classic)
# =============================================================================
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.private_subnet_cidrs)) : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-nat-eip-${count.index}" })

  depends_on = [aws_internet_gateway.main]
}

# =============================================================================
# NAT GATEWAY
# =============================================================================
# NAT (Network Address Translation) Gateway allows instances in private
# subnets to make outbound connections to the internet (e.g., pulling Docker
# images, installing packages) while preventing inbound connections.
#
# HOW IT WORKS:
#   1. Private instance sends packet to the NAT Gateway
#   2. NAT replaces the private source IP with its EIP (public IP)
#   3. Response comes back to the EIP
#   4. NAT forwards the response to the original private instance
#
# SINGLE vs MULTI-AZ:
#   - single_nat_gateway = true:  1 NAT in 1 AZ (~$33/month) — cheaper but single point of failure
#   - single_nat_gateway = false: 1 NAT per AZ (~$99/month) — HA but more expensive
#
# PLACEMENT: NAT Gateway is always in a PUBLIC subnet (it needs internet access)
# =============================================================================
resource "aws_nat_gateway" "nat" {
  count         = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.private_subnet_cidrs)) : 0
  subnet_id     = aws_subnet.public[count.index].id
  allocation_id = aws_eip.nat[count.index].id
  tags          = merge(var.tags, { Name = "${var.name_prefix}-nat-gateway-${count.index}" })

  depends_on = [aws_eip.nat]
}

# =============================================================================
# PUBLIC ROUTE TABLE — SINGLE (1 for ALL public subnets)
# =============================================================================
# A route table contains rules (routes) that determine where network traffic
# goes. Each subnet must be associated with exactly one route table.
#
# The public route table has a route to the Internet Gateway (0.0.0.0/0 → IGW).
# This is what makes subnets "public" — they can reach the internet directly.
#
# ┌───────────────────────────────────────────────────────────────────────────┐
# │ WHY ONLY 1 PUBLIC ROUTE TABLE?                                          │
# │                                                                         │
# │ All public subnets route to the SAME Internet Gateway (IGW).            │
# │ The IGW is a VPC-wide resource — AWS manages it as horizontally-scaled  │
# │ and highly available across ALL AZs. There's always exactly 1 IGW per   │
# │ VPC, and it never fails, so all public subnets can share one table:     │
# │                                                                         │
# │   Public RT ──→ 0.0.0.0/0 ──→ IGW (same for AZ-A, AZ-B, AZ-C)         │
# │                                                                         │
# │ Compare with PRIVATE route tables below — those may need 1 per AZ      │
# │ because NAT Gateways are AZ-specific (see line ~319).                   │
# └───────────────────────────────────────────────────────────────────────────┘
#
# NOTE: Every VPC has a "main" route table by default. We create explicit
# route tables for clarity and to avoid relying on the implicit default.
# =============================================================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-public-route-table" })
}

# =============================================================================
# PUBLIC ROUTE — INTERNET GATEWAY
# =============================================================================
# This route says: "All traffic destined for the internet (0.0.0.0/0) should
# go through the Internet Gateway."
#
# 0.0.0.0/0 is a "default route" — it matches any destination that doesn't
# match a more specific route. Think of it as "everything else goes here."
#
# Without this route, even though the IGW exists, no traffic would flow
# through it because there's no rule telling packets where to go.
#
# ┌───────────────────────────────────────────────────────────────────────────┐
# │ WHY 0.0.0.0/0 TO AN IGW ALLOWS BOTH INGRESS AND EGRESS:                 │
# │                                                                         │
# │ When you create a route that points 0.0.0.0/0 to an Internet Gateway    │
# │ (IGW), it allows traffic to flow in both directions:                    │
# │                                                                         │
# │ 1. Egress (Outbound):                                                   │
# │    If an instance in your public subnet tries to reach google.com       │
# │    (covered by 0.0.0.0/0), the route table sends this request out       │
# │    through the Internet Gateway.                                        │
# │                                                                         │
# │ 2. Ingress (Inbound):                                                   │
# │    Because the IGW is stateful and bidirectional, when the response     │
# │    comes back, the IGW remembers who asked for it and routes the        │
# │    traffic back to the correct instance.                                │
# │    Additionally, if someone on the outside internet tries to connect    │
# │    to your instance's Public IP, the IGW acts as the front door. The    │
# │    traffic enters through the IGW, which translates the Public IP       │
# │    into your instance's Private IP.                                     │
# │                                                                         │
# │ IMPORTANT DISTINCTION FOR PRIVATE SUBNETS (NAT GATEWAY):                │
# │ This is why Private Subnets use a NAT Gateway instead of an IGW.        │
# │ A route pointing 0.0.0.0/0 to a NAT Gateway is EGRESS-ONLY.             │
# │ Instances inside a private subnet can reach out to the internet, but    │
# │ nobody on the internet can initiate a connection to them. The NAT       │
# │ Gateway blocks unsolicited inbound requests!                            │
# └───────────────────────────────────────────────────────────────────────────┘
# =============================================================================
resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id

  depends_on = [aws_internet_gateway.main]
}

# =============================================================================
# PUBLIC ROUTE TABLE ASSOCIATION
# =============================================================================
# Associates each public subnet with the public route table.
# Without this association, subnets use the VPC's default (main) route table,
# which has NO internet route — making the subnet effectively private.
#
# count matches the number of public subnets, so each gets associated.
# =============================================================================
resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id

  depends_on = [aws_route.public]
}

# =============================================================================
# PRIVATE ROUTE TABLE(S) — 1 or MANY (depends on NAT Gateway mode)
# =============================================================================
# Private route tables route outbound traffic through the NAT Gateway
# instead of the Internet Gateway. This allows private subnets to:
#   ✅ Make outbound connections (pull images, install packages)
#   ❌ Receive inbound connections from the internet
#
# ┌───────────────────────────────────────────────────────────────────────────┐
# │ WHY MULTIPLE PRIVATE ROUTE TABLES (but only 1 public)?                  │
# │                                                                         │
# │ Unlike the IGW (VPC-wide, HA by design), each NAT Gateway lives in     │
# │ ONE specific AZ. If that AZ goes down, the NAT goes down with it.      │
# │                                                                         │
# │ single_nat_gateway = true  (dev/staging — saves ~$66/mo):               │
# │   1 NAT in AZ-A → 1 route table shared by all private subnets          │
# │   ⚠️  If AZ-A fails, ALL private subnets lose internet access          │
# │                                                                         │
# │   Private RT ──→ 0.0.0.0/0 ──→ NAT-A                                   │
# │     ↑ AZ-A, AZ-B, AZ-C all use this                                    │
# │                                                                         │
# │ single_nat_gateway = false (production — full HA):                      │
# │   1 NAT per AZ → 1 route table per AZ, each pointing to its own NAT   │
# │   ✅ If AZ-A fails, AZ-B and AZ-C continue working independently       │
# │                                                                         │
# │   Private RT-A ──→ 0.0.0.0/0 ──→ NAT-A  (AZ-A subnet uses this)       │
# │   Private RT-B ──→ 0.0.0.0/0 ──→ NAT-B  (AZ-B subnet uses this)       │
# │   Private RT-C ──→ 0.0.0.0/0 ──→ NAT-C  (AZ-C subnet uses this)       │
# └───────────────────────────────────────────────────────────────────────────┘
# =============================================================================
resource "aws_route_table" "private" {
  count  = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.private_subnet_cidrs)) : 1
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name_prefix}-private-route-table-${count.index}" })
}

# =============================================================================
# PRIVATE ROUTE — NAT GATEWAY
# =============================================================================
# This route sends all outbound traffic (0.0.0.0/0) from private subnets
# through the NAT Gateway. The NAT Gateway translates the private IP to
# its public EIP, makes the request, and returns the response.
#
# Traffic Flow:
#   Private instance → Private Route Table → NAT Gateway → Internet
#   Internet → NAT Gateway → Private instance (response only)
# =============================================================================
resource "aws_route" "private" {
  count                  = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(var.private_subnet_cidrs)) : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat[count.index].id

  depends_on = [aws_nat_gateway.nat]
}

# =============================================================================
# PRIVATE ROUTE TABLE ASSOCIATION
# =============================================================================
# Associates each private subnet with its route table.
# If single NAT: all private subnets → 1 route table
# If multi-AZ: each private subnet → its own route table
# =============================================================================
resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.enable_nat_gateway ? (var.single_nat_gateway ? 0 : count.index) : 0].id

  depends_on = [aws_route.private]
}

# =============================================================================
# NETWORK ACLs (NEW — Security Enhancement)
# =============================================================================
# Network ACLs (NACLs) are STATELESS firewalls at the subnet level.
# They are evaluated BEFORE security groups and provide a second layer
# of defense.
#
# NACL vs SECURITY GROUP:
# ┌──────────────────────┬──────────────────────────────────┐
# │ Feature              │  NACL           │  Security Group │
# │──────────────────────│─────────────────│────────────────│
# │ Level                │  Subnet         │  Instance/ENI  │
# │ Stateful             │  ❌ No          │  ✅ Yes        │
# │ Rule evaluation      │  In order       │  All evaluated │
# │ Allow + Deny rules   │  ✅ Both        │  ❌ Allow only │
# │ Default              │  Allows all     │  Denies all    │
# └──────────────────────┴──────────────────────────────────┘
#
# STATELESS means: If you allow inbound traffic on port 443, you also need
# to explicitly allow the outbound RESPONSE traffic (ephemeral ports 1024-65535).
# =============================================================================

# ------- PUBLIC SUBNET NACL -------
# Controls traffic entering and leaving public subnets.
# Allow:
#   - HTTP (80), HTTPS (443) inbound from anywhere (for ALB)
#   - SSH (22) from anywhere (if needed — restrict in production)
#   - Ephemeral ports (1024-65535) for return traffic
#   - All outbound traffic
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public[*].id # [*] expands to all public subnet IDs

  # ---- INBOUND RULES ----

  # Rule 100: Allow HTTPS inbound from anywhere
  # ALBs and external services need HTTPS access
  ingress {
    rule_no    = 100         # Evaluated in ascending order (100 first)
    protocol   = "tcp"       # TCP protocol
    action     = "allow"     # Allow this traffic
    cidr_block = "0.0.0.0/0" # From any source IP
    from_port  = 443         # HTTPS port
    to_port    = 443         # Single port
  }

  # Rule 200: Allow HTTP inbound from anywhere
  # For HTTP-to-HTTPS redirects and health checks
  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }

  # Rule 300: Allow ephemeral port responses
  # When our instances make outbound requests, responses come back on
  # high-numbered ports (1024-65535). We must allow these in because
  # NACLs are STATELESS — they don't track connections.
  ingress {
    rule_no    = 300
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535 # Ephemeral port range
  }

  # Rule 400: Allow all traffic from within the VPC
  # Intra-VPC communication (e.g., NAT Gateway → private subnets)
  ingress {
    rule_no    = 400
    protocol   = "-1" # -1 means ALL protocols
    action     = "allow"
    cidr_block = var.vpc_cidr # Only from within our VPC
    from_port  = 0
    to_port    = 0
  }

  # ---- OUTBOUND RULES ----

  # Rule 100: Allow all outbound traffic
  # Public subnets need unrestricted outbound for:
  #   - NAT Gateway forwarding traffic to the internet
  #   - ALB communicating with targets in private subnets
  egress {
    rule_no    = 100
    protocol   = "-1" # All protocols
    action     = "allow"
    cidr_block = "0.0.0.0/0" # To any destination
    from_port  = 0
    to_port    = 0
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-public-nacl"
    }
  )
}

# ------- PRIVATE SUBNET NACL -------
# More restrictive than public NACLs since private subnets shouldn't
# receive any direct internet traffic.
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.private[*].id

  # ---- INBOUND RULES ----

  # Rule 100: Allow all traffic from within the VPC
  # Cluster communication: ALB → nodes, nodes → nodes, control plane → nodes
  ingress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  # Rule 200: Allow ephemeral port responses from the internet
  # When private instances make outbound requests (via NAT), responses
  # come back on ephemeral ports. NACL is stateless so we must allow this.
  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # ---- OUTBOUND RULES ----

  # Rule 100: Allow all outbound traffic
  # Nodes need outbound for: pulling images, API calls, DNS, etc.
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-private-nacl"
    }
  )
}


# =============================================================================
# VPC FLOW LOGS (OPTIONAL — Disabled by default)
# =============================================================================
# VPC Flow Logs capture information about the IP traffic going to and from
# network interfaces in your VPC. This is essential for:
#   - Security monitoring (detecting unauthorized access attempts)
#   - Troubleshooting connectivity issues
#   - Compliance auditing (PCI DSS, HIPAA, SOC 2)
#
# Each flow log record contains:
#   - Source/destination IP and port
#   - Protocol, packets, bytes
#   - Action (ACCEPT or REJECT)
#   - Timestamp
#
# We send flow logs to CloudWatch Logs for easy querying and alerting.
#
# KUBE-NATIVE ALTERNATIVE:
#   → Cilium Hubble: Network observability with flow logs and service maps
#   → Calico: Network policy engine with flow log export
#
# COST: ~$5/month for a small cluster (charged per GB ingested).
#
# To enable: set enable_vpc_flow_logs = true in terraform.tfvars
# =============================================================================

# ------- IAM ROLE FOR FLOW LOGS -------
# VPC Flow Logs needs an IAM role to write to CloudWatch Logs.
# The role has a trust policy allowing the vpc-flow-logs service to assume it.
resource "aws_iam_role" "flow_log" {
  count       = var.enable_flow_logs ? 1 : 0
  name_prefix = "${var.name_prefix}-vpc-flow-log-"

  # Trust policy: "Who can assume this role?"
  # Answer: Only the vpc-flow-logs.amazonaws.com service
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole" # The action: assume this role
      Effect = "Allow"          # Allow (not deny)
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com" # Only this AWS service
      }
    }]
  })

  tags = var.tags
}

# ------- IAM POLICY FOR FLOW LOGS -------
# Grants the flow log role permission to create and write to CloudWatch Logs.
resource "aws_iam_role_policy" "flow_log" {
  count       = var.enable_flow_logs ? 1 : 0
  name_prefix = "${var.name_prefix}-vpc-flow-log-"
  role        = aws_iam_role.flow_log[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "logs:CreateLogGroup",    # Create the log group if it doesn't exist
        "logs:CreateLogStream",   # Create log streams within the group
        "logs:PutLogEvents",      # Write individual log events
        "logs:DescribeLogGroups", # List log groups
        "logs:DescribeLogStreams" # List log streams
      ]
      Effect   = "Allow"
      Resource = "*" # Allow for all log resources
    }]
  })
}

# ------- CLOUDWATCH LOG GROUP FOR FLOW LOGS -------
# Where the flow log data is stored. Retention is set to 30 days to
# balance between compliance requirements and storage costs.
resource "aws_cloudwatch_log_group" "flow_log" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/aws/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = var.flow_logs_retention_in_days

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-vpc-flow-logs"
    }
  )
}

# ------- VPC FLOW LOG RESOURCE -------
# The actual flow log that captures network traffic data.
resource "aws_flow_log" "main" {
  count           = var.enable_flow_logs ? 1 : 0
  vpc_id          = aws_vpc.main.id                          # Monitor this VPC
  traffic_type    = "ALL"                                    # Capture ALL traffic (ACCEPT + REJECT)
  iam_role_arn    = aws_iam_role.flow_log[0].arn             # Use the IAM role we created
  log_destination = aws_cloudwatch_log_group.flow_log[0].arn # Send to CloudWatch

  # traffic_type options:
  #   "ACCEPT" — Only accepted traffic (less data, lower cost)
  #   "REJECT" — Only rejected traffic (good for security monitoring)
  #   "ALL"    — Both accepted and rejected (recommended for security)

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-vpc-flow-log"
    }
  )
}
