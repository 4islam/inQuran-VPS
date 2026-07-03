# Zero-Downtime Deployment Guide

The deployment process for the inQuran Astro application has been fully automated to support **Zero-Downtime Deployments**. The entire pipeline is orchestrated through two main scripts: `release.sh` (which runs on your local machine) and `deploy_app.sh` (which runs on the servers).

## Quick Start — Interactive Wizard (Recommended)

The easiest way to deploy is to use the interactive wizard. It asks you all the necessary questions and builds the correct command for you:

```bash
./deploy/wizard.sh
```

The wizard will ask:
1. **Environment** — Deploy to Staging only, or the full Staging → Production pipeline.
2. **Database re-seed** — Whether to wipe and re-import the Supabase database.
3. **Skip DNS** — Whether to hold off on the Cloudflare DNS switch (useful when testing a new server before cutting traffic over).

It then shows a summary of the command it will run and waits for your confirmation before doing anything.

> **Tip:** The wizard is just a friendly wrapper around `release.sh`. Power users can call `release.sh` directly (see below).

---

## The Staging & Production Workflow

To ensure a stable application, the deployment flow requires you to first deploy to your Staging environment. Once you have verified the staging environment works flawlessly, you can deploy to Production.

### 1. Deploying to Staging

When you merge new code into your GitHub repository's main branch, deploy it to the staging server first:

```bash
./deploy/release.sh staging
```

This command will:
- Connect to the staging server and clone the latest code into an isolated folder.
- Install dependencies and compile the Astro project.
- Symlink shared databases (`lanes.sqlite`) and environment variables (`.env`).
- Perform an atomic switch and restart PM2 without dropping any requests.
- Verify that the staging site is healthy.

### 2. Verifying Staging

Visit your staging URL to verify that everything looks and performs correctly. Make sure API requests and database queries resolve as expected.

### 3. Deploying to Production

Once you are fully satisfied with the staging deployment, roll out the exact same changes to your live production server:

```bash
./deploy/release.sh production
```

This will run the same zero-downtime pipeline on the production VPS, ensuring that your users never experience an outage while the server updates.

## Seeding & Database Migrations

If your update requires a fresh wipe and re-import of the Supabase database (for example, if the schema changed or you have new data scripts):

```bash
# Deploys code AND rebuilds the database on Staging
./deploy/release.sh staging --full-reseed

# Once verified on Staging, perform the same on Production
./deploy/release.sh production --full-reseed
```

> **Warning:** Reseeding takes around 5-10 minutes and wipes the database. The frontend site will remain online during this time, but API queries for verses might fail or return partial results until the seeding completes.

## Under The Hood (Zero-Downtime Architecture)

When a new version is rolled out, the following sequence happens behind the scenes:

1. **Isolation**: The script downloads the latest code from GitHub into a brand new, timestamped folder (e.g., `releases/20260703_102300`).
2. **Offline Build**: It installs NPM dependencies and compiles the project in this isolated directory. The active live site is **completely untouched** during this phase.
3. **Linking Assets**: Shared state assets that shouldn't be overwritten—like `.env` and `lanes.sqlite`—are symlinked automatically from a shared `deployments/inquran/` root folder.
4. **Atomic Switch**: Once the new build is 100% ready, the script updates a single symbolic link (`inquran-app`) to instantly point from the old release folder to the new one.
5. **Graceful Reload**: PM2 is instructed to reload the Node.js server. PM2 keeps the old process alive to handle any pending HTTP requests while spinning up the new process, ensuring **zero dropped requests**.
6. **Cleanup**: Finally, it automatically deletes older releases, keeping only the 3 most recent ones to save disk space.

## Rolling Back

Because the system automatically keeps the last 3 release folders, rolling back to a previous version is straightforward if an error slips into production:

1. SSH into the server:
   ```bash
   ssh nislam@142.132.160.191
   ```
2. Point the symlink back to an older folder and restart PM2:
   ```bash
   ln -sfn ~/deployments/inquran/releases/<old-timestamp> ~/inquran-app
   pm2 reload inquran-astro
   ```
