# Git Commit Guide

## Conventional Commits

Perform conventional commits for all uncommitted changes. Do not create a single monolithic commit. Instead, split changes into multiple commits based on logical separation such as features, bug fixes, refactors, or chores.

Each commit must:

* Follow the Conventional Commits specification (`feat:`, `fix:`, `refactor:`, `chore:`, etc.)
* Contain only related changes that belong to a single purpose or feature
* Have a clear, descriptive commit message
* Avoid mixing unrelated changes in the same commit

## Breaking Changes handling

* Identify any changes that introduce **incompatible API or behavioral changes**
* Any breaking change must be explicitly marked using:

  * `!` in the commit type (e.g. `feat!:` or `fix!:`), **and/or**
  * a `BREAKING CHANGE:` footer in the commit message
* Clearly describe:

  * what changed
  * what breaks
  * how users should migrate or update their usage
* Breaking changes should never be hidden inside normal commits—they must be isolated and clearly visible

## Goal

Produce a clean, structured git history where commits are logically grouped, easy to review, and explicitly highlight any breaking changes for safe downstream usage.
