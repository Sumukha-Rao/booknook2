# BookNook — Online Bookstore on AWS

A full-stack bookstore with **login, roles, and an admin panel**. Normal users browse, search, filter, add to cart, and check out (simulated); admins add/remove books and view every order. Built as a three-tier app and deployed on AWS.

**Stack:** Node.js 20 + Express · MySQL 8.0 · Bootstrap 5 (vanilla JS) · JWT auth (bcrypt-hashed passwords)
**AWS services (7):** VPC · EC2 (+ Auto Scaling) · RDS MySQL · S3 · CloudFront · Application Load Balancer · Route 53

> Login uses JSON Web Tokens. Passwords are stored as bcrypt hashes. Database credentials and the token secret live in a `.env` file (no Secrets Manager); instances launch without an IAM role, and there is no CloudWatch in this build. A single-file **Terraform** config (`main.tf`) can provision the whole stack.

## Demo accounts (seeded on first run)

| Username | Password | Role |
|----------|----------|------|
| admin | admin123 | admin |
| alice | alice123 | user |
| bob | bob123 | user |

The admin sees **Manage Books** (add / remove) and **All Orders**. Normal users see **Browse**, **Cart**, and **Orders** (their own).

## Files

```
booknook/
├── backend/
│   ├── server.js        # API + auth + DB setup (auto-creates & seeds 5 tables)
│   ├── package.json
│   └── .env.example
├── frontend/
│   └── index.html       # login + shop + admin panel in one page
├── main.tf              # single-file Terraform for the whole AWS stack
├── DEPLOYMENT.md        # step-by-step manual AWS deployment guide
└── README.md
```

## Run locally

Needs **Node 20+** and **MySQL 8.0**.

```bash
cd backend
cp .env.example .env        # set your MySQL DB_* values and a JWT_SECRET
npm install
npm start                   # creates the DB + 5 tables, seeds books & users, runs on :3000
```

Serve the frontend (static):

```bash
cd frontend
python3 -m http.server 8080   # open http://localhost:8080, sign in as admin / alice / bob
```

The `API` constant near the top of the `<script>` in `index.html` points at `http://localhost:3000` for local dev; in production it is rewritten to `""` so the page calls the API same-origin through CloudFront.

## API

| Method | Path | Auth | Notes |
|--------|------|------|-------|
| POST | `/api/login` | — | `{username, password}` → `{token, user}` |
| GET | `/api/me` | token | current user |
| GET | `/health` | — | load-balancer check |
| GET | `/api/books?search=&category=` | token | list / search / filter |
| GET | `/api/categories` | token | categories with counts |
| POST | `/api/books` | **admin** | add a book |
| DELETE | `/api/books/:id` | **admin** | remove a book |
| GET | `/api/cart` · POST · PUT `/:id` · DELETE `/:id` | token | cart (scoped to the user) |
| POST | `/api/orders` | token | checkout |
| GET | `/api/orders` | token | the user's own orders |
| GET | `/api/admin/orders` | **admin** | every order, with the username |

All non-login `/api` routes require an `Authorization: Bearer <token>` header. Cart and orders are scoped to the logged-in user.

## Deploy to AWS

- **Manual:** follow **DEPLOYMENT.md** (VPC → security groups → RDS → EC2 → ALB → Auto Scaling → S3 → CloudFront → Route 53).
- **Automated:** put your repo URL in `main.tf` (`var.git_repo_url`), then `terraform init && terraform apply`. Terraform generates the DB password and a shared `JWT_SECRET` automatically, so every instance validates the same tokens.

Whichever route you use, `JWT_SECRET` must be the **same value on every instance** so tokens work across the load balancer (Terraform handles this for you).
