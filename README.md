# github-actions-cosmos-build

GitHub Actions CI/CD for the [Noble](https://github.com/strangelove-ventures/noble) Cosmos testnet node — sibling of [jenkins-cosmos-build](https://github.com/keerthi-chandan/jenkins-cosmos-build).

Same Noble `grand-1` testnet node, same multistage Dockerfile, same AWS ECR target — different CI tool. Where the Jenkins repo provisions an EC2 controller + agent and hand-wires SSH credentials, this repo runs on GitHub-hosted ephemeral runners and authenticates to AWS via OIDC (no long-lived keys).

## Pipeline at a glance

```
push / PR / workflow_dispatch / nightly cron
                │
                ▼
         ┌──────────────┐
         │    build     │  setup-go → clone noble → make install → upload nobled artifact
         └──────┬───────┘
                │
   ┌────────┬───┴────┬──────────┐
   ▼        ▼        ▼          ▼
  test    lint    gosec    trivy_fs        (parallel; all needs: build)
   └────────┴────┬───┴──────────┘
                 ▼ (main + non-PR + production environment approval)
         ┌──────────────┐
         │   publish    │  OIDC → ECR login → docker build/push → trivy image scan
         └──────┬───────┘
                ▼
         ┌──────────────┐
         │    notify    │  Slack on success/failure (optional)
         └──────────────┘
```

## Branches

| Branch | AWS auth | Purpose |
|---|---|---|
| `main` | OIDC (IAM role via `aws-actions/configure-aws-credentials` + `role-to-assume`) | Recommended path. No long-lived secrets in GitHub. |
| `legacy-keys` | Static IAM access keys via `secrets.AWS_ACCESS_KEY_ID` + `secrets.AWS_SECRET_ACCESS_KEY` | Kept for side-by-side comparison with the OIDC variant. |

The `legacy-keys` workflow lives at `examples/nobled-ci.legacy-keys.yml` on `main`; on the `legacy-keys` branch it replaces `.github/workflows/nobled-ci.yml`. See [docs/procedure.md §11](docs/procedure.md).

## Docs

- [docs/architecture.md](docs/architecture.md) — ASCII topology, job graph, concept-by-concept comparison vs the Jenkins repo
- [docs/procedure.md](docs/procedure.md) — step-by-step walkthrough, prereqs through teardown
- [docs/purposes.md](docs/purposes.md) — what each file/job is here for

## Reused from jenkins-cosmos-build

- `docker/Dockerfile` — multistage `golang:1.24.13-bookworm` builder → `debian:bookworm-slim` runtime, non-root `cosmos` user, ports 26656/26657/1317/9090. Verbatim copy.
- `scripts/noble-node-setup.sh` — bare-metal Noble `grand-1` node bootstrap, included for parity with the Jenkins repo so the image's deploy target is documented in-repo.

## AWS resources

- ECR repo: `720294271237.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled` (shared with `jenkins-cosmos-build`)
- IAM OIDC provider: `token.actions.githubusercontent.com` (set up once per AWS account)
- IAM role `github-actions-nobled-ci` (trust-scoped to this repo's `main` branch)
- For `legacy-keys` branch: IAM user `github-actions-legacy` with access keys
