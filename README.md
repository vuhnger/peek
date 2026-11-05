# Peek

![Peek](docs/screenshot.png)

GitHub Actions and GitLab pipeline status for your repos, in the menu bar.

Download the latest `.dmg` from [releases](https://github.com/vuhnger/peek/releases/latest) and drag it to Applications.
The first launch says Apple could not verify Peek is free of malware, because the app is not notarized. Click Done, open System Settings, go to Privacy & Security, click Open Anyway next to Peek and confirm.
Run `gh auth login` first. Peek uses your GitHub CLI login.
For GitLab, run `glab auth login`.

Time estimates include queue time and use the median of up to 30 comparable successful runs that outlast the current elapsed time, without a safety margin.
Peek matches observed jobs, separates GitHub retries, and stops predicting when the run outlasts its history; GitLab retries without a reliable attempt boundary show elapsed time only.

Replay before/after accuracy with `swiftc -parse-as-library Sources/PeekCore/{Models,RepoPath,ETA}.swift scripts/evaluate-eta.swift -o /tmp/evaluate-eta` and `/tmp/evaluate-eta dataset.json results.json`.
The dataset contains a `runs` array of GitHub workflow records with `repo`, `split` set to `warmup` or `holdout`, and attempt-specific `jobs` including their creation, start and completion timestamps.

GPL-3.0
