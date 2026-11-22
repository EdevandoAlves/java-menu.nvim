-- java_menu/build.lua
-- <leader>jb: build and run Java projects (Maven preferred, Gradle when an
-- executable wrapper exists). Reuses the earlier infrastructure (ui, project)
-- and `run_config` for per-canonical-root Repeat Last history.

local ui = require("java_menu.ui")
local project = require("java_menu.project")
local lsp = require("java_menu.lsp")
local run_config = require("java_menu.run_config")

local M = {}

local LIFECYCLE = {
  build = "build",
  compile = "compile",
  package = "package",
  clean = "clean",
  install = "install",
}

---@class BuildState
local state = {
  job = nil,
  pid = nil,
  pid_start_ticks = nil,
  pgid = nil,
  pgid_start_ticks = nil,
  pgid_sid = nil,
  pgid_members = nil,
  pgid_reason = nil,
  pgid_uncertain = false,
  pgid_uncertain_reason = nil,
  draining_pgid = nil,
  draining_start_ticks = nil,
  drain_timer = nil,
  buf = nil,
  kind = nil,
  cmd = nil,
  cwd = nil,
  root = nil, -- project that started the job (isolation between projects)
  running = false,
  status = "idle",
  last_output = nil,
  last_output_root = nil,
  seq = 0,
  redactions = {},
  after_exit = nil,
  restarting = false,
  restart_op = nil,
  stopping = false,
}

---Tracked surviving process groups released from the foreground build lock
---after ordinary leader exit, keyed in order of release so they can still be
---safely stopped without blocking future builds or risking PID reuse.
local background_groups = {}

M._stop_grace_ms = 1000
M._restart_timeout_ms = 5000
M._background_grace_ms = 500
M._max_line_bytes = 65536
M._max_lookahead_bytes = 65536

---Last build arguments per canonical project root (repeat never crosses projects).
local last_builds = {}

---Last executed command per project (keyed by canonical root, without secrets).
local last_runs = {}

---Resolve Repeat Last arguments for `canon_root`:
---1) in-session `last_builds[canon_root]`,
---2) persisted per-root `run_config.load_last_build(canon_root)`.
---`jc.settings` (`build-last`) is intentionally neither read nor written here
---because its normalized path keys are non-injective and carry no cross-session
---ownership metadata.
---@param canon_root string
---@param notify_err boolean
---@return string[]|nil argv, boolean has_history
local function resolve_last_build(canon_root, notify_err)
  local last = last_builds[canon_root]
  if type(last) == "table" and #last > 0 then
    return vim.deepcopy(last), true
  end
  local saved_last, saved_err = run_config.load_last_build(canon_root)
  if saved_err and notify_err then
    ui.notify(saved_err, vim.log.levels.WARN)
  end
  if type(saved_last) == "table" and #saved_last > 0 then
    return saved_last, true
  end
  return nil, false
end

-- ---------- project helpers ----------

local function is_file(path)
  return vim.fn.filereadable(path) == 1
end

local function is_exec(path)
  return path ~= nil and path ~= "" and vim.fn.executable(path) == 1
end

---Build tool and runner to use at the root.
---@param root string
---@return table|nil tool { tool, runner, reason }
local function build_tool(root)
  local gradle = is_file(root .. "/settings.gradle")
    or is_file(root .. "/settings.gradle.kts")
    or is_file(root .. "/build.gradle")
    or is_file(root .. "/build.gradle.kts")

  if gradle then
    local wrapper = root .. "/gradlew"
    if is_exec(wrapper) then
      return { tool = "gradle", runner = wrapper }
    end
    if is_exec("gradle") then
      return { tool = "gradle", runner = "gradle" }
    end
    return { tool = "gradle", runner = nil, reason = "gradlew is not executable and gradle is not in PATH" }
  end

  if is_file(root .. "/pom.xml") then
    local wrapper = root .. "/mvnw"
    if is_exec(wrapper) then
      return { tool = "maven", runner = wrapper }
    end
    if is_exec("mvn") then
      return { tool = "maven", runner = "mvn" }
    end
    return { tool = "maven", runner = nil, reason = "mvnw is not executable and mvn is not in PATH" }
  end
end

---Module that owns a source root.
local function module_of_source_root(source_root)
  return (source_root:gsub("[/\\]src[/\\][^/\\]+[/\\]java$", ""))
end

---Module of the current buffer (the most specific source root containing it).
local function module_for(bufnr, root)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local best
  for _, sr in ipairs(project.source_roots(root)) do
    if name:sub(1, #sr.path + 1) == sr.path .. "/" then
      if not best or #sr.path > #best then
        best = sr.path
      end
    end
  end
  return best and module_of_source_root(best) or root
end

---@return boolean
local function jdtls_attached(bufnr)
  return #vim.lsp.get_clients({ name = "jdtls", bufnr = bufnr }) > 0
end

-- ---------- descoberta ----------

---Classes with `public static void main`.
local function main_classes(root)
  local out = {}
  for _, sr in ipairs(project.source_roots(root)) do
    local files = vim.fs.find(function(name)
      return name:sub(-5) == ".java"
    end, { path = sr.path, type = "file", limit = 800 })

    for _, file in ipairs(files) do
      local head = vim.fn.readfile(file, "", 80)
      if table.concat(head, "\n"):find("public static void main", 1, true) then
        local class = vim.fn.fnamemodify(file, ":t:r")
        local rel = vim.fs.relpath(sr.path, vim.fs.dirname(file))
        local pkg = rel and rel ~= "." and rel:gsub("[/\\]", ".") or ""
        out[#out + 1] = {
          fqn = (pkg ~= "" and (pkg .. ".") or "") .. class,
          path = file,
          module = module_of_source_root(sr.path),
        }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.fqn < b.fqn
  end)
  return out
end

---Modules that declare Spring Boot in the pom.
local function spring_modules(root)
  local out = {}
  for _, mod in ipairs(project.modules(root)) do
    local pom = mod .. "/pom.xml"
    if is_file(pom) then
      local text = table.concat(vim.fn.readfile(pom), "\n")
      if text:find("spring%-boot") then
        out[#out + 1] = mod
      end
    end
  end
  return out
end

-- ---------- execution ----------

local BUILD_EFM = table.concat({
  "%E%f:%l: error: %m",
  "%W%f:%l: warning: %m",
  "%E[ERROR] %f:[%l\\,%c] %m",
  "%E[ERROR] %f:%l: %m",
  "%-G%.%#",
}, ",")

---Last code buffer used by the menus (survives the output split).
local last_code_buf = nil

local function is_output_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and vim.b[buf].java_build_title ~= nil
end

---Menu context buffer: when focus is in the build output, use the last code
---buffer (the output split has no file, hence no project).
local function context_buf()
  local cur = vim.api.nvim_get_current_buf()
  if not is_output_buf(cur) then
    if vim.bo[cur].buftype == "" then
      last_code_buf = cur
    end
    return cur
  end
  if last_code_buf and vim.api.nvim_buf_is_valid(last_code_buf) and not is_output_buf(last_code_buf) then
    return last_code_buf
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and not is_output_buf(buf) then
      return buf
    end
  end
  return cur
end

local function open_output(title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.b[buf].java_build_title = title

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, 14)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, nowait = true })
  return buf
end

---Append to the output buffer, keeping the window at the end when visible.
local function append(buf, lines)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) or #lines == 0 then
    return
  end
  vim.bo[buf].modifiable = true
  local row = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, row, row, false, lines)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

---Fill the quickfix list with compilation errors from the output buffer.
local function fill_quickfix(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local items = vim.fn.getqflist({ lines = lines, efm = BUILD_EFM }).items
  local valid = vim.tbl_filter(function(item)
    return item.valid == 1
  end, items or {})
  if #valid == 0 then
    return
  end
  vim.fn.setqflist({}, " ", { title = "java build", items = valid })
  vim.cmd("botright copen")
  ui.notify(("%d compilation error(s) in the quickfix list"):format(#valid), vim.log.levels.WARN)
end

local function new_stream_state()
  return {
    chunks = {},
    len = 0,
    dropping = false,
    dropped_bytes = 0,
    truncated_notified = false,
  }
end

local pending = {
  stdout = new_stream_state(),
  stderr = new_stream_state(),
}

local pending_append = {
  seq = 0,
  buf = nil,
  lines = {},
  notices = {},
  bytes = 0,
  capped = false,
  scheduled = false,
}

-- Bound the entire captured output as well as individual lines.
M._max_output_bytes = 4 * 1024 * 1024

local function ensure_stream_state(stream)
  local st = pending[stream]
  if type(st) ~= "table" or type(st.chunks) ~= "table" then
    st = new_stream_state()
    pending[stream] = st
  end
  return st
end

local function reset_stream_state(stream)
  local st = ensure_stream_state(stream)
  st.chunks = {}
  st.len = 0
  st.dropping = false
  st.dropped_bytes = 0
  st.truncated_notified = false
end

local function reset_all_streams()
  reset_stream_state("stdout")
  reset_stream_state("stderr")
  pending_append.seq = 0
  pending_append.buf = nil
  pending_append.lines = {}
  pending_append.notices = {}
  pending_append.bytes = 0
  pending_append.capped = false
  pending_append.scheduled = false
end

local function pending_text(stream)
  if stream ~= "stdout" and stream ~= "stderr" then
    return ""
  end
  local st = ensure_stream_state(stream)
  return table.concat(st.chunks)
end

local function max_redaction_len(redactions)
  if type(redactions) ~= "table" or #redactions == 0 then
    return 0
  end
  local max_len = 0
  for _, secret in ipairs(redactions) do
    if type(secret) == "string" and #secret > max_len then
      max_len = #secret
    end
  end
  return max_len
end

local function drain_append(seq, buf)
  if seq ~= state.seq or pending_append.seq ~= seq then
    return
  end
  pending_append.scheduled = false
  if #pending_append.lines > 0 then
    local target = buf or pending_append.buf
    local lines = pending_append.lines
    pending_append.lines = {}
    append(target, lines)
  end
  if #pending_append.notices > 0 then
    local notices_list = pending_append.notices
    pending_append.notices = {}
    for _, msg in ipairs(notices_list) do
      ui.notify(msg, vim.log.levels.WARN)
    end
  end
end

local function enqueue_append(seq, buf, lines)
  if #lines == 0 then
    return
  end
  if pending_append.seq ~= seq or pending_append.buf ~= buf then
    pending_append.seq = seq
    pending_append.buf = buf
    pending_append.lines = {}
    pending_append.notices = {}
    pending_append.bytes = 0
    pending_append.capped = false
    pending_append.scheduled = false
  end
  local limit = math.max(1, math.floor(tonumber(M._max_output_bytes) or 4 * 1024 * 1024))
  for _, line in ipairs(lines) do
    if not pending_append.capped then
      if pending_append.bytes + #line + 1 > limit then
        pending_append.lines[#pending_append.lines + 1] = "[output limit reached; remaining output suppressed]"
        pending_append.capped = true
      else
        pending_append.lines[#pending_append.lines + 1] = line
        pending_append.bytes = pending_append.bytes + #line + 1
      end
    end
  end
  if not pending_append.scheduled then
    pending_append.scheduled = true
    vim.schedule(function()
      drain_append(seq, buf)
    end)
  end
end

local function notify_truncated(seq, buf, stream, limit, sync)
  local st = ensure_stream_state(stream)
  if st.truncated_notified then
    return
  end
  st.truncated_notified = true
  local kind = state.kind or "build"
  local msg = ("[%s] %s line exceeded %d bytes — truncated and remainder suppressed"):format(kind, stream, limit)
  if sync then
    if seq == state.seq then
      ui.notify(msg, vim.log.levels.WARN)
    end
    return
  end
  local target_buf = buf or state.buf
  if pending_append.seq ~= seq or pending_append.buf ~= target_buf then
    pending_append.seq = seq
    pending_append.buf = target_buf
    pending_append.lines = {}
    pending_append.notices = { msg }
  else
    pending_append.notices[#pending_append.notices + 1] = msg
  end
  vim.schedule(function()
    drain_append(seq, target_buf)
  end)
end

local function emit_truncated(raw, redactions, safe_prefix, limit, out_lines)
  if safe_prefix <= 0 then
    out_lines[#out_lines + 1] = ("[line truncated at 0/%d bytes — secret exceeds buffer; remainder suppressed]"):format(
      limit
    )
    return
  end
  local prefix_redacted = run_config.redact_prefix(raw, redactions, safe_prefix)
  out_lines[#out_lines + 1] = prefix_redacted
    .. (" ... [line truncated at %d bytes; remainder suppressed]"):format(safe_prefix)
end

local function process_segment(st, seq, buf, stream, seg, has_nl_after, redactions, out_lines)
  if st.dropping then
    st.dropped_bytes = st.dropped_bytes + #seg
    if has_nl_after then
      st.dropping = false
    end
    return
  end

  local limit = math.max(1, math.floor(tonumber(M._max_line_bytes) or 65536))
  local total = st.len + #seg

  if not has_nl_after then
    if total <= limit then
      if #seg > 0 then
        st.chunks[#st.chunks + 1] = seg
        st.len = total
      end
      return
    end
    local max_len = max_redaction_len(redactions)
    local max_lookahead = math.max(0, math.floor(tonumber(M._max_lookahead_bytes) or 65536))
    local need_guard = math.max(3, max_len - 1)
    local guard = math.min(max_lookahead, need_guard)
    local trigger_len = limit + guard
    if total < trigger_len then
      if #seg > 0 then
        st.chunks[#st.chunks + 1] = seg
        st.len = total
      end
      return
    end
    local need = math.max(0, trigger_len - st.len)
    if need > 0 and #seg > 0 then
      st.chunks[#st.chunks + 1] = (#seg > need) and seg:sub(1, need) or seg
    end
    local raw = table.concat(st.chunks)
    st.chunks = {}
    st.len = 0
    st.dropping = true
    st.dropped_bytes = st.dropped_bytes + math.max(0, #seg - need)
    local safe_prefix = math.min(limit, math.max(0, trigger_len - need_guard))
    emit_truncated(raw, redactions, safe_prefix, limit, out_lines)
    notify_truncated(seq, buf, stream, limit, false)
    return
  end

  if total == 0 then
    out_lines[#out_lines + 1] = ""
    return
  end

  if total <= limit then
    local line
    if st.len == 0 then
      line = seg
    else
      if #seg > 0 then
        st.chunks[#st.chunks + 1] = seg
      end
      line = table.concat(st.chunks)
      st.chunks = {}
      st.len = 0
    end
    out_lines[#out_lines + 1] = run_config.redact(line, redactions)
    return
  end

  local max_len = max_redaction_len(redactions)
  local max_lookahead = math.max(0, math.floor(tonumber(M._max_lookahead_bytes) or 65536))
  local need_guard = math.max(3, max_len - 1)
  local cap = limit + math.min(max_lookahead, need_guard)
  local need = math.max(0, cap - st.len)
  local clipped = #seg > need
  if need > 0 and #seg > 0 then
    st.chunks[#st.chunks + 1] = clipped and seg:sub(1, need) or seg
  end
  local raw = table.concat(st.chunks)
  st.chunks = {}
  st.len = 0
  st.dropped_bytes = st.dropped_bytes + math.max(0, #seg - need)
  local safe_prefix = clipped and math.min(limit, math.max(0, cap - need_guard)) or limit
  emit_truncated(raw, redactions, safe_prefix, limit, out_lines)
  notify_truncated(seq, buf, stream, limit, false)
end

local function feed(seq, buf, stream, data, redactions)
  if
    seq ~= state.seq
    or not state.running
    or (stream ~= "stdout" and stream ~= "stderr")
    or type(data) ~= "table"
    or #data == 0
  then
    return
  end
  local st = ensure_stream_state(stream)
  -- Fast O(1) drop path for chunks with no newline while suppressing an oversized line.
  if st.dropping and #data == 1 and type(data[1]) == "string" and not data[1]:find("\n", 1, true) then
    st.dropped_bytes = st.dropped_bytes + #data[1]
    return
  end

  local out_lines = {}
  local function flush_batch()
    if #out_lines >= 128 then
      enqueue_append(seq, buf, out_lines)
      out_lines = {}
    end
    return pending_append.capped
  end
  local n = #data
  for i = 1, n do
    local piece = data[i]
    if type(piece) == "string" then
      local has_next = (i < n)
      if not piece:find("\n", 1, true) then
        process_segment(st, seq, buf, stream, piece, has_next, redactions, out_lines)
        if flush_batch() then
          return
        end
      else
        local pos = 1
        while true do
          local nl = piece:find("\n", pos, true)
          if not nl then
            process_segment(st, seq, buf, stream, piece:sub(pos), has_next, redactions, out_lines)
            if flush_batch() then
              return
            end
            break
          end
          process_segment(st, seq, buf, stream, piece:sub(pos, nl - 1), true, redactions, out_lines)
          if flush_batch() then
            return
          end
          pos = nl + 1
        end
      end
    end
  end

  if #out_lines > 0 then
    enqueue_append(seq, buf, out_lines)
  end
end

local function read_proc_info(pid)
  if not pid or pid <= 0 then
    return nil
  end
  local stat_path = ("/proc/%d/stat"):format(pid)
  local fd = vim.uv.fs_open(stat_path, "r", 0)
  if fd then
    local data = vim.uv.fs_read(fd, 4096, 0)
    vim.uv.fs_close(fd)
    if type(data) == "string" then
      local rest = data:match("^%d+%s+%(.*%)%s+(.+)$")
      if rest then
        local fields = vim.split(vim.trim(rest), "%s+")
        local ppid = tonumber(fields[2])
        local pgid = tonumber(fields[3])
        local sid = tonumber(fields[4])
        local start_ticks = tonumber(fields[20])
        if pgid then
          return {
            pid = pid,
            ppid = ppid,
            pgid = pgid,
            sid = sid,
            start_ticks = start_ticks,
            state = fields[1],
          }
        end
      end
    end
  end
  local ok, out = pcall(vim.fn.systemlist, { "ps", "-o", "pgid=", "-p", tostring(pid) })
  if ok and type(out) == "table" and out[1] then
    local pgid = tonumber(vim.trim(out[1]))
    if pgid then
      return { pid = pid, ppid = nil, pgid = pgid, sid = nil, start_ticks = nil, state = nil }
    end
  end
  return nil
end

local function verify_own_pgid(pid)
  if type(pid) ~= "number" or pid <= 1 then
    return nil, nil, "invalid process PID"
  end
  local my = M._read_proc_info(vim.uv.os_getpid())
  if not my then
    return nil, nil, "could not read editor process group"
  end
  local info = M._read_proc_info(pid)
  if not info then
    return nil, nil, "could not read child process group (/proc and ps unavailable)"
  end
  if info.pgid == my.pgid then
    return nil, nil, ("child shares editor process group (%d)"):format(info.pgid)
  end
  if info.pgid ~= pid then
    return nil, nil, ("child pgid (%d) differs from pid (%d)"):format(info.pgid, pid)
  end
  if type(info.start_ticks) ~= "number" then
    return nil, nil, "could not verify child process group identity (/proc start time unavailable)"
  end
  return info.pgid, info.start_ticks, nil
end

local function snapshot_group_members(pgid, min_start_ticks, expected_sid)
  if type(pgid) ~= "number" or pgid <= 1 or type(min_start_ticks) ~= "number" then
    return nil
  end
  local dir = vim.uv.fs_scandir("/proc")
  if not dir then
    return nil
  end
  local my_pid = vim.uv.os_getpid()
  local members = {}
  while true do
    local name, kind = vim.uv.fs_scandir_next(dir)
    if not name then
      break
    end
    if (kind == "directory" or kind == nil) and name:match("^%d+$") then
      local pid = tonumber(name)
      if pid and pid > 1 and pid ~= my_pid then
        local info = M._read_proc_info(pid)
        if info and info.pgid == pgid and type(info.start_ticks) == "number" then
          local ticks_ok = info.start_ticks >= min_start_ticks
          local sid_ok = type(expected_sid) ~= "number" or (type(info.sid) == "number" and info.sid == expected_sid)
          if ticks_ok and sid_ok then
            members[pid] = info.start_ticks
          end
        end
      end
    end
  end
  return members
end

local function pgid_exists(pgid)
  if type(vim.uv.kill) == "function" then
    local ok, _, err_code = vim.uv.kill(-pgid, 0)
    return ok == 0 or err_code == "EPERM"
  end
  vim.fn.system({ "kill", "-0", "-" .. tostring(pgid) })
  return vim.v.shell_error == 0
end

---Verify continuity before accepting a refreshed `/proc` snapshot: at least
---one previously verified `(pid, start_ticks)` identity (the original leader or
---a tracked member) must still be present in the new snapshot.
---
---Limitations:
---  1. Polling gap: because `/proc` is sampled on lifecycle transitions and
---     menu/drain polls rather than kernel process-event streams, if every
---     verified member spawns a child in the same PGID and exits before the
---     next poll, continuity is permanently lost and the group becomes
---     `"uncertain"` until that PGID exits.
---  2. Fail-closed safety: `"uncertain"` groups are never refreshed from `/proc`
---     and never signaled (to avoid killing unrelated processes after PID/PGID
---     reuse), and `M.restart()` blocks until the PGID exits or is manually
---     stopped.
---  3. Non-atomic POSIX `kill(2)`: a process can exit and its PGID be reused in
---     the microsecond between checking `/proc` and calling `kill(-pgid, sig)`.
---  4. Platforms without `/proc`: `ps` fallback lacks `start_ticks`, so PGID
---     verification fails closed and live PGIDs cannot be proven `"alive"`.
---@param pgid number
---@param start_ticks number
---@param sid number|nil
---@param prev_members table<number, number>|nil
---@return table<number, number>|nil
local function refresh_verified_members(pgid, start_ticks, sid, prev_members)
  local latest = snapshot_group_members(pgid, start_ticks, sid)
  if not latest or next(latest) == nil then
    return nil
  end
  if type(start_ticks) == "number" and latest[pgid] == start_ticks then
    return latest
  end
  if type(prev_members) == "table" then
    for mpid, mticks in pairs(prev_members) do
      if type(mticks) == "number" and latest[mpid] == mticks then
        return latest
      end
    end
  end
  return nil
end

---Classify a tracked process group as `"alive"`, `"uncertain"`, or `"exited"`.
---Differentiates an unverified live PGID (`"uncertain"`) from a confirmed exit
---(`"exited"`): never signals `"uncertain"` groups and never prunes them as
---exited while processes remain in that PGID.
---@param pgid number|nil
---@param leader_start_ticks number|nil
---@param members table<number, number>|nil
---@return "alive"|"uncertain"|"exited", string|nil
local function group_status(pgid, leader_start_ticks, members)
  if type(pgid) ~= "number" or pgid <= 1 or type(leader_start_ticks) ~= "number" then
    return "exited", "missing verified process group identity"
  end
  local my = M._read_proc_info(vim.uv.os_getpid())
  if my and my.pgid == pgid then
    return "exited", "process group matches editor process group"
  end
  if not pgid_exists(pgid) then
    return "exited", nil
  end
  if not my then
    return "uncertain", "could not read editor process group to verify continuity"
  end
  -- A PGID alone is not an identity: require a matching /proc start time for
  -- its leader or a previously captured member before treating it as ours.
  -- The check and later kill cannot be atomic with POSIX kill(2); a process
  -- can exit and its PID/PGID can be reused in that narrow interval.
  local leader = M._read_proc_info(pgid)
  if leader and type(leader.start_ticks) == "number" then
    if leader.start_ticks ~= leader_start_ticks then
      -- On Linux, PID `pgid` cannot be reused until every process referencing
      -- that PGID has exited and been reaped, so a new start_ticks proves the
      -- original group has exited.
      return "exited", nil
    end
    if leader.pgid == pgid then
      return "alive", nil
    end
  end
  -- Leader exited (or lacked start_ticks / left PGID): a previously captured
  -- member PID + start-time pair can still prove continuity.
  if type(members) == "table" then
    for mpid, mticks in pairs(members) do
      local minfo = M._read_proc_info(mpid)
      if type(mticks) == "number" and minfo and minfo.pgid == pgid and minfo.start_ticks == mticks then
        return "alive", nil
      end
    end
  end
  return "uncertain",
    ("process group %d still has live processes, but neither leader nor any tracked member remains to prove continuity"):format(
      pgid
    )
end

local function group_alive(pgid, leader_start_ticks, members)
  local status, reason = group_status(pgid, leader_start_ticks, members)
  return status == "alive", status, reason
end

local function signal_group(pgid, leader_start_ticks, sig, members)
  if not group_alive(pgid, leader_start_ticks, members) then
    return false
  end
  if type(vim.uv.kill) == "function" then
    local ok = vim.uv.kill(-pgid, sig)
    return ok == 0
  end
  local flag = sig == "sigkill" and "-KILL" or "-TERM"
  vim.fn.system({ "kill", flag, "-" .. tostring(pgid) })
  return vim.v.shell_error == 0
end

local function stop_bg_monitor(monitor)
  if not monitor or monitor.done then
    return
  end
  monitor.done = true
  for bg in pairs(monitor.targets) do
    if bg.drain_monitor == monitor then
      bg.drain_monitor = nil
    end
  end
  monitor.targets = {}
  if monitor.timer then
    local timer = monitor.timer
    monitor.timer = nil
    pcall(function()
      timer:stop()
      timer:close()
    end)
  end
end

local function detach_bg_monitor(bg)
  local monitor = bg and bg.drain_monitor
  if not monitor then
    return
  end
  bg.drain_monitor = nil
  monitor.targets[bg] = nil
  if not next(monitor.targets) then
    stop_bg_monitor(monitor)
  end
end

local function bg_group_status(bg, refresh)
  if type(bg) ~= "table" then
    return "exited", nil
  end
  local status, reason = group_status(bg.pgid, bg.start_ticks, bg.members)
  if status == "exited" then
    bg.uncertain = false
    bg.uncertain_reason = nil
    return "exited", reason
  end
  if status == "uncertain" then
    bg.uncertain = true
    bg.uncertain_reason = reason
    return "uncertain", reason
  end
  bg.uncertain = false
  bg.uncertain_reason = nil
  if refresh and bg.members ~= nil then
    local latest = refresh_verified_members(bg.pgid, bg.start_ticks, bg.sid, bg.members)
    if latest then
      bg.members = latest
    end
  end
  return "alive", nil
end

local function bg_group_alive(bg, refresh)
  local status, reason = bg_group_status(bg, refresh)
  return status == "alive", status, reason
end

local function prune_background_groups(refresh)
  local kept = {}
  for _, bg in ipairs(background_groups) do
    if bg_group_status(bg, refresh) ~= "exited" then
      kept[#kept + 1] = bg
    end
  end
  for i = 1, #background_groups do
    background_groups[i] = nil
  end
  for i, bg in ipairs(kept) do
    background_groups[i] = bg
  end
end

local function record_background_group(seq, pgid, start_ticks, opts)
  opts = opts or {}
  local bg_root = opts.root or state.root
  local prev_members = opts.members or state.pgid_members
  local status, reason = group_status(pgid, start_ticks, prev_members)
  if status == "exited" then
    return false, false
  end
  local members = prev_members
  local uncertain = (status == "uncertain")
  if not uncertain then
    local refreshed = refresh_verified_members(pgid, start_ticks, opts.sid, prev_members)
    if refreshed then
      members = refreshed
    end
  end
  prune_background_groups(false)
  for _, existing in ipairs(background_groups) do
    if existing.seq == seq and existing.pgid == pgid then
      existing.uncertain = uncertain
      existing.uncertain_reason = uncertain and reason or nil
      if members ~= nil then
        existing.members = members
      end
      return true, existing.uncertain
    end
  end
  background_groups[#background_groups + 1] = {
    seq = seq,
    pgid = pgid,
    start_ticks = start_ticks,
    sid = opts.sid,
    members = members,
    root = bg_root,
    canon_root = bg_root and run_config.canonical(bg_root) or nil,
    kind = opts.kind or state.kind,
    exit_code = opts.exit_code,
    stopping = false,
    uncertain = uncertain,
    uncertain_reason = uncertain and reason or nil,
    drain_monitor = nil,
  }
  return true, uncertain
end

local function first_stopping_bg()
  prune_background_groups(false)
  for _, bg in ipairs(background_groups) do
    if bg.stopping and not bg.uncertain then
      return bg
    end
  end
  return nil
end

local function find_background_groups_for_root(canon_root)
  if not canon_root then
    return {}
  end
  prune_background_groups(true)
  local out = {}
  for _, bg in ipairs(background_groups) do
    if bg.canon_root == canon_root then
      out[#out + 1] = bg
    end
  end
  return out
end

local function find_uncertain_bg(canon_root)
  local fallback = nil
  for i = #background_groups, 1, -1 do
    local bg = background_groups[i]
    if bg.uncertain then
      if canon_root and bg.canon_root == canon_root then
        return bg
      end
      if not fallback then
        fallback = bg
      end
    end
  end
  return fallback
end

local function find_live_background_group(seq, pgid, origin_root)
  prune_background_groups(true)
  for _, bg in ipairs(background_groups) do
    if
      not bg.uncertain
      and (seq == nil or bg.seq == seq)
      and (pgid == nil or bg.pgid == pgid)
      and (origin_root == nil or bg.canon_root == origin_root)
    then
      return bg
    end
  end
  return nil
end

local function select_background_targets(canon_root, only_stopping)
  prune_background_groups(true)
  if #background_groups == 0 then
    return nil
  end
  local chosen = nil
  if only_stopping then
    for _, bg in ipairs(background_groups) do
      if bg.stopping and not bg.uncertain then
        chosen = bg
        break
      end
    end
    if not chosen then
      return nil
    end
  else
    if canon_root then
      for i = #background_groups, 1, -1 do
        local bg = background_groups[i]
        if not bg.uncertain and bg.canon_root == canon_root then
          chosen = bg
          break
        end
      end
    end
    if not chosen then
      for i = #background_groups, 1, -1 do
        local bg = background_groups[i]
        if not bg.uncertain then
          chosen = bg
          break
        end
      end
    end
    if not chosen then
      return nil
    end
  end
  local targets = {}
  for _, bg in ipairs(background_groups) do
    if not bg.uncertain and bg.canon_root == chosen.canon_root and (not only_stopping or bg.stopping) then
      targets[#targets + 1] = bg
    end
  end
  return targets, chosen
end

local function is_fg_draining()
  if not state.draining_pgid then
    return false
  end
  local status, reason = group_status(state.draining_pgid, state.draining_start_ticks, state.pgid_members)
  if status ~= "exited" then
    state.pgid_uncertain = (status == "uncertain")
    state.pgid_uncertain_reason = reason
    return true
  end
  state.draining_pgid = nil
  state.draining_start_ticks = nil
  state.pgid_sid = nil
  state.pgid_members = nil
  state.pgid_reason = nil
  state.pgid_uncertain = false
  state.pgid_uncertain_reason = nil
  return false
end

local function is_draining()
  if is_fg_draining() then
    return true
  end
  return first_stopping_bg() ~= nil
end

local function stop_drain_timer()
  if state.drain_timer then
    pcall(function()
      state.drain_timer:stop()
      state.drain_timer:close()
    end)
    state.drain_timer = nil
  end
end

local restart_seq = 0

local function clear_restart_state(expected_op)
  if expected_op ~= nil and state.restart_op ~= expected_op then
    return false
  end
  if state.restart_op then
    state.restart_op.active = false
  end
  state.restarting = false
  state.after_exit = nil
  state.restart_op = nil
  return true
end

local function begin_restart(cb)
  restart_seq = restart_seq + 1
  if state.restart_op then
    state.restart_op.active = false
  end
  local op = {
    id = restart_seq,
    after_exit = cb,
    active = true,
  }
  state.restarting = true
  state.after_exit = cb
  state.restart_op = op
  return op
end

local function monitor_owns_restart(restart_op, allow_legacy_restart)
  if restart_op ~= nil then
    return restart_op.active and state.restarting and state.restart_op == restart_op
  end
  if allow_legacy_restart then
    return state.restarting and state.restart_op == nil
  end
  return false
end

local function signal_pid(pid, sig)
  if type(pid) ~= "number" or pid <= 1 or pid == vim.uv.os_getpid() then
    return false
  end
  if type(vim.uv.kill) == "function" then
    local ok = vim.uv.kill(pid, sig)
    return ok == 0
  end
  local flag = sig == "sigkill" and "-KILL" or "-TERM"
  vim.fn.system({ "kill", flag, tostring(pid) })
  return vim.v.shell_error == 0
end

local function kill_tree(pid, sig, expected_start_ticks)
  if type(pid) ~= "number" or pid <= 1 or pid == vim.uv.os_getpid() then
    return false
  end
  local info = M._read_proc_info(pid)
  if
    type(expected_start_ticks) ~= "number"
    or not info
    or type(info.start_ticks) ~= "number"
    or info.start_ticks ~= expected_start_ticks
  then
    return false
  end
  local ok, children = pcall(vim.fn.systemlist, { "pgrep", "-P", tostring(pid) })
  if ok and type(children) == "table" then
    for _, child in ipairs(children) do
      local child_pid = tonumber(vim.trim(child))
      if child_pid and child_pid > 1 and child_pid ~= vim.uv.os_getpid() then
        local cinfo = M._read_proc_info(child_pid)
        if
          cinfo
          and cinfo.ppid == pid
          and type(cinfo.start_ticks) == "number"
          and cinfo.start_ticks >= info.start_ticks
        then
          kill_tree(child_pid, sig, cinfo.start_ticks)
        end
      end
    end
  end
  local latest = M._read_proc_info(pid)
  if not latest or latest.start_ticks ~= expected_start_ticks then
    return false
  end
  local uv_sig = (sig == "KILL" or sig == "sigkill") and "sigkill" or "sigterm"
  return signal_pid(pid, uv_sig)
end

---Safely terminate the running job or draining process group.
local function terminate_active(sig)
  sig = sig or "sigterm"
  local pgid = state.pgid or state.draining_pgid
  local start_ticks = state.pgid and state.pgid_start_ticks or state.draining_start_ticks
  if pgid then
    local status, reason = group_status(pgid, start_ticks, state.pgid_members)
    if status == "uncertain" then
      state.pgid_uncertain = true
      state.pgid_uncertain_reason = reason
      return false
    end
    if status == "alive" then
      state.pgid_uncertain = false
      state.pgid_uncertain_reason = nil
      if state.pgid_members ~= nil then
        local latest = refresh_verified_members(pgid, start_ticks, state.pgid_sid, state.pgid_members)
        if latest then
          state.pgid_members = latest
        end
      end
      signal_group(pgid, start_ticks, sig, state.pgid_members)
    end
  end
  local job = state.job
  if job then
    if not pgid then
      local ok_pid, pid = pcall(vim.fn.jobpid, job)
      if ok_pid and pid and pid > 1 and pid == state.pid then
        kill_tree(pid, sig == "sigkill" and "KILL" or "TERM", state.pid_start_ticks)
      end
    end
    if sig == "sigterm" then
      pcall(vim.fn.jobstop, job)
    end
  end
  return true
end

local function start_drain_monitor(seq, pgid, start_ticks, opts)
  stop_drain_timer()
  opts = opts or {}
  local restart_op = opts.restart_op
  local allow_legacy_restart = (
    restart_op == nil
    and not opts.background
    and state.restarting
    and state.restart_op == nil
  )
  local timer = vim.uv.new_timer()
  if not timer then
    if opts.background and not state.stopping and not state.restarting then
      if pgid then
        record_background_group(seq, pgid, start_ticks, opts)
      end
      state.draining_pgid = nil
      state.draining_start_ticks = nil
      state.pgid_sid = nil
      state.pgid_members = nil
      state.pgid_reason = nil
      state.pgid_uncertain = false
      state.pgid_uncertain_reason = nil
    elseif monitor_owns_restart(restart_op, allow_legacy_restart) then
      clear_restart_state(restart_op)
    end
    return
  end
  state.drain_timer = timer
  local start_ms = vim.uv.now()
  local sigkill_sent = false

  timer:start(
    50,
    50,
    vim.schedule_wrap(function()
      if state.drain_timer ~= timer then
        return
      end
      if state.seq ~= seq then
        stop_drain_timer()
        return
      end

      local active_pgid = pgid or state.draining_pgid or state.pgid
      local active_ticks = start_ticks or state.draining_start_ticks or state.pgid_start_ticks
      local still_running = state.running
      local status, uncertain_reason = "exited", nil
      if active_pgid ~= nil then
        status, uncertain_reason = group_status(active_pgid, active_ticks, opts.members or state.pgid_members)
      end

      if not still_running and status == "exited" then
        stop_drain_timer()
        state.pgid = nil
        state.pgid_start_ticks = nil
        state.pgid_sid = nil
        state.pgid_members = nil
        state.pgid_reason = nil
        state.pgid_uncertain = false
        state.pgid_uncertain_reason = nil
        state.draining_pgid = nil
        state.draining_start_ticks = nil
        state.stopping = first_stopping_bg() ~= nil
        if monitor_owns_restart(restart_op, allow_legacy_restart) then
          local cb = state.after_exit or (restart_op and restart_op.after_exit)
          clear_restart_state(restart_op)
          if cb then
            cb()
          end
        end
        return
      end

      if status == "alive" then
        state.pgid_uncertain = false
        state.pgid_uncertain_reason = nil
        local cur_members = opts.members or state.pgid_members
        if cur_members ~= nil then
          local updated = refresh_verified_members(active_pgid, active_ticks, opts.sid or state.pgid_sid, cur_members)
          if updated then
            if opts.members ~= nil then
              opts.members = updated
            end
            state.pgid_members = updated
          end
        end
      elseif status == "uncertain" then
        state.pgid_uncertain = true
        state.pgid_uncertain_reason = uncertain_reason
      end

      local elapsed = vim.uv.now() - start_ms

      -- Ordinary leader exit with surviving background group: monitor briefly
      -- without killing, then release the build lock while retaining safe PGID
      -- tracking so the user can still inspect and stop it later.
      if opts.background and not state.stopping and not state.restarting then
        local bg_grace_ms = M._background_grace_ms or 500
        if elapsed >= bg_grace_ms then
          stop_drain_timer()
          local tracked, tracked_uncertain = false, false
          if active_pgid then
            tracked, tracked_uncertain = record_background_group(seq, active_pgid, active_ticks, opts)
          end
          state.draining_pgid = nil
          state.draining_start_ticks = nil
          state.pgid_sid = nil
          state.pgid_members = nil
          state.pgid_reason = nil
          state.pgid_uncertain = false
          state.pgid_uncertain_reason = nil
          if tracked then
            if tracked_uncertain then
              ui.notify(
                ("process exited (%s) with surviving process group (pgid %s) whose identity became uncertain — released from build lock without signaling (verify and stop manually before Restart)"):format(
                  tostring(opts.exit_code),
                  tostring(active_pgid)
                ),
                vim.log.levels.WARN
              )
            else
              ui.notify(
                ("process exited (%s) with surviving background group (pgid %s) — released from build lock without killing (use Stop to terminate)"):format(
                  tostring(opts.exit_code),
                  tostring(active_pgid)
                ),
                vim.log.levels.WARN
              )
            end
          end
        end
        return
      end

      local grace_ms = M._stop_grace_ms or 1000
      local timeout_ms = M._restart_timeout_ms or 5000

      if not sigkill_sent and elapsed >= grace_ms then
        if active_pgid then
          if status == "alive" then
            if signal_group(active_pgid, active_ticks, "sigkill", opts.members or state.pgid_members) then
              sigkill_sent = true
            end
          end
        elseif state.pid then
          if kill_tree(state.pid, "KILL", state.pid_start_ticks) then
            sigkill_sent = true
          end
        end
      end

      if elapsed >= timeout_ms then
        stop_drain_timer()
        local was_restarting = monitor_owns_restart(restart_op, allow_legacy_restart)
        if was_restarting then
          clear_restart_state(restart_op)
        end
        state.stopping = first_stopping_bg() ~= nil
        if was_restarting then
          if status == "uncertain" then
            ui.notify(
              "previous process group identity became uncertain while stopping — restart cancelled; verify and stop it manually",
              vim.log.levels.WARN
            )
          else
            ui.notify("previous process did not exit in time — restart cancelled", vim.log.levels.WARN)
          end
        end
      end
    end)
  )
end

local function start_bg_drain_monitor(targets, opts)
  opts = opts or {}
  local restart_op = opts.restart_op
  if type(targets) ~= "table" or #targets == 0 then
    if restart_op then
      clear_restart_state(restart_op)
    end
    return
  end
  local timer = vim.uv.new_timer()
  if not timer then
    for _, bg in ipairs(targets) do
      bg.stopping = false
    end
    if restart_op then
      clear_restart_state(restart_op)
    end
    state.stopping = first_stopping_bg() ~= nil
    return
  end

  local monitor = {
    timer = timer,
    targets = {},
    done = false,
    restart_op = restart_op,
  }
  for _, bg in ipairs(targets) do
    detach_bg_monitor(bg)
    bg.drain_monitor = monitor
    monitor.targets[bg] = true
  end

  local start_ms = vim.uv.now()
  local sigkill_sent = {}

  local function poll()
    if monitor.done then
      return
    end
    prune_background_groups(false)
    local live = {}
    local uncertain = {}
    local exited = {}
    for bg in pairs(monitor.targets) do
      local status = bg_group_status(bg, true)
      if status == "alive" then
        live[#live + 1] = bg
      elseif status == "uncertain" then
        uncertain[#uncertain + 1] = bg
      else
        exited[#exited + 1] = bg
      end
    end
    for _, bg in ipairs(exited) do
      monitor.targets[bg] = nil
      sigkill_sent[bg] = nil
      if bg.drain_monitor == monitor then
        bg.drain_monitor = nil
      end
    end
    if #live == 0 and #uncertain == 0 then
      stop_bg_monitor(monitor)
      state.stopping = first_stopping_bg() ~= nil
      if monitor_owns_restart(monitor.restart_op, false) then
        local cb = state.after_exit or monitor.restart_op.after_exit
        clear_restart_state(monitor.restart_op)
        if cb then
          cb()
        end
      end
      return
    end

    local elapsed = vim.uv.now() - start_ms
    local grace_ms = M._stop_grace_ms or 1000
    local timeout_ms = M._restart_timeout_ms or 5000

    if elapsed >= grace_ms then
      for _, bg in ipairs(live) do
        if not sigkill_sent[bg] then
          if signal_group(bg.pgid, bg.start_ticks, "sigkill", bg.members) then
            sigkill_sent[bg] = true
          end
        end
      end
    end

    if elapsed >= timeout_ms then
      for bg in pairs(monitor.targets) do
        if bg.drain_monitor == monitor then
          bg.stopping = false
        end
      end
      stop_bg_monitor(monitor)
      local was_restarting = monitor_owns_restart(monitor.restart_op, false)
      if was_restarting then
        clear_restart_state(monitor.restart_op)
      end
      state.stopping = first_stopping_bg() ~= nil
      if was_restarting then
        if #uncertain > 0 and #live == 0 then
          ui.notify(
            "previous process group identity became uncertain while stopping — restart cancelled; verify and stop it manually",
            vim.log.levels.WARN
          )
        else
          ui.notify("previous process did not exit in time — restart cancelled", vim.log.levels.WARN)
        end
      elseif #uncertain > 0 and #live == 0 then
        ui.notify(
          "process group identity became uncertain while stopping — automatic SIGKILL skipped; verify and stop it manually",
          vim.log.levels.WARN
        )
      end
    end
  end

  timer:start(50, 50, vim.schedule_wrap(poll))
end

local function finish(seq, code, redactions)
  if seq ~= state.seq or not state.running then
    return
  end
  local buf = state.buf
  local pgid = state.pgid
  local start_ticks = state.pgid_start_ticks
  local sid = state.pgid_sid
  local members = pgid and state.pgid_members or nil
  if pgid then
    local refreshed = refresh_verified_members(pgid, start_ticks, sid, members)
    if refreshed then
      members = refreshed
      state.pgid_members = refreshed
    end
  end
  local root = state.root
  local kind = state.kind

  drain_append(seq, buf)

  state.running = false
  state.job = nil
  state.pid = nil
  state.pid_start_ticks = nil
  state.cmd = nil
  state.pgid = nil
  state.pgid_start_ticks = nil
  state.pgid_sid = nil
  state.status = code == 0 and "success" or "failed"

  local limit = math.max(1, math.floor(tonumber(M._max_line_bytes) or 65536))
  for _, stream in ipairs({ "stdout", "stderr" }) do
    local st = ensure_stream_state(stream)
    if st.len > 0 then
      local tail = table.concat(st.chunks)
      if st.len > limit then
        local truncated_lines = {}
        emit_truncated(tail, redactions, limit, limit, truncated_lines)
        append(buf, truncated_lines)
        notify_truncated(seq, buf, stream, limit, true)
      else
        append(buf, { run_config.redact(tail, redactions) })
      end
    end
    reset_stream_state(stream)
  end

  append(buf, {
    "",
    ("[%s] exit %s — %s"):format(
      state.kind or "build",
      tostring(code),
      state.status == "success" and "sucesso" or "falha"
    ),
  })

  if state.kind ~= "run_main" and state.kind ~= "spring" then
    fill_quickfix(buf)
  end

  local msg = ("[%s] %s — exit %s"):format(state.kind or "build", state.status, tostring(code))
  ui.notify(
    run_config.redact(msg, redactions),
    state.status == "success" and vim.log.levels.INFO or vim.log.levels.ERROR
  )

  state.redactions = {}

  local status, uncertain_reason = "exited", nil
  if pgid then
    status, uncertain_reason = group_status(pgid, start_ticks, members)
  end

  if pgid and status ~= "exited" then
    state.draining_pgid = pgid
    state.draining_start_ticks = start_ticks
    state.pgid_uncertain = (status == "uncertain")
    state.pgid_uncertain_reason = uncertain_reason
    if not state.drain_timer then
      if state.stopping or state.restarting then
        start_drain_monitor(seq, pgid, start_ticks, { restart_op = state.restart_op })
      else
        start_drain_monitor(seq, pgid, start_ticks, {
          background = true,
          exit_code = code,
          root = root,
          kind = kind,
          sid = sid,
          members = members,
        })
      end
    end
    return
  end

  stop_drain_timer()
  state.pgid_members = nil
  state.pgid_reason = nil
  state.pgid_uncertain = false
  state.pgid_uncertain_reason = nil
  state.draining_pgid = nil
  state.draining_start_ticks = nil
  state.stopping = first_stopping_bg() ~= nil
  local cb = state.after_exit or (state.restart_op and state.restart_op.after_exit)
  clear_restart_state()
  if cb then
    cb()
  end
end

---Start a process. `cmd` is a list; `root` is the originating project — the
---menu never treats this process as the current one.
---When `opts.use_env` is true, loads optional `root/.env` into `jobstart` env
---without logging, notifying, displaying, or persisting secret values.
---@param kind string
---@param cmd string[]
---@param cwd string
---@param root string|nil
---@param opts { use_env: boolean|nil, _secret_warned: boolean|nil, user_args: string[]|nil, build_args: string[]|nil }|nil
local function start(kind, cmd, cwd, root, opts)
  opts = opts or {}
  if state.running then
    ui.notify("a process is already running — stop it before starting another", vim.log.levels.WARN)
    return
  end
  if is_draining() then
    ui.notify("previous process group is still exiting — wait before starting another", vim.log.levels.WARN)
    return
  end
  prune_background_groups(false)
  clear_restart_state()

  local project_root = root or cwd
  local canon_root = run_config.canonical(project_root)
  local env_res = run_config.load_env(canon_root)
  local env_map = nil
  local env_keys = {}
  local redactions = {}

  if opts.use_env then
    for _, warn in ipairs(env_res.warnings) do
      ui.notify(warn, vim.log.levels.WARN)
    end
  end
  if env_res.exists and next(env_res.env) ~= nil then
    redactions = run_config.collect_redactions(env_res.env)
    if opts.use_env then
      env_map = env_res.env
      env_keys = env_res.keys
    end
  end

  local user_args = opts.user_args
  if user_args == nil then
    user_args = {}
    for i = 2, #cmd do
      user_args[#user_args + 1] = cmd[i]
    end
  end
  local cmd_has_secret = (opts._force_secret == true)
    or (env_res.exists and run_config.overlaps_env(user_args, env_res.env))
  local safe_runner = run_config.redact(cmd[1] or "", redactions)
  -- When user args overlap `.env`, redact the command arguments wholesale so
  -- secrets spanning multiple arguments or wrapped in quotes never leave
  -- reconstructable fragments in `state.cmd`, headers, or notifications.
  local redacted_cmd = safe_runner ~= "" and { safe_runner, "[REDACTED]" } or { "[REDACTED]" }
  local cmd_display = cmd_has_secret and table.concat(redacted_cmd, " ")
    or run_config.redact(table.concat(cmd, " "), redactions)
  local buf = open_output(kind)
  local header = {
    ("$ %s"):format(cmd_display),
    ("cwd: %s"):format(cwd),
  }
  if opts.use_env and #env_keys > 0 then
    header[#header + 1] = ("env: .env loaded (%d variable(s), values hidden)"):format(#env_keys)
  end
  header[#header + 1] = ""
  append(buf, header)

  local full = cmd
  state.seq = state.seq + 1
  local seq = state.seq
  reset_all_streams()
  local prev_win = vim.api.nvim_get_current_win() ---@type integer|nil
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == context_buf() then
      prev_win = win
    end
  end

  local job_opts = {
    cwd = cwd,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      feed(seq, buf, "stdout", data, redactions)
    end,
    on_stderr = function(_, data)
      feed(seq, buf, "stderr", data, redactions)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        finish(seq, code, redactions)
      end)
    end,
  }
  if env_map then
    job_opts.env = env_map
  end

  local job = vim.fn.jobstart(full, job_opts)

  if job <= 0 then
    ui.notify("could not start: " .. cmd_display, vim.log.levels.ERROR)
    return
  end

  local ok_pid, job_pid = pcall(vim.fn.jobpid, job)
  local pid = ok_pid and job_pid or nil
  local pgid, start_ticks, pgid_reason = M._verify_own_pgid(pid)
  local pinfo = pid and M._read_proc_info(pid) or nil
  state.job = job
  state.pid = pid
  state.pid_start_ticks = pinfo and pinfo.start_ticks or nil
  state.pgid = pgid
  state.pgid_start_ticks = start_ticks
  state.pgid_sid = (pgid and pinfo and pinfo.pgid == pgid) and pinfo.sid or nil
  state.pgid_members = pgid
      and (refresh_verified_members(pgid, start_ticks, state.pgid_sid, { [pid] = start_ticks }) or {
        [pid] = start_ticks,
      })
    or nil
  state.pgid_reason = pgid_reason
  state.pgid_uncertain = false
  state.pgid_uncertain_reason = nil
  state.draining_pgid = nil
  state.draining_start_ticks = nil
  state.stopping = false
  state.buf = buf
  state.last_output = buf
  state.kind = kind
  state.cmd = cmd_has_secret and redacted_cmd or cmd
  state.cwd = cwd
  state.root = project_root
  state.last_output_root = project_root
  state.running = true
  state.status = "running"
  state.redactions = redactions

  -- return focus to the code window after opening the output buffer
  if prev_win and vim.api.nvim_win_is_valid(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end

  -- Record non-secret repeat/restart metadata ONLY after successful launch.
  if cmd_has_secret then
    if not opts._secret_warned then
      ui.notify(
        "command arguments overlap with .env values (including short substrings) — not persisted or recorded for Repeat/Restart",
        vim.log.levels.WARN
      )
    end
  else
    last_runs[canon_root] = {
      kind = kind,
      cmd = vim.deepcopy(cmd),
      cwd = cwd,
      root = project_root,
      use_env = opts.use_env == true,
    }
    if type(opts.build_args) == "table" and #opts.build_args > 0 then
      last_builds[canon_root] = vim.deepcopy(opts.build_args)
      local ok_save_build, save_build_err = run_config.save_last_build(canon_root, opts.build_args)
      if not ok_save_build and save_build_err then
        ui.notify(save_build_err, vim.log.levels.WARN)
      end
    end
  end

  ui.notify(
    ("%s started (project %s)\n$ %s\nin %s"):format(kind, vim.fs.basename(state.root), cmd_display, cwd),
    vim.log.levels.INFO
  )
end

---Stop the current process (and only its process group), or a tracked surviving
---background process group. When the process belongs to another project,
---require an explicit user choice — never silently kill a job from a project
---other than the current buffer.
---@param confirmed boolean|table|nil
function M.stop(confirmed)
  local current_root = project.root(context_buf())
  local cur_canon = current_root and run_config.canonical(current_root) or nil
  local active_root = state.root and run_config.canonical(state.root) or nil
  local fg_draining = is_fg_draining()
  local fg_active = (state.running and state.job ~= nil) or fg_draining
  local fg_pgid = state.pgid or state.draining_pgid
  if fg_active and fg_pgid then
    local fg_ticks = state.pgid and state.pgid_start_ticks or state.draining_start_ticks
    local fg_status, fg_uncertain_reason = group_status(fg_pgid, fg_ticks, state.pgid_members)
    if fg_status == "uncertain" then
      state.pgid_uncertain = true
      state.pgid_uncertain_reason = fg_uncertain_reason
    elseif fg_status == "alive" then
      state.pgid_uncertain = false
      state.pgid_uncertain_reason = nil
      if state.pgid_members ~= nil then
        local latest = refresh_verified_members(fg_pgid, fg_ticks, state.pgid_sid, state.pgid_members)
        if latest then
          state.pgid_members = latest
        end
      end
    end
  end

  if fg_active then
    if type(confirmed) == "table" then
      if
        confirmed.is_background
        or state.seq ~= confirmed.seq
        or active_root ~= confirmed.origin_root
        or (confirmed.context_root ~= nil and cur_canon ~= confirmed.context_root)
      then
        ui.notify("stop confirmation is stale — process or project changed", vim.log.levels.WARN)
        return
      end
    end

    if state.pgid_uncertain then
      clear_restart_state()
      state.stopping = first_stopping_bg() ~= nil
      ui.notify(
        ("cannot automatically stop process group %s: %s — verify and stop it manually"):format(
          tostring(fg_pgid),
          state.pgid_uncertain_reason or "identity could not be verified"
        ),
        vim.log.levels.WARN
      )
      return
    end

    local from_other_project = active_root ~= nil and cur_canon ~= nil and active_root ~= cur_canon
    if from_other_project and not confirmed then
      local origin = vim.fs.basename(state.root)
      local token = {
        seq = state.seq,
        origin_root = active_root,
        context_root = cur_canon,
      }
      ui.pick_one(
        {
          ("No — keep the %s project process"):format(origin),
          ("Yes — stop the %s project process"):format(origin),
        },
        "Java: Build — process belongs to another project",
        function(choice)
          if choice and choice:find("^Yes") then
            M.stop(token)
          elseif choice then
            local now_root = project.root(context_buf())
            local now_canon = now_root and run_config.canonical(now_root) or nil
            local still_fg = (state.running and state.job ~= nil) or is_fg_draining()
            local still_root = state.root and run_config.canonical(state.root) or nil
            local still_bg = (not still_fg and state.seq == token.seq)
                and find_live_background_group(token.seq, nil, token.origin_root)
              or nil
            if
              ((still_fg and state.seq == token.seq and still_root == token.origin_root) or still_bg)
              and (token.context_root == nil or now_canon == token.context_root)
            then
              ui.notify(("the %s project process was kept running"):format(origin), vim.log.levels.INFO)
            else
              ui.notify("stop confirmation is stale — process or project changed", vim.log.levels.WARN)
            end
          end
        end
      )
      return
    end

    local was_stopping = state.stopping
    clear_restart_state()
    state.stopping = true
    terminate_active((not state.running and fg_draining and was_stopping) and "sigkill" or "sigterm")
    start_drain_monitor(
      state.seq,
      state.pgid or state.draining_pgid,
      state.pgid_start_ticks or state.draining_start_ticks
    )
    ui.notify(
      from_other_project and ("the %s project process was stopped"):format(vim.fs.basename(state.root))
        or "process stopped",
      vim.log.levels.INFO
    )
    return
  end

  local function resolve_confirmed_bg_targets(token)
    if type(token) ~= "table" or not token.is_background or type(token.targets) ~= "table" then
      return nil
    end
    prune_background_groups(true)
    local resolved = {}
    for _, identity in ipairs(token.targets) do
      for _, bg in ipairs(background_groups) do
        if
          not bg.uncertain
          and bg.seq == identity.seq
          and bg.pgid == identity.pgid
          and bg.canon_root == identity.origin_root
        then
          if bg.start_ticks ~= identity.start_ticks then
            return nil
          end
          resolved[#resolved + 1] = bg
          break
        end
      end
    end
    if #resolved == 0 then
      return nil
    end
    return resolved, resolved[1]
  end

  local targets, chosen
  if type(confirmed) == "table" then
    if confirmed.context_root ~= nil and cur_canon ~= confirmed.context_root then
      ui.notify("stop confirmation is stale — process or project changed", vim.log.levels.WARN)
      return
    end
    if confirmed.is_background then
      targets, chosen = resolve_confirmed_bg_targets(confirmed)
    elseif state.seq == confirmed.seq then
      local match = find_live_background_group(confirmed.seq, nil, confirmed.origin_root)
      if match then
        targets = { match }
        chosen = match
      end
    end
    if not targets or #targets == 0 or not chosen then
      ui.notify("stop confirmation is stale — process or project changed", vim.log.levels.WARN)
      return
    end
  else
    targets, chosen = select_background_targets(cur_canon, true)
    if not targets or #targets == 0 then
      targets, chosen = select_background_targets(cur_canon, false)
    end
  end

  if not targets or #targets == 0 or not chosen then
    local uncertain_bg = find_uncertain_bg(cur_canon)
    if uncertain_bg then
      ui.notify(
        ("no Java process is running (tracked process group %s identity could not be verified and was not signaled — verify and stop it manually)"):format(
          tostring(uncertain_bg.pgid)
        ),
        vim.log.levels.WARN
      )
    else
      ui.notify("no Java process is running", vim.log.levels.WARN)
    end
    return
  end

  local bg_canon = chosen.canon_root
  local from_other_project = bg_canon ~= nil and cur_canon ~= nil and bg_canon ~= cur_canon
  if from_other_project and not confirmed then
    local origin = vim.fs.basename(chosen.root)
    local token = {
      is_background = true,
      seq = chosen.seq,
      pgid = chosen.pgid,
      origin_root = bg_canon,
      context_root = cur_canon,
      targets = {},
    }
    for _, bg in ipairs(targets) do
      token.targets[#token.targets + 1] = {
        seq = bg.seq,
        pgid = bg.pgid,
        origin_root = bg.canon_root,
        start_ticks = bg.start_ticks,
      }
    end
    ui.pick_one(
      {
        ("No — keep the %s project background process"):format(origin),
        ("Yes — stop the %s project background process"):format(origin),
      },
      "Java: Build — background process belongs to another project",
      function(choice)
        if choice and choice:find("^Yes") then
          M.stop(token)
        elseif choice then
          local now_root = project.root(context_buf())
          local now_canon = now_root and run_config.canonical(now_root) or nil
          local still_targets = resolve_confirmed_bg_targets(token)
          if still_targets and (token.context_root == nil or now_canon == token.context_root) then
            ui.notify(("the %s project background process was kept running"):format(origin), vim.log.levels.INFO)
          else
            ui.notify("stop confirmation is stale — process or project changed", vim.log.levels.WARN)
          end
        end
      end
    )
    return
  end

  clear_restart_state()
  state.stopping = true
  for _, bg in ipairs(targets) do
    local sig = bg.stopping and "sigkill" or "sigterm"
    bg.stopping = true
    signal_group(bg.pgid, bg.start_ticks, sig, bg.members)
  end
  start_bg_drain_monitor(targets)
  ui.notify(
    from_other_project and ("the %s project background process was stopped"):format(vim.fs.basename(chosen.root))
      or "background process stopped",
    vim.log.levels.INFO
  )
end

---Restart the recorded command of the current project (stop if running, then re-run).
---When a process from another project is running, asks for explicit confirmation.
---@param confirmed boolean|table|nil
function M.restart(confirmed)
  local root = project.root(context_buf())
  local canon_root = root and run_config.canonical(root) or nil
  local fg_draining = is_fg_draining()
  local fg_active = (state.running and state.job ~= nil) or fg_draining
  local active_root = state.root and run_config.canonical(state.root) or nil

  if type(confirmed) == "table" then
    if
      not fg_active
      or state.seq ~= confirmed.seq
      or active_root ~= confirmed.origin_root
      or canon_root ~= confirmed.target_root
    then
      ui.notify("restart confirmation is stale — process or project changed", vim.log.levels.WARN)
      return
    end
  end

  if not root then
    ui.notify("no Maven/Gradle project (pom.xml, build.gradle) from this buffer", vim.log.levels.WARN)
    return
  end

  local rec = last_runs[canon_root]
  if not rec then
    ui.notify("no previous command in this project", vim.log.levels.WARN)
    return
  end

  if state.restarting then
    ui.notify("a restart is already in progress", vim.log.levels.WARN)
    return
  end

  local function launch_recorded()
    start(rec.kind, vim.deepcopy(rec.cmd), rec.cwd, rec.root, { use_env = rec.use_env })
  end

  -- A restart targets the destination project's full process set. This also
  -- runs after a confirmed cross-project foreground stop, where the target
  -- may already have a surviving background group of its own.
  local function find_uncertain_own_bg()
    local own_bgs = find_background_groups_for_root(canon_root)
    for _, bg in ipairs(own_bgs) do
      if bg.uncertain then
        return bg, own_bgs
      end
    end
    return nil, own_bgs
  end

  local function launch()
    local uncertain_bg, own_bgs = find_uncertain_own_bg()
    if uncertain_bg then
      ui.notify(
        ("cannot automatically restart: %s — verify and stop it manually before restarting"):format(
          uncertain_bg.uncertain_reason
            or ("process group %s identity could not be verified"):format(tostring(uncertain_bg.pgid))
        ),
        vim.log.levels.WARN
      )
      return
    end
    if #own_bgs == 0 then
      launch_recorded()
      return
    end
    local op = begin_restart(launch_recorded)
    state.stopping = true
    for _, bg in ipairs(own_bgs) do
      bg.stopping = true
      signal_group(bg.pgid, bg.start_ticks, "sigterm", bg.members)
    end
    start_bg_drain_monitor(own_bgs, { restart_op = op })
  end

  local uncertain_own = find_uncertain_own_bg()
  if uncertain_own then
    ui.notify(
      ("cannot automatically restart: %s — verify and stop it manually before restarting"):format(
        uncertain_own.uncertain_reason
          or ("process group %s identity could not be verified"):format(tostring(uncertain_own.pgid))
      ),
      vim.log.levels.WARN
    )
    return
  end

  if not fg_active then
    local stopping_bg = first_stopping_bg()
    if stopping_bg and stopping_bg.canon_root ~= canon_root then
      ui.notify("previous process group is still exiting — wait before starting another", vim.log.levels.WARN)
      return
    end
    launch()
    return
  end

  local target_pgid = state.pgid or state.draining_pgid
  if target_pgid then
    local target_ticks = state.pgid and state.pgid_start_ticks or state.draining_start_ticks
    local fg_status, fg_uncertain_reason = group_status(target_pgid, target_ticks, state.pgid_members)
    if fg_status == "uncertain" then
      state.pgid_uncertain = true
      state.pgid_uncertain_reason = fg_uncertain_reason
    elseif fg_status == "alive" then
      state.pgid_uncertain = false
      state.pgid_uncertain_reason = nil
      if state.pgid_members ~= nil then
        local latest = refresh_verified_members(target_pgid, target_ticks, state.pgid_sid, state.pgid_members)
        if latest then
          state.pgid_members = latest
        end
      end
    end
  end
  if not target_pgid or state.pgid_uncertain then
    local reason = state.pgid_uncertain_reason or state.pgid_reason or "process group could not be verified"
    ui.notify(
      ("cannot automatically restart running process: %s — stop it manually before restarting"):format(reason),
      vim.log.levels.WARN
    )
    return
  end

  local from_other_project = active_root ~= nil and active_root ~= canon_root
  if from_other_project and not confirmed then
    local origin = vim.fs.basename(state.root)
    local token = {
      seq = state.seq,
      origin_root = active_root,
      target_root = canon_root,
    }
    ui.pick_one(
      {
        ("No — keep the %s project process"):format(origin),
        ("Yes — stop the %s project process and restart"):format(origin),
      },
      "Java: Build — process belongs to another project",
      function(choice)
        if choice and choice:find("^Yes") then
          M.restart(token)
        elseif choice then
          local cur_root = project.root(context_buf())
          local cur_canon = cur_root and run_config.canonical(cur_root) or nil
          local still_active = (state.running and state.job ~= nil) or is_fg_draining()
          local still_root = state.root and run_config.canonical(state.root) or nil
          if
            still_active
            and state.seq == token.seq
            and still_root == token.origin_root
            and cur_canon == token.target_root
          then
            ui.notify(("the %s project process was kept running"):format(origin), vim.log.levels.INFO)
          else
            ui.notify("restart confirmation is stale — process or project changed", vim.log.levels.WARN)
          end
        end
      end
    )
    return
  end

  local seq = state.seq
  local target_ticks = state.pgid and state.pgid_start_ticks or state.draining_start_ticks
  local op = begin_restart(launch)
  state.stopping = true
  terminate_active("sigterm")
  start_drain_monitor(seq, target_pgid, target_ticks, { restart_op = op })
end

---Show the last output (from any project — the origin is identified in the menu).
function M.show_output()
  local buf = state.last_output
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    ui.notify("no previous output", vim.log.levels.WARN)
    return
  end
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, 14)
end

-- ---------- argumentos / comandos ----------

---Scope arguments (module) for Maven/Gradle. Maven uses the module path
---relative to the aggregator (`-pl services/api -am`); Gradle uses the logical
---project path (`:services:api:compile`), not the directory path.
local function scope_args(tool, root, module, args)
  if not module or module == root then
    return args
  end
  local rel = vim.fs.relpath(root, module)
  if tool == "maven" then
    local scoped = { "-pl", rel, "-am" }
    vim.list_extend(scoped, args)
    return scoped
  end
  local logical = project.gradle_path(root, module)
  local scoped = {}
  for _, arg in ipairs(args) do
    if arg:sub(1, 1) == "-" then
      scoped[#scoped + 1] = arg
    else
      scoped[#scoped + 1] = (logical .. ":" .. arg)
    end
  end
  return scoped
end

---Run build args at the root (with module scope).
local function run_build(tool, root, module, args, label)
  local scoped = scope_args(tool.tool, root, module, args)
  local cmd = { tool.runner }
  vim.list_extend(cmd, scoped)
  start(label or args[1], cmd, root, root, {
    user_args = args,
    build_args = scoped,
  })
end

---Runtime classpath + project JDK via jdtls (source-buffer client).
---@param uri string
---@param bufnr number
local function classpath_for(uri, bufnr, cb)
  local client = lsp.client_or_reason(bufnr)
  if not client then
    return cb(nil, client or "jdtls is not attached to this buffer")
  end

  client:request("workspace/executeCommand", {
    command = "java.project.getClasspaths",
    arguments = { uri, { scope = "runtime" } },
  }, function(err, result)
    vim.schedule(function()
      if err or type(result) ~= "table" or type(result.classpaths) ~= "table" then
        return cb(nil, "could not resolve the classpath through jdtls")
      end
      local cp = vim.deepcopy(result.classpaths)
      if type(result.modulepaths) == "table" then
        vim.list_extend(cp, result.modulepaths)
      end
      cb({
        classpaths = cp,
        project_root = type(result.projectRoot) == "string" and vim.uri_to_fname(result.projectRoot) or nil,
      })
    end)
  end, bufnr)

  client:request("workspace/executeCommand", {
    command = "java.project.getSettings",
    arguments = { uri, { "org.eclipse.jdt.ls.core.vm.location" } },
  }, function(err, result)
    -- remember the JDK for the next start; on failure, use java from PATH
    if not err and type(result) == "table" then
      local vm = result["org.eclipse.jdt.ls.core.vm.location"]
      if type(vm) == "string" and vm ~= "" then
        state.java = (is_file(vm .. "/bin/java") and (vm .. "/bin/java")) or vm
      end
    end
  end, bufnr)
end

local function java_bin()
  if state.java and is_exec(state.java) then
    return state.java
  end
  local home = os.getenv("JAVA_HOME")
  if home and is_exec(home .. "/bin/java") then
    return home .. "/bin/java"
  end
  return vim.fn.exepath("java")
end

local function split_args(text)
  return run_config.split_args(text)
end

-- ---------- operations ----------

local function choose_profile(scan, saved_profile, cb)
  saved_profile = vim.trim(saved_profile or "")
  if #scan.profiles == 0 then
    ui.ask("Java: Build — Spring profile (optional): ", saved_profile, function(value)
      if value ~= nil then
        cb(vim.trim(value))
      end
    end)
    return
  end

  local labels, by_label = {}, {}
  local seen = {}
  if saved_profile ~= "" then
    local label = saved_profile .. "  (saved)"
    labels[#labels + 1] = label
    by_label[label] = saved_profile
    seen[saved_profile] = true
  end
  for _, p in ipairs(scan.profiles) do
    if not seen[p] then
      seen[p] = true
      labels[#labels + 1] = p
      by_label[p] = p
    end
  end
  local none_label = "(none — default)"
  labels[#labels + 1] = none_label
  by_label[none_label] = ""
  local custom_label = "Custom profile…"
  labels[#labels + 1] = custom_label
  by_label[custom_label] = "__custom__"

  ui.pick_one(labels, "Java: Build — Spring profile", function(choice)
    local picked = by_label[choice]
    if picked == nil then
      return
    end
    if picked == "__custom__" then
      ui.ask("Java: Build — Spring profile (optional): ", saved_profile, function(value)
        if value ~= nil then
          cb(vim.trim(value))
        end
      end)
      return
    end
    cb(picked)
  end)
end

local function ask_module(root, bufnr, cb)
  local modules = project.modules(root)
  if #modules <= 1 then
    return cb(root)
  end

  local current = module_for(bufnr, root)
  local labels, by_label = {}, {}
  local ordered = { current }
  for _, mod in ipairs(modules) do
    if mod ~= current then
      ordered[#ordered + 1] = mod
    end
  end

  for _, mod in ipairs(ordered) do
    local label = (mod == root and "entire project" or vim.fs.relpath(root, mod))
    if mod == current then
      label = label .. "  (current module)"
    end
    labels[#labels + 1] = label
    by_label[label] = mod
  end

  ui.pick_one(labels, "Java: Build — module", function(choice)
    local mod = by_label[choice]
    if mod then
      cb(mod)
    end
  end)
end

local function do_goal(root, bufnr, tool, goal, label)
  if not tool.runner then
    ui.notify(tool.reason or "build tool unavailable", vim.log.levels.WARN)
    return
  end
  ask_module(root, bufnr, function(module)
    run_build(tool, root, module, { goal }, label or goal)
  end)
end

local function do_choose_goal(root, bufnr, tool)
  if not tool.runner then
    ui.notify(tool.reason or "build tool unavailable", vim.log.levels.WARN)
    return
  end
  local defaults = tool.tool == "maven" and "clean package" or "build"
  ui.ask("Java: Build — " .. tool.tool .. " args: ", defaults, function(value)
    if value == nil then
      return
    end
    value = vim.trim(value)
    if value == "" then
      return
    end
    local parsed, arg_err = split_args(value)
    if not parsed then
      ui.notify(arg_err or "invalid arguments", vim.log.levels.ERROR)
      return
    end
    ask_module(root, bufnr, function(module)
      run_build(tool, root, module, parsed, "goal")
    end)
  end)
end

local function do_repeat(root, tool)
  local canon_root = run_config.canonical(root)
  -- prefer this session's argv record by canonical root (never crosses projects),
  -- then Java Menu's per-root persisted argv
  local parsed, has_history = resolve_last_build(canon_root, true)
  if not has_history then
    ui.notify("no previous build in this project", vim.log.levels.WARN)
    return
  end
  if not tool.runner then
    ui.notify(tool.reason or "build tool unavailable", vim.log.levels.WARN)
    return
  end
  start("build", vim.list_extend({ tool.runner }, parsed), root, root, { user_args = parsed })
end

local function run_main(root, bufnr, mains)
  if #mains == 0 then
    ui.notify("no class with public static void main found", vim.log.levels.WARN)
    return
  end

  local cfg, cfg_err = run_config.load(root)
  if cfg_err then
    ui.notify(cfg_err, vim.log.levels.WARN)
  end

  local labels, by_label = {}, {}
  for _, entry in ipairs(mains) do
    local label = string.format("%s  (%s)", entry.fqn, vim.fs.relpath(root, entry.path))
    labels[#labels + 1] = label
    by_label[label] = entry
  end

  ui.pick_one(labels, "Java: Build — Run Main", function(choice)
    local entry = by_label[choice]
    if not entry then
      return
    end

    ui.ask("Java: Build — JVM arguments (optional): ", cfg.jvm_args or "", function(jvm_args)
      if jvm_args == nil then
        return
      end
      local jvm_list, jvm_err = split_args(jvm_args)
      if not jvm_list then
        ui.notify("JVM arguments: " .. tostring(jvm_err), vim.log.levels.ERROR)
        return
      end

      ui.ask("Java: Build — application arguments (optional): ", cfg.app_args or "", function(app_args)
        if app_args == nil then
          return
        end
        local app_list, app_err = split_args(app_args)
        if not app_list then
          ui.notify("application arguments: " .. tostring(app_err), vim.log.levels.ERROR)
          return
        end

        local uri = vim.uri_from_fname(entry.path)
        classpath_for(uri, bufnr, function(cp, err)
          if not cp then
            ui.notify("Run Main unavailable: " .. tostring(err), vim.log.levels.ERROR)
            return
          end

          local java = java_bin()
          if not is_exec(java) then
            ui.notify("java not found (PATH/JAVA_HOME)", vim.log.levels.ERROR)
            return
          end

          local next_cfg = vim.deepcopy(cfg)
          next_cfg.jvm_args = vim.trim(jvm_args)
          next_cfg.app_args = vim.trim(app_args)
          local ok_save, save_err = run_config.save(root, next_cfg)
          local secret_warned = false
          if ok_save then
            cfg = next_cfg
          elseif save_err then
            ui.notify(save_err, vim.log.levels.WARN)
            secret_warned = save_err:find("overlap", 1, true) ~= nil
          end

          local cmd = { java }
          vim.list_extend(cmd, jvm_list)
          if #cp.classpaths > 0 then
            vim.list_extend(cmd, { "-cp", table.concat(cp.classpaths, ":") })
          end
          cmd[#cmd + 1] = entry.fqn
          vim.list_extend(cmd, app_list)

          local user_args = {}
          vim.list_extend(user_args, jvm_list)
          vim.list_extend(user_args, app_list)

          start("run_main", cmd, cp.project_root or entry.module or root, root, {
            use_env = next_cfg.use_env ~= false,
            _secret_warned = secret_warned,
            _force_secret = secret_warned,
            user_args = user_args,
          })
        end)
      end)
    end)
  end)
end

local function run_spring(root, bufnr, spring)
  if #spring == 0 then
    ui.notify("no Spring Boot module detected", vim.log.levels.WARN)
    return
  end
  local tool = build_tool(root)
  if not tool or tool.tool ~= "maven" then
    ui.notify("Spring Boot run requires Maven (spring-boot:run)", vim.log.levels.WARN)
    return
  end
  if not tool.runner then
    ui.notify(tool.reason or "mvn unavailable", vim.log.levels.WARN)
    return
  end

  local cfg, cfg_err = run_config.load(root)
  if cfg_err then
    ui.notify(cfg_err, vim.log.levels.WARN)
  end

  local labels, by_label = {}, {}
  for _, mod in ipairs(spring) do
    local label = vim.fs.relpath(root, mod)
    labels[#labels + 1] = label
    by_label[label] = mod
  end

  local function ask_and_run(module)
    local rel = vim.fs.relpath(root, module)
    local scan = run_config.scan_profiles(root, module)
    choose_profile(scan, cfg.profile, function(profile)
      ui.ask("Java: Build — JVM arguments (optional): ", cfg.jvm_args or "", function(jvm_args)
        if jvm_args == nil then
          return
        end
        local jvm_list, jvm_err = split_args(jvm_args)
        if not jvm_list then
          ui.notify("JVM arguments: " .. tostring(jvm_err), vim.log.levels.ERROR)
          return
        end

        ui.ask("Java: Build — application arguments (optional): ", cfg.app_args or "", function(app_args)
          if app_args == nil then
            return
          end
          local app_list, app_err = split_args(app_args)
          if not app_list then
            ui.notify("application arguments: " .. tostring(app_err), vim.log.levels.ERROR)
            return
          end

          local next_cfg = vim.deepcopy(cfg)
          next_cfg.profile = vim.trim(profile)
          next_cfg.jvm_args = vim.trim(jvm_args)
          next_cfg.app_args = vim.trim(app_args)
          local ok_save, save_err = run_config.save(root, next_cfg)
          local secret_warned = false
          if ok_save then
            cfg = next_cfg
          elseif save_err then
            ui.notify(save_err, vim.log.levels.WARN)
            secret_warned = save_err:find("overlap", 1, true) ~= nil
          end

          local cmd = { tool.runner }
          if module ~= root then
            vim.list_extend(cmd, { "-pl", rel, "-am" })
          end
          cmd[#cmd + 1] = "spring-boot:run"
          local user_args = {}
          if next_cfg.profile ~= "" then
            cmd[#cmd + 1] = "-Dspring-boot.run.profiles=" .. next_cfg.profile
            user_args[#user_args + 1] = next_cfg.profile
            local prof_tokens = split_args(next_cfg.profile)
            if prof_tokens then
              vim.list_extend(user_args, prof_tokens)
            end
          end
          if next_cfg.jvm_args ~= "" then
            cmd[#cmd + 1] = "-Dspring-boot.run.jvmArguments=" .. next_cfg.jvm_args
            vim.list_extend(user_args, jvm_list)
          end
          if next_cfg.app_args ~= "" then
            cmd[#cmd + 1] = "-Dspring-boot.run.arguments=" .. next_cfg.app_args
            vim.list_extend(user_args, app_list)
          end
          if next_cfg.jvm_args ~= "" then
            user_args[#user_args + 1] = next_cfg.jvm_args
          end
          if next_cfg.app_args ~= "" then
            user_args[#user_args + 1] = next_cfg.app_args
          end
          start("spring", cmd, root, root, {
            use_env = next_cfg.use_env ~= false,
            _secret_warned = secret_warned,
            _force_secret = secret_warned,
            user_args = user_args,
          })
        end)
      end)
    end)
  end

  if #spring == 1 then
    ask_and_run(spring[1])
    return
  end
  ui.pick_one(labels, "Java: Build — Spring Boot module", function(choice)
    local mod = by_label[choice]
    if mod then
      ask_and_run(mod)
    end
  end)
end

---Configure per-project run settings (contextual profile, JVM/app args, .env toggle).
function M.run_settings()
  local root = project.root(context_buf())
  if not root then
    ui.notify("no Maven/Gradle project (pom.xml, build.gradle) from this buffer", vim.log.levels.WARN)
    return
  end

  local cfg, cfg_err = run_config.load(root)
  if cfg_err then
    ui.notify(cfg_err, vim.log.levels.WARN)
  end
  local scan = run_config.scan_profiles(root)
  local env_info = run_config.load_env(root)
  for _, warn in ipairs(env_info.warnings) do
    ui.notify(warn, vim.log.levels.WARN)
  end

  local entries = {
    {
      key = "profile",
      label = ("Spring Profile: %s"):format(cfg.profile ~= "" and cfg.profile or "(none)"),
      enabled = true,
    },
    {
      key = "jvm_args",
      label = ("JVM Arguments: %s"):format(cfg.jvm_args ~= "" and cfg.jvm_args or "(none)"),
      enabled = true,
    },
    {
      key = "app_args",
      label = ("Application Arguments: %s"):format(cfg.app_args ~= "" and cfg.app_args or "(none)"),
      enabled = true,
    },
    {
      key = "use_env",
      label = env_info.exists and (".env File: %s (%d variable(s), values hidden)"):format(
        cfg.use_env ~= false and "enabled" or "disabled",
        #env_info.keys
      ) or ".env File: not found (optional)",
      enabled = env_info.exists,
      reason = "no .env file at project root",
    },
    {
      key = "reset",
      label = "Reset Run Settings",
      enabled = true,
    },
  }

  local function persist_and_notify(next_cfg, msg)
    local ok_save, save_err = run_config.save(root, next_cfg)
    if not ok_save then
      ui.notify(save_err or "could not save run settings", vim.log.levels.ERROR)
      return false
    end
    cfg = next_cfg
    ui.notify(msg, vim.log.levels.INFO)
    return true
  end

  ui.menu(entries, ("Java: Run Settings — %s"):format(vim.fs.basename(root)), function(entry)
    if entry.key == "profile" then
      choose_profile(scan, cfg.profile, function(profile)
        local next_cfg = vim.deepcopy(cfg)
        next_cfg.profile = vim.trim(profile)
        persist_and_notify(
          next_cfg,
          ("run profile set to %s (project %s)"):format(
            next_cfg.profile ~= "" and next_cfg.profile or "(none)",
            vim.fs.basename(root)
          )
        )
      end)
    elseif entry.key == "jvm_args" then
      ui.ask("Java: Run Settings — JVM arguments: ", cfg.jvm_args or "", function(value)
        if value == nil then
          return
        end
        local parsed, err = split_args(value)
        if not parsed then
          ui.notify("JVM arguments: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        local next_cfg = vim.deepcopy(cfg)
        next_cfg.jvm_args = vim.trim(value)
        persist_and_notify(next_cfg, ("JVM arguments updated (project %s)"):format(vim.fs.basename(root)))
      end)
    elseif entry.key == "app_args" then
      ui.ask("Java: Run Settings — application arguments: ", cfg.app_args or "", function(value)
        if value == nil then
          return
        end
        local parsed, err = split_args(value)
        if not parsed then
          ui.notify("application arguments: " .. tostring(err), vim.log.levels.ERROR)
          return
        end
        local next_cfg = vim.deepcopy(cfg)
        next_cfg.app_args = vim.trim(value)
        persist_and_notify(next_cfg, ("application arguments updated (project %s)"):format(vim.fs.basename(root)))
      end)
    elseif entry.key == "use_env" then
      local next_cfg = vim.deepcopy(cfg)
      next_cfg.use_env = not (cfg.use_env ~= false)
      persist_and_notify(
        next_cfg,
        (".env injection %s (project %s)"):format(next_cfg.use_env and "enabled" or "disabled", vim.fs.basename(root))
      )
    elseif entry.key == "reset" then
      local ok_reset, reset_err = run_config.reset(root)
      if not ok_reset then
        ui.notify(reset_err or "could not reset run settings", vim.log.levels.ERROR)
        return
      end
      ui.notify(("run settings reset (project %s)"):format(vim.fs.basename(root)), vim.log.levels.INFO)
    end
  end)
end

-- ---------- menu ----------

---Entry point of `<leader>jb`.
function M.build()
  local bufnr = context_buf()
  local root = project.root(bufnr)
  if not root then
    ui.notify("no Maven/Gradle project (pom.xml, build.gradle) from this buffer", vim.log.levels.WARN)
    return
  end

  local canon_root = run_config.canonical(root)
  local tool = build_tool(root)
  local attached = jdtls_attached(bufnr)
  local mains = main_classes(root)
  local springs = spring_modules(root)
  local java = java_bin()
  local can_build = tool ~= nil and tool.runner ~= nil
  local build_reason = (tool and tool.reason) or "no build tool found"
  local rec = last_runs[canon_root]
  local fg_draining = is_fg_draining()
  local fg_active = state.running or fg_draining
  local active_root = state.root and run_config.canonical(state.root) or nil
  local fg_pgid = state.pgid or state.draining_pgid
  if fg_active and fg_pgid then
    local fg_ticks = state.pgid and state.pgid_start_ticks or state.draining_start_ticks
    local fg_status, fg_uncertain_reason = group_status(fg_pgid, fg_ticks, state.pgid_members)
    if fg_status == "uncertain" then
      state.pgid_uncertain = true
      state.pgid_uncertain_reason = fg_uncertain_reason
    elseif fg_status == "alive" then
      state.pgid_uncertain = false
      state.pgid_uncertain_reason = nil
      if state.pgid_members ~= nil then
        local latest = refresh_verified_members(fg_pgid, fg_ticks, state.pgid_sid, state.pgid_members)
        if latest then
          state.pgid_members = latest
        end
      end
    end
  end
  local bg_targets, bg_chosen
  if not fg_active then
    bg_targets, bg_chosen = select_background_targets(canon_root, true)
    if not bg_targets or #bg_targets == 0 then
      bg_targets, bg_chosen = select_background_targets(canon_root, false)
    end
  else
    prune_background_groups(true)
  end
  local own_uncertain_bg = nil
  for _, bg in ipairs(background_groups) do
    if bg.uncertain and bg.canon_root == canon_root then
      own_uncertain_bg = bg
      break
    end
  end
  local any_uncertain_bg = own_uncertain_bg or find_uncertain_bg(canon_root)
  local stopping_bg = (not fg_active and bg_chosen and bg_chosen.stopping) and bg_chosen or nil
  local fg_unverified = fg_active and (not fg_pgid or state.pgid_uncertain)
  local fg_unverified_reason = state.pgid_uncertain_reason or state.pgid_reason or "process group could not be verified"
  local stop_active = (fg_active and not state.pgid_uncertain) or (bg_chosen ~= nil)
  local stop_canon = fg_active and active_root or (bg_chosen and bg_chosen.canon_root) or nil

  local _, has_last_build = resolve_last_build(canon_root, false)
  local entries = {
    {
      key = "run_main",
      label = "Run Main Class",
      enabled = attached and #mains > 0 and is_exec(java),
      reason = (not attached and "jdtls is not attached (classpath comes from jdtls)")
        or (#mains == 0 and "no class with public static void main")
        or "java not found",
    },
    {
      key = "run_spring",
      label = "Run Spring Boot",
      enabled = #springs > 0 and tool ~= nil and tool.tool == "maven" and tool.runner ~= nil,
      reason = (#springs == 0 and "no Spring Boot module detected")
        or (tool and tool.tool ~= "maven" and "spring-boot:run requires Maven")
        or build_reason,
    },
    {
      key = "restart",
      label = rec and ("Restart Last Process (%s)"):format(rec.kind) or "Restart Last Process",
      enabled = rec ~= nil
        and not fg_unverified
        and own_uncertain_bg == nil
        and not (stopping_bg ~= nil and stopping_bg.canon_root ~= canon_root),
      reason = (not rec and "no previous command in this project")
        or (fg_unverified and ("cannot automatically restart running process (" .. fg_unverified_reason .. ") — stop it manually first"))
        or (own_uncertain_bg and ("cannot automatically restart (" .. (own_uncertain_bg.uncertain_reason or ("process group " .. tostring(
          own_uncertain_bg.pgid
        ) .. " identity could not be verified")) .. ") — verify and stop it manually first"))
        or (fg_active and active_root ~= canon_root and "process from another project — will ask for confirmation")
        or (stopping_bg and stopping_bg.canon_root ~= canon_root and "another project's background process is still stopping")
        or "",
    },
    {
      key = "run_settings",
      label = "Run Settings…",
      enabled = true,
    },
    { key = "compile", label = "Compile", enabled = can_build, reason = build_reason },
    { key = "package", label = "Package", enabled = can_build, reason = build_reason },
    { key = "clean", label = "Clean", enabled = can_build, reason = build_reason },
    { key = "install", label = "Install", enabled = can_build, reason = build_reason },
    {
      key = "choose_goal",
      label = "Choose Maven/Gradle Goal…",
      enabled = can_build,
      reason = build_reason,
    },
    {
      key = "repeat",
      label = "Repeat Last",
      enabled = can_build and has_last_build,
      reason = (not can_build and build_reason) or "no previous build in this project",
    },
    {
      key = "stop",
      label = (
        fg_active
        and (
          state.root and ("Stop Running Process — project %s"):format(vim.fs.basename(state.root))
          or "Stop Running Process"
        )
      )
        or (bg_chosen and (bg_chosen.root and ("Stop Background Process — project %s"):format(
          vim.fs.basename(bg_chosen.root)
        ) or "Stop Background Process"))
        or "Stop Running Process",
      enabled = stop_active,
      reason = (
        fg_active
        and state.pgid_uncertain
        and ("cannot automatically stop (" .. fg_unverified_reason .. ") — verify and stop it manually")
      )
        or (fg_active and active_root ~= canon_root and "process from another project — will ask for confirmation")
        or (bg_chosen and stop_canon ~= canon_root and "background process from another project — will ask for confirmation")
        or (not fg_active and not bg_chosen and any_uncertain_bg and ("process group " .. tostring(
          any_uncertain_bg.pgid
        ) .. " identity could not be verified — verify and stop it manually"))
        or "no process running",
    },
    {
      key = "output",
      label = state.last_output_root
          and vim.api.nvim_buf_is_valid(state.last_output or -1)
          and ("Show Last Output — project %s"):format(vim.fs.basename(state.last_output_root))
        or "Show Last Output",
      enabled = state.last_output ~= nil and vim.api.nvim_buf_is_valid(state.last_output),
      reason = "no previous output",
    },
  }

  ui.menu(
    entries,
    ("Java: Build — %s — %s"):format(tool and tool.tool or "?", vim.fs.basename(root)),
    function(entry)
      if entry.key == "run_main" then
        run_main(root, bufnr, mains)
      elseif entry.key == "run_spring" then
        run_spring(root, bufnr, springs)
      elseif entry.key == "restart" then
        M.restart()
      elseif entry.key == "run_settings" then
        M.run_settings()
      elseif entry.key == "compile" then
        do_goal(root, bufnr, tool, LIFECYCLE.compile)
      elseif entry.key == "package" then
        do_goal(root, bufnr, tool, LIFECYCLE.package)
      elseif entry.key == "clean" then
        do_goal(root, bufnr, tool, LIFECYCLE.clean)
      elseif entry.key == "install" then
        do_goal(root, bufnr, tool, LIFECYCLE.install)
      elseif entry.key == "choose_goal" then
        do_choose_goal(root, bufnr, tool)
      elseif entry.key == "repeat" then
        do_repeat(root, tool)
      elseif entry.key == "stop" then
        M.stop()
      elseif entry.key == "output" then
        M.show_output()
      end
    end
  )
end

-- exposed for tests
M._state = state
M._build_tool = build_tool
M._main_classes = main_classes
M._spring_modules = spring_modules
M._module_for = module_for
M._scope_args = scope_args
M._last_builds = last_builds
M._last_runs = last_runs
M._is_draining = is_draining
M._start_drain_monitor = start_drain_monitor
M._background_groups = background_groups
M._read_proc_info = read_proc_info
M._group_status = group_status
M._group_alive = group_alive
M._bg_group_status = bg_group_status
M._verify_own_pgid = verify_own_pgid
M._kill_tree = kill_tree
M._feed = feed
M._finish = finish
M._pending = pending
M._pending_text = pending_text
M._reset_streams = reset_all_streams

return M
