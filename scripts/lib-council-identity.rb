# Canonical model-identity resolver (council-wiring.md §2). Longest-prefix match.
PREFIXES = [
  ["claude", ["claude", "anthropic"]], ["fable", ["claude", "anthropic"]],
  ["opus", ["claude", "anthropic"]], ["sonnet", ["claude", "anthropic"]],
  ["haiku", ["claude", "anthropic"]],
  ["gpt-", ["codex", "openai"]], ["codex", ["codex", "openai"]],
  ["glm", ["glm", "zhipu"]],
  ["kimi", ["kimi", "moonshot"]], ["k3", ["kimi", "moonshot"]],
  ["fugu", ["fugu", "sakana"]],
].sort_by { |prefix, _| -prefix.length }
def resolve_identity(id)
  key = id.to_s.strip.downcase
  return nil if key.empty?
  PREFIXES.each { |prefix, tuple| return tuple if key.start_with?(prefix) }
  nil
end
