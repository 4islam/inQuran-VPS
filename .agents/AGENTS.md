# inQuran-VPS Rules

## Deployment Mechanics
1. **Target Branch:** The deployment scripts (`release.sh`, `deploy_app.sh`, etc.) clone the `inQuran-Astro` repository directly from the remote `main` branch (NOT `dev`).
2. **Execution:** Before triggering any release scripts here, ensure that the application code you intend to deploy has been successfully merged into `main` and pushed to `origin/main` in the `inQuran-Astro` repository. Pushing to `dev` is insufficient for deployment.
