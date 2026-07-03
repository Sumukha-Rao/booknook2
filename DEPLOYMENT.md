# BookNook — AWS Deployment Guide

A from-scratch, step-by-step guide to deploy BookNook (with login, roles, and an admin panel) on AWS using **7 services**: VPC, EC2 (+ Auto Scaling), RDS MySQL, S3, CloudFront, Application Load Balancer, and Route 53.

> This build does **not** use IAM roles, Secrets Manager, CloudWatch, or ACM. The database credentials **and the JWT secret** are written into a `.env` file on the server by the instance's user-data. The `JWT_SECRET` must be the **same value on every instance**, or a login token issued by one instance will be rejected by another behind the load balancer.

Demo accounts seeded on first run: **admin / admin123** (admin), **alice / alice123** and **bob / bob123** (users).

Do the phases in order. Each ends with a **✓ Checkpoint** to confirm before moving on. Console clicks are written in arrow notation (`menu → option`). Example region: `ap-south-1`.

> Prefer automation? The included `main.tf` provisions this entire stack with `terraform init && terraform apply` — see the "Automated" note at the end.

---

## Phase 0 — Prerequisites

- An AWS account.
- The BookNook code in a **public** Git repository (the EC2 user-data clones it).
- An EC2 **key pair** in your region for optional SSH access.
- A long random string to use as the JWT secret.

**✓ Checkpoint:** your code is on GitHub, you have a key pair, and you have a JWT secret ready. Note the repo URL.

---

## Phase 1 — Network (VPC, subnets, gateways, routes)

**1.1 Create the VPC** — `VPC → Create VPC → VPC only → Name = booknook-vpc → IPv4 CIDR = 10.0.0.0/16 → Create VPC`

**1.2 Create subnets** (two AZs):

| Subnet | AZ | CIDR | Tier |
|--------|-----|------|------|
| booknook-public-a | az-a | 10.0.0.0/24 | Public (ALB, NAT) |
| booknook-public-b | az-b | 10.0.5.0/24 | Public (ALB) |
| booknook-app-a | az-a | 10.0.1.0/24 | Private (EC2) |
| booknook-app-b | az-b | 10.0.2.0/24 | Private (EC2) |
| booknook-db-a | az-a | 10.0.3.0/24 | Isolated (RDS) |
| booknook-db-b | az-b | 10.0.4.0/24 | Isolated (RDS) |

**1.3 Internet Gateway** — `Internet Gateways → Create → Attach to booknook-vpc`
**1.4 NAT Gateway** — `NAT Gateways → Create → Subnet = booknook-public-a → Allocate Elastic IP → Create`
**1.5 Route tables:**

| Route table | Route to add | Associated subnets |
|-------------|--------------|--------------------|
| booknook-public-rt | `0.0.0.0/0 → Internet Gateway` | public-a, public-b |
| booknook-private-rt | `0.0.0.0/0 → NAT Gateway` | app-a, app-b |
| booknook-db-rt | (none — local only) | db-a, db-b |

**✓ Checkpoint:** public RT → IGW, private RT → NAT, db RT has no internet route.

---

## Phase 2 — Security groups (the chain)

| Security group | Inbound rule | Source |
|----------------|--------------|--------|
| sg-alb | HTTP : 80 | Anywhere `0.0.0.0/0` |
| sg-backend | Custom TCP : 3000 | `sg-alb` |
| sg-rds | MySQL/Aurora : 3306 | `sg-backend` |

**✓ Checkpoint:** three groups exist; each source points to the group in front of it.

---

## Phase 3 — Database (RDS MySQL 8.0)

`RDS → Create database → Standard create → MySQL → 8.0.x → Template = Dev/Test`
- identifier = `booknook-db`; master username = `admin`; set a strong password.
- `db.t3.micro`, 20 GB gp3, Multi-AZ off.
- Connectivity: `VPC = booknook-vpc → DB subnet group = db subnets → Public access = No → Security group = sg-rds`.
- Additional configuration: Initial database name = `booknook` → **Create database**.

**✓ Checkpoint:** status **Available**. Copy the **Endpoint** and remember the password. The API creates and seeds the 5 tables, sample books, and demo users on first boot.

---

## Phase 4 — EC2 backend (with user-data)

`EC2 → Launch instance → Ubuntu 22.04 → t3.small → Network = booknook-vpc → Subnet = booknook-app-a → Auto-assign public IP = Disable → Security group = sg-backend`

`Advanced details → User data →` paste (fill in the RDS endpoint, password, and a JWT secret):

```bash
#!/bin/bash
apt update -y
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs git
git clone https://github.com/your-username/booknook.git /opt/booknook
cd /opt/booknook/backend
cat > .env <<EOF
PORT=3000
CORS_ORIGIN=*
JWT_SECRET=<one-long-random-string-shared-by-all-instances>
DB_HOST=<your-rds-endpoint>
DB_PORT=3306
DB_USER=admin
DB_PASSWORD=<your-rds-password>
DB_NAME=booknook
EOF
npm install
# run as a service so it restarts automatically
cat > /etc/systemd/system/booknook.service <<UNIT
[Unit]
After=network.target
[Service]
WorkingDirectory=/opt/booknook/backend
ExecStart=/usr/bin/node server.js
Restart=always
EnvironmentFile=/opt/booknook/backend/.env
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now booknook
```

**✓ Checkpoint:** the instance boots, clones the repo, and starts the API. On first run it creates the 5 tables and seeds the sample books and the demo users (admin / alice / bob).

---

## Phase 5 — Target group + Application Load Balancer

`EC2 → Target Groups → Create → Instances → HTTP : 3000 → Health check path = /health → register booknook-api-1`
`EC2 → Load Balancers → Create → Application Load Balancer → Internet-facing → the two public subnets → Security group = sg-alb → Listener HTTP : 80 → Forward to booknook-tg → Create`

```bash
curl http://<alb-dns-name>/health
curl -X POST http://<alb-dns-name>/api/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}'   # returns a token
```

**✓ Checkpoint:** health is healthy and the login call returns a token.

---

## Phase 6 — Auto Scaling

`EC2 → Instances → booknook-api-1 → Actions → Image and templates → Create template from instance → Name = booknook-lt`
`EC2 → Auto Scaling Groups → Create → Launch template = booknook-lt → Subnets = app-a + app-b → Attach to booknook-tg → Health check type = ELB → Desired 2 / Min 2 / Max 4 → Target tracking = Average CPU 70% → Create`

> Because the launch template carries the same `.env` (same `JWT_SECRET`), every scaled instance validates the same tokens.

**✓ Checkpoint:** the ASG launches 2 instances and both become healthy.

---

## Phase 7 — Frontend storage (S3)

`S3 → Create bucket → Block all public access = ON → Create`. Set the API URL in `frontend/index.html`:
```js
const API = "";   // same-origin; CloudFront proxies /api to the ALB (Phase 8)
```
`Open the bucket → Upload → Add files = index.html → Upload`

**✓ Checkpoint:** `index.html` is in the private bucket.

---

## Phase 8 — CloudFront (CDN)

`CloudFront → Create distribution → Origin = the S3 bucket → Origin access = OAC → copy the bucket policy into S3 → Redirect HTTP to HTTPS → Default root object = index.html → Create`

Add custom error responses (403 and 404 → `/index.html` → 200). Then route the API through CloudFront:
`Origins → Create origin → Origin domain = the ALB DNS → Protocol = HTTP only`
`Behaviors → Create behavior → Path pattern = /api/* → Origin = the ALB → Cache policy = CachingDisabled → Origin request policy = AllViewer → Save` (repeat for `/health`).

**✓ Checkpoint:** the CloudFront URL shows the login page; signing in as admin / alice / bob works over HTTPS.

---

## Phase 9 — Route 53 (custom domain, optional)

`Route 53 → Hosted zones → your domain → Create record → Type A → Alias = Yes → Alias to CloudFront distribution → Create records`

> A custom domain on HTTPS would need an ACM certificate, which is out of scope. Until then, use the default `*.cloudfront.net` URL.

**✓ Checkpoint:** your domain resolves to the CloudFront distribution.

---

## Final verification

- CloudFront URL shows the **login page**.
- Sign in as **admin** → Manage Books and All Orders are visible; you can add and remove a book.
- Sign in as **alice** → Browse, Cart, Orders; add to cart and check out; the order appears under Orders **and** in the admin's All Orders.
- A normal user cannot reach admin actions (the API returns 403).

## Troubleshooting

| Symptom | Likely cause & fix |
|---------|--------------------|
| Login works once, then requests 401 | `JWT_SECRET` differs between instances. Make every instance (and the launch template) use the same value. |
| ALB returns 502 / target unhealthy | API not on port 3000 or `/health` failing. Confirm sg-backend allows 3000 from sg-alb. |
| API cannot reach the database | sg-rds must allow 3306 from sg-backend; `DB_HOST` must be the RDS endpoint. |
| Site loads but API fails (mixed content) | HTTPS page calling HTTP ALB. Route `/api/*` through CloudFront (Phase 8) and set `const API = ""`. |
| CloudFront `AccessDenied` for S3 | OAC bucket policy not applied — re-copy it into the S3 bucket policy. |
| `npm install` fails on the instance | No outbound internet — confirm the private route table points `0.0.0.0/0` to the NAT gateway. |

## Teardown (to stop charges)

Delete in order: CloudFront distribution → S3 bucket → Auto Scaling group → Launch Template → ALB + Target group → EC2 instances → RDS (skip final snapshot) → NAT Gateway (release its Elastic IP) → VPC. The **NAT Gateway** and **RDS** are the main hourly costs.

## Automated deployment (Terraform)

Instead of the manual phases, put your repo URL in `main.tf` (`var.git_repo_url`) and run `terraform init && terraform apply`. Terraform builds the whole stack, generates the DB password and a shared `JWT_SECRET` automatically, and prints the CloudFront URL. Run `terraform destroy` to remove everything.
