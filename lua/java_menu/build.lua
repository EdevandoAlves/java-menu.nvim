-- java_menu/build.lua
-- <leader>jb: build and run Java projects (Maven preferred, Gradle when an
-- executable wrapper exists). Reuses the earlier infrastructure (ui, project)
-- and `jc.settings` for jc's "repeat last".

local ui = require("java_menu.ui")
local project = require("java_menu.project")
local lsp = require("java_menu.lsp")
local jca = require("java_menu.jc")

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
  buf = nil,
  kind = nil,
  cmd = nil,
  cwd = nil,
  root = nil, -- project that started the job (isolation between projects)
  running = false,
  status = "idle",
  last_output = nil,
  last_output_root = nil,
}

---Last build arguments per project (repeat never crosses projects).
---jc.settings persists by cwd project name; here the key is the resolved
---buffer root, so repeat never runs A's args in B.
local last_builds = {}

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

local pending = { stdout = "", stderr = "" }

local function feed(buf, stream, data)
  if type(data) ~= "table" then
    return
  end
  local text = pending[stream] .. table.concat(data, "\n")
  local lines = vim.split(text, "\n", { plain = true })
  pending[stream] = table.remove(lines) or ""
  vim.schedule(function()
    append(buf, lines)
  end)
end

local function finish(code)
  local buf = state.buf
  state.running = false
  state.job = nil
  state.status = code == 0 and "success" or "failed"

  for _, stream in ipairs({ "stdout", "stderr" }) do
    if pending[stream] ~= "" then
      append(buf, { pending[stream] })
      pending[stream] = ""
    end
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

  ui.notify(
    ("[%s] %s — exit %s"):format(state.kind or "build", state.status, tostring(code)),
    state.status == "success" and vim.log.levels.INFO or vim.log.levels.ERROR
  )
end

---Start a process. `cmd` is a list; it runs with setsid so the whole group
---can be stopped (avoids an orphan JVM from spring-boot:run). `root` is the
---originating project — the menu never treats this process as the current one.
local function start(kind, cmd, cwd, root)
  if state.running then
    ui.notify("a process is already running — stop it before starting another", vim.log.levels.WARN)
    return
  end

  local buf = open_output(kind)
  append(buf, {
    ("$ %s"):format(table.concat(cmd, " ")),
    ("cwd: %s"):format(cwd),
    "",
  })

  local full = cmd
  pending.stdout, pending.stderr = "", ""
  local prev_win = vim.api.nvim_get_current_win() ---@type integer|nil
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == context_buf() then
      prev_win = win
    end
  end
  local job = vim.fn.jobstart(full, {
    cwd = cwd,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      feed(buf, "stdout", data)
    end,
    on_stderr = function(_, data)
      feed(buf, "stderr", data)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        finish(code)
      end)
    end,
  })

  if job <= 0 then
    ui.notify("could not start: " .. table.concat(cmd, " "), vim.log.levels.ERROR)
    return
  end

  state.job = job
  state.buf = buf
  state.last_output = buf
  state.kind = kind
  state.cmd = cmd
  state.cwd = cwd
  state.root = root or cwd
  state.last_output_root = root or cwd
  state.running = true
  state.status = "running"

  -- keep focus in the code; the output split stays visible below
  if prev_win and vim.api.nvim_win_is_valid(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end

  ui.notify(
    ("%s started (project %s)\n$ %s\nin %s"):format(kind, vim.fs.basename(state.root), table.concat(cmd, " "), cwd),
    vim.log.levels.INFO
  )
end

---Kill the process tree started by this job (children first).
local function kill_tree(pid)
  if not pid or pid <= 0 then
    return
  end
  local ok, children = pcall(vim.fn.systemlist, { "pgrep", "-P", tostring(pid) })
  if ok then
    for _, child in ipairs(children or {}) do
      local child_pid = tonumber(child)
      if child_pid then
        kill_tree(child_pid)
      end
    end
  end
  pcall(vim.fn.system, { "kill", "-TERM", tostring(pid) })
end

---Stop the current process (and only its tree). When the process belongs to
---another project, require an explicit user choice — never silently kill a
---job from a project other than the current buffer.
---@param confirmed boolean|nil
function M.stop(confirmed)
  if not state.running or not state.job then
    ui.notify("no Java process is running", vim.log.levels.WARN)
    return
  end
  local current_root = project.root(context_buf())
  local from_other_project = state.root ~= nil and current_root ~= nil and state.root ~= current_root
  if from_other_project and not confirmed then
    local origin = vim.fs.basename(state.root)
    ui.pick_one(
      {
        ("No — keep the %s project process"):format(origin),
        ("Yes — stop the %s project process"):format(origin),
      },
      "Java: Build — process belongs to another project",
      function(choice)
        if choice and choice:find("^Yes") then
          M.stop(true)
        elseif choice then
          ui.notify(("the %s project process was kept running"):format(origin), vim.log.levels.INFO)
        end
      end
    )
    return
  end
  local pid = vim.fn.jobpid(state.job)
  kill_tree(pid)
  pcall(vim.fn.jobstop, state.job)
  ui.notify(
    from_other_project and ("the %s project process was stopped"):format(vim.fs.basename(state.root))
      or "process stopped",
    vim.log.levels.INFO
  )
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
  last_builds[root] = table.concat(scoped, " ")
  -- same state as jc :JCbuildLast (argument string per project)
  local ok, err = jca.write_build_last(table.concat(scoped, " "))
  if not ok then
    ui.notify(err, vim.log.levels.WARN)
  end
  start(label or args[1], cmd, root, root)
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
  if not text or vim.trim(text) == "" then
    return {}
  end
  return vim.split(vim.trim(text), "%s+", { trimempty = true })
end

-- ---------- operations ----------

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
    ask_module(root, bufnr, function(module)
      run_build(tool, root, module, split_args(value), "goal")
    end)
  end)
end

local function do_repeat(root, bufnr, tool)
  -- prefer this session's record by ROOT (never crosses projects);
  -- without it, fall back to jc build-last (keyed by the cwd project)
  local last = last_builds[root]
  if not last or last == "" then
    local err
    last, err = jca.read_build_last()
    if err then
      ui.notify(err, vim.log.levels.WARN)
    end
  end
  if not last or last == "" then
    ui.notify("no previous build in this project", vim.log.levels.WARN)
    return
  end
  if not tool.runner then
    ui.notify(tool.reason or "build tool unavailable", vim.log.levels.WARN)
    return
  end
  start("build", vim.list_extend({ tool.runner }, split_args(last)), root, root)
end

local function run_main(root, bufnr, mains)
  if #mains == 0 then
    ui.notify("no class with public static void main found", vim.log.levels.WARN)
    return
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

    ui.ask("Java: Build — application arguments: ", "", function(args)
      if args == nil then
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

        local cmd = { java }
        if #cp.classpaths > 0 then
          vim.list_extend(cmd, { "-cp", table.concat(cp.classpaths, ":") })
        end
        cmd[#cmd + 1] = entry.fqn
        vim.list_extend(cmd, split_args(args))

        start("run_main", cmd, cp.project_root or entry.module or root, root)
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

  local labels, by_label = {}, {}
  for _, mod in ipairs(spring) do
    local label = vim.fs.relpath(root, mod)
    labels[#labels + 1] = label
    by_label[label] = mod
  end

  local function ask_and_run(module)
    local rel = vim.fs.relpath(root, module)
    ui.ask("Java: Build — Spring profile (optional): ", "", function(profile)
      if profile == nil then
        return
      end
      ui.ask("Java: Build — application arguments (optional): ", "", function(args)
        if args == nil then
          return
        end
        local cmd = { tool.runner }
        if module ~= root then
          vim.list_extend(cmd, { "-pl", rel, "-am" })
        end
        cmd[#cmd + 1] = "spring-boot:run"
        if vim.trim(profile) ~= "" then
          cmd[#cmd + 1] = "-Dspring-boot.run.profiles=" .. vim.trim(profile)
        end
        if vim.trim(args) ~= "" then
          cmd[#cmd + 1] = "-Dspring-boot.run.arguments=" .. vim.trim(args)
        end
        start("spring", cmd, root, root)
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

-- ---------- menu ----------

---Entry point of `<leader>jb`.
function M.build()
  local bufnr = context_buf()
  local root = project.root(bufnr)
  if not root then
    ui.notify("no Maven/Gradle project (pom.xml, build.gradle) from this buffer", vim.log.levels.WARN)
    return
  end

  local tool = build_tool(root)
  local attached = jdtls_attached(bufnr)
  local mains = main_classes(root)
  local springs = spring_modules(root)
  local java = java_bin()
  local can_build = tool ~= nil and tool.runner ~= nil
  local build_reason = (tool and tool.reason) or "no build tool found"

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
      enabled = can_build and (function()
        local last = last_builds[root]
        if not last or last == "" then
          last = jca.read_build_last()
        end
        return last ~= nil and last ~= ""
      end)(),
      reason = (not can_build and build_reason) or "no previous build in this project",
    },
    {
      key = "stop",
      label = state.running and state.root and ("Stop Running Process — project %s"):format(
        vim.fs.basename(state.root)
      ) or "Stop Running Process",
      enabled = state.running,
      reason = (state.running and state.root ~= root and "process from another project — will ask for confirmation")
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
        do_repeat(root, bufnr, tool)
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

return M
