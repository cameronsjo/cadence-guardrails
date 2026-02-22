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

// NOTE: This file uses execFileSync (not exec/execSync) for all subprocess
// calls. execFileSync does not invoke a shell, so there is no command injection
// risk. The arguments (e.g. "remote", "get-url", "upstream") are static strings
// or derived from git remote URLs, never from user input.

// --- Helpers ---

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

/** Quick-exit check: does the command contain `gh` as a word? */
function hasGhCommand(command) {
  return /\bgh\b/.test(command);
}

// --- AST-based loop detection ---

/** Walk the AST looking for For/While/Until nodes whose body contains a gh Command. */
function astHasLoopWithGh(node) {
  if (!node || typeof node !== "object") return false;

  if (node.type === "For" || node.type === "While" || node.type === "Until") {
    if (astContainsGhCommand(node.do)) return true;
  }

  for (const key of Object.keys(node)) {
    const value = node[key];
    if (Array.isArray(value)) {
      for (const child of value) {
        if (astHasLoopWithGh(child)) return true;
      }
    } else if (value && typeof value === "object" && value.type) {
      if (astHasLoopWithGh(value)) return true;
    }
  }
  return false;
}

/** Recursively search an AST subtree for a Command node named `gh`. */
function astContainsGhCommand(node) {
  if (!node || typeof node !== "object") return false;

  if (node.type === "Command" && node.name?.text === "gh") return true;

  for (const key of Object.keys(node)) {
    const value = node[key];
    if (Array.isArray(value)) {
      for (const child of value) {
        if (astContainsGhCommand(child)) return true;
      }
    } else if (value && typeof value === "object" && value.type) {
      if (astContainsGhCommand(value)) return true;
    }
  }
  return false;
}

/** Regex fallback for when bash-parser throws. Matches the original bash behavior. */
function detectLoopWithGhRegex(command) {
  const stripped = command.replace(/"[^"]*"/g, "").replace(/'[^']*'/g, "");
  const hasLoop = /\bfor\s+\w+\s+in\b|\bwhile\b.*;\s*do\b/.test(stripped);
  return hasLoop && /\bgh\b/.test(command);
}

/** Primary loop detection: AST-based with regex fallback. */
function detectLoopWithGh(command) {
  try {
    const ast = parse(command);
    return astHasLoopWithGh(ast);
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

function isGistCommand(command) {
  return /gh\s+gist\s/.test(command);
}

// --- Repo resolution ---

/** Normalize any git remote URL to owner/repo. */
function repoFromUrl(url) {
  const cleaned = url
    .replace(/^.*:\/\/[^/]*\//, "")  // https://host/... or ssh://user@host:port/...
    .replace(/^[^:]*:/, "")           // git@host:...
    .replace(/\.git$/, "");
  const match = cleaned.match(/^([^/]+\/[^/]+)/);
  return match ? match[1] : "";
}

/** Run a git command safely via execFileSync (no shell invocation). */
function execGit(args, cwd) {
  try {
    return execFileSync("git", args, { cwd, encoding: "utf8", timeout: 3000, stdio: ["pipe", "pipe", "ignore"] }).trim();
  } catch {
    return "";
  }
}

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

/**
 * Resolve the target repo from the command, in priority order:
 * 1. Explicit -R or --repo flag
 * 2. gh repo create positional arg
 * 3. gh api repos/OWNER/REPO path
 * 4. Git remotes (with fork detection)
 *
 * Returns { repo: string } on success, or { error: true, stderr: string } to block.
 */
function resolveTargetRepo(command, workDir, config) {
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
  const upstreamUrl = execGit(["remote", "get-url", "upstream"], workDir);
  if (upstreamUrl) {
    // Fork detected — require -R to disambiguate
    const upstreamRepo = repoFromUrl(upstreamUrl);
    const originUrl = execGit(["remote", "get-url", "origin"], workDir);
    const originRepo = repoFromUrl(originUrl);
    return {
      error: true,
      stderr: [
        "\u{1F6AB} git-guardrails: Write operation in a fork \u2014 specify target with -R",
        `   Fork:     ${originRepo}`,
        `   Upstream: ${upstreamRepo}`,
        "",
        `   Use -R ${originRepo} to target your fork`,
        `   Use -R ${upstreamRepo} to target upstream (if intended)`,
      ].join("\n") + "\n",
    };
  }

  // Non-fork: resolve from origin
  const originUrl = execGit(["remote", "get-url", "origin"], workDir);
  if (originUrl) {
    return { repo: repoFromUrl(originUrl) };
  }

  // No repo resolvable
  return {
    error: true,
    stderr: [
      "\u26A0\uFE0F  git-guardrails: Cannot determine target repo for gh write operation",
      "   Use -R owner/repo to specify target explicitly.",
    ].join("\n") + "\n",
  };
}

// --- Ownership check ---

function isAllowed(repo, config) {
  const owner = repo.split("/")[0];
  for (const allowedRepo of config.allowedRepos) {
    if (repo === allowedRepo) return true;
  }
  for (const allowedOwner of config.allowedOwners) {
    if (owner === allowedOwner) return true;
  }
  return false;
}

function isForkParent(targetRepo, workDir) {
  const upstreamUrl = execGit(["remote", "get-url", "upstream"], workDir);
  if (!upstreamUrl) return false;
  return repoFromUrl(upstreamUrl) === targetRepo;
}

// --- Output helpers ---

/** Write a block message to stderr and exit 2. */
function block(message, detail) {
  process.stderr.write(`\u{1F6AB} git-guardrails: ${message}\n`);
  if (detail) process.stderr.write(`   ${detail}\n`);
  process.exit(2);
}

// --- Main ---

async function main() {
  const raw = await readStdin();
  const command = parseInput(raw);

  // Quick exit: no gh command
  if (!hasGhCommand(command)) process.exit(0);

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
  if (isGistCommand(command)) process.exit(0);

  // Resolve working directory and target repo
  const workDir = parseWorkDir(command);
  const result = resolveTargetRepo(command, workDir, config);

  if (result.error) {
    process.stderr.write(result.stderr);
    process.exit(2);
  }

  // Ownership check
  if (!isAllowed(result.repo, config) && !isForkParent(result.repo, workDir)) {
    process.stderr.write([
      `\u{1F6AB} git-guardrails: gh write targets repo you don't own`,
      `   Target:  ${result.repo}`,
      `   Allowed: owners=[${allowedOwners.join(" ")}] repos=[${allowedRepos.join(" ")}]`,
      "",
      "   To override: add to GIT_GUARDRAILS_ALLOWED_REPOS",
      "   Or specify:  -R owner/repo",
    ].join("\n") + "\n");
    process.exit(2);
  }

  process.exit(0);
}

main();
