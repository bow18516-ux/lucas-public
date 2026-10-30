---
name: skill-creator
description: Create new skills, modify and improve existing skills, and evaluate their behavior. Use when the user wants to turn a workflow into a reusable skill, create or edit SKILL.md, test a skill, or improve its triggering description. Do not use merely to carry out the task described by another skill.
---

# Skill Creator

Create reusable skills for Bailongma through a draft, test, feedback, and improvement loop.
Adapted from Anthropic's skill-creator; see [UPSTREAM.txt](UPSTREAM.txt) and [LICENSE.txt](LICENSE.txt).

## Understand the request

Extract the desired capability, triggering situations, expected outputs, and constraints from
the conversation. Ask only for missing information that affects the result. If the user has
an existing draft, read it and begin at the relevant stage. Match the amount of testing to
the request; a quick edit does not require a full evaluation campaign.

## Use this runtime

- Discover available filesystem and command tools through `runtime.tool.search`. Use actual
  tool results to confirm reads, writes, execution, and installation.
- Obtain the configured skill directories from the Local Agent Skills catalog in context.
  Prefer the first directory for a new skill unless the user specifies another location.
  An empty directory list means discovery is disabled; explain that before claiming installation.
- Save a new skill as `<configured-directory>/<skill-name>/SKILL.md`. Read existing files
  before editing, preserve an existing skill's name, and do not overwrite unrelated work.
- New skills belong in the writable configured directory, not inside the application bundle
  or this skill-creator directory. Never change runtime configuration merely to install a skill.
- Skill instructions do not grant tool permissions. Respect the user's scope and runtime policy.
- This adaptation uses Bailongma tools. Do not assume Claude CLI, `.claude/commands`, a
  particular subagent API, Python, or an external model account is available.

## Draft the skill

Use YAML frontmatter with `name` and `description`, followed by actionable workflow instructions.
The name must use lowercase letters, digits, and single hyphens between words (maximum 64
characters). The description must explain what the skill does and when to use it (maximum
1024 characters). Keep it precise enough to distinguish adjacent tasks.

Keep the entrypoint concise. Put substantial optional guidance in `references/`, reusable
code in `scripts/`, and output templates in `assets/`. Link resources with relative paths
and explain when to read them. Only add resources needed by the workflow.

For detailed structure and writing guidance, read [references/writing.md](references/writing.md).
Explain the reasons behind important steps; avoid rigid rules that only fit one example.
Preserve the user's chosen tools and product. Do not introduce unavailable dependencies.

## Validate and improve

1. Read back the saved files. Check frontmatter, naming, referenced paths, dependencies,
   and unfinished placeholders. Verify bundled scripts with safe representative inputs
   when an appropriate execution tool is available.
2. Confirm the saved skill appears in the catalog on a subsequent model call before saying
   it is installed. If no refreshed catalog is available, report the saved path and that
   discovery is not yet verified.
3. For a new workflow or meaningful behavior change, use a few realistic test requests.
   Follow [references/evaluation.md](references/evaluation.md) when evaluation is warranted.
4. Show actual outputs and relevant checks to the user, incorporate feedback, and retest
   affected behavior. Stop when the request is satisfied or further testing needs unavailable
   input or capabilities; describe any remaining limitation accurately.

Report the installed path, what the skill does, and what was verified in plain language.
