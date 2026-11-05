# inQuran-VPS Rules

## Deployment Mechanics
1. **Target Branch:** The deployment scripts (`release.sh`, `deploy_app.sh`, etc.) clone the `inQuran-Astro` repository directly from the remote `main` branch (NOT `dev`).
2. **Execution:** Before triggering any release scripts here, ensure that the application code you intend to deploy has been successfully merged into `main` and pushed to `origin/main` in the `inQuran-Astro` repository. Pushing to `dev` is insufficient for deployment.

## Mandatory Scheduled Review, Documentation & Roadmap Protocol
1. **Developer Documentation Synchronization:**
   - Always update `PROMPT_SUGGESTIONS.md` with detailed findings, root-cause analyses, latency benchmarks, and remediations for each iteration.
   - Ensure corresponding developer notes are logged in `inQuran-Astro/CHANGELOG.md`.
2. **Public-Facing Milestone Evaluation:**
   - When fixes, cluster adjustments, or architectural enhancements are deployed, determine whether they are noteworthy for public users. If so, update the changelog in `inQuran-Astro/src/pages/about.astro`.
3. **Weekly Feature Research & Roadmap Progress Tracking:**
   - Regularly track roadmap milestones and record research for upcoming features in `inQuran-Astro/ROADMAP.md`.
4. **Periodic Library Updates:**
   - Periodically inspect dependencies with `npm outdated`, update safe packages, and verify zero downtime via staging smoke tests.
