// guard-gh-write.js — Block gh CLI write operations to non-owned repos
//
// PreToolUse hook for Bash. Detects gh write commands, resolves the
// target repo, and blocks if you don't own it.
//
// Uses bash-parser for AST-based loop detection (no more regex false positives).
// Falls back to regex if bash-parser chokes on exotic syntax.
//
// Config (env vars):
//   GIT_GUARDRAILS_ALLOWED_OWNERS  space-separated GitHub orgs/users
//   GIT_GUARDRAILS_ALLOWED_REPOS   space-separated owner/repo overrides

"use strict";

const { execFileSync } = require("node:child_process");
const parse = require("bash-parser");

// --- I/O ---

/** Read all of stdin as a string. */
function readStdin() {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { data += chunk; });
    process.stdin.on("end", () => resolve(data));
  });
}

/** Extract .tool_input.command from Claude Code's hook JSON. */
function parseInput(raw) {
  try {
    const obj = JSON.parse(raw);
    return obj?.tool_input?.command ?? "";
  } catch {
    return "";
  }
}

/** Write a block message to stderr and exit 2. */
function block(message, details) {
  process.stderr.write(`\u{1F6AB} git-guardrails: ${message}\n`);
  if (details) {
    const lines = Array.isArray(details) ? details : [details];
    for (const line of lines) {
      process.stderr.write(line === "" ? "\n" : `   ${line}\n`);
    }
  }
  process.exit(2);
}

// --- AST helpers ---

/** Walk an AST tree, returning true if any node satisfies the predicate. */
function walkAST(node, predicate) {
  if (!node || typeof node !== "object") return false;
  if (predicate(node)) return true;

  for (const key of Object.keys(node)) {
    const value = node[key];
    if (Array.isArray(value)) {
      for (const child of value) {
        if (walkAST(child, predicate)) return true;
      }
    } else if (value && typeof value === "object" && value.type) {
      if (walkAST(value, predicate)) return true;
    }
  }
  return false;
}

const LOOP_TYPES = new Set(["For", "While", "Until"]);

function isGhCommandNode(node) {
  return node.type === "Command" && node.name?.text === "gh";
}

// --- Loop detection ---

/** Regex fallback for when bash-parser throws. Matches the original bash behavior. */
function detectLoopWithGhRegex(command) {
  const stripped = command.replace(/"[^"]*"/g, "").replace(/'[^']*'/g, "");
  const hasLoop = /\bfor\s+\w+\s+in\b|\bwhile\b.*;\s*do\b/.test(stripped);
  return hasLoop && /\bgh\b/.test(command);
}

/** AST-based loop detection with regex fallback. */
function detectLoopWithGh(command) {
  try {
    const ast = parse(command);
    return walkAST(ast, (node) =>
      LOOP_TYPES.has(node.type) && walkAST(node.do, isGhCommandNode)
    );
  } catch {
    return detectLoopWithGhRegex(command);
  }
}

// --- Write detection (regex — same patterns as bash) ---

const WRITE_ACTIONS = /gh\s+(pr|issue|release|label|repo|gist|workflow)\s+(create|merge|close|comment|edit|delete|transfer|archive|rename|review|reopen|ready|lock|unlock|fork|run|enable|disable)/;
const API_WRITE_METHOD = /gh\s+api.*(-X|--method)\s+(POST|PUT|PATCH|DELETE)/;
const API_FIELD_FLAGS = /gh\s+api.*\s(-f\s|--field\s|-F\s|--raw-field\s)/;
const API_INPUT_FLAG = /gh\s+api.*\s--input\s/;

function detectWrite(command) {
  return WRITE_ACTIONS.test(command)
    || API_WRITE_METHOD.test(command)
    || API_FIELD_FLAGS.test(command)
    || API_INPUT_FLAG.test(command);
}

// --- Git helpers ---

/** Run a git command safely via execFileSync (no shell invocation). */
function defaultExecGit(args, cwd) {
  try {
    return execFileSync("git", args, { cwd, encoding: "utf8", timeout: 3000, stdio: ["pipe", "pipe", "ignore"] }).trim();
  } catch {
    return "";
  }
}

/** Normalize any git remote URL to owner/repo. */
function repoFromUrl(url) {
  const cleaned = url
    .replace(/^.*:\/\/[^/]*\//, "")  // https://host/... or ssh://user@host:port/...
    .replace(/^[^:]*:/, "")           // git@host:...
    .replace(/\.git$/, "");
  const match = cleaned.match(/^([^/]+\/[^/]+)/);
  return match ? match[1] : "";
}

// --- Command parsing ---

/** Extract the last cd target from a chained command. */
function parseWorkDir(command) {
  const cwd = process.cwd();
  const cdPattern = /(?:^|&&|;|\|\|)\s*cd\s+(?:"([^"]*)"|([^ &;|]+))/g;
  let lastTarget = null;
  let match;
  while ((match = cdPattern.exec(command)) !== null) {
    lastTarget = match[1] ?? match[2];
  }
  if (!lastTarget) return cwd;
  if (lastTarget.startsWith("/")) return lastTarget;
  if (lastTarget.startsWith("~")) return lastTarget.replace(/^~/, process.env.HOME ?? "");
  return `${cwd}/${lastTarget}`;
}

// --- Repo resolution ---

/**
 * Resolve the target repo from the command, in priority order:
 * 1. Explicit -R or --repo flag
 * 2. gh repo create positional arg
 * 3. gh api repos/OWNER/REPO path
 * 4. Git remotes (with fork detection)
 *
 * Returns one of:
 *   { repo: string }
 *   { error: "fork", origin: string, upstream: string }
 *   { error: "unresolvable" }
 */
function resolveTargetRepo(command, workDir, config, git = defaultExecGit) {
  // 1. Explicit -R or --repo flag
  const repoFlagMatch = command.match(/(-R|--repo)\s+([^ ]+)/);
  if (repoFlagMatch) {
    return { repo: repoFlagMatch[2] };
  }

  // 2. gh repo create <name>
  if (/gh\s+repo\s+create\b/.test(command)) {
    const afterCreate = command.replace(/.*gh\s+repo\s+create\s+/, "");
    const firstArg = afterCreate.split(/\s+/)[0];
    if (firstArg && !firstArg.startsWith("-")) {
      if (firstArg.includes("/")) {
        return { repo: firstArg };
      }
      const defaultOwner = config.allowedOwners[0] ?? "";
      return { repo: `${defaultOwner}/${firstArg}` };
    }
  }

  // 3. gh api with repos/OWNER/REPO
  if (/gh\s+api\b.*\/?repos\//.test(command)) {
    const apiMatch = command.match(/\/?repos\/([^/]+\/[^/ ]+)/);
    if (apiMatch) {
      return { repo: apiMatch[1] };
    }
  }

  // 4. Git remotes
  const upstreamUrl = git(["remote", "get-url", "upstream"], workDir);
  if (upstreamUrl) {
    return {
      error: "fork",
      origin: repoFromUrl(git(["remote", "get-url", "origin"], workDir)),
      upstream: repoFromUrl(upstreamUrl),
    };
  }

  const originUrl = git(["remote", "get-url", "origin"], workDir);
  if (originUrl) {
    return { repo: repoFromUrl(originUrl) };
  }

  return { error: "unresolvable" };
}

// --- Ownership check ---

function isAllowed(repo, config) {
  const owner = repo.split("/")[0];
  return config.allowedRepos.includes(repo)
    || config.allowedOwners.includes(owner);
}

function isForkParent(targetRepo, workDir, git = defaultExecGit) {
  const upstreamUrl = git(["remote", "get-url", "upstream"], workDir);
  if (!upstreamUrl) return false;
  return repoFromUrl(upstreamUrl) === targetRepo;
}

// --- Main ---

async function main() {
  const raw = await readStdin();
  const command = parseInput(raw);

  // Quick exit: no gh command
  if (!/\bgh\b/.test(command)) process.exit(0);

  const allowedOwners = (process.env.GIT_GUARDRAILS_ALLOWED_OWNERS ?? "").split(/\s+/).filter(Boolean);
  const allowedRepos = (process.env.GIT_GUARDRAILS_ALLOWED_REPOS ?? "").split(/\s+/).filter(Boolean);
  const config = { allowedOwners, allowedRepos };

  // Complexity gate: AST-based loop detection
  if (detectLoopWithGh(command)) {
    block("gh command in loop \u2014 cannot verify targets", "Run each gh command individually.");
  }

  // Write detection
  if (!detectWrite(command)) process.exit(0);

  // Fail-safe: block writes when unconfigured
  if (allowedOwners.length === 0) {
    block("Not configured \u2014 run /guardrails-init to set up", "GIT_GUARDRAILS_ALLOWED_OWNERS is not set.");
  }

  // Gists are user-scoped — no ownership to validate
  if (/gh\s+gist\s/.test(command)) process.exit(0);

  // Fork creates a copy under your own account — safe regardless of target
  if (/gh\s+repo\s+fork\b/.test(command)) process.exit(0);

  // Resolve working directory and target repo
  const workDir = parseWorkDir(command);
  const result = resolveTargetRepo(command, workDir, config);

  if (result.error === "fork") {
    block("Write operation in a fork \u2014 specify target with -R", [
      `Fork:     ${result.origin}`,
      `Upstream: ${result.upstream}`,
      "",
      `Use -R ${result.origin} to target your fork`,
      `Use -R ${result.upstream} to target upstream (if intended)`,
    ]);
  }

  if (result.error === "unresolvable") {
    process.stderr.write("\u26A0\uFE0F  git-guardrails: Cannot determine target repo for gh write operation\n");
    process.stderr.write("   Use -R owner/repo to specify target explicitly.\n");
    process.exit(2);
  }

  // Ownership check
  if (!isAllowed(result.repo, config) && !isForkParent(result.repo, workDir)) {
    block("gh write targets repo you don't own", [
      `Target:  ${result.repo}`,
      `Allowed: owners=[${allowedOwners.join(" ")}] repos=[${allowedRepos.join(" ")}]`,
      "",
      "To override: add to GIT_GUARDRAILS_ALLOWED_REPOS",
      "Or specify:  -R owner/repo",
    ]);
  }

  process.exit(0);
}

main();
