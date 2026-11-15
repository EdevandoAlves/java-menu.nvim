-- Fixtures para specs do Java Menu.
-- Não inicia JDTLS nem altera configuração: apenas cria projetos temporários.

local M = {}

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(vim.trim(text) .. "\n", "\n", { plain = true }), path)
end

---Projeto Maven single-module com um arquivo Java.
---@param label string
---@param pkg string
---@param class_name string
---@return string root, string main_path
function M.maven_project(label, pkg, class_name)
  local root = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-" .. label)
  local rel_pkg = pkg:gsub("%.", "/")
  local main_path = root .. "/src/main/java/" .. rel_pkg .. "/" .. class_name .. ".java"

  write(root .. "/pom.xml", [[
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.java.menu.test</groupId>
  <artifactId>]] .. label .. [[</artifactId>
  <version>1.0</version>
  <properties>
    <maven.compiler.release>21</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
</project>
]])

  write(main_path, [[
package ]] .. pkg .. [[;

public class ]] .. class_name .. [[ {
  public String name() {
    return "]] .. class_name .. [[";
  }
}
]])

  return root, main_path
end

---Arquivo Java adicional no mesmo projeto.
---@param root string
---@param pkg string
---@param class_name string
---@param body string|nil corpo sem declaração de package/class
---@return string path
function M.java_file(root, pkg, class_name, body)
  local rel_pkg = pkg:gsub("%.", "/")
  local path = root .. "/src/main/java/" .. rel_pkg .. "/" .. class_name .. ".java"
  write(path, [[
package ]] .. pkg .. [[;

public class ]] .. class_name .. [[ {
]] .. (body or "") .. [[
}
]])
  return path
end

---Espera até `predicate()` ser verdadeira.
---@param timeout_ms integer
---@param predicate fun(): boolean
---@return boolean
function M.wait_for(timeout_ms, predicate)
  return vim.wait(timeout_ms or 30000, predicate, 100)
end

---Escreve um arquivo (cria diretórios pais).
---@param path string
---@param lines string[]
function M.write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local function pom_xml(path, modules, with_parent)
  local t = { '<project xmlns="http://maven.apache.org/POM/4.0.0">' }
  if with_parent then
    vim.list_extend(t, {
      "  <parent>",
      "    <groupId>com.nest</groupId>",
      "    <artifactId>root</artifactId>",
      "    <version>1.0</version>",
      "  </parent>",
    })
  end
  vim.list_extend(t, {
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>com.nest</groupId>",
    "  <artifactId>" .. vim.fs.basename(vim.fs.dirname(path)) .. "</artifactId>",
    "  <version>1.0</version>",
    "  <packaging>pom</packaging>",
  })
  if modules and #modules > 0 then
    t[#t + 1] = "  <modules>"
    for _, m in ipairs(modules) do
      t[#t + 1] = "    <module>" .. m .. "</module>"
    end
    t[#t + 1] = "  </modules>"
  end
  t[#t + 1] = "</project>"
  M.write(path, t)
end

---Projeto Maven multimódulo aninhado (M3):
---  root/pom.xml       → modules: services, libraries/core
---  services/pom.xml   → modules: api, worker
---  services/{api,worker}, libraries/core (poms standalone)
---  root/rogue/pom.xml (NÃO declarado), root/.git/pom.xml
---@param label string
---@return string root, table mods { services, api, worker, core }
function M.maven_nested(label)
  local root = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-nest-" .. label)
  pom_xml(root .. "/pom.xml", { "services", "libraries/core" })
  pom_xml(root .. "/services/pom.xml", { "api", "worker" })
  pom_xml(root .. "/services/api/pom.xml")
  pom_xml(root .. "/services/worker/pom.xml")
  pom_xml(root .. "/libraries/core/pom.xml")
  pom_xml(root .. "/rogue/pom.xml")
  pom_xml(root .. "/.git/pom.xml")
  local mods = {
    services = root .. "/services",
    api = root .. "/services/api",
    worker = root .. "/services/worker",
    core = root .. "/libraries/core",
  }
  for _, dir in pairs(mods) do
    M.write(dir .. "/src/main/java/com/nest/" .. vim.fs.basename(dir) .. "/Thing.java", {
      "package com.nest." .. vim.fs.basename(dir) .. ";",
      "",
      "public class Thing {}",
    })
  end
  return root, mods
end

---Projeto Gradle com settings estático (sem Gradle instalado: só descoberta).
---@param label string
---@param settings string[] linhas do settings.gradle(.kts)
---@param opts { kts: boolean|nil, src_dirs: string[]|nil }|nil dirs relativos criados
---@return string root
function M.gradle_project(label, settings, opts)
  opts = opts or {}
  local root = vim.fs.normalize(vim.fn.tempname() .. "/java-menu-gradle-" .. label)
  local name = opts.kts and "settings.gradle.kts" or "settings.gradle"
  M.write(root .. "/" .. name, settings)
  M.write(root .. "/build.gradle", { "// vazio" })
  for _, dir in ipairs(opts.src_dirs or {}) do
    M.write(root .. "/" .. dir .. "/.keep", {})
  end
  return root
end

return M
