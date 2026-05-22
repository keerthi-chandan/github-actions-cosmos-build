# Procedure — github-actions-cosmos-build

Step-by-step walkthrough, mostly UI-driven (AWS Console + GitHub Settings) so you can see what each piece looks like. Only local git commands use the terminal.

Sections:

1. Prereqs
2. Create the GitHub repo
3. First push (terminal)
4. AWS — create the IAM OIDC provider
5. AWS — create the IAM role for GitHub Actions
6. GitHub — set the secret + variable
7. GitHub — configure the `production` environment
8. First full run + approve the production deploy
9. PR trigger test
10. `workflow_dispatch` + scheduled cron
11. Switch to the `legacy-keys` branch (static keys variant)
12. Gotchas
13. Teardown

---

## 1. Prereqs

Tools (you already have these from jenkins-cosmos-build):

- `git` (terminal)
- A web browser logged into your GitHub account `keerthi-chandan`
- A web browser logged into the AWS Console for account `720294271237` (the same account that hosts the `cosmos/nobled` ECR repo from jenkins-cosmos-build)

You do **not** need: `gh` CLI, `aws` CLI, anything else — the UI handles it all.

Local scaffold at `~/Desktop/devops/github-actions-cosmos-build/` is already in place.

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

Now we create a role that the GitHub Actions workflow can assume.

1. Still in IAM, click **Roles** in the left sidebar.
2. Click the **Create role** button (top right).
3. **Trusted entity type**: choose **Web identity**.
4. **Identity provider**: select `token.actions.githubusercontent.com` from the dropdown (it appears because we created it in step 4).
5. **Audience**: select `sts.amazonaws.com` from the dropdown.
6. **GitHub organization**: type `keerthi-chandan`.
7. **GitHub repository** (optional but recommended): type `github-actions-cosmos-build`.
8. **GitHub branch** (optional): type `main`. This locks the role to only the main branch — feature branches and forks can't assume it.
9. Click **Next** (bottom right).
10. **Permissions**: in the search box, type `AmazonEC2ContainerRegistryPowerUser` and check the checkbox next to it. This gives the role permission to push and pull from any ECR repo in your account.
11. Click **Next**.
12. **Role name**: `github-actions-nobled-ci`.
13. **Description** (optional): `OIDC role for github-actions-cosmos-build workflow`.
14. Scroll down and click **Create role**.
15. You'll land back on the Roles list. Click into the `github-actions-nobled-ci` role you just created.
16. At the top of the role's page, you'll see the **ARN** — it looks like `arn:aws:iam::720294271237:role/github-actions-nobled-ci`. Copy this ARN; you'll paste it into GitHub in the next step.

## 6. GitHub — set the secret + variable

The workflow needs to know which IAM role to assume. We pass the ARN through GitHub Secrets, and the AWS region through Variables.

1. Go to `https://github.com/keerthi-chandan/github-actions-cosmos-build`.
2. Click **Settings** (top right of the repo navigation).
3. In the left sidebar, click **Secrets and variables** → **Actions**.

### Add the secret

4. Click the green **New repository secret** button.
5. **Name**: `AWS_ROLE_ARN`.
6. **Secret**: paste the role ARN you copied from step 5.16 (e.g., `arn:aws:iam::720294271237:role/github-actions-nobled-ci`).
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
2. Click into it. You'll see the job DAG — `build` running first, then `test`/`lint`/`gosec`/`trivy_fs` fanning out in parallel, then `publish`.
3. When `publish` is reached, it pauses with an orange **"Waiting"** badge and a banner saying *"This workflow is awaiting deployment to production."*

### Approve the deploy

4. Click the **Review deployments** button in that banner.
5. Check the **production** checkbox.
6. (Optional) add a comment.
7. Click **Approve and deploy**.
8. The `publish` job starts. It'll take about 3-5 minutes (docker build of Noble is the slow part).

### Verify the image landed in ECR

1. Open the AWS Console → search **ECR** → click Elastic Container Registry.
2. Click **Repositories** in the left sidebar.
3. Click into the **cosmos/nobled** repository.
4. On the **Images** tab, you'll see a new image tagged with the git commit SHA and `latest`, with the push time matching your run.

## 9. PR trigger test

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

- `build`, `test` (with the "skip on non-main" message), `lint`, `gosec`, `trivy_fs` all run.
- `publish` is **skipped** (you'll see it greyed out with a "Skipped" badge) because the workflow's `if:` condition gates it to main + non-PR.

Close the PR without merging:

1. On the PR page, scroll to the bottom.
2. Click **Close pull request**.
3. Click **Delete branch** (the button appears after closing).

## 10. `workflow_dispatch` + scheduled cron

`workflow_dispatch` was tested in step 8 (Option B). The cron `0 2 * * *` fires nightly at 2 AM UTC — you don't need to do anything to test it, it'll just appear in the Actions tab tomorrow morning. If you want to confirm it's registered:

1. Actions tab → left sidebar → **nobled CI/CD**.
2. Above the run list, you'll see **"This workflow has a `workflow_dispatch` event trigger"** badge if the file is parsed correctly.
3. (There's no UI badge for cron, but if the workflow file parses, the cron is registered.)

## 11. Switch to the `legacy-keys` branch (static keys variant)

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

## 12. Gotchas

Things that have bitten people (or are likely to). Numbered like jenkins-cosmos-build's Gx series.

- **G1 — OIDC `sub` claim mismatch.** If you typed the GitHub org/repo/branch fields wrong in step 5, the workflow's OIDC token won't match what the role's trust policy expects, and AWS rejects it with "Not authorized to perform `sts:AssumeRoleWithWebIdentity`." Fix: in IAM → Roles → `github-actions-nobled-ci` → Trust relationships, verify the `sub` claim matches `repo:keerthi-chandan/github-actions-cosmos-build:ref:refs/heads/main`.

- **G2 — `id-token: write` is per-job, not workflow-wide.** The workflow-level `permissions: contents: read` is read-only. The `publish` job adds `id-token: write` specifically so it can request an OIDC token. If you ever copy this workflow to a new repo and forget that per-job permission block, AWS auth will fail with "Could not retrieve ID token."

- **G3 — Secrets aren't passed to fork PRs.** GitHub deliberately blocks fork PRs from accessing secrets. If anyone forks your repo and opens a PR, `secrets.AWS_ROLE_ARN` will be empty inside that run. Our workflow's `publish` job is already gated against PRs, so this isn't a problem — but be aware if you ever lift that gate.

- **G4 — Every parallel job re-clones Noble.** Hosted runners are isolated VMs with no shared filesystem, so `test`/`lint`/`gosec`/`trivy_fs` each clone Noble independently. Total clone cost ≈ 4× a single clone. For a small repo this is fine; for a large repo you'd consolidate into one job.

- **G5 — `environment: production` blocks indefinitely.** If you set required reviewers and forget to approve, the run sits in "Waiting for review" forever (well, up to 30 days, then GitHub auto-cancels). If you're going on vacation, either disable the cron or remove yourself as the sole reviewer and add a co-reviewer.

- **G6 — Cold cache on first build.** The very first `build` job runs with empty Go module + build caches, so it has to download all of Noble's transitive Go dependencies. That can take 5-8 minutes. The second build (with warm cache) is much faster, often 2-3 minutes. Don't panic on the first run's slow build.

## 13. Teardown

If you want to fully clean up the AWS side of this lab (the GitHub repo itself costs nothing while idle — keep it for the portfolio).

### Delete the IAM role (UI)

1. AWS Console → IAM → Roles.
2. Search for `github-actions-nobled-ci` and check the checkbox.
3. Click **Delete** (top right) → type the role name to confirm → **Delete**.

### Delete the legacy IAM user (UI, only if you did step 11)

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
