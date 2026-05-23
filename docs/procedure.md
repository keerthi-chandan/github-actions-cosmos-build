# Procedure — github-actions-cosmos-build

Step-by-step walkthrough, mostly UI-driven (AWS Console + GitHub Settings) so you can see what each piece looks like. Only local git commands use the terminal.

Sections:

1. Prereqs
2. Create the GitHub repo
3. First push (terminal)
4. AWS — create the IAM OIDC provider
5. AWS — create the IAM role for GitHub Actions (ECR push + ECS deploy)
6. GitHub — set the secret + variable
7. GitHub — configure the `production` environment
8. First full run + approve the production deploy (CI → ECR push)
9. Verify the CD workflow (auto-deploy + manual rollback)
10. PR trigger test
11. Verify the `paths-ignore` filter (docs/CD skip CI)
12. `workflow_dispatch` + scheduled cron
13. Switch to the `legacy-keys` branch (static keys variant)
14. Teardown

---

## 1. Prereqs

Tools you need:

- `git` (terminal)
- A web browser logged into your GitHub account `keerthi-chandan`
- A web browser logged into the AWS Console for account `720294271237` (the account that hosts the `cosmos/nobled` ECR repo and will host the ECS resources)

You do **not** need: `gh` CLI, `aws` CLI, anything else — the UI handles it all.

Local scaffold at `~/Desktop/devops/github-actions-cosmos-build/` is already in place.

The CI workflow pushes images to ECR repo `cosmos/nobled`. The CD workflow (step 9) rolls those images out to an ECS Fargate service that this procedure walks through creating in §9.1–9.5. No dependency on any other pipeline — this repo is self-contained.

## 2. Create the GitHub repo

1. Open https://github.com/new in your browser.
2. **Owner**: `keerthi-chandan`.
3. **Repository name**: `github-actions-cosmos-build`.
4. **Description** (optional): `GitHub Actions CI/CD for Noble testnet node`.
5. **Public** — required for the portfolio.
6. **Leave unchecked**: "Add a README file", "Add .gitignore", "Choose a license". We have all of these locally; if you check any of them, GitHub creates a first commit on the remote that will conflict with your local one.
7. Click **Create repository**.
8. On the next page, copy the HTTPS URL — it'll look like `https://github.com/keerthi-chandan/github-actions-cosmos-build.git`.

## 3. First push (terminal)

```bash
cd ~/Desktop/devops/github-actions-cosmos-build

# Verify git identity is set globally (should match your GitHub account)
git config user.name
git config user.email

# Initialize and stage everything
git init -b main
git add .

# Verify nothing accidentally gets committed (e.g., .env, secrets)
git status

# Commit
git commit -m "Initial scaffold: nobled CI/CD"

# Wire up the remote and push
git remote add origin https://github.com/keerthi-chandan/github-actions-cosmos-build.git
git push -u origin main
```

The push triggers a workflow run automatically (because the trigger includes `push: branches: [main]`).

**Expected outcome of this first run**: the `publish` job will fail at the "Configure AWS credentials via OIDC" step, because we haven't created the IAM role or set `AWS_ROLE_ARN` yet. **That's expected** — we set that up in steps 4-6. The other jobs (`build`, `test`, `lint`, `gosec`, `trivy_fs`) should pass.

You can watch the run in your browser at `https://github.com/keerthi-chandan/github-actions-cosmos-build/actions`.

## 4. AWS — create the IAM OIDC provider

This is a one-time setup per AWS account. It tells AWS *"trust JWTs signed by GitHub Actions."*

1. Open the AWS Console → sign in to account `720294271237`.
2. In the top search bar, type **IAM** → click the IAM service.
3. In the left sidebar, click **Identity providers**.
4. Click the **Add provider** button (top right).
5. **Provider type**: choose **OpenID Connect**.
6. **Provider URL**: paste `https://token.actions.githubusercontent.com`.
7. Click **Get thumbprint** — AWS auto-fetches GitHub's TLS certificate fingerprint. You should see a thumbprint appear.
8. **Audience**: type `sts.amazonaws.com`.
9. Click **Add provider** (bottom right).

You should now see `token.actions.githubusercontent.com` in the Identity providers list. The ARN looks like `arn:aws:iam::720294271237:oidc-provider/token.actions.githubusercontent.com`.

## 5. AWS — create the IAM role for GitHub Actions

Now we create a role that the GitHub Actions workflow can assume. We'll use the **Custom trust policy** flow instead of the **Web identity** wizard — the wizard generates a `StringLike` condition with an array of `repo:OWNER/REPO:ref:refs/heads/BRANCH` strings that's surprisingly fragile (the role assumption can fail with `Not authorized to perform sts:AssumeRoleWithWebIdentity` even when the policy looks correct). Pasting a hand-written wildcard policy avoids that whole class of issue and is the production-grade pattern anyway.

1. Still in IAM, click **Roles** in the left sidebar.
2. Click the **Create role** button (top right).
3. **Trusted entity type**: choose **Custom trust policy**.
4. In the JSON editor that appears, delete the placeholder and paste:

    ```json
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "Federated": "arn:aws:iam::720294271237:oidc-provider/token.actions.githubusercontent.com"
          },
          "Action": "sts:AssumeRoleWithWebIdentity",
          "Condition": {
            "StringEquals": {
              "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
            },
            "StringLike": {
              "token.actions.githubusercontent.com:sub": "repo:keerthi-chandan/github-actions-cosmos-build:*"
            }
          }
        }
      ]
    }
    ```

    What this says: only JWTs signed by `token.actions.githubusercontent.com` (the GitHub Actions OIDC issuer) with audience `sts.amazonaws.com` and a subject under `repo:keerthi-chandan/github-actions-cosmos-build:*` may assume this role. The `*` after the repo allows any ref inside the repo — branches, tags, PRs, environments — but rejects every other repo or user on GitHub.

5. Click **Next** (bottom right).
6. **Permissions**: in the search box, type `AmazonEC2ContainerRegistryPowerUser` and check the checkbox next to it. This gives the role permission to push and pull from any ECR repo in your account.
7. Click **Next**.
8. **Role name**: `github-actions-nobled-ci`.
9. **Description** (optional): `OIDC role for github-actions-cosmos-build workflow`.
10. Scroll down and click **Create role**.
11. You'll land back on the Roles list. Click into the `github-actions-nobled-ci` role you just created.
12. At the top of the role's page, you'll see the **ARN** — it looks like `arn:aws:iam::720294271237:role/github-actions-nobled-ci`. Copy this ARN; you'll paste it into GitHub in the next step.

> **Why not the Web identity wizard?** The wizard's UI for "GitHub branch" generates a trust policy with `StringLike` and an array containing an exact `:ref:refs/heads/main` string (sometimes duplicated). In practice this combination can return `Not authorized to perform sts:AssumeRoleWithWebIdentity` even when the JWT subject claim from the workflow exactly matches. Switching to a hand-written wildcard policy resolves it immediately and is what most production OIDC setups use anyway — you typically want CI to work from any branch, not just one.

### Add ECS deploy permissions to the role

The ECR PowerUser policy covers the `publish` job (push image to ECR). The `noble-cd.yml` workflow also needs to update an ECS service — that's a separate, narrow set of permissions we attach as an inline policy.

13. Still on the `github-actions-nobled-ci` role page, click **Add permissions** (the button is on the right above the policy list) → **Create inline policy**.
14. Click the **JSON** tab and paste:

    ```json
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "ECSTaskDefRegister",
          "Effect": "Allow",
          "Action": [
            "ecs:DescribeTaskDefinition",
            "ecs:RegisterTaskDefinition"
          ],
          "Resource": "*"
        },
        {
          "Sid": "ECSServiceUpdate",
          "Effect": "Allow",
          "Action": [
            "ecs:UpdateService",
            "ecs:DescribeServices"
          ],
          "Resource": "arn:aws:ecs:us-east-1:720294271237:service/nobled-cluster/nobled-smoke-service"
        },
        {
          "Sid": "PassExecutionRole",
          "Effect": "Allow",
          "Action": "iam:PassRole",
          "Resource": "arn:aws:iam::720294271237:role/ecsTaskExecutionRole"
        }
      ]
    }
    ```

    Note: `DescribeTaskDefinition` and `RegisterTaskDefinition` don't support resource-level scoping (AWS limitation), so they use `Resource: "*"`. `UpdateService` is scoped to *only* the `nobled-smoke-service`. `iam:PassRole` is scoped to *only* the ECS task execution role — without this, ECS rejects the new task definition revision with "Unable to assume role."

15. Click **Next** → **Policy name**: `github-actions-nobled-cd-ecs` → **Create policy**.

## 6. GitHub — set the secret + variable

The workflow needs to know which IAM role to assume. We pass the ARN through GitHub Secrets, and the AWS region through Variables.

1. Go to `https://github.com/keerthi-chandan/github-actions-cosmos-build`.
2. Click **Settings** (top right of the repo navigation).
3. In the left sidebar, click **Secrets and variables** → **Actions**.

### Add the secret

4. Click the green **New repository secret** button.
5. **Name**: `AWS_ROLE_ARN`.
6. **Secret**: paste the role ARN you copied from step 5.12 (e.g., `arn:aws:iam::720294271237:role/github-actions-nobled-ci`).
7. Click **Add secret**.

### Add the variable

8. At the top of the same page, click the **Variables** tab (next to "Secrets").
9. Click the green **New repository variable** button.
10. **Name**: `AWS_REGION`.
11. **Value**: `us-east-1`.
12. Click **Add variable**.

### Optional: Slack webhook

If you want Slack notifications on success/failure:

13. Back on the Secrets tab, click **New repository secret**.
14. **Name**: `SLACK_WEBHOOK_URL`.
15. **Secret**: paste your Slack incoming webhook URL.
16. Click **Add secret**.

If you skip this, the `notify` job runs but just logs "skipping notify" — no error.

## 7. GitHub — configure the `production` environment

The `publish` job has `environment: production` in its definition. We need to actually create that environment in GitHub Settings so we can configure the manual approval gate.

1. Still in **Settings** for the repo, click **Environments** in the left sidebar (about midway down the list).
2. Click the green **New environment** button.
3. **Name**: `production`.
4. Click **Configure environment**.
5. On the configuration page, check the **Required reviewers** checkbox.
6. In the field that appears, type your own GitHub username `keerthi-chandan` and select yourself from the dropdown.
7. (Leave "Wait timer" at 0 unless you want a forced delay between approval and execution — not needed.)
8. (Leave "Deployment branch policies" alone for now — by default it accepts any branch, which is fine since the workflow itself gates on main.)
9. Click **Save protection rules**.

Now every time the `publish` job runs, it pauses and waits for you to click "Approve" in the run page.

## 8. First full run + approve the production deploy

We need to trigger a new run, since the first push happened before the AWS setup.

### Trigger the run

Option A — push an empty commit:

```bash
cd ~/Desktop/devops/github-actions-cosmos-build
git commit --allow-empty -m "Trigger first full run after AWS setup"
git push
```

Option B — manual trigger via UI:

1. Go to the Actions tab: `https://github.com/keerthi-chandan/github-actions-cosmos-build/actions`.
2. In the left sidebar, click **nobled CI/CD**.
3. On the right side, click the **Run workflow** dropdown → leave branch as `main` → click the green **Run workflow** button.

### Watch the run

1. Refresh the Actions tab. The new run appears at the top with a yellow "in progress" icon.
2. Click into it. You'll see the job DAG — `build`, `test`, `lint`, `gosec`, and `trivy_fs` all running in parallel from the start. `publish` waits for all five.
3. The slow part is `build` (the Docker build of Noble — clone + `make install` inside the builder stage, ~3–5 minutes). When all five jobs finish, `publish` pauses with an orange **"Waiting"** badge and a banner saying *"This workflow is awaiting deployment to production."*

### Approve the deploy

4. Click the **Review deployments** button in that banner.
5. Check the **production** checkbox.
6. (Optional) add a comment.
7. Click **Approve and deploy**.
8. The `publish` job starts. It's quick (~30–60 seconds) — it only downloads the image artifact, `docker load`s it, and pushes to ECR. There's no rebuild in `publish`.

### Verify the image landed in ECR

1. Open the AWS Console → search **ECR** → click Elastic Container Registry.
2. Click **Repositories** in the left sidebar.
3. Click into the **cosmos/nobled** repository.
4. On the **Images** tab, you'll see a new image tagged with the git commit SHA and `latest`, with the push time matching your run.

## 9. Verify the CD workflow (auto-deploy + manual rollback)

`.github/workflows/noble-cd.yml` is a second workflow file that handles the ECS Fargate rollout. It runs as a *downstream* workflow that fires after `nobled CI/CD` succeeds, so CI and CD are independently retriggerable.

The CD workflow only *updates* an existing ECS service — it does not create the cluster, service, or task definition. §9.1–9.5 below walk through creating those resources in the console one time. After that, the workflow takes over.

You also need the inline IAM policy you attached in step 5 sub-steps 13-15 (`github-actions-nobled-cd-ecs`). Without it, the deploy job fails on `ecs:DescribeTaskDefinition` with `AccessDenied`.

### 9.1 — CloudWatch log group (~2 min)

The task definition refuses to register if the log group it references doesn't exist yet, so this comes first.

1. AWS Console → search **CloudWatch** → click the service.
2. Left sidebar → **Log groups** → click **Create log group** (top right).
3. **Log group name**: `/ecs/nobled-smoke`.
4. **Retention setting**: `1 week` (cheap; we don't need forever).
5. Click **Create**.

### 9.2 — ECS task execution role (~3 min)

This role is what Fargate uses to pull from ECR and write to CloudWatch *before* your container starts. It is separate from the OIDC role from step 5 (which is what the GitHub Actions runner assumes).

1. AWS Console → IAM → **Roles** (left sidebar).
2. Click **Create role** (top right).
3. **Trusted entity type**: **AWS service**.
4. **Use case**: **Elastic Container Service** → select **Elastic Container Service Task** (NOT "EC2 Container Service") → click **Next**.
5. **Permissions policies**: in the search box, type `AmazonECSTaskExecutionRolePolicy` and check it → **Next**.
6. **Role name**: `ecsTaskExecutionRole` — use this exact name. The inline policy you attached in step 5.14 has `iam:PassRole` scoped to this exact ARN; renaming it will silently break the deploy job.
7. **Description** (optional): `Fargate execution role — pulls from ECR + writes CloudWatch logs`.
8. Scroll down → **Create role**.

### 9.3 — ECS cluster (~2 min)

A cluster is just a named bucket for services and tasks — no compute is reserved upfront on Fargate.

1. AWS Console → search **ECS** → click Elastic Container Service.
2. Left sidebar → **Clusters** → **Create cluster** (top right).
3. **Cluster name**: `nobled-cluster`.
4. **Infrastructure**: leave **AWS Fargate (serverless)** checked. Uncheck "Amazon EC2 instances" if it's on.
5. **Monitoring / Tags**: skip.
6. Click **Create**. Takes ~1 min.

### 9.4 — Task definition, revision 1 (~5 min)

This is the blueprint Fargate uses to launch a container. The CD workflow patches the image field and registers a new revision on every deploy, but revision 1 has to be created in the console once.

1. Still in ECS → **Task definitions** (left sidebar) → **Create new task definition** (top right). Pick the standard wizard, not the JSON editor.
2. **Task definition family**: `nobled-smoke`.
3. **Infrastructure requirements**:
    - Launch type: **AWS Fargate**
    - Operating system / Architecture: **Linux/X86_64**
    - CPU: `0.25 vCPU`
    - Memory: `0.5 GB`
    - Task role: leave blank (`None`) — the smoke-test container needs no AWS perms.
    - Task execution role: **`ecsTaskExecutionRole`** (the one from §9.2).
4. **Container — 1**:
    - Name: `nobled`
    - Image URI: `720294271237.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled:latest` (bootstrap with `:latest` — the CD workflow rewrites this on every deploy)
    - Essential container: **Yes**
    - Port mappings: leave empty (smoke test exposes nothing)
5. Expand **Docker configuration**:
    - **Entry point**: `sh,-c`
    - **Command**: `nobled version && sleep 3600`

    ⚠️ **Landmine**: the Dockerfile sets `ENTRYPOINT ["nobled"]` + `CMD ["start"]`. If you override only **Command**, the final invocation becomes `nobled sh -c "nobled version && sleep 3600"` — broken. You **must** override both Entry point and Command. After saving, reopen the task def and confirm both fields stuck — the console UI here is finicky.

6. Expand **Logging** → enable **Use log collection** → **CloudWatch**:
    - Log group: select `/ecs/nobled-smoke` (must exist from §9.1)
    - Region: `us-east-1`
    - Stream prefix: `nobled`
7. Health check / environment vars / secrets: skip.
8. Scroll down → **Create**. You should now have `nobled-smoke:1`.

### 9.5 — ECS service (~5 min)

The service is the long-running supervisor that keeps the desired count of tasks alive and is what the CD workflow's `UpdateService` call targets.

1. ECS → Clusters → click `nobled-cluster` → **Services** tab → click **Create**.
2. **Environment**:
    - Compute options: **Launch type**
    - Launch type: **Fargate**
    - Platform version: `LATEST`
3. **Deployment configuration**:
    - Application type: **Service**
    - Family: `nobled-smoke`
    - Revision: `1` (latest)
    - Service name: `nobled-smoke-service`
    - Desired tasks: `1`
4. **Networking**:
    - VPC: default
    - Subnets: pick the **2 default public subnets** (us-east-1a and us-east-1b)
    - Security group: choose **Create a new security group**, name it `nobled-smoke-sg`, leave **no inbound rules**, and accept the default outbound rule (all traffic out — needed to reach ECR's public endpoint).
    - Public IP: **TURNED ON** ⚠️ if this is off, Fargate can't reach ECR; the task gets stuck `PROVISIONING → STOPPED` with `CannotPullContainerError`. Easiest mistake in this whole phase.
5. **Load balancing**: None.
6. **Service auto scaling**: off.
7. Scroll down → **Create**. Takes ~1–2 min.

**Verify the bootstrap task runs**: after ~2 min, the service should report `Running tasks: 1`. Open the **Tasks** tab → click the task → **Logs** tab. You should see Noble's version banner:

```
name: nobled
version: v11.4.0
commit: ...
go: go version go1.25.X linux/amd64
```

The container then sleeps 3600s, exits 0, and ECS restarts it. Looping forever is expected.

If the task gets stuck in PROVISIONING or fails to pull the image, double-check the public IP toggle on the service and that the ECR repo `cosmos/nobled` actually has an image (step 8 should have pushed `:latest`).

### Watch the auto-deploy

Once the CI run from step 8 finishes successfully, GitHub fires a `workflow_run` event that triggers `nobled CD` automatically.

1. Refresh the Actions tab. You'll see a new run for **nobled CD** appear at the top (separate from the `nobled CI/CD` run).
2. Click into it. The `deploy` job starts, then pauses with the orange **"Waiting"** badge — the same `production` environment gate from step 7 applies here too.
3. Click **Review deployments** → check **production** → **Approve and deploy**.
4. Watch the `Deploy to ECS` step. You'll see the same log progression as the Jenkins ECS Deploy stage:

    ```
    ==> Reading current task def for nobled-smoke
    ==> Patching image tag to 720294271237.dkr.ecr.us-east-1.amazonaws.com/cosmos/nobled:<sha>
    ==> Registering new task definition revision
        new revision: arn:aws:ecs:us-east-1:720294271237:task-definition/nobled-smoke:<N>
    ==> Updating nobled-smoke-service
    ==> Waiting for services-stable (fails if rollout doesn't succeed)
    ==> Rollout complete
    ```

5. The `notify` job then posts to Slack (if `SLACK_WEBHOOK_URL` is configured) with `:rocket: nobled <sha7> deployed to nobled-smoke-service`.

### Verify the rollout in AWS

1. AWS Console → search **ECS** → **Clusters** → click `nobled-cluster`.
2. **Services** tab → click `nobled-smoke-service`.
3. **Deployments** tab — the latest deployment shows status `PRIMARY` with the new task definition revision number, and the image field matches `cosmos/nobled:<your-commit-sha>`.
4. **Tasks** tab — the running task should be on the new revision, in `RUNNING` state with `HealthStatus: HEALTHY`.

### Manual deploy / rollback

If a deploy goes bad and you want to roll back to an older image without re-running CI:

1. Actions tab → **nobled CD** in the left sidebar.
2. Click the **Run workflow** dropdown (top right of the run list).
3. **image_tag** input: paste a previous commit SHA (40 chars from `git log`), or type `latest` to redeploy the current `latest` tag.
4. Click the green **Run workflow** button.
5. Approve at the production gate as usual.

Every CI publish tags the image with the commit SHA, so any historical build can be redeployed by SHA. This is the rollback path — no need to revert commits or re-trigger CI.

## 10. PR trigger test

This verifies that pull requests run CI but don't push to ECR.

```bash
cd ~/Desktop/devops/github-actions-cosmos-build
git checkout -b chore/test-pr
echo "" >> README.md
git commit -am "test PR trigger"
git push -u origin chore/test-pr
```

Then in GitHub:

1. Go to the repo home → you'll see a banner "chore/test-pr had recent pushes" with a **Compare & pull request** button. Click it.
2. Leave the defaults. Click **Create pull request**.

Check the Actions tab — a new run starts for the PR. Expected:

- `build`, `test` (with the "skip on non-main" message), `lint`, `gosec`, `trivy_fs` all run in parallel.
- `publish` is **skipped** (you'll see it greyed out with a "Skipped" badge) because the workflow's `if:` condition gates it to main + non-PR.
- `build` still produces the image artifact and runs the Trivy image scan as a gate — so PRs surface CVE regressions even though they never push to ECR.

Close the PR without merging:

1. On the PR page, scroll to the bottom.
2. Click **Close pull request**.
3. Click **Delete branch** (the button appears after closing).

## 11. Verify the `paths-ignore` filter (docs/CD skip CI)

The CI workflow has a `paths-ignore:` block on both `push` and `pull_request` triggers (see tutorial §4.2). Patterns ignored: `**.md`, `docs/**`, `LICENSE`, `.gitignore`, `.github/workflows/noble-cd.yml`. A push that touches **only** ignored files should produce no CI run.

### Test 1 — docs-only push should skip CI

```bash
cd ~/Desktop/devops/github-actions-cosmos-build
echo "" >> README.md
git commit -am "docs: nudge README to test paths-ignore"
git push
```

Then in GitHub:

1. Go to the Actions tab.
2. Confirm that **no new run appears** for `nobled CI/CD` for that commit. The commit itself shows up in the repo's commit list (with no status check icon), but the Actions tab is unchanged.

### Test 2 — mixed push should still run CI

If you change a code file in the same commit as a doc file, CI fires as normal — the filter only skips when *every* changed file matches an ignored pattern.

```bash
echo "// nudge" >> docker/Dockerfile  # any non-ignored file works
echo "" >> README.md
git commit -am "mixed: code + doc change"
git push
```

This time a new `nobled CI/CD` run appears — `paths-ignore` doesn't apply because `docker/Dockerfile` is outside the ignore list.

### Test 3 — CD-only edit should skip CI but trigger CD

The CI workflow ignores `.github/workflows/noble-cd.yml`. So editing only the CD file does **not** trigger CI, and (because CD itself is triggered via `workflow_run` on CI success) the CD workflow also does not auto-fire from this push alone. The CD workflow on this branch is reachable only via the next CI success or via manual `workflow_dispatch` from the Actions tab.

### When to update the filter

Add to `paths-ignore:` when you find yourself routinely pushing files that don't need CI (new doc directories, IDE config files, etc.). Remove patterns if you ever start running code from a path that's currently ignored — e.g., if `docs/` ever holds generated/executable content.

## 12. `workflow_dispatch` + scheduled cron

`workflow_dispatch` was tested in step 8 (Option B). The cron `0 2 * * *` fires nightly at 2 AM UTC — you don't need to do anything to test it, it'll just appear in the Actions tab tomorrow morning. If you want to confirm it's registered:

1. Actions tab → left sidebar → **nobled CI/CD**.
2. Above the run list, you'll see **"This workflow has a `workflow_dispatch` event trigger"** badge if the file is parsed correctly.
3. (There's no UI badge for cron, but if the workflow file parses, the cron is registered.)

## 13. Switch to the `legacy-keys` branch (static keys variant)

This branch shows what the workflow looks like with traditional access keys instead of OIDC. We're doing it for educational comparison, not to actually use long-term.

### Create the IAM user (UI)

1. AWS Console → IAM → **Users** (left sidebar).
2. Click **Create user** (top right).
3. **User name**: `github-actions-legacy`.
4. **Do not** check "Provide user access to the AWS Management Console" — this user is for programmatic access only.
5. Click **Next**.
6. **Permissions options**: choose **Attach policies directly**.
7. Search for `AmazonEC2ContainerRegistryPowerUser` and check it.
8. Click **Next** → **Create user**.

### Generate access keys for the user (UI)

9. Back on the Users list, click into `github-actions-legacy`.
10. Click the **Security credentials** tab.
11. Scroll to **Access keys** → click **Create access key**.
12. **Use case**: choose **Command Line Interface (CLI)** (closest match — it's for programmatic use).
13. Check the confirmation box, click **Next**.
14. (Optional) description: `GitHub Actions legacy-keys branch`.
15. Click **Create access key**.
16. **Important**: on the success page, click **Show** next to the Secret access key. **You can only see the secret once.** Copy both the Access key ID and the Secret access key somewhere safe (a password manager). Or click **Download .csv file**.
17. Click **Done**.

### Add the keys to GitHub Secrets

18. Go to the repo → Settings → Secrets and variables → Actions.
19. Click **New repository secret** → Name: `AWS_ACCESS_KEY_ID` → Secret: paste the Access key ID → Add.
20. Click **New repository secret** → Name: `AWS_SECRET_ACCESS_KEY` → Secret: paste the Secret access key → Add.

### Create the branch locally and swap the workflow

```bash
cd ~/Desktop/devops/github-actions-cosmos-build
git checkout -b legacy-keys

# Replace the OIDC workflow with the access-keys variant
rm .github/workflows/nobled-ci.yml
mv examples/nobled-ci.legacy-keys.yml .github/workflows/nobled-ci.yml

git add -A
git commit -m "Switch to access-keys auth for legacy-keys branch"
git push -u origin legacy-keys
```

The push triggers a workflow run on the `legacy-keys` branch. On this branch, `publish` is still gated to `main` only, so it won't push to ECR — but you can see in the run that `build`, `test` (skipped), `lint`, `gosec`, `trivy_fs` all run with the static-keys workflow file.

If you want to *actually* exercise the access-keys publish, you'd merge `legacy-keys` to `main`. Don't do that in this scaffold — the point is to view the two workflow files side-by-side in the repo.

## 14. Teardown

If you want to fully clean up the AWS side of this lab (the GitHub repo itself costs nothing while idle — keep it for the portfolio).

### Delete the IAM role (UI)

1. AWS Console → IAM → Roles.
2. Search for `github-actions-nobled-ci` and check the checkbox.
3. Click **Delete** (top right) → type the role name to confirm → **Delete**.

### Delete the ECS resources (UI, only if you created them in §9)

Order matters — you can't delete a cluster while it still has services, and you can't delete a task definition family while a revision is `ACTIVE`. Walk through in this order:

1. **Scale the service to 0** so no Fargate tasks keep running while you tear down:
    - ECS → Clusters → `nobled-cluster` → Services tab → `nobled-smoke-service` → **Update service** → Desired tasks: `0` → **Update**.
2. **Delete the service**: same service page → **Delete service** (top right) → check **Force delete** → type `delete` to confirm.
3. **Deregister the task definition revisions**: ECS → Task definitions → click `nobled-smoke` → select all revisions → **Actions** → **Deregister**. (You can't outright delete revisions; deregistered is fine and free.)
4. **Delete the cluster**: ECS → Clusters → check `nobled-cluster` → **Delete cluster** → type the cluster name to confirm.
5. **Delete the security group**: EC2 → Security groups → check `nobled-smoke-sg` → **Actions** → **Delete security groups**. (If it complains about dependencies, wait ~1 min after deleting the service for the ENI to free up.)
6. **Delete the execution role**: IAM → Roles → `ecsTaskExecutionRole` → **Delete** → confirm. Skip this step if any other lab in the account uses this role — the name is generic.
7. **Delete the log group**: CloudWatch → Log groups → check `/ecs/nobled-smoke` → **Actions** → **Delete log group(s)**.

### Delete the legacy IAM user (UI, only if you did step 13)

1. AWS Console → IAM → Users.
2. Click into `github-actions-legacy`.
3. **Security credentials** tab → under Access keys, click **Actions** next to the key → **Deactivate** → then **Delete**.
4. Go back up to the user page → click **Delete user** (top right) → confirm.

### OIDC provider

The OIDC provider is account-wide. **Don't delete it** unless you're sure no other repo in your AWS account is using it.

### ECR images

ECR storage is a few cents per GB-month — usually fine to leave. If you want to clean up:

1. AWS Console → ECR → Repositories → `cosmos/nobled` → Images tab.
2. Check all images → **Delete** → confirm.
