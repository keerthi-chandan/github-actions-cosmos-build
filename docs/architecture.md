# Architecture

This pipeline takes the Noble testnet node source from GitHub, builds it, scans it, packages it into a Docker image, pushes that image to AWS ECR, and then rolls out the new image to an ECS Fargate service. Every step runs on GitHub Actions — you don't manage any servers.

Two workflow files split the work along the CI/CD boundary:

- **`.github/workflows/nobled-ci.yml`** — build, test, scan, push image to ECR.
- **`.github/workflows/noble-cd.yml`** — downstream deploy to ECS Fargate, triggered by the CI workflow finishing successfully (or manually for rollback).

## Topology

```
  push to main · PR to main · workflow_dispatch · cron "0 2 * * *"
                            │
                            ▼
                  ┌──────────────────────┐
                  │  GitHub Actions      │
                  │  schedules runners   │
                  └──────────┬───────────┘
                             │ each job gets its own
                             │ fresh ubuntu-latest VM
                             ▼
   nobled CI/CD (.github/workflows/nobled-ci.yml)
                         ┌───────┐
                         │ build │  clone noble → make install → upload nobled
                         └───┬───┘
                             │
            ┌────────┬───────┴────────┬──────────┐
            ▼        ▼                ▼          ▼
          test     lint             gosec     trivy_fs        (parallel jobs)
            └────────┴───────┬────────┴──────────┘
                             ▼  all green, on main, non-PR, "production" approved
                       ┌───────────┐
                       │  publish  │  OIDC → ECR login → docker push → trivy image scan
                       └─────┬─────┘
                             ▼
                        ┌────────┐
                        │ notify │  Slack: image pushed (success / failure)
                        └────┬───┘
                             │
                             │  AWS ECR (image now available)
                             │  720294271237.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled
                             │  (shared with jenkins-cosmos-build)
                             │
                             │  workflow_run: completed
                             │  (fires only if upstream conclusion == 'success')
                             ▼
   nobled CD (.github/workflows/noble-cd.yml)
                       ┌────────┐
                       │ deploy │  OIDC → describe task def → patch image tag (jq)
                       │        │  → register new revision → update-service
                       │        │  → wait services-stable
                       └────┬───┘
                             ▼  "production" approved (same gate as CI publish)
                        ┌────────┐
                        │ notify │  Slack: deploy result (success / failure)
                        └────┬───┘
                             ▼
   AWS ECS Fargate: nobled-cluster / nobled-smoke-service
   (running task def nobled-smoke at the new revision)
```

`workflow_dispatch` on the CD side enters at `deploy` independently — the manual rollback path that bypasses CI entirely.

## What each job does

| Job | Plain-English purpose | When it runs |
|---|---|---|
| `build` | Clones the Noble source, compiles `nobled` with `make install`, uploads the binary as a workflow artifact you can download from the run page. | Every run. |
| `test` | Runs the Noble test suite (`go test ./...`). To keep PR feedback fast, this is skipped on non-main branches — it only runs on pushes to main, on manual triggers, and on the nightly cron. | Conditional. |
| `lint` | Runs `golangci-lint` over the Noble source. Report-only: failures don't block the pipeline, because Noble is upstream code we don't own and can't fix from here. | Every run. |
| `gosec` | Runs the `gosec` security scanner over the Noble source. Uploads its findings as a SARIF file (a standard scan-result format). | Every run. |
| `trivy_fs` | Runs Trivy filesystem scan, which looks for known vulnerable dependencies in `go.sum` and similar files. Uploads its JSON report. | Every run. |
| `publish` | Builds the Docker image from `docker/Dockerfile`, tags it with the git commit SHA and `latest`, pushes both tags to AWS ECR, then runs Trivy against the just-pushed image. **Only runs on `main` branch and only on non-PR events**, and waits for manual approval if you set up the production environment with required reviewers. | Gated. |
| `notify` (CI) | Posts a Slack message saying whether the publish succeeded or failed. If you didn't set up a Slack webhook, this job runs but does nothing. | After publish. |
| `deploy` (CD) | Lives in `noble-cd.yml`. After CI succeeds on main, fetches the live ECS task definition, patches in the new image tag with `jq`, registers a new task definition revision, calls `update-service` on `nobled-smoke-service`, and `aws ecs wait services-stable` blocks until the rollout succeeds. Also runnable manually via `workflow_dispatch` for rollback to any prior SHA. | After CI / manual. |
| `notify` (CD) | Slack message with the deploy result and the deployed image tag. Same skip-on-missing-webhook behavior as the CI notify. | After deploy. |

## Why OIDC (and not access keys)

The `publish` job has to push to AWS ECR, which means it has to authenticate to AWS. The traditional way is to create an AWS IAM user, generate an access key, paste it into GitHub Secrets, and reference it in the workflow.

Problem: access keys are long-lived. If someone gets your key (a leak, a malicious dependency, a careless screen share), they have ECR push access until you notice and rotate the key. Could be hours, could be months.

OIDC ("OpenID Connect") replaces that with short-lived tokens:

1. When the workflow starts, GitHub generates a JWT (a signed JSON token) containing details like *"this is workflow run X in repo keerthi-chandan/github-actions-cosmos-build on branch main"*.
2. The workflow hands this JWT to AWS, asking *"can I have temporary credentials please?"*
3. AWS checks the JWT's signature against GitHub's public keys (proving it really came from GitHub) and checks the trust policy on the IAM role (proving this repo+branch is allowed to use the role).
4. If both checks pass, AWS returns temporary credentials that expire after about one hour.

Nothing long-lived is stored anywhere. If your repo is compromised, an attacker who can run workflows could push images — but they can't *steal a key* and use it from elsewhere. That's a much smaller blast radius.

The `legacy-keys` branch shows the old static-keys flow for side-by-side comparison.

## What `environment: production` does

The `publish` job has `environment: production` set. This unlocks three things in the GitHub UI:

1. **Manual approval gate.** If you add "Required reviewers" to the environment under Settings → Environments → production, every deploy pauses and waits for someone (probably you) to click "Approve" before pushing to ECR. Catches accidental deploys.
2. **Environment-scoped secrets.** You can store secrets *inside* the environment, separate from repo-level secrets — useful later when you have staging and production with different IAM roles.
3. **Deployment log.** GitHub surfaces a "Deployments" sidebar on the repo home page, showing each push to ECR with the timestamp, the commit SHA, and a link to the run. Free deploy history.

## How jobs talk to each other

Jobs share data in two ways:

1. **`needs:`** declares ordering. `publish` has `needs: [build, test, lint, gosec, trivy_fs]` — it won't start until all of those finish, and won't start at all if any of them failed.
2. **Artifacts.** Each job runs on a fresh VM, so files don't carry over. `build` uploads the `nobled` binary; another job could download it via `actions/download-artifact`. In this pipeline we don't pass files between jobs (each one re-clones what it needs) because the Noble source is small enough that re-cloning is cheap.
