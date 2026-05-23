import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

type DeployEnvironment = "development" | "production";
type WorkerTarget = "toc" | "tob";

interface WorkerConfig {
  readonly target: WorkerTarget;
  readonly packageName: string;
  readonly directory: string;
}

const scriptDir = dirname(resolve(process.argv[1] ?? "tools/cloudflare/deploy-workers.ts"));
const repoRoot = resolve(scriptDir, "../..");

const workers: readonly WorkerConfig[] = [
  {
    target: "toc",
    packageName: "@sift/worker-toc",
    directory: join(repoRoot, "apps/worker-toc")
  },
  {
    target: "tob",
    packageName: "@sift/worker-tob",
    directory: join(repoRoot, "apps/worker-tob")
  }
];

function optionValue(name: string): string | null {
  const prefix = `${name}=`;
  const inline = process.argv.slice(2).find((arg) => arg.startsWith(prefix));
  if (inline) {
    return inline.slice(prefix.length);
  }

  const index = process.argv.indexOf(name);
  if (index === -1) {
    return null;
  }
  const value = process.argv[index + 1];
  return value && !value.startsWith("--") ? value : null;
}

function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

function usage(): string {
  return `Usage: tsx tools/cloudflare/deploy-workers.ts [--env production|development] [--worker all|toc|tob] [--dry-run] [--skip-checks] [--skip-whoami]

Deploys Sift Workers through Wrangler with the selected environment.

Root shortcuts:
  pnpm deploy:workers
  pnpm deploy:workers:dry-run
  pnpm deploy:worker:toc
  pnpm deploy:worker:tob

Defaults:
  --env production
  --worker all

Preflight:
  - validates ignored wrangler.toml files exist and contain no template placeholders
  - refuses MASTER_KEY in wrangler.toml; use Wrangler secrets instead
  - runs each selected Worker's build and test scripts unless --skip-checks is set
  - runs wrangler whoami before real deploys unless --skip-whoami is set
`;
}

function parseEnvironment(): DeployEnvironment {
  const value = optionValue("--env") ?? "production";
  if (value === "development" || value === "production") {
    return value;
  }
  throw new Error(`Unsupported --env "${value}". Expected development or production.`);
}

function parseTargets(): readonly WorkerConfig[] {
  const value = optionValue("--worker") ?? "all";
  if (value === "all") {
    return workers;
  }
  if (value === "toc" || value === "tob") {
    return workers.filter((worker) => worker.target === value);
  }
  throw new Error(`Unsupported --worker "${value}". Expected toc, tob, or all.`);
}

function validateWranglerConfig(worker: WorkerConfig): void {
  const configPath = join(worker.directory, "wrangler.toml");
  if (!existsSync(configPath)) {
    throw new Error(
      `${worker.packageName} is missing wrangler.toml. Copy wrangler.template.toml to wrangler.toml and fill in real Cloudflare resource IDs.`
    );
  }

  const contents = readFileSync(configPath, "utf8");
  if (contents.includes("replace-with-")) {
    throw new Error(`${worker.packageName} wrangler.toml still contains template placeholders.`);
  }
  if (/^\s*MASTER_KEY\s*=/m.test(contents)) {
    throw new Error(`${worker.packageName} wrangler.toml must not contain MASTER_KEY. Use wrangler secret put instead.`);
  }
}

function run(command: string, args: readonly string[], cwd: string): void {
  const result = spawnSync(command, args, {
    cwd,
    stdio: "inherit",
    shell: false
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} exited with status ${result.status ?? "unknown"}`);
  }
}

function runChecks(worker: WorkerConfig): void {
  console.log(`\nChecking ${worker.packageName}...`);
  run("pnpm", ["run", "build"], worker.directory);
  run("pnpm", ["run", "test"], worker.directory);
}

function main(): void {
  if (hasFlag("--help") || hasFlag("-h")) {
    console.log(usage());
    return;
  }

  const environment = parseEnvironment();
  const targets = parseTargets();
  const dryRun = hasFlag("--dry-run");
  const skipChecks = hasFlag("--skip-checks");
  const skipWhoami = hasFlag("--skip-whoami");

  for (const worker of targets) {
    validateWranglerConfig(worker);
  }

  if (skipChecks) {
    console.log("\nSkipping Worker build/test preflight.");
  } else {
    for (const worker of targets) {
      runChecks(worker);
    }
  }

  if (!dryRun && !skipWhoami) {
    run("pnpm", ["exec", "wrangler", "whoami"], targets[0]?.directory ?? repoRoot);
  }

  for (const worker of targets) {
    const args = ["exec", "wrangler", "deploy", "--env", environment];
    if (dryRun) {
      args.push("--dry-run");
    }

    console.log(`\nDeploying ${worker.packageName} with Wrangler env "${environment}"...`);
    run("pnpm", args, worker.directory);
  }
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`\nWorker deploy failed: ${message}`);
  process.exit(1);
}
