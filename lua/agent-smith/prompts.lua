--- agent-smith/prompts.lua
---
--- System prompt templates for each operation type.
---
--- Design philosophy:
--- Prompts are structured with XML-like tags to help the AI understand
--- the boundaries between instructions, context, and user input.
---
--- Prompt structure:
--- Each operation has a specific instruction template that tells the AI:
--- 1. What format to use for output
--- 2. What constraints to follow
--- 3. What the selection/context contains
---
--- Why XML tags?
--- - Clear boundaries between sections
--- - AI models are trained to respect XML structure
--- - Easy to parse if needed
--- - Matches the pattern used by 99 (proven effective)

local M = {}

--- Build the visual selection prompt.
---
--- Includes:
--- - Instruction to replace only the selection
--- - Selection location (file, line range)
--- - Selection content
--- - Surrounding context (for understanding)
---
---@param range table Range object with to_string() and to_text()
---@return string
function M.visual(range)
  return string.format(
    [[Replace only the selected code below. Return ONLY the replacement code.
Do not include explanations, markdown, or any other text.

<SELECTION>%s</SELECTION>
<CONTENT>
%s
</CONTENT>]],
    range:to_string(),
    range:to_text()
  )
end

--- Build the semantic search prompt.
---
--- Instructs the AI to output results in the strict format:
--- /path/to/file:line:col,count,brief note
---
---@return string
function M.search()
  return [[Search the project for code matching the description.
You may read files and run non-mutating inspection commands. Do not edit, create,
delete, rename, or write any project file.
Output ONLY location lines in this exact format (one per line):

/path/to/file.ext:line:column,line_count,Brief note about why this location is relevant

Rules:
- Use absolute paths
- Line numbers are 1-based
- Columns are 1-based
- line_count = number of lines to highlight
- Notes must be on a single line (no newlines)
- Do not include any other text, explanations, or markdown]]
end

--- Build the vibe mode prompt.
---
--- Similar to search but for broader analysis operations.
---@return string
function M.vibe()
  return [[Perform the requested analysis on this project.
You may read files and run non-mutating inspection commands. Never use editing,
writing, creating, deleting, renaming, or version-control mutation tools. Agent-Smith
will apply only returned FILE_CHANGE proposals after the user approves them.

For analysis requests, output ONLY location lines in this exact format (one per line):
/path/to/file.ext:line:column,line_count,Brief note about what was found

For requests that create, modify, or delete files, output ONLY complete proposals:
<FILE_CHANGE>/absolute/path/to/file.ext</FILE_CHANGE>
<CONTENT>
complete replacement content for this file
</CONTENT>

Rules:
- Never claim a file was changed unless it is represented by a FILE_CHANGE proposal
- Use absolute paths
- Location line numbers and columns are 1-based
- line_count is number of lines to highlight
- Location notes must be single-line
- FILE_CHANGE content must be complete file content, never a diff
- Do not include explanations or markdown fences]]
end

--- Build the first, planning phase of a sandboxed Vibe session.
---@return string
function M.vibe_plan()
  return [[Inspect this sandboxed project and create a plan. Do not modify files yet.

Return ONLY this structure:
<PLAN>
<EDIT_FILES>
<FILE>repo/relative/path.ext</FILE>
</EDIT_FILES>
<STEPS>
Concise ordered implementation steps
</STEPS>
</PLAN>

Rules:
- Paths must be relative to the sandbox project root
- EDIT_FILES must contain every file that execution may create, modify, or delete
- Use an empty EDIT_FILES block for analysis-only requests
- Read all files needed to make a reliable plan
- Do not edit, create, delete, rename, or write files during this phase
- Do not include markdown fences or text outside PLAN]]
end

--- Build the execution phase of a sandboxed Vibe session.
---@param plan string Approved plan text
---@param files string[] Approved editable relative paths
---@return string
function M.vibe_execute(plan, files)
  local file_lines = {}
  for _, path in ipairs(files) do table.insert(file_lines, "- " .. path) end
  local scope = #file_lines > 0 and table.concat(file_lines, "\n") or "(analysis only; no file writes allowed)"
  return string.format([[Execute the approved plan inside this sandbox project.

Approved editable files:
%s

Approved plan:
%s

Rules:
- Work only inside the current sandbox directory
- Modify only approved editable files
- Do not access or modify the original repository
- For analysis-only plans, do not write files and return location lines as:
  /absolute/sandbox/path:line:column,line_count,Brief note
- For editing plans, use tools to edit sandbox files directly
- When complete, return a concise plain-text summary]], scope, plan)
end

--- Build the multi-file edit prompt.
---
--- Instructs the AI to use FILE_CHANGE/CONTENT blocks.
---@return string
function M.multi_file()
  return [[For changes spanning multiple files, output each file's changes using:

<FILE_CHANGE>/absolute/path/to/file.lua</FILE_CHANGE>
<CONTENT>
full replacement content for this file
</CONTENT>

Rules:
- Use absolute file paths
- Each file gets its own FILE_CHANGE/CONTENT pair
- CONTENT must contain the COMPLETE file content (not a diff)
- Only include files that actually need changes
- Do not include explanations, only the structured blocks]]
end

--- Wrap instruction and user prompt in XML tags.
---
---@param instruction string The operation-specific instruction
---@param user string The user's natural language prompt
---@return string
function M.wrap(instruction, user)
  return string.format(
    "<INSTRUCTIONS>\n%s\n</INSTRUCTIONS>\n<PROMPT>\n%s\n</PROMPT>",
    instruction,
    user
  )
end

return M
