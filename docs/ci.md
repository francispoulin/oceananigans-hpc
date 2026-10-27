# Automatic GPU tests with Buildkite (pelee and rondeau)

The checks in `tests/ci/` run on GitHub for every pull request, but they have no GPUs. The platform
tests (`tools/run_tests.sh`: 21 steps on 1 and 4 GPUs, about 15 minutes) need a GPU server. This
page sets up [Buildkite](https://buildkite.com), as Oceananigans does, so that they run by
themselves on pelee or rondeau for every pull request and every push to `main`, with the result as a
check on the pull request and the summary on the build page.

How it works: a small program from Buildkite, the **agent**, runs on the server under one account.
It connects out to Buildkite (HTTPS, no open port), waits for work, and runs the steps of
[`.buildkite/pipeline.yml`](../.buildkite/pipeline.yml). The one step,
[`tools/ci_platform_tests.sh`](../tools/ci_platform_tests.sh), runs the machine's own
`tools/test_branch.sh` on the commit being built: the same worktree, free-GPU check and summary as a
test started by hand. If the GPUs or the test worktree are busy it waits (up to 2 hours) instead of
skipping steps, and the build passes only if the summary is clean.

## What it can and cannot do

- **Only branches of this repository are tested.** Builds of pull requests from forks are switched
  off in the pipeline settings (below), and the script fetches the commit from this repository, so a
  fork's commit is not even found. Only people who can push here can start a test.
- **It uses free GPUs only**, one test at a time on both servers (they share one clone).
- **It runs as the agent's account**, with that account's files and keys. Use an account that holds
  nothing else (e.g. `ocean-ci`); a personal account is fine for a first trial.
- **It fetches over HTTPS** (the repository is public): no SSH key is needed to test. Publishing a
  summary as a `results/...` branch (`OCEAN_CI_PUBLISH=1`) needs a key that can push.
- **Free plan:** Buildkite's free plan allows up to 5 users and 10 jobs at a time on your own
  machines, far more than two servers need.

## Setting it up (once)

### 1. In Buildkite (web)

1. Create an organization at [buildkite.com](https://buildkite.com) (free plan; sign in with GitHub).
2. *Settings → Repository Providers → GitHub (Limited Access)* (enough for agents on your own
   machines) → connect the GitHub account that owns this repository, and give it this repository.
3. *Agents* → your cluster (a new organization has one, with a `default` queue) → *Queues*: add a
   queue with key `fluidsgpu`. Then, in the same cluster, *Agent Tokens*: a new token, described
   `pelee-rondeau`. **Copy the token now**; it is shown
   once. It is the agent's password: keep it out of any repository and out of chat.
4. *Pipelines → New pipeline*:
   - Repository: `https://github.com/<owner>/oceananigans-hpc.git` (HTTPS: public, no key needed);
   - Cluster: the one with the `fluidsgpu` queue;
   - Steps (the only steps kept in Buildkite; the rest is in this repository):
     ```yaml
     steps:
       - label: ":pipeline: Upload"
         command: buildkite-agent pipeline upload
         agents:
           queue: fluidsgpu
     ```
   - If Buildkite shows a webhook URL to add in GitHub, add it as it says.
5. The pipeline's *Settings → GitHub* (names as Buildkite shows them; they change now and then):
   - **Build when pull request is opened or updated**: on;
   - **Allow builds from third-party forked repositories**: **off** (check this one);
   - **Filter builds using a conditional**: on, with
     `build.branch == pipeline.default_branch || build.pull_request.id != null`, so only `main` and
     pull requests are built: a push to a branch without a pull request creates no build (and so no
     quick green check for a later pull request to inherit). *New Build* is not filtered;
   - **Skip builds with existing commits** and **Skip when pull request has existing build for
     commit and branch**: off (a pull request is always tested);
   - commit statuses: on (this puts the check on the pull request).
   - *Settings → Builds*: **Skip intermediate builds** on (only the newest commit of a branch is built;
     otherwise every push queues its own ~17-minute build holding all four GPUs).
6. Optional: making the pipeline public lets anyone read the build pages without a Buildkite login
   (as Oceananigans' are). Logs show paths on the server; nothing else.

### 2. On the server (pelee, then rondeau)

As the account the agent runs under. The account needs a working clone of this repository on that
server, set up as usual (`setup/install_julia.sh`, `setup/setup.sh`, `tools/run_tests.sh` passing once
by hand), with `tools/test_branch.sh` on its `main`.

```bash
# Install the agent in ~/.buildkite-agent (no root needed). Paste the token where it says.
TOKEN="<agent token>" bash -c "$(curl -sL https://raw.githubusercontent.com/buildkite/agent/main/install.sh)"
```

Then edit `~/.buildkite-agent/buildkite-agent.cfg` (the token is already in it):

```ini
name="%hostname-%spawn"
# machine=rondeau on rondeau
tags="queue=fluidsgpu,machine=pelee"
# Builds off the home folder (only this script and the pipeline file are checked out there)
build-path="/mnt/autofs/bow.math/scratch/<user>/buildkite/builds"
```

Tell the tests where the machine's clone is, in `~/.buildkite-agent/hooks/environment`:

```bash
#!/bin/bash
export OCEAN_HPC_CLONE=/mnt/autofs/bow.math/scratch/<user>/software/oceananigans-hpc
```

Start it:

```bash
chmod 600 ~/.buildkite-agent/buildkite-agent.cfg && chmod +x ~/.buildkite-agent/hooks/environment
tmux new -d -s buildkite '~/.buildkite-agent/bin/buildkite-agent start'
```

Check: the agent appears under *Agents* in Buildkite with `queue=fluidsgpu`; `tmux attach -t buildkite`
shows its log (Ctrl-b d to leave it running). Started this way it stops when the server reboots; for
good, the agent runs as a system service (root, i.e. the server's administrators), or from the
account's `crontab` with `@reboot`.

### 3. First build

In Buildkite, *New Build* on a branch (e.g. the branch that added this page). The *Upload* step
runs, then *Platform tests*: about 15 minutes on free GPUs. The summary appears at the top of the
build page; on a pull request, the check appears next to GitHub's own.

## Day to day

- **Nothing to type.** Push a branch with a pull request (or push to `main`): the build starts.
- **Failed, busy, or stopped by a reboot:** fix, then *Retry* the step in Buildkite (or push again).
- **A release:** *New Build* on the release branch with environment `OCEAN_CI_PUBLISH=1` publishes the
  clean summary as a `results/<machine>_<date>` branch, as `tools/test_branch.sh` does by hand.
- **Fewer GPUs:** `OCEAN_CI_GPUS="1 2"` on a build.
- **Stopping the agent:** `tmux kill-session -t buildkite` (or *Stop* on the agent's page in Buildkite).
  Revoking the agent token in Buildkite cuts off every agent that uses it.

Tests started by hand (`tools/test_branch.sh`) still work; while one runs, the agent waits for it.
