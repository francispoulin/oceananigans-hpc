# Automatic GPU tests with Buildkite (pelee and rondeau)

The checks in `tests/ci/` run on GitHub for every pull request, but they have no GPUs. The platform
tests (`tools/run_tests.sh`; in CI on 1 and 2 GPUs, about 15 minutes) need a GPU server. This
page sets up [Buildkite](https://buildkite.com), as Oceananigans does, so that they run by
themselves on pelee or rondeau for every pull request and every push to `main`, with the result as a
check on the pull request and the summary on the build page.

How it works: a small program from Buildkite, the **agent**, runs on the server under one account.
It connects out to Buildkite (HTTPS, no open port), waits for work, and runs the steps of
[`.buildkite/pipeline.yml`](../.buildkite/pipeline.yml). The one step,
[`tools/ci_platform_tests.sh`](../tools/ci_platform_tests.sh), runs the machine's own
`tools/test_branch.sh` on the commit being built: the same worktree, free-GPU check and summary as a
test started by hand. It needs only 2 free GPUs (the tests on 1 and 2 GPUs). If they or the test
worktree are busy, it waits 10 minutes, then hands the job back to the queue so the other machine can
take it (up to 10 times, about 2 hours in all), instead of skipping steps; the build passes only if
the summary is clean.

## What it can and cannot do

- **Only branches of this repository are tested.** Builds of pull requests from forks are switched
  off in the pipeline settings (below), and the script fetches the commit from this repository, so a
  fork's commit is not even found. Only people who can push here can start a test.
- **It uses free GPUs only**, one test at a time on both servers (they share one clone).
- **It runs as the agent's account**, with that account's files and keys: a dedicated account that
  holds nothing else and that nobody logs in to (`ocean-ci` on pelee, run as a service by the
  administrators). A personal account is fine for a first trial.
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
   after where it runs (e.g. `pelee-ocean-ci`). **Copy the token now**; it is shown
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

The agent runs as a dedicated account (`ocean-ci` on pelee) that nobody logs in to, not even with
a key: the server's administrators run it as a system service, and the build pages on Buildkite are
how you see what it does. (A service account with a login is a security concern for them.) What
the administrators set up, once:

1. Room for the account's files: our Julia, the depot and its own clone of this repository (as
   much as your own setup uses). They go in `/mnt/autofs/bow.math/scratch/ocean-ci` if that folder
   exists, else in the account's home folder (on pelee: `/u/ocean-ci`), the same rule
   `env/fluidsgpu.sh` uses for the depot.
2. The agent, from Buildkite's package, as a `systemd` service running as the account, e.g.
   `/etc/systemd/system/buildkite-agent.service`:
   ```ini
   [Service]
   User=ocean-ci
   Group=ocean-ci
   Environment=HOME=/var/lib/buildkite-agent
   ExecStart=/usr/bin/buildkite-agent start
   Restart=on-failure
   RestartSec=5
   ```
   (they may add limits such as `Nice=10`, `CPUQuota=` or `MemoryMax=`).
3. Its configuration, `/etc/buildkite-agent/buildkite-agent.cfg` (readable by the account only):
   ```ini
   token="<agent token>"
   # %hostname: pelee-ocean-ci, rondeau-ocean-ci. Distinct names matter: the build folder is named
   # after the agent, and /u is shared by both machines.
   name="%hostname-ocean-ci"
   # tags="queue=fluidsgpu,machine=rondeau" on rondeau
   tags="queue=fluidsgpu,machine=pelee"
   build-path="/u/ocean-ci/builds"
   ```
   The `tags` line is required: without a queue, Buildkite refuses the agent ("Queue is required
   when registering agents to a cluster"). No hook is needed; an `environment` hook setting
   `OCEAN_HPC_CLONE` overrides where the clone goes.
4. A check that the account sees other users' GPU processes in
   `nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv`: the free-GPU check relies on it.

Give them the agent token in person or in a file only you can read (`umask 077`), not by email.

**Nothing else is set up by hand.** The first build finds no clone, so
[`tools/ci_platform_tests.sh`](../tools/ci_platform_tests.sh) clones this repository over HTTPS and
runs `setup/install_julia.sh`, `setup/setup.sh` and `setup/setup_viz.sh` in it (about 30 minutes,
once; a failed setup is redone by the next build). After that the clone is never updated by hand:
`tools/test_branch.sh` installs each tested commit's Julia and packages. The account needs no
GitHub key (the repository is public and nothing is pushed), provided the pipeline's
*Repository* setting is the HTTPS address: with the SSH one (`git@github.com:…`, which Buildkite's
GitHub integration may fill in) the agent's own checkout fails with "Permission denied (publickey)".

A job goes to whichever agent is free; the tests themselves run one at a time across both machines
(the pipelines' shared `concurrency_group`), each waiting on its machine until the GPUs it needs are
free. A private repository's pipeline also needs a read-only GitHub deploy key for the account
(generated as the account, so the private key stays on the machine) and its SSH address.

Only one agent per server: stop any trial agent under a personal account first
(`tmux kill-session -t buildkite`), and revoke its token once the new agent's first build is green.

### 3. First build

In Buildkite, *New Build* on `main`. The *Upload* step runs, then *Platform tests*: on a new agent
account first the setup (about 30 minutes), then about 15 minutes of tests on free GPUs. The summary appears at the top of the
build page; on a pull request, the check appears next to GitHub's own.

## Day to day

- **Nothing to type.** Push a branch with a pull request (or push to `main`): the build starts.
- **Failed, busy, or stopped by a reboot:** fix, then *Retry* the step in Buildkite (or push again).
- **A release:** *New Build* on the release branch with environment `OCEAN_CI_PUBLISH=1` publishes the
  clean summary as a `results/<machine>_<date>` branch, as `tools/test_branch.sh` does by hand.
- **4 GPUs:** `OCEAN_CI_GPUS="1 4"` on a build (run_tests.sh's own default; needs a machine with all four free).
- **Stopping the agent:** the administrators' `systemctl stop buildkite-agent` (a trial agent:
  `tmux kill-session -t buildkite`), or *Stop* on the agent's page in Buildkite.
  Revoking the agent token in Buildkite cuts off every agent that uses it.

Tests started by hand (`tools/test_branch.sh`) still work; while one runs, the agent waits for it.
