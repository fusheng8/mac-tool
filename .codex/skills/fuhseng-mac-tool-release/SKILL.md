---
name: fuhseng-mac-tool-release
description: Use in /Users/fusheng/develop/code/other/fuhseng-mac-tool when the user asks to submit, push, merge, tag, publish a new version, trigger the DMG workflow, or fix GitHub CLI auth for this repo. This is a project-local skill only.
---

# fuhseng-mac-tool Release Skill

This skill is intentionally project-local. Do not copy or install it under
`~/.codex/skills`.

## Release Model

- `main` is protected. Do not force-push or expect direct pushes to `main` to
  work. Changes must go through a PR with required checks.
- `.github/workflows/ci.yml` runs `Swift Build`.
- `.github/workflows/build-dmg.yml` runs on PRs, pushes to `main`, manual
  dispatch, and tags matching `[0-9]*.[0-9]*.[0-9]*`.
- A version tag such as `0.1.16` is the release trigger. Tag pushes build the
  DMG, upload `MacTool.dmg` to GitHub Release, generate Sparkle appcast, and
  deploy the appcast to GitHub Pages.
- Existing release tags are lightweight tags. Keep using lightweight tags unless
  the user asks for annotated tags.

## Before Publishing

1. Confirm the worktree and scope.
   - Run `git status -sb`.
   - Inspect `git diff --stat`, `git diff --name-status`, and relevant diffs.
   - Do not stage unrelated files silently.
2. Confirm GitHub auth and remote.
   - Run `gh auth status -h github.com`.
   - Expected: logged in as `fusheng8`, credential storage is keyring, Git
     operations protocol is `ssh`.
   - Expected remote: `git@github.com:fusheng8/mac-tool.git`.
3. Sync tags and remote state.
   - Run `git fetch origin --tags --prune`.
   - Determine the next patch tag from `git tag --sort=-v:refname`.
4. Run tests before opening or merging a release PR.
   - Use:
     `env CLANG_MODULE_CACHE_PATH=.build/module-cache swift test`
   - If SwiftPM fails inside Codex with `sandbox-exec: sandbox_apply:
     Operation not permitted`, rerun the same command with sandbox escalation.

## PR Flow

Use this flow for normal publishing:

1. If starting from `main`, create a branch named `codex/<short-description>`.
2. Stage only intended files.
3. Commit with a terse imperative message.
4. Push the branch:
   `git push -u origin <branch>`
5. Create a ready PR, not a draft, when the user explicitly asked to publish:
   `gh pr create --base main --head <branch> --title "<title>" --body "<body>"`
6. Wait for checks:
   `gh pr checks <number> --watch`
7. Merge only after required checks pass. Prefer squash merge:
   `gh pr merge <number> --squash --delete-branch --subject "<title>" --body ""`

If a direct push to `main` was attempted first and GitHub rejects it with
branch protection, do not retry or bypass protection. Create a PR branch from the
current commit and continue with the PR flow.

## Tag And Release

After the PR is merged:

1. Confirm the merge commit:
   `gh pr view <number> --json state,mergedAt,mergeCommit,url,headRefName,baseRefName`
2. Fetch remote state:
   `git fetch origin --tags --prune`
3. Create the next patch tag on `origin/main`, not on a stale local commit:
   `git tag <next-version> origin/main`
4. Push the tag:
   `git push origin <next-version>`
5. Find the tag workflow:
   `gh run list --workflow build-dmg.yml --limit 10 --json databaseId,headBranch,headSha,status,conclusion,event,displayTitle,createdAt,url`
6. Watch the tag run to completion:
   `gh run watch <run-id> --exit-status`
7. Verify release and asset:
   `gh release view <next-version> --json tagName,name,url,publishedAt,assets`

The release is complete only when the tag run succeeds and the release contains
`MacTool.dmg`.

## Local Cleanup

After a squash merge, local `main` may show `ahead 1, behind 1` if the local
commit was pushed through a PR as a different squash commit. In that case:

1. Confirm `origin/main` contains the merged change.
2. Run `git rebase origin/main`.
3. It is acceptable if Git says it skipped the previously applied local commit.
4. Confirm `git status -sb` shows `## main...origin/main`.

## GitHub CLI Auth Notes

For this repo, prefer one-time web login stored in macOS keyring plus SSH for
Git operations:

- `gh auth login -h github.com -p ssh -w --skip-ssh-key`
- `gh auth refresh -h github.com -s admin:public_key` only if adding an SSH key
  requires the extra scope.
- If the user asks to use the repo owner's local SSH key directory, use
  `/Users/fusheng/Desktop/个人/ssh密钥/id_rsa.pub` for public-key upload and
  `/Users/fusheng/Desktop/个人/ssh密钥/id_rsa` for SSH. Never print or read private
  key contents.
- To bind this repo to that key:
  `git config core.sshCommand "ssh -i /Users/fusheng/Desktop/个人/ssh密钥/id_rsa -o IdentitiesOnly=yes"`

## Known Non-Blocking Warning

GitHub Actions may warn that Node.js 20 actions are deprecated for
`actions/checkout@v4`, `actions/upload-artifact@v4`, and `actions/deploy-pages@v4`.
Treat this as non-blocking for a release unless the job fails. Mention it as a
follow-up maintenance item.
