# Evaluate a skill in Bailongma

Adapted from the test, review, and improvement loop in Anthropic skill-creator.
See ../UPSTREAM.txt and ../LICENSE.txt.

## Choose representative cases

Use two or three realistic requests to start, including a normal case and a meaningful edge
case. Derive expected results from the user's requirements. For deterministic outputs, check
observable properties such as values, file validity, or preserved content. For subjective
outputs, present the artifacts for user feedback rather than inventing a numeric score.

Keep temporary test outputs outside installed skill directories. Do not send messages, make
purchases, or modify production data merely to evaluate a skill. Use fixtures where possible;
obtain any authorization required for real external actions.

## Run and compare

Discover the tools actually available. When independent agent execution is available and
authorized, give each run the request, skill, and minimum necessary inputs. For comparison,
use equivalent inputs with and without the skill (or with the previous version). Keep their
outputs separate. Independent runs are useful but are not a prerequisite for creating a skill.

Without independent execution, run safe cases sequentially with existing tools and label the
result a manual sanity check. Do not represent a same-context run as an independent benchmark.
If execution is unavailable, review the instructions and explicitly report that behavior
has not been tested.

Record the request, observed output, passed or failed requirements, and any execution errors.
Use timings and token counts only if the runtime reports them. Separate infrastructure errors
from failures caused by the skill. Show outputs directly or link local artifacts using the
available interface; a custom viewer or local server is not required.

## Improve from feedback

Find the general cause of a failure rather than adding a rule tailored to one test. Remove
instructions that cause unnecessary work. Consider bundling a helper if repeated tests reveal
the same code being rewritten. Retest changed behavior and preserve a useful regression case.
Stop once the requested outcome is achieved; do not impose repeated review rounds on a quick edit.

## Check triggering descriptions

Include both requests that should use the skill and nearby requests that should not. Vary
wording and specificity. Use the actual Bailongma catalog and skill-read observations if the
runtime exposes isolated test runs. Reading a skill manually does not demonstrate automatic
selection. Without those observations, report a description review rather than trigger accuracy.

Never use a Claude CLI benchmark as evidence of Bailongma's selection behavior. An external
model evaluation is a separate workflow requiring suitable tools and user authorization.
