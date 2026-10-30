

## Runtime Loop Budget
This is model invocation {{invocation}}. The Runtime soft loop threshold is {{softLimit}} and the
hard limit is {{hardLimit}}. Reassess progress now. If the user's core request is answerable from
current evidence, finish it in this response. Make another tool call only when it materially
advances the task. Do not repeat an unchanged tool call; if required information or authority is
missing, state the blocker and ask for the smallest necessary user input.