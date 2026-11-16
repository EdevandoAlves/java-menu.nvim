-- java_menu/lsp.lua
-- JDTLS client selection for the source buffer.
--
-- jc.nvim resolves the client globally (`jc.lsp.get_jdtls_client()`), which is
-- fine with one project per session but ambiguous with two independent Java
-- projects open at once. The Java Menu selects the client by buffer and uses
-- Neovim APIs; no server is started or reconfigured here.

local M = {}

---JDTLS client attached to the buffer (nil when there is no client).
---@param bufnr number|nil
---@return vim.lsp.Client|nil
function M.client(bufnr)
  bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local clients = vim.lsp.get_clients({ name = "jdtls", bufnr = bufnr })
  return clients[1]
end

---Client attached to the buffer plus a readable reason when there is none.
---@param bufnr number|nil
---@return vim.lsp.Client|nil client
---@return string|nil reason
function M.client_or_reason(bufnr)
  bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "the target buffer no longer exists"
  end
  local clients = vim.lsp.get_clients({ name = "jdtls", bufnr = bufnr })
  if #clients == 0 then
    return nil, "jdtls is not attached to this buffer"
  end
  return clients[1], nil
end

---Client encoding, with the nvim-jdtls default when unavailable.
---@param client vim.lsp.Client|nil
---@return string
function M.encoding(client)
  return (client and client.offset_encoding) or "utf-16"
end

---LSP capabilities: use blink.cmp's when available (merged over the native
---ones); without blink, native only. Nothing is installed here and completion
---for other languages is untouched.
---@return table
function M.capabilities()
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  local ok, blink = pcall(require, "blink.cmp")
  if ok and type(blink.get_lsp_capabilities) == "function" then
    capabilities = blink.get_lsp_capabilities(capabilities)
  end
  return capabilities
end

---Reason to block jc APIs that resolve the client globally.
---jc calls `jc.lsp.get_jdtls_client()`/`executeCommand()` without a bufnr; with
---two Java projects open the choice is ambiguous. Desired upstream APIs:
---`get_jdtls_client(bufnr)`, `jdtls_request(bufnr, ...)` already targeted, and
---`executeCommand(command, callback, { bufnr = bufnr })`.
---@param op string|nil label of the operation for the message
---@return string|nil reason
function M.jc_global_reason(op)
  local count = #vim.lsp.get_clients({ name = "jdtls" })
  if count <= 1 then
    return nil
  end
  local what = op and (" (" .. op .. ")") or ""
  return ("jc.nvim operation unavailable with %d Java projects open%s: jc resolves the jdtls client globally and does not accept a bufnr/client in this API"):format(
    count,
    what
  )
end

---Number of JDTLS clients in the session (for tests).
---@return integer
function M.global_count()
  return #vim.lsp.get_clients({ name = "jdtls" })
end

return M
