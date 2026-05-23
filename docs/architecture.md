# Architecture

This pipeline takes the Noble mainnet (`noble-1`) node source from GitHub, builds a Docker image, scans it for vulnerabilities, pushes the scanned image to AWS ECR, and then rolls out the new image to an ECS Fargate service. Every step runs on GitHub Actions — you don't manage any servers.

Two workflow files split the work along the CI/CD boundary:

- **`.github/workflows/nobled-ci.yml`** — build image, scan it as a gate, run tests in parallel, then push to ECR.
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
   nobled CI (.github/workflows/nobled-ci.yml)
            ┌────────┬─────────────┬──────────┬──────────┐
            ▼        ▼             ▼          ▼          ▼
          build    test          lint       gosec    trivy_fs     (all parallel from trigger)
            │       │             │          │          │
            │  docker build (uses docker/Dockerfile)
            │  → trivy image scan (HIGH/CRITICAL, gate, exit-code: 1, .trivyignore for upstream CVEs)
            │  → docker save | gzip → upload-artifact (nobled-image-${sha}.tar.gz)
            │
            └───────┴─────────────┴──────────┴──────────┘
                             │ all green, on main, non-PR, "production" approved
                             ▼
                       ┌───────────┐
                       │  publish  │  download-artifact → docker load
                       │           │  → OIDC → ECR login → docker tag → docker push (sha + latest)
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

The image is built **once** (inside `build`) and the same scanned bytes are promoted to ECR by `publish` via a workflow artifact. There is no rebuild in `publish` — that step only tags and pushes the artifact it downloaded.

## What each job does

| Job | Plain-English purpose | When it runs |
|---|---|---|
| `build` | Builds the Docker image from `docker/Dockerfile` (which itself clones Noble at the pinned version and runs `make install` inside the builder stage), then runs Trivy against the image as a **gate** — HIGH/CRITICAL findings outside `.trivyignore` fail the job and no artifact is uploaded. On success, the image is saved to a gzipped tarball and uploaded as a workflow artifact for `publish` to consume. | Every run. |
| `test` | Runs the Noble test suite (`go test ./...`). To keep PR feedback fast, this is skipped on non-main branches — it only runs on pushes to main, on manual triggers, and on the nightly cron. Runs **in parallel** with `build`, not after — tests don't depend on the built image. | Conditional. |
| `lint` | Runs `golangci-lint` over the Noble source. Report-only: failures don't block the pipeline, because Noble is upstream code we don't own and can't fix from here. Runs in parallel with `build`. | Every run. |
| `gosec` | Runs the `gosec` security scanner over the Noble source. Uploads its findings as a SARIF file (a standard scan-result format). Runs in parallel with `build`. | Every run. |
| `trivy_fs` | Runs Trivy filesystem scan, which looks for known vulnerable dependencies in `go.sum` and similar files. Uploads its JSON report. Runs in parallel with `build`. | Every run. |
| `publish` | Downloads the image artifact from `build`, `docker load`s it, then OIDC-logs into ECR, tags the image with the commit SHA and `latest`, and pushes both. **No rebuild and no scan here** — it just promotes the bytes that already passed the gate in `build`. **Only runs on `main` branch and only on non-PR events**, and waits for manual approval if you set up the production environment with required reviewers. | Gated. |
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

1. **`needs:`** declares ordering. `publish` has `needs: [build, test, lint, gosec, trivy_fs]` — it won't start until all of those finish, and won't start at all if any of them failed. The four check jobs themselves declare no `needs:`, so they fan out in parallel with `build` from the moment the workflow triggers.
2. **Artifacts.** Each job runs on a fresh VM, so files don't carry over between runners. `build` produces a gzipped Docker image tarball as the `nobled-image-${sha}` artifact; `publish` downloads it and `docker load`s it into its own daemon before pushing to ECR. This is the *only* file passed between jobs — the four check jobs each re-clone Noble independently because the source is small and the parallelism is more valuable than dedup.

## Why image scan is in `build`, not `publish`

The Trivy image scan acts as a **CVE gate** (exit code 1 on HIGH/CRITICAL findings, suppressions in `.trivyignore`). Putting it in `build` rather than `publish` has two benefits:

1. **The image artifact is only uploaded if the scan passes.** A failed scan short-circuits the job before `docker save` and `upload-artifact` run, so a vulnerable image can never become an artifact that `publish` could later push.
2. **No artifact roundtrip for the scan.** `docker buildx build --load` puts the image straight into the local Docker daemon, where Trivy reads it without going through ECR or the artifact store.

`publish` is therefore pure promotion — its only failure mode is the ECR push itself, not anything about image contents.
