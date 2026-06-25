<!--
  Thanks for contributing to gke-labs! 🎉
  Please fill in the sections below before requesting a review.
  Delete any sections that are not relevant to your change.
-->

## Summary

<!-- One or two sentences describing WHAT this PR changes and WHY. -->

## Lab Exercise Reference

<!--
  If this PR is part of a specific lab exercise, link it here so reviewers
  have context about the intended learning goal.
-->

- **Lab:** <!-- e.g. Lab 03 — Autoscaling -->
- **Issue / Ticket:** <!-- e.g. #42 or N/A -->
- **Docs / Reference:** <!-- any external doc, ADR, or design note -->

---

## Type of Change

<!-- Put an `x` in the boxes that apply. -->

- [ ] 🏗️  Infrastructure (Terraform — adds/modifies/removes cloud resources)
- [ ] ⚙️  Helm chart change (values, templates, chart version bump)
- [ ] 🐳  Docker image change (Dockerfile, build args)
- [ ] 🔄  CI/CD pipeline change (workflow files)
- [ ] 📖  Documentation only
- [ ] 🐛  Bug fix
- [ ] ✨  New feature / lab exercise
- [ ] 🔒  Security improvement
- [ ] 🧹  Refactor / housekeeping (no functional change)

---

## Pre-flight Checklist

<!--
  Complete ALL items before marking this PR as Ready for Review.
  These mirror the CI checks so you can catch issues locally first.
-->

### Terraform (if applicable)

- [ ] `terraform fmt -recursive` has been run and no files were changed
- [ ] `terraform validate` passes for every touched environment
      ```
      cd terraform/environments/<env> && terraform init -backend=false && terraform validate
      ```
- [ ] `terraform plan` output has been reviewed — no unexpected resource deletions
- [ ] State file changes are intentional (if any)
- [ ] Variables and outputs are documented with `description` fields

### Helm (if applicable)

- [ ] `helm lint --strict helm/<chart-name>` passes with zero warnings
- [ ] `helm template` output has been reviewed for correctness
- [ ] Values files follow the naming convention (`values.yaml`, `values-dev.yaml`, `values-staging.yaml`)
- [ ] Resource requests and limits are set on all containers
- [ ] Chart `version` in `Chart.yaml` has been bumped (semantic versioning)

### Docker (if applicable)

- [ ] Image builds successfully locally (`docker build -t test docker/<image>/`)
- [ ] No secrets, credentials, or `.env` files are baked into the image
- [ ] Base image is pinned to a specific digest or version tag (not `latest`)
- [ ] `.dockerignore` is up to date

### CI/CD (if applicable)

- [ ] Workflow syntax is valid (use `actionlint` or paste into GitHub's editor)
- [ ] No plaintext secrets are embedded in workflow files — all secrets use `${{ secrets.* }}`
- [ ] Permissions are scoped to the minimum required (`permissions:` block)

### General

- [ ] Branch is up to date with `main` (rebased or merged)
- [ ] Commit messages follow conventional commits format (`feat:`, `fix:`, `chore:`, etc.)
- [ ] CODEOWNERS-required reviewers have been added automatically (check the "Reviewers" panel)

---

## Changes Description

<!--
  Provide a more detailed description of the changes.
  Use bullet points, code snippets, or diagrams as needed.
-->

### What changed?

-

### Why was this change needed?

-

### How was this tested?

<!--
  Describe how you verified the change works correctly.
  Include commands run, output observed, and any manual test steps.
-->

-

---

## Terraform Plan Summary (if applicable)

<!--
  Paste a summary of the `terraform plan` output here so reviewers
  can quickly see what will be created/updated/destroyed.
  The CI job also posts the full plan as a comment automatically.
-->

<details>
<summary>Click to expand plan summary</summary>

```
# Paste plan output here, or leave blank — CI will post the full plan.
```

</details>

---

## Screenshots / Diagrams (if applicable)

<!-- Drag & drop screenshots or architecture diagrams here. -->

---

## Post-Merge Steps

<!--
  List any manual steps that need to happen AFTER this PR is merged.
  Examples: update a secret, run a one-time migration, notify a stakeholder.
-->

- [ ] <!-- e.g. Update GCP_WORKLOAD_IDENTITY_PROVIDER secret with new provider URL -->
- [ ] <!-- e.g. Trigger staging deployment via CD — Staging workflow_dispatch -->
- [ ] N/A

---

## Reviewer Notes

<!--
  Anything specific you'd like reviewers to focus on?
  Areas of uncertainty, trade-offs made, or areas that need extra scrutiny?
-->

>
