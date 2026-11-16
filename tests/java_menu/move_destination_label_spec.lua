-- Regression: Move Class destinations must be distinguishable by source root.
-- Run with:
--   nvim --headless -u NONE \
--     -c "set rtp+=~/.config/nvim" \
--     -c "luafile tests/java_menu/move_destination_label_spec.lua" -c qa

local refactor = require("java_menu.refactor")

local root = "/tmp/proj"
local function dest(path, name, default)
  return {
    uri = "file://" .. path,
    displayName = name,
    isDefaultPackage = default == true,
  }
end

local app_test, app_test_dir =
  refactor._destination_label(root, dest("/tmp/proj/app/src/test/java/com/demo/lib", "com.demo.lib"))
local lib_main, lib_main_dir =
  refactor._destination_label(root, dest("/tmp/proj/lib/src/main/java/com/demo/lib", "com.demo.lib"))
local default_pkg = refactor._destination_label(root, dest("/tmp/proj/app/src/main/java", nil, true))

assert(app_test == "com.demo.lib  [app/src/test/java/com/demo/lib]", app_test)
assert(lib_main == "com.demo.lib  [lib/src/main/java/com/demo/lib]", lib_main)
assert(app_test ~= lib_main, "destinos de source roots diferentes não podem colidir")
assert(app_test_dir == "/tmp/proj/app/src/test/java/com/demo/lib", app_test_dir)
assert(lib_main_dir == "/tmp/proj/lib/src/main/java/com/demo/lib", lib_main_dir)
assert(default_pkg == "(default package)  [app/src/main/java]", default_pkg)

-- Validação do plano de Move: o destino e a declaração `package` precisam
-- corresponder ao package escolhido.
local function plan(opts)
  return {
    ops = {
      { kind = "rename", old_path = opts.source, new_path = opts.target },
    },
    files = {
      {
        source_path = opts.source,
        after = opts.after or { "package " .. (opts.package or "com.demo") .. ";", "", "public class C {}" },
      },
    },
  }
end

local source = "/tmp/proj/src/main/java/com/demo/pkg/C.java"
local target = "/tmp/proj/src/main/java/com/demo/C.java"
local expected = { source_path = source, target_path = target, package = "com.demo", root = "/tmp/proj" }

local ok, reason =
  refactor._validate_move_plan(plan({ source = source, target = target, package = "com.demo" }), expected)
assert(ok, "plano correto recusado: " .. tostring(reason))

ok, reason = refactor._validate_move_plan(
  plan({ source = source, target = "/tmp/proj/src/main/java/C.java", package = "com.demo" }),
  expected
)
assert(not ok, "destino na raiz do source root deveria ser recusado")
assert(reason:find("does not match", 1, true) ~= nil, "motivo de destino divergente ausente: " .. tostring(reason))

ok, reason = refactor._validate_move_plan(plan({ source = source, target = target, package = "com.other" }), expected)
assert(not ok, "package divergente deveria ser recusado")
assert(
  reason:find("resulting declaration", 1, true) ~= nil,
  "motivo de package divergente ausente: " .. tostring(reason)
)

ok, reason = refactor._validate_move_plan(
  plan({ source = source, target = target, after = { "package com.demo;", "", "public class C {}" } }),
  expected
)
assert(ok, "package igual deveria ser aceito: " .. tostring(reason))

ok = refactor._validate_move_plan(plan({ source = source, target = target, after = { "public class C {}" } }), expected)
assert(not ok, "package ausente deveria ser recusado")

local default_expected = {
  source_path = source,
  target_path = "/tmp/proj/src/main/java/C.java",
  package = "",
  root = "/tmp/proj",
}
ok = refactor._validate_move_plan(
  plan({
    source = source,
    target = "/tmp/proj/src/main/java/C.java",
    after = { "public class C {}" },
  }),
  default_expected
)
assert(ok, "default package sem declaração deveria ser aceito")
ok = refactor._validate_move_plan(
  plan({ source = source, target = "/tmp/proj/src/main/java/C.java", package = "com.demo" }),
  default_expected
)
assert(not ok, "default package mantendo declaração deveria ser recusado")

ok = refactor._validate_move_plan({ ops = {}, files = {} }, expected)
assert(not ok, "plano sem rename deveria ser recusado")

print("move_destination_label_spec: OK")
