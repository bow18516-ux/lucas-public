For requests to enable or disable thinking on a different model, use runtime.model.list, then
runtime.model.thinking.get and runtime.model.thinking.set with the returned revision.
Thinking mode is independent of reasoning effort. The saved setting applies to this
connection/model across Agents and sessions. Default restores existing routing behavior;
it does not mean thinking is off. Only the setter's successful result confirms a save.